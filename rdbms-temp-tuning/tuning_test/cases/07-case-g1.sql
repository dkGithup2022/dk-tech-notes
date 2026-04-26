-- Case G — 3.3 "temp 위의 temp 피하기" (SUM 스냅샷 + VALUES 주입 버전)
-- BEFORE: 외곽 GROUP BY SUM 재계산 + 내부 HAVING 서브쿼리 (중첩 구조)
-- AFTER 1단계: SUM 스냅샷 획득
-- AFTER 2단계: 1단계 결과를 VALUES 로 주입, 재계산 없음

USE tuning;

-- ========== BEFORE ==========
EXPLAIN
SELECT c.name AS category, p.name AS product, SUM(oi.qty) AS total_qty
FROM order_items oi
JOIN orders     o ON o.id = oi.order_id
JOIN products   p ON p.id = oi.product_id
JOIN categories c ON c.id = p.category_id
WHERE o.order_date >= '2024-01-01'
  AND oi.product_id IN (
    SELECT oi2.product_id
    FROM order_items oi2
    JOIN orders o2 ON o2.id = oi2.order_id
    WHERE o2.order_date >= '2024-01-01'
    GROUP BY oi2.product_id
    HAVING SUM(oi2.qty) > 50
  )
GROUP BY p.id
ORDER BY total_qty DESC
LIMIT 20;

EXPLAIN ANALYZE
SELECT c.name AS category, p.name AS product, SUM(oi.qty) AS total_qty
FROM order_items oi
JOIN orders     o ON o.id = oi.order_id
JOIN products   p ON p.id = oi.product_id
JOIN categories c ON c.id = p.category_id
WHERE o.order_date >= '2024-01-01'
  AND oi.product_id IN (
    SELECT oi2.product_id
    FROM order_items oi2
    JOIN orders o2 ON o2.id = oi2.order_id
    WHERE o2.order_date >= '2024-01-01'
    GROUP BY oi2.product_id
    HAVING SUM(oi2.qty) > 50
  )
GROUP BY p.id
ORDER BY total_qty DESC
LIMIT 20;

-- ========== AFTER 1단계: SUM 스냅샷 획득 ==========
EXPLAIN
SELECT oi.product_id, SUM(oi.qty) AS total_qty
FROM order_items oi
JOIN orders o ON o.id = oi.order_id
WHERE o.order_date >= '2024-01-01'
GROUP BY oi.product_id
HAVING SUM(oi.qty) > 50;

EXPLAIN ANALYZE
SELECT oi.product_id, SUM(oi.qty) AS total_qty
FROM order_items oi
JOIN orders o ON o.id = oi.order_id
WHERE o.order_date >= '2024-01-01'
GROUP BY oi.product_id
HAVING SUM(oi.qty) > 50;

-- 관찰용: 상위 20개 실제 값 확인 (애플리케이션이 수령할 데이터 형태)
SELECT oi.product_id, SUM(oi.qty) AS total_qty
FROM order_items oi
JOIN orders o ON o.id = oi.order_id
WHERE o.order_date >= '2024-01-01'
GROUP BY oi.product_id
HAVING SUM(oi.qty) > 50
ORDER BY total_qty DESC
LIMIT 20;

-- ========== AFTER 2단계: VALUES 스냅샷 주입 ==========
-- 운영에서는 1단계 결과를 애플리케이션이 받아 VALUES 리스트로 구성.
-- 관찰용으로 20개 샘플 사용.
EXPLAIN
SELECT c.name AS category, p.name AS product, snap.total_qty
FROM (VALUES
  ROW(1, 100), ROW(2, 95), ROW(3, 88), ROW(4, 82), ROW(5, 77),
  ROW(6, 73), ROW(7, 71), ROW(8, 68), ROW(9, 66), ROW(10, 64),
  ROW(11, 62), ROW(12, 60), ROW(13, 58), ROW(14, 57), ROW(15, 56),
  ROW(16, 55), ROW(17, 54), ROW(18, 53), ROW(19, 52), ROW(20, 51)
) AS snap(product_id, total_qty)
JOIN products   p ON p.id = snap.product_id
JOIN categories c ON c.id = p.category_id
ORDER BY snap.total_qty DESC
LIMIT 20;

EXPLAIN ANALYZE
SELECT c.name AS category, p.name AS product, snap.total_qty
FROM (VALUES
  ROW(1, 100), ROW(2, 95), ROW(3, 88), ROW(4, 82), ROW(5, 77),
  ROW(6, 73), ROW(7, 71), ROW(8, 68), ROW(9, 66), ROW(10, 64),
  ROW(11, 62), ROW(12, 60), ROW(13, 58), ROW(14, 57), ROW(15, 56),
  ROW(16, 55), ROW(17, 54), ROW(18, 53), ROW(19, 52), ROW(20, 51)
) AS snap(product_id, total_qty)
JOIN products   p ON p.id = snap.product_id
JOIN categories c ON c.id = p.category_id
ORDER BY snap.total_qty DESC
LIMIT 20;
