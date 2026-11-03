-- 이전 대상 앱의 스키마: 쇼핑몰 (고객, 상품, 주문, 주문 상품, 결제, 감사 로그)
SET ROLE app;

CREATE TABLE customers (
  id         bigserial PRIMARY KEY,
  email      text NOT NULL UNIQUE,
  name       text NOT NULL,
  address    jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE products (
  id     bigserial PRIMARY KEY,
  sku    text NOT NULL UNIQUE,
  name   text NOT NULL,
  price  numeric(12,2) NOT NULL,
  stock  integer NOT NULL,
  attrs  jsonb NOT NULL DEFAULT '{}'
);

CREATE TABLE orders (
  id          bigserial PRIMARY KEY,
  customer_id bigint NOT NULL REFERENCES customers(id),
  status      text NOT NULL DEFAULT 'created',
  total       numeric(12,2) NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
-- 고객별 최근 주문 조회용. customer_id 단일 인덱스만 있으면 플래너가 PK 역순 스캔을 골라 수백만 행을 읽는다
CREATE INDEX orders_customer_idx ON orders(customer_id, id DESC);
CREATE INDEX orders_created_idx ON orders(created_at);

CREATE TABLE order_items (
  id         bigserial PRIMARY KEY,
  order_id   bigint NOT NULL REFERENCES orders(id),
  product_id bigint NOT NULL REFERENCES products(id),
  qty        integer NOT NULL,
  unit_price numeric(12,2) NOT NULL
);
CREATE INDEX order_items_order_idx ON order_items(order_id);

CREATE TABLE payments (
  id       bigserial PRIMARY KEY,
  order_id bigint NOT NULL REFERENCES orders(id),
  method   text NOT NULL,
  amount   numeric(12,2) NOT NULL,
  status   text NOT NULL,
  paid_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX payments_order_idx ON payments(order_id);

-- PK가 없는 테이블: 사전 점검이 잡아내야 하는 대상. 보존 기간 정리용 인덱스만 있다
CREATE TABLE audit_log (
  ts      timestamptz NOT NULL DEFAULT now(),
  actor   text NOT NULL,
  action  text NOT NULL,
  detail  jsonb
);
CREATE INDEX audit_log_ts_idx ON audit_log(ts);

RESET ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO replicator;
