#!/usr/bin/env bash
# 시나리오 7: 초기 복사를 물리 복사로 (notes/cdc-short-switchover.md B1, PostgreSQL 17 이상)
#   논리 복제의 초기 복사(copy_data = true)는 대상이 행을 하나씩 넣으며 인덱스를 갱신해서 느리다.
#   대신 pg_basebackup 으로 블록을 그대로 복사하고 pg_createsubscriber 로 논리 구독자로 바꾼 뒤,
#   기존과 같은 CDC, 전환, 롤백을 실행한다. 쓰기는 복사 내내 계속 들어온다.
# 비교 기준: 같은 SCALE 로 04_realistic.sh 를 돌렸을 때의 initial_sync_sec
# 결과: results/physical-report.json
source "$(dirname "$0")/common.sh"
export PG_IMAGE="${PG_IMAGE:-postgres:17}" SCALE="${SCALE:-10}" RATE="${RATE:-200}"
ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }   # macOS date 는 %3N 을 모른다
[[ -z "${REMOTE_NODES:-}" ]] || { echo "로컬 전용입니다 (원격 pg-b 의 데이터 디렉터리를 다룰 수 없음)"; exit 1; }

fresh_start
start_load 5
step "원본 준비 (marker 테이블, REPLICA IDENTITY)"; $T 02p_prepare_physical.sh pg-a

step "물리 복사 (pg-b 중지 → pg_basebackup → pg_createsubscriber)"
t0=$(ms)
docker compose stop pg-b >/dev/null
docker compose --profile clone run --rm -T pg-b-clone
docker compose up -d --wait pg-b >/dev/null
t1=$(ms)

step "구독 설정을 기존 스크립트와 맞춤 (origin = none, replicator 계정)"
docker compose --profile tools run --rm -T --entrypoint bash toolbox -c '
  source scripts/lib.sh
  q pg-b "ALTER SUBSCRIPTION mig_from_pg_a SET (origin = none)" >/dev/null
  q pg-b "ALTER SUBSCRIPTION mig_from_pg_a CONNECTION '"'"'$(repl_conn pg-a)'"'"'" >/dev/null
  q pg-b "select subname, subenabled, suborigin from pg_subscription"'

step "동기화 대기"; $T 03_wait_sync.sh pg-a pg-b 600
t2=$(ms)
sleep 10

step "전환 pg-a → pg-b";  VERIFY_AFTER=light $T $SW pg-a pg-b >/dev/null
sleep 10
step "롤백 pg-b → pg-a";  VERIFY_AFTER=light $T 06_rollback.sh pg-a >/dev/null
sleep 5
step "부하 중지";          stop_load

step "검증"
$T 03_wait_sync.sh pg-a pg-b 120 2>/dev/null
if $T 04_compare.sh pg-a pg-b; then same=true; else same=false; fi
lost_a="$($T 07_check_lost.sh pg-a | python3 -c 'import json,sys; print(json.load(sys.stdin)["lost"])')"
lost_b="$($T 07_check_lost.sh pg-b | python3 -c 'import json,sys; print(json.load(sys.stdin)["lost"])')"

python3 - "$same" "$lost_a" "$lost_b" "$t0" "$t1" "$t2" <<'PY' | tee results/physical-report.json
import glob, json, os, sys
same, lost_a, lost_b = sys.argv[1] == "true", int(sys.argv[2]), int(sys.argv[3])
t0, t1, t2 = map(int, sys.argv[4:7])
clone = json.load(open("results/physical-clone.json"))
load = json.load(open("results/loadgen-summary.json"))
sw = [json.load(open(f)) for f in sorted(glob.glob("results/switchover-*.json"))]
out = {
  "pg_image": os.environ["PG_IMAGE"], "scale": int(os.environ["SCALE"]), "rate_target": int(os.environ["RATE"]),
  "cluster_mb": round(clone["bytes"] / 2**20),
  "basebackup_sec": round(clone["basebackup_ms"] / 1000, 1),
  "createsubscriber_sec": round(clone["createsubscriber_ms"] / 1000, 1),
  "copy_total_sec": round((t1 - t0) / 1000, 1),          # pg-b 중지부터 다시 뜰 때까지
  "until_streaming_sec": round((t2 - t0) / 1000, 1),     # 실시간 동기화까지
  "switchovers": [{k: s.get(k) for k in ("from", "to", "write_pause_ms", "verify_ok")} for s in sw],
  "loadgen": load, "checksum_match": same, "lost": {"pg-a": lost_a, "pg-b": lost_b},
}
out["pass"] = same and lost_a == 0 and lost_b == 0 and load["errors"] == 0
print(json.dumps(out, indent=2, ensure_ascii=False))
PY
