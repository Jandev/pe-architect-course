#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect OrbStack — its ARM64 kernel BPF verifier limit blocks Falco's eBPF driver
IS_ORBSTACK=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | grep -q '^orbstack$' && echo true || echo false)

echo "=== Foundation Setup: Grafana, Gatekeeper, Falco, Metrics Server ==="
echo ""

# ─── 1. Helm Repositories ────────────────────────────────────────────────────
echo "[1/11] Adding Helm repositories..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo add kubescape https://kubescape.github.io/helm-charts/
helm repo update
echo ""

# ─── 2. Grafana Stack ────────────────────────────────────────────────────────
echo "[2/11] Installing Grafana stack (kube-prometheus-stack)..."
kubectl apply -f "${SCRIPT_DIR}/grafana/namespace.yaml"

helm upgrade --install grafana-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values "${SCRIPT_DIR}/grafana/values.yaml" \
  --wait \
  --timeout=600s

echo "Grafana stack installed."
echo ""

# ─── 3. Gatekeeper ───────────────────────────────────────────────────────────
echo "[3/11] Installing OPA Gatekeeper..."
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.14/deploy/gatekeeper.yaml

echo "Waiting for Gatekeeper deployments to be ready..."
kubectl rollout status deployment/gatekeeper-controller-manager -n gatekeeper-system --timeout=120s
kubectl rollout status deployment/gatekeeper-audit -n gatekeeper-system --timeout=120s

echo "Gatekeeper installed."
echo ""

# ─── 4. Gatekeeper Constraint Template & Constraint ──────────────────────────
echo "[4/11] Applying Gatekeeper namespace-labels constraint..."
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
echo "[5/11] Applying CVE vulnerability scanning constraint..."
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
echo "[6/11] Applying code quality (coverage) constraint..."
kubectl apply -f "${SCRIPT_DIR}/gatekeeper/code-quality/quality-constraint-template.yaml"

echo "Waiting for CodeCoverageSimple CRD to be established..."
until kubectl get crd codecoveragesimple.constraints.gatekeeper.sh &>/dev/null; do sleep 2; done
kubectl wait --for=condition=Established \
  crd/codecoveragesimple.constraints.gatekeeper.sh \
  --timeout=60s

kubectl apply -f "${SCRIPT_DIR}/gatekeeper/code-quality/quality-constraint.yaml"
echo "Code quality constraint applied."
echo ""

# ─── 7. Falco Runtime Security ───────────────────────────────────────────────
echo "[7/11] Installing Falco runtime security..."
if [ "$IS_ORBSTACK" = "true" ]; then
  echo "⚠️  Skipping Falco on OrbStack: the ARM64 kernel BPF verifier limit (1,000,000 insns)"
  echo "   is exceeded by Falco's modern_ebpf driver (1,000,001 insns required)."
  echo "   All drivers (modern_ebpf, ebpf, kmod) fail — no kernel headers at /lib/modules."
  echo "   Falco will be deployed correctly in the Coder / production environment."
else
  kubectl apply -f "${SCRIPT_DIR}/falco/namespace.yaml"

  helm upgrade --install falco falcosecurity/falco \
    --namespace falco-system \
    --values "${SCRIPT_DIR}/falco/values.yaml" \
    --set-file 'customRules.custom_rules\.yaml'="${SCRIPT_DIR}/falco/custom_rules.yaml" \
    --wait \
    --timeout=300s

  echo "Falco installed."
fi
echo ""

# ─── 8. Kubescape Compliance Scanning ────────────────────────────────────────
echo "[8/11] Installing Kubescape compliance scanning..."
kubectl apply -f "${SCRIPT_DIR}/kubescape/namespace.yaml"

helm upgrade --install kubescape kubescape/kubescape-operator \
  --namespace kubescape \
  --values "${SCRIPT_DIR}/kubescape/values.yaml" \
  --set clusterName="$(kubectl config current-context)" \
  --wait \
  --timeout=300s

echo "Kubescape installed."
echo ""

# ─── 9. Gatekeeper SecOps Constraint ─────────────────────────────────────────
echo "[9/11] Applying Gatekeeper secops (root prevention) constraint..."
kubectl apply -f "${SCRIPT_DIR}/gatekeeper/secops/constraint-template.yaml"

echo "Waiting for FalcoRootPrevention CRD to be established..."
until kubectl get crd falcorootprevention.constraints.gatekeeper.sh &>/dev/null; do sleep 2; done
kubectl wait --for=condition=Established \
  crd/falcorootprevention.constraints.gatekeeper.sh \
  --timeout=60s

kubectl apply -f "${SCRIPT_DIR}/gatekeeper/secops/constraint.yaml"
echo "SecOps root prevention constraint applied."
echo ""

# ─── 10. Metrics Server ──────────────────────────────────────────────────────
echo "[10/11] Installing Metrics Server..."
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --values "${SCRIPT_DIR}/metrics-server/values.yaml" \
  --wait \
  --timeout=120s

echo "Metrics Server installed."
echo ""

# ─── 11. Summary ─────────────────────────────────────────────────────────────
echo "[11/11] Deployment complete. Run verify.sh to validate the setup."
echo ""
echo "  Grafana:       kubectl port-forward -n monitoring service/grafana-stack-grafana 3000:80"
echo "                 Then open http://localhost:3000  (admin / admin123)"
echo "  Gatekeeper:    kubectl get pods -n gatekeeper-system"
echo "  Kubescape:     kubectl get workloadconfigurationscans -A"
if [ "$IS_ORBSTACK" = "true" ]; then
  echo "  Falco:         Skipped on OrbStack (deploy in Coder for full runtime detection)"
else
  echo "  Falco:         kubectl get pods -n falco-system"
fi
echo "  Metrics:       kubectl top nodes  (may take ~60s to populate)"
echo ""
