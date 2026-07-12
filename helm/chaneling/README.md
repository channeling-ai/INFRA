# chaneling 차트 (app 네임스페이스)

애플리케이션 계층. Chaneling v2의 백엔드/LLM/실시간/워커를 배포합니다.

## 배포 대상

| 컴포넌트 | 이미지 | 포트 | 설명 |
|---|---|---|---|
| **spring** | hadoroke/chaneling-be | 8080 | 백엔드 API (Vercel 프론트가 호출) |
| **fastapi** | hadoroke/chaneling-llm | 8000 | LLM 동기 API (spring이 호출) |
| **sse** | hadoroke/chaneling-sse | 8081 | Server-Sent Events 실시간 푸시 |
| **consumer × 5** | hadoroke/chaneling-llm | — | Kafka 비동기 워커 (fastapi 이미지 재사용, entrypoint만 다름) |

consumer 종류: `overview`, `analysis`, `idea`, `dashboard`, `recommend` (각 `kafka_<name>_consumer.py`). Service 없음(Kafka가 라우팅, 인바운드 호출 없음).

## 외부 노출

spring만 Cloudflare 터널로 노출(`api-dev.chaneling.com`). fastapi/sse/consumer는 클러스터 내부 전용.

## 주요 values

| 키 | 의미 |
|---|---|
| `<svc>.enabled` | 컴포넌트 on/off (이미지 미빌드 시 임시 false 가능) |
| `<svc>.replicaCount` | 레플리카 수 |
| `<svc>.image.tag` | **CI가 자동 갱신** (dev-<sha>). 수동 수정 지양 |
| `<svc>.resources` | requests/limits (dev는 축소) |
| `<svc>.probes` | startup/liveness/readiness (아래 참고) |
| `config.*` | 외부 서비스 주소(pgHost 등), 프로파일, 도메인, region |
| `consumer.<name>` | 컨슈머별 enabled/replicaCount/command |

DB/Redis/Kafka 주소는 `config.pgHost` 등에서 FQDN으로 지정(`postgres.data.svc.cluster.local`).

## 새 컨슈머 추가하는 법

1. `values.yaml`의 `consumer:` 밑에 블록 추가:
   ```yaml
   consumer:
     <name>:
       enabled: true
       replicaCount: 1        # dev는 CPU 빡빡하니 1로 시작
       command: ["python", "kafka_<name>_consumer.py"]
   ```
2. `templates/consumer-<name>-deployment.yaml` 추가 (기존 `consumer-overview-deployment.yaml` 복사 후 `overview`→`<name>` 치환).
3. 렌더 검증: `helm template chaneling . -f values.yaml -f values-dev.yaml | grep consumer-<name>`.

## 설계 노트 (트레이드오프)

- **nodeSelector**: dev는 `values-dev.yaml`에서 `global.nodeSelector: null`로 해제(양 노드 사용). ⚠️ `{}`(빈 맵)로 하면 Helm 딥머지가 base의 `role=app-tier`를 못 지움 → 반드시 `null`. 템플릿은 `{{- with }}` 가드.
- **probes**: JVM(spring/sse)은 기동이 느려(CPU 굶주린 노드에서 90s+) **startupProbe**로 기동 대기를 분리 → 기동 중 kill 방지. liveness/readiness는 `timeoutSeconds: 5`.
- **프로파일**: `config.springProfilesActive`는 spring/sse 공통. 앱은 `application-{db,s3,oauth,jwt}.yml`을 프로파일로 로드하므로 이 값이 정확해야 함.
- **env 주입**: 공통 env는 `templates/_helpers.tpl`의 `commonEnv`(DB/Redis/Kafka/JWT), `springExtraEnv`(S3/OAuth/프로파일), `llmEnv`(OpenAI/SerpAPI 등). 앱이 새 env를 요구하면 여기 추가.

## 로컬 렌더 (검증)

```bash
helm template chaneling . -f values.yaml -f values-dev.yaml
helm lint . -f values.yaml -f values-dev.yaml
```
