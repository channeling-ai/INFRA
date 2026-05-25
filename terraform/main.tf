################################################################################
# Chaneling INFRA · main.tf
#
# OCI Always Free 기반 K3s 클러스터 부트스트랩.
# - VCN + 공인서브넷 + Security List
# - 2 ARM A1.Flex 인스턴스 (k3s server / k3s agent)
# - cloud-init으로 K3s + ArgoCD 자동 설치
# - ArgoCD가 git에서 모든 워크로드 동기화 (app-of-apps)
#
# Apply 순서:
#   terraform init
#   terraform plan  -var-file=dev.tfvars
#   terraform apply -var-file=dev.tfvars
#
# 동일 모듈을 prod.tfvars로 다시 apply하면 prod 환경 생성됨.
################################################################################

# Terraform 자체 설정

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
  }

  # state는 일단 로컬. 추후 OCI Object Storage backend로 이전 권장.
  # backend "s3" { ... }
}

provider "oci" {
  region = var.region
  # 인증 정보는 ~/.oci/config 에서 자동 로드 (oci setup config 로 사전 설정)
}

################################################################################
# Variables (Input 정리, tfvars와 매칭)
################################################################################

variable "tenancy_ocid" {
  description = "OCI tenancy OCID (Console → Identity → Tenancy)"
  type        = string
}

variable "compartment_ocid" {
  description = "리소스를 생성할 compartment OCID"
  type        = string
}

variable "region" {
  description = "OCI region"
  type        = string
  default     = "ap-chuncheon-1"
}

variable "ssh_public_key" {
  description = "인스턴스 ubuntu 사용자 SSH 공개키"
  type        = string
}

variable "k3s_token" {
  description = "K3s server-agent join 토큰 (openssl rand -hex 32)"
  type        = string
  sensitive   = true
}

variable "oci_s3_endpoint" {
  description = "OCI Object Storage S3-호환 엔드포인트 (full URL with https://)"
  type        = string
}

variable "oci_s3_bucket" {
  description = "etcd 스냅샷 백업용 버킷명"
  type        = string
}

variable "oci_s3_access_key" {
  description = "OCI Customer Secret Key access key"
  type        = string
  sensitive   = true
}

variable "oci_s3_secret_key" {
  description = "OCI Customer Secret Key secret"
  type        = string
  sensitive   = true
}

variable "github_infra_repo" {
  description = "ArgoCD가 sync할 INFRA git 레포 URL"
  type        = string
}

variable "github_infra_path" {
  description = "ArgoCD app-of-apps 매니페스트 경로"
  type        = string
  default     = "argocd/apps"
}

variable "github_infra_branch" {
  description = "git 브랜치 (dev/main)"
  type        = string
  default     = "dev"
}

variable "env_name" {
  description = "환경 이름 (cluster/tag prefix)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "prod"], var.env_name)
    error_message = "env_name은 dev 또는 prod여야 합니다."
  }
}

variable "instance_shape" {
  description = "인스턴스 shape"
  type        = string
  default     = "VM.Standard.A1.Flex"
}

variable "instance_ocpus" {
  description = "인스턴스당 OCPU"
  type        = number
  default     = 1
}

variable "instance_memory_gb" {
  description = "인스턴스당 메모리 (GB)"
  type        = number
  default     = 6
}

variable "boot_volume_gb" {
  description = "부트 볼륨 크기 (GB). Always Free 총 200GB 한도, 2대 = 100GB 권장"
  type        = number
  default     = 100
}

variable "allowed_ssh_cidr" {
  description = "SSH 허용 CIDR. 보안상 가능하면 본인 IP/32로 제한 권장"
  type        = string
  default     = "0.0.0.0/0"
}

################################################################################
# Locals(밑에서 쓸 변수 만들기)
################################################################################

locals {
  cluster_name = "chaneling-${var.env_name}"

  common_tags = {
    Project     = "chaneling"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Cluster     = local.cluster_name
  }

  # OCI S3 endpoint 호스트 부분만 추출 (k3s --etcd-s3-endpoint는 host:port 형식 요구)
  oci_s3_endpoint_host = replace(var.oci_s3_endpoint, "https://", "")

  vcn_cidr    = "10.0.0.0/16" # 확보할 IP 범위, /16 -> 앞 16비트가 고정(10.0.0.0~10.0.255.255)
  subnet_cidr = "10.0.1.0/24"
}

################################################################################
# Data sources (기존 OCI 리소스 조회)
################################################################################

# availability_domain == AWS의 AZ
data "oci_identity_availability_domain" "ad" {
  compartment_id = var.tenancy_ocid
  ad_number      = 1
}

# Canonical Ubuntu 22.04 ARM64 최신 이미지
data "oci_core_images" "ubuntu_arm" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = var.instance_shape
  state                    = "AVAILABLE"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

################################################################################
# Networking · VCN, Subnet, Internet Gateway, Routing, Security(80/443은 허용 불필요, cloudflare -> cloudflared 터널 -> K3s Service로 들어오기 때문에)
################################################################################

resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [local.vcn_cidr] 
  display_name   = "${local.cluster_name}-vcn"
  dns_label      = replace(local.cluster_name, "-", "") # OCI는 VCN 내부에 자동으로 DNS 서버 띄워줌. dns_label로 이름 만들면 인스턴스끼리 IP대신 호스트명으로 통신 가능(도커에서 컨테이너끼리 컨테이너 이름으로 통신하는거마냥)
  freeform_tags  = local.common_tags
}

resource "oci_core_internet_gateway" "main" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.cluster_name}-igw"
  enabled        = true
  freeform_tags  = local.common_tags # 리소스에 붙이는 메타데이터(비용 추적, 필터링에 용이)
}

# 인터넷 게이트웨이로 아웃바운드 보내기
resource "oci_core_route_table" "main" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.cluster_name}-rt"

# VCN안에서 발생한 트래픽 중 목적지가 사설망 밖인 모든 패킷은 인터넷 게이트웨이로 라우팅
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }

  freeform_tags = local.common_tags
}

resource "oci_core_security_list" "main" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.cluster_name}-sl"

  # Egress: 나가는 트래픽

  # ── Egress: 전체 허용 (cloudflared 아웃바운드, OCI Object Storage, 패키지 업데이트 등)
  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
    stateless        = false
  }
  # Ingress: 들어오는 트래픽

  # ── Ingress: SSH
  ingress_security_rules {
    protocol  = "6" # TCP
    source    = var.allowed_ssh_cidr
    stateless = false
    tcp_options {
      min = 22
      max = 22
    }
    description = "SSH"
  }

  # ── Ingress: K3s API (kubectl, agent join)
  ingress_security_rules {
    protocol  = "6"
    source    = local.vcn_cidr  # 같은 VCN 안의 인스턴스끼리만 OK, 외부 인터넷에서는 차단
    stateless = false
    tcp_options {
      min = 6443
      max = 6443
    }
    description = "K3s API server (intra-VCN)" # VCN 내부에서만
  }

  # ── Ingress: kubelet (metrics, exec, logs)
  ingress_security_rules {
    protocol  = "6"
    source    = local.vcn_cidr
    stateless = false
    tcp_options {
      min = 10250
      max = 10250
    }
    description = "kubelet (intra-VCN)"
  }

  # ── Ingress: embedded etcd peer/client 
  # peer(2380): etcd 노드끼리 통신(내가 리더야, 이 데이터 동기화하자, Raft 합의보자 등) / client(2379): 외부 클라이언트(api-server) - etcd에 데이터 읽기/쓰기
  ingress_security_rules {
    protocol  = "6"
    source    = local.vcn_cidr
    stateless = false
    tcp_options {
      min = 2379
      max = 2380
    }
    description = "etcd peer/client (intra-VCN)"
  }

  # ── Ingress: flannel VXLAN (default CNI)
  # flannel = K3s의 기본 CNI(서로 다른 노드에 있는 파드끼리도 네트워크 통신시켜주는 플러그인, 다른 노드 IP는 알아도 그 안에 파드 IP는 모르는데 어떻게? -> 노드안에 가상 터널 만들어서 마치 파드들이 다 같은 네트워크에 있는거처럼 만듬)
  ingress_security_rules {
    protocol  = "17" # UDP
    source    = local.vcn_cidr
    stateless = false
    udp_options {
      min = 8472
      max = 8472
    }
    description = "flannel VXLAN (intra-VCN)"
  }

  # ── Ingress: ICMP for path MTU discovery / debugging
  # Internet Control Message Protocol (ping 쓰려고 허용)
  ingress_security_rules {
    protocol    = "1" # ICMP
    source      = local.vcn_cidr
    stateless   = false
    description = "ICMP (intra-VCN)"
  }

  freeform_tags = local.common_tags
}

# Q. 윗줄에서 만든 oci_core_vcn의 아이디를 여기서 어떻게 알고 집어넣음?
# A. terraform plan 할 때 terraform이 코드 파싱 -> oci_core_subnet.main이 oci_core_vcn.main.id 참조하는거 확인 -> 암묵적 의존성 그래프에 추가
#    terraform apply할 때 의존성 그래프대로 실행 순서 결정. VCN 먼저 생성하고 생성 후 반환되는 ID 메모리에 저장 -> Subnet 생성할때 vcn_id 자리에 끼워넣음 
#    apply 끝나며 .tfstate 파일에 모든 ID 저장. 다음 terraform plan 때 이거 참조해서 뭐뭐가 이미 만들어졌는지 확인함. 
resource "oci_core_subnet" "main" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = local.subnet_cidr
  display_name               = "${local.cluster_name}-subnet"
  dns_label                  = "main"
  route_table_id             = oci_core_route_table.main.id
  security_list_ids          = [oci_core_security_list.main.id]
  prohibit_public_ip_on_vnic = false
  freeform_tags              = local.common_tags
}

################################################################################
# Instances · K3s server + K3s agent
################################################################################

resource "oci_core_instance" "k3s_server" {
  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domain.ad.name
  shape               = var.instance_shape
  display_name        = "${local.cluster_name}-node-1"

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gb
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_arm.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_gb
  }

  # VNIC = Virtual Network Interface Card (가상 랜카드), 인스턴스를 네트워크(서브넷)에 연결 + IP 주소(사설/공인) 보유
  create_vnic_details {
    subnet_id        = oci_core_subnet.main.id
    assign_public_ip = true
    hostname_label   = "node-1"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    # 첫 부팅 때 한 번만 실행. 로그 위치: /var/log/cloud-init.log 
    user_data = base64encode(templatefile("${path.module}/cloud-init/k3s-server.yaml", {
      k3s_token            = var.k3s_token
      oci_s3_endpoint_host = local.oci_s3_endpoint_host
      oci_s3_bucket        = var.oci_s3_bucket
      oci_s3_access_key    = var.oci_s3_access_key
      oci_s3_secret_key    = var.oci_s3_secret_key
      oci_region           = var.region
      github_infra_repo    = var.github_infra_repo
      github_infra_path    = var.github_infra_path
      github_infra_branch  = var.github_infra_branch
    }))
  }

  freeform_tags = merge(local.common_tags, { Role = "k3s-server" })
}

resource "oci_core_instance" "k3s_agent" {
  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domain.ad.name
  shape               = var.instance_shape
  display_name        = "${local.cluster_name}-node-2"

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gb
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_arm.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_gb
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.main.id
    assign_public_ip = true
    hostname_label   = "node-2"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/cloud-init/k3s-agent.yaml", {
      k3s_token         = var.k3s_token
      server_private_ip = oci_core_instance.k3s_server.private_ip # 서버 노드의 IP 연결
    }))
  }

  # agent는 server가 먼저 떠야 의미가 있음 (cloud-init이 server private IP 참조)
  depends_on = [oci_core_instance.k3s_server]

  freeform_tags = merge(local.common_tags, { Role = "k3s-agent" })
}

################################################################################
# Outputs(apply 후 화면에 뜨는 값들)
################################################################################

output "server_public_ip" {
  description = "K3s server (node-1) 공인 IP"
  value       = oci_core_instance.k3s_server.public_ip
}

output "server_private_ip" {
  description = "K3s server (node-1) 사설 IP"
  value       = oci_core_instance.k3s_server.private_ip
}

output "agent_public_ip" {
  description = "K3s agent (node-2) 공인 IP"
  value       = oci_core_instance.k3s_agent.public_ip
}

output "ssh_server" {
  description = "server SSH 접속 명령"
  value       = "ssh ubuntu@${oci_core_instance.k3s_server.public_ip}"
}

output "ssh_agent" {
  description = "agent SSH 접속 명령"
  value       = "ssh ubuntu@${oci_core_instance.k3s_agent.public_ip}"
}

# kubeconfig = 어느 클러스터에 어떤 권한으로 접속하는지 정보가 담긴 yaml 파일
# K3s 설치하면 /etc/rancher/k3s/k3s.yaml에 자동 생성됨
# 근데 기본값으로 server 주소가 https://127.0.0.1:6443로 되어있어서, 이걸 server 공인 IP로 바꿔줘야됨
output "kubeconfig_fetch_command" {
  description = "로컬에 kubeconfig 받아오기 (cloud-init 완료 후 ~5분 뒤 실행)"
  # sed로 로컬호스트 실제 IP로 치환
  value       = <<-EOT
    ssh ubuntu@${oci_core_instance.k3s_server.public_ip} sudo cat /etc/rancher/k3s/k3s.yaml \
      | sed "s/127.0.0.1/${oci_core_instance.k3s_server.public_ip}/" \
      > ~/.kube/config-${var.env_name}
    export KUBECONFIG=~/.kube/config-${var.env_name}
    kubectl get nodes
  EOT
}

output "argocd_initial_admin_password_command" {
  description = "ArgoCD 초기 admin 비번 확인 (UI 첫 로그인용)"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

output "cluster_summary" {
  description = "클러스터 요약"
  value = {
    cluster_name     = local.cluster_name
    region           = var.region
    server_node      = "node-1 (${oci_core_instance.k3s_server.public_ip}) · role=data-tier"
    agent_node       = "node-2 (${oci_core_instance.k3s_agent.public_ip}) · role=app-tier"
    total_cpu        = "${var.instance_ocpus * 2} OCPU"
    total_memory_gb  = "${var.instance_memory_gb * 2} GB"
    total_storage_gb = "${var.boot_volume_gb * 2} GB"
    backup_target    = "${var.oci_s3_bucket} (etcd snapshot every 6h)"
  }
}
