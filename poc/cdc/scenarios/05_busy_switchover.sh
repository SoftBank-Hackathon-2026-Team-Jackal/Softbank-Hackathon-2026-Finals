#!/usr/bin/env bash
# 시나리오 6: 배치가 도는 순간에 전환을 시작하면 (notes/cdc-short-switchover.md E1)
#   배치가 상품 행 전체를 BATCH_SEC 동안 잠그고 있는 동안 전환을 시작한다. 앱의 주문 트랜잭션은 그 잠금에 막혀 길어진다.
#   1회차 pg-a → pg-b: WAIT_READY_SEC=0 (전환 가능 시점을 기다리지 않음) → PAUSE 가 막힌 트랜잭션을 기다리느라 쓰기 중단이 길어짐
#   2회차 pg-b → pg-a: 기본값 (ready 조건을 만족할 때까지 기다린 뒤 PAUSE) → 쓰기 중단이 평소 수준
# 결과: results/busy-switchover.json
source "$(dirname "$0")/common.sh"
export SCALE="${SCALE:-1}" RATE="${RATE:-100}"
BATCH_SEC="${BATCH_SEC:-4}"
[[ "$SWITCHOVER" == fast ]] || { echo "SWITCHOVER=fast 에서만 의미가 있습니다"; exit 1; }

# 현재 주 DB에서 상품 행을 모두 잠근 채 BATCH_SEC 동안 유지하는 배치 (앱과 같은 id 순서로 잠금)
batch() {
  docker compose --profile tools run --rm -T --entrypoint bash toolbox -c \
    "psql \"\$$(echo "$1" | tr 'a-z-' 'A-Z_')_URL\" -XAtq -c 'BEGIN' \
       -c 'SELECT count(*) FROM (SELECT id FROM products ORDER BY id FOR UPDATE) t' \
       -c 'SELECT pg_sleep($BATCH_SEC)' -c 'COMMIT'" >/dev/null
}
# 배치가 잠금을 잡을 때까지 기다린다
wait_batch() {
  for _ in $(seq 100); do
    docker compose --profile tools run --rm -T --entrypoint bash toolbox -c \
      "psql \"\$$(echo "$1" | tr 'a-z-' 'A-Z_')_URL\" -XAtq -c \"select count(*) from pg_stat_activity where query like 'SELECT pg_sleep%'\"" \
      | grep -q '^1$' && return 0
    sleep 0.1
  done
  return 1
}

fresh_start
start_load 3
step "스키마 복사";   $T 01_copy_schema.sh pg-a pg-b
step "복제 시작";     $T 02_start_replication.sh pg-a pg-b
step "동기화 대기";   $T 03_wait_sync.sh pg-a pg-b
sleep 5

step "1회차: 배치 중 전환, 시점 대기 없음 (WAIT_READY_SEC=0)"
batch pg-a & bp=$!
wait_batch pg-a
$T readiness.py pg-a 0.5
WAIT_READY_SEC=0 VERIFY_AFTER=light $T $SW pg-a pg-b >/dev/null
wait $bp
sleep 10

step "2회차: 배치 중 전환, 시점 대기 (기본값)"
batch pg-b & bp=$!
wait_batch pg-b
$T readiness.py pg-b 0.5
VERIFY_AFTER=light $T 06_rollback.sh pg-a >/dev/null
wait $bp
sleep 5

step "부하 중지";     stop_load
step "검증"
$T 03_wait_sync.sh pg-a pg-b 60 2>/dev/null
lost_a="$($T 07_check_lost.sh pg-a | python3 -c 'import json,sys; print(json.load(sys.stdin)["lost"])')"
if $T 04_compare.sh pg-a pg-b; then same=true; else same=false; fi

python3 - "$same" "$lost_a" <<'PY' | tee results/busy-switchover.json
import glob, json, sys
sw = [json.load(open(f)) for f in sorted(glob.glob("results/switchover-*.json"))]
load = json.load(open("results/loadgen-summary.json"))
print(json.dumps({
  "runs": [{"wait_ready_sec": s["wait_ready_sec"], "from": s["from"], "to": s["to"],
            "write_pause_ms": s["write_pause_ms"], "steps_ms": s["steps_ms"]} for s in sw],
  "loadgen": load, "checksum_match": sys.argv[1] == "true", "lost": int(sys.argv[2]),
}, indent=2, ensure_ascii=False))
PY
