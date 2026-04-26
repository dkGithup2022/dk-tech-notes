# dk-tech-notes

엔지니어링 노트. 작업 정리 글을 모아둔다.

블로그 사이트: <https://dkGithup2022.github.io/dk-tech-notes/>

## Posts

- [ES 노드 단위 처리량 한계 측정 — single-shard test 기반 샤드 사이징](es-shard-sizing.md)
- [RDBMS SQL 쿼리 튜닝 — 레거시 쿼리의 temp 테이블 원인·회피·검증](rdbms-temp-tuning.md)
  - [`rdbms-temp-tuning/deep-dive.md`](rdbms-temp-tuning/deep-dive.md) — MySQL 8.0 / Oracle 19c 메커니즘 비교
  - [`rdbms-temp-tuning/tuning_test/`](rdbms-temp-tuning/tuning_test/) — Docker 재현 환경, EXPLAIN 결과
    - [`report.md`](rdbms-temp-tuning/tuning_test/report.md) — 실험 결과 리포트
    - [`cases/`](rdbms-temp-tuning/tuning_test/cases/) — 실측 SQL 쿼리
    - [`explains/`](rdbms-temp-tuning/tuning_test/explains/) — EXPLAIN 원문
    - [`docker/`](rdbms-temp-tuning/tuning_test/docker/) — 재현 환경 (docker-compose)
- [`es-shard-sizing/`](es-shard-sizing/) — ES 포스트 첨부 이미지

## Theme

[just-the-docs](https://just-the-docs.com/) (remote_theme).
