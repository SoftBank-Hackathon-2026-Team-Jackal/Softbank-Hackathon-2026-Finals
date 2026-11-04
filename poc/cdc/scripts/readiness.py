#!/usr/bin/env python3
"""사용법: readiness.py <현재 주 DB> [관찰 시간(초)]

지금 전환해도 되는 순간인지 판단하는 신호를 JSON 한 줄로 출력한다 (notes/cdc-short-switchover.md E1).
에이전트는 이 값을 몇 번 읽어 추세를 보고 전환 시점을 고르고, 05_switchover_fast.py 는
PAUSE 직전에 같은 조건(ready)을 다시 확인한다.

PAUSE 는 진행 중인 트랜잭션이 끝나기를 기다리므로, 쓰기 중단 시간의 하한은 "그 순간 가장 오래 걸릴 트랜잭션"이다.
  longest_xact_ms   지금 열려 있는 트랜잭션 가운데 가장 오래된 것의 경과 시간 (이 도구의 접속은 제외)
  lock_waiters      잠금을 기다리는 세션 수. 배치가 행을 잠그고 있으면 앱 트랜잭션이 줄줄이 길어진다
  lag_bytes         정방향 슬롯 지연량. 크면 marker 가 늦게 도착한다
  commits_per_sec   관찰 시간 동안의 초당 커밋 수 (트래픽 추세)
  top               오래된 트랜잭션 상위 3개 (에이전트가 배치인지 판단하는 근거)
ready = longest_xact_ms <= READY_MAX_XACT_MS 이고 lock_waiters == 0 이고 0 <= lag_bytes <= LAG_OK_BYTES
"""
import json
import os
import sys
import time

import psycopg

READY_MAX_XACT_MS = int(os.environ.get("READY_MAX_XACT_MS", 200))
LAG_OK_BYTES = int(os.environ.get("LAG_OK_BYTES", 1048576))
APP_NAME = "mig-switchover"   # 이 도구의 접속. 신호에서 제외한다


def sub_name(node):
    return "mig_from_" + node.replace("-", "_")


def sample(conn, fwd):
    row = conn.execute("""
        with a as (
          select pid, usename, state, wait_event_type, xact_start, left(query, 80) as query
          from pg_stat_activity
          where backend_type = 'client backend' and pid <> pg_backend_pid()
            and coalesce(application_name, '') <> %(app)s
        )
        select
          coalesce((extract(epoch from now() - min(xact_start)) * 1000)::bigint, 0),
          count(*) filter (where xact_start is not null),
          count(*) filter (where wait_event_type = 'Lock'),
          (select coalesce(max(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)), -1)::bigint
             from pg_replication_slots where slot_name = %(fwd)s),
          (select xact_commit from pg_stat_database where datname = current_database()),
          coalesce((select json_agg(t) from (
             select pid, usename, (extract(epoch from now() - xact_start) * 1000)::bigint as xact_ms,
                    state, wait_event_type, query
             from a where xact_start is not null order by xact_start limit 3) t), '[]'::json)
        from a""", {"app": APP_NAME, "fwd": fwd}).fetchone()
    longest, open_x, waiters, lag, commits, top = row
    return {"longest_xact_ms": longest, "open_xacts": open_x, "lock_waiters": waiters,
            "lag_bytes": lag, "xact_commit": commits, "top": top}


def is_ready(s):
    reasons = []
    if s["longest_xact_ms"] > READY_MAX_XACT_MS:
        reasons.append(f"트랜잭션이 {s['longest_xact_ms']}ms 째 진행 중 (기준 {READY_MAX_XACT_MS}ms)")
    if s["lock_waiters"]:
        reasons.append(f"잠금 대기 {s['lock_waiters']}건")
    if not 0 <= s["lag_bytes"] <= LAG_OK_BYTES:
        reasons.append(f"복제 지연 {s['lag_bytes']} bytes")
    return not reasons, reasons


def main():
    node = sys.argv[1]
    window = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
    url = os.environ[node.upper().replace("-", "_") + "_URL"]
    with psycopg.connect(url, autocommit=True, application_name=APP_NAME) as conn:
        first = sample(conn, sub_name(node))
        t0 = time.monotonic()
        time.sleep(window)
        s = sample(conn, sub_name(node))
        s["commits_per_sec"] = round((s.pop("xact_commit") - first["xact_commit"]) / (time.monotonic() - t0), 1)
    s["ready"], s["reasons"] = is_ready(s)
    s["t"] = int(time.time() * 1000)
    print(json.dumps(s, ensure_ascii=False))


if __name__ == "__main__":
    main()
