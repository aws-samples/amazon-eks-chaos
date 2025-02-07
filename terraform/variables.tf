variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "default_tags" {
  description = "Default Tags"
  type = map
  default = {}
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string

}
variable "addons" {
  description = "Kubernetes addons"
  type        = any
  default = {
    enable_aws_load_balancer_controller = true
    enable_metrics_server               = true
    enable_aws_for_fluentbit            = true
    enable_cluster_autoscaler           = true
    enable_kube_prometheus_stack        = true
    enable_aws_secrets_store_csi_driver_provider = true
    enable_cert_manager                 = true
  }
}
# Addons Git
variable "gitops_addons_org" {
  description = "Git repository org/user contains for addons"
  type        = string
  default     = "https://github.com/gitops-bridge-dev/"
}
variable "gitops_addons_repo" {
  description = "Git repository contains for addons"
  type        = string
  default     = "gitops-bridge-argocd-control-plane-template"
}
variable "gitops_addons_revision" {
  description = "Git repository revision/branch/ref for addons"
  type        = string
  default     = "HEAD"
}
variable "gitops_addons_basepath" {
  description = "Git repository base path for addons"
  type        = string
  default     = ""
}
variable "gitops_addons_path" {
  description = "Git repository path for addons"
  type        = string
  default     = "bootstrap/control-plane/addons"
}
# Workloads Git

variable "workload_repo" {
  type = string
  default = "https://github.com/aws-samples/amazon-eks-chaos"
}

variable "gitops_workload_revision" {
  description = "Git repository revision/branch/ref for workload"
  type        = string
  default     = "main"
}
variable "gitops_workload_basepath" {
  description = "Git repository base path for workload"
  type        = string
  default     = "/"
}
variable "gitops_workload_path" {
  description = "Git repository path for workload"
  type        = string
  default     = "app"
}

variable "enable_gitops_auto_addons" {
  description = "Automatically deploy addons"
  type        = bool
  default     = true
}

variable "enable_gitops_auto_workloads" {
  description = "Automatically deploy addons"
  type        = bool
  default     = true
}