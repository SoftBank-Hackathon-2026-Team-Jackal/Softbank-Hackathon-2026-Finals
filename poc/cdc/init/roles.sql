-- 두 서버에 공통으로 만드는 역할 (pg_dump의 OWNER/GRANT 구문이 대상에서도 성공하도록)
CREATE ROLE app LOGIN PASSWORD 'app';
CREATE ROLE replicator LOGIN REPLICATION PASSWORD 'replicator';
GRANT CREATE ON DATABASE app TO app;
GRANT CREATE ON SCHEMA public TO app;
