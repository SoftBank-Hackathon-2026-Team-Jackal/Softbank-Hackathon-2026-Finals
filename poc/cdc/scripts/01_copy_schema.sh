#!/usr/bin/env bash
# 사용법: 01_copy_schema.sh <원본> <대상>
# 논리 복제는 DDL을 옮기지 않으므로 스키마만 먼저 복사한다. 전환 확인용 marker 테이블도 함께 만든다.
source "$(dirname "$0")/lib.sh"
src="${1:?원본}" dst="${2:?대상}"

q "$src" "
  CREATE SCHEMA IF NOT EXISTS mig;
  CREATE TABLE IF NOT EXISTS mig.marker (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), created_at timestamptz NOT NULL DEFAULT now());
  GRANT USAGE ON SCHEMA mig TO replicator;
  GRANT SELECT ON mig.marker TO replicator;" >/dev/null

[[ "$(q "$dst" "select count(*) from pg_tables where schemaname = 'public'")" == "0" ]] \
  || die "$dst 에 이미 테이블이 있습니다. 빈 DB에만 스키마를 복사합니다"

log "스키마 복사: $src → $dst"
pg_dump --schema-only --no-publications --no-subscriptions "$(url "$src")" \
  | psql "$(url "$dst")" -Xq -v ON_ERROR_STOP=1 >/dev/null
log "완료: $(q "$dst" "select count(*) from pg_tables where schemaname in ('public','mig')")개 테이블"
