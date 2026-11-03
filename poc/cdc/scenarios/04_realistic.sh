#!/usr/bin/env bash
# 시나리오 5: 운영에 가까운 이전
#   - 기존 데이터 SCALE(기본 100 ≈ 5GB), 쇼핑몰 트래픽 RATE(기본 초당 200 트랜잭션)
#   - 초기 복사 중에 대형 배치(상품 전체 가격 인상, 한 트랜잭션)를 실행
#   - 동기화 후 STEADY_SEC 동안 실시간 지연 관찰 → 전환 → HOLD_SEC 동안 새 DB로 운영 → 롤백
#   - 부하를 멈춘 뒤 전체 체크섬과 유실 검사
# 결과: results/realistic-report.json
source "$(dirname "$0")/common.sh"
export SCALE="${SCALE:-100}" RATE="${RATE:-200}" WORKERS="${WORKERS:-16}"
STEADY_SEC="${STEADY_SEC:-60}" HOLD_SEC="${HOLD_SEC:-60}"

t_seed0=$(date +%s); fresh_start; t_seed1=$(date +%s)
step "사전 점검";  $T 00_precheck.sh pg-a

if [[ -n "${REMOTE_NODES:-}" ]] && command -v iperf3 >/dev/null; then
  step "WireGuard 구간 대역폭 (iperf3, 10초)"
  iperf3 -c 10.100.0.2 -t 10 -J > results/iperf3.json 2>/dev/null || echo "iperf3 서버가 없어 건너뜀"
fi

start_load 10
step "스키마 복사";   $T 01_copy_schema.sh pg-a pg-b
step "복제 시작";     t_copy0=$(date +%s); $T 02_start_replication.sh pg-a pg-b

step "초기 복사 중 대형 배치: 상품 가격 5% 인상 (한 트랜잭션, 앱과 같은 id 순서로 잠금)"
( sleep 15; docker compose exec -T pg-a psql -U postgres -d app -XAtq -c \
    "\\timing on" -c "UPDATE products SET price = round(price * 1.05, 2) WHERE id IN (SELECT id FROM products ORDER BY id FOR UPDATE)" > results/batch.txt 2>&1 ) &
batch_pid=$!

step "동기화 대기"
POLL_SEC=5 $T 03_wait_sync.sh pg-a pg-b 7200
t_copy1=$(date +%s)
wait $batch_pid || true

step "실시간 동기화 ${STEADY_SEC}초 관찰"
for ((i = 0; i < STEADY_SEC / 5; i++)); do POLL_SEC=1 $T 03_wait_sync.sh pg-a pg-b 5 2>&1 | tail -1; sleep 4; done

step "전환 pg-a → pg-b";   $T 05_switchover.sh pg-a pg-b >/dev/null
step "새 DB로 ${HOLD_SEC}초 운영"; sleep "$HOLD_SEC"
step "롤백 pg-b → pg-a";   $T 06_rollback.sh pg-a >/dev/null
sleep 10
step "부하 중지";           stop_load

step "검증 (전체 체크섬, 시간이 걸립니다)"
$T 03_wait_sync.sh pg-a pg-b 600 2>/dev/null
t_verify0=$(date +%s)
if $T 04_compare.sh pg-a pg-b; then same=true; else same=false; fi
t_verify1=$(date +%s)
lost_a="$($T 07_check_lost.sh pg-a | python3 -c 'import json,sys; print(json.load(sys.stdin)["lost"])')"
lost_b="$($T 07_check_lost.sh pg-b | python3 -c 'import json,sys; print(json.load(sys.stdin)["lost"])')"
size_a="$(docker compose exec -T pg-a psql -U postgres -d app -XAtq -c "select pg_database_size('app')")"

python3 - "$same" "$lost_a" "$lost_b" "$size_a" "${t_seed0}" "${t_seed1}" "${t_copy0}" "${t_copy1}" "${t_verify0}" "${t_verify1}" <<'PY' | tee results/realistic-report.json
import glob, json, os, sys
same, lost_a, lost_b, size = sys.argv[1] == "true", int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
seed0, seed1, copy0, copy1, v0, v1 = map(int, sys.argv[5:11])
rep = [json.loads(l) for l in open("results/replication-mig_from_pg_a.jsonl")]
load = json.load(open("results/loadgen-summary.json"))
sw = [json.load(open(f)) for f in sorted(glob.glob("results/switchover-*.json"))]
copy_sec = copy1 - copy0
steady = [r for r in rep if r["phase"] == "streaming"]
iperf = None
if os.path.exists("results/iperf3.json"):
    try:
        iperf = round(json.load(open("results/iperf3.json"))["end"]["sum_received"]["bits_per_second"] / 1e6)
    except Exception:
        pass
out = {
  "scale": int(os.environ.get("SCALE", 0)), "rate_target": int(os.environ.get("RATE", 0)),
  "db_size_mb": round(size / 2**20),
  "seed_sec": seed1 - seed0,
  "initial_sync_sec": copy_sec,
  "initial_sync_mb_per_sec": round(size / 2**20 / max(copy_sec, 1), 1),
  "max_retained_wal_mb": round(max(r["retained_bytes"] for r in rep) / 2**20, 1),
  "steady_lag_bytes_max": max((r["lag_bytes"] for r in steady), default=None),
  "wireguard_mbps": iperf,
  "switchovers": [{k: s[k] for k in ("from", "to", "write_pause_ms", "verify_in_pause", "steps_ms")} for s in sw],
  "loadgen": load,
  "full_checksum_sec": v1 - v0, "checksum_match": same, "lost": {"pg-a": lost_a, "pg-b": lost_b},
}
out["pass"] = (same and lost_a == 0 and lost_b == 0 and load["errors"] == 0
               and all(s["write_pause_ms"] <= 2000 for s in sw))
print(json.dumps(out, indent=2, ensure_ascii=False))
PY
