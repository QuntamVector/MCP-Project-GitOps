# MCP Platform — Complete Project Guide

---

## Project Title

> **"QuantamVector MCP Platform — Cloud-Native AI Microservices on AWS EKS with GitOps, IRSA & Automated TLS"**

---

## Why This Project Is Important

This project demonstrates the **full DevOps + Cloud-Native + AI engineering stack** in a single, production-grade system:

| Dimension | What it proves |
|-----------|---------------|
| **Cloud** | AWS EKS cluster management, RDS PostgreSQL, ECR image registry |
| **GitOps** | ArgoCD with 7-wave ordered deployment, sync waves, self-healing |
| **Security** | IRSA (fine-grained AWS permissions without static credentials), JWT auth, TLS/HTTPS |
| **AI/ML** | OpenAI GPT-4o integration, tool-calling AI agent, recommendation engine |
| **Microservices** | 10 independently deployable services with clean boundaries |
| **Observability** | Prometheus ServiceMonitor + alerting rules, health probes on every pod |
| **Scalability** | HPA on 3 services, Kustomize overlays per environment |
| **IaC** | Kustomize + Helm chart dual strategy, Terraform placeholder |

---

## All Microservices — What Each One Does

### Architecture at a Glance

```
Internet
   │
   ▼ HTTPS (cert-manager + Let's Encrypt)
[ Nginx Ingress ]
   │
   ├── /          →  Frontend (React 18 + Vite + Nginx)
   └── /api/*     →  MCP API Gateway
                          │
            ┌─────────────┼────────────────────┐
            │             │                    │
       auth-service  model-service       ai-assistant
       user-service  recommendation-   payment-service
       (RDS Postgres) engine            product-service
                          │             mcp-control-plane
                          └─────────────────────┘
                                    │
                             [ AWS EKS + RDS ]
```

---

### 1. `mcp-api-gateway` (port 8000)
**Role:** Single entry point for all backend traffic.
**How:** Acts as a reverse proxy — receives `/api/{service}/{path}` and forwards to the correct internal service using Kubernetes DNS (`http://service-name:port`).
**Key file:** `services/mcp-api-gateway/main.py`

---

### 2. `auth-service` (port 8001)
**Role:** User registration, login, JWT token issuance and verification.
**How:** Stores users in **AWS RDS PostgreSQL**. Issues HS256 JWT tokens with 8-hour expiry. Seeds `admin/admin123` on startup. bcrypt password hashing.
**Endpoints:** `/register`, `/login`, `/verify-header`, `/refresh`

---

### 3. `mcp-control-plane` (port 8008)
**Role:** Cluster observability and model registry. The only service with **IRSA**.
**How:** Uses `kubernetes` Python SDK (in-cluster config) for pod/node metrics. Uses `boto3` with IRSA to call EKS API (`DescribeCluster`, `ListNodegroups`). Also maintains an in-memory model registry.
**Endpoints:** `/status`, `/namespaces`, `/models`

---

### 4. `model-service` (port 8002)
**Role:** OpenAI inference wrapper.
**How:** Accepts `model_id` + `prompt`, calls OpenAI Chat Completions API, returns `response` + token `usage`.
**Models:** `gpt-4o`, `gpt-4o-mini`, `gpt-4-turbo`

---

### 5. `ai-assistant` (port 8003)
**Role:** Agentic AI that answers questions about the live platform.
**How:** Uses **OpenAI tool-calling** in a loop (max 5 rounds). Tools let the AI query `mcp-control-plane`, `product-service`, `user-service`, `payment-service`, and `model-service` in real time before answering.
**Endpoints:** `/chat`, `/summarize`

---

### 6. `recommendation-engine` (port 8004)
**Role:** Personalized AI recommendations.
**How:** Passes `user_id`, `context`, and history to GPT-4o-mini, which returns JSON recommendations with `id`, `title`, `reason`, `score`.
**Endpoints:** `/recommend`, `/similar/{item_id}`

---

### 7. `product-service` (port 8005)
**Role:** Product catalog CRUD.
**How:** In-memory store (demo data: AI Widget, ML Toolkit). Full CRUD with category filtering.
**Endpoints:** `/products` (GET/POST), `/products/{id}` (GET/PUT/DELETE)

---

### 8. `user-service` (port 8006)
**Role:** User profile management (reads from RDS, does NOT handle auth).
**How:** Reads/writes the same `users` table as auth-service in **AWS RDS PostgreSQL**. No password operations — delegates authentication to auth-service.
**Endpoints:** `/users` (list), `/users/{id}` (get/update/delete)

---

### 9. `payment-service` (port 8007)
**Role:** Payment processing and tracking.
**How:** In-memory store with UUID-based payment IDs. Simulates a payment gateway — marks all payments as `completed`.
**Endpoints:** `/payments` (POST), `/payments/{id}`, `/payments/user/{user_id}`

---

### 10. `frontend` (port 80)
**Role:** React SPA served by Nginx with internal API proxying.
**How:** 2-stage Docker build (Node → Nginx). Nginx proxies `/api/` to `mcp-api-gateway` via Kubernetes DNS. SPA fallback to `index.html`. Gzip + 1-year asset caching.

---

### Infrastructure Components

| Component | Purpose |
|-----------|---------|
| **redis** | Session caching (AOF persistence, port 6379) |
| **PostgreSQL (RDS)** | Persistent user/auth data |

---

## How Services Are Connected

```
Browser → Nginx Ingress → Frontend (/) or mcp-api-gateway (/api)

mcp-api-gateway routes by first path segment:
  /api/auth/*           → auth-service:8001
  /api/model/*          → model-service:8002
  /api/ai-assistant/*   → ai-assistant:8003
  /api/recommendation/* → recommendation-engine:8004
  /api/product/*        → product-service:8005
  /api/user/*           → user-service:8006
  /api/payment/*        → payment-service:8007
  /api/control-plane/*  → mcp-control-plane:8008

ai-assistant (tool-calling, makes internal HTTP calls):
  → mcp-control-plane:8008/status
  → product-service:8005/products
  → user-service:8006/users
  → payment-service:8007/payments/{id}

auth-service + user-service → AWS RDS PostgreSQL (same DB)
mcp-control-plane → Kubernetes API (in-cluster) + EKS API (via IRSA)

All services share:
  ConfigMap: mcp-config  (URLs, DB host, region, cluster name)
  Secret:    mcp-secrets (JWT_SECRET, OPENAI_API_KEY, DB password)
```

---

## What is IRSA?

**IRSA = IAM Roles for Service Accounts**

It solves a critical problem: *"How do pods running inside Kubernetes call AWS APIs without hardcoding credentials?"*

### Without IRSA (bad):
```bash
# Hardcode keys in env vars — security risk, rotation nightmare
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=abc...
```

### With IRSA (correct):
```
Pod → Kubernetes ServiceAccount
    → Projected JWT token (auto-mounted by EKS)
    → AWS STS AssumeRoleWithWebIdentity
    → Temporary credentials (auto-rotated)
    → IAM Role with least-privilege policy
```

### The Chain of Trust

```
EKS Cluster
   │ has OIDC provider (e.g., oidc.eks.ap-northeast-1.amazonaws.com/id/54010A...)
   │
ServiceAccount (mcp-control-plane)
   │ annotated with eks.amazonaws.com/role-arn: arn:aws:iam::508262720940:role/mcp-control-plane-role
   │
IAM Role (mcp-control-plane-role)
   │ Trust Policy: only allow this specific namespace/serviceaccount to assume it
   │
IAM Policy (mcp-control-plane-eks-policy)
   └── eks:DescribeCluster, eks:ListClusters, eks:ListNodegroups, eks:DescribeNodegroup
```

---

## How IRSA Is Wired in This GitOps Project

### Step 1 — ServiceAccount with annotation (`gitops/base/mcp-control-plane/rbac.yaml`)

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: mcp-control-plane
  namespace: mcp-platform
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::508262720940:role/mcp-control-plane-role
```

### Step 2 — Deployment references the ServiceAccount (`gitops/base/mcp-control-plane/deployment.yaml`)

```yaml
spec:
  template:
    spec:
      serviceAccountName: mcp-control-plane   # ← this links to the annotated SA
```

### Step 3 — RBAC for Kubernetes API access

```yaml
# ClusterRole — what K8s resources the SA can read
kind: ClusterRole
rules:
  - apiGroups: [""]
    resources: ["pods", "nodes", "namespaces"]
    verbs: ["get", "list"]
  - apiGroups: ["metrics.k8s.io"]
    resources: ["pods", "nodes"]
    verbs: ["get", "list"]
---
# ClusterRoleBinding — binds the role to the ServiceAccount
kind: ClusterRoleBinding
subjects:
  - kind: ServiceAccount
    name: mcp-control-plane
    namespace: mcp-platform
```

### Step 4 — IAM Role Trust Policy (created in AWS once)

```json
{
  "Principal": {
    "Federated": "arn:aws:iam::508262720940:oidc-provider/oidc.eks..."
  },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "...:sub": "system:serviceaccount:mcp-platform:mcp-control-plane"
    }
  }
}
```

### How boto3 picks it up automatically

EKS injects two environment variables into the pod:
```bash
AWS_ROLE_ARN=arn:aws:iam::508262720940:role/mcp-control-plane-role
AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
```
`boto3` reads these automatically — **no code changes needed**.

---

## Project Directory Structure

```
mcp-project/
├── gitops/                          # ArgoCD manages this
│   ├── argocd-apps.yaml             # 7-wave ArgoCD Application definitions
│   ├── kustomization.yaml           # Root kustomization
│   ├── base/                        # Environment-agnostic K8s manifests
│   │   ├── platform-config/         # Shared ConfigMap (Wave 0)
│   │   ├── redis/                   # Redis StatefulSet (Wave 1)
│   │   ├── auth-service/            # Wave 2
│   │   ├── mcp-control-plane/       # Wave 2 (includes rbac.yaml)
│   │   ├── model-service/           # Wave 3
│   │   ├── ai-assistant/            # Wave 3
│   │   ├── recommendation-engine/   # Wave 3
│   │   ├── product-service/         # Wave 4
│   │   ├── user-service/            # Wave 4
│   │   ├── payment-service/         # Wave 4
│   │   ├── mcp-api-gateway/         # Wave 5
│   │   └── frontend/                # Wave 6 (+ ingress + cluster-issuer)
│   └── overlays/
│       ├── eks/                     # Production (ECR images, HPA, 2 replicas)
│       └── microk8s/                # Dev (local registry, NodePort, scaled down)
│
├── services/                        # Application source code
│   ├── {service}/
│   │   ├── main.py
│   │   ├── requirements.txt
│   │   └── Dockerfile
│   └── frontend/
│       ├── src/
│       ├── nginx.conf
│       └── Dockerfile
│
├── helm/mcp-platform/               # Alternative Helm chart
├── monitoring/                      # Prometheus rules + Grafana dashboards
├── infrastructure/terraform/        # IaC placeholder
└── k8s/                            # Legacy manifests (not used by ArgoCD)
```

---

## How This Project Strengthens Your Resume

### Resume Bullet Points You Can Write

```
• Designed and deployed a 10-service AI microservices platform on AWS EKS using
  ArgoCD GitOps with 7-wave ordered sync, achieving zero-downtime deployments.

• Implemented IRSA (IAM Roles for Service Accounts) for mcp-control-plane service,
  eliminating static AWS credentials via OIDC-federated STS token exchange.

• Integrated OpenAI GPT-4o tool-calling agent capable of querying live platform
  services (cluster status, payments, products) to answer operator questions.

• Built Kustomize overlay strategy with separate EKS (production) and microk8s
  (dev) environments, including HPA on API gateway (2–10 replicas at 70% CPU).

• Configured cert-manager with Let's Encrypt ACME HTTP-01 solver for automated
  TLS certificate issuance and renewal on nginx ingress.

• Set up Prometheus ServiceMonitor with custom alerting rules (ServiceDown,
  HighCPU >80%, HighMemory >85%) for platform-wide observability.
```

### Skills This Project Demonstrates

| Category | Technologies |
|----------|-------------|
| Container Orchestration | AWS EKS, Kubernetes (Deployments, Services, HPA, RBAC) |
| GitOps | ArgoCD, Kustomize, sync waves, self-healing, automated pruning |
| Cloud Security | IRSA, IAM trust policies, OIDC federation, JWT auth |
| AI/LLM Integration | OpenAI GPT-4o, tool-calling agents, inference APIs |
| Networking | Nginx Ingress, TLS termination, service mesh, internal DNS |
| Automation | cert-manager, HPA, ArgoCD auto-sync |
| Languages | Python (FastAPI), TypeScript (React), YAML |
| Infrastructure | AWS RDS, ECR, EKS, Kustomize, Helm |

---

# Complete Installation Guide

---

## Prerequisites

```bash
# Tools required on your workstation
aws --version          # AWS CLI v2
kubectl version        # kubectl 1.28+
helm version           # Helm 3
eksctl version         # eksctl (optional, for cluster creation)
argocd version         # ArgoCD CLI
```

---

## Phase 1 — EKS Cluster Setup

### 1.1 Create EKS Cluster (if not existing)

```bash
eksctl create cluster \
  --name quantamvector \
  --region ap-northeast-1 \
  --nodegroup-name workers \
  --node-type t3.medium \
  --nodes 3 \
  --nodes-min 2 \
  --nodes-max 5 \
  --with-oidc \
  --managed
```

> `--with-oidc` is **required** for IRSA to work.

### 1.2 Update kubeconfig

```bash
aws eks update-kubeconfig \
  --region ap-northeast-1 \
  --name quantamvector
```

### 1.3 Verify OIDC Provider

```bash
# Get OIDC issuer URL
aws eks describe-cluster \
  --name quantamvector \
  --region ap-northeast-1 \
  --query "cluster.identity.oidc.issuer" \
  --output text

# Should return something like:
# https://oidc.eks.ap-northeast-1.amazonaws.com/id/54010A8680852B657EC215C7264F77E3

# Verify OIDC provider exists in IAM
aws iam list-open-id-connect-providers
```

If missing, create it:
```bash
eksctl utils associate-iam-oidc-provider \
  --region ap-northeast-1 \
  --cluster quantamvector \
  --approve
```

---

## Phase 2 — IRSA Setup for mcp-control-plane

### 2.1 Create IAM Policy

```bash
cat > mcp-control-plane-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "eks:DescribeCluster",
        "eks:ListClusters",
        "eks:ListNodegroups",
        "eks:DescribeNodegroup"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name mcp-control-plane-eks-policy \
  --policy-document file://mcp-control-plane-policy.json
```

### 2.2 Get OIDC Provider ID

```bash
OIDC_ID=$(aws eks describe-cluster \
  --name quantamvector \
  --region ap-northeast-1 \
  --query "cluster.identity.oidc.issuer" \
  --output text | cut -d '/' -f5)

echo "OIDC ID: $OIDC_ID"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account ID: $ACCOUNT_ID"
```

### 2.3 Create IAM Role Trust Policy

```bash
cat > trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.ap-northeast-1.amazonaws.com/id/${OIDC_ID}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.ap-northeast-1.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:mcp-platform:mcp-control-plane",
          "oidc.eks.ap-northeast-1.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF
```

### 2.4 Create IAM Role and Attach Policy

```bash
aws iam create-role \
  --role-name mcp-control-plane-role \
  --assume-role-policy-document file://trust-policy.json

aws iam attach-role-policy \
  --role-name mcp-control-plane-role \
  --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/mcp-control-plane-eks-policy
```

### 2.5 Update ServiceAccount Annotation in GitOps

Edit `gitops/base/mcp-control-plane/rbac.yaml`:
```yaml
annotations:
  eks.amazonaws.com/role-arn: arn:aws:iam::<YOUR_ACCOUNT_ID>:role/mcp-control-plane-role
```

---

## Phase 3 — Install ArgoCD on EKS

### 3.1 Install ArgoCD

```bash
kubectl create namespace argocd

kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for pods to be ready
kubectl wait --for=condition=Ready pods \
  --all -n argocd --timeout=300s
```

### 3.2 Get Initial Admin Password

```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

### 3.3 Access ArgoCD UI

**Option A — Port Forward (quick test):**
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080
# Username: admin, Password: from step 3.2
```

**Option B — LoadBalancer (production):**
```bash
kubectl patch svc argocd-server -n argocd \
  -p '{"spec": {"type": "LoadBalancer"}}'

kubectl get svc argocd-server -n argocd
# Note the EXTERNAL-IP
```

### 3.4 Login via ArgoCD CLI

```bash
argocd login localhost:8080 \
  --username admin \
  --password <password-from-3.2> \
  --insecure

# Change password
argocd account update-password
```

### 3.5 Add GitHub Repository to ArgoCD

```bash
argocd repo add https://github.com/QuntamVector/MCP-Project-GitOps.git \
  --username <github-username> \
  --password <github-PAT>
```

---

## Phase 4 — Install Nginx Ingress Controller

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.replicaCount=2 \
  --set controller.service.type=LoadBalancer \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"=nlb

# Get the external LoadBalancer DNS
kubectl get svc ingress-nginx-controller -n ingress-nginx
# Note: EXTERNAL-IP — point your domain DNS to this
```

### Update DNS

In your DNS provider (Route 53 or registrar), add:
```
A record (or CNAME):
  quntamvector.in  →  <EXTERNAL-IP from above>
  *.quntamvector.in → <EXTERNAL-IP>
```

---

## Phase 5 — Install cert-manager

### 5.1 Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true \
  --version v1.14.0

# Verify
kubectl get pods -n cert-manager
```

### 5.2 Apply ClusterIssuer (already in GitOps)

The ClusterIssuer is at `gitops/base/frontend/cluster-issuer.yaml`. ArgoCD will apply it automatically. If applying manually:

```bash
kubectl apply -f gitops/base/frontend/cluster-issuer.yaml

# Verify
kubectl get clusterissuer letsencrypt-prod
kubectl describe clusterissuer letsencrypt-prod
```

---

## Phase 6 — Create Namespace and Secrets

### 6.1 Create Namespace

```bash
kubectl create namespace mcp-platform
```

### 6.2 Create Kubernetes Secret (manual step — never in Git)

```bash
kubectl create secret generic mcp-secrets \
  -n mcp-platform \
  --from-literal=POSTGRES_USER=postgres \
  --from-literal=POSTGRES_PASSWORD='<your-rds-password>' \
  --from-literal=JWT_SECRET='<your-jwt-secret-min-32-chars>' \
  --from-literal=OPENAI_API_KEY='sk-<your-openai-key>' \
  --from-literal=REDIS_PASSWORD=''
```

---

## Phase 7 — Deploy via ArgoCD (GitOps)

### 7.1 Create AppProject and Applications

```bash
# Apply the ArgoCD project + all application definitions
kubectl apply -f gitops/argocd-apps.yaml -n argocd
```

### 7.2 Verify ArgoCD Sync Waves

Watch the deployment happen in order:
```bash
# Watch applications status
watch argocd app list

# Or in the UI — you'll see applications sync wave by wave:
# Wave 0: platform-config (ConfigMap)
# Wave 1: redis
# Wave 2: auth-service, mcp-control-plane
# Wave 3: model-service, ai-assistant, recommendation-engine
# Wave 4: product-service, user-service, payment-service
# Wave 5: mcp-api-gateway
# Wave 6: frontend
```

### 7.3 Monitor Pods Coming Up

```bash
kubectl get pods -n mcp-platform -w

# Check specific service logs
kubectl logs -f deployment/auth-service -n mcp-platform
kubectl logs -f deployment/mcp-control-plane -n mcp-platform
```

---

## Phase 8 — Install Metrics Server (Required for HPA)

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Verify
kubectl get deployment metrics-server -n kube-system
kubectl top nodes
kubectl top pods -n mcp-platform
```

---

## Phase 9 — Verify Everything

### 9.1 Check All Pods Running

```bash
kubectl get all -n mcp-platform
```

### 9.2 Check Ingress and TLS Certificate

```bash
# Check ingress
kubectl get ingress -n mcp-platform

# Check certificate was issued
kubectl get certificate -n mcp-platform
kubectl describe certificate frontend-tls -n mcp-platform

# Should show: "Certificate is up to date and has not expired"
```

### 9.3 Check IRSA is Working

```bash
# Exec into control-plane pod
kubectl exec -it deployment/mcp-control-plane -n mcp-platform -- bash

# Inside pod - verify AWS credentials via IRSA
env | grep AWS
# Should show AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE

# Test AWS call
python3 -c "import boto3; print(boto3.client('eks', region_name='ap-northeast-1').list_clusters())"
```

### 9.4 Test API Endpoints

```bash
# Health checks through the gateway
curl https://quntamvector.in/api/auth/health
curl https://quntamvector.in/api/model/health
curl https://quntamvector.in/api/control-plane/health

# Login
curl -X POST https://quntamvector.in/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}'

# Get cluster status (tests IRSA)
curl https://quntamvector.in/api/control-plane/status?namespace=mcp-platform
```

---

## Phase 10 — Install Monitoring (Optional)

```bash
# Install Prometheus stack
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace

# Apply ServiceMonitor
kubectl apply -f monitoring/prometheus/service-monitor.yaml
kubectl apply -f monitoring/prometheus/prometheus-rules.yaml
```

---

## Full Deployment Checklist

```
AWS Prerequisites
  [ ] EKS cluster created with --with-oidc flag
  [ ] OIDC provider associated
  [ ] IAM policy mcp-control-plane-eks-policy created
  [ ] IAM role mcp-control-plane-role created with trust policy
  [ ] RDS PostgreSQL accessible from EKS nodes

Kubernetes Infrastructure
  [ ] kubectl configured for cluster
  [ ] ingress-nginx installed (LoadBalancer)
  [ ] cert-manager installed (v1.14+)
  [ ] metrics-server installed
  [ ] ArgoCD installed in argocd namespace

Secrets & Config
  [ ] mcp-platform namespace created
  [ ] mcp-secrets Secret created with all 5 keys
  [ ] DNS A record pointing to ingress LoadBalancer IP

GitOps
  [ ] GitHub repo added to ArgoCD
  [ ] argocd-apps.yaml applied
  [ ] All 7 waves synced successfully
  [ ] ClusterIssuer letsencrypt-prod Ready
  [ ] TLS certificate issued for quntamvector.in

Verification
  [ ] All pods Running in mcp-platform namespace
  [ ] https://quntamvector.in loads frontend
  [ ] /api/auth/health returns 200
  [ ] /api/control-plane/status returns cluster data (IRSA working)
  [ ] HPA objects exist: kubectl get hpa -n mcp-platform
```
