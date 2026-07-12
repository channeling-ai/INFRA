# INFRA

Chaneling(v2) 서비스의 쿠버네티스 기반 인프라 레포. **Terraform**으로 OCI에 K3s 클러스터를 프로비저닝하고, **ArgoCD**로 Git 상태를 클러스터에 동기화하는 **GitOps** 구조입니다.

> 한 줄 요약: 이 레포의 Git = 클러스터의 desired state. 여기 커밋하면 ArgoCD가 자동 배포합니다.

---

## 아키텍처

```
                 사용자 / Vercel 프론트
                        │ HTTPS
                        ▼
                 Cloudflare 엣지  ── TLS 종료
                        │ (아웃바운드 터널, 인바운드 포트 안 엶)
                        ▼
        ┌──────────────────  OCI VCN (10.0.0.0/16) ──────────────────┐
        │  node-1 (server, data-tier)        node-2 (agent, app-tier)  │
        │  ┌───────────────────────────┐   ┌───────────────────────┐  │
        │  │ k3s control-plane + etcd  │   │ cloudflared (터널)     │  │
        │  │ ArgoCD                    │   │  (app-tier 고정)       │  │
        │  │ postgres/kafka/redis(data)│   └───────────────────────┘  │
        │  │ loki · grafana (monitoring)│                              │
        │  └───────────────────────────┘  ← node-1 고정(PVC/etcd)     │
        │                                                             │
        │  ┌── app 워크로드 : dev는 nodeSelector 해제 → 양 노드 분산 ──┐ │
        │  │  spring · fastapi · sse · consumers ×5                   │ │
        │  │        (app ns) — 스케줄러가 node-1·node-2 둘 다 사용     │ │
        │  └──────────────────────────────────────────────────────────┘ │
        │  promtail = DaemonSet(모든 노드)                              │
        │        ◀──── flannel VXLAN (UDP 8472) 크로스노드 파드망 ────▶  │
        └─────────────────────────────────────────────────────────────┘
            OCI A1.Flex ARM64 · 1 OCPU/6GB × 2 · Ubuntu 22.04 · K3s v1.30.5

  * data(postgres/kafka/redis)·etcd·ArgoCD·loki·grafana = node-1 고정.
    app 파드는 dev에서 양 노드에 흩어짐(prod는 role=app-tier로 node-2 고정).
    cloudflared는 platform 차트라 dev에서도 app-tier(node-2) 유지.
```

자세한 내용은 [docs/architecture.md](docs/architecture.md).

## 기술 스택

| 영역 | 사용 기술 |
|---|---|
| IaC / 프로비저닝 | Terraform (OCI provider), cloud-init |
| 클러스터 | K3s v1.30.5 (embedded etcd), flannel CNI |
| 배포 | ArgoCD (app-of-apps), Helm |
| 호스팅 | Oracle Cloud (OCI Always Free, A1.Flex ARM) |
| 데이터 | PostgreSQL 17 + pgvector, Apache Kafka (KRaft), Redis 7 |
| 관측 | Loki + Promtail + Grafana |
| 네트워크 노출 | Cloudflare Tunnel (cloudflared) |
| CI/CD | GitHub Actions → 이미지 빌드/푸시 → 이 레포 image.tag 갱신 → ArgoCD |
| 백업 | etcd 스냅샷 → OCI Object Storage (6h 주기) |

## 레포 구조

```
INFRA/
├── terraform/          # OCI 인스턴스·VCN·보안리스트, K3s 부트스트랩 (cloud-init)
├── helm/               # 네임스페이스별 Helm 차트
│   ├── chaneling/      # app ns: spring / fastapi / sse / consumers
│   ├── data/           # data ns: postgres / kafka / redis
│   ├── monitoring/     # monitoring ns: loki / grafana / promtail
│   └── platform/       # platform ns: cloudflared 터널
├── argocd/apps/        # app-of-apps: 각 차트를 가리키는 ArgoCD Application
│   ├── dev/            #   dev 클러스터가 등록 (root path=argocd/apps/dev)
│   └── prod/           #   prod 클러스터가 등록 (root path=argocd/apps/prod)
├── docs/               # 아키텍처·CI/CD·네트워크·운영·트러블슈팅 문서
└── README.md
```

## 네임스페이스 & 배포 순서

ArgoCD **sync-wave**로 의존성 순서를 강제합니다 (낮은 번호 먼저).

| wave | ArgoCD App | 네임스페이스 | 차트 | 내용 |
|---|---|---|---|---|
| 5 | data | `data` | helm/data | postgres·kafka·redis (StatefulSet, node-1 고정) |
| 6 | monitoring | `monitoring` | helm/monitoring | loki·grafana·promtail |
| 10 | chaneling-app | `app` | helm/chaneling | spring·fastapi·sse·consumers |
| 15 | platform | `platform` | helm/platform | cloudflared 터널 |

- **dev** = `dev` 브랜치, **prod** = `main` 브랜치 (같은 차트, valueFile/branch만 다름)
- ArgoCD 자체는 cloud-init이 설치하고, `argocd/apps/`의 root Application이 나머지를 자동 등록

## 빠른 시작 (dev 클러스터 신규 생성)

```bash
# 1. OCI CLI 설정 (최초 1회)
oci setup config

# 2. 변수 파일 작성
cd terraform
cp dev.tfvars.example dev.tfvars
$EDITOR dev.tfvars   # tenancy_ocid, compartment_ocid, ssh_public_key, k3s_token 등

# 3. Terraform 적용 (VCN + 인스턴스 2대 + cloud-init로 K3s/ArgoCD 자동 설치)
terraform init
terraform plan  -var-file=dev.tfvars
terraform apply -var-file=dev.tfvars

# 4. kubeconfig 가져오기 (apply output에 명령이 그대로 출력됨)
ssh ubuntu@<server-public-ip> sudo cat /etc/rancher/k3s/k3s.yaml \
  | sed "s/127.0.0.1/<server-public-ip>/" > ~/.kube/config-oci-dev
export KUBECONFIG=~/.kube/config-oci-dev
kubectl get nodes            # node-1, node-2 Ready 확인

# 5. ArgoCD가 git에서 앱 자동 동기화 (~5분). 진행 상황:
kubectl get applications -n argocd
```

배포 전 준비물(시크릿·터널)은 [docs/operations.md](docs/operations.md), 문제 발생 시 [docs/troubleshooting.md](docs/troubleshooting.md).

## 환경

- **dev**: 2 노드 (OCI Always Free, 각 1 OCPU/6GB), etcd 백업 6시간 주기, image tag = `dev-<git sha>`
- **prod**: 동일 구조, image tag = release semver (별도 클러스터, `main` 브랜치)

## 문서

| 문서 | 내용 |
|---|---|
| [docs/architecture.md](docs/architecture.md) | 노드·네임스페이스 구성, 데이터 흐름, 설계 결정과 트레이드오프 |
| [docs/cicd.md](docs/cicd.md) | GitOps 이미지 배포 흐름, 각 앱 레포 CI, 태그 규칙 |
| [docs/networking.md](docs/networking.md) | Cloudflare 터널, flannel VXLAN, DNS, argocd insecure |
| [docs/operations.md](docs/operations.md) | 런북: 시크릿 생성, 터널 세팅, sync/롤백, 백업 |
| [docs/troubleshooting.md](docs/troubleshooting.md) | 자주 겪는 장애와 해결 |

차트별 상세는 각 `helm/*/README.md`, 프로비저닝은 [terraform/README.md](terraform/README.md).
