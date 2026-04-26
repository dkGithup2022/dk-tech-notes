---
title: "ES 노드 처리량 한계 측정 — 샤드 사이징"
nav_order: 2
permalink: /es-shard-sizing/
---

# ES 노드 단위 처리량 한계 측정 — single-shard test 기반 샤드 사이징
{: .no_toc }

## 목차
{: .no_toc .text-delta }

1. TOC
{:toc}


Cafe24 상품 검색 시스템 개발 과정에서 진행한 퍼포먼스 튜닝 작업의 정리입니다.

작업 시점과 작성 시점의 시간 차이가 크기 때문에, 사내 실제 데이터나 환경보다는 재현 가능한 기술적 인사이트에 초점을 맞춥니다.

---

## 1. 작업 개요

탑다운 1,000 QPS 목표를 받은 상품 검색용 신규 ES 클러스터에서, single-shard test 로 노드 단위 처리량 한계를 측정하고 그 임계 미만으로 샤드를 사이징.

**결과: 단일 노드 처리량을 4배 이상 (약 500 → 2,000+ QPS, P95 latency SLO 기준 안정 구간) 으로 확장.**

- **환경**: 단일 인덱스 2,000만+ 문서, 전체 상품 1억+ 규모, Clickhouse → ES 데이터 파이프라인 위
- **흐름**: single-shard test (es-rally + 실 검색어 사전 + populating) 로 임계 곡선 측정 → 임계 미만으로 샤드 사이즈 결정 → 데이터 노드 안 배치 가능 여부 → 불가 시 노드 증설의 정량 근거

> 본문은 작업 순서대로 두고, 개념과 공식 자료는 3장에 모았다. 본문 각 단계에서 필요한 지점마다 해당 항목으로 링크를 건다.

---

## 2. 수행 작업

다른 퍼포먼스 튜닝 — 데이터 타입 보정, 검색에 쓰지 않는 리소스(URL 등) noindex 처리 등 — 은 2~5% 향상에 그쳤다. 물리적 병목 제거 이후에야 indexing/query 양쪽에서 2~3배 향상이 관찰됐다. **본 글은 샤드 사이즈 조절을 통한 물리적 병목 제거에 초점을 둔다.** indexing 쪽은 같은 클러스터의 색인 부하 측정으로 별도 확인했고, 본 글은 검색 측에 집중한다.

### 2.1 병목 진단

데이터 노드 CPU 90% 이상, 다른 자원 20% 미만 — 병목이 원인인 데이터 노드임을 확인.

ES 7의 샤드-쓰레드 1:1 모델([→ 3.1 샤드 사이즈에 따른 퍼포먼스 하락](#31-샤드-사이즈에-따른-퍼포먼스-하락))을 떠올려, 샤드 1개의 처리량 한계를 직접 잡는 쪽으로 좁혔다.

### 2.2 Single-shard 임계 측정

샤드 1개가 어느 데이터량부터 무너지는지를 직접 잡기 위해, 실 운영과 동등한 분포·부하 위에서 데이터량을 단계적으로 키웠다.

- 인덱스 구성 — primary 1 / secondary 0 (노드/샤드 외 변수를 제거해 노드 단위 한계만 분리해 측정)
- 데이터 분포 — 실 운영 데이터 사전 기반으로 populating, 분포·크기 모사
- 부하 — es-rally(Elastic 공식 벤치마크 도구) + 실 검색어 사전 + 5단어 이상 보수 케이스 ([→ 3.2 테스트 환경 생성 주의 사항](#32-테스트-환경-생성-주의-사항))
- 부하 패턴 — 꾸준 부하 위에 QPS를 계단식으로 올리며, 각 단계가 P95 latency SLO 안에 들어오는지 본다 (SLO 임계값은 사내 기준이라 비공개)
- 관찰 곡선 (재현값):

| 환경 | 단일 노드 처리량 (재현값) |
|---|---|
| 임계 이하 — 인덱스 약 1,000개 문서, primary shard 5개 기준 | 5,000+ QPS |
| 임계 초과 (계단식 절벽, 테스트 이전) — 인덱스 약 1억 개 문서, primary shard 5개 기준 | 100~200 QPS |

위 표는 single-shard test로 잡은 임계가 5-shard 운영 환경에서 어떻게 드러나는지 비교한 측정값이다.

### 2.3 샤드 사이즈/노드 배치 결정

측정한 임계점이 그대로 사이즈 상한과 노드 증설 근거로 변환된다.

- 임계 미만으로 샤드 사이즈를 결정한다
- 그 사이즈로 데이터 노드 안에 배치 가능한지 본다
- 배치가 불가하면 노드 증설을 측정 기반의 정량 근거로 제안한다

결과: P95 SLO 기준 단일 노드 처리량이 약 500 → 2,000~2,200 QPS 안정 구간으로 확장됐다.

> 인덱스 매핑 / 분석기 / refresh interval 등은 본 작업과 별개 축이다. refresh interval은 본 측정에서 결과에 유의미한 영향을 주지 않았다.

---

## 3. 개념 정리 (참조)

### 3.1 샤드 사이즈에 따른 퍼포먼스 하락

ES의 인덱스는 샤드라는 논리 구조로 이루어진다. ES 7 버전까지의 읽기/쓰기 연산은 쓰레드 1개가 1개의 샤드 단위로 수행되며, 따라서 샤드 1개의 연산이 딜레이되면 그대로 전체 throughput 감소로 이어진다.

여기에 더해, 한 샤드를 RAM 위에 다 올리지 못해 disk IO가 발생하면 계단식 성능 하락이 포착된다. 앞서 적은 indexing/query 양쪽 2~3배 향상은 이 메커니즘과 연관되어 있음을 추측한다.

ES 8 버전에서도 이 메커니즘이 동일하게 통하는지는 별도 테스트가 필요하다.

추가로 index/shard/segment, 물리적 연산 순서(flush, merge) 등의 internal 구조는 2년 전에 정리해 둔 자료가 있다.
참고: [`es_internal_arcchitecture_and_lucene`](https://github.com/dkGithup2022/es_internal_arcchitecture_and_lucene)

---

근거 리소스 (중요도 순)

**disk IO 계단식 절벽 시각화** — Adrien Grand "What is in a Lucene index?" (Lucene Revolution 2013) 발표 슬라이드.

![What is happening here? — Adrien Grand]({{ "/es-shard-sizing/whatis_lucene.png" | relative_url }})

> *이미지 출처: Adrien Grand, "What is in a Lucene index?" (Lucene Revolution 2013, [SpeakerDeck](https://speakerdeck.com/elasticsearch/what-is-in-a-lucene-index)).*
> *그림은 단일 Lucene 인덱스가 페이지 캐시 한도를 넘을 때 stored fields → terms dict/postings 순으로 두 절벽이 발생함을 보여준다.*

### 3.2 테스트 환경 생성 주의 사항

실 환경과 맞추는 게 우선이다. 데이터(인덱싱)와 검색어 두 축 모두 실 분포에서 벗어나면 성능이 실제보다 좋게 나온다.

**데이터 관점.** indexing된 문서의 토큰 분포가 단순하면 데이터 노드 연산이 가벼워져 성능이 실제보다 좋게 나온다. 같은 데이터를 복사해 양만 불리는 방식은 안 쓴다.\* 사내 샘플링 데이터를 우선 쓰고, 양이 부족하면 오픈소스 학습용 단어집으로 분포를 불린다.

> \* 토큰은 trie로 관리되어 데이터 양이 늘어도 토큰 사전이 무한히 커지지는 않는다. 다만 제한된 데이터 셋의 토큰 사전은 10MB도 못 넘는 반면 실 운영은 수백 MB 수준이라, 분포 차이가 너무 크면 성능이 실제보다 좋게 나온다.

**검색어 관점.** 검색어 토큰 수가 많을수록 analyzing 단계의 부하가 비례해 커진다. 그래서 테스트 검색어는 실 검색어와 같거나 더 길게 잡는다 — 더 짧게 하면 성능이 실제보다 좋게 나온다. 본 서비스 평균 검색어가 2~3단어(예: "빨간 바지")여서, 본 작업에서는 5단어 이상의 자연어 쿼리로 잡았다.

analyzing 과정의 자세한 메커니즘은 별도로 정리해 둔 자료가 있다.
참고: [`es_search_concept_of_search_technique`](https://github.com/dkGithup2022/es_search_concept_of_search_technique)

---

## 4. 레퍼런스

본 작업의 원 출처는 아래 두 책입니다. 본문 안의 인용은 글 작성 과정에서 확인한 공식 문서를 별도로 분리해 둡니다.

**원 출처 (책)**
- [기초부터 다지는 ElasticSearch 운영 노하우](https://ebook-product.kyobobook.co.kr/dig/epd/ebook/E000003160863)
- [엘라스틱서치 실무 가이드](https://product.kyobobook.co.kr/detail/S000001766375)

**Elasticsearch 공식**
- [Size your shards](https://www.elastic.co/docs/deploy-manage/production-guidance/optimize-performance/size-shards) — 샤드 단일 스레드, 양방향 제약, 권장 사이즈, 벤치마크 권장, "샤드 = 단일 Lucene 인덱스"
- [Tune for search speed](https://www.elastic.co/guide/en/elasticsearch/reference/current/tune-for-search-speed.html) — filesystem cache가 검색 성능 1순위
- [Elasticsearch 8.12 Release Highlights](https://www.elastic.co/guide/en/elasticsearch/reference/8.12/release-highlights.html) — Concurrent Segment Search 기본 활성화 (본 작업 이후 변화)
- [Rally — 공식 벤치마크 도구](https://esrally.readthedocs.io)

**외부 발표 자료**
- [Adrien Grand, "What is in a Lucene index?" (Lucene Revolution 2013)](https://speakerdeck.com/elasticsearch/what-is-in-a-lucene-index) — 인덱스 단위 페이지 캐시 절벽 곡선 (본문 인용 이미지)

**자체 자료**
- [`es_internal_arcchitecture_and_lucene`](https://github.com/dkGithup2022/es_internal_arcchitecture_and_lucene) — ES 내부 구조와 Lucene 연산 deep-dive
