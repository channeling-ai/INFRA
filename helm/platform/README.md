# platform 차트 (platform 네임스페이스)

Cloudflare Tunnel(cloudflared)만 운영. 클러스터를 **인바운드 포트 없이** 외부에 노출하는 진입점.

## 배포 대상

| 컴포넌트 | 종류 | 설명 |
|---|---|---|
| **cloudflared** | Deployment (2 replica) | Cloudflare로 아웃바운드 터널 유지, hostname→내부 Service 라우팅 |

## 동작

```
사용자 → Cloudflare 엣지(TLS 종료) → 터널 → cloudflared 파드 → K8s Service
```
인바운드 80/443을 안 엶. cloudflared가 Cloudflare로 아웃바운드 연결을 맺고 트래픽을 받음.

## 방식: locally-managed 터널

- 터널 UUID + `credentials.json`을 CLI로 발급받아 씀. **ingress 규칙은 이 차트의 ConfigMap(`config.yaml`)** 에 둠 → Git 버전 관리.
- 대시보드 Zero Trust UI(remotely-managed, 토큰 방식)는 **안 씀**.

## 주요 values (`values-dev.yaml`)

| 키 | 의미 |
|---|---|
| `cloudflared.tunnelId` | 터널 UUID (`cloudflared tunnel create` 출력값) |
| `cloudflared.credentialsSecret` | credentials.json 담은 Secret 이름 (`cloudflared-credentials`) |
| `cloudflared.ingress` | hostname → Service 매핑 목록. **마지막 catch-all(`http_status:404`) 필수** |
| `cloudflared.replicaCount` | HA용 (기본 2, antiAffinity로 노드 분산) |

## 세팅 절차 (요약)

```bash
cloudflared tunnel login
cloudflared tunnel create chaneling-dev            # UUID + ~/.cloudflared/<UUID>.json
cloudflared tunnel route dns chaneling-dev api-dev.chaneling.com   # (grafana-dev, argocd-dev도)
kubectl create secret generic cloudflared-credentials -n platform \
  --from-file=credentials.json=$HOME/.cloudflared/<UUID>.json
# values-dev.yaml tunnelId 갱신 후 커밋 → ArgoCD sync
```
전체 절차/함정은 [operations.md](../../docs/operations.md#cloudflare-터널-세팅), [networking.md](../../docs/networking.md#cloudflare-tunnel-cloudflared).

## ⚠️ 알아둘 것

- **하이픈 단일 단계 서브도메인** 사용(`api-dev.chaneling.com`). 무료 인증서가 2단계(`*.dev.chaneling.com`)를 커버 못 함.
- ingress에 `argocd-dev`가 있으면 argocd-server를 **insecure 모드**로 해야 리다이렉트 루프가 안 남(cloud-init에 반영).
- 파드가 `ContainerCreating`에서 멈추면 `cloudflared-credentials` Secret 확인.

## 로컬 렌더

```bash
helm template platform . -f values.yaml -f values-dev.yaml | grep -A20 config.yaml
```
