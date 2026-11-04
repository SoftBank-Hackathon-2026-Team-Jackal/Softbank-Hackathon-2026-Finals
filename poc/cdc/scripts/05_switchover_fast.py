#!/usr/bin/env python3
"""사용법: 05_switchover_fast.py <현재 주 DB> <새 주 DB>

05_switchover.sh 와 같은 전환을 하되, PAUSE 안에서 하는 일을 최소로 줄인다
(notes/cdc-short-switchover.md A3~A6).

PAUSE 전
  0a. 역방향 구독을 꺼진 상태로 생성 (A1)
  0b. 대상 시퀀스를 원본 값 + SEQ_HEADROOM 으로 미리 올림 (A4)
  0c. 동기 복제 창: 원본에 synchronous_standby_names = <정방향 구독>,
      synchronous_commit = local 을 설정 (A3)
      앱 트랜잭션은 local 이라 기다리지 않고, 이 스크립트의 marker 커밋만 remote_apply 로
      대상 반영까지 기다린다. 커밋 순서대로 적용되므로 marker 가 반영되면 그 앞의 변경도 모두 반영된 것이다.
  0d. 전환 가능 시점 대기 (E1): readiness.py 의 ready 조건(오래된 트랜잭션, 잠금 대기, 지연 없음)을
      만족하는 순간에만 PAUSE 한다. WAIT_READY_SEC 안에 오지 않으면 PAUSE 하지 않고 중단한다
PAUSE 안
  1. PAUSE                         진행 중 트랜잭션이 끝나기를 기다림
  2. marker 커밋 (remote_apply)     폴링 없이 대상 반영 시점에 커밋이 돌아옴
  3. 두 DB에서 스냅샷 고정 + 시퀀스 확인 (병렬)
     원본 시퀀스가 미리 올린 값을 넘었으면 그때만 대상에서 setval
  4. 정방향 구독 DISABLE + 역방향 구독 ENABLE (병렬)
  5. PgBouncer 대상 변경 → RECONNECT → RESUME
RESUME 후
  6. 동기 복제 창 해제, 정방향 구독 삭제 (원격 슬롯 삭제는 느리므로 PAUSE 밖에서)
  7. 3에서 고정한 스냅샷으로 두 DB를 비교 (A5). 전환 순간의 상태를 비교하므로 쓰기가 계속돼도 정확하다

모든 접속은 처음에 한 번만 연다 (A6). PAUSE 안에서는 SQL만 보낸다.
PAUSE 안에서 실패하면 구독 상태를 되돌리고 원래 DB로 RESUME 한다.
"""
import json
import os
import select
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import psycopg
from psycopg import sql
from psycopg.pq import ExecStatus

from readiness import APP_NAME, is_ready, sample

RESULTS_DIR = os.environ.get("RESULTS_DIR", "/poc/results")
LAG_OK_BYTES = int(os.environ.get("LAG_OK_BYTES", 1048576))
PAUSE_TIMEOUT_SEC = float(os.environ.get("PAUSE_TIMEOUT_SEC", 5))
MARKER_TIMEOUT_MS = int(os.environ.get("MARKER_TIMEOUT_MS", 10000))
SEQ_HEADROOM = int(os.environ.get("SEQ_HEADROOM", 10000))
# 전환 후 검증: checksum(전체 체크섬) | light(테이블별 max(id)) | auto(DB 100MB 이하면 checksum) | none
# 전체 체크섬은 새 DB에서 앱과 CPU, 디스크를 나눠 쓴다. 450MB에서 전환 직후 15초 동안 앱 최대 지연이 1.1초까지 올랐으므로
# 큰 DB는 light 로 확인하고, 전체 체크섬은 한가한 시간에 04_compare.sh 로 따로 한다
VERIFY_AFTER = os.environ.get("VERIFY_AFTER", "auto")
# 전환 가능 시점을 기다리는 최대 시간(초). 0 이면 기다리지 않고 바로 PAUSE 한다
WAIT_READY_SEC = float(os.environ.get("WAIT_READY_SEC", 30))


class Abort(Exception):
    pass


def log(msg):
    t = time.time()
    print(f"[{time.strftime('%H:%M:%S', time.localtime(t))}.{int(t * 1000) % 1000:03d}] {msg}", file=sys.stderr, flush=True)


def now_ms():
    return time.monotonic_ns() // 1_000_000


def fault_point(name):
    """장애 주입: FAULT_AT=<지점> 이면 결과 폴더에 .fault-<지점> 을 만들고, 호스트가 장애를 일으킨 뒤
    .fault-<지점>.done 을 만들 때까지 최대 5초 기다린다 (poc/demo/bin/fault)."""
    if os.environ.get("FAULT_AT") != name:
        return
    log(f"장애 주입 지점: {name}")
    p = os.path.join(RESULTS_DIR, f".fault-{name}")
    open(p, "w").close()
    for _ in range(100):
        if os.path.exists(p + ".done"):
            break
        time.sleep(0.05)
    for f in (p, p + ".done"):
        try:
            os.remove(f)
        except OSError:
            pass


def env_key(node):
    return node.upper().replace("-", "_")


def url(node):
    v = os.environ.get(f"{env_key(node)}_URL")
    if not v:
        raise Abort(f"접속 정보 {env_key(node)}_URL 이 없습니다")
    return v


def sub_name(node):
    return "mig_from_" + node.replace("-", "_")


def repl_conn(node):
    host = os.environ.get(f"{env_key(node)}_REPL_HOST", node)
    return f"host={host} port=5432 dbname=app user=replicator password={os.environ['REPL_PASSWORD']}"


def connect(node):
    return psycopg.connect(url(node), autocommit=True, prepare_threshold=None, connect_timeout=5,
                           application_name=APP_NAME)


def one(conn, query, params=None):
    row = conn.execute(query, params).fetchone()
    return row[0] if row else None


# --- PgBouncer -------------------------------------------------------------

PGB_DB_INI = os.path.join(os.environ.get("PGB_RUNTIME", "/pgb-runtime"), "databases.ini")


def pgb_target():
    with open(PGB_DB_INI) as f:
        for line in f:
            if line.startswith("app = host="):
                return line.split("host=", 1)[1].split()[0]
    return None


def pgb_set_target(node):
    with open(PGB_DB_INI, "w") as f:
        f.write(f"[databases]\napp = host={node} port=5432 dbname=app\n")


class Bouncer:
    """PgBouncer 관리 콘솔. 관리 콘솔은 simple query 프로토콜만 받으므로 libpq를 직접 쓴다."""

    def __init__(self):
        self.conn = psycopg.connect(os.environ["PGB_ADMIN_URL"], autocommit=True, connect_timeout=5)

    def cmd(self, query, timeout=None):
        pg = self.conn.pgconn
        pg.send_query(query.encode())
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            pg.consume_input()
            if not pg.is_busy():
                break
            remaining = None if deadline is None else deadline - time.monotonic()
            if remaining is not None and remaining <= 0:
                raise TimeoutError(query)
            select.select([pg.socket], [], [], remaining)
        err = None
        while (res := pg.get_result()) is not None:
            if res.status == ExecStatus.FATAL_ERROR:
                err = (res.error_message or b"").decode().strip()
        if err:
            raise Abort(f"PgBouncer {query}: {err}")

    def reopen(self):
        try:
            self.conn.close()
        except Exception:
            pass
        self.__init__()


# --- 준비 단계 ----------------------------------------------------------------

def fix_replica_identity(conn, node):
    rows = conn.execute("""
        select format('%I.%I', n.nspname, c.relname)
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where c.relkind = 'r' and n.nspname not in ('pg_catalog','information_schema')
          and c.relreplident = 'd'
          and not exists (select 1 from pg_index i where i.indrelid = c.oid and i.indisprimary)""").fetchall()
    for (t,) in rows:
        log(f"{node}: {t} 에 PK가 없어 REPLICA IDENTITY FULL 지정")
        conn.execute(f"ALTER TABLE {t} REPLICA IDENTITY FULL")


SEQ_QUERY = """select format('%I.%I', schemaname, sequencename), last_value
               from pg_sequences where last_value is not null"""


def read_sequences(conn):
    return dict(conn.execute(SEQ_QUERY).fetchall())


def set_sequences(conn, values):
    with conn.transaction():
        for name, v in values.items():
            conn.execute("select setval(%s::regclass, %s, true)", (name, v))


def sync_window(conn, sub):
    # ALTER SYSTEM 은 트랜잭션 안에서 실행할 수 없으므로 한 문장씩 보낸다
    conn.execute("ALTER SYSTEM SET synchronous_commit = 'local'")
    conn.execute(sql.SQL("ALTER SYSTEM SET synchronous_standby_names = {}").format(sql.Literal(sub)))
    conn.execute("select pg_reload_conf()")


def sync_window_off(conn):
    conn.execute("ALTER SYSTEM RESET synchronous_standby_names")
    conn.execute("ALTER SYSTEM RESET synchronous_commit")
    conn.execute("select pg_reload_conf()")


# --- 검증 --------------------------------------------------------------------

def begin_snapshot(conn):
    """REPEATABLE READ 트랜잭션을 열고 첫 쿼리로 스냅샷을 고정한다. 시퀀스 값도 함께 읽는다."""
    conn.execute("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
    return read_sequences(conn)


def table_summary(conn, mode):
    tables = [r[0] for r in conn.execute(
        "select tablename from pg_tables where schemaname = 'public' order by 1").fetchall()]
    out = {}
    for t in tables:
        if mode == "checksum":
            q = sql.SQL("select count(*), coalesce(sum(('x' || substr(md5(t::text), 1, 16))::bit(64)::bigint::numeric), 0)"
                        " from public.{} t").format(sql.Identifier(t))
        else:
            has_id = one(conn, """select count(*) from pg_index i join pg_attribute a
                                  on a.attrelid = i.indrelid and a.attnum = i.indkey[0]
                                  where i.indrelid = %s::regclass and i.indisprimary and a.attname = 'id'""",
                         (f"public.{t}",))
            if not has_id:
                continue
            q = sql.SQL("select coalesce(max(id), 0) from public.{}").format(sql.Identifier(t))
        out[t] = [str(v) for v in conn.execute(q).fetchone()]
    return out


# --- 본체 --------------------------------------------------------------------

def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    frm, to = sys.argv[1], sys.argv[2]
    fwd, rev = sub_name(frm), sub_name(to)

    if pgb_target() != frm:
        raise Abort(f"PgBouncer 대상이 {frm} 이 아닙니다 (현재: {pgb_target()})")

    # A6: 접속은 모두 여기서 연다. *_v 는 스냅샷 검증용
    src, tgt, src_v, tgt_v = connect(frm), connect(to), connect(frm), connect(to)
    pgb = Bouncer()
    pool = ThreadPoolExecutor(max_workers=2)

    if one(tgt, "select count(*) from pg_subscription where subname = %s and subenabled", (fwd,)) != 1:
        raise Abort(f"{to} 에 활성 구독 {fwd} 가 없습니다")
    lag = one(src, """select coalesce(max(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)), -1)::bigint
                      from pg_replication_slots where slot_name = %s""", (fwd,))
    if not 0 <= lag <= LAG_OK_BYTES:
        raise Abort(f"지연량이 큽니다 ({lag} bytes). 03_wait_sync.sh 를 먼저 실행하세요")

    verify_mode = VERIFY_AFTER
    if verify_mode == "auto":
        verify_mode = "checksum" if one(src, "select pg_database_size(current_database())") <= 100 << 20 else "light"

    ts = {}
    st = dict(prepared=False, sync_on=False, paused=False, fwd_disabled=False, rev_enabled=False,
              retargeted=False, switched=False)
    seq_fixed = 0
    try:
        # 0a. 역방향 구독 준비 (A1)
        ts["prepare"] = now_ms()
        log(f"0a. 역방향 복제 준비 ({to} → {frm}, 꺼진 상태)")
        fix_replica_identity(tgt, to)
        tgt.execute("GRANT USAGE ON SCHEMA mig TO replicator")
        tgt.execute("GRANT SELECT ON ALL TABLES IN SCHEMA public, mig TO replicator")
        if not one(tgt, "select count(*) from pg_publication where pubname = 'mig_pub'"):
            tgt.execute("CREATE PUBLICATION mig_pub FOR ALL TABLES")
        if one(src, "select count(*) from pg_subscription where subname = %s", (rev,)):
            raise Abort(f"{frm} 에 이미 구독 {rev} 가 있습니다")
        st["prepared"] = True
        src.execute(sql.SQL("CREATE SUBSCRIPTION {} CONNECTION {} PUBLICATION mig_pub "
                            "WITH (copy_data = false, origin = none, enabled = false)")
                    .format(sql.Identifier(rev), sql.Literal(repl_conn(to))))

        # 0b. 시퀀스 미리 올리기 (A4)
        ts["seq_prebump"] = now_ms()
        bumped = {k: v + SEQ_HEADROOM for k, v in read_sequences(src).items()}
        log(f"0b. 시퀀스 {len(bumped)}개를 원본 값 + {SEQ_HEADROOM} 으로 미리 설정")
        set_sequences(tgt, bumped)

        # 0c. 동기 복제 창 (A3)
        ts["sync_on"] = now_ms()
        log(f"0c. 동기 복제 창 열기 (synchronous_standby_names = {fwd}, 앱은 synchronous_commit = local)")
        st["sync_on"] = True
        sync_window(src, fwd)
        deadline = time.monotonic() + 5
        while one(src, "select sync_state from pg_stat_replication where application_name = %s", (fwd,)) != "sync":
            if time.monotonic() > deadline:
                raise Abort(f"5초 안에 {fwd} 가 동기 대기 상태가 되지 않았습니다")
            time.sleep(0.01)
        src.execute("SET synchronous_commit = remote_apply")

        # 0d. 전환 가능 시점 대기 (E1)
        ts["wait_ready"] = now_ms()
        ready_checks = 0
        if WAIT_READY_SEC > 0:
            log(f"0d. 전환 가능 시점 대기 (최대 {WAIT_READY_SEC:g}초)")
            last_log = 0
            while True:
                ok, reasons = is_ready(sample(src, fwd))
                ready_checks += 1
                if ok:
                    break
                if now_ms() - last_log >= 1000:   # 20ms 마다 확인하지만 기록은 1초에 한 번
                    log("   대기: " + ", ".join(reasons))
                    last_log = now_ms()
                if now_ms() - ts["wait_ready"] > WAIT_READY_SEC * 1000:
                    raise Abort(f"{WAIT_READY_SEC:g}초 안에 전환 가능 시점이 오지 않았습니다 ({', '.join(reasons)}). PAUSE 하지 않고 중단합니다")
                time.sleep(0.02)
            if ready_checks > 1:
                log(f"   준비됨 ({now_ms() - ts['wait_ready']}ms 기다림)")

        # 1. PAUSE
        ts["start"] = now_ms()
        log(f"1. PAUSE (최대 {PAUSE_TIMEOUT_SEC:g}초)")
        st["paused"] = True
        try:
            pgb.cmd("PAUSE app;", timeout=PAUSE_TIMEOUT_SEC)
        except TimeoutError:
            for (line,) in src.execute("""
                    select format('  긴 트랜잭션: pid %s, %s, %s', pid, now() - xact_start, left(query, 60))
                    from pg_stat_activity where usename = 'app' and xact_start < now() - interval '1 second'
                    order by xact_start limit 5""").fetchall():
                log(line)
            pgb.reopen()   # PAUSE 응답을 기다리던 연결은 버리고 새로 연다
            raise Abort(f"PAUSE가 {PAUSE_TIMEOUT_SEC:g}초 안에 끝나지 않았습니다 (긴 트랜잭션). 전환을 중단합니다")
        ts["paused"] = now_ms()
        fault_point("paused")

        # 2. marker 커밋: remote_apply 라서 대상에 반영된 뒤에 돌아온다.
        #    대상이 응답하지 않으면 타이머가 취소를 보낸다. 취소되면 커밋은 로컬에만 된 채로 돌아오므로 대상에서 다시 확인한다
        log("2. marker 커밋 (remote_apply)")
        timer = threading.Timer(MARKER_TIMEOUT_MS / 1000, src.cancel)
        timer.start()
        try:
            marker = one(src, "INSERT INTO mig.marker DEFAULT VALUES RETURNING id")
        finally:
            timer.cancel()
        while not one(tgt, "select count(*) from mig.marker where id = %s", (marker,)):
            if now_ms() - ts["paused"] > MARKER_TIMEOUT_MS:
                raise Abort(f"marker가 {MARKER_TIMEOUT_MS}ms 안에 도착하지 않았습니다")
            time.sleep(0.002)
        # remote_apply 는 marker 에만 쓴다. 이 세션의 다음 커밋(역방향 ENABLE)까지 기다리게 두면,
        # 4단계에서 정방향 구독(= 동기 대기 대상)이 꺼지는 순간 그 커밋이 영원히 돌아오지 않는다
        src.execute("SET synchronous_commit = local")
        ts["marker"] = now_ms()

        # 3. 스냅샷 고정 + 시퀀스 확인 (병렬)
        log("3. 스냅샷 고정, 시퀀스 확인")
        f_src, f_tgt = pool.submit(begin_snapshot, src_v), pool.submit(begin_snapshot, tgt_v)
        src_seq, tgt_seq = f_src.result(), f_tgt.result()
        behind = {k: v for k, v in src_seq.items() if tgt_seq.get(k, -1) < v}
        if behind:
            log(f"   미리 올린 값을 넘은 시퀀스 {len(behind)}개를 원본 값으로 맞춤")
            set_sequences(tgt, behind)
            seq_fixed = len(behind)
        ts["snapshot"] = now_ms()

        # 4. 구독 전환 (병렬)
        log(f"4. 정방향 {fwd} DISABLE, 역방향 {rev} ENABLE")
        f1 = pool.submit(tgt.execute, sql.SQL("ALTER SUBSCRIPTION {} DISABLE").format(sql.Identifier(fwd)))
        f2 = pool.submit(src.execute, sql.SQL("ALTER SUBSCRIPTION {} ENABLE").format(sql.Identifier(rev)))
        try:
            f1.result()
        finally:
            st["fwd_disabled"] = True
        try:
            f2.result()
        finally:
            st["rev_enabled"] = True
        ts["subs"] = now_ms()
        fault_point("forward-disabled")

        # 5. 대상 변경 → RESUME
        #    4단계 뒤로는 대상에 보내는 SQL이 없으므로, 그사이 대상이 죽어도 모르고 죽은 DB로 트래픽을 보낼 수 있다.
        #    대상 변경 직전에 한 번 더 확인한다 (1ms 안팎). 실패하면 아래 except 가 원래 DB로 되돌린다
        log("5. 대상 생존 확인 → PgBouncer 대상 변경 → RESUME")
        try:
            one(tgt, "select 1")
        except psycopg.OperationalError as e:
            raise Abort(f"{to} 에 접속할 수 없습니다 ({str(e).splitlines()[0]}). 전환을 중단합니다")
        st["retargeted"] = True
        pgb_set_target(to)
        pgb.cmd("RELOAD;")
        pgb.cmd("RECONNECT app;")
        pgb.cmd("RESUME app;")
        st["switched"] = True
        ts["resumed"] = now_ms()
        pause_ms = ts["resumed"] - ts["start"]
        log(f"   쓰기 중단 {pause_ms}ms")
    except BaseException:
        rollback_attempt(st, frm, to, fwd, rev, src, tgt, pgb, ts)
        for c in (src_v, tgt_v):
            try:
                c.rollback() if not c.autocommit else c.execute("ROLLBACK")
            except Exception:
                pass
        raise

    # 6. 정리 (PAUSE 밖)
    sync_window_off(src)
    st["sync_on"] = False
    log(f"6. 동기 복제 창 닫음, 정방향 구독 {fwd} 삭제")
    for i in range(50):
        try:
            tgt.execute(sql.SQL("DROP SUBSCRIPTION {}").format(sql.Identifier(fwd)))
            break
        except psycopg.errors.ObjectInUse:
            time.sleep(0.2)   # 원본 쪽 walsender 가 아직 종료 중
        except psycopg.OperationalError as e:
            log(f"주의: {to} 접속이 끊겨 {fwd} 를 삭제하지 못했습니다 ({str(e).splitlines()[0]})")
            break
    else:
        log(f"주의: {fwd} 를 삭제하지 못했습니다. 나중에 직접 삭제하세요")
    ts["dropped"] = now_ms()

    # 7. 전환 순간의 스냅샷으로 검증 (A5)
    verify_ok = None
    if verify_mode != "none":
        log(f"7. 전환 순간 스냅샷 비교 ({verify_mode})")
        f_src, f_tgt = pool.submit(table_summary, src_v, verify_mode), pool.submit(table_summary, tgt_v, verify_mode)
        a, b = f_src.result(), f_tgt.result()
        verify_ok = a == b
        if not verify_ok:
            for t in sorted(set(a) | set(b)):
                if a.get(t) != b.get(t):
                    log(f"   불일치 {t}: {frm}={a.get(t)} {to}={b.get(t)}")
            log(f"ERROR: 전환 순간 두 DB가 다릅니다. 06_rollback.sh {frm} 로 되돌리는 것을 검토하세요")
        else:
            log(f"   일치 ({len(a)}개 테이블)")
    for c in (src_v, tgt_v):
        c.execute("ROLLBACK")
    ts["verified"] = now_ms()

    result = {
        "from": frm, "to": to, "impl": "fast",
        "write_pause_ms": pause_ms,
        "verify_in_pause": "none",
        "verify_after": verify_mode, "verify_ok": verify_ok,
        "seq_fixed_in_pause": seq_fixed,
        "wait_ready_sec": WAIT_READY_SEC,
        "steps_ms": {
            "prepare_reverse (PAUSE 전)": ts["seq_prebump"] - ts["prepare"],
            "seq_prebump (PAUSE 전)": ts["sync_on"] - ts["seq_prebump"],
            "sync_window_on (PAUSE 전)": ts["wait_ready"] - ts["sync_on"],
            "wait_ready (PAUSE 전)": ts["start"] - ts["wait_ready"],
            "pause_wait_inflight": ts["paused"] - ts["start"],
            "marker_wait": ts["marker"] - ts["paused"],
            "snapshot_seq_check": ts["snapshot"] - ts["marker"],
            "switch_subscriptions": ts["subs"] - ts["snapshot"],
            "retarget_resume": ts["resumed"] - ts["subs"],
            "drop_forward (RESUME 후)": ts["dropped"] - ts["resumed"],
            "verify (RESUME 후)": ts["verified"] - ts["dropped"],
        },
    }
    path = os.path.join(RESULTS_DIR, f"switchover-{time.strftime('%Y%m%dT%H%M%S')}-{frm}-to-{to}.json")
    with open(path, "w") as f:
        json.dump(result, f, indent=2, ensure_ascii=False)
    log(f"완료: {frm} → {to}, 쓰기 중단 {pause_ms}ms ({path})")
    print(json.dumps(result, indent=2, ensure_ascii=False))
    sys.exit(0 if verify_ok is not False else 3)


def rollback_attempt(st, frm, to, fwd, rev, src, tgt, pgb, ts):
    """전환 도중 실패: 구독을 원래대로 되돌린 뒤 원래 DB로 RESUME 한다."""
    def safe(desc, fn):
        try:
            fn()
        except Exception as e:
            log(f"   {desc} 실패: {e}")

    if st["switched"]:
        return
    try:
        src.cancel()
    except Exception:
        pass
    safe("synchronous_commit = local", lambda: src.execute("SET synchronous_commit = local"))
    if st["rev_enabled"]:
        log(f"중단: 역방향 구독 {rev} DISABLE")
        safe("DISABLE", lambda: src.execute(sql.SQL("ALTER SUBSCRIPTION {} DISABLE").format(sql.Identifier(rev))))
    if st["fwd_disabled"]:
        log(f"중단: 정방향 구독 {fwd} 다시 ENABLE")
        safe("ENABLE", lambda: tgt.execute(sql.SQL("ALTER SUBSCRIPTION {} ENABLE").format(sql.Identifier(fwd))))
    if st["retargeted"]:
        log(f"중단: PgBouncer 대상을 {frm} 으로 되돌림")
        pgb_set_target(frm)
        safe("RELOAD", lambda: (pgb.cmd("RELOAD;"), pgb.cmd("RECONNECT app;")))
    if st["paused"]:
        safe("RESUME", lambda: pgb.cmd("RESUME app;"))
        log(f"중단: PgBouncer RESUME, 대상은 계속 {frm} (쓰기 중단 {now_ms() - ts['start']}ms)")
    if st["sync_on"]:
        log("중단: 동기 복제 창 닫음")
        safe("동기 복제 창 해제", lambda: sync_window_off(connect(frm)))
    if st["prepared"]:
        log(f"중단: 미리 만든 역방향 구독 {rev} 삭제")

        def drop_rev():
            c = connect(frm)
            try:
                c.execute(sql.SQL("DROP SUBSCRIPTION IF EXISTS {}").format(sql.Identifier(rev)))
            except psycopg.OperationalError:
                # {to} 가 죽어서 원격 슬롯을 지울 수 없으면 슬롯 연결을 끊고 구독만 지운다
                c.execute(sql.SQL("ALTER SUBSCRIPTION {} DISABLE").format(sql.Identifier(rev)))
                c.execute(sql.SQL("ALTER SUBSCRIPTION {} SET (slot_name = NONE)").format(sql.Identifier(rev)))
                c.execute(sql.SQL("DROP SUBSCRIPTION IF EXISTS {}").format(sql.Identifier(rev)))
                log(f"주의: {to} 에 남은 복제 슬롯 {rev} 는 {to} 가 돌아오면 지워야 합니다")
        safe("DROP", drop_rev)
    if st["fwd_disabled"] and not tgt_alive(tgt):
        log(f"주의: {to} 에 접속할 수 없어 정방향 구독을 켜지 못했습니다. {to} 가 돌아오면 ALTER SUBSCRIPTION {fwd} ENABLE")


def tgt_alive(conn):
    try:
        conn.execute("select 1")
        return True
    except Exception:
        return False


if __name__ == "__main__":
    try:
        main()
    except Abort as e:
        log(f"ERROR: {e}")
        sys.exit(1)
