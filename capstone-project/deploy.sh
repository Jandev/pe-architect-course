#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Foundation Setup: Grafana, Gatekeeper, Metrics Server ==="
echo ""

# ─── 1. Helm Repositories ────────────────────────────────────────────────────
echo "[1/6] Adding Helm repositories..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update
echo ""

# ─── 2. Grafana Stack ────────────────────────────────────────────────────────
echo "[2/6] Installing Grafana stack (kube-prometheus-stack)..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install grafana-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values "${SCRIPT_DIR}/grafana/values.yaml" \
  --wait \
  --timeout=600s

echo "Grafana stack installed."
echo ""

# ─── 3. Gatekeeper ───────────────────────────────────────────────────────────
echo "[3/6] Installing OPA Gatekeeper..."
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.14/deploy/gatekeeper.yaml

echo "Waiting for Gatekeeper deployments to be ready..."
kubectl rollout status deployment/gatekeeper-controller-manager -n gatekeeper-system --timeout=120s
kubectl rollout status deployment/gatekeeper-audit -n gatekeeper-system --timeout=120s

echo "Gatekeeper installed."
echo ""

# ─── 4. Gatekeeper Constraint Template & Constraint ──────────────────────────
echo "[4/6] Applying Gatekeeper constraint template and constraint..."
kubectl apply -f "${SCRIPT_DIR}/gatekeeper/constraint-template.yaml"

# Give the CRD a moment to be established before applying the constraint
echo "Waiting for K8sRequiredLabels CRD to be established..."
kubectl wait --for=condition=Established \
  crd/k8srequiredlabels.constraints.gatekeeper.sh \
  --timeout=60s

kubectl apply -f "${SCRIPT_DIR}/gatekeeper/constraint.yaml"
echo "Constraint template and constraint applied."
echo ""

# ─── 5. Metrics Server ───────────────────────────────────────────────────────
echo "[5/6] Installing Metrics Server..."
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --values "${SCRIPT_DIR}/metrics-server/values.yaml" \
  --wait \
  --timeout=120s

echo "Metrics Server installed."
echo ""

# ─── 6. Summary ──────────────────────────────────────────────────────────────
echo "[6/6] Deployment complete. Run verify.sh to validate the setup."
echo ""
echo "  Grafana:       kubectl port-forward -n monitoring service/grafana-stack-grafana 3000:80"
echo "                 Then open http://localhost:3000  (admin / admin123)"
echo "  Gatekeeper:    kubectl get pods -n gatekeeper-system"
echo "  Metrics:       kubectl top nodes  (may take ~60s to populate)"
echo ""
echo "  To remove the ns-must-have-gk constraint (required before deploying Falco):"
echo "    kubectl delete -f ${SCRIPT_DIR}/gatekeeper/constraint.yaml"
echo "    kubectl delete -f ${SCRIPT_DIR}/gatekeeper/ns-with-label.yaml"
