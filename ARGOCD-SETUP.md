# ArgoCD Setup on AWS EKS

This guide covers installing ArgoCD on your EKS cluster, retrieving the initial admin secret, and deploying the MCP Platform apps.

---

## Prerequisites

- `kubectl` configured against your EKS cluster
- `aws` CLI authenticated (`aws sts get-caller-identity` should return your account)
- `helm` v3 installed (optional — we use plain manifests below)

### Verify kubectl is pointing at the right cluster

```bash
aws eks update-kubeconfig \
  --region ap-northeast-1 \
  --name mcp-platform-dev

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

> **Note:** The initial password is the name of the `argocd-server` pod. The secret is only present on first install. After you change the password it can be deleted.

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

The `EXTERNAL-IP` column will show the AWS ALB/NLB hostname.

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

## 4. Install the ArgoCD CLI (optional but useful)

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

After changing, delete the initial secret:

```bash
kubectl delete secret argocd-initial-admin-secret -n argocd
```

---

## 5. Add GitHub Repository to ArgoCD

ArgoCD needs read access to the GitOps repo.

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

## 6. Deploy MCP Platform Applications

Apply the App-of-Apps manifest which creates all 13 ArgoCD Applications:

```bash
kubectl apply -f argocd-apps.yaml
```

### Verify applications are created

```bash
kubectl get applications -n argocd

# Or with argocd CLI
argocd app list
```

### Sync all apps

```bash
argocd app sync mcp-platform-apps

# Or sync individually
argocd app sync mcp-api-gateway
argocd app sync auth-service
argocd app sync frontend
# ... etc
```

### Watch sync status

```bash
kubectl get applications -n argocd -w
```

---

## 7. Useful Commands

| Task | Command |
|------|---------|
| Get admin password | `kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" \| base64 --decode` |
| Port-forward UI | `kubectl port-forward svc/argocd-server -n argocd 8080:443` |
| List all apps | `argocd app list` |
| Sync all apps | `argocd app sync --selector app.kubernetes.io/part-of=mcp-platform` |
| App health status | `argocd app get <app-name>` |
| Force hard refresh | `argocd app get <app-name> --hard-refresh` |
| Delete app | `argocd app delete <app-name>` |
| Get ArgoCD version | `argocd version` |

---

## 8. Troubleshooting

### Pod stuck in Pending
```bash
kubectl describe pod <pod-name> -n argocd
kubectl get events -n argocd --sort-by='.lastTimestamp'
```

### App OutOfSync but no changes
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
# Get the bcrypt hash of your new password
htpasswd -nbBC 10 "" newpassword | tr -d ':\n' | sed 's/$2y/$2a/'

# Patch the argocd-secret
kubectl patch secret argocd-secret \
  -n argocd \
  -p '{"stringData": {"admin.password": "<bcrypt-hash>", "admin.passwordMtime": "'$(date +%FT%T%Z)'"}}'

kubectl rollout restart deployment argocd-server -n argocd
```

---

## 9. Deploy All MCP Platform Apps in One Shot

This is the fastest way to get every service running on EKS from scratch.

### Step 1 — Apply the App of Apps manifest

One single `kubectl apply` registers all 13 ArgoCD Applications at once:

```bash
kubectl apply -f gitops/argocd-apps.yaml
```

This creates the `mcp-platform` AppProject plus one ArgoCD Application per service:

| Wave | Services deployed |
|------|------------------|
| Wave 1 | redis, postgresql |
| Wave 2 | auth-service, mcp-control-plane |
| Wave 3 | model-service, ai-assistant, recommendation-engine |
| Wave 4 | product-service, user-service, payment-service |
| Wave 5 | mcp-api-gateway |
| Wave 6 | frontend |

ArgoCD automatically respects the wave order — each wave waits until the previous wave is Healthy before proceeding.

### Step 2 — Trigger a full sync

```bash
argocd app sync --label app.kubernetes.io/part-of=mcp-platform
```

If that label isn't set, sync each app in wave order explicitly:

```bash
# Wave 1
argocd app sync redis postgresql

# Wave 2 (waits for wave 1 to be Healthy)
argocd app sync auth-service mcp-control-plane

# Wave 3
argocd app sync model-service ai-assistant recommendation-engine

# Wave 4
argocd app sync product-service user-service payment-service

# Wave 5
argocd app sync mcp-api-gateway

# Wave 6
argocd app sync frontend
```

Or sync everything at once and let the wave annotations control the order:

```bash
argocd app sync \
  redis postgresql \
  auth-service mcp-control-plane \
  model-service ai-assistant recommendation-engine \
  product-service user-service payment-service \
  mcp-api-gateway \
  frontend
```

### Step 3 — Watch the rollout live

```bash
# Watch all applications status
watch -n 3 "argocd app list"

# Or with kubectl
watch -n 3 "kubectl get applications -n argocd"

# Watch pods coming up in mcp-platform namespace
kubectl get pods -n mcp-platform -w
```

### Step 4 — Verify everything is Healthy + Synced

```bash
argocd app list
```

Expected output — all apps should show `Synced` and `Healthy`:

```
NAME                    CLUSTER     NAMESPACE     PROJECT       STATUS  HEALTH
redis                   in-cluster  mcp-platform  mcp-platform  Synced  Healthy
postgresql              in-cluster  mcp-platform  mcp-platform  Synced  Healthy
auth-service            in-cluster  mcp-platform  mcp-platform  Synced  Healthy
mcp-control-plane       in-cluster  mcp-platform  mcp-platform  Synced  Healthy
model-service           in-cluster  mcp-platform  mcp-platform  Synced  Healthy
ai-assistant            in-cluster  mcp-platform  mcp-platform  Synced  Healthy
recommendation-engine   in-cluster  mcp-platform  mcp-platform  Synced  Healthy
product-service         in-cluster  mcp-platform  mcp-platform  Synced  Healthy
user-service            in-cluster  mcp-platform  mcp-platform  Synced  Healthy
payment-service         in-cluster  mcp-platform  mcp-platform  Synced  Healthy
mcp-api-gateway         in-cluster  mcp-platform  mcp-platform  Synced  Healthy
frontend                in-cluster  mcp-platform  mcp-platform  Synced  Healthy
```

### Quick full-deploy script

Save this as `gitops/deploy-all.sh` and run it once after ArgoCD is installed:

```bash
#!/bin/bash
set -e

ARGOCD_SERVER="localhost:8080"
ARGOCD_USER="admin"
ARGOCD_PASS="$1"   # pass the admin password as first argument

echo "==> Logging into ArgoCD..."
argocd login $ARGOCD_SERVER \
  --username $ARGOCD_USER \
  --password $ARGOCD_PASS \
  --insecure

echo "==> Applying App of Apps manifest..."
kubectl apply -f argocd-apps.yaml

echo "==> Waiting for Applications to be created..."
sleep 5

echo "==> Syncing all applications (wave order)..."
argocd app sync \
  redis postgresql \
  auth-service mcp-control-plane \
  model-service ai-assistant recommendation-engine \
  product-service user-service payment-service \
  mcp-api-gateway \
  frontend

echo "==> Waiting for all apps to become Healthy..."
for app in redis postgresql auth-service mcp-control-plane \
           model-service ai-assistant recommendation-engine \
           product-service user-service payment-service \
           mcp-api-gateway frontend; do
  echo "  Waiting for $app..."
  argocd app wait $app --health --timeout 300
done

echo ""
echo "All MCP Platform apps are Synced and Healthy!"
argocd app list
```

Usage:
```bash
chmod +x gitops/deploy-all.sh
./gitops/deploy-all.sh <your-argocd-admin-password>
```

---

## Architecture Reference

```
EKS Cluster (ap-northeast-1)
└── namespace: argocd
    ├── argocd-server          ← UI + API
    ├── argocd-repo-server     ← Pulls from GitHub
    ├── argocd-application-controller  ← Reconciles K8s state
    ├── argocd-applicationset-controller
    ├── argocd-dex-server      ← SSO (optional)
    └── argocd-redis           ← Cache

GitHub: QuntamVector/MCP-Project-GitOps
    └── argocd-apps.yaml  ←  ArgoCD watches this
        └── gitops/overlays/eks/  ←  Applied to mcp-platform namespace
```
