#!/usr/bin/env bash
# env-a VM에서 명령을 실행한다 (SSM, SSH 포트 없음). 작업 디렉터리는 /opt/cdc
#   cloud/run.sh sync                         최신 PoC 파일을 S3에서 다시 받기 (먼저 terraform apply)
#   cloud/run.sh 'scenarios/01_round_trip.sh'
#   cloud/run.sh 'docker compose ps'
set -euo pipefail
cd "$(dirname "$0")"
export AWS_PROFILE="${AWS_PROFILE:-prod}" AWS_REGION=ap-northeast-2

iid="$(terraform output -raw env_a_instance_id)"
if [[ "${1:-}" == sync ]]; then
  cmd="/snap/bin/aws s3 cp $(terraform output -raw bundle_url) /tmp/poc-cdc.zip && unzip -oq /tmp/poc-cdc.zip -d /opt/cdc && chmod +x /opt/cdc/bin/* /opt/cdc/scripts/*.sh /opt/cdc/scenarios/*.sh && echo synced"
else
  cmd="${1:?명령}"
fi

# AWS-RunShellScript 는 sh 로 실행하므로, 명령을 파일로 쓴 뒤 bash 로 실행한다.
# 실행 중인 명령이 있을 때 다른 명령을 보내도 서로의 파일을 덮어쓰지 않도록 파일 이름을 명령마다 다르게 한다
body="$(python3 -c '
import json, sys, uuid
script = "set -o pipefail\ncd /opt/cdc\nexport REMOTE_NODES=pg-b\n" + sys.argv[1] + "\n"
f = "/tmp/cdc-cmd-" + uuid.uuid4().hex + ".sh"
print(json.dumps({"commands": ["cat > " + f + " <<'"'"'CDC_EOF'"'"'\n" + script + "CDC_EOF", "bash " + f + "; rc=$?; rm -f " + f + "; exit $rc"],
                  "executionTimeout": ["1800"]}))' "$cmd")"
cid="$(aws ssm send-command --instance-ids "$iid" --document-name AWS-RunShellScript \
        --parameters "$body" --timeout-seconds 600 --query Command.CommandId --output text)"

while :; do
  sleep 3
  status="$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$iid" --query Status --output text 2>/dev/null || echo Pending)"
  [[ "$status" =~ ^(Pending|InProgress|Delayed)$ ]] || break
done
aws ssm get-command-invocation --command-id "$cid" --instance-id "$iid" \
  --query '[StandardOutputContent,StandardErrorContent]' --output text
[[ "$status" == Success ]]
