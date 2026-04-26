-- Case E2 — Case E 를 더 현실화한 버전
-- 실제 레거시에서처럼 다중 WHERE 필터 (카테고리 범위·주문 기간·배송 상태) 를 추가.
-- oi 풀스캔을 피하고 정상 인덱스 경로 위에서도 BEFORE 의 DEPENDENT SUBQUERY 재평가 비용이 드러나는지 관찰.

USE tuning;

-- 사전: shipments.status 에 idx_status 가 붙어 있는지 확인 (Case F 에서 추가되었어야 함)
SHOW INDEX FROM shipments;

-- ========== BEFORE: 외곽에 실질 WHERE 필터 추가 ==========
EXPLAIN
SELECT rank_t.category_id, rank_t.delay_count, rank_t.rk
FROM (
  SELECT c.id AS category_id,
         COUNT(*) AS delay_count,
         RANK() OVER (ORDER BY COUNT(*) DESC) AS rk
  FROM categories c
  JOIN products p      ON p.category_id = c.id
  JOIN order_items oi  ON oi.product_id = p.id
  JOIN orders o        ON o.id = oi.order_id
  JOIN shipments s     ON s.order_id = oi.order_id
  WHERE c.parent_id = 1
    AND o.order_date >= '2024-07-01'
    AND s.status = 'DELIVERED'
    AND s.order_id IN (
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
  JOIN orders o        ON o.id = oi.order_id
  JOIN shipments s     ON s.order_id = oi.order_id
  WHERE c.parent_id = 1
    AND o.order_date >= '2024-07-01'
    AND s.status = 'DELIVERED'
    AND s.order_id IN (
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

-- ========== AFTER 1단계: order_id 리스트 확보 (단독 실행) ==========
EXPLAIN
SELECT order_id
FROM shipments
WHERE status = 'DELIVERED'
  AND shipped_at IS NOT NULL AND delivered_at IS NOT NULL
GROUP BY order_id
HAVING AVG(DATEDIFF(delivered_at, shipped_at)) > 7;

EXPLAIN ANALYZE
SELECT order_id
FROM shipments
WHERE status = 'DELIVERED'
  AND shipped_at IS NOT NULL AND delivered_at IS NOT NULL
GROUP BY order_id
HAVING AVG(DATEDIFF(delivered_at, shipped_at)) > 7;

-- ========== AFTER 2단계: 실질 필터 + 고정 IN 리스트 ==========
EXPLAIN
SELECT rank_t.category_id, rank_t.delay_count, rank_t.rk
FROM (
  SELECT c.id AS category_id,
         COUNT(*) AS delay_count,
         RANK() OVER (ORDER BY COUNT(*) DESC) AS rk
  FROM categories c
  JOIN products p      ON p.category_id = c.id
  JOIN order_items oi  ON oi.product_id = p.id
  JOIN orders o        ON o.id = oi.order_id
  JOIN shipments s     ON s.order_id = oi.order_id
  WHERE c.parent_id = 1
    AND o.order_date >= '2024-07-01'
    AND s.status = 'DELIVERED'
    AND s.order_id IN (1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39,
                       41,43,45,47,49,51,53,55,57,59,61,63,65,67,69,71,73,75,77,79)
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
  JOIN orders o        ON o.id = oi.order_id
  JOIN shipments s     ON s.order_id = oi.order_id
  WHERE c.parent_id = 1
    AND o.order_date >= '2024-07-01'
    AND s.status = 'DELIVERED'
    AND s.order_id IN (1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39,
                       41,43,45,47,49,51,53,55,57,59,61,63,65,67,69,71,73,75,77,79)
  GROUP BY c.id
) AS rank_t
WHERE rank_t.rk <= 10;
