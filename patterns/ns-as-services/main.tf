provider "aws" {
  region = local.region
}

# Required for public ECR where Karpenter artifacts are hosted
provider "aws" {
  region = "us-east-1"
  alias  = "virginia"
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

provider "kubectl" {
  apply_retry_count      = 5
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.virginia
}

data "aws_availability_zones" "available" {}

locals {
  name   = basename(path.cwd)
  region = "us-west-2"

  vpc_cidr = "10.100.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/aws-ia/terraform-aws-eks-blueprints"
  }
}

################################################################################
# Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.16"

  cluster_name                   = local.name
  cluster_version                = "1.27"
  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Fargate profiles use the cluster primary security group so these are not utilized
  create_cluster_security_group = false
  create_node_security_group    = false

  manage_aws_auth_configmap = true
  aws_auth_roles = [
    # We need to add in the Karpenter node IAM role for nodes launched by Karpenter
    {
      rolearn  = module.eks_blueprints_addons.karpenter.node_iam_role_arn
      username = "system:node:{{EC2PrivateDNSName}}"
      groups = [
        "system:bootstrappers",
        "system:nodes",
      ]
    },
  ]

  fargate_profiles = {
    karpenter = {
      selectors = [
        { namespace = "karpenter" }
      ]
    }
    kube_system = {
      name = "kube-system"
      selectors = [
        { namespace = "kube-system" }
      ]
    }
  }

  tags = merge(local.tags, {
    # NOTE - if creating multiple security groups with this module, only tag the
    # security group that Karpenter should utilize with the following tag
    # (i.e. - at most, only one security group should have this tag in your account)
    "karpenter.sh/discovery" = local.name
  })
}

################################################################################
# EKS Blueprints Addons
################################################################################

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.0"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  # We want to wait for the Fargate profiles to be deployed first
  create_delay_dependencies = [for prof in module.eks.fargate_profiles : prof.fargate_profile_arn]

  eks_addons = {
    coredns = {
      configuration_values = jsonencode({
        computeType = "Fargate"
        # Ensure that the we fully utilize the minimum amount of resources that are supplied by
        # Fargate https://docs.aws.amazon.com/eks/latest/userguide/fargate-pod-configuration.html
        # Fargate adds 256 MB to each pod's memory reservation for the required Kubernetes
        # components (kubelet, kube-proxy, and containerd). Fargate rounds up to the following
        # compute configuration that most closely matches the sum of vCPU and memory requests in
        # order to ensure pods always have the resources that they need to run.
        resources = {
          limits = {
            cpu = "0.25"
            # We are targetting the smallest Task size of 512Mb, so we subtract 256Mb from the
            # request/limit to ensure we can fit within that task
            memory = "256M"
          }
          requests = {
            cpu = "0.25"
            # We are targetting the smallest Task size of 512Mb, so we subtract 256Mb from the
            # request/limit to ensure we can fit within that task
            memory = "256M"
          }
        }
      })
    }
    vpc-cni = {
      configuration_values = jsonencode({
        enableNetworkPolicy = "true",
        nodeAgent = {
          enableCloudWatchLogs = "true"
          healthProbeBindAddr  = "8163"
          metricsBindAddr      = "8162"
        }
      })
    }
    kube-proxy = {}
  }

  enable_gatekeeper = true
  enable_karpenter  = true
  karpenter = {
    repository_username = data.aws_ecrpublic_authorization_token.token.user_name
    repository_password = data.aws_ecrpublic_authorization_token.token.password
  }

  tags = local.tags
}

################################################################################
# Karpenter
################################################################################
resource "kubectl_manifest" "karpenter_provisioner" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1alpha5
    kind: Provisioner
    metadata:
      name: default
    spec:
      requirements:
        - key: "karpenter.k8s.aws/instance-category"
          operator: In
          values: ["c", "m"]
        - key: "karpenter.k8s.aws/instance-cpu"
          operator: In
          values: ["8", "16", "32"]
        - key: "karpenter.k8s.aws/instance-hypervisor"
          operator: In
          values: ["nitro"]
        - key: "topology.kubernetes.io/zone"
          operator: In
          values: ${jsonencode(local.azs)}
        - key: "kubernetes.io/arch"
          operator: In
          values: ["arm64", "amd64"]
        - key: "karpenter.sh/capacity-type" # If not included, the webhook for the AWS cloud provider will default to on-demand
          operator: In
          values: ["spot", "on-demand"]
      kubeletConfiguration:
        containerRuntime: containerd
        maxPods: 110
      limits:
        resources:
          cpu: 1000
      consolidation:
        enabled: true
      providerRef:
        name: default
      ttlSecondsUntilExpired: 604800 # 7 Days = 7 * 24 * 60 * 60 Seconds
  YAML

  depends_on = [
    module.eks_blueprints_addons
  ]
}

resource "kubectl_manifest" "karpenter_provisioner_pool" {
  for_each = { for np in var.pool_list : np.pool => np }

  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1alpha5
    kind: Provisioner
    metadata:
      name: ${each.value.pool}
    spec:
      providerRef:
        name: default
      taints:
        - key: node-pool
          value: ${each.value.pool}
          effect: NoSchedule
      labels:
        node-pool: ${each.value.pool}
      ttlSecondsAfterEmpty: 30
  YAML

  depends_on = [
    module.eks_blueprints_addons
  ]
}

resource "kubectl_manifest" "karpenter_node_template" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1alpha1
    kind: AWSNodeTemplate
    metadata:
      name: default
    spec:
      subnetSelector:
        karpenter.sh/discovery: ${module.eks.cluster_name}
      securityGroupSelector:
        karpenter.sh/discovery: ${module.eks.cluster_name}
      instanceProfile: ${module.eks_blueprints_addons.karpenter.node_instance_profile_name}
      userData: |
          MIME-Version: 1.0
          Content-Type: multipart/mixed; boundary="BOUNDARY"

          --BOUNDARY
          Content-Type: text/x-shellscript; charset="us-ascii"

          #!/bin/bash
          sudo mount -t bpf bpffs /sys/fs/bpf
          --BOUNDARY--
      tags:
        karpenter.sh/discovery: ${module.eks.cluster_name}
  YAML

  depends_on = [
    module.eks_blueprints_addons
  ]
}

################################################################################
# GateKeeper
################################################################################
resource "kubectl_manifest" "gk_selector_pool" {
  for_each = { for np in var.pool_list : np.pool => np }

  yaml_body = <<-YAML
    apiVersion: mutations.gatekeeper.sh/v1
    kind: Assign
    metadata:
      name: nodepool-selector-${each.value.pool}
    spec:
      applyTo:
      - groups:
        - ""
        kinds:
        - Pod
        versions:
        - v1
      location: spec.nodeSelector
      match:
        kinds:
        - apiGroups:
          - '*'
          kinds:
          - Pod
        namespaces:
        - ${each.value.namespace}
        scope: Namespaced
      parameters:
        assign:
          value:
            node-pool: ${each.value.pool}
  YAML
  depends_on = [
    module.eks_blueprints_addons
  ]
}

resource "kubectl_manifest" "gk_toleration_pool" {
  for_each = { for np in var.pool_list : np.pool => np }

  yaml_body = <<-YAML
    apiVersion: mutations.gatekeeper.sh/v1
    kind: Assign
    metadata:
      name: nodepool-toleration-${each.value.pool}
    spec:
      applyTo:
      - groups:
        - ""
        kinds:
        - Pod
        versions:
        - v1
      location: spec.tolerations
      match:
        kinds:
        - apiGroups:
          - '*'
          kinds:
          - Pod
        namespaces:
        - ${each.value.namespace}
        scope: Namespaced
      parameters:
        assign:
          value:
          - key: node-pool
            operator: Equal
            value: ${each.value.pool}
  YAML

  depends_on = [
    module.eks_blueprints_addons
  ]
}
################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Tags subnets for Karpenter auto-discovery
    "karpenter.sh/discovery" = local.name
  }

  tags = local.tags
}
