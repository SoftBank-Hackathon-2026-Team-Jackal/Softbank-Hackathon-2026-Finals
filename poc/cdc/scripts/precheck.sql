-- 이전 전 사전 점검. 결과는 Map(db.postgres attrs)과 db-postgres Skill의 위험 판단 입력이 된다
\pset footer off
\echo '== 서버'
select version() as version,
       current_setting('wal_level') as wal_level,
       current_setting('max_replication_slots') as max_replication_slots,
       (select count(*) from pg_replication_slots) as slots_in_use,
       pg_size_pretty(pg_database_size(current_database())) as db_size;

\echo '== PK가 없는 테이블 (REPLICA IDENTITY FULL 필요)'
select format('%I.%I', n.nspname, c.relname) as table_name,
       case c.relreplident when 'd' then 'default' when 'f' then 'full' when 'i' then 'index' else 'nothing' end as replica_identity,
       c.reltuples::bigint as approx_rows
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where c.relkind = 'r' and n.nspname not in ('pg_catalog','information_schema')
  and not exists (select 1 from pg_index i where i.indrelid = c.oid and i.indisprimary);

\echo '== 시퀀스 (전환 시 값 동기화 대상)'
select schemaname || '.' || sequencename as sequence, last_value from pg_sequences;

\echo '== 복제되지 않는 객체'
select 'large_objects' as item, count(*)::text as value from pg_largeobject_metadata
union all
select 'unlogged_tables', count(*)::text from pg_class where relkind = 'r' and relpersistence = 'u'
union all
select 'extensions', coalesce(string_agg(extname, ', '), '') from pg_extension where extname <> 'plpgsql';

\echo '== 테이블 크기 (초기 복사량)'
select format('%I.%I', schemaname, relname) as table_name, n_live_tup as approx_rows,
       pg_size_pretty(pg_total_relation_size(relid)) as total_size
from pg_stat_user_tables order by pg_total_relation_size(relid) desc limit 10;

\echo '== REPLICA IDENTITY FULL 대상 중 쓸 만한 인덱스가 없는 테이블 (대상에서 UPDATE/DELETE마다 전체 스캔)'
select format('%I.%I', n.nspname, c.relname) as table_name
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where c.relkind = 'r' and n.nspname not in ('pg_catalog','information_schema')
  and not exists (select 1 from pg_index i where i.indrelid = c.oid and i.indisprimary)
  and not exists (select 1 from pg_index i where i.indrelid = c.oid and i.indisvalid and not i.indisexclusion and i.indpred is null);
