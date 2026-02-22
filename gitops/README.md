# GitOps Directory

ArgoCD ApplicationSets and Helm charts for EKS cluster addon management. This directory is watched by ArgoCD (deployed as an EKS Capability) to deploy and manage cluster addons via the GitOps Bridge pattern.

## Directory Structure

```
gitops/
├── bootstrap/              # ArgoCD AppProjects (apply once during cluster setup)
│   └── argocd-projects.yaml
├── addons/                 # Standard cluster addons (Helm chart references)
│   └── applicationset.yaml
├── custom-addons/          # Organization-specific addons (Helm charts in git)
│   ├── applicationset.yaml
│   └── charts/
│       ├── cis-benchmark/  # CIS EKS Benchmark Kyverno policies
│       └── velero-infra/   # ACK-managed S3 bucket for Velero backups
└── tenants/                # Tenant workload namespaces and resources
    ├── applicationset.yaml
    └── workloads/
```

## How It Works

### GitOps Bridge Pattern

Terraform writes cluster metadata (IRSA ARNs, cluster name, VPC ID, addon flags) into a Kubernetes Secret as annotations. ArgoCD ApplicationSets read these annotations to template which addons to deploy and with what parameters.

```
Terraform → K8s Secret (annotations) → ArgoCD ApplicationSet (templatePatch) → Addon Helm releases
```

The secret is created by the `kubernetes_secret_v1.gitops_bridge` resource in Terraform and lives in the `argocd` namespace with the label `argocd.argoproj.io/secret-type: cluster`.

### ApplicationSet Generators

| ApplicationSet | Generator | Description |
|----------------|-----------|-------------|
| `cluster-addons` | `matrix(clusters + list)` | Deploys standard addons from public Helm repos |
| `custom-addons` | `matrix(clusters + git directory)` | Auto-discovers charts in `custom-addons/charts/*` |
| `tenants` | `matrix(clusters + git directory)` | Deploys tenant workload configurations |

All ApplicationSets use Go templates (`goTemplate: true`) with `missingkey=zero` to handle optional annotations.

## Standard Addons (`addons/applicationset.yaml`)

| Addon | Chart Version | Namespace | AWS Credential Method |
|-------|--------------|-----------|----------------------|
| aws-load-balancer-controller | 1.16.0 | kube-system | IRSA (via eks-blueprints-addons) |
| cluster-autoscaler | 9.44.0 | kube-system | IRSA (via eks-blueprints-addons) |
| metrics-server | 3.13.0 | kube-system | N/A |
| kyverno | 3.5.2 | kyverno | N/A |
| gatekeeper | 3.18.2 | gatekeeper-system | N/A |
| velero | 11.3.2 | velero | Pod Identity (via Terraform) |
| external-dns | 1.15.1 | external-dns | IRSA (via eks-blueprints-addons) |
| cert-manager | 1.17.1 | cert-manager | IRSA (via eks-blueprints-addons) |
| external-secrets | 0.20.1 | external-secrets | IRSA (via eks-blueprints-addons) |

### Per-addon Configuration via `templatePatch`

Addons that need AWS access or cluster-specific config get Helm values injected through the ApplicationSet `templatePatch`. This reads annotations from the GitOps Bridge secret:

```yaml
templatePatch: |
  {{- if eq .addon "cluster-autoscaler" }}
  spec:
    source:
      helm:
        valuesObject:
          autoDiscovery:
            clusterName: {{ .metadata.annotations.cluster_name }}
          awsRegion: {{ .metadata.annotations.aws_region }}
          rbac:
            serviceAccount:
              name: {{ .metadata.annotations.cluster_autoscaler_service_account }}
              annotations:
                eks.amazonaws.com/role-arn: {{ .metadata.annotations.cluster_autoscaler_iam_role_arn }}
  {{- end }}
```

### AWS Credential Patterns

**IRSA (IAM Roles for Service Accounts)** — used by standard addons (LBC, cluster-autoscaler, external-dns, cert-manager, external-secrets):
- Terraform's `eks-blueprints-addons` module creates IRSA roles with `create_kubernetes_resources = false`
- Module outputs `gitops_metadata` (flat map of IRSA ARNs, service accounts, namespaces)
- `gitops_metadata` is merged into the GitOps Bridge secret as annotations
- `templatePatch` reads `{{ .metadata.annotations.<addon>_iam_role_arn }}` and injects into Helm values

**Pod Identity** — used by Velero (preferred over IRSA):
- Terraform creates the IAM Role with a `pods.eks.amazonaws.com` trust policy
- Terraform creates an `aws_eks_pod_identity_association` linking the role to `velero/velero-server`
- The EKS Pod Identity Agent (installed as a managed addon) injects credentials into the pod
- No ServiceAccount annotation needed — the association is managed outside Kubernetes

## Custom Addons (`custom-addons/`)

Custom addons are Helm charts stored directly in this git repository. ArgoCD auto-discovers any subdirectory under `custom-addons/charts/` and creates an Application for it.

### velero-infra

Creates the S3 backup bucket for Velero using ACK (AWS Controllers for Kubernetes):

- **S3 Bucket** — encrypted (AES256), public access fully blocked
- **IAM Role** — managed by Terraform (not ACK) with Pod Identity Association

The ACK S3 controller (running as an EKS Capability) reconciles the `Bucket` CRD and creates the actual S3 bucket in AWS.

### cis-benchmark

Kyverno ClusterPolicies implementing CIS Amazon EKS Benchmark v1.8.0 controls. Deployed in Audit mode by default.

## Bootstrap (`bootstrap/`)

Contains three ArgoCD AppProjects:

| Project | Purpose |
|---------|---------|
| `cluster-addons` | Standard infrastructure addons |
| `custom-addons` | Organization-specific addons |
| `tenants` | Tenant workload namespaces and resources |

Apply these once during initial cluster setup:
```bash
kubectl apply -f gitops/bootstrap/argocd-projects.yaml
```

## Deployment

### Prerequisites

1. EKS cluster with ArgoCD EKS Capability enabled
2. Terraform applied (creates IRSA roles, Pod Identity associations, GitOps Bridge secret)
3. ACK and KRO EKS Capabilities enabled (for custom addons that use ACK CRDs)

### Apply ApplicationSets

```bash
# Bootstrap: create AppProjects
kubectl apply -f gitops/bootstrap/argocd-projects.yaml

# Deploy standard addons
kubectl apply -f gitops/addons/applicationset.yaml

# Deploy custom addons (auto-discovers charts in custom-addons/charts/)
kubectl apply -f gitops/custom-addons/applicationset.yaml

# Deploy tenant workloads
kubectl apply -f gitops/tenants/applicationset.yaml
```

ArgoCD auto-syncs all applications. Monitor status:
```bash
kubectl get applications -n argocd
```

### Adding a New Standard Addon

1. Add an entry to the `elements` list in `addons/applicationset.yaml`:
   ```yaml
   - addon: my-addon
     namespace: my-namespace
     chart: my-chart
     repo: https://my-helm-repo.example.com
     version: "1.0.0"
   ```
2. If the addon needs AWS access, add a `templatePatch` block to inject IRSA/Pod Identity config
3. Enable the addon in the Terraform `addons.yaml` config
4. Run `terraform apply` to create any required IAM roles
5. Push to git — ArgoCD picks up changes automatically

### Adding a New Custom Addon

1. Create a Helm chart directory under `custom-addons/charts/my-addon/`
2. The `custom-addons` ApplicationSet auto-discovers it
3. If values are needed from the GitOps Bridge, add a `templatePatch` block
4. Push to git — ArgoCD creates the Application automatically

### Updating Addon Versions

Change the `version` field in the addon list and push to git. ArgoCD detects the `targetRevision` change and re-syncs.
