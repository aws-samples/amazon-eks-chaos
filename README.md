## Running chaos experiments on microservices in Amazon EKS using AWS Fault Injection Simulator with ChaosMesh and LitmusChaos

This project shows the steps involved to implement the solution architecture explained in this AWS blog: Running chaos experiments on microservices in Amazon EKS using AWS Fault Injection Simulator with ChaosMesh and LitmusChaos

## Prerequisites

- A local machine which has access to AWS
- Following tools on the machine
	- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-install.html)
   	- [Terraform](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli)
  	- [kubectl](https://docs.aws.amazon.com/eks/latest/userguide/install-kubectl.html)
  	- [Helm](https://helm.sh/docs/intro/install/)

Assumption : You already configured a [default] profile in the AWS CLI.

## Instructions

### Step 1 - Clone this GitHub repo to your machine

```bash
git clone git@github.com:aws-samples/amazon-eks-chaos.git
cd amazon-eks-chaos/terraform/
```

### Step 2 - Create the VPC and EKS Cluster with ArgoCD 

```bash
terraform init
terraform plan
terraform apply
```

Fill in the target EKS version that you would like to create, e.g. 1.32
Once you finished the installation, you will get the following outputs.

You can follow the outuput to logon to the ArgoCD UI. 

```bash
Outputs:

access_argocd = <<EOT
export KUBECONFIG="/tmp/chaos-cluster"
aws eks --region <region-name> update-kubeconfig --name chaos-cluster
echo "ArgoCD Username: admin"
echo "ArgoCD Password: $(kubectl get secrets argocd-initial-admin-secret -n argocd --template="{{index .data.password | base64decode}}")"
echo "ArgoCD URL: https://$(kubectl get svc -n argocd argo-cd-argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

EOT
configure_argocd = <<EOT
export KUBECONFIG="/tmp/chaos-cluster"
aws eks --region <region-name> update-kubeconfig --name chaos-cluster
export ARGOCD_OPTS="--port-forward --port-forward-namespace argocd --grpc-web"
kubectl config set-context --current --namespace argocd
argocd login --port-forward --username admin --password $(argocd admin initial-password | head -1)
echo "ArgoCD Username: admin"
echo "ArgoCD Password: $(kubectl get secrets argocd-initial-admin-secret -n argocd --template="{{index .data.password | base64decode}}")"
echo Port Forward: http://localhost:8080
kubectl port-forward -n argocd svc/argo-cd-argocd-server 8080:80

EOT
configure_kubectl = <<EOT
export KUBECONFIG="/tmp/chaos-cluster"
aws eks --region us-east-1 update-kubeconfig --name chaos-cluster
```

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.
