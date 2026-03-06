# AWS EKS Cluster with Terraform -- Multi-Environment

Production-ready Amazon EKS cluster with autoscaling nodes, ALB ingress, and NAT gateway egress -- fully managed via Terraform with isolated **systest** and **prod** environments.

## Architecture

```
                    ┌─── Internet ───┐
                    │                │
                    ▼                │
              ┌───────────┐         │
              │    ALB     │         │
              │ (public)   │         │
              └─────┬─────┘         │
                    │                │
    ┌───────────────┼────────────────┼───────────────────┐
    │  VPC          │                │                    │
    │               │                │                    │
    │  ┌────────────┼─── Public Subnets ──────────────┐  │
    │  │            │                ▲                  │  │
    │  │      ┌─────┘          ┌─────┴─────┐          │  │
    │  │      │                │ NAT GW(s) │          │  │
    │  │      │                └─────┬─────┘          │  │
    │  └──────┼──────────────────────┼────────────────┘  │
    │         │                      │                    │
    │  ┌──────┼─── Private Subnets ──┼────────────────┐  │
    │  │      ▼                      │                 │  │
    │  │  ┌───────┐  ┌───────┐  ┌───────┐            │  │
    │  │  │ Node  │  │ Node  │  │ Node  │  ◄── ASG   │  │
    │  │  │ (Pod) │  │ (Pod) │  │ (Pod) │            │  │
    │  │  └───────┘  └───────┘  └───────┘            │  │
    │  │         egress via NAT ──►                    │  │
    │  └───────────────────────────────────────────────┘  │
    └─────────────────────────────────────────────────────┘

  systest: VPC 10.10.0.0/16  |  prod: VPC 10.20.0.0/16
```

**Traffic flow:**
- **Ingress:** Internet -> ALB (public subnets) -> Pods (private subnets)
- **Egress:** Pods (private subnets) -> NAT Gateway (public subnets) -> Internet

## Environment Comparison

| Setting | systest | prod |
|---|---|---|
| VPC CIDR | `10.10.0.0/16` | `10.20.0.0/16` |
| NAT Gateways | 1 (single) | 3 (one per AZ) |
| Node type | `t3.medium` (SPOT) | `m5.large` / `m5a.large` (ON_DEMAND) |
| Node count | 1-4 (desired: 2) | 3-15 (desired: 3) |
| Disk size | 30 GiB | 100 GiB |
| API endpoint | Public + Private | Private only |
| Log retention | 14 days | 90 days |
| State key | `eks/systest/terraform.tfstate` | `eks/prod/terraform.tfstate` |

## Features

| Feature | Description |
|---|---|
| **Multi-Environment** | Isolated state, networking, and configuration per environment |
| **VPC** | Multi-AZ VPC with public/private subnets, proper EKS/ALB subnet tagging |
| **NAT Gateways** | Single NAT (systest) or one-per-AZ (prod) for HA egress |
| **EKS** | Managed control plane with envelope encryption (KMS), full control plane logging |
| **Managed Node Groups** | Autoscaling worker nodes in private subnets with SSM access |
| **AWS Load Balancer Controller** | ALB ingress via Helm with IRSA |
| **Cluster Autoscaler** | Automatic node scaling via Helm with IRSA |
| **Metrics Server** | Enables Horizontal Pod Autoscaler (HPA) |
| **EBS CSI Driver** | EKS managed add-on for persistent block storage (EBS volumes) |
| **S3 CSI Driver** | Mountpoint for Amazon S3 -- mount S3 buckets as pod filesystems |
| **EFS CSI Driver** | ReadWriteMany persistent storage via Amazon EFS |
| **Secrets Store CSI Driver** | Mount AWS Secrets Manager / SSM parameters as K8s volumes |
| **VPC Flow Logs** | Network audit trail to CloudWatch |
| **IRSA** | OIDC-based pod-level IAM via service accounts |
| **EKS Add-ons** | Managed VPC CNI, CoreDNS, kube-proxy |

## Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.5.0
- [AWS CLI](https://aws.amazon.com/cli/) v2 configured with appropriate credentials
- [kubectl](https://kubernetes.io/docs/tasks/tools/) >= 1.28
- [Helm](https://helm.sh/docs/intro/install/) >= 3.0
- An S3 bucket and DynamoDB table for Terraform remote state (see [Remote State Setup](#remote-state-setup))
- An AWS account with permissions to create EKS, VPC, IAM, KMS, and ELB resources

## Quick Start

### 1. Set up remote state (one-time)

Create the S3 bucket and DynamoDB lock table referenced in `environments/*/backend.tf`:

```bash
# Replace bucket name with your own in environments/systest/backend.tf and environments/prod/backend.tf
aws s3api create-bucket \
  --bucket my-terraform-state-bucket \
  --region us-west-2 \
  --create-bucket-configuration LocationConstraint=us-west-2

aws s3api put-bucket-versioning \
  --bucket my-terraform-state-bucket \
  --versioning-configuration Status=Enabled

aws dynamodb create-table \
  --table-name terraform-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

### 2. Deploy systest

```bash
# Initialize with systest backend config
terraform init -backend-config=environments/systest/backend.tf

# Plan and apply
terraform plan  -var-file=environments/systest/terraform.tfvars -out=tfplan
terraform apply tfplan
```

### 3. Deploy prod

```bash
# Re-initialize with prod backend config (use -reconfigure to switch backends)
terraform init -reconfigure -backend-config=environments/prod/backend.tf

# Plan and apply
terraform plan  -var-file=environments/prod/terraform.tfvars -out=tfplan
terraform apply tfplan
```

### 4. Connect to a cluster

```bash
# The exact command is shown in the terraform output after apply
# systest
aws eks update-kubeconfig --region us-west-2 --name eks-cluster-systest

# prod
aws eks update-kubeconfig --region us-west-2 --name eks-cluster-prod

# Verify
kubectl get nodes
kubectl get pods -A
```

### 5. Deploy a sample app with ALB ingress

```bash
kubectl apply -f examples/sample-ingress.yaml

# Wait for the ALB to provision (~2-3 minutes)
kubectl get ingress sample-app -w
```

## Switching Between Environments

Since both environments share the same Terraform root module but use different S3 backend keys, you must re-initialize when switching:

```bash
# Switch to systest
terraform init -reconfigure -backend-config=environments/systest/backend.tf

# Switch to prod
terraform init -reconfigure -backend-config=environments/prod/backend.tf
```

Always verify which environment you are targeting before running `plan` or `apply`:

```bash
# Check current state
terraform output cluster_name
```

## Project Structure

```
.
├── main.tf                                    # Root: wires VPC, EKS, and addons together
├── variables.tf                               # All input variables with validation
├── outputs.tf                                 # Useful outputs (kubectl command, IPs, ARNs)
├── providers.tf                               # AWS, Kubernetes, and Helm provider config
├── versions.tf                                # Terraform/provider versions + S3 backend stub
├── .gitignore
├── environments/
│   ├── systest/
│   │   ├── terraform.tfvars                   # systest variable values (SPOT, small nodes, 1 NAT)
│   │   └── backend.tf                         # S3 backend config for systest state
│   └── prod/
│       ├── terraform.tfvars                   # prod variable values (ON_DEMAND, large nodes, 3 NATs)
│       └── backend.tf                         # S3 backend config for prod state
├── examples/
│   └── sample-ingress.yaml                    # Sample Deployment + Service + ALB Ingress
└── modules/
    ├── vpc/
    │   ├── main.tf                            # VPC, subnets, NAT GWs, route tables, flow logs
    │   ├── variables.tf
    │   └── outputs.tf
    ├── eks/
    │   ├── main.tf                            # EKS cluster, node groups, OIDC, KMS, SGs, EBS CSI add-on
    │   ├── variables.tf
    │   └── outputs.tf
    └── addons/
        ├── main.tf                            # ALB Controller, Autoscaler, Metrics Server, S3/EFS/Secrets CSI
        ├── variables.tf
        ├── outputs.tf
        └── policies/
            └── alb-controller-policy.json     # IAM policy for ALB Controller
```

## Configuration

### Key Variables

| Variable | Description | systest | prod |
|---|---|---|---|
| `environment` | Environment name (no default -- must be set) | `systest` | `prod` |
| `vpc_cidr` | VPC address space | `10.10.0.0/16` | `10.20.0.0/16` |
| `single_nat_gateway` | Single NAT vs one-per-AZ | `true` | `false` |
| `cluster_endpoint_public_access` | Public API server | `true` | `false` |
| `node_instance_types` | EC2 instance types | `["t3.medium"]` | `["m5.large", "m5a.large"]` |
| `node_capacity_type` | SPOT or ON_DEMAND | `SPOT` | `ON_DEMAND` |
| `node_min_size` / `node_max_size` | Autoscaler bounds | `1` / `4` | `3` / `15` |
| `cluster_log_retention_days` | Log retention | `14` | `90` |
| `enable_ebs_csi_driver` | EBS persistent volumes | `true` | `true` |
| `enable_secrets_store_csi_driver` | Secrets Manager mounts | `false` | `true` |

See `variables.tf` for the full list with descriptions and validation rules.

### Adding a New Environment

1. Create `environments/<name>/terraform.tfvars` (copy from `systest` and adjust)
2. Create `environments/<name>/backend.tf` with a unique `key`
3. Add the environment name to the validation list in `variables.tf`
4. Deploy:
   ```bash
   terraform init -backend-config=environments/<name>/backend.tf
   terraform plan  -var-file=environments/<name>/terraform.tfvars -out=tfplan
   terraform apply tfplan
   ```

## Remote State Setup

Each environment stores its Terraform state in a separate S3 key within the same bucket:

```
s3://my-terraform-state-bucket/
  ├── eks/systest/terraform.tfstate
  └── eks/prod/terraform.tfstate
```

This ensures complete state isolation -- changes to systest can never accidentally affect prod. The DynamoDB table provides state locking to prevent concurrent modifications.

Update the bucket name and region in:
- `environments/systest/backend.tf`
- `environments/prod/backend.tf`

## Best Practices Applied

### Security
- Kubernetes secrets encrypted at rest with a dedicated KMS key (auto-rotated)
- Nodes in private subnets with no public IPs
- IRSA (IAM Roles for Service Accounts) for least-privilege pod-level IAM
- VPC flow logs for network auditing
- Security groups with minimal required rules
- SSM-enabled nodes (no SSH keys needed)
- Separate cluster and node security groups
- Prod API endpoint is private-only (no public access)

### Multi-Environment Isolation
- Separate VPC CIDRs (non-overlapping, safe for VPC peering)
- Separate S3 state keys with DynamoDB locking
- Environment name embedded in all resource names and tags
- No default on `environment` variable -- forces explicit selection

### Networking
- Multi-AZ deployment across 3 availability zones
- Proper EKS subnet tagging (`kubernetes.io/role/elb`, `kubernetes.io/role/internal-elb`)
- ALB in public subnets, pods in private subnets
- NAT gateways for controlled egress (HA in prod)

### Reliability
- Managed node groups with rolling updates (`max_unavailable_percentage = 25`)
- Cluster Autoscaler with `least-waste` expander and scale-down delays
- Metrics Server for HPA support
- `ignore_changes` on `desired_size` to prevent Terraform from fighting with autoscaler

### Observability
- All 5 EKS control plane log types enabled
- CloudWatch log retention: 14 days (systest), 90 days (prod)
- VPC flow logs with configurable retention

## ALB Ingress Usage

The AWS Load Balancer Controller watches for `Ingress` resources and creates ALBs automatically. Key annotations:

```yaml
annotations:
  kubernetes.io/ingress.class: alb
  alb.ingress.kubernetes.io/scheme: internet-facing    # or "internal"
  alb.ingress.kubernetes.io/target-type: ip            # direct pod targeting
  alb.ingress.kubernetes.io/certificate-arn: <acm-arn> # for HTTPS
  alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
  alb.ingress.kubernetes.io/ssl-redirect: "443"
```

See `examples/sample-ingress.yaml` for a full working example.

## CSI Drivers

Four CSI drivers are available, each gated by a feature flag. The EBS driver uses the EKS managed add-on; the others use Helm charts. All use IRSA for IAM.

| Driver | Variable | Delivery | Default |
|---|---|---|---|
| Amazon EBS CSI | `enable_ebs_csi_driver` | EKS managed add-on | `true` |
| Mountpoint for S3 | `enable_s3_csi_driver` | Helm | `false` |
| Amazon EFS CSI | `enable_efs_csi_driver` | Helm | `false` |
| Secrets Store CSI | `enable_secrets_store_csi_driver` | Helm (2 charts) | `false` |

### EBS CSI Driver -- Persistent Block Storage

Enabled by default. Creates a `gp3` StorageClass for dynamic provisioning:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-ebs-pvc
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: gp3
  resources:
    requests:
      storage: 10Gi
```

### S3 CSI Driver -- Mount S3 Buckets

Mount an S3 bucket as a filesystem in your pods:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: s3-pv
spec:
  capacity:
    storage: 1200Gi  # ignored by Mountpoint, required by K8s
  accessModes: [ReadWriteMany]
  mountOptions:
    - allow-delete
    - region us-west-2
  csi:
    driver: s3.csi.aws.com
    volumeHandle: s3-csi-driver-volume
    volumeAttributes:
      bucketName: my-bucket
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: s3-pvc
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ""
  resources:
    requests:
      storage: 1200Gi
  volumeName: s3-pv
```

> **Note:** The S3 CSI driver IRSA role has broad S3 access. For production, scope the IAM policy to specific bucket ARNs.

### EFS CSI Driver -- Shared Filesystem (ReadWriteMany)

Create an EFS filesystem first, then use dynamic provisioning:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: fs-0123456789abcdef0
  directoryPerms: "700"
  basePath: "/dynamic_provisioning"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: efs-pvc
spec:
  accessModes: [ReadWriteMany]
  storageClassName: efs-sc
  resources:
    requests:
      storage: 5Gi
```

> **Note:** You must create the EFS filesystem and mount targets separately (or add them to the Terraform config). The CSI driver only handles the K8s-to-EFS binding.

### Secrets Store CSI Driver -- Mount AWS Secrets

Mount secrets from AWS Secrets Manager or SSM Parameter Store as volumes:

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: my-aws-secrets
spec:
  provider: aws
  parameters:
    objects: |
      - objectName: "my-secret"
        objectType: "secretsmanager"
      - objectName: "/my/ssm/parameter"
        objectType: "ssmparameter"
---
apiVersion: v1
kind: Pod
metadata:
  name: my-app
spec:
  serviceAccountName: my-app  # must have IRSA role with secrets access
  containers:
    - name: app
      image: my-app:latest
      volumeMounts:
        - name: secrets
          mountPath: /mnt/secrets
          readOnly: true
  volumes:
    - name: secrets
      csi:
        driver: secrets-store.csi.k8s.io
        readOnly: true
        volumeAttributes:
          secretProviderClass: my-aws-secrets
```

> **Note:** The Terraform-managed IRSA role provides the provider DaemonSet its baseline permissions. Individual application pods need their own IRSA roles scoped to their specific secrets.

## Scaling

### Cluster Autoscaler (node-level)

Nodes scale automatically based on pod scheduling pressure. The autoscaler is configured to:
- Discover node groups via ASG tags (`k8s.io/cluster-autoscaler/enabled`)
- Use the `least-waste` expander to choose the best node group
- Wait 5 minutes before scaling down idle nodes
- Balance nodes across similar node groups

### Horizontal Pod Autoscaler (pod-level)

With Metrics Server installed, you can use HPA:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-app
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

## Teardown

```bash
# 1. Switch to the target environment
terraform init -reconfigure -backend-config=environments/<env>/backend.tf

# 2. Delete Kubernetes resources first (to clean up ALBs and target groups)
kubectl delete ingress --all -A

# 3. Wait for ALBs to be deprovisioned, then destroy infrastructure
terraform destroy -var-file=environments/<env>/terraform.tfvars
```

**Important:** Always delete Kubernetes `Ingress` and `Service` (type LoadBalancer) resources before running `terraform destroy`. Otherwise the ALBs/NLBs created by the controller will be orphaned and block VPC/subnet deletion.

## Cost Considerations

| Resource | systest (est. monthly) | prod (est. monthly) |
|---|---|---|
| EKS control plane | ~$73 | ~$73 |
| NAT Gateway(s) | ~$32 (1 GW) | ~$96 (3 GWs) |
| Nodes | ~$20 (2x t3.medium SPOT) | ~$210 (3x m5.large ON_DEMAND) |
| ALB | ~$22 + LCU | ~$22 + LCU |
| KMS key | ~$1 | ~$1 |
| **Total baseline** | **~$148** | **~$402** |

**Cost-saving tips for systest:**
- SPOT nodes are already configured (~60-70% savings vs ON_DEMAND)
- Single NAT gateway saves ~$64/mo vs one-per-AZ
- Shorter log retention (14 days) reduces CloudWatch costs

## Troubleshooting

**Nodes not joining the cluster:**
```bash
aws eks describe-nodegroup --cluster-name <name> --nodegroup-name <name>-default
kubectl get pods -n kube-system
```

**ALB not provisioning:**
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
aws ec2 describe-subnets --filters "Name=tag:kubernetes.io/role/elb,Values=1"
```

**Cluster Autoscaler not scaling:**
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler
aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?Tags[?Key=='k8s.io/cluster-autoscaler/enabled']]"
```

**Wrong environment targeted:**
```bash
# Always verify before plan/apply
terraform output cluster_name
```

## License

MIT
