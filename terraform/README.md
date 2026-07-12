# terraform (OCI 프로비저닝 + K3s 부트스트랩)

OCI Always Free 기반 K3s 클러스터를 코드로 생성. VCN·보안·인스턴스 2대를 만들고, cloud-init으로 K3s + ArgoCD까지 자동 설치합니다.

## 생성되는 리소스

| 리소스 | 설명 |
|---|---|
| VCN (10.0.0.0/16) + Subnet (10.0.1.0/24) | 사설 네트워크 |
| Internet Gateway + Route Table | 아웃바운드 |
| Security List | SSH(22), K3s API(6443), kubelet(10250), etcd(2379-2380), **flannel VXLAN(UDP 8472)**, ICMP — 대부분 intra-VCN 한정 |
| Instance node-1 (server) | K3s control-plane+etcd, `role=data-tier` |
| Instance node-2 (agent) | K3s worker, `role=app-tier` |

인스턴스: **VM.Standard.A1.Flex (ARM Ampere)**, 기본 1 OCPU / 6GB, Ubuntu 22.04, 부트볼륨 100GB.

## cloud-init이 하는 일

**node-1 (`cloud-init/k3s-server.yaml`)**
1. sysctl(패킷 포워딩) 설정
2. **호스트 iptables에 VXLAN/intra-VCN 허용** 삽입 + 영구화 (OCI 기본 REJECT 우회 — 안 하면 크로스노드 통신 불가)
3. 자기 public IP 조회 → K3s server 설치(embedded etcd, traefik/servicelb 비활성, etcd S3 스냅샷 6h)
4. **ArgoCD 설치** → `argocd-cmd-params-cm`에 `server.insecure=true`(터널 뒤 리다이렉트 루프 방지) → argocd-server 재시작
5. **root Application(app-of-apps)** 적용 → ArgoCD가 `argocd/apps/`의 나머지를 자동 등록

**node-2 (`cloud-init/k3s-agent.yaml`)**
1. sysctl + **iptables VXLAN 허용**
2. server API 대기 후 K3s agent로 join (`role=app-tier` 라벨)

## 사용법

```bash
oci setup config                        # 최초 1회
cp dev.tfvars.example dev.tfvars
$EDITOR dev.tfvars                      # 필수 변수 채움 (아래)
terraform init
terraform plan  -var-file=dev.tfvars
terraform apply -var-file=dev.tfvars
```

같은 모듈을 `prod.tfvars`로 다시 apply하면 prod 환경 생성(별도 클러스터).

### 필수 변수 (dev.tfvars)

| 변수 | 설명 |
|---|---|
| `tenancy_ocid` / `compartment_ocid` | OCI 식별자 |
| `ssh_public_key` | 인스턴스 접속용 공개키 |
| `k3s_token` | server-agent join 토큰 (`openssl rand -hex 32`) |
| `oci_s3_endpoint` / `oci_s3_bucket` / `oci_s3_access_key` / `oci_s3_secret_key` | etcd 스냅샷 백업용 OCI Object Storage(S3 호환) |
| `github_infra_repo` / `github_infra_branch` | ArgoCD가 sync할 이 레포/브랜치 |
| `env_name` | `dev` 또는 `prod` |

## apply 후

`terraform output`에 kubeconfig 가져오는 명령, SSH 명령, ArgoCD 초기 비번 명령이 출력됨. → [README 빠른 시작](../README.md#빠른-시작-dev-클러스터-신규-생성).

## 주의

- **state는 현재 로컬**. 추후 OCI Object Storage backend로 이전 권장(팀 협업 시 필수).
- 보안 리스트는 **클라우드 레벨** 방화벽. cloud-init의 iptables는 **호스트 레벨**. 크로스노드 통신은 둘 다 뚫려야 함 → [networking.md](../docs/networking.md#flannel-vxlan).
- `k3s_token`, S3 키 등 민감값은 tfvars에만 두고 **커밋 금지**(`.gitignore` 확인).
