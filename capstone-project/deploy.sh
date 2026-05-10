#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect OrbStack — its ARM64 kernel BPF verifier limit blocks Falco's eBPF driver
IS_ORBSTACK=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | grep -q '^orbstack$' && echo true || echo false)

# Detect kind cluster name dynamically (used for image loading)
KIND_CLUSTER=$(kind get clusters 2>/dev/null | head -1 || true)

echo "=== Foundation Setup: Grafana, Gatekeeper, Falco, Metrics Server, Keycloak ==="
echo ""

# ─── 1. Helm Repositories ────────────────────────────────────────────────────
echo "[1/19] Adding Helm repositories..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo add kubescape https://kubescape.github.io/helm-charts/
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
echo ""

# ─── 2. Ingress-Nginx ────────────────────────────────────────────
echo "[2/19] Installing Ingress-Nginx..."
kubectl apply -f "${SCRIPT_DIR}/ingress-nginx/namespace.yaml"
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --values "${SCRIPT_DIR}/ingress-nginx/values.yaml" \
  --wait \
  --timeout=300s
echo "Ingress-Nginx installed."
echo ""

# ─── 2. Grafana Stack ────────────────────────────────────────────────────────
echo "[3/19] Installing Grafana stack (kube-prometheus-stack)..."
kubectl apply -f "${SCRIPT_DIR}/grafana/namespace.yaml"

helm upgrade --install grafana-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values "${SCRIPT_DIR}/grafana/values.yaml" \
  --wait \
  --timeout=600s

echo "Grafana stack installed."
echo ""

# ─── 3. Gatekeeper ───────────────────────────────────────────────────────────
echo "[4/19] Installing OPA Gatekeeper..."
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.14/deploy/gatekeeper.yaml

echo "Waiting for Gatekeeper deployments to be ready..."
kubectl rollout status deployment/gatekeeper-controller-manager -n gatekeeper-system --timeout=120s
kubectl rollout status deployment/gatekeeper-audit -n gatekeeper-system --timeout=120s

echo "Gatekeeper installed."
echo ""

# ─── 4. Gatekeeper Constraint Template & Constraint ──────────────────────────
echo "[5/19] Applying Gatekeeper namespace-labels constraint..."
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
echo "[6/19] Applying CVE vulnerability scanning constraint..."
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
echo "[7/19] Applying code quality (coverage) constraint..."
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
echo "[8/19] Installing Falco runtime security..."
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
echo "[9/19] Installing Kubescape compliance scanning..."
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
echo "[10/19] Applying Gatekeeper secops (root prevention) constraint..."
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
echo "[11/19] Installing Metrics Server..."
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --values "${SCRIPT_DIR}/metrics-server/values.yaml" \
  --wait \
  --timeout=120s

echo "Metrics Server installed."
echo ""

# ─── 11. Deploy Keycloak ─────────────────────────────────────────────────────
echo "[12/19] Deploying Keycloak to Kubernetes..."
kubectl apply -f "${SCRIPT_DIR}/keycloak/keycloak.yaml"
echo "Waiting for Keycloak Postgres rollout..."
kubectl rollout status deployment/keycloak-postgres -n keycloak --timeout=120s
echo "Keycloak resources deployed."
echo ""

# ─── 12. Wait for Keycloak Rollout ───────────────────────────────────────────
echo "[13/19] Waiting for Keycloak rollout..."
kubectl rollout status deployment/keycloak -n keycloak --timeout=180s
echo "Keycloak is ready."
echo ""

# ─── 13. Build and Publish Teams CLI ────────────────────────────────────────
echo "[14/19] Building Teams CLI as a single-file executable..."
DOTNET_RID=$(dotnet --info 2>/dev/null | awk '/^[[:space:]]+RID:/{print $2; exit}')
dotnet publish "${SCRIPT_DIR}/teams-cli/teams-cli.cs" -c Release -r "${DOTNET_RID}" -p:PublishSingleFile=true -p:SelfContained=true -o "${SCRIPT_DIR}/bin"
cp "${SCRIPT_DIR}/bin/tli" "${SCRIPT_DIR}/tli"
chmod +x "${SCRIPT_DIR}/tli"
echo "Teams CLI installed: ${SCRIPT_DIR}/tli"
echo ""

# ─── 14. Build Teams API Docker Image ────────────────────────────────────────
echo "[15/19] Building Teams API Docker image..."
docker build -t teams-api:local "${SCRIPT_DIR}/teams-api/src/"
echo "Teams API image built: teams-api:local"
echo ""

# ─── 15. Load Image into Kind Cluster ────────────────────────────────────────
if [ "$IS_ORBSTACK" = "true" ]; then
  echo "[16/19] Skipping kind image load on OrbStack (local Docker images are directly accessible)."
else
  if [ -z "$KIND_CLUSTER" ]; then
    echo "[16/19] WARNING: No kind cluster found — skipping image load. Run 'kind load docker-image teams-api:local --name <cluster>' manually."
  else
    echo "[16/19] Loading Teams API image into kind cluster '${KIND_CLUSTER}'..."
    kind load docker-image teams-api:local --name "${KIND_CLUSTER}"
    echo "Image loaded into cluster '${KIND_CLUSTER}'."
  fi
fi
echo ""

# ─── 16. Deploy Teams API to Kubernetes ──────────────────────────────────────
echo "[17/19] Deploying Teams API to Kubernetes..."
kubectl apply -f "${SCRIPT_DIR}/teams-api/deployment.yaml"
echo "Teams API deployed."
echo ""

# ─── 17. Wait for Teams API Rollout ──────────────────────────────────────────
echo "[18/19] Waiting for Teams API rollout..."
kubectl rollout status deployment/teams-api -n teams-api --timeout=120s
echo "Teams API is ready."
echo ""

# ─── 18. Summary ─────────────────────────────────────────────────────────────
echo "[19/19] Deployment complete. Run verify.sh to validate the setup."
echo ""
echo "  Grafana:       http://grafana.127.0.0.1.sslip.io:30080  (admin / admin123)"
echo "  Prometheus:    http://prometheus.127.0.0.1.sslip.io:30080"
echo "  AlertManager:  http://alertmanager.127.0.0.1.sslip.io:30080"
echo "  Gatekeeper:    kubectl get pods -n gatekeeper-system"
echo "  Kubescape:     kubectl get workloadconfigurationscans -A"
if [ "$IS_ORBSTACK" = "true" ]; then
  echo "  Falco:         Skipped on OrbStack (deploy in Coder for full runtime detection)"
else
  echo "  Falco:         kubectl get pods -n falco-system"
fi
echo "  Metrics:       kubectl top nodes  (may take ~60s to populate)"
echo "  Keycloak:      http://platform-auth.127.0.0.1.sslip.io:30080"
echo "  Teams API:     http://teams-api.127.0.0.1.sslip.io:30080"
echo "  Teams CLI:     ./tli health"
echo ""
