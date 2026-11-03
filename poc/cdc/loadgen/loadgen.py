"""PgBouncer를 거쳐 쇼핑몰 형태의 트래픽을 계속 넣고, 커밋 성공 기록과 지연 시간을 남긴다.

작업 비율 (트랜잭션 기준):
  60% 주문 생성   주문 + 상품 1~5개 + 재고 차감(인기 상품에 몰림) + 결제 + 감사 로그
  25% 상태 변경   최근 주문을 shipped/delivered 로
  10% 조회        고객의 최근 주문 내역 (조인)
   4% 취소        주문 취소 + 결제 환불 + 재고 복구
   1% 로그 정리   오래된 audit_log 최대 500건 DELETE (PK 없는 테이블)

출력 (OUT_DIR):
  committed_ids.txt       커밋이 확인된 새 주문 ID (유실 검증용)
  loadgen-timeline.jsonl  1초마다 성공 수, 에러 수, 최대 지연
  loadgen-summary.json    종료(SIGTERM) 시 요약
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
WORKERS = int(os.environ.get("WORKERS", "8"))
OUT = os.environ.get("OUT_DIR", "/results")

stop = threading.Event()
lock = threading.Lock()
stats = {"ok": 0, "err": 0, "latencies_ms": [], "errors": {}, "by_op": {}}
window = {"ok": 0, "err": 0, "max_ms": 0.0}
ids_file = open(os.path.join(OUT, "committed_ids.txt"), "w", buffering=1)
bounds = {}


def connect():
    # 트랜잭션 모드 PgBouncer에서는 서버 측 prepared statement를 쓰지 않는다
    return psycopg.connect(URL, autocommit=False, prepare_threshold=None, connect_timeout=5)


def load_bounds():
    while not stop.is_set():
        try:
            with connect() as c:
                r = c.execute("select (select max(id) from customers), (select max(id) from products),"
                              " (select max(id) from orders)").fetchone()
                bounds.update(nc=r[0], np=r[1], no=r[2])
                return
        except Exception as e:  # noqa: BLE001
            print(f"waiting for db: {e}", flush=True)
            time.sleep(1)


def pick_product():
    # 다섯 번에 한 번은 인기 상품 100개: 같은 행에 쓰기가 몰리는 상황
    return random.randint(1, 100) if random.random() < 0.2 else random.randint(1, bounds["np"])


def recent_order(cur):
    hi = bounds["no"]
    cur.execute("select max(id) from orders")
    hi = cur.fetchone()[0] or hi
    return random.randint(max(1, hi - 20000), hi)


def op_place_order(cur):
    cid = random.randint(1, bounds["nc"])
    cur.execute("INSERT INTO orders(customer_id, status) VALUES (%s, 'created') RETURNING id", (cid,))
    oid = cur.fetchone()[0]
    items = sorted({pick_product() for _ in range(random.randint(1, 5))})  # 정렬: 교착 방지
    total = 0.0
    for pid in items:
        qty = random.randint(1, 3)
        cur.execute("UPDATE products SET stock = stock - %s WHERE id = %s RETURNING price", (qty, pid))
        price = float(cur.fetchone()[0])
        cur.execute("INSERT INTO order_items(order_id, product_id, qty, unit_price) VALUES (%s, %s, %s, %s)",
                    (oid, pid, qty, price))
        total += price * qty
    cur.execute("UPDATE orders SET total = %s, status = 'paid', updated_at = now() WHERE id = %s", (round(total, 2), oid))
    cur.execute("INSERT INTO payments(order_id, method, amount, status) VALUES (%s, %s, %s, 'captured')",
                (oid, random.choice(["card", "card", "bank", "point"]), round(total, 2)))
    cur.execute("INSERT INTO audit_log(actor, action, detail) VALUES (%s, 'order', %s)",
                (f"customer:{cid}", json.dumps({"order": oid, "items": len(items)})))
    return oid


def op_update_status(cur):
    oid = recent_order(cur)
    cur.execute("UPDATE orders SET status = %s, updated_at = now() WHERE id = %s AND status <> 'cancelled'",
                (random.choice(["shipped", "delivered"]), oid))


def op_read(cur):
    cur.execute("""select o.id, o.status, o.total, count(i.id)
                   from orders o join order_items i on i.order_id = o.id
                   where o.customer_id = %s group by o.id order by o.id desc limit 10""",
                (random.randint(1, bounds["nc"]),))
    cur.fetchall()


def op_cancel(cur):
    oid = recent_order(cur)
    cur.execute("UPDATE orders SET status = 'cancelled', updated_at = now() WHERE id = %s AND status <> 'cancelled' RETURNING id", (oid,))
    if cur.fetchone() is None:
        return
    cur.execute("UPDATE payments SET status = 'refunded' WHERE order_id = %s", (oid,))
    cur.execute("SELECT product_id, qty FROM order_items WHERE order_id = %s ORDER BY product_id", (oid,))
    for pid, qty in cur.fetchall():
        cur.execute("UPDATE products SET stock = stock + %s WHERE id = %s", (qty, pid))


def op_purge_audit(cur):
    cur.execute("""DELETE FROM audit_log WHERE ctid IN (
                     SELECT ctid FROM audit_log WHERE ts < now() - interval '60 days' ORDER BY ts LIMIT 500)""")


OPS = [(0.60, "place_order", op_place_order), (0.25, "update_status", op_update_status),
       (0.10, "read", op_read), (0.04, "cancel", op_cancel), (0.01, "purge_audit", op_purge_audit)]


def choose():
    r, acc = random.random(), 0.0
    for p, name, fn in OPS:
        acc += p
        if r < acc:
            return name, fn
    return OPS[0][1], OPS[0][2]


def worker(wid):
    interval = WORKERS / RATE
    conn = None
    next_at = time.monotonic()
    while not stop.is_set():
        next_at += interval
        name, fn = choose()
        t0 = time.monotonic()
        try:
            if conn is None or conn.closed:
                conn = connect()
            with conn.cursor() as cur:
                oid = fn(cur)
            conn.commit()
            ms = (time.monotonic() - t0) * 1000
            with lock:
                stats["ok"] += 1
                stats["latencies_ms"].append(ms)
                stats["by_op"][name] = stats["by_op"].get(name, 0) + 1
                window["ok"] += 1
                window["max_ms"] = max(window["max_ms"], ms)
                if name == "place_order":
                    ids_file.write(f"{oid}\n")
        except Exception as e:  # noqa: BLE001 - 모든 실패를 에러로 센다
            key = f"{name}: {type(e).__name__}: {str(e).splitlines()[0][:120]}"
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
        "by_op": stats["by_op"],
        "latency_ms": {"p50": pick(0.5), "p99": pick(0.99), "max": round(lat[-1], 1) if lat else None},
    }
    with open(os.path.join(OUT, "loadgen-summary.json"), "w") as f:
        json.dump(out, f, indent=2)
    print(json.dumps(out), flush=True)


signal.signal(signal.SIGTERM, lambda *_: stop.set())
signal.signal(signal.SIGINT, lambda *_: stop.set())
load_bounds()
threads = [threading.Thread(target=worker, args=(i,)) for i in range(WORKERS)]
threads.append(threading.Thread(target=ticker))
for t in threads:
    t.start()
for t in threads:
    t.join()
ids_file.close()
summary()
