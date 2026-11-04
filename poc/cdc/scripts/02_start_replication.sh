#!/usr/bin/env bash
# 사용법: 02_start_replication.sh <원본> <대상>
# copy_data = true: 구독이 슬롯을 만든 시점의 스냅샷으로 초기 복사를 하고, 이어서 그 뒤의 변경(CDC)을 적용한다.
source "$(dirname "$0")/lib.sh"
src="${1:?원본}" dst="${2:?대상}"
sub="$(sub_name "$src")"

if [[ "${SKIP_RI_FIX:-0}" != "1" ]]; then
  fix_replica_identity "$src"
fi

# 초기 복사는 replicator 권한으로 SELECT한다. 초기화 이후 앱이 만든 테이블(예: 데모 앱의 chat_messages)은
# 권한이 없어서 tablesync worker가 permission denied로 무한 재시도하므로, 복제 직전에 다시 부여한다.
q "$src" "GRANT SELECT ON ALL TABLES IN SCHEMA public TO replicator" >/dev/null

q "$src" "select 1 from pg_publication where pubname = 'mig_pub'" | grep -q 1 \
  || q "$src" "CREATE PUBLICATION mig_pub FOR ALL TABLES" >/dev/null

log "구독 생성: $dst ← $src ($sub, copy_data = true)"
q "$dst" "CREATE SUBSCRIPTION $sub CONNECTION '$(repl_conn "$src")' PUBLICATION mig_pub
          WITH (copy_data = true, origin = none)" >/dev/null
log "복제 시작. 진행 상황은 03_wait_sync.sh $src $dst"
