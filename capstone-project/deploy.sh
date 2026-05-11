#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect OrbStack — its ARM64 kernel BPF verifier limit blocks Falco's eBPF driver
IS_ORBSTACK=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | grep -q '^orbstack$' && echo true || echo false)

# Detect kind cluster name dynamically (used for image loading)
KIND_CLUSTER=$(kind get clusters 2>/dev/null | head -1 || true)

echo "=== Foundation Setup: Grafana, Gatekeeper, Falco, Metrics Server, Keycloak, Teams ==="
echo ""

# ─── 1. Helm Repositories ────────────────────────────────────────────────────
echo "[1/30] Adding Helm repositories..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo add kubescape https://kubescape.github.io/helm-charts/
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
echo ""

# ─── 2. Ingress-Nginx ────────────────────────────────────────────
echo "[2/30] Installing Ingress-Nginx..."
kubectl apply -f "${SCRIPT_DIR}/ingress-nginx/namespace.yaml"
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --values "${SCRIPT_DIR}/ingress-nginx/values.yaml" \
  --wait \
  --timeout=300s
echo "Ingress-Nginx installed."
echo ""

# ─── 2. Grafana Stack ────────────────────────────────────────────────────────
echo "[3/30] Installing Grafana stack (kube-prometheus-stack)..."
kubectl apply -f "${SCRIPT_DIR}/grafana/namespace.yaml"

helm upgrade --install grafana-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values "${SCRIPT_DIR}/grafana/values.yaml" \
  --wait \
  --timeout=600s

echo "Grafana stack installed."
echo ""

# ─── 3. Gatekeeper ───────────────────────────────────────────────────────────
echo "[4/30] Installing OPA Gatekeeper..."
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.14/deploy/gatekeeper.yaml

echo "Waiting for Gatekeeper deployments to be ready..."
kubectl rollout status deployment/gatekeeper-controller-manager -n gatekeeper-system --timeout=120s
kubectl rollout status deployment/gatekeeper-audit -n gatekeeper-system --timeout=120s

echo "Gatekeeper installed."
echo ""

# ─── 4. Gatekeeper Constraint Template & Constraint ──────────────────────────
echo "[5/30] Applying Gatekeeper namespace-labels constraint..."
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
echo "[6/30] Applying CVE vulnerability scanning constraint..."
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
echo "[7/30] Applying code quality (coverage) constraint..."
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
echo "[8/30] Installing Falco runtime security..."
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
echo "[9/30] Installing Kubescape compliance scanning..."
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
echo "[10/30] Applying Gatekeeper secops (root prevention) constraint..."
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
echo "[11/30] Installing Metrics Server..."
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --values "${SCRIPT_DIR}/metrics-server/values.yaml" \
  --wait \
  --timeout=120s

echo "Metrics Server installed."
echo ""

# ─── 11. Deploy Keycloak ─────────────────────────────────────────────────────
echo "[12/30] Deploying Keycloak to Kubernetes..."
kubectl apply -f "${SCRIPT_DIR}/keycloak/keycloak.yaml"
echo "Waiting for Keycloak Postgres rollout..."
kubectl rollout status deployment/keycloak-postgres -n keycloak --timeout=120s
echo "Keycloak resources deployed."
echo ""

# ─── 12. Wait for Keycloak Rollout ───────────────────────────────────────────
echo "[13/30] Waiting for Keycloak rollout..."
kubectl rollout status deployment/keycloak -n keycloak --timeout=180s
echo "Keycloak is ready."
echo ""

# ─── 13. Build and Publish Teams CLI ────────────────────────────────────────
echo "[14/30] Building Teams CLI as a single-file executable..."
DOTNET_RID=$(dotnet --info 2>/dev/null | awk '/^[[:space:]]+RID:/{print $2; exit}')
dotnet publish "${SCRIPT_DIR}/teams-cli/teams-cli.cs" -c Release -r "${DOTNET_RID}" -p:PublishSingleFile=true -p:SelfContained=true -o "${SCRIPT_DIR}/bin"
cp "${SCRIPT_DIR}/bin/tli" "${SCRIPT_DIR}/tli"
chmod +x "${SCRIPT_DIR}/tli"
echo "Teams CLI installed: ${SCRIPT_DIR}/tli"
echo ""

# ─── 14. Build Teams API Docker Image ────────────────────────────────────────
echo "[15/30] Building Teams API Docker image..."
docker build -t teams-api:local "${SCRIPT_DIR}/teams-api/src/"
echo "Teams API image built: teams-api:local"
echo ""

# ─── 15. Load Image into Kind Cluster ────────────────────────────────────────
if [ "$IS_ORBSTACK" = "true" ]; then
  echo "[16/30] Skipping kind image load on OrbStack (local Docker images are directly accessible)."
else
  if [ -z "$KIND_CLUSTER" ]; then
    echo "[16/30] WARNING: No kind cluster found — skipping image load. Run 'kind load docker-image teams-api:local --name <cluster>' manually."
  else
    echo "[16/30] Loading Teams API image into kind cluster '${KIND_CLUSTER}'..."
    kind load docker-image teams-api:local --name "${KIND_CLUSTER}"
    echo "Image loaded into cluster '${KIND_CLUSTER}'."
  fi
fi
echo ""

# ─── 16. Deploy Teams API to Kubernetes ──────────────────────────────────────
echo "[17/30] Deploying Teams API to Kubernetes..."
kubectl apply -f "${SCRIPT_DIR}/teams-api/deployment.yaml"
kubectl rollout restart deployment/teams-api -n teams-api
echo "Teams API deployed."
echo ""

# ─── 17. Wait for Teams API Rollout ──────────────────────────────────────────
echo "[18/30] Waiting for Teams API rollout..."
kubectl rollout status deployment/teams-api -n teams-api --timeout=120s
echo "Teams API is ready."
echo ""

# ─── 19. Build Teams UI Docker Image ────────────────────────────────────────────────
echo "[19/30] Building Teams UI Docker image..."
docker build -t teams-ui:local "${SCRIPT_DIR}/teams-ui/app/"
echo "Teams UI image built: teams-ui:local"
echo ""

# ─── 20. Load Teams UI Image into Kind Cluster ──────────────────────────────────────
if [ "$IS_ORBSTACK" = "true" ]; then
  echo "[20/30] Skipping kind image load on OrbStack (local Docker images are directly accessible)."
else
  if [ -z "$KIND_CLUSTER" ]; then
    echo "[20/30] WARNING: No kind cluster found — skipping image load. Run 'kind load docker-image teams-ui:local --name <cluster>' manually."
  else
    echo "[20/30] Loading Teams UI image into kind cluster '${KIND_CLUSTER}'..."
    kind load docker-image teams-ui:local --name "${KIND_CLUSTER}"
    echo "Image loaded into cluster '${KIND_CLUSTER}'."
  fi
fi
echo ""

# ─── 21. Deploy Teams UI to Kubernetes ───────────────────────────────────────────────
echo "[21/30] Deploying Teams UI to Kubernetes..."
kubectl apply -f "${SCRIPT_DIR}/teams-ui/namespace.yaml"
kubectl apply -f "${SCRIPT_DIR}/teams-ui/deployment.yaml"
kubectl rollout restart deployment/teams-ui -n teams-ui
echo "Waiting for Teams UI rollout..."
kubectl rollout status deployment/teams-ui -n teams-ui --timeout=120s
echo "Teams UI is ready."
echo ""

# ─── 22. Build Teams Operator Docker Image ────────────────────────────────────
echo "[22/30] Building Teams Operator Docker image..."
docker build -t teams-operator:local "${SCRIPT_DIR}/teams-operator/src/"
echo "Teams Operator image built: teams-operator:local"
echo ""

# ─── 23. Load Teams Operator Image into Kind Cluster ─────────────────────────
if [ "$IS_ORBSTACK" = "true" ]; then
  echo "[23/30] Skipping kind image load on OrbStack (local Docker images are directly accessible)."
else
  if [ -z "$KIND_CLUSTER" ]; then
    echo "[23/30] WARNING: No kind cluster found — skipping image load. Run 'kind load docker-image teams-operator:local --name <cluster>' manually."
  else
    echo "[23/30] Loading Teams Operator image into kind cluster '${KIND_CLUSTER}'..."
    kind load docker-image teams-operator:local --name "${KIND_CLUSTER}"
    echo "Image loaded into cluster '${KIND_CLUSTER}'."
  fi
fi
echo ""

# ─── 24. Deploy Teams Operator to Kubernetes ─────────────────────────────────
echo "[24/30] Deploying Teams Operator to Kubernetes..."
kubectl apply -f "${SCRIPT_DIR}/teams-operator/namespace.yaml"
kubectl apply -f "${SCRIPT_DIR}/teams-operator/deployment.yaml"
echo "Waiting for Teams Operator rollout..."
kubectl rollout status deployment/teams-operator -n engineering-platform --timeout=120s
echo "Teams Operator is ready."
echo ""

# ─── 25. Install Argo Rollouts ────────────────────────────────────────────────
echo "[25/30] Installing Argo Rollouts controller and kubectl plugin..."
kubectl apply -f "${SCRIPT_DIR}/argo-rollouts/namespace.yaml"
kubectl apply -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml -n argo-rollouts
echo "Waiting for Argo Rollouts controller..."
kubectl rollout status deployment/argo-rollouts -n argo-rollouts --timeout=180s
echo "Argo Rollouts is ready."

# Install the kubectl argo rollouts plugin if not already present
if ! kubectl argo rollouts version &>/dev/null; then
  echo "Installing kubectl argo rollouts plugin..."
  ARGO_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARGO_ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
  ARGO_PLUGIN_URL="https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-${ARGO_OS}-${ARGO_ARCH}"
  ARGO_TMP=$(mktemp)
  curl -fsSL "${ARGO_PLUGIN_URL}" -o "${ARGO_TMP}"
  chmod +x "${ARGO_TMP}"
  sudo mv "${ARGO_TMP}" /usr/local/bin/kubectl-argo-rollouts
  echo "kubectl argo rollouts plugin installed."
else
  echo "kubectl argo rollouts plugin already installed."
fi
echo ""

# ─── 26. Deploy Production Namespace + RequireArgoRollouts Constraint ─────────
echo "[26/30] Deploying production namespace and RequireArgoRollouts Gatekeeper constraint..."
kubectl apply -f "${SCRIPT_DIR}/gatekeeper/argo-rollouts/namespace.yaml"
kubectl apply -f "${SCRIPT_DIR}/gatekeeper/argo-rollouts/constraint-template.yaml"
echo "Waiting for RequireArgoRollouts ConstraintTemplate to be ready..."
until kubectl get crd requireargorollouts.constraints.gatekeeper.sh &>/dev/null; do sleep 2; done
kubectl wait --for=condition=Established \
  crd/requireargorollouts.constraints.gatekeeper.sh \
  --timeout=60s
kubectl apply -f "${SCRIPT_DIR}/gatekeeper/argo-rollouts/constraint.yaml"
echo "RequireArgoRollouts constraint applied."
echo ""

# ─── 27. Build rollout-demo-api Docker Images (v1 blue + v2 green) ───────────
echo "[27/30] Building rollout-demo-api Docker images (v1=blue, v2=green)..."
docker build \
  --build-arg APP_VERSION=v1 \
  --build-arg APP_COLOR=blue \
  -t jandev/rollout-demo-api:v1 \
  "${SCRIPT_DIR}/rollout-demo-api/src/"
docker build \
  --build-arg APP_VERSION=v2 \
  --build-arg APP_COLOR=green \
  -t jandev/rollout-demo-api:v2 \
  "${SCRIPT_DIR}/rollout-demo-api/src/"
echo "rollout-demo-api images built: v1 (blue) and v2 (green)"
echo ""

# ─── 28. Push rollout-demo-api to Docker Hub ─────────────────────────────────
echo "[28/30] Pushing rollout-demo-api images to Docker Hub..."
docker push jandev/rollout-demo-api:v1
docker push jandev/rollout-demo-api:v2
echo "Images pushed to Docker Hub: jandev/rollout-demo-api:v1 and :v2"
echo ""

# ─── 29. Load rollout-demo-api Images into Kind Cluster ──────────────────────
if [ "$IS_ORBSTACK" = "true" ]; then
  echo "[29/30] Skipping kind image load on OrbStack (local Docker images are directly accessible)."
else
  if [ -z "$KIND_CLUSTER" ]; then
    echo "[29/30] WARNING: No kind cluster found — skipping image load."
  else
    echo "[29/30] Loading rollout-demo-api images into kind cluster '${KIND_CLUSTER}'..."
    kind load docker-image jandev/rollout-demo-api:v1 --name "${KIND_CLUSTER}"
    kind load docker-image jandev/rollout-demo-api:v2 --name "${KIND_CLUSTER}"
    echo "Images loaded into cluster '${KIND_CLUSTER}'."
  fi
fi
echo ""

# ─── 30. Deploy rollout-demo-api via Argo Rollouts ───────────────────────────
echo "[30/30] Deploying rollout-demo-api via Argo Rollouts..."
# Reset the rollout on re-runs so v1 is always the starting active revision.
# Without this, a previous promotion of v2 would leave v2 as active and
# applying rollout.yaml (image: v1) would make v1 the preview instead.
kubectl delete rollout rollout-demo-api -n production --ignore-not-found
kubectl apply -f "${SCRIPT_DIR}/rollout-demo-api/service.yaml"
kubectl apply -f "${SCRIPT_DIR}/rollout-demo-api/ingress.yaml"
kubectl apply -f "${SCRIPT_DIR}/rollout-demo-api/rollout.yaml"
echo "Waiting for rollout-demo-api v1 (blue/active) to become healthy..."
kubectl wait rollout/rollout-demo-api \
  -n production \
  --for=condition=Available \
  --timeout=120s
echo "rollout-demo-api v1 (blue) is healthy — active service is live."
echo ""

# Trigger a Blue/Green rollout to v2 (green) so both pods run simultaneously.
# Argo Rollouts will spin up the green preview pod and pause for manual promotion.
echo "Triggering Blue/Green update to v2 (green)..."
kubectl patch rollout rollout-demo-api -n production --type=merge \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"rollout-demo-api","image":"jandev/rollout-demo-api:v2"}]}}}}'
echo "Waiting for v2 (green) preview pod to become ready..."
# Wait until the preview service has at least one ready endpoint
until kubectl get endpoints rollout-demo-api-preview -n production \
  -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q '.'; do
  sleep 3
done
echo "v2 (green) preview pod is ready — rollout is paused awaiting manual promotion."
echo ""

# ─── Summary ─────────────────────────────────────────────────────────────────
echo "Deployment complete. Run verify.sh to validate the setup."
echo ""
echo "  Grafana:          http://grafana.127.0.0.1.sslip.io:30080  (admin / admin123)"
echo "  Prometheus:       http://prometheus.127.0.0.1.sslip.io:30080"
echo "  AlertManager:     http://alertmanager.127.0.0.1.sslip.io:30080"
echo "  Gatekeeper:       kubectl get pods -n gatekeeper-system"
echo "  Kubescape:        kubectl get workloadconfigurationscans -A"
if [ "$IS_ORBSTACK" = "true" ]; then
  echo "  Falco:            Skipped on OrbStack (deploy in Coder for full runtime detection)"
else
  echo "  Falco:            kubectl get pods -n falco-system"
fi
echo "  Metrics:          kubectl top nodes  (may take ~60s to populate)"
echo "  Keycloak:         http://platform-auth.127.0.0.1.sslip.io:30080"
echo "  Teams API:        http://teams-api.127.0.0.1.sslip.io:30080"
echo "  Teams UI:         http://teams-ui.127.0.0.1.sslip.io:30080  (login: admin / admin123)"
echo "  Teams Operator:   kubectl get pods -n engineering-platform"
echo "  Teams CLI:        ./tli health"
echo "  Argo Rollouts:    kubectl get rollouts -n production"
echo "  Rollout Demo API (blue/active):   http://rollout-demo-api.127.0.0.1.sslip.io:30080"
echo "  Rollout Demo API (green/preview): http://rollout-demo-api-preview.127.0.0.1.sslip.io:30080"
echo "  Promote green→active:             kubectl patch rollout rollout-demo-api -n production --type=merge -p '{\"spec\":{\"paused\":false}}'"
echo ""
