# Architecture

## 큰 그림

Chaneling은 **GitOps** 방식으로 운영됩니다. 이 INFRA 레포의 Git 상태가 클러스터가 가져야 할 desired state이고, ArgoCD가 그걸 클러스터에 맞춥니다. 사람이 `kubectl apply`로 직접 배포하지 않습니다 — 커밋이 배포입니다.

```
개발자 → INFRA 레포 커밋 → ArgoCD(clusterk 감시) → 클러스터 반영
앱 개발자 → 앱 레포 커밋 → CI가 이미지 빌드 + INFRA image.tag 갱신 커밋 → ArgoCD → 배포
```

## 클러스터 토폴로지

OCI Always Free 티어의 **ARM64(Ampere A1.Flex)** 인스턴스 2대로 구성된 K3s 클러스터.

| | node-1 | node-2 |
|---|---|---|
| K3s 역할 | server (control-plane + etcd) | agent (worker) |
| 노드 라벨 | `role=data-tier` | `role=app-tier` |
| 사설 IP | 10.0.1.161 | 10.0.1.119 |
| 스펙 | 1 OCPU / 6GB (Ampere ARM) | 1 OCPU / 6GB |
| 고정 배치되는 것 | etcd, ArgoCD, **data**(postgres/kafka/redis), **monitoring**(loki/grafana) | **cloudflared**(platform, app-tier 고정) |

> **app 파드(spring/fastapi/sse/consumers)는 특정 노드 전용이 아님.** dev에선 `nodeSelector` 해제라 스케줄러가 **양 노드에 분산** 배치합니다(아래 트레이드오프 참고). promtail은 DaemonSet이라 모든 노드에 1개씩.

- **왜 계층 분리(data-tier / app-tier)?** 데이터(StatefulSet + PVC)는 노드 로컬 스토리지(`local-path`)를 쓰므로 노드 이동이 불가 → node-1에 고정. 앱은 상태가 없어 자유롭게 배치.
- **dev의 트레이드오프**: 노드가 2대(총 2 OCPU)뿐이라, dev에서는 app 파드가 `nodeSelector`를 풀어 **양 노드를 다 쓰게** 합니다(node-1 여유 CPU 활용). prod는 노드가 넉넉하면 `role=app-tier` 고정 유지.

## 네임스페이스

| 네임스페이스 | 차트 | 구성 | 노출 |
|---|---|---|---|
| `data` | helm/data | postgres(+pgvector), kafka(KRaft), redis — 전부 StatefulSet + PVC | 클러스터 내부 전용 |
| `monitoring` | helm/monitoring | loki(로그 저장), promtail(수집 DaemonSet), grafana(대시보드) | grafana만 터널로 |
| `app` | helm/chaneling | spring(BE API), fastapi(LLM), sse, consumer ×5 | spring만 터널로 |
| `platform` | helm/platform | cloudflared (Cloudflare 터널) | 아웃바운드 터널 |
| `argocd` | (cloud-init 설치) | ArgoCD 컴포넌트 | argocd-server만 터널로 |
| `kube-system` | K3s 기본 | coredns, metrics-server, local-path-provisioner | — |

## 서비스 간 통신 (클러스터 내부 DNS)

K8s CoreDNS가 `<service>.<namespace>.svc.cluster.local` 형식으로 Service를 자동 등록합니다. app 파드가 data 계층을 호출하는 예:

```
spring (app ns) ──▶ postgres.data.svc.cluster.local:5432
                ──▶ redis.data.svc.cluster.local:6379
                ──▶ kafka.data.svc.cluster.local:9092
spring ──▶ fastapi.app.svc.cluster.local:8000   (LLM 호출)
```

- 크로스 네임스페이스 호출이라 **FQDN**을 씀. app→data는 크로스 노드(node-2→node-1)이므로 flannel VXLAN 터널을 탐 → [networking.md](networking.md#flannel-vxlan) 참고.
- postgres는 일반 Service(`postgres`, ClusterIP)와 headless Service(`postgres-headless`, StatefulSet 안정 DNS) 두 개. 앱은 일반 Service를 호출.

## 데이터 흐름 (요청 → 리포트 생성)

```
프론트 → api-dev.chaneling.com (Cloudflare 터널) → spring(BE)
  → DB 저장 + Kafka 토픽 발행 (overview/analysis/idea/dashboard 등)
       │
       ▼
  consumer-*(fastapi 이미지 재사용) ── Kafka 구독 ──▶ LLM 처리(fastapi/OpenAI)
       │                                              → 결과 DB 저장 + result 토픽
       ▼
  spring이 result 구독 → 프론트에 반영 (SSE로 실시간 푸시도)
```

- **fastapi**: 동기 LLM API (spring이 호출).
- **consumer ×5**: Kafka 기반 비동기 워커. fastapi와 **같은 `chaneling-llm` 이미지**를 쓰되 entrypoint만 다름(`kafka_<name>_consumer.py`). 종류: overview, analysis, idea, dashboard, recommend.
- **sse**: Server-Sent Events 실시간 푸시 전용 (별도 Spring 앱).

## 배포 순서 (ArgoCD sync-wave)

```
wave 5  data        (postgres/kafka/redis 먼저 떠야 앱이 붙음)
wave 6  monitoring
wave 10 chaneling-app  (data 준비 후)
wave 15 platform    (cloudflared, 서비스들 준비된 뒤 노출)
```

ArgoCD는 cloud-init이 설치 → **root Application(app-of-apps)** 이 나머지 Application들을 자동 등록 → 각자 담당 차트를 sync.

**env별 분리**: `argocd/apps/`는 `dev/`·`prod/` 폴더로 나뉘고, 각 클러스터의 root는 **자기 환경 폴더만** 가리킵니다(cloud-init이 `path=argocd/apps/${env_name}`로 설정). 즉 **dev 클러스터엔 -dev 앱만, prod 클러스터엔 -prod 앱만** 뜹니다 — 클러스터 분리 원칙과 일치. (한 클러스터에 두 환경 앱이 뜨면 같은 네임스페이스를 두고 충돌하므로 반드시 분리.)

## dev vs prod

| | dev | prod |
|---|---|---|
| 브랜치 | `dev` | `main` |
| valueFiles | values.yaml + values-dev.yaml | values.yaml + values-prod.yaml |
| 이미지 태그 | `dev-<sha>` (CI 자동 갱신) | release semver |
| nodeSelector | 해제(null, 양 노드 사용) | `role=app-tier` 고정 |
| 리소스 | 축소(CPU request 작게) | 여유 |
| 프론트 도메인 | dev.chaneling.com | chaneling.com |

## 주요 설계 결정과 이유

- **K3s(경량) + OCI Always Free**: 비용 0으로 실운영급 GitOps 학습/운영. 대신 2 OCPU 제약 → 리소스 튜닝·startupProbe·nodeSelector 전략 필요.
- **ArgoCD app-of-apps**: 클러스터 재생성 시 root Application 하나만 심으면 전체가 복원됨.
- **불변 이미지 태그(dev-sha)**: mutable `latest`는 ArgoCD가 diff를 못 봐 자동 배포가 안 됨 → sha 태그를 image.tag에 커밋해야 배포가 트리거됨. [cicd.md](cicd.md) 참고.
- **Cloudflare 터널**: 인바운드 포트(80/443)를 안 열고 아웃바운드 터널로만 노출 → 공격면 축소.
- **v1/v2 분리**: 기존 prod(v1)는 AWS EC2 ASG + `channeling-*`(n 2개) 이미지. v2는 이 K8s 클러스터 + `chaneling-*`(n 1개) 이미지. 이름/인프라가 완전히 분리돼 공존.
