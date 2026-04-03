#!/bin/bash
# ─────────────────────────────────────────────────────────────
# deploy-all.sh — Deploy all MCP Platform apps to EKS in one shot
#
# Usage:
#   ./deploy-all.sh <argocd-admin-password>
#
# Prerequisites:
#   - kubectl configured against your EKS cluster
#   - ArgoCD installed and accessible at localhost:8080 (port-forward)
#   - argocd CLI installed
# ─────────────────────────────────────────────────────────────
set -e

ARGOCD_SERVER="localhost:8080"
ARGOCD_USER="admin"
ARGOCD_PASS="${1:?Usage: $0 <argocd-admin-password>}"

APPS=(
  redis
  postgresql
  auth-service
  mcp-control-plane
  model-service
  ai-assistant
  recommendation-engine
  product-service
  user-service
  payment-service
  mcp-api-gateway
  frontend
)

# ── 1. Login ──────────────────────────────────────────────────
echo "==> Logging into ArgoCD at $ARGOCD_SERVER..."
argocd login "$ARGOCD_SERVER" \
  --username "$ARGOCD_USER" \
  --password "$ARGOCD_PASS" \
  --insecure

# ── 2. Apply App of Apps ──────────────────────────────────────
echo "==> Applying argocd-apps.yaml..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
kubectl apply -f "$SCRIPT_DIR/argocd-apps.yaml"

echo "==> Waiting 10s for Applications to register..."
sleep 10

# ── 3. Sync all apps (ArgoCD respects wave order) ─────────────
echo "==> Syncing all applications..."
argocd app sync "${APPS[@]}"

# ── 4. Wait for each app to become Healthy ────────────────────
echo "==> Waiting for all apps to become Healthy (timeout: 5m each)..."
for app in "${APPS[@]}"; do
  echo "  --> Waiting for $app..."
  argocd app wait "$app" --health --timeout 300
  echo "      $app is Healthy"
done

# ── 5. Final status ───────────────────────────────────────────
echo ""
echo "============================================"
echo " All MCP Platform apps deployed successfully"
echo "============================================"
argocd app list

echo ""
echo "==> Pods in mcp-platform namespace:"
kubectl get pods -n mcp-platform
