#!/usr/bin/env bash
# 사용법: 02p_prepare_physical.sh <원본>
# 물리 복사(06_physical_copy.sh) 전에 원본에서 할 일. 물리 복사는 원본을 블록 그대로 옮기므로,
# 대상에 있어야 할 것(marker 테이블, REPLICA IDENTITY)을 원본에 먼저 만들어 두면 함께 복사된다.
# 01_copy_schema.sh(스키마 복사)와 02_start_replication.sh(구독 생성)는 쓰지 않는다
source "$(dirname "$0")/lib.sh"
src="${1:?원본}"
q "$src" "
  CREATE SCHEMA IF NOT EXISTS mig;
  CREATE TABLE IF NOT EXISTS mig.marker (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), created_at timestamptz NOT NULL DEFAULT now());
  GRANT USAGE ON SCHEMA mig TO replicator;
  GRANT SELECT ON ALL TABLES IN SCHEMA public, mig TO replicator;" >/dev/null
fix_replica_identity "$src"
log "$src: 물리 복사 준비 완료"
