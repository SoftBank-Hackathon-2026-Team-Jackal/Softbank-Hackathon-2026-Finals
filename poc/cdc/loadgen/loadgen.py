"""PgBouncer를 거쳐 계속 쓰기를 넣고, 커밋에 성공한 주문 ID와 지연 시간을 기록한다.

- committed_ids.txt: 커밋 성공이 확인된 orders.id (유실 검증용)
- loadgen-timeline.jsonl: 1초마다 성공 수, 에러 수, 최대 지연
- loadgen-summary.json: 종료(SIGTERM) 시 요약
"""

import json
import os
import random
import signal
import threading
import time

import psycopg

URL = os.environ["DATABASE_URL"]
RATE = float(os.environ.get("RATE", "50"))
WORKERS = int(os.environ.get("WORKERS", "4"))
OUT = os.environ.get("OUT_DIR", "/results")

stop = threading.Event()
lock = threading.Lock()
stats = {"ok": 0, "err": 0, "latencies_ms": [], "errors": {}}
window = {"ok": 0, "err": 0, "max_ms": 0.0}
ids_file = open(os.path.join(OUT, "committed_ids.txt"), "w", buffering=1)


def connect():
    # 트랜잭션 모드 PgBouncer에서는 서버 측 prepared statement를 쓰지 않는다
    return psycopg.connect(URL, autocommit=False, prepare_threshold=None, connect_timeout=5)


def one_op(conn, n):
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO orders(customer_id, amount) VALUES (%s, %s) RETURNING id",
            (random.randint(1, 1000), round(random.random() * 1000, 2)),
        )
        oid = cur.fetchone()[0]
        if n % 5 == 0:
            cur.execute(
                "UPDATE orders SET status = 'paid', updated_at = now() WHERE id = %s",
                (random.randint(1, oid),),
            )
        cur.execute("INSERT INTO audit_log(actor, action) VALUES ('loadgen', %s)", (f"order-{oid}",))
        if n % 100 == 0:
            # 보존 기간 정리: PK 없는 테이블의 DELETE는 REPLICA IDENTITY가 없으면 publication 생성 후 실패한다
            cur.execute("DELETE FROM audit_log WHERE actor = 'loadgen' AND ts < now() - interval '30 seconds'")
    conn.commit()
    return oid


def worker(wid):
    interval = WORKERS / RATE
    conn, n = None, 0
    next_at = time.monotonic()
    while not stop.is_set():
        next_at += interval
        n += 1
        t0 = time.monotonic()
        try:
            if conn is None or conn.closed:
                conn = connect()
            oid = one_op(conn, n)
            ms = (time.monotonic() - t0) * 1000
            with lock:
                stats["ok"] += 1
                stats["latencies_ms"].append(ms)
                window["ok"] += 1
                window["max_ms"] = max(window["max_ms"], ms)
                ids_file.write(f"{oid}\n")
        except Exception as e:  # noqa: BLE001 - 모든 실패를 에러로 센다
            key = f"{type(e).__name__}: {str(e).splitlines()[0][:120]}"
            with lock:
                stats["err"] += 1
                window["err"] += 1
                stats["errors"][key] = stats["errors"].get(key, 0) + 1
            print(f"[w{wid}] error: {key}", flush=True)
            try:
                if conn is not None:
                    conn.close()
            except Exception:  # noqa: BLE001
                pass
            conn = None
            time.sleep(0.2)
        delay = next_at - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        else:
            next_at = time.monotonic()


def ticker():
    with open(os.path.join(OUT, "loadgen-timeline.jsonl"), "w", buffering=1) as f:
        while not stop.wait(1.0):
            with lock:
                row = {"t": round(time.time(), 3), **window}
                window.update(ok=0, err=0, max_ms=0.0)
            f.write(json.dumps(row) + "\n")
            print(f"ok={row['ok']:3d}/s err={row['err']} max={row['max_ms']:.0f}ms", flush=True)


def summary():
    lat = sorted(stats["latencies_ms"])
    pick = lambda q: round(lat[min(len(lat) - 1, int(len(lat) * q))], 1) if lat else None  # noqa: E731
    out = {
        "ok": stats["ok"],
        "errors": stats["err"],
        "error_kinds": stats["errors"],
        "latency_ms": {"p50": pick(0.5), "p99": pick(0.99), "max": round(lat[-1], 1) if lat else None},
    }
    with open(os.path.join(OUT, "loadgen-summary.json"), "w") as f:
        json.dump(out, f, indent=2)
    print(json.dumps(out), flush=True)


signal.signal(signal.SIGTERM, lambda *_: stop.set())
signal.signal(signal.SIGINT, lambda *_: stop.set())
threads = [threading.Thread(target=worker, args=(i,)) for i in range(WORKERS)]
threads.append(threading.Thread(target=ticker))
for t in threads:
    t.start()
for t in threads:
    t.join()
ids_file.close()
summary()
