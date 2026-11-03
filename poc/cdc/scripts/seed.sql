-- 기존 데이터 생성. :scale = 1 이면 약 60MB, 100 이면 약 5GB
--   customers 1만×s, products 1천×s, orders 5만×s, order_items 15만×s, payments 5만×s, audit_log 10만×s
\set ON_ERROR_STOP 1
\timing on
-- 대량 생성 중에는 FK 트리거를 건너뛴다 (값은 아래에서 범위 안으로 만든다)
SET session_replication_role = replica;
SET synchronous_commit = off;

\set nc 10000 * :scale
\set np 1000 * :scale
\set no 50000 * :scale

INSERT INTO customers(email, name, address, created_at)
SELECT 'user' || g || '@example.com', 'customer ' || g,
       jsonb_build_object('city', (array['Seoul','Busan','Tokyo','Osaka','Fukuoka'])[1 + g % 5],
                          'zip', lpad((g % 100000)::text, 5, '0'), 'line1', md5(g::text)),
       now() - (g % 1000) * interval '1 day'
FROM generate_series(1::bigint, :nc) g;

INSERT INTO products(sku, name, price, stock, attrs)
SELECT 'SKU-' || lpad(g::text, 8, '0'), 'product ' || g, round((5 + random() * 495)::numeric, 2), 10000000,
       jsonb_build_object('color', (array['red','blue','black','white'])[1 + g % 4], 'size', 1 + g % 5,
                          'tags', jsonb_build_array('t' || g % 17, 't' || g % 23))
FROM generate_series(1::bigint, :np) g;

INSERT INTO orders(customer_id, status, total, created_at, updated_at)
SELECT 1 + (g * 7919) % :nc,
       (array['delivered','delivered','delivered','shipped','paid','cancelled'])[1 + g % 6],
       round((10 + random() * 990)::numeric, 2),
       now() - ((:no - g) * interval '1 minute') / greatest(:scale, 1),
       now() - ((:no - g) * interval '1 minute') / greatest(:scale, 1)
FROM generate_series(1::bigint, :no) g;

-- 주문마다 상품 3개. 다섯 번에 한 번은 인기 상품 100개 중 하나
INSERT INTO order_items(order_id, product_id, qty, unit_price)
SELECT 1 + (g - 1) / 3,
       CASE WHEN g % 5 = 0 THEN 1 + g % 100 ELSE 1 + (g * 31) % :np END,
       1 + g % 3, round((5 + random() * 495)::numeric, 2)
FROM generate_series(1::bigint, 3 * :no) g;

INSERT INTO payments(order_id, method, amount, status, paid_at)
SELECT g, (array['card','card','card','bank','point'])[1 + g % 5], round((10 + random() * 990)::numeric, 2),
       CASE WHEN g % 6 = 5 THEN 'refunded' ELSE 'captured' END, now() - ((:no - g) * interval '1 minute') / greatest(:scale, 1)
FROM generate_series(1::bigint, :no) g;

INSERT INTO audit_log(ts, actor, action, detail)
SELECT now() - interval '90 days' + (g * interval '90 days') / (100000 * :scale), 'system',
       (array['login','view','order','pay','ship'])[1 + g % 5],
       jsonb_build_object('ip', '10.0.' || g % 256 || '.' || g % 199, 'ua', 'app/' || g % 7)
FROM generate_series(1::bigint, 100000 * :scale) g;

RESET session_replication_role;
VACUUM ANALYZE;
