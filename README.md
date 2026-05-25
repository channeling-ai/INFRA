# INFRA

Chaneling 서비스의 Kubernetes 기반 인프라. Terraform으로 OCI 인스턴스를 프로비저닝하고, K3s + ArgoCD로 GitOps 배포.

## 구조

```
INFRA/
├── terraform/          # OCI 인스턴스, VCN, K3s 부트스트랩
├── helm/               # 앱/데이터/모니터링/플랫폼 차트
├── argocd/             # app-of-apps Application 매니페스트
├── .github/workflows/  # GHA CI/CD
└── docs/               # 운영/장애 복구 가이드
```

## 빠른 시작 (dev)

```bash
# 1. OCI CLI 설정 (최초 1회)
oci setup config

# 2. 변수 파일 작성
cd terraform
cp dev.tfvars.example dev.tfvars
$EDITOR dev.tfvars  # tenancy_ocid, compartment_ocid, ssh_public_key 등 채움

# 3. Terraform 적용
terraform init
terraform plan -var-file=dev.tfvars
terraform apply -var-file=dev.tfvars

# 4. kubeconfig 가져오기 (output에 명령 출력됨)
ssh ubuntu@<server-public-ip> sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config-dev
sed -i '' "s/127.0.0.1/<server-public-ip>/" ~/.kube/config-dev
export KUBECONFIG=~/.kube/config-dev

# 5. 노드 확인
kubectl get nodes

# 6. ArgoCD가 git에서 앱 자동 동기화 (~5분)
kubectl get applications -n argocd
```

## 환경

- **dev**: 2 노드 (OCI Always Free), 자동 백업 6시간
- **prod**: 동일 구조, 백업 1시간, image tag = release semver (추후 활성화)

자세한 내용은 `docs/` 참고.
