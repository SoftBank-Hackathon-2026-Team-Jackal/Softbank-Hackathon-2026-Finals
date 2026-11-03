-- 이전 대상 앱의 스키마 (예선 앱을 단순화한 형태)
SET ROLE app;

CREATE TABLE customers (
  id         bigserial PRIMARY KEY,
  name       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE orders (
  id          bigserial PRIMARY KEY,
  customer_id bigint NOT NULL REFERENCES customers(id),
  amount      numeric(12,2) NOT NULL,
  status      text NOT NULL DEFAULT 'created',
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX orders_customer_idx ON orders(customer_id);

-- PK가 없는 테이블: 사전 점검이 잡아내야 하는 대상
CREATE TABLE audit_log (
  ts      timestamptz NOT NULL DEFAULT now(),
  actor   text NOT NULL,
  action  text NOT NULL
);

RESET ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO replicator;
