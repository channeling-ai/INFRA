# Networking

## 전체 흐름

```
사용자 브라우저
   │ HTTPS (①)
   ▼
Cloudflare 엣지 ── TLS 종료 (여기서 암호 벗김)
   │ HTTP over 터널 (②)
   ▼
cloudflared 파드 (platform ns) ── config.yaml ingress 규칙으로 라우팅
   │
   ▼
K8s Service (spring / grafana / argocd-server)
```

- 인바운드 포트(80/443)를 **안 엽니다**. cloudflared가 Cloudflare로 **아웃바운드 터널**을 맺고, 사용자 트래픽이 그 터널을 타고 들어옵니다. 공격면이 작아짐.

## Cloudflare Tunnel (cloudflared)

- **방식**: locally-managed 터널. 터널 UUID + `credentials.json`을 발급받아 쓰고, ingress 규칙은 차트의 ConfigMap(`config.yaml`)에 둠 → **ingress가 Git에 버전 관리됨**(GitOps 친화적). 대시보드 UI(remotely-managed)는 안 씀.
- **설정 위치**: `helm/platform/values-{env}.yaml`의 `cloudflared.tunnelId` + `cloudflared.ingress`.
- **credentials**: `cloudflared-credentials` K8s Secret(키 `credentials.json`). Git에 없음 → 수동/외부 생성. [operations.md](operations.md#cloudflare-터널-세팅) 참고.

### dev 노출 대상 (ingress)

| hostname | → 내부 Service |
|---|---|
| api-dev.chaneling.com | spring.app.svc.cluster.local:8080 |
| grafana-dev.chaneling.com | grafana.monitoring.svc.cluster.local:3000 |
| argocd-dev.chaneling.com | argocd-server.argocd.svc.cluster.local:80 |
| (그 외) | http_status:404 (catch-all, 필수) |

fastapi/sse/postgres/kafka/redis는 **클러스터 내부 통신 전용** → 노출 안 함.

### ⚠️ 무료 인증서는 1단계 서브도메인만 커버

Cloudflare 무료 **Universal SSL**은 `chaneling.com` + `*.chaneling.com` **한 단계**만 인증서로 커버합니다. `api.dev.chaneling.com`(두 단계)은 커버 안 돼 **TLS handshake 실패**.

→ 그래서 **하이픈 단일 단계**(`api-dev.chaneling.com`)를 씀. 두 단계 `*.dev.chaneling.com`을 쓰려면 유료 Advanced Certificate Manager 필요.

### ⚠️ ArgoCD 리다이렉트 루프 → insecure

argocd-server는 기본이 HTTP→HTTPS 강제 리다이렉트인데, cloudflared가 엣지에서 TLS를 벗기고 HTTP로 넘기므로 **서버는 늘 HTTP만 봄 → 영원히 HTTPS로 리다이렉트 → 무한 루프**.

→ argocd-server를 **insecure 모드**로 (엣지가 TLS 담당). cloud-init(`k3s-server.yaml`)에 반영됨:

```bash
kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge \
  -p '{"data":{"server.insecure":"true"}}'
kubectl -n argocd rollout restart deployment argocd-server
```

spring/grafana는 프로토콜 리다이렉트를 강제 안 해서 루프 없음(argocd만 해당).

## flannel VXLAN (크로스 노드 파드망)

서로 다른 노드의 파드끼리 통신은 flannel의 **VXLAN 터널(UDP 8472)**을 탑니다. app(node-2) → data/CoreDNS(node-1) 호출이 여기에 해당.

### ⚠️ OCI 기본 방화벽이 VXLAN을 막음 (한 번 크게 물렸던 이슈)

OCI Ubuntu 이미지는 호스트 iptables에 catch-all REJECT가 있음:
```
-A INPUT -j REJECT --reject-with icmp-host-prohibited
```
이게 노드 간 VXLAN(UDP 8472) 패킷을 드롭 → **크로스 노드 파드 통신 전면 불가** → 예: `UnknownHostException: postgres.data.svc.cluster.local` (DNS 조회조차 실패).

**증상 구분**: `UnknownHostException`(DNS 실패)은 크로스노드/CoreDNS 도달 불가. Service는 있는데 응답이 없으면 ConnectionRefused/timeout.

**해결** (cloud-init `k3s-server.yaml` / `k3s-agent.yaml`에 반영됨):
```bash
# REJECT보다 앞에 intra-VCN 허용 + VXLAN 허용 삽입 후 영구화
iptables -I INPUT -s 10.0.0.0/16 -j ACCEPT
iptables -I INPUT -p udp --dport 8472 -j ACCEPT
netfilter-persistent save
```

**진단 방법**: 각 노드에 디버그 파드를 띄워 크로스노드 ping / DNS 테스트.
```bash
kubectl run t --image=busybox:1.36 --overrides='{"spec":{"nodeName":"node-2"}}' --restart=Never --command -- sleep 60
kubectl exec t -- ping -c2 <다른노드 파드 IP>          # 100% loss면 VXLAN 막힘
kubectl exec t -- nslookup postgres.data.svc.cluster.local 10.43.0.10
```
OCI **Security List**에서도 UDP 8472/ICMP를 intra-VCN 허용해야 함(terraform `main.tf`에 이미 있음). 보안 리스트는 클라우드 레벨, iptables는 호스트 레벨 — **둘 다** 뚫려야 함.

## 클러스터 네트워크 대역 (참고)

| 대역 | 용도 |
|---|---|
| 10.0.0.0/16 | OCI VCN (노드 사설 IP: 10.0.1.x) |
| 10.42.0.0/16 | 파드 네트워크 (node-1: 10.42.0.x, node-2: 10.42.1.x) |
| 10.43.0.0/16 | Service ClusterIP (CoreDNS: 10.43.0.10) |
