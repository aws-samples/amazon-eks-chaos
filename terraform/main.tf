provider "aws" {
  default_tags {
    tags = var.default_tags
  }
  
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", local.region]
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
  registry {
    url      = "oci://${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com"
    username = data.aws_ecr_authorization_token.token.user_name
    password = data.aws_ecr_authorization_token.token.password
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


################################################################################
# GitOps Bridge: Bootstrap
################################################################################
module "gitops_bridge_bootstrap" {
  source = "gitops-bridge-dev/gitops-bridge/helm"

  cluster = {
    cluster_name = module.eks.cluster_name
    environment  = "dev"
    metadata     = local.addons_metadata
    addons       = local.addons
  }
  apps = local.argocd_apps
}

################################################################################
# EKS Blueprints Addons
################################################################################
module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.21.1"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  # Using GitOps Bridge
  create_kubernetes_resources = false

  # EKS Blueprints Addons
  #enable_cert_manager                 = local.aws_addons.enable_cert_manager
  #enable_aws_efs_csi_driver           = local.aws_addons.enable_aws_efs_csi_driver
  #enable_aws_fsx_csi_driver           = local.aws_addons.enable_aws_fsx_csi_driver
  #enable_aws_cloudwatch_metrics       = local.aws_addons.enable_aws_cloudwatch_metrics
  #enable_aws_privateca_issuer         = local.aws_addons.enable_aws_privateca_issuer
  #enable_cluster_autoscaler           = local.aws_addons.enable_cluster_autoscaler
  #enable_external_dns                 = local.aws_addons.enable_external_dns
  #enable_external_secrets             = local.aws_addons.enable_external_secrets
  #enable_aws_load_balancer_controller = local.aws_addons.enable_aws_load_balancer_controller
  #enable_fargate_fluentbit            = local.aws_addons.enable_fargate_fluentbit
  #enable_aws_for_fluentbit            = local.aws_addons.enable_aws_for_fluentbit
  #enable_aws_node_termination_handler = local.aws_addons.enable_aws_node_termination_handler
  #enable_karpenter                    = local.aws_addons.enable_karpenter
  #enable_velero                       = local.aws_addons.enable_velero
  #enable_aws_gateway_api_controller   = local.aws_addons.enable_aws_gateway_api_controller

  tags = local.tags
}



################################################################################
# Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.33"

  cluster_name                   = local.name
  #cluster_version                = "1.31"
  cluster_endpoint_public_access = true
  # Cluster access entry
  # To add the current caller identity as an administrator
  enable_cluster_creator_admin_permissions = true
  iam_role_additional_policies = {
    SSM_Policy = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.public_subnets

  eks_managed_node_groups = {
    mg_5 = {
      instance_types = ["m5.large"]
      name = "managed-workload"
      min_size     = 1
      max_size     = 5
      desired_size = 2
    }
  }

  # EKS Addons
  cluster_addons = {
    coredns    = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
    vpc-cni = {
      # Specify the VPC CNI addon should be deployed before compute to ensure
      # the addon is configured before data plane compute resources are created
      # See README for further details
      before_compute = true
      most_recent    = true # To ensure access to the latest settings provided
      configuration_values = jsonencode({
        env = {
          # Reference docs https://docs.aws.amazon.com/eks/latest/userguide/cni-increase-ip-addresses.html
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
  }

  //manage_aws_auth_configmap = true
  //aws_auth_roles = flatten([
    //module.eks_blueprints_admin_team.aws_auth_configmap_role,
    //[for team in module.eks_blueprints_dev_teams : team.aws_auth_configmap_role],
  //])

  tags = local.tags
}

################################################################################
# Supporting Resources VPC
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.18"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway   = true
  create_igw           = true
  enable_dns_hostnames = true
  single_nat_gateway   = true

  # Manage so we can name
  manage_default_network_acl    = true
  default_network_acl_tags      = { Name = "${local.name}-default" }
  manage_default_route_table    = true
  default_route_table_tags      = { Name = "${local.name}-default" }
  manage_default_security_group = true
  default_security_group_tags   = { Name = "${local.name}-default" }

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.name}" = "shared"
    "kubernetes.io/role/elb"              = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.name}" = "shared"
    "kubernetes.io/role/internal-elb"     = "1"
  }

  tags = local.tags
}


/*
  platform_teams = {
    admin = {
      users = [
        data.aws_caller_identity.current.arn
      ]
    }
  }
*/


/*
module "kubernetes_addons" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints?ref=v4.32.1/modules/kubernetes-addons"

  eks_cluster_id = module.eks_blueprints.eks_cluster_id



  # observability
  //enable_prometheus      = true
  //enable_grafana         = false
  //enable_amazon_eks_adot = true
  //amazon_eks_adot_config = {
  //  most_recent        = true
  //  kubernetes_version = module.eks_blueprints.eks_cluster_version
  //  resolve_conflicts  = "OVERWRITE"
  //}
}

module "adot_collector_irsa_addon" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints?ref=v4.21.0/modules/irsa"

  create_kubernetes_namespace       = true
  create_kubernetes_service_account = true
  kubernetes_namespace              = "aws-otel"
  kubernetes_service_account        = "adot-collector"
  irsa_iam_policies                 = ["arn:aws:iam::aws:policy/AmazonPrometheusRemoteWriteAccess"]
  eks_cluster_id                    = module.eks_blueprints.eks_cluster_id
  eks_oidc_provider_arn             = module.eks_blueprints.eks_oidc_provider_arn
}*/
