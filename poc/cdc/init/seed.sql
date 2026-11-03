-- 초기 복사가 눈에 보이도록 넣는 기존 데이터
INSERT INTO customers(name) SELECT 'customer-' || g FROM generate_series(1, 1000) g;
INSERT INTO orders(customer_id, amount, status)
SELECT 1 + (g % 1000), round((random() * 1000)::numeric, 2), 'paid'
FROM generate_series(1, 50000) g;
INSERT INTO audit_log(actor, action) SELECT 'seed', 'import-' || g FROM generate_series(1, 5000) g;
