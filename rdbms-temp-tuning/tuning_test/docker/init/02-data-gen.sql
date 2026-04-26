-- 02-data-gen.sql
-- cartesian product 기반 seq 로 데이터 생성 (recursive CTE 대비 안정적).

USE tuning;

-- 공통 seq 생성 함수 대신 인라인 사용
-- t10 / t100 / t1000 / t10000 / t20000

-- ========== categories (50) ==========
INSERT INTO categories (id, parent_id, name)
WITH t10  AS (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
              UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9),
     t100 AS (SELECT a.n * 10 + b.n AS n FROM t10 a CROSS JOIN t10 b)
SELECT n + 1,
       CASE WHEN n < 10 THEN NULL ELSE 1 + (n % 10) END,
       CONCAT('Category-', n + 1)
FROM t100
WHERE n < 50;

-- ========== suppliers (100) ==========
INSERT INTO suppliers (id, name, region)
WITH t10  AS (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
              UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9),
     t100 AS (SELECT a.n * 10 + b.n AS n FROM t10 a CROSS JOIN t10 b)
SELECT n + 1,
       CONCAT('Supplier-', n + 1),
       ELT(1 + (n % 5), 'SEOUL', 'BUSAN', 'DAEGU', 'INCHEON', 'GWANGJU')
FROM t100;

-- ========== warehouses (5) ==========
INSERT INTO warehouses (id, name, city) VALUES
  (1, 'WH-Central', 'SEOUL'),
  (2, 'WH-South',   'BUSAN'),
  (3, 'WH-East',    'DAEGU'),
  (4, 'WH-West',    'INCHEON'),
  (5, 'WH-North',   'GWANGJU');

-- ========== products (10,000) ==========
INSERT INTO products (id, name, category_id, supplier_id, warehouse_id, price, created_at)
WITH t10   AS (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
               UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9),
     t100  AS (SELECT a.n * 10 + b.n AS n FROM t10 a CROSS JOIN t10 b),
     t10000 AS (SELECT a.n * 100 + b.n AS n FROM t100 a CROSS JOIN t100 b)
SELECT n + 1,
       CONCAT('Product-', n + 1),
       1 + (n % 50),
       1 + (n % 100),
       1 + (n % 5),
       ROUND(1000 + (n % 100000), 2),
       DATE_ADD('2024-01-01', INTERVAL (n % 365) DAY)
FROM t10000;

-- ========== users (2,000) ==========
INSERT INTO users (id, name, region)
WITH t10   AS (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
               UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9),
     t100  AS (SELECT a.n * 10 + b.n AS n FROM t10 a CROSS JOIN t10 b),
     t10000 AS (SELECT a.n * 100 + b.n AS n FROM t100 a CROSS JOIN t100 b)
SELECT n + 1,
       CONCAT('User-', n + 1),
       ELT(1 + (n % 5), 'SEOUL', 'BUSAN', 'DAEGU', 'INCHEON', 'GWANGJU')
FROM t10000
WHERE n < 2000;

-- ========== orders (5,000) ==========
INSERT INTO orders (id, user_id, order_date, amount)
WITH t10   AS (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
               UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9),
     t100  AS (SELECT a.n * 10 + b.n AS n FROM t10 a CROSS JOIN t10 b),
     t10000 AS (SELECT a.n * 100 + b.n AS n FROM t100 a CROSS JOIN t100 b)
SELECT n + 1,
       1 + (n % 2000),
       DATE_ADD('2024-01-01', INTERVAL (n % 730) DAY),
       ROUND(1000 + (n * 17 % 1000000), 2)
FROM t10000
WHERE n < 5000;

-- ========== order_items (15,000) ==========
INSERT INTO order_items (id, order_id, product_id, qty)
WITH t10   AS (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
               UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9),
     t100  AS (SELECT a.n * 10 + b.n AS n FROM t10 a CROSS JOIN t10 b),
     t10000 AS (SELECT a.n * 100 + b.n AS n FROM t100 a CROSS JOIN t100 b),
     t20000 AS (SELECT n FROM t10000 UNION ALL SELECT n + 10000 FROM t10000)
SELECT n + 1,
       1 + (n % 5000),
       1 + (n % 10000),
       1 + (n % 5)
FROM t20000
WHERE n < 15000;

-- ========== shipments (10,000) ==========
-- status 분포: PAID 는 없고, PENDING 10%, SHIPPED 30%, DELIVERED 50%, RETURNED 5%, LOST 5%
INSERT INTO shipments (id, order_id, status, shipped_at, delivered_at)
WITH t10   AS (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
               UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9),
     t100  AS (SELECT a.n * 10 + b.n AS n FROM t10 a CROSS JOIN t10 b),
     t10000 AS (SELECT a.n * 100 + b.n AS n FROM t100 a CROSS JOIN t100 b)
SELECT n + 1,
       1 + (n % 5000),
       CASE
         WHEN n % 100 < 10 THEN 'PENDING'
         WHEN n % 100 < 40 THEN 'SHIPPED'
         WHEN n % 100 < 90 THEN 'DELIVERED'
         WHEN n % 100 < 95 THEN 'RETURNED'
         ELSE 'LOST'
       END,
       CASE
         WHEN n % 100 < 10 THEN NULL
         ELSE DATE_ADD('2024-01-01', INTERVAL (n % 730) DAY)
       END,
       CASE
         WHEN n % 100 < 40 THEN NULL
         WHEN n % 100 < 90 THEN DATE_ADD('2024-01-01', INTERVAL ((n % 730) + 3 + (n % 12)) DAY)
         ELSE NULL
       END
FROM t10000;

-- ========== reviews (20,000) ==========
INSERT INTO reviews (id, product_id, user_id, rating, created_at)
WITH t10   AS (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
               UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9),
     t100  AS (SELECT a.n * 10 + b.n AS n FROM t10 a CROSS JOIN t10 b),
     t10000 AS (SELECT a.n * 100 + b.n AS n FROM t100 a CROSS JOIN t100 b),
     t20000 AS (SELECT n FROM t10000 UNION ALL SELECT n + 10000 FROM t10000)
SELECT n + 1,
       1 + (n % 10000),
       1 + (n % 2000),
       1 + (n % 5),
       DATE_ADD('2024-01-01', INTERVAL (n % 700) DAY)
FROM t20000;

-- 검증용 요약
SELECT 'categories'  AS table_name, COUNT(*) AS rows_count FROM categories
UNION ALL SELECT 'suppliers',   COUNT(*) FROM suppliers
UNION ALL SELECT 'warehouses',  COUNT(*) FROM warehouses
UNION ALL SELECT 'products',    COUNT(*) FROM products
UNION ALL SELECT 'users',       COUNT(*) FROM users
UNION ALL SELECT 'orders',      COUNT(*) FROM orders
UNION ALL SELECT 'order_items', COUNT(*) FROM order_items
UNION ALL SELECT 'shipments',   COUNT(*) FROM shipments
UNION ALL SELECT 'reviews',     COUNT(*) FROM reviews;
