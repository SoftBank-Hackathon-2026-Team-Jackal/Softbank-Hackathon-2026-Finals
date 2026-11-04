#!/usr/bin/env bash
# 사용법: 06_rollback.sh <되돌아갈 DB>
# 전환 후 살아 있는 역방향 복제를 이용해 같은 절차를 반대로 실행한다.
source "$(dirname "$0")/lib.sh"
back="${1:?되돌아갈 DB}"
cur="$(pgb_target)"
[[ "$cur" != "$back" ]] || die "이미 $back 이 주 DB입니다"
"$(dirname "$0")/03_wait_sync.sh" "$cur" "$back" 60
if [[ "${SWITCHOVER:-fast}" == classic ]]; then
  exec "$(dirname "$0")/05_switchover.sh" "$cur" "$back"
fi
exec "$(dirname "$0")/05_switchover_fast.py" "$cur" "$back"
