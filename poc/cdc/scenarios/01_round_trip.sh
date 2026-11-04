#!/usr/bin/env bash
# 시나리오 1+2: 쓰기를 계속 넣으면서 pg-a → pg-b 전환, 다시 pg-b → pg-a 롤백
# 성공 기준: 전환마다 쓰기 중단 2초 이하, 부하 생성기 에러 0, 유실 0, 체크섬 일치
source "$(dirname "$0")/common.sh"

fresh_start
step "사전 점검";            $T 00_precheck.sh pg-a
start_load 3
step "스키마 복사";           $T 01_copy_schema.sh pg-a pg-b
step "복제 시작";             $T 02_start_replication.sh pg-a pg-b
step "동기화 대기";           $T 03_wait_sync.sh pg-a pg-b
sleep 5
step "전환 pg-a → pg-b";      $T $SW pg-a pg-b >/dev/null
sleep 10
step "롤백 pg-b → pg-a";      $T 06_rollback.sh pg-a >/dev/null
sleep 5
step "부하 중지";             stop_load
step "검증"
$T 03_wait_sync.sh pg-a pg-b 60 2>/dev/null
lost_a="$($T 07_check_lost.sh pg-a | python3 -c 'import json,sys; print(json.load(sys.stdin)["lost"])')"
lost_b="$($T 07_check_lost.sh pg-b | python3 -c 'import json,sys; print(json.load(sys.stdin)["lost"])')"
if $T 04_compare.sh pg-a pg-b; then same=true; else same=false; fi

errors="$(json_get results/loadgen-summary.json '["errors"]')"
pauses=($(for f in results/switchover-*.json; do json_get "$f" '["write_pause_ms"]'; done))
max_pause=$(printf '%s\n' "${pauses[@]}" | sort -n | tail -1)

pass=true
check() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; pass=false; fi; }
step "결과"
check "쓰기 중단 2초 이하 (전환별: ${pauses[*]} ms)" "(( max_pause <= 2000 ))"
check "부하 생성기 에러 0 (실제: $errors)"            "(( errors == 0 ))"
check "유실 0 (pg-a: $lost_a, pg-b: $lost_b)"          "(( lost_a == 0 && lost_b == 0 ))"
check "체크섬 일치"                                     "$same"

python3 - "$pass" <<'PY' > results/round-trip.json
import glob, json, sys
print(json.dumps({
  "pass": sys.argv[1] == "true",
  "loadgen": json.load(open("results/loadgen-summary.json")),
  "switchovers": [json.load(open(f)) for f in sorted(glob.glob("results/switchover-*.json"))],
}, indent=2, ensure_ascii=False))
PY
$pass
