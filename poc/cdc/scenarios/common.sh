# 시나리오 공통: 호스트에서 실행한다
set -euo pipefail
cd "$(dirname "$0")/.."
T=bin/tool
step() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }

fresh_start() {
  step "환경 초기화"
  docker compose --profile load --profile tools down -v --remove-orphans >/dev/null 2>&1 || true
  rm -f results/*.json results/*.jsonl results/*.txt
  docker compose up -d --build --wait >/dev/null
  # 2단계(클라우드): 원격 노드는 down -v 로 지워지지 않으므로 SQL로 초기화한다
  for n in ${REMOTE_NODES:-}; do
    docker compose --profile tools run --rm -T -e RESET_OK=yes toolbox scripts/reset_node.sh "$n"
  done
}

start_load() {
  step "부하 생성 시작 (초당 ${RATE:-50}건)"
  RATE="${RATE:-50}" docker compose --profile load up -d --build loadgen >/dev/null
  sleep "${1:-3}"
}

stop_load() {
  docker compose --profile load stop loadgen >/dev/null
  cat results/loadgen-summary.json
}

json_get() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))$2)" "$1"; }
