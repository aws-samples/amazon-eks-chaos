# Running chaos experiments on microservices in Amazon EKS using AWS Fault Injection Simulator with ChaosMesh and LitmusChaos

This project shows the steps involved to implement the solution architecture explained in this AWS blog: Running chaos experiments on microservices in Amazon EKS using AWS Fault Injection Simulator with ChaosMesh and LitmusChaos

## Prerequisites

- A local machine which has access to AWS
- Following tools on the machine
	- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-install.html)
   	- [Terraform](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli)
  	- [kubectl](https://docs.aws.amazon.com/eks/latest/userguide/install-kubectl.html)
  	- [Helm](https://helm.sh/docs/intro/install/)

Assumption : You already configured a [default](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-quickstart.html) profile in the AWS CLI with AWS identity and region.

## Instructions

### Step 1 - Deploy EKS Cluster 

####  1.1 - Clone this Github to Local

```bash
git clone git@github.com:aws-samples/amazon-eks-chaos.git
cd amazon-eks-chaos/terraform/
```
#### 1.2 - Create the VPC and EKS Cluster with ArgoCD 

```bash
terraform init
terraform plan
terraform apply
```

Fill in the target EKS version that you would like to create, e.g. 1.31
Once you finished the installation, you will get the following outputs.

You can follow the output to logon to the ArgoCD UI. 

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

### Step 2 - Install application
                 
We will deploy sample applications to provide actual container components that we can inject chaos experiments, you can find the full source code for the sample application [Github](https://github.com/aws-containers/retail-store-sample-app).

Follow below command to create app namespace and deploy application in app namespace    

**Note - Replace `<replaceallwithyourownpassword>` to create your own database password**, the plain text will be automatically base64 encoded during secret creation.

```bash
kubectl create namespace app
kubectl create secret generic catalog-db --from-literal=username=catalog --from-literal=password=<replaceallwithyourownpassword> -n app 
kubectl create secret generic orders-db --from-literal=username=orders --from-literal=password=<replaceallwithyourownpassword> -n app
kubectl apply -f https://github.com/aws-samples/amazon-eks-chaos/blob/main/app/retail-store-sample-app.yaml -n app
```
**Note- You might observe catalog pod in CrashLoopBackOff before it is in running status, which is due to the application dependency on database.** 

### Step 3 - Install Chaos Mesh 

#### 3.1 - Add chaos mesh repo to helm

```bash
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm repo update
```
#### 3.2 - Install Chaos Mesh with containerd runtime 

```bash
helm install chaos-mesh chaos-mesh/chaos-mesh -n=chaos-mesh --set chaosDaemon.runtime=containerd --set chaosDaemon.socketPath=/run/containerd/containerd.sock --version 2.7.0 --create-namespace
```
#### 3.3 - Verify the installations 

```bash
 kubectl get pods --namespace chaos-mesh -l app.kubernetes.io/instance=chaos-mesh
```

expected output:  
```bash
chaos-controller-manager-86fd989fd-4qsnt   1/1     Running   0          54s
chaos-controller-manager-86fd989fd-vgls5   1/1     Running   0          54s
chaos-controller-manager-86fd989fd-zjf9p   1/1     Running   0          54s
chaos-daemon-nrnl5                         1/1     Running   0          54s
chaos-daemon-x2r4j                         1/1     Running   0          54s
chaos-dashboard-54c7d9d-2jfxt              1/1     Running   0          54s
chaos-dns-server-66d757d748-76j9g          1/1     Running   0          54s
```

### Step 4 - Install  Litmus Chaos 

#### 4.1 - Add Litmus helm repo 

```bash
helm repo add litmuschaos https://litmuschaos.github.io/litmus-helm/
helm repo update
```
#### 4.2 - Install Litmus Mesh 

```bash
kubectl apply -f https://github.com/kubernetes-sigs/aws-ebs-csi-driver/blob/master/examples/kubernetes/dynamic-provisioning/manifests/storageclass.yaml - maynot need if add on 
helm install chaos litmuschaos/litmus --namespace=litmus --set portal.frontend.service.type=NodePort --set mongodb.global.storageClass=ebs-sc --create-namespace
```
#### 4.3 - Verify the installations, it takes a few mins for pod set up 

```bash
kubectl get pods -n litmus
```

expected output:  
```bash
chaos-litmus-auth-server-6db8c96466-hl5ps   1/1     Running   0          2m18s
chaos-litmus-frontend-699547f68b-xddf2      1/1     Running   0          2m18s
chaos-litmus-server-54656496c5-pt4gw        1/1     Running   0          2m18s
chaos-mongodb-0                             1/1     Running   0          2m17s
chaos-mongodb-1                             1/1     Running   0          111s
chaos-mongodb-2                             1/1     Running   0          83s
chaos-mongodb-arbiter-0                     1/1     Running   0          2m17s
```

#### Step 4.4 - Install LitmusChaos Operator where it installs all the CRDs required for litmus 

```bash
kubectl apply -f https://litmuschaos.github.io/litmus/litmus-operator-v1.13.8.yaml
```

Verified installation with below command and expected output 

```bash
kubectl get pods -n litmus  | grep ope
chaos-operator-ce-5577475cf5-rbzzh          1/1     Running   0          21s
```


### Step 5 - Set Up AWS Fault injection Service (FIS)

Use FIS to inject Chaos Mesh and Litmus chaos by leveraging action - aws:eks:inject-kubernetes-custom-resource

#### 5.1 - Create FIS role 

The permissions required to use this action are controlled by Kubernetes using RBAC authorization.  Hence, you will need to create a FIS role and mapped into EKS access entry for RBAC permission. 

Create trust policy Json:

```bash
cat >fis-role-trust-policy.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": [
                  "fis.amazonaws.com"
                ]
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
```

Create fis role with above trust relationship: 

```bash
aws iam create-role --role-name fis-role --assume-role-policy-document file://fis-role-trust-policy.json 
```

Expected outcome: 
```bash
{
    "Role": {
        "Path": "/",
        "RoleName": "fis-role",
        ...
        "Arn": "arn:aws:iam::account:role/fis-role",
        ...
```

#### 5.2 - Create CloudWatch Log group for storing fault injection experiment logs

Create CloudWatch log group: 

```bash
aws logs create-log-group --log-group-name fis-chaos
```

Enable fis-role with CloudWatch related permissions: 
```bash
cat >fis-log.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "CloudWatchLogsFullAccess",
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogDelivery",
                "logs:PutResourcePolicy",
                "logs:DescribeResourcePolicies",
                "logs:DescribeLogGroups"
            ],
            "Resource": "*"
        }
    ]
}
EOF
```

Create Policy: 

```bash
aws iam create-policy --policy-name fis-log --policy-document file://fis-log.json 
```

Attach the policy to FIS role: 

```bash
aws iam attach-role-policy --policy-arn arn:aws:iam::<accountnumber>:policy/fis-log --role-name fis-role
```

#### 5.3 - Grant FIS role EKS RBAC access

Grant minimal RBAC privilege for FIS role to interact with litmus chaos and chaos-mesh api resources.: 
```bash
cat >rbac-fis-role.yaml <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: app  #where app is running 
  name: fis-role-litmus
rules:
- apiGroups: ["litmuschaos.io"]
  resources: ["chaosengines","chaosexperiments","chaosresults"]
  verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
# This cluster role binding allows anyone in the "manager" group to read secrets in any namespace.
kind: RoleBinding
metadata:
  name: fis-rolebindings-litmus
  namespace: app
subjects:
- kind: Group
  name: fis # Name is case sensitive
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: fis-role-litmus
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: chaos-mesh
  name: fis-role-chaos-mesh
rules:
- apiGroups: ["chaos-mesh.org"] 
  resources: ["*"]
  verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
# This cluster role binding allows anyone in the "manager" group to read secrets in any namespace.
kind: RoleBinding
metadata:
  name: fis-rolebindings-chaos-mesh
  namespace: chaos-mesh
subjects:
- kind: Group
  name: fis # Name is case sensitive
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: fis-role-chaos-mesh
  apiGroup: rbac.authorization.k8s.io
EOF
```
Run below command to create role and rolebindings 
```
kubectl apply -f rbac-fis-role.yaml
```

#### 5.4 - Create EKS Cluster Access entry for fis-role: 

Use below command to bind fis role with above RBAC permission granted: 

```bash
aws eks create-access-entry --cluster-name chaos-cluster --principal-arn arn:aws:iam::xxxxxx:role/fis-role --type STANDARD --kubernetes-groups fis 
```
**Note - replace xxxxxx to your own AWS account number**

### Step 6 - Create FIS experiment template - Litmus Chaos 

Injecting http reset peer chaos  to application pod via AWS FIS through Litmus chaos experiment. 

http reset peer chaos experiment injects http reset on the service whose port is provided as TARGET_SERVICE_PORT which stops outgoing http requests by resetting the TCP connection by starting proxy server and then redirecting the traffic through the proxy server. It can test the application's resilience to lossy/flaky http connection.

#### 6.1 - Create pod-http-reset-peer experiment resource in the namespace where application is deployed.

Use below command:

```bash
kubectl apply -f "https://hub.litmuschaos.io/api/chaos/master?file=faults/kubernetes/pod-http-reset-peer/fault.yaml" -n app
```
Verify the installation:

```bash
kubectl get chaosexperiments -n app | grep http
pod-http-reset-peer   6s
```

#### 6.2 - Grant pod-http-reset-peer chaos minimal RBAC permission

Please copy below content and save as pod-http-reset-peer-rbac.yaml, change the namespace to the namespace where application is deployed: 

```bash
cat >pod-http-reset-peer-rbac.yaml <<EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pod-http-reset-peer-sa
  namespace: app #application namespace
  labels:
    name: pod-http-reset-peer-sa
    app.kubernetes.io/part-of: litmus
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-http-reset-peer-sa
  namespace: app
  labels:
    name: pod-http-reset-peer-sa
    app.kubernetes.io/part-of: litmus
rules:
  # Create and monitor the experiment & helper pods
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create","delete","get","list","patch","update", "deletecollection"]
  # Performs CRUD operations on the events inside chaosengine and chaosresult
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create","get","list","patch","update"]
  # Fetch configmaps details and mount it to the experiment pod (if specified)
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get","list",]
  # Track and get the runner, experiment, and helper pods log
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get","list","watch"]
  # for creating and managing to execute comands inside target container
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["get","list","create"]
  # deriving the parent/owner details of the pod(if parent is anyof {deployment, statefulset, daemonsets})
  - apiGroups: ["apps"]
    resources: ["deployments","statefulsets","replicasets", "daemonsets"]
    verbs: ["list","get"]
  # deriving the parent/owner details of the pod(if parent is deploymentConfig)
  - apiGroups: ["apps.openshift.io"]
    resources: ["deploymentconfigs"]
    verbs: ["list","get"]
  # deriving the parent/owner details of the pod(if parent is deploymentConfig)
  - apiGroups: [""]
    resources: ["replicationcontrollers"]
    verbs: ["get","list"]
  # deriving the parent/owner details of the pod(if parent is argo-rollouts)
  - apiGroups: ["argoproj.io"]
    resources: ["rollouts"]
    verbs: ["list","get"]
  # for configuring and monitor the experiment job by the chaos-runner pod
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["create","list","get","delete","deletecollection"]
  # for creation, status polling and deletion of litmus chaos resources used within a chaos workflow
  - apiGroups: ["litmuschaos.io"]
    resources: ["chaosengines","chaosexperiments","chaosresults"]
    verbs: ["create","list","get","patch","update","delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pod-http-reset-peer-sa
  namespace: app
  labels:
    name: pod-http-reset-peer-sa
    app.kubernetes.io/part-of: litmus
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: pod-http-reset-peer-sa
subjects:
- kind: ServiceAccount
  name: pod-http-reset-peer-sa
  namespace: app
EOF
```

Use below command to apply: 

```bash
kubectl apply -f pod-http-reset-peer-rbac.yaml 
```

#### 6.3 - Create FIS experiment template 

Use below command to create FIS experiment template, please replace value for cluster arn, ui pod name, fis role arn, CloudWatch Log group: 

Get ui pod name: 
```bash
kubectl get pod -n app | grep ui 
ui-cc49d69f-xcqxn                 1/1     Running 
```

```bash
aws fis create-experiment-template \
    --cli-input-json '{
        "description": "fis-litmus-chaos",
        "targets": {
                "Cluster-Target-1": {
                        "resourceType": "aws:eks:cluster",
                        "resourceArns": [
                                "arn:aws:eks:ap-southeast-2:<accountnumber>:cluster/chaos-cluster"
                        ],
                        "selectionMode": "ALL"
                }
        },
        "actions": {
                "http-reset-peer": {
                        "actionId": "aws:eks:inject-kubernetes-custom-resource",
                        "description": "litmus-http-reset-peer-chaos",
                        "parameters": {
                                "kubernetesApiVersion": "litmuschaos.io/v1alpha1",
                                "kubernetesKind": "ChaosEngine",
                                "kubernetesNamespace": "app",
                                "kubernetesSpec": "{   \"engineState\": \"active\",   \"applabel\": \"app=ui\",   \"annotationCheck\": \"false\",   \"appinfo\": {     \"appns\": \"app\",     \"applabel\": \"app.kubernetes.io/name=ui\",     \"appkind\": \"deployment\"   },   \"chaosServiceAccount\": \"pod-http-reset-peer-sa\",   \"experiments\": [     {       \"name\": \"pod-http-reset-peer\",       \"spec\": {         \"components\": {           \"env\": [             {               \"name\": \"TARGET_PODS\",               \"value\": \"ui-cc49d69f-xcqxn\"             },             {               \"name\": \"TOXICITY\",               \"value\": \"100\"             },             {               \"name\": \"TARGET_SERVICE_PORT\",               \"value\": \"8080\"             }           ]         }       }     }   ] }",
                                "maxDuration": "PT2M"
                        },
                        "targets": {
                                "Cluster": "Cluster-Target-1"
                        }
                }
        },
        "stopConditions": [
                {
                        "source": "none"
                }
        ],
        "roleArn": "arn:aws:iam::<accountnumber>:role/fis-role",
        "tags": {},
        "logConfiguration": {
                "cloudWatchLogsConfiguration": {
                        "logGroupArn": "arn:aws:logs:ap-southeast-2:<accountnumber>:log-group:fis-chaos:*"
                },
                "logSchemaVersion": 2
        },
        "experimentOptions": {
                "accountTargeting": "single-account",
                "emptyTargetResolutionMode": "fail"
        }
}'
```

Record experiment template ID or query the experiment template ID 
```bash
aws fis list-experiment-templates | grep lit -B1
```

Expected outcome 
```bash
 "id": "EXT5ZByKtF4sgEL",
 "description": "fis-litmus-chaos",
```

#### 6.4 - Run FIS fault injections 

Verify pod is up and running before running the FIS experiment: 

Get ui pod IP 
```bash
kubectl get pod -n app -o wide | grep ui 
ui-d6bddf848-ghr4b                1/1     Running   2 (6d ago)    10d   172.31.38.116   ip-172-31-47-5.ec2.internal   <none>           <none>
```

Deploy a pod with networking utility pre-installed to check the test response: 
```bash
kubectl apply -f https://k8s.io/examples/admin/dns/dnsutils.yaml
kubectl exec -it dnsutils -- bash
```

Check HTTP response before Fault injection with below expected HTTP 200 response code: 

```bash
bash-5.0# curl 172.31.30.32:8080 -kv
*   Trying 172.31.30.32:8080...
* Connected to 172.31.30.32 (172.31.30.32) port 8080 (#0)
> GET / HTTP/1.1
> Host: 172.31.30.32:8080
> User-Agent: curl/7.79.1
> Accept: */*
> 
* Mark bundle as not supporting multiuse
< HTTP/1.1 200 OK
< Content-Type: text/html
```

Run experiment: 
```bash
aws fis start-experiment --experiment-template-id EXT5ZByKtF4sgEL 
```

Output: 
```bash
{
    "experiment": {
        "id": "EXPpH5gti5bgNFXv1Y",
        "experimentTemplateId": "EXT5ZByKtF4sgEL",
...
```

During experiment, see the connection reset error triggered 
```bash
 curl 172.31.30.32:8080 -kv
*   Trying 172.31.30.32:8080...
* Connected to 172.31.30.32 (172.31.30.32) port 8080 (#0)
> GET / HTTP/1.1
> Host: 172.31.30.32:8080
> User-Agent: curl/7.79.1
> Accept: */*
> 
* Empty reply from server
* Closing connection 0
curl: (52) Empty reply from server
```

Verify the expriment is in completed status: 

```bash
aws fis get-experiment --id EXPpH5gti5bgNFXv1Y | grep status 
            "status": "completed",
                    "status": "completed",
```

### Step 7 - Create FIS experiment template - Chaos-Mesh 

Chaos Mesh offers a diverse range of Kubernetes chaos experiments. The container Kill action, for instance, simulates container kill, allowing you to test the resilience of your applications in the face of such disruptions.

#### 7.1 - Get application pod label and container name 

Pod label can be be used to select pod target, use below command to show labels for each pod in a particular namespace 

```bash
kubectl get pod -n app --show-labels | grep checkout
checkout-7b68fd5f58-llwbb         1/1     Running   0              4d11h   app.kuberneres.io/owner=retail-store-sample,app.kubernetes.io/component=service,app.kubernetes.io/instance=checkout,app.kubernetes.io/name=checkout,pod-template-hash=7b68fd5f58
```

Use below command to grep checkout pod container name: 
```bash
kubectl get pod checkout-7b68fd5f58-llwbb -o jsonpath='{.spec.containers[*].name}' -n app          
checkout               
```
#### 7.2 - Create FIS experiment template 

Use below command to create FIS experiment template: 

```bash
aws fis create-experiment-template \
    --cli-input-json '{
        "description": "chaos-mesh-container-kill",
        "targets": {
                "Cluster-Target-1": {
                        "resourceType": "aws:eks:cluster",
                        "resourceArns": [
                                "arn:aws:eks:ap-southeast-2:<accountnumber>:cluster/chaos-cluster"
                        ],
                        "selectionMode": "ALL"
                }
        },
        "actions": {
                "chaos-mesh-container-kill": {
                        "actionId": "aws:eks:inject-kubernetes-custom-resource",
                        "description": "chaos-mesh-container-kill",
                        "parameters": {
                                "kubernetesApiVersion": "chaos-mesh.org/v1alpha1",
                                "kubernetesKind": "PodChaos",
                                "kubernetesNamespace": "chaos-mesh",
                                "kubernetesSpec": "{   \"action\": \"container-kill\",   \"mode\": \"one\",   \"containerNames\": [     \"checkout\"   ],   \"selector\": {     \"namespaces\": [       \"app\"     ],     \"labelSelectors\": {       \"app.kubernetes.io/name\": \"checkout\"     }   } }",
                                "maxDuration": "PT1M"
                        },
                        "targets": {
                                "Cluster": "Cluster-Target-1"
                        }
                }
        },
        "stopConditions": [
                {
                        "source": "none"
                }
        ],
        "roleArn": "arn:aws:iam::xxxxxx:role/fis-role",
        "tags": {
                "Name": "chaos-mesh-container-kill"
        },
        "logConfiguration": {
                "cloudWatchLogsConfiguration": {
                        "logGroupArn": "arn:aws:logs:ap-southeast-2:<accountnumber>:log-group:fis-chaos:*"
                },
                "logSchemaVersion": 2
        },
        "experimentOptions": {
                "accountTargeting": "single-account",
                "emptyTargetResolutionMode": "fail"
        }
}'
```

Record experiment template ID or query the experiment template ID: 

```bash
aws fis list-experiment-templates --region us-east-1 | grep chaos-mesh -B1
```

Expected outcome: 
```bash
 "id": "EXT3biMwNMevDYtg8",
 "description": "chaos-mesh-container-kill",
```

#### 7.3 - Run FIS fault injections 

**Note**
chaos-mesh is facing an known limit documented in github issue (https://github.com/chaos-mesh/chaos-mesh/issues/2187)

Error when run chaos injection captured from chaos-mesh controller log: 

```bash
2024-07-01T13:58:23.946Z        DEBUG   controller-runtime.webhook.webhooks     admission/http.go:143   wrote response  {"webhook": "/validate-auth", "code": 403, "reason": "fis is forbidden on namespace app", "UID": "f05fbce2-4a23-4dd5-9d7f-78cbfa5cc574", "allowed": false}
```

Proposed fix: 

```bash
kubectl delete validatingwebhookconfigurations.admissionregistration.k8s.io chaos-mesh-validation-auth
```

Verify check out pod status: 

```bash
kubectl get pod -n app | grep checkout  
checkout-778f5f98cf-q92gn         1/1     Running   0             53s
```

Run experiment 

```bash
aws fis start-experiment --experiment-template-id EXT3biMwNMevDYtg8
```

Output: 
```bash
{
    "experiment": {
        "id": "EXPFUuXSsHEugGq9aS",
        "experimentTemplateId": "EXT3biMwNMevDYtg8",
        ...
```

Verify the experiment is in completed status:
```bash
aws fis get-experiment --id EXPFUuXSsHEugGq9aS | grep status 
            "status": "completed",
                    "status": "completed",
```

Check pod status, and verify the container is restarted: 
```
kubectl get pod -n app | grep checkout 
checkout-778f5f98cf-q92gn         1/1     Running   1 (4m8s ago)   6m4s
```

```bash
kubectl describe pod -n app checkout-778f5f98cf-q92gn

  Restart Count:  1
  
Events:
  Type     Reason            Age                    From               Message
  ----     ------            ----                   ----               -------
  Normal   Pulled            4m41s (x2 over 6m34s)  kubelet            Container image "public.ecr.aws/aws-containers/retail-store-sample-checkout:0.7.1" already present on machine
  Normal   Created           4m41s (x2 over 6m34s)  kubelet            Created container checkout
  Normal   Started           4m40s (x2 over 6m33s)  kubelet            Started container checkout

```

Check chaos mesh log for successful executions: 

```bash
kubectl logs -n chaos-mesh -l app.kubernetes.io/component=controller-manager
```

## Clean up 

### Uninstall Chaos Mesh, Litmus Chaos and sample applications

```bash
helm uninstall chaos-mesh -n chaos-mesh
helm uninstall chaos -n litmus
kubectl delete namespace -n chaos-mesh
kubectl delete namespace -n litmus
kubectl delete -f https://github.com/aws-samples/amazon-eks-chaos/blob/main/app/retail-store-sample-app.yaml -n app
kubectl delete namespace -n app
```

### Delete all the FIS and IAM Roles manually created above

### Destroy the Terraform Resource

```bash
terraform destroy
```

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.
