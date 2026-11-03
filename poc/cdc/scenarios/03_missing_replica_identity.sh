#!/usr/bin/env bash
# 시나리오 4: 사전 점검을 건너뛰면 무엇이 깨지는가
# PK 없는 audit_log에 REPLICA IDENTITY를 지정하지 않고 publication을 만들면,
# 복제 대상이 아니라 "원본 앱"의 DELETE가 실패한다. 사전 점검이 필요한 이유를 보여 준다.
source "$(dirname "$0")/common.sh"

fresh_start
start_load 2
$T 01_copy_schema.sh pg-a pg-b
step "REPLICA IDENTITY 지정 없이 복제 시작"
SKIP_RI_FIX=1 docker compose --profile tools run --rm -T -e SKIP_RI_FIX=1 toolbox scripts/02_start_replication.sh pg-a pg-b
sleep 8
stop_load
errors="$(json_get results/loadgen-summary.json '["errors"]')"
if (( errors > 0 )); then
  echo "예상대로 원본 앱 에러 ${errors}건 발생 (위 error_kinds 참고). 00_precheck.sh 가 잡아내야 하는 위험입니다."
else
  echo "에러가 발생하지 않았습니다. 시나리오 가정을 다시 확인해야 합니다." && exit 1
fi
