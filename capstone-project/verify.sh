#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
ALLOW_OUTPUT=$(kubectl apply -f "${SCRIPT_DIR}/gatekeeper/ns-with-label.yaml" 2>&1 || true)
if echo "${ALLOW_OUTPUT}" | grep -qv "Error\|error\|denied"; then
  pass "Creating namespace with 'admission' label is correctly ALLOWED"
  kubectl delete -f "${SCRIPT_DIR}/gatekeeper/ns-with-label.yaml" &>/dev/null || true
else
  fail "Creating namespace with 'admission' label FAILED: ${ALLOW_OUTPUT}"
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

# ─── Summary ─────────────────────────────────────────────────────────────────
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
echo ""

if [[ ${FAIL} -eq 0 ]]; then
  echo "All checks passed. Foundation setup is complete."
  echo ""
  echo "REMINDER: Delete the ns-must-have-gk constraint before deploying Falco:"
  echo "  kubectl delete -f ${SCRIPT_DIR}/gatekeeper/constraint.yaml"
  echo "  kubectl delete -f ${SCRIPT_DIR}/gatekeeper/ns-with-label.yaml"
  exit 0
else
  echo "Some checks failed. Review the output above and consult workshop/foundation/README.md for troubleshooting."
  exit 1
fi
