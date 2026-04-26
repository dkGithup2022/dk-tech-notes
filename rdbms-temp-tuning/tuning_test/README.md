---
title: "테스트 환경 셋업"
parent: "RDBMS SQL 쿼리 튜닝 — temp 테이블 회피"
nav_order: 3
permalink: /rdbms-temp-tuning/tuning-test-setup/
---

# tuning_test — 본문 회피 패턴 검증 환경
{: .no_toc }

해당 테스트는 docker 와 스크립트 설치 후 로컬에서 재현할 수 있습니다.

링크: <https://github.com/dkGithup2022/dk-tech-notes/tree/main/rdbms-temp-tuning/tuning_test>

## 목차
{: .no_toc .text-delta }

1. TOC
{:toc}

본문([RDBMS SQL 쿼리 튜닝]({{ "/rdbms-temp-tuning/" | relative_url }})) 회피 패턴을 MySQL 8.0.31 에서 BEFORE/AFTER 비교 가능한 쿼리로 재현.

## 본문 매핑

| 본문 위치 | 케이스 | 핵심 변화 |
|---|---|---|
| 3.1 근원 회피 (인덱스 추가) | Case F (`05-case-f.sql`) | `Using temporary` → `Using index` |
| 3.2 temp 크기 줄이기 (id 선행 확정) | Case D (`03-case-d.sql`) | `DEPENDENT SUBQUERY × 3` → `DERIVED × 2` + hash join |
| 3.3 2단계 분리 (SUM 스냅샷 + VALUES) | Case G (`07-case-g1.sql`, `08-case-g2.sql`) | `DEPENDENT SUBQUERY` 제거 + `PRIMARY KEY` lookup |

상세 측정 결과·인사이트는 [튜닝 테스트 리포트]({{ "/rdbms-temp-tuning/tuning-test-report/" | relative_url }}) 에 정리.

## 폴더 구조

```
tuning_test/
├── README.md                — (이 파일) 환경 셋업·실행 방법
├── report.md                — 측정 결과·해석
├── docker/
│   ├── docker-compose.yml
│   └── init/                — MySQL 최초 기동 시 자동 실행
│       ├── 01-schema.sql    — 9 테이블 + 인덱스
│       └── 02-data-gen.sql  — 데이터 (cartesian product 기반)
├── cases/
│   ├── 03-case-d.sql        — 3.2 검증
│   ├── 04-case-e.sql        — 구 3.3 (AVG 배송 지연, IN 리터럴). Case G 로 대체됨
│   ├── 05-case-f.sql        — 3.1 검증
│   ├── 06-case-e2.sql       — Case E 의 WHERE 보강 변형 (참고용)
│   ├── 07-case-g1.sql       — 3.3 검증 (HAVING > 50, 희소 매칭 0 rows)
│   └── 08-case-g2.sql       — 3.3 검증 (HAVING > 5, 정상 매칭)
└── explains/                — raw EXPLAIN 출력 (.txt)
```

## 스키마 (9 테이블)

| 테이블 | rows | 비고 |
|---|---|---|
| categories | 50 | self-reference `parent_id` |
| suppliers | 100 | |
| warehouses | 5 | |
| products | 10,000 | |
| users | 2,000 | |
| orders | 5,000 | |
| order_items | 15,000 | |
| shipments | **10,000** | `status` 컬럼에 **인덱스 의도적으로 누락** (Case F) |
| reviews | 20,000 | |

10만 건 확장은 `02-data-gen.sql` 의 `WHERE n < ...` 상한만 올리면 된다. cartesian product 기반이라 100,000 도 무리 없음.

## 실행

```bash
# 1. 기동 (최초 시 MySQL 이미지 pull + 초기화 스크립트 자동 실행)
cd rdbms-temp-tuning/tuning_test/docker
docker compose up -d

# 2. 로그로 초기화 완료 확인 (데이터 생성까지 1~2분)
docker compose logs -f mysql-tuning

# 3. 접속
docker exec -it mysql-tuning-test mysql -uroot -ptestpw tuning

# 4. row count 검증
mysql> SELECT 'products' t, COUNT(*) FROM products
    -> UNION ALL SELECT 'shipments', COUNT(*) FROM shipments
    -> UNION ALL SELECT 'reviews',   COUNT(*) FROM reviews;
```

## Case 실행 (EXPLAIN 캡처)

본문에서 인용하는 3 케이스 (D / F / G) 가 핵심:

```bash
# Case F (3.1 근원 회피)
docker exec -i mysql-tuning-test mysql -uroot -ptestpw tuning \
  < ../cases/05-case-f.sql > ../explains/case-f.txt 2>&1

# Case D (3.2 id 선행 확정)
docker exec -i mysql-tuning-test mysql -uroot -ptestpw tuning \
  < ../cases/03-case-d.sql > ../explains/case-d.txt 2>&1

# Case G-2 (3.3 2단계 분리, 정상 매칭) — BEFORE 가 약 5분 소요
docker exec -i mysql-tuning-test mysql -uroot -ptestpw tuning \
  < ../cases/08-case-g2.sql > ../explains/case-g2.txt 2>&1
```

`07-case-g1.sql` (희소 매칭, BEFORE 결과 0 rows 임에도 5분) 은 **"BEFORE 비용은 결과 매칭 수가 아니라 검사 횟수가 지배"** 인사이트 검증용 — 시간이 있을 때 선택 실행.

## 관찰 포인트

### Case F (3.1)
- BEFORE: `type=ALL, key=NULL, Extra: Using temporary` (status 인덱스 부재)
- AFTER: `type=index, key=idx_status, Extra: Using index` (covering scan)

### Case D (3.2)
- BEFORE: 3개 `DEPENDENT SUBQUERY` 가 products 각 row 마다 재평가. `loops=800` × 내부 lookup `loops=8,000,000`
- AFTER: `DERIVED × 2` (materialize 1회씩) + hash join 으로 조립

### Case G (3.3)
- BEFORE: 외곽 `oi type=ALL, key=NULL` (풀스캔) + 안쪽 `DEPENDENT SUBQUERY` (HAVING SUM, `loops=15,000`, 내부 nested loop `loops=225,000,000`)
- AFTER 1단계: SUM 스냅샷 획득. `Index scan + Group aggregate`
- AFTER 2단계: VALUES 주입 → `p`, `c` `PRIMARY KEY` lookup. 안쪽 서브쿼리 사라짐

## 포트·설정

- 호스트 포트 `13306` 사용 (기본 3306 충돌 회피)
- `tmp_table_size=16M` / `max_heap_table_size=16M` 의도적으로 작게 — 디스크 이관 관측 용이
- `cte_max_recursion_depth=1000000` — 데이터 생성 확장 대비

## 종료·정리

```bash
cd rdbms-temp-tuning/tuning_test/docker
docker compose down           # 컨테이너만 제거, 데이터 유지
docker compose down -v        # 볼륨까지 제거 (재초기화 원할 때)
```
