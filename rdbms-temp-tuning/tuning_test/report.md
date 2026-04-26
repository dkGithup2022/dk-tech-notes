---
title: "튜닝 테스트 리포트"
parent: "RDBMS SQL 쿼리 튜닝 — temp 테이블 회피"
nav_order: 2
permalink: /rdbms-temp-tuning/tuning-test-report/
---

# tuning_test 실험 결과 리포트
{: .no_toc }

## 목차
{: .no_toc .text-delta }

1. TOC
{:toc}

본문([RDBMS SQL 쿼리 튜닝]({{ "/rdbms-temp-tuning/" | relative_url }})) 회피 카드 세 개 (근원 회피 / temp 크기 줄이기 / 2단계 분리) 를 실제 MySQL 8.0.31 에서 BEFORE/AFTER 로 검증한 결과.

실행 방법은 [테스트 환경 셋업]({{ "/rdbms-temp-tuning/tuning-test-setup/" | relative_url }}) 참조. 원문 EXPLAIN 출력은 [`explains/case-*.txt`](https://github.com/dkGithup2022/dk-tech-notes/tree/main/rdbms-temp-tuning/tuning_test/explains) 원본.

---

## 1. 환경 및 데이터

- **MySQL 8.0.31** (Docker, `docker/docker-compose.yml`)
- 세션 기본 설정: `tmp_table_size = 16M`, `max_heap_table_size = 16M` (의도적으로 작게 — 디스크 이관 임계 관찰 용이)
- **데이터 규모 (9 테이블)**

| 테이블 | rows | 비고 |
|---|---|---|
| categories | 50 | self-reference `parent_id` |
| suppliers | 100 | |
| warehouses | 5 | |
| products | 10,000 | |
| users | 2,000 | |
| orders | 5,000 | |
| order_items | 15,000 | |
| **shipments** | **10,000** | `status` 컬럼 **인덱스 의도적 누락** (Case F) |
| reviews | 20,000 | |

---

## 2. Case F — 근원 회피 (인덱스 추가)

### 쿼리

```sql
-- BEFORE: shipments.status 인덱스 없음
SELECT status, COUNT(*) AS cnt FROM shipments GROUP BY status;

-- ALTER: 인덱스 추가
ALTER TABLE shipments ADD INDEX idx_status (status);

-- AFTER: 인덱스 커버
SELECT status, COUNT(*) AS cnt FROM shipments GROUP BY status;
```

### EXPLAIN 핵심

| | type | key | Extra |
|---|---|---|---|
| BEFORE | ALL | NULL | **Using temporary** |
| AFTER | index | idx_status | **Using index** |

### 실행 시간 (EXPLAIN ANALYZE)

- BEFORE: Table scan → Aggregate using temporary table, **5.724 ms**
- AFTER: Covering index scan → Group aggregate, **2.300 ms**

### 해석

"인덱스가 없으면 걸자" 의 교본. 스캔 방식이 `table scan` → `covering index scan` 으로 전환되고 temp 자체가 사라진다. 1만 건 규모에서는 절대 시간 차가 크지 않지만, buffer pool 을 벗어나는 규모에서는 격차가 급증한다.

---

## 3. Case D — temp 크기 줄이기 (핵심 id 선행 확정)

### 쿼리

```sql
-- BEFORE: 스칼라 서브쿼리 3개가 각 product 마다 반복
SELECT p.id, p.name,
  (SELECT COUNT(*) FROM reviews r WHERE r.product_id = p.id) AS review_count,
  (SELECT AVG(rating) FROM reviews r WHERE r.product_id = p.id) AS avg_rating,
  (SELECT COUNT(*) FROM shipments s
    JOIN order_items oi ON s.order_id = oi.order_id
    WHERE oi.product_id = p.id) AS ship_count
FROM products p
WHERE p.category_id IN (SELECT id FROM categories WHERE parent_id = 1)
  AND p.created_at >= '2024-01-01';
```

```sql
-- AFTER: 핵심 id CTE + 각 서브쿼리에 IN 주입
WITH target_ids AS (
  SELECT p.id FROM products p
  WHERE p.category_id IN (SELECT id FROM categories WHERE parent_id = 1)
    AND p.created_at >= '2024-01-01'
)
SELECT p.id, p.name, rc.review_count, rc.avg_rating, sc.ship_count
FROM products p
LEFT JOIN (
  SELECT product_id, COUNT(*) AS review_count, AVG(rating) AS avg_rating
  FROM reviews WHERE product_id IN (SELECT id FROM target_ids)
  GROUP BY product_id
) rc ON p.id = rc.product_id
LEFT JOIN (
  SELECT oi.product_id, COUNT(*) AS ship_count
  FROM shipments s JOIN order_items oi ON s.order_id = oi.order_id
  WHERE oi.product_id IN (SELECT id FROM target_ids)
  GROUP BY oi.product_id
) sc ON p.id = sc.product_id
WHERE p.id IN (SELECT id FROM target_ids);
```

### EXPLAIN 핵심

**BEFORE** — `DEPENDENT SUBQUERY` 3개가 각 product row 마다 재평가:

```
-> Select #4 (subquery in projection; dependent)
   -> Aggregate: count(0)  actual time=26.360..26.360 rows=1 loops=800
      -> Nested loop inner join  actual time=13.066..26.355 rows=3 loops=800
         -> Covering index scan on s using idx_order  rows=10000 loops=800
         -> Index lookup on oi using idx_order (order_id=s.order_id)  loops=8,000,000
```

→ shipments 10K × products 800 회 반복 + 내부 oi lookup **8백만** 이터레이션.

**AFTER** — `DERIVED` 2개가 각 1회 materialize + hash join:

```
-> Left hash join (sc.product_id = p.id)  actual time=106.151..107.990 rows=800 loops=1
   -> Left hash join (rc.product_id = p.id)  actual time=40.888..42.612
      -> Hash -> Materialize rc 800 rows
   -> Hash -> Materialize sc 800 rows
```

### 실행 시간

- BEFORE: 서브쿼리 #4 만 `26.4 ms × loops=800 ≈ 21,000 ms`. 전체 **~21 초**.
- AFTER: **108 ms**.

### 해석

인덱스는 BEFORE/AFTER 모두 제대로 타고 있다. 차이는 **"서브쿼리를 몇 번 실행하느냐"**:
- BEFORE: scalar subquery 3개 × 각 product 800회 재평가 = 2,400회, 그 중 서브쿼리 #4 내부는 8백만 loops.
- AFTER: CTE/derived 2개 materialize 1회씩, 이후 hash join 으로 조립.

옵티마이저가 BEFORE 의 `WHERE oi.product_id = p.id` correlated 조건을 보고 DEPENDENT SUBQUERY 로 풀면서 반복 실행 플랜을 채택. `idx_product` 가 존재하지만 join order 를 `shipments → order_items` 로 잡아 `oi.product_id` 필터가 뒤로 밀림.

---

## 4. Case G — temp 위의 temp 피하기 (SUM 스냅샷 + VALUES 주입)

3.3 의 본질을 측정한다. 1단계 결과를 단순 id 리스트가 아니라 **집계값까지 포함한 스냅샷** 으로 받아두고, 2단계는 그 스냅샷을 그대로 사용해 **재계산을 아예 없앤다**.

같은 BEFORE/AFTER 패턴에서 HAVING 조건만 다른 두 케이스를 측정해 비용 구조를 비교한다.

### 4.1 case 1 — 희소 매칭 (HAVING SUM(qty) > 50)

조건이 데이터 분포 (oi 15K / product 10K, qty 1~5, product 당 SUM 평균 ≈ 4.5) 대비 너무 높아 **결과가 0 rows** 인 케이스. BEFORE 가 "결과 없음" 을 확정하는 데조차 폭발적 시간이 들어가는지 확인.

#### 쿼리

```sql
-- BEFORE
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
```

```sql
-- AFTER 1단계
SELECT oi.product_id, SUM(oi.qty) AS total_qty
FROM order_items oi
JOIN orders o ON o.id = oi.order_id
WHERE o.order_date >= '2024-01-01'
GROUP BY oi.product_id
HAVING SUM(oi.qty) > 50;
-- 결과: 0 rows
```

```sql
-- AFTER 2단계 (관찰용 샘플 VALUES 20개)
SELECT c.name AS category, p.name AS product, snap.total_qty
FROM (VALUES ROW(1, 100), ROW(2, 95) /* ... 20 rows */) AS snap(product_id, total_qty)
JOIN products   p ON p.id = snap.product_id
JOIN categories c ON c.id = p.category_id
ORDER BY snap.total_qty DESC
LIMIT 20;
```

#### 결과

| 단계 | 시간 | 결과 rows |
|---|---|---|
| BEFORE | **315,060 ms (약 5분 15초)** | 0 |
| AFTER 1단계 | 26.5 ms | 0 |
| AFTER 2단계 | 9.8 ms | 20 (VALUES 기반) |
| **AFTER 합계** | **~36 ms** | — |

→ **약 8,700× 단축**

### 4.2 case 2 — 정상 매칭 (HAVING SUM(qty) > 5)

같은 구조에 HAVING 조건만 낮춰 실제 매칭이 있는 정상 케이스. 1단계 스냅샷이 의미 있는 리스트를 반환.

#### 결과

| 단계 | 시간 | 결과 rows |
|---|---|---|
| BEFORE | **292,530 ms (약 4분 53초)** | 20 (LIMIT) |
| AFTER 1단계 | ~26 ms | 다수 (상위 20개 반환) |
| AFTER 2단계 | **0.7 ms** | 20 |
| **AFTER 합계** | **~27 ms** | — |

→ **약 10,800× 단축**

#### 1단계 스냅샷 (상위 20개, 애플리케이션이 수령)

```
[(5, 10), (10, 10), (15, 10), (20, 10), ..., (100, 10)]
```
(데이터 생성의 modular 패턴 영향으로 product_id 5의 배수가 상위에 몰림)

#### 2단계 EXPLAIN 핵심

```
-> Limit: 20 rows  actual time=0.120..0.733 rows=20 loops=1
   -> Nested loop inner join
      -> Sort: snap.total_qty DESC  rows=20 loops=1
         -> Materialize  rows=20 loops=1  (VALUES)
      -> Single-row index lookup on p using PRIMARY  loops=20
      -> Single-row index lookup on c using PRIMARY  loops=20
```

→ VALUES 20 rows materialize + 단순 JOIN + filesort. **집계 재계산 없음**.

### 4.3 두 case 비교에서 얻는 인사이트

| | case 1 (희소, 0 rows) | case 2 (정상, 6,000 매칭) |
|---|---|---|
| BEFORE 시간 | 315,060 ms | 292,530 ms |
| 외곽 oi 풀스캔 | 15,000 rows | 15,000 rows |
| DEPENDENT SUBQUERY loops | 15,000 | 15,000 |
| 안쪽 nested loop | **225,000,000** | **225,000,000** |

결과 매칭 수가 0 vs 6,000 으로 크게 다른데 BEFORE 시간 차는 **약 7%** 에 불과.

→ BEFORE 의 비용은 결과 row 수가 아니라 **"DEPENDENT SUBQUERY × 외곽 row 수 × 안쪽 nested loop"** 의 곱에 지배된다. 옵티마이저가 매칭 여부를 *확정* 하는 데조차 같은 곱연산을 거쳐야 하기 때문.

이게 본문 3.3 의 핵심 — **temp 위의 temp 가 치명적인 이유는 "검사 횟수 자체가 곱연산으로 누적" 되기 때문이지 결과 크기 때문이 아니다**.

#### BEFORE EXPLAIN ANALYZE 의 안쪽 라인 (case 2 기준)

```
-> Filter: <in_optimizer>(oi.product_id, <exists>(select #2))  rows=6000 loops=1
   -> Table scan on oi  rows=15,000 loops=1
   -> Select #2 (subquery in condition; dependent)
      -> Aggregate using temporary table  rows=10,000 loops=15,000
         -> Nested loop inner join  rows=15,000 loops=15,000
            -> Single-row index lookup on o2  loops=225,000,000
```

→ 안쪽 nested loop 가 oi2 15K × o2 15K 로 풀려 `loops=225,000,000`.

---

## 5. 측정 환경 제약 (중요)

### buffer pool 안 상주

- 9 테이블 총 row 수 약 62,000. 한 row 당 수백 바이트 기준 **총 수십 MB**.
- InnoDB `innodb_buffer_pool_size` 기본값 128MB 안에 전체 데이터가 상주.
- `loops=15,000` 의 반복 탐색도 **디스크 I/O 없는 메모리 내 CPU 연산**.
- BEFORE 의 5분급 시간은 "디스크가 느려서" 가 아니라 **"CPU 가 15,000번 반복 연산"** 해서 나온 수치.

### 대규모 (10만·100만 건) 에서 달라지는 지점

1. **디스크 I/O 추가**: 반복 탐색마다 buffer pool miss 가능. 단, 같은 블록이 반복 참조되면 OS 페이지 캐시에 살아남아 영향이 덜할 수도.
2. **temp → 디스크 이관의 계단식 드롭**: `tmp_table_size` 임계를 BEFORE 가 먼저 넘어감. 이게 걸리면 배수가 **더 커짐**. 옵티마이저가 다른 플랜으로 회피하면 **작아질 수도**.
3. **옵티마이저 플랜 교체**: 통계상 거대 테이블이 되면 join order / 서브쿼리 strategy 가 달라짐. DEPENDENT SUBQUERY 가 materialize 로 승격되면 배수가 한 자릿수로 줄 수도.

### 결론

절대 시간 배수 (10,000×) 는 이 측정 조건의 artefact. **"temp 가 몇 번 반복 실행되느냐"** 의 이터레이션 수 차이 (`loops=15,000` vs `loops=1`, `loops=225,000,000` vs `loops=20`) 가 스케일에 덜 민감한 본질적 지표.

---

## 6. 총평

| Case | 본문 대응 | 본질 |
|---|---|---|
| F | 3.1 근원 회피 | `Extra: Using temporary` → `Using index` 전환 |
| D | 3.2 temp 크기 줄이기 | loops=8,000,000 → loops=1. 8백만 회 반복이 materialize 1회로 축약 |
| G (case 1·2) | 3.3 2단계 분리 | DEPENDENT SUBQUERY 의 안쪽 nested loop 225M loops 폭발 → 1단계 SUM 스냅샷 + 2단계 VALUES 주입으로 재계산 자체 제거 |

실측의 일관된 관찰:
- temp 의 비용은 "있냐 없냐" 가 아니라 **"몇 번 반복되느냐"** 다.
- **결과 row 수가 아니라 "검사 횟수 (loops)" 가 비용을 지배** 한다 (Case G 의 case 1·case 2 비교에서 확인).
