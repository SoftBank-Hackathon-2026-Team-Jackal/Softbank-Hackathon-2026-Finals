# bin/ 스크립트 공통 설정. source 해서 쓴다
set -euo pipefail
cd "$(dirname "$0")/.."
# PoC의 bin/tool은 poc/cdc Compose만 보므로 데모 컨테이너를 orphan으로 경고한다
export COMPOSE_IGNORE_ORPHANS=true
# 물리 초기 복사(pg_createsubscriber)는 PostgreSQL 17 이상이 필요하다. 논리 복사도 17에서 그대로 동작한다
export PG_IMAGE="${PG_IMAGE:-postgres:17}"
# 전환 스크립트: fast(05_switchover_fast.py, 기본) | classic(05_switchover.sh, PAUSE 안에서 체크섬 검증)
export SWITCHOVER="${SWITCHOVER:-fast}"
if [[ "$SWITCHOVER" == classic ]]; then SW=05_switchover.sh; else SW=05_switchover_fast.py; fi
T=../cdc/bin/tool
step() { printf '\n\033[1m[%s] ▶ %s\033[0m\n' "$(date +%T)" "$*"; }
