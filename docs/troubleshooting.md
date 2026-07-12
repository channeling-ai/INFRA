# Troubleshooting

실제로 겪었던 장애들과 해결법. 증상 → 원인 → 해결 순.

## 파드가 못 뜸 (Pending / ContainerCreating / ImagePullBackOff / CrashLoop)

### `UnknownHostException: <svc>.data.svc.cluster.local` (앱이 DB/Redis 못 찾음)
- **원인**: 크로스 노드 파드 통신(flannel VXLAN) 차단. OCI Ubuntu 호스트 iptables의 REJECT가 UDP 8472를 드롭.
- **확인**: 디버그 파드로 크로스노드 ping → 100% loss.
- **해결**: 노드 iptables에 VXLAN 허용 삽입 + 영구화. → [networking.md](networking.md#flannel-vxlan). cloud-init에 반영돼 있으니 재빌드 시 자동.

### `no match for platform in manifest: not found`
- **원인**: **amd64 이미지를 arm64 노드에서 pull**. CI에 arm64 빌드 설정 누락.
- **해결**: 워크플로우에 `docker/setup-qemu-action` + `platforms: linux/arm64`. → [cicd.md](cicd.md#️-arm64-가장-흔한-함정).

### `ContainerCreating`이 오래 지속
- **원인**: 마운트할 **Secret이 없음**(예: `cloudflared-credentials`, `chaneling-secrets`).
- **해결**: 해당 Secret 생성. → [operations.md](operations.md#사전-준비물-배포-전-필수).

### Pod `Pending` (`Insufficient cpu` / `didn't match node affinity`)
- **원인**: 노드 CPU 포화, 또는 nodeSelector가 안 맞음.
- dev 특이사항: `nodeSelector: {}`(빈 맵)는 Helm 딥머지에서 base의 `role=app-tier`를 **못 지움** → 모든 app 파드가 node-2로 몰려 CPU 포화. **`null`로 명시해야** 제거됨.
- **해결**: `values-dev.yaml`의 `global.nodeSelector: null`(빈 맵 아님) 확인. 템플릿은 `{{- with .Values.global.nodeSelector }}` 가드로 비었을 때 nodeSelector 미출력.

### `ModuleNotFoundError` / 빈 생성 실패 (앱 부팅 중 크래시)
- **원인**: 앱 이미지의 의존성/설정 문제(인프라 아님).
  - 예1) `No module named 'numpy'` → 앱 requirements.txt에 의존성 누락.
  - 예2) `Could not resolve placeholder 'cloud.aws.region.static'` → Spring 프로파일 누락으로 해당 `application-*.yml` 미로드.
- **해결**: 앱 레포에서 수정 후 재빌드. 인프라 쪽은 env 주입(`_helpers.tpl`)이 맞는지 확인.

## 헬스체크 / probe 관련

### probe가 401 (액세스 토큰 요구)
- **원인**: Spring Security가 `/actuator/health/**`까지 인증 요구. 화이트리스트가 `/actuator/health`(정확 일치)면 `/liveness` 하위 경로 미포함.
- **해결(앱)**: JWT 필터 화이트리스트 `/actuator/health/**`, SecurityConfig `permitAll` 추가.

### probe가 404
- **원인**: `/actuator/*` 자체가 없음 → **`spring-boot-starter-actuator` 의존성 부재**, 또는 `management.endpoint.health.probes.enabled` 미설정으로 liveness/readiness 그룹 없음.
- **해결(앱)**: actuator 스타터 추가 + `management.endpoint.health.probes.enabled: true`.

### 느린 JVM 기동으로 재시작 루프
- **원인**: CPU 굶주린 노드에서 기동이 90s+인데 liveness `initialDelay`가 짧아 기동 중 kill.
- **해결(인프라)**: **startupProbe** 추가(기동 대기 분리) + liveness `timeoutSeconds` 상향. `values.yaml`의 `*.probes.startup` 참고.

## Cloudflare 터널

### TLS handshake failure / curl exit 35
- **원인**: 무료 인증서가 2단계 서브도메인(`api.dev.chaneling.com`) 미커버.
- **해결**: 하이픈 단일 단계(`api-dev.chaneling.com`). → [networking.md](networking.md#️-무료-인증서는-1단계-서브도메인만-커버).

### HTTP 404 (터널은 연결됐는데)
- **원인**: cloudflared ConfigMap ingress가 요청 hostname과 안 맞음(catch-all 404). 보통 ArgoCD가 아직 최신 커밋을 sync 안 함.
- **해결**: ArgoCD refresh, ConfigMap 확인(`kubectl get cm -n platform cloudflared-config -o yaml`).

### argocd만 리다이렉트 루프(307 반복)
- **원인/해결**: argocd insecure 미설정. → [networking.md](networking.md#️-argocd-리다이렉트-루프--insecure).

## 배포가 반영 안 됨

### 이미지 푸시했는데 클러스터가 그대로
- **원인**: mutable 태그(`latest`)라 ArgoCD가 diff를 못 봄. 또는 CI가 INFRA image.tag를 안 바꿈.
- **해결**: 불변 태그 사용 + CI가 `values-dev.yaml` image.tag를 갱신하는지 확인. 급하면 `kubectl rollout restart`.

### `kubectl`로 바꿨는데 되돌아감
- **원인**: ArgoCD `selfHeal=true`. Git이 진실.
- **해결**: 영구 변경은 Git 커밋으로.

## 롤아웃이 멈춤 (옛 파드 남고 새 파드 계속 실패)
- 새 ReplicaSet 파드가 Ready가 안 되면(이미지 못 당김/크래시) 롤아웃이 완료를 못 해 옛 RS가 남음 → CPU 이중 점유.
- 위 "파드가 못 뜸" 항목으로 새 파드 실패 원인부터 해결하면 자동 정리됨.
