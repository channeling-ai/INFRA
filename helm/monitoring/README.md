# monitoring 차트 (monitoring 네임스페이스)

로그 수집·조회 스택. 메트릭보다 **로그 중심**(Loki).

## 배포 대상

| 컴포넌트 | 종류 | 설명 |
|---|---|---|
| **promtail** | DaemonSet (+RBAC) | 각 노드의 컨테이너 로그를 수집해 Loki로 전송 |
| **loki** | Deployment (+Service) | 로그 저장/질의 백엔드 |
| **grafana** | Deployment (+Service +PVC) | 대시보드 UI (Loki를 데이터소스로) |

## 흐름

```
각 노드 파드 로그 → promtail(DaemonSet, 노드마다 1개) → loki(저장) → grafana(조회)
```

## 외부 노출

grafana만 Cloudflare 터널로 노출(`grafana-dev.chaneling.com`). loki/promtail은 내부 전용.

## 주요 values

| 키 | 의미 |
|---|---|
| `grafana.*` | 이미지/리소스/PVC(대시보드·설정 영속) |
| `loki.*` | 이미지/리소스 |
| `promtail.*` | 이미지/리소스, 수집 대상 경로 |
| `global.nodeSelector` | 배치 노드 (data-tier로 이동됨 — 아래) |

## 설계 노트

- **data-tier로 이동**: 초기엔 app-tier(node-2)였으나 node-2 CPU 부족으로 **node-1(data-tier)로 이동**. 모니터링은 상시 부하가 낮아 데이터 노드에 얹음.
- promtail은 **DaemonSet**이라 nodeSelector와 무관하게 모든 노드에 1개씩(로그를 놓치지 않기 위해).
- loki probe는 TCP 방식(HTTP 헬스 대신) 사용 이력 있음 — 리소스 제약 환경 대응.

## 접속

- URL: https://grafana-dev.chaneling.com
- 초기 계정은 grafana values/configmap 참고. 로그 조회는 Explore → Loki → `{namespace="app"}` 등.

## 로컬 렌더

```bash
helm template monitoring . -f values.yaml -f values-dev.yaml
```
