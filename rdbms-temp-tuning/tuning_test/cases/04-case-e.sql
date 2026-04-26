-- Case E — 3.3 "temp 위의 temp 피하기 — 쿼리를 2단계로 분리"
-- 배송 지연 평균이 큰 카테고리 Top-10 랭킹.

USE tuning;

-- ========== BEFORE: 중첩 derived + 중첩 IN 서브쿼리 ==========
-- 외곽 derived 한 층 + 안쪽 IN 서브쿼리의 HAVING aggregate → temp 위에 temp
EXPLAIN
SELECT rank_t.category_id, rank_t.delay_count, rank_t.rk
FROM (
  SELECT c.id AS category_id,
         COUNT(*) AS delay_count,
         RANK() OVER (ORDER BY COUNT(*) DESC) AS rk
  FROM categories c
  JOIN products p      ON p.category_id = c.id
  JOIN order_items oi  ON oi.product_id = p.id
  JOIN shipments s     ON s.order_id = oi.order_id
  WHERE s.order_id IN (
    SELECT order_id
    FROM shipments
    WHERE status = 'DELIVERED'
      AND shipped_at IS NOT NULL AND delivered_at IS NOT NULL
    GROUP BY order_id
    HAVING AVG(DATEDIFF(delivered_at, shipped_at)) > 7
  )
  GROUP BY c.id
) AS rank_t
WHERE rank_t.rk <= 10;

EXPLAIN ANALYZE
SELECT rank_t.category_id, rank_t.delay_count, rank_t.rk
FROM (
  SELECT c.id AS category_id,
         COUNT(*) AS delay_count,
         RANK() OVER (ORDER BY COUNT(*) DESC) AS rk
  FROM categories c
  JOIN products p      ON p.category_id = c.id
  JOIN order_items oi  ON oi.product_id = p.id
  JOIN shipments s     ON s.order_id = oi.order_id
  WHERE s.order_id IN (
    SELECT order_id
    FROM shipments
    WHERE status = 'DELIVERED'
      AND shipped_at IS NOT NULL AND delivered_at IS NOT NULL
    GROUP BY order_id
    HAVING AVG(DATEDIFF(delivered_at, shipped_at)) > 7
  )
  GROUP BY c.id
) AS rank_t
WHERE rank_t.rk <= 10;

-- ========== AFTER 1단계: 안쪽 temp 블록을 미리 실행 ==========
-- 애플리케이션이 결과(shipment id 리스트)를 받아 보유
SELECT order_id
FROM shipments
WHERE status = 'DELIVERED'
  AND shipped_at IS NOT NULL AND delivered_at IS NOT NULL
GROUP BY order_id
HAVING AVG(DATEDIFF(delivered_at, shipped_at)) > 7
LIMIT 20;  -- 관찰용 상위 20만 확인

-- EXPLAIN 도 분리해서 관찰
EXPLAIN
SELECT order_id
FROM shipments
WHERE status = 'DELIVERED'
  AND shipped_at IS NOT NULL AND delivered_at IS NOT NULL
GROUP BY order_id
HAVING AVG(DATEDIFF(delivered_at, shipped_at)) > 7;

-- ========== AFTER 2단계: 고정 IN 리스트로 바깥 쿼리 실행 ==========
-- 실 운영에서는 1단계 결과를 애플리케이션이 받아 IN 절을 생성.
-- 여기서는 관찰용으로 작은 고정 집합 ('1,2,3,...,200') 사용.
EXPLAIN
SELECT rank_t.category_id, rank_t.delay_count, rank_t.rk
FROM (
  SELECT c.id AS category_id,
         COUNT(*) AS delay_count,
         RANK() OVER (ORDER BY COUNT(*) DESC) AS rk
  FROM categories c
  JOIN products p      ON p.category_id = c.id
  JOIN order_items oi  ON oi.product_id = p.id
  JOIN shipments s     ON s.order_id = oi.order_id
  WHERE s.order_id IN (1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39)
  GROUP BY c.id
) AS rank_t
WHERE rank_t.rk <= 10;

EXPLAIN ANALYZE
SELECT rank_t.category_id, rank_t.delay_count, rank_t.rk
FROM (
  SELECT c.id AS category_id,
         COUNT(*) AS delay_count,
         RANK() OVER (ORDER BY COUNT(*) DESC) AS rk
  FROM categories c
  JOIN products p      ON p.category_id = c.id
  JOIN order_items oi  ON oi.product_id = p.id
  JOIN shipments s     ON s.order_id = oi.order_id
  WHERE s.order_id IN (1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39)
  GROUP BY c.id
) AS rank_t
WHERE rank_t.rk <= 10;
