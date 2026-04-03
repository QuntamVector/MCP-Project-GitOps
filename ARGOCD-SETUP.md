# ArgoCD Setup on AWS EKS

This guide covers installing ArgoCD on your EKS cluster, retrieving the initial admin secret, deploying the MCP Platform apps, and setting up IRSA for real EKS metrics.

---

## Cluster Details

| Field | Value |
|-------|-------|
| Cluster Name | `quantamvector` |
| Region | `ap-northeast-1` |
| Account ID | `508262720940` |
| OIDC Provider | `oidc.eks.ap-northeast-1.amazonaws.com/id/54010A8680852B657EC215C7264F77E3` |
| Namespace | `mcp-platform` |
| GitOps Repo | `https://github.com/QuntamVector/MCP-Project-GitOps.git` |
| Services Repo | `https://github.com/QuntamVector/MCP-Project-ALL-services.git` |

---

## Prerequisites

- `kubectl` configured against your EKS cluster
- `aws` CLI authenticated (`aws sts get-caller-identity` should return your account)
- `helm` v3 installed (optional — we use plain manifests below)

### Verify kubectl is pointing at the right cluster

```bash
aws eks update-kubeconfig \
  --region ap-northeast-1 \
  --name quantamvector

kubectl config current-context
kubectl get nodes
```

---

## 1. Install ArgoCD

### Create the namespace

```bash
kubectl create namespace argocd
```

### Apply the official ArgoCD install manifest

```bash
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

### Wait for all pods to be Running

```bash
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=argocd-server \
  -n argocd \
  --timeout=120s

# Verify all pods
kubectl get pods -n argocd
```

Expected output:
```
NAME                                                READY   STATUS    RESTARTS
argocd-application-controller-0                     1/1     Running   0
argocd-applicationset-controller-xxx                1/1     Running   0
argocd-dex-server-xxx                               1/1     Running   0
argocd-notifications-controller-xxx                 1/1     Running   0
argocd-redis-xxx                                    1/1     Running   0
argocd-repo-server-xxx                              1/1     Running   0
argocd-server-xxx                                   1/1     Running   0
```

---

## 2. Get the Initial Admin Password

ArgoCD auto-generates an initial admin password and stores it in a Kubernetes secret.

```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath="{.data.password}" | base64 --decode
echo   # print a newline after the password
```

> **Username:** `admin`
> **Password:** output of the command above

> **Note:** After you change the password, delete the initial secret:
> ```bash
> kubectl delete secret argocd-initial-admin-secret -n argocd
> ```

---

## 3. Access the ArgoCD UI

### Option A — Port Forward (quick access, no DNS needed)

```bash
kubectl port-forward svc/argocd-server \
  -n argocd \
  8080:443
```

Open your browser: `https://localhost:8080`
Login with `admin` / `<password from step 2>`

### Option B — Expose via LoadBalancer (EKS permanent access)

```bash
kubectl patch svc argocd-server \
  -n argocd \
  -p '{"spec": {"type": "LoadBalancer"}}'

# Get the external hostname (takes ~60s to provision)
kubectl get svc argocd-server -n argocd
```

### Option C — Expose via ALB Ingress (recommended for production)

```bash
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: argocd
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/backend-protocol: HTTPS
spec:
  rules:
    - host: argocd.your-domain.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
EOF
```

---

## 4. Install the ArgoCD CLI

```bash
# macOS
brew install argocd

# Linux
curl -sSL -o /usr/local/bin/argocd \
  https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x /usr/local/bin/argocd
```

### Login via CLI

```bash
argocd login localhost:8080 \
  --username admin \
  --password <password from step 2> \
  --insecure
```

### Change the admin password (recommended)

```bash
argocd account update-password \
  --current-password <old-password> \
  --new-password <your-new-password>
```

---

## 5. Add GitHub Repository to ArgoCD

### Option A — HTTPS with token (GitHub PAT)

```bash
argocd repo add https://github.com/QuntamVector/MCP-Project-GitOps.git \
  --username QuntamVector \
  --password <your-github-pat>
```

### Option B — via Kubernetes secret (declarative)

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: mcp-gitops-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/QuntamVector/MCP-Project-GitOps.git
  username: QuntamVector
  password: <your-github-pat>
EOF
```

---

## 6. Apply Secrets and ConfigMap (required before pods start)

These must be applied manually — secrets are never stored in Git.

```bash
# ConfigMap (service URLs, DB host, cluster info)
kubectl apply -n mcp-platform -f base/platform-config/configmap.yaml

# Secrets (apply with real values)
kubectl apply -n mcp-platform -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: mcp-secrets
  namespace: mcp-platform
type: Opaque
stringData:
  POSTGRES_USER: "postgres"
  POSTGRES_PASSWORD: "<your-rds-password>"
  JWT_SECRET: "<your-jwt-secret>"
  OPENAI_API_KEY: "<your-openai-key>"
  REDIS_PASSWORD: ""
EOF
```

---

## 7. IRSA Setup — Real EKS Metrics for Control Plane

The `mcp-control-plane` service queries the EKS API using boto3. It needs an IAM role via IRSA.

### Step 1 — Create IAM policy

```bash
aws iam create-policy \
  --policy-name mcp-control-plane-eks-policy \
  --policy-document '{
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
  }'
```

### Step 2 — Create IAM role with OIDC trust

```bash
cat > trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::508262720940:oidc-provider/oidc.eks.ap-northeast-1.amazonaws.com/id/54010A8680852B657EC215C7264F77E3"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.ap-northeast-1.amazonaws.com/id/54010A8680852B657EC215C7264F77E3:sub": "system:serviceaccount:mcp-platform:mcp-control-plane",
          "oidc.eks.ap-northeast-1.amazonaws.com/id/54010A8680852B657EC215C7264F77E3:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name mcp-control-plane-role \
  --assume-role-policy-document file://trust-policy.json
```

### Step 3 — Attach policy to role

```bash
aws iam attach-role-policy \
  --role-name mcp-control-plane-role \
  --policy-arn arn:aws:iam::508262720940:policy/mcp-control-plane-eks-policy
```

### Step 4 — Apply RBAC + ServiceAccount

```bash
kubectl apply -f base/mcp-control-plane/rbac.yaml
```

### Step 5 — Verify IRSA is working

```bash
kubectl rollout restart deployment mcp-control-plane -n mcp-platform

# Should show AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE
kubectl exec -n mcp-platform deployment/mcp-control-plane -- env | grep AWS
```

---

## 8. Deploy All MCP Platform Apps in One Shot

### Step 1 — Apply the App of Apps manifest

```bash
kubectl apply -f argocd-apps.yaml
```

This creates the `mcp-platform` AppProject plus one ArgoCD Application per service:

| Wave | Services |
|------|----------|
| Wave 0 | platform-config (ConfigMap) |
| Wave 1 | redis |
| Wave 2 | auth-service, mcp-control-plane |
| Wave 3 | model-service, ai-assistant, recommendation-engine |
| Wave 4 | product-service, user-service, payment-service |
| Wave 5 | mcp-api-gateway |
| Wave 6 | frontend |

### Step 2 — Sync all apps in wave order

```bash
argocd app sync platform-config
argocd app sync redis
argocd app sync auth-service mcp-control-plane
argocd app sync model-service ai-assistant recommendation-engine
argocd app sync product-service user-service payment-service
argocd app sync mcp-api-gateway
argocd app sync frontend
```

### Step 3 — Watch the rollout

```bash
watch -n 3 "argocd app list"
kubectl get pods -n mcp-platform -w
```

### Step 4 — Verify all Healthy + Synced

```bash
argocd app list
```

Expected:
```
NAME                    STATUS  HEALTH
platform-config         Synced  Healthy
redis                   Synced  Healthy
auth-service            Synced  Healthy
mcp-control-plane       Synced  Healthy
model-service           Synced  Healthy
ai-assistant            Synced  Healthy
recommendation-engine   Synced  Healthy
product-service         Synced  Healthy
user-service            Synced  Healthy
payment-service         Synced  Healthy
mcp-api-gateway         Synced  Healthy
frontend                Synced  Healthy
```

### Quick deploy script

```bash
chmod +x deploy-all.sh
./deploy-all.sh <your-argocd-admin-password>
```

---

## 9. Useful Commands

| Task | Command |
|------|---------|
| Get admin password | `kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" \| base64 --decode` |
| Port-forward UI | `kubectl port-forward svc/argocd-server -n argocd 8080:443` |
| List all apps | `argocd app list` |
| Sync one app | `argocd app sync <app-name>` |
| App health | `argocd app get <app-name>` |
| Force refresh | `argocd app get <app-name> --hard-refresh` |
| Delete app | `argocd app delete <app-name>` |
| Watch pods | `kubectl get pods -n mcp-platform -w` |
| Restart deployment | `kubectl rollout restart deployment <name> -n mcp-platform` |
| Check logs | `kubectl logs -f deployment/<name> -n mcp-platform` |
| Get all services | `kubectl get svc -n mcp-platform` |

---

## 10. Troubleshooting

### Pod stuck in Pending
```bash
kubectl describe pod <pod-name> -n mcp-platform
kubectl get events -n mcp-platform --sort-by='.lastTimestamp'
```

### CreateContainerConfigError
```bash
# Check if ConfigMap and Secret exist
kubectl get configmap mcp-config -n mcp-platform
kubectl get secret mcp-secrets -n mcp-platform
```

### App OutOfSync
```bash
argocd app diff <app-name>
argocd app sync <app-name> --force
```

### Repo connection error
```bash
argocd repo list
argocd repo get https://github.com/QuntamVector/MCP-Project-GitOps.git
```

### Reset admin password (if locked out)
```bash
htpasswd -nbBC 10 "" newpassword | tr -d ':\n' | sed 's/$2y/$2a/'

kubectl patch secret argocd-secret \
  -n argocd \
  -p '{"stringData": {"admin.password": "<bcrypt-hash>", "admin.passwordMtime": "'$(date +%FT%T%Z)'"}}'

kubectl rollout restart deployment argocd-server -n argocd
```

---

## Architecture Reference

```
EKS Cluster: quantamvector (ap-northeast-1)
├── namespace: argocd
│   ├── argocd-server                    ← UI + API
│   ├── argocd-repo-server               ← Pulls from GitHub
│   ├── argocd-application-controller    ← Reconciles K8s state
│   └── argocd-redis                     ← Cache
│
└── namespace: mcp-platform
    ├── platform-config  (ConfigMap)
    ├── redis
    ├── auth-service     → RDS PostgreSQL (quantamvectordb.crqai6ems4a2.ap-northeast-1.rds.amazonaws.com)
    ├── mcp-control-plane → K8s API + EKS API (IRSA)
    ├── model-service    → OpenAI GPT-4o
    ├── ai-assistant     → OpenAI GPT-4o-mini
    ├── recommendation-engine → OpenAI GPT-4o-mini
    ├── product-service
    ├── user-service     → RDS PostgreSQL
    ├── payment-service
    ├── mcp-api-gateway  ← Routes all /api/* traffic
    └── frontend         ← React + Nginx (public)

GitHub: QuntamVector/MCP-Project-GitOps
    └── argocd-apps.yaml  ← ArgoCD watches this repo
```
