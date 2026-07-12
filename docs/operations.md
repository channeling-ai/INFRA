# Operations (런북)

## 클러스터 접속

```bash
export KUBECONFIG=~/.kube/config-oci-dev
kubectl get nodes
```
kubeconfig가 없으면 [README 빠른 시작](../README.md#빠른-시작-dev-클러스터-신규-생성) 4번 참고.

노드 SSH: `ssh -i ~/.ssh/id_ed25519_oci ubuntu@<public-ip>` (node-1/node-2 공인 IP는 `terraform output`).

## 사전 준비물 (배포 전 필수)

ArgoCD가 차트를 sync해도, 아래 시크릿이 없으면 파드가 안 뜹니다(Secret 마운트 실패로 ContainerCreating).

### 1. 앱 시크릿 `chaneling-secrets` (app + data ns가 참조)

포함 키: `PG_PASSWORD`, `JWT_SECRET`, `OPENAI_API_KEY`, `GOOGLE_CLIENT_ID/SECRET/REDIRECT_URI`, `AWS_ACCESS_KEY_ID/SECRET_ACCESS_KEY`, `AWS_ENDPOINT_URL_S3`, `AWS_S3_PRIVATE_BUCKET/PUBLIC_BUCKET`, `S3_PUBLIC_URL_BASE`, `SERPAPI_KEY`, `YOUTUBE_API_KEY`, `PROXY_USERNAME/PASSWORD`, `DISCORD_WEBHOOK_URL` 등.

```bash
# app, data 두 네임스페이스에 동일 이름으로 필요
kubectl create secret generic chaneling-secrets -n app \
  --from-literal=PG_PASSWORD=... --from-literal=JWT_SECRET=...  # (필요 키 전부)
kubectl create secret generic chaneling-secrets -n data \
  --from-literal=PG_PASSWORD=...
```
> 실제 값은 팀 비밀 저장소에서. Git에 커밋 금지. (추후 SealedSecrets/외부 시크릿 매니저 권장.)

### 2. Cloudflare 터널 시크릿 `cloudflared-credentials` (platform ns)

아래 "Cloudflare 터널 세팅" 참고.

## Cloudflare 터널 세팅

이 차트는 locally-managed 터널을 씀. **CLI로** 진행(대시보드 UI 불필요).

```bash
brew install cloudflared
cloudflared tunnel login                       # 브라우저 → chaneling.com 존 선택
cloudflared tunnel create chaneling-dev        # UUID 출력 + ~/.cloudflared/<UUID>.json 생성

# DNS 라우팅 (하이픈 단일 단계! 무료 인증서 제약)
cloudflared tunnel route dns chaneling-dev api-dev.chaneling.com
cloudflared tunnel route dns chaneling-dev grafana-dev.chaneling.com
cloudflared tunnel route dns chaneling-dev argocd-dev.chaneling.com

# credentials → K8s Secret
kubectl create secret generic cloudflared-credentials -n platform \
  --from-file=credentials.json=$HOME/.cloudflared/<UUID>.json
```
그 다음 `helm/platform/values-dev.yaml`의 `cloudflared.tunnelId`를 실제 UUID로 커밋 → ArgoCD sync → cloudflared 파드가 뜨고 터널 연결.

검증:
```bash
curl -s -o /dev/null -w "%{http_code}\n" https://api-dev.chaneling.com/actuator/health   # 200
```
자세한 배경(하이픈/인증서/argocd insecure)은 [networking.md](networking.md).

## 배포 / 동기화

배포는 **Git 커밋으로**. 수동 개입이 필요할 때:

```bash
# ArgoCD 앱 상태
kubectl get applications -n argocd

# 즉시 새 커밋 당겨오기(폴링 대기 없이)
kubectl annotate application -n argocd <app> argocd.argoproj.io/refresh=hard --overwrite

# 특정 워크로드 강제 재배포(같은 태그 유지 시. 새 이미지 pull 등)
kubectl rollout restart deployment/<name> -n <ns>
```
> ArgoCD `selfHeal=true`라 `kubectl`로 직접 바꾼 스펙은 Git 상태로 되돌려집니다. 영구 변경은 반드시 Git으로.

## 롤백

```bash
# 방법 A: INFRA 레포에서 image.tag를 이전 sha로 되돌려 커밋
# 방법 B: ArgoCD에서 이전 리비전으로 sync (argocd app rollback 또는 UI)
```

## etcd 백업 / 복구

- K3s server가 **6시간마다 etcd 스냅샷**을 OCI Object Storage(S3 호환)로 자동 업로드(최근 10개 보관). 설정은 cloud-init `k3s-server.yaml`.
- 복구는 K3s `--cluster-reset --cluster-reset-restore-path` 절차 참고(재해 시).

## ArgoCD UI

- URL: https://argocd-dev.chaneling.com (터널)
- 초기 admin 비번:
  ```bash
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
  ```

## 자주 쓰는 확인 명령

```bash
kubectl get pods -A | grep -vE "Running|Completed"     # 비정상 파드만
kubectl describe node node-2 | grep -A5 "Allocated"    # 노드 리소스 여유
kubectl logs -n app deploy/spring --tail=50            # 앱 로그
kubectl get application -n argocd -o wide               # sync/health 상태
```
