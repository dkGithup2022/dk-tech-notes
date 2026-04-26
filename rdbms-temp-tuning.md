---
title: "RDBMS SQL 쿼리 튜닝 — temp 테이블 회피"
nav_order: 3
has_children: true
permalink: /rdbms-temp-tuning/
---

# RDBMS SQL 쿼리 튜닝 — 레거시 쿼리의 temp 테이블 원인·회피·검증
{: .no_toc }

## 목차
{: .no_toc .text-delta }

1. TOC
{:toc}


롯데 계열사 물류 관련 기능의 퍼포먼스 튜닝을 시행하면서 정리한 기록입니다.

개선 중, 반복되는 해결 패턴을 모으고 기술적 원인을 서술합니다. 사내 노션에 정리해 두었으나, 본 글에서는 개념 설명과 테스트용 Docker 세팅을 함께 첨부해 다시 업로드합니다.

사측 실제 데이터나 쿼리는 다루지 않고, 범용적으로 사용할 수 있는 방법론에 초점을 맞춥니다.

---

## 들어가며

롯데 계열사 SI/SM 환경에서 SQL 퍼포먼스 튜닝을 맡아, 1000~2000라인 단위의 레거시 쿼리를 반복적으로 개선했습니다.

금융권·대기업 SI/SM 환경에서 흔히 만나는 제약은 다음과 같습니다.

- 1000~2000+ 라인의 쿼리
- 복잡한 계약 구조
- 업체 간 책임에 대한 위약 조건이 존재
- 리아키텍처 등 엔지니어링적 근원 해결책 적용 불가

위의 제약에서 현실적으로 최선의 결과를 내는 데에 집중합니다.

그 과정에서 반복적으로 사용했던 패턴을 정리합니다.

---

## 기술적 해결범위 : temp 테이블에 대처하기

1000라인이 넘는 쿼리의 성능이 보장되지 않는 가장 흔한 이유는, 인덱스를 사용할 수 없거나 merge 되지 않는 구문 때문에 쿼리 depth 중간에 temp table 이 생기고, 그 위에서 fullscan 이 강제된다는 점입니다.

본 글에서는 temp 테이블의 발생 원인을 정리한 뒤, 그 회피·검증 패턴을 다룹니다.

---

## Temp 테이블의 기술적 원인

temp 가 만들어지는 두 차원:

**A. 결과 도출 자체에서 데이터를 모아둬야 할 때**

- GROUP BY / DISTINCT
- ORDER BY
- UNION (UNION ALL 제외)

**B. 서브쿼리가 외곽과 합쳐지지 못할 때 (구조 분리)** — 상위 depth 와 merge 되지 않은 서브쿼리는 별도 단계로 평가되어 결과가 temp 에 저장됩니다.

각 메커니즘 · 인덱스 활용 가능 여부 · 영어 원문 인용은 [별도 자료]({{ "/rdbms-temp-tuning/deep-dive/" | relative_url }})로 분리했습니다.

> temp 테이블은 물리 페이지 이외에 복사된 공간이 필요합니다. 램 위에 들어가지 않으면 disk swap 이 발생해 계단식 성능 저하로 이어집니다.

---

## 회피 방법

사측 실제 쿼리는 가져올 수 없어, 동일 메커니즘을 재현한 테스트 환경에서 BEFORE/AFTER 를 측정해 참고로 두었습니다. 실제 쿼리와 EXPLAIN 결과는 [튜닝 테스트 리포트]({{ "/rdbms-temp-tuning/tuning-test-report/" | relative_url }}) 에 정리되어 있습니다.

| 항목 | 값 |
| --- | --- |
| DBMS | MySQL 8.0.31 |
| 데이터 규모 | products 10K · reviews 20K · shipments 10K · order_items 15K · categories 50 |
| 검증 지표 | EXPLAIN ANALYZE 의 actual time / loops / select_type / type / key |

### 3.1. 근원 회피 — 가능하면 우선

가장 깔끔한 해결은 원인 자체를 제거하는 것입니다. 인덱스가 없으면 걸고, 불필요한 aggregate / DISTINCT / LIMIT / UNION 이 있으면 제거합니다.  
다만 레거시에서 이 선택 자체가 가능한 경우는 많지 않습니다. 아래는 이렇게 정상적 해결이 불가능한 경우를 다룹니다. 

### 3.2. temp 크기 줄이기 — 키를 먼저 확보하기

temp 생성을 피할 수 없다면, **temp 의 크기를 좁히는 것이 우선** 이 되어야 합니다.  
방법은, 노출될 정보의 **축이 되는 key** 를 먼저 쿼리한 뒤, `WHERE id IN (...)` 조건으로 최소화된 범위 안에서만 temp 가 만들어지도록 유도하는 것입니다.

메커니즘상 같은 복잡도를 가져도, 실제로 비교되는 행 수를 줄임으로써 연산 부담을 줄일 수 있습니다.

```sql
-- BEFORE: 스칼라 서브쿼리 3개가 products 각 row 마다 재평가됨
-- 의도적으로 느리게 만든 쿼리, 각 컬럼 조건에서 n*n 연산 발생
-- 이 구조적 개선이 불가능하다는 가정하에, 어떻게 빠르게 만들 것인가?
SELECT p.id, p.name,
  (SELECT COUNT(*)    FROM reviews r  WHERE r.product_id = p.id) AS review_count,
  (SELECT AVG(rating) FROM reviews r  WHERE r.product_id = p.id) AS avg_rating,
  (SELECT COUNT(*)
     FROM shipments s JOIN order_items oi ON s.order_id = oi.order_id
     WHERE oi.product_id = p.id)                                  AS ship_count
FROM products p
WHERE p.category_id IN (SELECT id FROM categories WHERE parent_id = 1)
  AND p.created_at >= '2024-01-01';
```

```sql
-- AFTER: target_ids 를 먼저 확정. 각 서브쿼리는 이 범위 안에서만 돈다
-- 컬럼 별 n*n 복잡도는 똑같지만, 연산에 들어가는 모수 자체를 줄이는 것에 의의를 둔다.
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

위의 쿼리는 만들어 놓은 테스트 환경의 일부입니다. 1만 건 규모 (products 10K · reviews 20K · shipments 10K · order_items 15K) 에서 AS-IS / TO-BE 를 측정한 결과:


| 지표              | BEFORE                                | AFTER                                  | 근거                                                                     |
| --------------- | ------------------------------------- | -------------------------------------- | ---------------------------------------------------------------------- |
| 총 실행 시간         | ~21,000 ms                            | 108 ms                                 | AFTER 는 최상위 `actual time` 직접. BEFORE 는 서브쿼리 #4 `26.4ms × loops=800` 유도 |
| 서브쿼리 분류         | `DEPENDENT SUBQUERY` × 3              | `DERIVED` × 2                          | EXPLAIN `select_type`                                                  |
| 인덱스 활용          | `idx_product` / `idx_order` lookup 활용 | derived materialize 1회 + PK lookup     | EXPLAIN `key` 컬럼                                                       |
| 인덱스 lookup 호출 수 | ~8,000,000 (외곽 row × 안쪽 lookup 곱연산)   | ~30,000 (1회 materialize 시 내부 lookup 합) | EXPLAIN ANALYZE `loops` 최대값                                            |


상세 EXPLAIN·원문은 [tuning_test/report.md 3절 Case D]({{ "/rdbms-temp-tuning/tuning-test-report/" | relative_url }}).

### 3.3. temp 위의 temp 피하기 — 깊이 기준 쿼리를 2단계로 분리

깊어진 서브쿼리의 안쪽 블록이 temp (materialized) 되면, 그 temp 는 원본 테이블의 인덱스를 물려받지 않습니다. 상단의 연산에서 그 temp 를 참조해야 한다면, temp 위에 만들어지는 연산은 인덱스 조건을 쓴다 하여도 풀스캔이 강제됩니다.

e.g.) 특정 칼럼의 sum 조건을 이어받아 상단의 연산에 사용해야 하는 경우가 있다고 합시다. 이 경우 3.2 처럼 id 로 횡으로 깔끔히 잘리지 않습니다.

```sql
SELECT ...
FROM (
  SELECT ...                         -- B: 복잡하지만 인덱스 활용 가능
  FROM ...
  WHERE ... IN (
    SELECT ... FROM ...              -- A: temp 생성
    WHERE ... IN (
      SELECT ... FROM ...            -- 더 깊은 temp 생성
    )
  )
) AS outer;
```

잘라서 해결한다는 점에서 3.2 와 동일합니다.
단 Key 를 기준으로 횡으로 자르는 것과 sub query 영역을 어플리케이션 영역에 보관하는 종으로 자르는 것의 차이는, <u>여기선 죽어있던 인덱스가 활용될 여지가 있다는 점입니다</u>.

```sql
-- 1단계: SUM 스냅샷 획득 — id 뿐 아니라 집계값까지 함께 가져온다
SELECT oi.product_id, SUM(oi.qty) AS total_qty
FROM order_items oi
JOIN orders o ON o.id = oi.order_id
WHERE o.order_date >= '2024-01-01'
GROUP BY oi.product_id
HAVING SUM(oi.qty) > 5;
-- 결과 (애플리케이션 보유): [(5, 12), (10, 47), (15, 8), ..., (100, 23)]
```

```sql
-- 2단계: 스냅샷을 VALUES 로 주입. 집계 재계산 없이 단순 JOIN 으로 조립
SELECT c.name AS category, p.name AS product, snap.total_qty
FROM (VALUES
  ROW(5, 12), ROW(10, 47), ROW(15, 8) /* ... */
) AS snap(product_id, total_qty)
JOIN products   p ON p.id = snap.product_id
JOIN categories c ON c.id = p.category_id
ORDER BY snap.total_qty DESC
LIMIT 20;
```

위의 쿼리는 만들어 놓은 테스트 환경의 일부입니다. 1만 건 규모 (order_items 15K · products 10K · categories 50) 에서 AS-IS / TO-BE 를 측정한 결과:


| 지표              | BEFORE                                            | AFTER (1+2단계)                                            | 근거                             |
| --------------- | ------------------------------------------------- | -------------------------------------------------------- | ------------------------------ |
| 총 실행 시간         | ~292,530 ms (약 5분)                                | ~27 ms                                                   | 최상위 `actual time` 직접           |
| 외곽 드라이빙 테이블 인덱스 | `oi`: `**type=ALL, key=NULL**` (풀스캔, 인덱스 미활용)     | 2단계: `snap` (VALUES) → `p`, `c` `**PRIMARY KEY` lookup** | EXPLAIN `type`, `key`          |
| 서브쿼리 분류         | `DEPENDENT SUBQUERY` (HAVING SUM), `loops=15,000` | 제거 (상수 IN)                                               | EXPLAIN `select_type`, `loops` |
| 안쪽 nested loop  | `loops=225,000,000` (oi2 15K × o2 15K)            | `loops=20` (VALUES 20행)                                  | EXPLAIN ANALYZE `loops`        |
| 2단계 집계 재계산      | — (한 쿼리 안에서 외곽 GROUP BY 도 재실행)                    | 없음 (스냅샷 값 그대로 SELECT)                                    | EXPLAIN                        |


상세 EXPLAIN·원문은 [tuning_test/report.md 4.2 Case G — case 2]({{ "/rdbms-temp-tuning/tuning-test-report/" | relative_url }}).

1단계 결과는 애플리케이션 메모리로 옮겨지고, 2단계 IN 자리는 고정 상수 리스트가 됩니다. 중첩 temp 한 층이 사라집니다.

EXPLAIN 으로 본 차이는 **인덱스 활용 여부**입니다. BEFORE 의 `oi` 는 `type=ALL, key=NULL` — 안쪽 IN 서브쿼리가 동적 결과를 반환하기 때문에 옵티마이저가 `oi` 를 풀스캔으로 잡고 안쪽 oi2 도 같은 이유로 풀스캔합니다. AFTER 의 2단계는 IN 이 상수 VALUES 가 되어, 옵티마이저가 그 상수를 드라이빙으로 삼고 `products` / `categories` 를 `PRIMARY KEY` 로 lookup 합니다.

외곽 WHERE 를 더 정교하게 짜도 서브쿼리 구조를 자르지 않으면 같은 풀스캔이 반복됩니다. 이 분리가 항상 가능한 것은 아닙니다. 옵티마이저가 어떻게 풀어내는지·애초에 자를 수 있는 구조인지는 현장에 가봐야 압니다. 자를 수 있다면 시도해봄직합니다.

---

## 검증 — 동시성과 동치성

1단계·2단계 사이에 다른 tx 가 데이터를 바꾸면 결과가 어긋날 수 있습니다 — 애플리케이션 tx 로 묶어야 하고, 격리 수준 주의도 필요합니다.

2단계 분리 (3.3) 는 한 쿼리가 두 쿼리로 나뉘는 만큼 두 가지를 챙깁니다.

### 4.1. 동시성 — 같은 snapshot 으로 묶기

BEFORE (단일 쿼리) 는 한 SQL 안에서 statement-level snapshot 으로 한 시점의 데이터를 봅니다. 2단계 분리가 같은 행동을 유지하려면 1단계·2단계가 같은 tx 의 같은 snapshot 안에 있어야 합니다 — **`REPEATABLE READ` 수준이 권장됩니다**.

- **MySQL InnoDB 기본: `REPEATABLE READ`**. 일반 SELECT 라면 기본 격리 수준만으로 BEFORE 와 동일 일관성.
- **Oracle 기본: `READ COMMITTED`**. 두 SQL 사이 일관성은 보장되지 않음. `SET TRANSACTION READ ONLY` 또는 `SERIALIZABLE` 로 명시 승격 권장.

지키지 않으면 1단계·2단계 사이에 다른 tx 의 변경이 끼어 결과가 어긋날 수 있습니다.

→ [MySQL 8.0: Transaction Isolation Levels](https://dev.mysql.com/doc/refman/8.0/en/innodb-transaction-isolation-levels.html)
→ [Oracle Database Concepts: Data Concurrency and Consistency](https://docs.oracle.com/cd/E11882_01/server.112/e40540/consist.htm)

### 4.2. 동치성 — 결과가 같은지 확인

쿼리를 분해·재조립한 만큼 BEFORE 와 AFTER 의 결과가 같은지 확인해야 합니다. 결과를 다방면으로 백업해 대조하는 것이 이상적이지만, 두 가지 현실이 끼어듭니다.

1. 검증 환경을 어디까지 갖출 수 있는가는 현장마다 다릅니다. 풀 데이터셋·동등 부하·트래픽 shadow 가 항상 가능하진 않습니다.
2. 잘 관리되지 않은 레거시 쿼리는 **기존 로직 자체가 잘못된 경우도 많습니다**. AFTER 가 BEFORE 와 다르게 나온 게 사실은 BEFORE 의 버그였을 수도 있습니다. 무조건 동치성을 맞추려 들면 오히려 버그를 보존하는 결과가 됩니다.

검증은 필요합니다. 다만 현장 상황·기존 로직의 신뢰도에 따라 어디까지·어떻게 검증할지는 위트 있게 판단할 일입니다. 구체 방법론은 본 글에서 다루지 않습니다.

---

## 참고 자료

**1. 책**: Real MySQL

실제로는 책을 보고 했지만, 참고용으로 같은 설명의 공식 문서를 모았습니다.

**MySQL 공식 문서 (8.0 기준)**

- [Internal Temporary Table Use](https://dev.mysql.com/doc/refman/8.0/en/internal-temporary-tables.html)
- [GROUP BY Optimization](https://dev.mysql.com/doc/refman/8.0/en/group-by-optimization.html)
- [ORDER BY Optimization](https://dev.mysql.com/doc/refman/8.0/en/order-by-optimization.html)
- [Set Operations with UNION, INTERSECT, EXCEPT](https://dev.mysql.com/doc/refman/8.0/en/set-operations.html)
- [Optimizing Derived Tables, View References, and CTEs](https://dev.mysql.com/doc/refman/8.0/en/derived-table-optimization.html)
- [Optimizing Subqueries with Materialization](https://dev.mysql.com/doc/refman/8.0/en/subquery-materialization.html)
- [EXPLAIN Output Format](https://dev.mysql.com/doc/refman/8.0/en/explain-output.html)
- [Transaction Isolation Levels](https://dev.mysql.com/doc/refman/8.0/en/innodb-transaction-isolation-levels.html)
