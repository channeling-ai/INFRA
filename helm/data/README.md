# data 차트 (data 네임스페이스)

상태를 가지는 데이터 계층. 전부 **StatefulSet + PVC**이며 **node-1(`role=data-tier`)에 고정**됩니다.

## 배포 대상

| 컴포넌트 | 이미지 | 포트 | 설명 |
|---|---|---|---|
| **postgres** | pgvector/pgvector:pg17 | 5432 | PostgreSQL 17 + **pgvector**(임베딩). 일반 Service + headless Service |
| **kafka** | apache/kafka | 9092 | KRaft 단일 노드(combined controller+broker) |
| **redis** | redis:7-alpine | 6379 | 캐시/세션 |

각 Service DNS: `postgres.data.svc.cluster.local` 등. 앱은 일반 Service(ClusterIP)를 호출.

## 왜 node-1 고정인가

- 스토리지가 K3s `local-path`(노드 로컬) → PVC가 특정 노드에 묶임 → 노드 이동 불가 → `nodeSelector: role=data-tier`로 node-1 고정.
- **트레이드오프**: 단일 노드라 node-1이 죽으면 데이터 접근 불가. dev 한정 감수(백업은 etcd만; DB 데이터 백업은 별도 전략 필요).

## 주요 values

| 키 | 의미 |
|---|---|
| `postgres.enabled` / `redis.enabled` / `kafka.enabled` | on/off |
| `postgres.image.repository/tag` | **pgvector/pgvector:pg17** (일반 postgres 아님 — pgvector 확장 필요) |
| `postgres.database/user` | 초기 DB/유저(첫 부팅 시 자동 생성). 비번은 시크릿 `PG_PASSWORD` |
| `*.persistence.size` | PVC 크기 (dev 축소) |
| `*.resources` | requests/limits |
| `kafka.clusterId` | KRaft cluster ID. **한 번 정하면 변경 금지** |
| `global.nodeSelector` | `role: data-tier` (node-1) |
| `secrets.existingSecret` | `chaneling-secrets` (PG_PASSWORD 등 참조) |

## 왜 pgvector 이미지인가

앱의 Flyway 마이그레이션에 `CREATE EXTENSION vector`가 있음. 순정 `postgres:17`엔 pgvector가 없어 마이그레이션 실패 → `pgvector/pgvector:pg17`(postgres 17 기반 + pgvector 프리인스톨, 드롭인 호환) 사용. PGDATA/PVC 그대로 호환.

## 사전 준비

`chaneling-secrets` 시크릿에 최소 `PG_PASSWORD` 필요(data ns). → [operations.md](../../docs/operations.md#사전-준비물-배포-전-필수).

## 로컬 렌더

```bash
helm template data . -f values.yaml -f values-dev.yaml
```
