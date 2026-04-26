-- Case F — 3.1 "근원 회피" : 인덱스 추가로 temp 제거
-- shipments.status 에 인덱스 없음 → GROUP BY 로 Using temporary → 인덱스 추가 후 Using index.

USE tuning;

-- ========== BEFORE: status 인덱스 없음 ==========
EXPLAIN
SELECT status, COUNT(*) AS cnt
FROM shipments
GROUP BY status;

EXPLAIN ANALYZE
SELECT status, COUNT(*) AS cnt
FROM shipments
GROUP BY status;

-- 실제 결과 확인
SELECT status, COUNT(*) AS cnt
FROM shipments
GROUP BY status
ORDER BY cnt DESC;

-- ========== 인덱스 추가 ==========
ALTER TABLE shipments ADD INDEX idx_status (status);

-- ========== AFTER: 인덱스 커버 ==========
EXPLAIN
SELECT status, COUNT(*) AS cnt
FROM shipments
GROUP BY status;

EXPLAIN ANALYZE
SELECT status, COUNT(*) AS cnt
FROM shipments
GROUP BY status;

-- 인덱스 롤백 (재실행 대비)
-- ALTER TABLE shipments DROP INDEX idx_status;
