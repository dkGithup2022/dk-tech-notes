-- Case D — 3.2 "temp 크기 줄이기 — 핵심 id 를 먼저 좁히기"
-- 상품별 리뷰 통계 + 배송 통계를 한 쿼리에서 뽑는 보고서.

USE tuning;

-- ========== BEFORE: 스칼라 서브쿼리 3개가 각 product 마다 반복 스캔 ==========
EXPLAIN
SELECT p.id, p.name,
  (SELECT COUNT(*)            FROM reviews r  WHERE r.product_id = p.id) AS review_count,
  (SELECT AVG(rating)         FROM reviews r  WHERE r.product_id = p.id) AS avg_rating,
  (SELECT COUNT(*)
     FROM shipments s
     JOIN order_items oi ON s.order_id = oi.order_id
     WHERE oi.product_id = p.id)                                         AS ship_count
FROM products p
WHERE p.category_id IN (SELECT id FROM categories WHERE parent_id = 1)
  AND p.created_at >= '2024-01-01';

-- EXPLAIN ANALYZE 로 실제 시간 관찰
EXPLAIN ANALYZE
SELECT p.id, p.name,
  (SELECT COUNT(*)            FROM reviews r  WHERE r.product_id = p.id) AS review_count,
  (SELECT AVG(rating)         FROM reviews r  WHERE r.product_id = p.id) AS avg_rating,
  (SELECT COUNT(*)
     FROM shipments s
     JOIN order_items oi ON s.order_id = oi.order_id
     WHERE oi.product_id = p.id)                                         AS ship_count
FROM products p
WHERE p.category_id IN (SELECT id FROM categories WHERE parent_id = 1)
  AND p.created_at >= '2024-01-01';

-- ========== AFTER: 핵심 id 를 CTE 로 선행 확정, 각 서브쿼리에 IN 주입 ==========
EXPLAIN
WITH target_ids AS (
  SELECT p.id FROM products p
  WHERE p.category_id IN (SELECT id FROM categories WHERE parent_id = 1)
    AND p.created_at >= '2024-01-01'
)
SELECT p.id, p.name,
       rc.review_count, rc.avg_rating,
       sc.ship_count
FROM products p
LEFT JOIN (
  SELECT product_id,
         COUNT(*)    AS review_count,
         AVG(rating) AS avg_rating
  FROM reviews
  WHERE product_id IN (SELECT id FROM target_ids)
  GROUP BY product_id
) rc ON p.id = rc.product_id
LEFT JOIN (
  SELECT oi.product_id, COUNT(*) AS ship_count
  FROM shipments s
  JOIN order_items oi ON s.order_id = oi.order_id
  WHERE oi.product_id IN (SELECT id FROM target_ids)
  GROUP BY oi.product_id
) sc ON p.id = sc.product_id
WHERE p.id IN (SELECT id FROM target_ids);

EXPLAIN ANALYZE
WITH target_ids AS (
  SELECT p.id FROM products p
  WHERE p.category_id IN (SELECT id FROM categories WHERE parent_id = 1)
    AND p.created_at >= '2024-01-01'
)
SELECT p.id, p.name,
       rc.review_count, rc.avg_rating,
       sc.ship_count
FROM products p
LEFT JOIN (
  SELECT product_id,
         COUNT(*)    AS review_count,
         AVG(rating) AS avg_rating
  FROM reviews
  WHERE product_id IN (SELECT id FROM target_ids)
  GROUP BY product_id
) rc ON p.id = rc.product_id
LEFT JOIN (
  SELECT oi.product_id, COUNT(*) AS ship_count
  FROM shipments s
  JOIN order_items oi ON s.order_id = oi.order_id
  WHERE oi.product_id IN (SELECT id FROM target_ids)
  GROUP BY oi.product_id
) sc ON p.id = sc.product_id
WHERE p.id IN (SELECT id FROM target_ids);
