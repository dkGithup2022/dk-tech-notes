-- Case G-2 — Case G 의 정상 매칭 버전
-- 취지:
--   Case G-1 (HAVING SUM(oi.qty) > 50) 은 데이터 분포 (oi 15K / product 10K, qty 1~5)
--   에서 매칭 product 가 0 인 희소 케이스. BEFORE 가 "결론 = 0 rows" 를 도출하는 데
--   조차 DEPENDENT SUBQUERY 의 폭발로 5분 이상이 걸리는 현상을 보여줬다.
--
--   Case G-2 는 HAVING 조건을 > 5 로 낮춰 실제 결과가 있는 정상 시나리오에서
--   같은 BEFORE/AFTER 패턴을 측정한다. 1단계 스냅샷이 의미 있는 리스트를 반환하고
--   2단계가 그 스냅샷을 그대로 사용한다.
--
-- BEFORE: 외곽 GROUP BY SUM 재계산 + 내부 HAVING SUM > 5 서브쿼리 (중첩)
-- AFTER 1단계: SUM 스냅샷 획득 (HAVING > 5)
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
    HAVING SUM(oi2.qty) > 5
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
    HAVING SUM(oi2.qty) > 5
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
HAVING SUM(oi.qty) > 5;

EXPLAIN ANALYZE
SELECT oi.product_id, SUM(oi.qty) AS total_qty
FROM order_items oi
JOIN orders o ON o.id = oi.order_id
WHERE o.order_date >= '2024-01-01'
GROUP BY oi.product_id
HAVING SUM(oi.qty) > 5;

-- 관찰용: 1단계 결과 상위 20개 (애플리케이션이 수령할 데이터 형태)
SELECT oi.product_id, SUM(oi.qty) AS total_qty
FROM order_items oi
JOIN orders o ON o.id = oi.order_id
WHERE o.order_date >= '2024-01-01'
GROUP BY oi.product_id
HAVING SUM(oi.qty) > 5
ORDER BY total_qty DESC
LIMIT 20;

-- ========== AFTER 2단계: VALUES 스냅샷 주입 ==========
-- 위 1단계 상위 20개 결과를 VALUES 로 주입해 재계산 없이 카테고리·상품 상세 조립
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
