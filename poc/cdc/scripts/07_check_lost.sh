#!/usr/bin/env bash
# 사용법: 07_check_lost.sh <노드>
# 부하 생성기가 커밋 성공을 확인한 주문 ID가 모두 <노드>에 있는지 확인한다.
source "$(dirname "$0")/lib.sh"
db="${1:?노드}"
ids="$RESULTS_DIR/committed_ids.txt"
[[ -s "$ids" ]] || die "$ids 가 비어 있습니다"
read -r total missing <<<"$(psql "$(url "$db")" -XAtq -v ON_ERROR_STOP=1 -F ' ' <<SQL
CREATE TEMP TABLE committed(id bigint);
\copy committed from '$ids'
select count(*), count(*) filter (where o.id is null) from committed c left join orders o using (id);
SQL
)"
log "$db: 커밋된 쓰기 ${total}건 중 유실 ${missing}건"
echo "{\"node\":\"$db\",\"committed\":$total,\"lost\":$missing}"
(( missing == 0 ))
