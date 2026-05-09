#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Foundation Setup: Grafana, Gatekeeper, Metrics Server ==="
echo ""

# ─── 1. Helm Repositories ────────────────────────────────────────────────────
echo "[1/8] Adding Helm repositories..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update
echo ""

# ─── 2. Grafana Stack ────────────────────────────────────────────────────────
echo "[2/8] Installing Grafana stack (kube-prometheus-stack)..."
kubectl apply -f "${SCRIPT_DIR}/grafana/namespace.yaml"

helm upgrade --install grafana-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values "${SCRIPT_DIR}/grafana/values.yaml" \
  --wait \
  --timeout=600s

echo "Grafana stack installed."
echo ""

# ─── 3. Gatekeeper ───────────────────────────────────────────────────────────
echo "[3/8] Installing OPA Gatekeeper..."
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.14/deploy/gatekeeper.yaml

echo "Waiting for Gatekeeper deployments to be ready..."
kubectl rollout status deployment/gatekeeper-controller-manager -n gatekeeper-system --timeout=120s
kubectl rollout status deployment/gatekeeper-audit -n gatekeeper-system --timeout=120s

echo "Gatekeeper installed."
echo ""

# ─── 4. Gatekeeper Constraint Template & Constraint ──────────────────────────
echo "[4/8] Applying Gatekeeper namespace-labels constraint..."
kubectl apply -f "${SCRIPT_DIR}/gatekeeper/namespace-labels/constraint-template.yaml"

echo "Waiting for K8sRequiredLabels CRD to be established..."
until kubectl get crd k8srequiredlabels.constraints.gatekeeper.sh &>/dev/null; do sleep 2; done
kubectl wait --for=condition=Established \
  crd/k8srequiredlabels.constraints.gatekeeper.sh \
  --timeout=60s

kubectl apply -f "${SCRIPT_DIR}/gatekeeper/namespace-labels/constraint.yaml"
echo "Namespace-labels constraint applied."
echo ""

# ─── 5. CVE Vulnerability Scanning ──────────────────────────────────────────
echo "[5/8] Applying CVE vulnerability scanning constraint..."
kubectl apply -f "${SCRIPT_DIR}/gatekeeper/vulnerability/cve-constraint-template.yaml"

echo "Waiting for VulnerabilityScan CRD to be established..."
until kubectl get crd vulnerabilityscan.constraints.gatekeeper.sh &>/dev/null; do sleep 2; done
kubectl wait --for=condition=Established \
  crd/vulnerabilityscan.constraints.gatekeeper.sh \
  --timeout=60s

kubectl apply -f "${SCRIPT_DIR}/gatekeeper/vulnerability/cve-constraint.yaml"
echo "CVE vulnerability scanning constraint applied."
echo ""

# ─── 6. Code Quality Enforcement ─────────────────────────────────────────────
echo "[6/8] Applying code quality (coverage) constraint..."
kubectl apply -f "${SCRIPT_DIR}/gatekeeper/code-quality/quality-constraint-template.yaml"

echo "Waiting for CodeCoverageSimple CRD to be established..."
until kubectl get crd codecoveragesimple.constraints.gatekeeper.sh &>/dev/null; do sleep 2; done
kubectl wait --for=condition=Established \
  crd/codecoveragesimple.constraints.gatekeeper.sh \
  --timeout=60s

kubectl apply -f "${SCRIPT_DIR}/gatekeeper/code-quality/quality-constraint.yaml"
echo "Code quality constraint applied."
echo ""

# ─── 7. Metrics Server ───────────────────────────────────────────────────────
echo "[7/8] Installing Metrics Server..."
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --values "${SCRIPT_DIR}/metrics-server/values.yaml" \
  --wait \
  --timeout=120s

echo "Metrics Server installed."
echo ""

# ─── 8. Summary ──────────────────────────────────────────────────────────────
echo "[8/8] Deployment complete. Run verify.sh to validate the setup."
echo ""
echo "  Grafana:       kubectl port-forward -n monitoring service/grafana-stack-grafana 3000:80"
echo "                 Then open http://localhost:3000  (admin / admin123)"
echo "  Gatekeeper:    kubectl get pods -n gatekeeper-system"
echo "  Metrics:       kubectl top nodes  (may take ~60s to populate)"
echo ""
echo "  To remove the ns-must-have-gk constraint (required before deploying Falco):"
echo "    kubectl delete -f ${SCRIPT_DIR}/gatekeeper/namespace-labels/constraint.yaml"
echo "    kubectl delete -f ${SCRIPT_DIR}/gatekeeper/namespace-labels/ns-with-label.yaml"
