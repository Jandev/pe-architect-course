#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect OrbStack — same check used in deploy.sh
IS_ORBSTACK=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | grep -q '^orbstack$' && echo true || echo false)

PASS=0
FAIL=0

pass() { echo "  [PASS] $1"; ((PASS++)) || true; }
fail() { echo "  [FAIL] $1"; ((FAIL++)) || true; }

echo "=== Foundation Verification ==="
echo ""

# ─── Namespaces ───────────────────────────────────────────────────────────────
echo "--- Namespaces ---"
kubectl get namespace monitoring &>/dev/null \
  && pass "Namespace 'monitoring' exists" \
  || fail "Namespace 'monitoring' not found"

kubectl get namespace gatekeeper-system &>/dev/null \
  && pass "Namespace 'gatekeeper-system' exists" \
  || fail "Namespace 'gatekeeper-system' not found"
echo ""

# ─── Grafana / Monitoring Stack ───────────────────────────────────────────────
echo "--- Grafana (kube-prometheus-stack) ---"
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=grafana \
  -n monitoring \
  --timeout=300s &>/dev/null \
  && pass "Grafana pod is Ready" \
  || fail "Grafana pod is NOT ready"

kubectl get service grafana-stack -n monitoring &>/dev/null \
  && pass "Grafana service exists" \
  || fail "Grafana service not found"
echo ""

# ─── Gatekeeper ──────────────────────────────────────────────────────────────
echo "--- OPA Gatekeeper ---"
kubectl rollout status deployment/gatekeeper-controller-manager \
  -n gatekeeper-system --timeout=90s &>/dev/null \
  && pass "Gatekeeper controller-manager deployment is Ready" \
  || fail "Gatekeeper controller-manager deployment is NOT ready"

kubectl rollout status deployment/gatekeeper-audit \
  -n gatekeeper-system --timeout=90s &>/dev/null \
  && pass "Gatekeeper audit deployment is Ready" \
  || fail "Gatekeeper audit deployment is NOT ready"

kubectl get constrainttemplate k8srequiredlabels &>/dev/null \
  && pass "ConstraintTemplate 'k8srequiredlabels' exists" \
  || fail "ConstraintTemplate 'k8srequiredlabels' not found"

kubectl get k8srequiredlabels ns-must-have-gk &>/dev/null \
  && pass "Constraint 'ns-must-have-gk' exists" \
  || fail "Constraint 'ns-must-have-gk' not found"
echo ""

# ─── Gatekeeper Policy Enforcement ───────────────────────────────────────────
echo "--- Gatekeeper Policy Enforcement ---"

# Unlabelled namespace should be DENIED
DENY_OUTPUT=$(kubectl create namespace verify-test-deny 2>&1 || true)
kubectl delete namespace verify-test-deny &>/dev/null || true
if echo "${DENY_OUTPUT}" | grep -q "denied\|admission webhook"; then
  pass "Creating namespace without 'admission' label is correctly DENIED"
else
  fail "Creating namespace without 'admission' label was NOT denied (policy may not be active)"
fi

# Labelled namespace should be ALLOWED
ALLOW_OUTPUT=$(kubectl apply -f "${SCRIPT_DIR}/gatekeeper/namespace-labels/ns-with-label.yaml" 2>&1 || true)
if echo "${ALLOW_OUTPUT}" | grep -qv "Error\|error\|denied"; then
  pass "Creating namespace with 'admission' label is correctly ALLOWED"
  kubectl delete -f "${SCRIPT_DIR}/gatekeeper/namespace-labels/ns-with-label.yaml" &>/dev/null || true
else
  fail "Creating namespace with 'admission' label FAILED: ${ALLOW_OUTPUT}"
fi
echo ""
# ─── CVE Vulnerability Scanning ─────────────────────────────────────────────────────────
echo "--- CVE Vulnerability Scanning ---"
kubectl get constrainttemplate vulnerabilityscan &>/dev/null \
  && pass "ConstraintTemplate 'vulnerabilityscan' exists" \
  || fail "ConstraintTemplate 'vulnerabilityscan' not found"

kubectl get vulnerabilityscan enforce-vulnerability-scanning &>/dev/null \
  && pass "Constraint 'enforce-vulnerability-scanning' exists" \
  || fail "Constraint 'enforce-vulnerability-scanning' not found"

# httpd:2.4 has 2 critical CVEs — should be DENIED
CVE_DENY_OUTPUT=$(kubectl apply -f "${SCRIPT_DIR}/gatekeeper/vulnerability/deployment.yaml" 2>&1 || true)
kubectl delete -f "${SCRIPT_DIR}/gatekeeper/vulnerability/deployment.yaml" &>/dev/null || true
if echo "${CVE_DENY_OUTPUT}" | grep -q "denied\|admission webhook"; then
  pass "Deploying image with critical CVEs is correctly DENIED"
else
  fail "Deploying image with critical CVEs was NOT denied (CVE policy may not be active)"
fi

# nginx:1.21 has 0 critical, 1 high CVE — should be ALLOWED
CVE_ALLOW_OUTPUT=$(kubectl apply -f "${SCRIPT_DIR}/gatekeeper/vulnerability/deployment-working.yaml" 2>&1 || true)
if echo "${CVE_ALLOW_OUTPUT}" | grep -qv "Error\|error\|denied"; then
  pass "Deploying image with acceptable CVE levels is correctly ALLOWED"
  kubectl delete -f "${SCRIPT_DIR}/gatekeeper/vulnerability/deployment-working.yaml" &>/dev/null || true
else
  fail "Deploying image with acceptable CVE levels FAILED: ${CVE_ALLOW_OUTPUT}"
fi
echo ""

# ─── Code Quality Enforcement ────────────────────────────────────────────────────────────────
echo "--- Code Quality (Coverage) ---"
kubectl get constrainttemplate codecoveragesimple &>/dev/null \
  && pass "ConstraintTemplate 'codecoveragesimple' exists" \
  || fail "ConstraintTemplate 'codecoveragesimple' not found"

kubectl get codecoveragesimple enforce-code-coverage-simple &>/dev/null \
  && pass "Constraint 'enforce-code-coverage-simple' exists" \
  || fail "Constraint 'enforce-code-coverage-simple' not found"

# commit b2c3... maps to 72% — below 80% minimum, should be DENIED
QA_DENY_OUTPUT=$(kubectl apply -f "${SCRIPT_DIR}/gatekeeper/code-quality/deployment.yaml" 2>&1 || true)
kubectl delete -f "${SCRIPT_DIR}/gatekeeper/code-quality/deployment.yaml" &>/dev/null || true
if echo "${QA_DENY_OUTPUT}" | grep -q "denied\|admission webhook"; then
  pass "Deploying with low code coverage (72%) is correctly DENIED"
else
  fail "Deploying with low code coverage (72%) was NOT denied (quality policy may not be active)"
fi

# commit a1b2... maps to 85% — above 80% minimum, should be ALLOWED
QA_ALLOW_OUTPUT=$(kubectl apply -f "${SCRIPT_DIR}/gatekeeper/code-quality/deployment-working.yaml" 2>&1 || true)
if echo "${QA_ALLOW_OUTPUT}" | grep -qv "Error\|error\|denied"; then
  pass "Deploying with sufficient code coverage (85%) is correctly ALLOWED"
  kubectl delete -f "${SCRIPT_DIR}/gatekeeper/code-quality/deployment-working.yaml" &>/dev/null || true
else
  fail "Deploying with sufficient code coverage (85%) FAILED: ${QA_ALLOW_OUTPUT}"
fi
echo ""
# ─── Metrics Server ───────────────────────────────────────────────────────────
echo "--- Metrics Server ---"
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=metrics-server \
  -n kube-system \
  --timeout=90s &>/dev/null \
  && pass "Metrics Server pod is Ready" \
  || fail "Metrics Server pod is NOT ready"

# kubectl top may need up to 60s after the pod is ready to serve data
if kubectl top nodes &>/dev/null; then
  pass "'kubectl top nodes' returns metrics"
else
  fail "'kubectl top nodes' did not return metrics (may need more time — retry after 60s)"
fi
echo ""

# ─── Falco Runtime Security ───────────────────────────────────────────────────
echo "--- Falco Runtime Security ---"
if [ "$IS_ORBSTACK" = "true" ]; then
  echo "  [SKIP] Falco was not deployed on OrbStack (BPF verifier limit exceeded — deploy in Coder)"
else
  kubectl get namespace falco-system &>/dev/null \
    && pass "Namespace 'falco-system' exists" \
    || fail "Namespace 'falco-system' not found"

  kubectl rollout status daemonset/falco \
    -n falco-system --timeout=120s &>/dev/null \
    && pass "Falco DaemonSet is Ready" \
    || fail "Falco DaemonSet is NOT ready"

  if kubectl logs -n falco-system daemonset/falco 2>/dev/null | grep -q "custom_rules"; then
    pass "Falco custom rules are loaded"
  else
    fail "Falco custom rules not detected in logs"
  fi
fi
echo ""

# ─── Kubescape Compliance Scanning ───────────────────────────────────────────
echo "--- Kubescape Compliance Scanning ---"
kubectl get namespace kubescape &>/dev/null \
  && pass "Namespace 'kubescape' exists" \
  || fail "Namespace 'kubescape' not found"

kubectl rollout status deployment/kubescape \
  -n kubescape --timeout=120s &>/dev/null \
  && pass "Kubescape deployment is Ready" \
  || fail "Kubescape deployment is NOT ready"

if kubectl get crd rules.kubescape.io &>/dev/null; then
  pass "Kubescape rules CRD is registered"
else
  fail "Kubescape rules CRD not found"
fi

# WorkloadConfigurationScan is served by an aggregated API (storage pod), not a CRD
if kubectl get workloadconfigurationscans -A &>/dev/null; then
  pass "Kubescape WorkloadConfigurationScan aggregated API is available"
else
  fail "Kubescape WorkloadConfigurationScan API not available (storage pod may not be ready)"
fi
echo ""

# ─── Gatekeeper SecOps (Root Prevention) ─────────────────────────────────────
echo "--- Gatekeeper SecOps (Root Prevention) ---"
kubectl get constrainttemplate falcorootprevention &>/dev/null \
  && pass "ConstraintTemplate 'falcorootprevention' exists" \
  || fail "ConstraintTemplate 'falcorootprevention' not found"

kubectl get falcorootprevention enforce-falco-root-prevention &>/dev/null \
  && pass "Constraint 'enforce-falco-root-prevention' exists" \
  || fail "Constraint 'enforce-falco-root-prevention' not found"

# runAsUser: 0 — should be DENIED
SECOPS_DENY_OUTPUT=$(kubectl apply -f "${SCRIPT_DIR}/gatekeeper/secops/deployment.yaml" 2>&1 || true)
kubectl delete -f "${SCRIPT_DIR}/gatekeeper/secops/deployment.yaml" &>/dev/null || true
if echo "${SECOPS_DENY_OUTPUT}" | grep -q "denied\|admission webhook"; then
  pass "Deploying root-user container (UID 0) is correctly DENIED"
else
  fail "Deploying root-user container (UID 0) was NOT denied (secops policy may not be active)"
fi

# runAsUser: 1000, runAsNonRoot: true — should be ALLOWED
SECOPS_ALLOW_OUTPUT=$(kubectl apply -f "${SCRIPT_DIR}/gatekeeper/secops/deployment-working.yaml" 2>&1 || true)
if echo "${SECOPS_ALLOW_OUTPUT}" | grep -qv "Error\|error\|denied"; then
  pass "Deploying non-root container (UID 1000) is correctly ALLOWED"
  kubectl delete -f "${SCRIPT_DIR}/gatekeeper/secops/deployment-working.yaml" &>/dev/null || true
else
  fail "Deploying non-root container (UID 1000) FAILED: ${SECOPS_ALLOW_OUTPUT}"
fi
echo ""

# ─── Keycloak ────────────────────────────────────────────────────────────────
echo "--- Keycloak ---"

kubectl get namespace keycloak &>/dev/null \
  && pass "Namespace 'keycloak' exists" \
  || fail "Namespace 'keycloak' not found"

kubectl rollout status deployment/keycloak-postgres \
  -n keycloak --timeout=120s &>/dev/null \
  && pass "Keycloak Postgres deployment is Ready" \
  || fail "Keycloak Postgres deployment is NOT ready"

kubectl rollout status deployment/keycloak \
  -n keycloak --timeout=180s &>/dev/null \
  && pass "Keycloak deployment is Ready" \
  || fail "Keycloak deployment is NOT ready"

kubectl port-forward -n keycloak svc/keycloak-service 18080:8080 &>/dev/null &
KC_PF_PID=$!
sleep 3
if curl -sf http://localhost:18080/realms/teams &>/dev/null; then
  pass "Keycloak 'teams' realm is reachable"
else
  fail "Keycloak 'teams' realm is NOT reachable"
fi
kill "${KC_PF_PID}" 2>/dev/null
wait "${KC_PF_PID}" 2>/dev/null

kubectl get configmap keycloak-realm-config -n keycloak &>/dev/null \
  && pass "Keycloak realm ConfigMap exists" \
  || fail "Keycloak realm ConfigMap not found"
echo ""

# ─── Teams API ────────────────────────────────────────────────────────────────
echo "--- Teams API ---"

kubectl get namespace teams-api &>/dev/null \
  && pass "Namespace 'teams-api' exists" \
  || fail "Namespace 'teams-api' not found"

kubectl rollout status deployment/teams-api \
  -n teams-api --timeout=120s &>/dev/null \
  && pass "Teams API deployment is Ready" \
  || fail "Teams API deployment is NOT ready"

if "${SCRIPT_DIR}/tli" health &>/dev/null; then
  pass "tli health exits successfully"
else
  fail "tli health returned non-zero exit code (API may not be reachable)"
fi
echo ""

# ─── Teams UI ────────────────────────────────────────────────────────────────
echo "--- Teams UI ---"

kubectl get namespace teams-ui &>/dev/null \
  && pass "Namespace 'teams-ui' exists" \
  || fail "Namespace 'teams-ui' not found"

kubectl rollout status deployment/teams-ui \
  -n teams-ui --timeout=120s &>/dev/null \
  && pass "Teams UI deployment is Ready" \
  || fail "Teams UI deployment is NOT ready"

if curl -sf http://teams-ui.127.0.0.1.sslip.io:30080 &>/dev/null; then
  pass "Teams UI is reachable at http://teams-ui.127.0.0.1.sslip.io:30080"
else
  fail "Teams UI is NOT reachable at http://teams-ui.127.0.0.1.sslip.io:30080"
fi
echo ""

# ─── Teams Operator ───────────────────────────────────────────────────────────
echo "--- Teams Operator ---"

kubectl get namespace engineering-platform &>/dev/null \
  && pass "Namespace 'engineering-platform' exists" \
  || fail "Namespace 'engineering-platform' not found"

kubectl rollout status deployment/teams-operator \
  -n engineering-platform --timeout=120s &>/dev/null \
  && pass "Teams Operator deployment is Ready" \
  || fail "Teams Operator deployment is NOT ready"

kubectl get clusterrole teams-operator &>/dev/null \
  && pass "ClusterRole 'teams-operator' exists" \
  || fail "ClusterRole 'teams-operator' not found"

kubectl get clusterrolebinding teams-operator &>/dev/null \
  && pass "ClusterRoleBinding 'teams-operator' exists" \
  || fail "ClusterRoleBinding 'teams-operator' not found"

# Smoke test: create a team → wait for operator to reconcile → verify namespace
SMOKE_TEAM_NAME="verify-operator-smoke-test"
SMOKE_NAMESPACE="team-verify-operator-smoke-test"

echo "  Smoke test: creating team '${SMOKE_TEAM_NAME}' via Teams API..."
SMOKE_RESPONSE=$(curl -sf -X POST "http://teams-api.127.0.0.1.sslip.io:30080/teams" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"${SMOKE_TEAM_NAME}\"}" 2>&1 || true)
SMOKE_TEAM_ID=$(echo "${SMOKE_RESPONSE}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || true)

if [ -z "${SMOKE_TEAM_ID}" ]; then
  fail "Teams Operator smoke test: could not create team via API (response: ${SMOKE_RESPONSE})"
else
  # Wait up to 40s for the operator to reconcile and create the namespace
  SMOKE_DEADLINE=$(( $(date +%s) + 40 ))
  while [ "$(date +%s)" -lt "${SMOKE_DEADLINE}" ]; do
    if kubectl get namespace "${SMOKE_NAMESPACE}" &>/dev/null; then
      break
    fi
    sleep 5
  done

  if kubectl get namespace "${SMOKE_NAMESPACE}" &>/dev/null; then
    pass "Teams Operator smoke test: namespace '${SMOKE_NAMESPACE}' created after team was added"

    # Check admission label
    ADMISSION_LABEL=$(kubectl get namespace "${SMOKE_NAMESPACE}" -o jsonpath='{.metadata.labels.admission}' 2>/dev/null || true)
    if [ "${ADMISSION_LABEL}" = "true" ]; then
      pass "Teams Operator smoke test: namespace has required 'admission: true' label"
    else
      fail "Teams Operator smoke test: namespace is missing 'admission: true' label"
    fi

    # Check created-by label
    CREATED_BY=$(kubectl get namespace "${SMOKE_NAMESPACE}" -o jsonpath='{.metadata.labels.teams\.example\.com/created-by}' 2>/dev/null || true)
    if [ "${CREATED_BY}" = "teams-operator" ]; then
      pass "Teams Operator smoke test: namespace has 'teams.example.com/created-by: teams-operator' label"
    else
      fail "Teams Operator smoke test: namespace is missing 'teams.example.com/created-by' label"
    fi

    # Check created-at annotation
    CREATED_AT=$(kubectl get namespace "${SMOKE_NAMESPACE}" -o jsonpath='{.metadata.annotations.teams\.example\.com/created-at}' 2>/dev/null || true)
    if [ -n "${CREATED_AT}" ]; then
      pass "Teams Operator smoke test: namespace has 'teams.example.com/created-at' annotation (${CREATED_AT})"
    else
      fail "Teams Operator smoke test: namespace is missing 'teams.example.com/created-at' annotation"
    fi
  else
    fail "Teams Operator smoke test: namespace '${SMOKE_NAMESPACE}' was NOT created within 40s"
  fi

  # Verify operator deletes the namespace when the team is removed
  echo "  Smoke test: deleting team '${SMOKE_TEAM_NAME}' via Teams API..."
  curl -sf -X DELETE "http://teams-api.127.0.0.1.sslip.io:30080/teams/${SMOKE_TEAM_ID}" &>/dev/null || true

  DELETE_DEADLINE=$(( $(date +%s) + 40 ))
  while [ "$(date +%s)" -lt "${DELETE_DEADLINE}" ]; do
    if ! kubectl get namespace "${SMOKE_NAMESPACE}" &>/dev/null; then
      break
    fi
    sleep 5
  done

  if ! kubectl get namespace "${SMOKE_NAMESPACE}" &>/dev/null; then
    pass "Teams Operator smoke test: namespace '${SMOKE_NAMESPACE}' was deleted after team was removed"
  else
    fail "Teams Operator smoke test: namespace '${SMOKE_NAMESPACE}' was NOT deleted within 40s after team removal"
    # Force-clean so leftover state doesn't affect the cluster
    kubectl delete namespace "${SMOKE_NAMESPACE}" --ignore-not-found &>/dev/null || true
  fi
fi
echo ""

# ─── Summary ─────────────────────────────────────────────────────────────────
echo "=== Argo Rollouts ==="
echo ""

# ─── Argo Rollouts Controller ─────────────────────────────────────────────────
echo "--- Argo Rollouts Controller ---"
kubectl get namespace argo-rollouts &>/dev/null \
  && pass "Namespace 'argo-rollouts' exists" \
  || fail "Namespace 'argo-rollouts' not found"

kubectl rollout status deployment/argo-rollouts \
  -n argo-rollouts --timeout=120s &>/dev/null \
  && pass "Argo Rollouts controller deployment is Ready" \
  || fail "Argo Rollouts controller deployment is NOT ready"
echo ""

# ─── RequireArgoRollouts Gatekeeper Constraint ────────────────────────────────
echo "--- RequireArgoRollouts Constraint ---"
kubectl get constrainttemplate requireargorollouts &>/dev/null \
  && pass "ConstraintTemplate 'requireargorollouts' exists" \
  || fail "ConstraintTemplate 'requireargorollouts' not found"

kubectl get requireargorollouts require-argo-rollouts-in-production &>/dev/null \
  && pass "Constraint 'require-argo-rollouts-in-production' exists" \
  || fail "Constraint 'require-argo-rollouts-in-production' not found"

# Raw Deployment in 'production' should be DENIED
ARGO_DENY_OUTPUT=$(kubectl apply -f "${SCRIPT_DIR}/gatekeeper/argo-rollouts/deployment.yaml" 2>&1 || true)
kubectl delete -f "${SCRIPT_DIR}/gatekeeper/argo-rollouts/deployment.yaml" &>/dev/null || true
if echo "${ARGO_DENY_OUTPUT}" | grep -q "denied\|admission webhook"; then
  pass "Deploying a raw Deployment to 'production' is correctly DENIED"
else
  fail "Deploying a raw Deployment to 'production' was NOT denied (RequireArgoRollouts policy may not be active)"
fi
echo ""

# ─── Production Namespace ─────────────────────────────────────────────────────
echo "--- Production Namespace ---"
kubectl get namespace production &>/dev/null \
  && pass "Namespace 'production' exists" \
  || fail "Namespace 'production' not found"

PROD_LABEL=$(kubectl get namespace production -o jsonpath='{.metadata.labels.admission}' 2>/dev/null || true)
if [ "${PROD_LABEL}" = "true" ]; then
  pass "Namespace 'production' has required 'admission: true' label"
else
  fail "Namespace 'production' is missing 'admission: true' label"
fi
echo ""

# ─── rollout-demo-api (Argo Rollout) ──────────────────────────────────────────
echo "--- rollout-demo-api (Argo Rollouts Blue/Green) ---"

# Use jsonpath — kubectl argo rollouts plugin is not required
ROLLOUT_PHASE=$(kubectl get rollout rollout-demo-api -n production \
  -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [ "${ROLLOUT_PHASE}" = "Healthy" ] || [ "${ROLLOUT_PHASE}" = "Paused" ]; then
  pass "rollout-demo-api Rollout phase is '${ROLLOUT_PHASE}'"
else
  fail "rollout-demo-api Rollout phase is '${ROLLOUT_PHASE}' (expected Healthy or Paused)"
fi

# ── Active service (blue / v1) ─────────────────────────────────────────────
if curl -sf http://rollout-demo-api.127.0.0.1.sslip.io:30080/health &>/dev/null; then
  pass "Active service /health endpoint is reachable"
else
  fail "Active service /health endpoint is NOT reachable"
fi

ACTIVE_RESPONSE=$(curl -sf http://rollout-demo-api.127.0.0.1.sslip.io:30080/ 2>/dev/null || true)
ACTIVE_COLOR=$(echo "${ACTIVE_RESPONSE}" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('color',''))" 2>/dev/null || true)
ACTIVE_VERSION=$(echo "${ACTIVE_RESPONSE}" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('version',''))" 2>/dev/null || true)

if [ "${ACTIVE_COLOR}" = "blue" ]; then
  pass "Active service returns color='blue' (v1 — before promotion)"
else
  fail "Active service returned color='${ACTIVE_COLOR}' (expected 'blue')"
fi
if [ "${ACTIVE_VERSION}" = "v1" ]; then
  pass "Active service returns version='v1'"
else
  fail "Active service returned version='${ACTIVE_VERSION}' (expected 'v1')"
fi

# ── Preview service (green / v2) ───────────────────────────────────────────
if curl -sf http://rollout-demo-api-preview.127.0.0.1.sslip.io:30080/health &>/dev/null; then
  pass "Preview service /health endpoint is reachable"
else
  fail "Preview service /health endpoint is NOT reachable"
fi

PREVIEW_RESPONSE=$(curl -sf http://rollout-demo-api-preview.127.0.0.1.sslip.io:30080/ 2>/dev/null || true)
PREVIEW_COLOR=$(echo "${PREVIEW_RESPONSE}" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('color',''))" 2>/dev/null || true)
PREVIEW_VERSION=$(echo "${PREVIEW_RESPONSE}" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('version',''))" 2>/dev/null || true)

if [ "${PREVIEW_COLOR}" = "green" ]; then
  pass "Preview service returns color='green' (v2 — awaiting promotion)"
else
  fail "Preview service returned color='${PREVIEW_COLOR}' (expected 'green')"
fi
if [ "${PREVIEW_VERSION}" = "v2" ]; then
  pass "Preview service returns version='v2'"
else
  fail "Preview service returned version='${PREVIEW_VERSION}' (expected 'v2')"
fi
echo ""

# ─── Blue/Green Promotion Validation ─────────────────────────────────────────
echo "--- Blue/Green Promotion Validation ---"
echo "  Promoting rollout (green/v2 → active)..."
kubectl argo rollouts promote rollout-demo-api -n production &>/dev/null || true

# Wait up to 120s for the rollout to become Healthy again after promotion
PROMOTE_DEADLINE=$(( $(date +%s) + 120 ))
while [ "$(date +%s)" -lt "${PROMOTE_DEADLINE}" ]; do
  PROMOTE_PHASE=$(kubectl get rollout rollout-demo-api -n production \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "${PROMOTE_PHASE}" = "Healthy" ] && break
  sleep 3
done
PROMOTE_PHASE=$(kubectl get rollout rollout-demo-api -n production \
  -o jsonpath='{.status.phase}' 2>/dev/null || true)

if [ "${PROMOTE_PHASE}" = "Healthy" ]; then
  pass "Rollout is Healthy after promotion"
else
  fail "Rollout did not reach Healthy state within 120s (phase: ${PROMOTE_PHASE})"
fi

# After promotion the active service must serve the promoted color (green/v2)
PROMOTED_RESPONSE=$(curl -sf http://rollout-demo-api.127.0.0.1.sslip.io:30080/ 2>/dev/null || true)
PROMOTED_COLOR=$(echo "${PROMOTED_RESPONSE}" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('color',''))" 2>/dev/null || true)
PROMOTED_VERSION=$(echo "${PROMOTED_RESPONSE}" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('version',''))" 2>/dev/null || true)

if [ "${PROMOTED_COLOR}" = "green" ]; then
  pass "After promotion: active service now returns color='green' (v2 promoted to production)"
else
  fail "After promotion: active service returned color='${PROMOTED_COLOR}' (expected 'green')"
fi
if [ "${PROMOTED_VERSION}" = "v2" ]; then
  pass "After promotion: active service now returns version='v2'"
else
  fail "After promotion: active service returned version='${PROMOTED_VERSION}' (expected 'v2')"
fi
echo ""

# ─── Summary ─────────────────────────────────────────────────────────────────
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
echo ""

if [[ ${FAIL} -eq 0 ]]; then
  echo "All checks passed. Foundation setup is complete."
  echo ""
  echo "  Keycloak:         http://platform-auth.127.0.0.1.sslip.io:30080  (admin / admin)"
  echo "  Teams API:        http://teams-api.127.0.0.1.sslip.io:30080"
  echo "  Teams UI:         http://teams-ui.127.0.0.1.sslip.io:30080"
  echo "  Rollout Demo API (active):  http://rollout-demo-api.127.0.0.1.sslip.io:30080  (green/v2 after promotion)"
  echo "  Argo Rollouts:              kubectl get rollouts -n production"
  echo ""
  exit 0
else
  echo "Some checks failed. Review the output above and consult workshop/foundation/README.md for troubleshooting."
  exit 1
fi
