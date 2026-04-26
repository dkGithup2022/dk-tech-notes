# Temp 테이블 메커니즘 — MySQL 8.0 / Oracle 19c

본 자료는 `slow-query-migration-v2.md` 본문의 보조 자료다. 기준 버전은 MySQL 8.0 / Oracle Database 19c 이며, 본문이 MySQL 위주이므로 Oracle 은 대비 형식으로 나란히 배치했다.

본문과의 매핑:

- 본문 2장 A (집계·정렬·중복 제거) → 본 자료 1·2·3
- 본문 2장 B (derived materialize) → 본 자료 4 (+ 0. 평탄화 섹션)
- 본문 3.2·3.3 → 본 자료 5 (Subquery materialization / WITH clause)
- 본문 3.1 ~ 3.3 (실측 케이스) → `tuning_test/report.md` 의 Case F / D / G

---

## 0. 핵심 개념 — Streaming 과 평탄화 (merge)

### Streaming

옵티마이저가 결과를 임시 테이블에 모으지 않고 한 row 씩 흘려보내며 처리하는 방식. 인덱스가 정렬·그룹 정보를 직접 제공할 때 가능하다.

같은 `GROUP BY status` 쿼리에 대해 인덱스 유무로 EXPLAIN 이 다음과 같이 갈린다 (실측: `tuning_test/report.md` Case F):

```sql
SELECT status, COUNT(*) FROM shipments GROUP BY status;
```

| 인덱스 상태 | type | key | Extra |
|---|---|---|---|
| BEFORE: status 인덱스 없음 | `ALL` | `NULL` | **`Using temporary`** (모음) |
| AFTER: `idx_status` 추가 | `index` | `idx_status` | **`Using index`** (streaming) |

`Extra` 가 `Using temporary` → `Using index` 로 전환되면 streaming 으로 풀린 것이다. 단, 인덱스를 *사용해도* GROUP BY / ORDER BY 컬럼이 인덱스 prefix 와 일치하지 않으면 streaming 이 안 된다는 점에 유의.

→ 구체 구현 (Loose / Tight Index Scan) 은 [MySQL GROUP BY Optimization](https://dev.mysql.com/doc/refman/8.0/en/group-by-optimization.html) 참조.

### 평탄화 (merge)

옵티마이저가 서브쿼리·view·CTE 를 외곽 query block 에 inline 으로 펼쳐 하나의 query block 으로 처리하는 변환이다. 외곽 WHERE 와 서브쿼리 WHERE 가 합쳐져 통합 plan 으로 최적화되며, EXPLAIN 의 `select_type=SIMPLE` 한 줄로 나오면 평탄화 성공의 표식이다. 평탄화 불가 시에는 `PRIMARY` + `<derived2>` 두 줄로 분리되고 derived 결과를 internal temporary table 로 굳힌 뒤 그 위에서 access 한다.

BEFORE / AFTER 가상 예시:

```sql
-- 평탄화 가능 (단순 select-project)
SELECT *
  FROM (SELECT id, name FROM products WHERE created_at >= '2024-01-01') AS t
 WHERE t.category_id = 5;

-- 옵티마이저 내부 처리 결과:
-- SELECT id, name FROM products WHERE created_at >= '2024-01-01' AND category_id = 5
-- EXPLAIN: select_type=SIMPLE 한 줄
```

```sql
-- 평탄화 불가 (서브쿼리 안 GROUP BY)
SELECT *
  FROM (SELECT category_id, COUNT(*) AS c FROM products GROUP BY category_id) AS t
 WHERE t.c > 100;

-- EXPLAIN: PRIMARY <derived2> + DERIVED 두 줄
-- 외곽의 c > 100 조건을 derived 안으로 내려보낼 수 없으므로 derived 가 굳어진 뒤 filter
```

**원문 리소스 (MySQL)**: [MySQL 8.0 Reference Manual, Optimizing Derived Tables, View References, and Common Table Expressions with Merging or Materialization](https://dev.mysql.com/doc/refman/8.0/en/derived-table-optimization.html)

> "The optimizer handles derived tables, view references, and common table expressions the same way: It avoids unnecessary materialization whenever possible, which enables pushing down conditions from the outer query to derived tables and produces more efficient execution plans."
>
> Constructs that prevent merging include: "Aggregate functions or window functions (SUM(), MIN(), MAX(), COUNT(), etc.) … DISTINCT … GROUP BY … HAVING … LIMIT … UNION or UNION ALL … Subqueries in the select list … Assignments to user variables … References only to literal values."

**원문 리소스 (Oracle)**: [Oracle Database SQL Tuning Guide 19c, Query Transformations — View Merging](https://docs.oracle.com/en/database/oracle/oracle-database/19/tgsql/query-transformations.html)

> "View merging is a transformation where the optimizer merges the query block representing a view into the query block that contains it."

---

## 1. GROUP BY / DISTINCT

### MySQL

GROUP BY 의 디폴트 처리는 temp 테이블 기반이다 — 같은 그룹의 행이 연속되도록 임시 테이블에 모은 뒤 그 위에서 그룹 경계를 인식하고 집계 함수를 적용한다. 이 디폴트를 회피하려면 GROUP BY 의 모든 컬럼이 동일한 정렬 가능 인덱스 (B-tree) 의 prefix 를 따라야 하며, 그때만 Loose Index Scan / Tight Index Scan 으로 streaming 이 가능해진다 (위 0. 핵심 개념 참조). DISTINCT 는 GROUP BY 와 같은 메커니즘을 따르고, ORDER BY 와 결합되어 정렬과 중복 제거가 동시에 요구되면 별도의 temp 가 추가로 필요해질 수 있다.

**원문 리소스**: [MySQL 8.0 Reference Manual, GROUP BY Optimization](https://dev.mysql.com/doc/refman/8.0/en/group-by-optimization.html)

> "The most general way to satisfy a `GROUP BY` clause is to scan the whole table and create a new temporary table where all rows from each group are consecutive, and then use this temporary table to discover groups and apply aggregate functions (if any). In some cases, MySQL is able to do much better than that and avoid creation of temporary tables by using index access."
>
> "The most important preconditions for using indexes for `GROUP BY` are that all `GROUP BY` columns reference attributes from the same index, and that the index stores its keys in order (as is true, for example, for a `BTREE` index, but not for a `HASH` index)."

**원문 리소스**: [MySQL 8.0 Reference Manual, Internal Temporary Table Use](https://dev.mysql.com/doc/refman/8.0/en/internal-temporary-tables.html)

> "Evaluation of statements that contain an `ORDER BY` clause and a different `GROUP BY` clause, or for which the `ORDER BY` or `GROUP BY` contains columns from tables other than the first table in the join queue."
>
> "Evaluation of `DISTINCT` combined with `ORDER BY` may require a temporary table."

### Oracle

PGA work area 위에서 SORT GROUP BY / HASH GROUP BY 로 처리되며, 입력이 들어오지 않으면 TEMP tablespace 의 sort segment 로 spill 된다. DISTINCT 는 SORT UNIQUE / HASH UNIQUE 로 같은 규칙을 따른다.

**원문 리소스**: [Oracle Database Concepts 19c, Memory Architecture — Work Area](https://docs.oracle.com/en/database/oracle/oracle-database/19/cncpt/memory-architecture.html)

> "If the amount of data to be processed by the operators does not fit into a work area, then Oracle Database divides the input data into smaller pieces. In this way, the database processes some data pieces in memory while writing the rest to temporary disk storage for processing later."

---

## 2. ORDER BY

### MySQL

ORDER BY 는 두 가지 경로 중 하나로 처리된다 — 인덱스 키 순서가 ORDER BY 와 호환되면 인덱스를 그대로 따라가며 정렬을 회피하고, 그렇지 않으면 filesort 라는 별도 정렬 단계를 거친다. filesort 는 결과 집합이 메모리 (`sort_buffer_size`) 안에 들어오면 in-memory 로 끝나지만, 초과하면 디스크 임시 파일에 부분 정렬 결과를 흘려보내며 외부 병합을 수행한다 — 이 디스크 영역이 internal temporary 자원의 한 형태다. 인덱스가 ORDER BY 와 정확히 일치하지 않더라도, 일치하지 않는 인덱스 컬럼·추가 ORDER BY 컬럼이 모두 WHERE 의 상수 조건이라면 여전히 인덱스가 정렬을 대신할 수 있다. EXPLAIN 의 Extra 컬럼에 `Using filesort` 가 없으면 인덱스가 정렬을 처리한 경우다.

**원문 리소스**: [MySQL 8.0 Reference Manual, ORDER BY Optimization](https://dev.mysql.com/doc/refman/8.0/en/order-by-optimization.html)

> "If an index cannot be used to satisfy an `ORDER BY` clause, MySQL performs a `filesort` operation that reads table rows and sorts them. A `filesort` constitutes an extra sorting phase in query execution."
>
> "The index may also be used even if the `ORDER BY` does not match the index exactly, as long as all unused portions of the index and all extra `ORDER BY` columns are constants in the `WHERE` clause."
>
> "A `filesort` operation uses temporary disk files as necessary if the result set is too large to fit in memory."

### Oracle

인덱스로 정렬을 회피할 수 없으면 SORT ORDER BY 가 PGA sort area 위에서 수행되고, 입력이 들어오지 않으면 TEMP tablespace 로 spill 된다. 인덱스가 정렬을 흡수하면 sort 단계 자체가 사라진다.

**원문 리소스**: [Oracle Database Concepts 19c, Memory Architecture — Work Area](https://docs.oracle.com/en/database/oracle/oracle-database/19/cncpt/memory-architecture.html)

> "The database automatically tunes work area sizes when automatic PGA memory management is enabled."

---

## 3. UNION (vs UNION ALL)

### MySQL

UNION 은 중복 제거 (DISTINCT) 가 동반되는 집합 연산이다. MySQL 은 중복 제거를 위해 각 query block 의 결과를 internal temporary table 에 모은 뒤, 그 위에서 unique 제약을 통해 duplicate 를 걸러낸다. 따라서 UNION 자체가 internal temporary table 을 트리거하는 대표적인 케이스로 공식 문서에 명시돼 있다. 반대로 UNION ALL 은 중복 제거가 필요 없으므로 일반적으로 행을 그대로 stream 할 수 있어 temp 가 불필요하다. 여러 ALL/DISTINCT 가 섞이면 어느 한 위치의 DISTINCT 가 그 좌측의 ALL 을 override 한다. UNION ALL 로 바꾸면 temp materialize 단계가 사라진다.

**원문 리소스**: [MySQL 8.0 Reference Manual, Internal Temporary Table Use](https://dev.mysql.com/doc/refman/8.0/en/internal-temporary-tables.html)

> "The server creates temporary tables under conditions such as these:
> - Evaluation of `UNION` statements, with some exceptions described later.
> - Evaluation of some views, such those that use the `TEMPTABLE` algorithm, `UNION`, or aggregation.
> - Evaluation of derived tables …
> - Evaluation of common table expressions …
> - Tables created for subquery or semijoin materialization …"

**원문 리소스**: [MySQL 8.0 Reference Manual, Set Operations with UNION, INTERSECT, and EXCEPT](https://dev.mysql.com/doc/refman/8.0/en/set-operations.html)

> "By default, duplicate rows are removed from results of set operations."
>
> "With the optional ALL keyword, duplicate-row removal does not occur and the result includes all matching rows from all queries in the union."
>
> "You can mix ALL and DISTINCT in the same query. Mixed types are treated such that a set operation using DISTINCT overrides any such operation using ALL to its left."

### Oracle

UNION 은 SORT UNIQUE / HASH UNIQUE 단계를 거치며 spill 시 TEMP 로 떨어진다. UNION ALL 은 stream 으로 연결되며, 동일 base 테이블이 여러 branch 에 반복되는 경우 CBO 가 cursor-duration temporary table 로 한 번만 평가하도록 변환할 수 있다.

**원문 리소스**: [Oracle Database SQL Tuning Guide 19c, Query Transformations — Cursor-Duration Temporary Tables](https://docs.oracle.com/en/database/oracle/oracle-database/19/tgsql/query-transformations.html)

> "To materialize the intermediate results of a query, Oracle Database may implicitly create a cursor-duration temporary table in memory during query compilation."
>
> "Without any transformation, the database must perform the scan and the filtering on table `t1` twice, one time for each branch."
>
> "In this case, because table `t1` is factorized, the database performs the table scan and the filtering on `t1` only one time."

---

## 4. Derived table / inline view materialize

### MySQL

MySQL 8.0 의 옵티마이저는 derived table·view·CTE 를 동일한 두 가지 전략 — merge 또는 materialize — 으로 다룬다. 가능한 한 outer query 와 merge 해서 외부 조건의 push-down 을 허용하고, merge 가 막힌 경우에만 internal temporary table 로 materialize 한다. merge 를 차단하는 구문은 0. 핵심 개념 섹션에 인용된 리스트와 동일하다 — 집계·윈도우 함수, DISTINCT, GROUP BY, HAVING, LIMIT, UNION/UNION ALL, select list 의 subquery, user variable 할당, literal-only reference. 또 merge 결과의 base 테이블 수가 61 을 넘으면 자동으로 materialize 로 떨어진다. `derived_merge` optimizer switch 로 이 동작을 끌 수 있다. materialize 된 derived table 에는 옵티마이저가 동적으로 인덱스를 붙여 ref access 를 가능하게 만들기도 한다.

**원문 리소스**: [MySQL 8.0 Reference Manual, Optimizing Derived Tables, View References, and Common Table Expressions with Merging or Materialization](https://dev.mysql.com/doc/refman/8.0/en/derived-table-optimization.html)

> "If merging would result in an outer query block that references more than 61 base tables, the optimizer chooses materialization instead."
>
> "Similarly, you can use the `derived_merge` flag of the `optimizer_switch` system variable. By default, the flag is enabled to permit merging."
>
> "During query execution, the optimizer may add an index to a derived table to speed up row retrieval from it."

### Oracle

Oracle 의 "temp" 는 두 층으로 구성된다 — (1) PGA work area 가 부족할 때 disk 로 spill 되어 만들어지는 temp segment 와 (2) CBO 가 의도적으로 중간 결과를 저장하기 위해 만드는 cursor-duration temporary table. 두 층 모두 TEMP tablespace 에 저장된다.

Oracle 은 inline view 와 view reference 를 view merging 으로 outer query 와 합치려 한다. simple view merging 은 select-project-join view 에, complex view merging 은 GROUP BY / DISTINCT 가 포함된 view 에 적용되며, outer join·MODEL·CONNECT BY·set operator 같은 구문은 simple merge 를 막는다. 채택 여부는 cost 비교로 결정된다. 같은 query block 이 반복 참조되는 패턴 (WITH 절, star transformation, grouping sets) 에서는 CBO 가 cursor-duration temporary table 을 자동 생성해 한 번만 계산한 결과를 재사용한다. 임시 테이블은 고유 이름으로 만들어지고 메모리에 우선 적재되며, 메모리가 부족하면 disk 의 temporary segment 로 떨어졌다가 cursor 종료 시 truncate 된다.

**원문 리소스**: [Oracle Database SQL Tuning Guide 19c, Query Transformations — Cursor-Duration Temporary Tables](https://docs.oracle.com/en/database/oracle/oracle-database/19/tgsql/query-transformations.html)

> "To materialize the intermediate results of a query, Oracle Database may implicitly create a cursor-duration temporary table in memory during query compilation."
>
> The database, when it chooses this plan, "Creates the temporary table using a unique name", "Rewrites the query to refer to the temporary table", "Loads data into memory until no memory remains, in which case it creates temporary segments on disk", "Executes the query, returning data from the temporary table", and "Truncates the table, releasing memory and any on-disk temporary segments".

---

## 5. 엔진 특유

### MySQL: Subquery materialization

IN/EXISTS 같은 nested subquery 도 옵티마이저가 한 번만 평가하도록 internal temporary table 로 materialize 할 수 있다. materialize 된 결과에는 보통 hash index 가 부여되어 outer 행마다의 lookup 이 저렴해지며, in-memory 로 시작해 크기가 커지면 on-disk 로 spill 된다. 이 동작은 `optimizer_switch` 의 `materialization` 플래그가 켜져 있을 때 활성화되고, EXPLAIN 의 `select_type` 이 `DEPENDENT SUBQUERY` 에서 `SUBQUERY` 로 변하면 적용된 것을 확인할 수 있다. derived materialize 와 별개의 카테고리다.

**원문 리소스**: [MySQL 8.0 Reference Manual, Optimizing Subqueries with Materialization](https://dev.mysql.com/doc/refman/8.0/en/subquery-materialization.html)

> "Materialization speeds up query execution by generating a subquery result as a temporary table, normally in memory."
>
> "The optimizer may index the table with a hash index to make lookups fast and inexpensive. The index contains unique values to eliminate duplicates and make the table smaller."
>
> "Subquery materialization uses an in-memory temporary table when possible, falling back to on-disk storage if the table becomes too large."

### Oracle: WITH clause (subquery factoring) — MATERIALIZE / INLINE

WITH 절의 query name 은 CBO 가 비용·재사용 횟수에 따라 inline view 로 풀어 쓰거나 cursor-duration temporary table 로 한 번만 계산해 둔다. 같은 경로는 star transformation 과 grouping sets 에서도 쓰인다.

**원문 리소스**: [Oracle Database SQL Language Reference 19c, SELECT — Subquery Factoring Clause](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/SELECT.html)

> "The `subquery_factoring_clause` lets you assign a name (`query_name`) to a subquery block. You can then reference the subquery block multiple places in the query by specifying `query_name`. Oracle Database optimizes the query by treating the `query_name` as either an inline view or as a temporary table."

---

## 정리

두 엔진 모두 두 개의 메커니즘 축으로 정리된다.

- **streaming 회피**: GROUP BY / ORDER BY / DISTINCT / UNION 처럼 의미상 "결과를 모아두지 않으면 답이 안 나오는" 단계는 인덱스 정렬 (Loose / Tight Index Scan, NOSORT plan) 로 streaming 이 가능한 경우에만 temp 를 피한다. 이 조건이 좁다는 점이 본문 2장 A 의 출발점이다.
- **merge / view merging**: derived table·view·CTE 는 외곽 query block 으로 평탄화 가능하면 별도 단계가 사라지고, 평탄화가 막히면 MySQL 은 internal temporary table, Oracle 은 cursor-duration temporary table 로 굳어진다. 굳어진 뒤에는 옵티마이저가 동적 인덱스 (MySQL) 또는 unique 이름의 temp segment (Oracle) 로 후속 access 비용을 결정한다 — 본문 2장 B 가 가리키는 지점이다.

두 메커니즘 모두 spill (work area / sort buffer 부족 시 강제 disk) 과 materialize (옵티마이저가 의도적으로 굳히는 전략) 라는 두 단계가 겹쳐 작동한다.
