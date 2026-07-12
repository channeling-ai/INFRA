# CI/CD (GitOps 배포 흐름)

## 핵심 원리

**이미지를 레지스트리에 푸시한다고 배포되지 않습니다.** ArgoCD는 이 INFRA 레포의 **매니페스트(이미지 태그 문자열 포함)**만 클러스터와 비교합니다. 레지스트리의 digest 변화는 모릅니다.

→ 따라서 배포를 트리거하려면 **이 레포의 `image.tag` 값을 바꿔 커밋**해야 합니다. 그래서 각 앱 레포 CI가 자기 이미지를 빌드/푸시한 뒤, **이 레포의 `values-dev.yaml` image.tag를 갱신 커밋**합니다.

```
앱 레포(develop 푸시)
  │
  ├─ 1. 이미지 빌드 (arm64!) → 불변 태그 dev-<sha>로 Docker Hub 푸시
  │
  └─ 2. INFRA 레포 clone → values-dev.yaml 의 image.tag = dev-<sha> → dev 브랜치 커밋/푸시
                                  │
                                  ▼
                       ArgoCD (INFRA dev 감시)
                                  │ diff 감지 (태그 문자열 변경)
                                  ▼
                       클러스터 롤아웃 (새 이미지 pull → 배포)
```

## 태그 규칙

- **불변 태그** `dev-<7자리 git sha>` 사용. `latest` 같은 mutable 태그는 ArgoCD가 diff를 못 봐서 자동 배포가 안 됨.
- 롤백 = INFRA `values-dev.yaml`의 태그를 이전 sha로 되돌려 커밋 (또는 ArgoCD에서 이전 리비전 sync).

## 각 앱 레포 → INFRA 필드 매핑

| 앱 레포 | 이미지 | 갱신하는 INFRA 필드 |
|---|---|---|
| BE-V2 | `hadoroke/chaneling-be` | `spring.image.tag` |
| LLM-V2 | `hadoroke/chaneling-llm` | `fastapi.image.tag` + `consumer.image.tag` (둘 다 같은 이미지) |
| SSE | `hadoroke/chaneling-sse` | `sse.image.tag` |

## 워크플로우 (`.github/workflows/deploy-dev.yml`)

각 앱 레포에 동일 패턴으로 존재. 트리거는 **`develop` 브랜치 푸시**.

```yaml
on:
  push:
    branches: [ develop ]

# 주요 스텝:
# 1) actions/checkout
# 2) docker/setup-qemu-action     ← ★ 필수 (아래 arm64 참고)
# 3) docker/setup-buildx-action
# 4) docker/login-action          ← DOCKER_USERNAME / DOCKER_ACCESS_TOKEN
# 5) docker/build-push-action
#      platforms: linux/arm64     ← ★ 필수
#      tags: <user>/chaneling-*:dev-<sha>
# 6) INFRA clone → yq로 image.tag 갱신 → 커밋/푸시 (INFRA_REPO_TOKEN)
```

## ⚠️ arm64 (가장 흔한 함정)

클러스터 노드는 **ARM64**(OCI A1.Flex)인데 GitHub 러너는 **amd64**입니다. 그냥 빌드하면 amd64 이미지가 나와서 노드가 못 당깁니다:

```
Failed to pull image ... no match for platform in manifest: not found
→ 파드 ImagePullBackOff
```

**해결**: 워크플로우에 `docker/setup-qemu-action`(에뮬레이션) + build-push에 `platforms: linux/arm64`. (이미 세 워크플로우에 반영됨.)

- QEMU 에뮬 빌드는 네이티브보다 느림 → `cache-from/to: type=gha`로 완화. 너무 느리면 `runs-on: ubuntu-24.04-arm`(네이티브 arm 러너)로 교체 고려(private 레포는 요금 확인).

## 필요한 시크릿 (각 앱 레포)

| 시크릿 | 용도 | 비고 |
|---|---|---|
| `DOCKER_USERNAME` | Docker Hub 로그인 | 기존 v1 CI가 쓰던 것 재사용 |
| `DOCKER_ACCESS_TOKEN` | Docker Hub 토큰 | 〃 |
| `INFRA_REPO_TOKEN` | INFRA 레포에 커밋 푸시 | **신규**. `channeling-ai/INFRA` Contents: Read/Write 권한 fine-grained PAT |

- **org 시크릿 주의**: Free org 플랜은 org 시크릿이 **public 레포만** 대상. v2 레포는 private이라 **레포별 시크릿**으로 각각 등록해야 함(Team 플랜이면 org 공유 가능).

## 동시성 / 충돌

여러 앱 CI가 동시에 INFRA `dev`에 푸시하면 충돌 가능 → 워크플로우의 INFRA 갱신 스텝에 **rebase 재시도 루프** 포함. 앱 레포별 `concurrency` 그룹으로 자기 레포 내 중복 실행은 취소.

## v1 프로덕션과의 관계 (SSE 특히 주의)

- **SSE 레포는 v1 prod와 공유**됨:
  - `CI.yml` (`main` 푸시): v1 prod → `channeling-sse`(n2) → **AWS ASG 리프레시**. **절대 삭제/수정 금지.**
  - `deploy-dev.yml` (`develop` 푸시): v2 dev → `chaneling-sse`(n1) → INFRA 태그 갱신.
  - 브랜치/이미지 이름이 달라 충돌 없음.
- BE-V2/LLM-V2의 옛 `CI.yml`은 v1 leftover라 삭제됨(v1 prod BE/LLM은 별도 v1 레포에서 배포).

## prod CI (미구현)

현재 dev만 자동화. prod는 릴리스 태그 푸시 시 `values-prod.yaml`의 image.tag를 semver로 갱신하는 워크플로우를 추후 추가.
