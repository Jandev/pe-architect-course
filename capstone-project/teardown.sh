#!/usr/bin/env bash
# Capstone Project — Full Teardown
# Removes every resource created by deploy.sh in reverse dependency order.
# Safe to run multiple times (idempotent).
#
# Order rationale:
#   1. Gatekeeper constraints/templates first — admission webhook cannot block DELETE ops
#   2. All RBAC next — service accounts lose write access before workloads are touched
#   3. Teams Operator stopped — prevents the controller from reconciling while we delete
#   4. Workloads and namespaces
#   5. Cluster infrastructure (Argo Rollouts, Keycloak, Kubescape, Falco, Grafana, …)
#   6. OPA Gatekeeper last — the webhook itself, after everything it governed is gone

set -uo pipefail   # catch unbound vars and pipe failures; individual step failures do NOT abort

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Capstone Project Teardown ==="
echo ""
echo "This will remove ALL resources deployed by deploy.sh:"
echo "  • Argo Rollout, Services, and Ingress for rollout-demo-api (production)"
echo "  • Rollouts and Services deployed per-team via the Teams API"
echo "  • All Gatekeeper constraints and constraint templates"
echo "  • IDP RBAC (Roles, RoleBindings, ClusterRoles, ClusterRoleBindings)"
echo "  • Teams Operator (ns: engineering-platform)"
echo "  • Teams API       (ns: teams-api)"
echo "  • Teams UI        (ns: teams-ui)"
echo "  • Team namespaces (label: app.kubernetes.io/managed-by=teams-operator)"
echo "  • Production namespace"
echo "  • Argo Rollouts controller (ns: argo-rollouts)"
echo "  • Keycloak        (ns: keycloak)"
echo "  • Kubescape       (ns: kubescape)"
echo "  • Falco           (ns: falco-system)"
echo "  • Grafana / kube-prometheus-stack (ns: monitoring)"
echo "  • Ingress-Nginx   (ns: ingress-nginx)"
echo "  • Metrics Server  (ns: kube-system)"
echo "  • OPA Gatekeeper  (ns: gatekeeper-system)"
echo "  • Local ./tli binary"
echo ""
echo "Press Ctrl+C within 10 seconds to cancel..."
sleep 10
echo ""

# ── Pre-flight: cluster must be reachable ─────────────────────────────────────
if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: kubectl cannot reach the cluster. Aborting."
  exit 1
fi

# Collect team namespaces now, before we start deleting things.
TEAM_NAMESPACES=$(kubectl get namespaces \
  -l app.kubernetes.io/managed-by=teams-operator \
  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

# ─── 1. Gatekeeper constraints ────────────────────────────────────────────────
# Remove first so the admission webhook cannot block any subsequent DELETE operation.
# Constraints must be deleted before their ConstraintTemplates.
# If Gatekeeper CRDs are already gone this section is a no-op.
echo "[1/19] Removing Gatekeeper constraints..."
kubectl delete requireidporigin require-idp-origin \
  --ignore-not-found 2>/dev/null || true
kubectl delete requireargorollouts require-argo-rollouts-in-production \
  --ignore-not-found 2>/dev/null || true
kubectl delete falcorootprevention enforce-falco-root-prevention \
  --ignore-not-found 2>/dev/null || true
kubectl delete codecoveragesimple enforce-code-coverage-simple \
  --ignore-not-found 2>/dev/null || true
kubectl delete vulnerabilityscan enforce-vulnerability-scanning \
  --ignore-not-found 2>/dev/null || true
kubectl delete k8srequiredlabels ns-must-have-gk \
  --ignore-not-found 2>/dev/null || true
echo ""

# ─── 2. Gatekeeper constraint templates ───────────────────────────────────────
echo "[2/19] Removing Gatekeeper constraint templates..."
kubectl delete constrainttemplate requireidporigin --ignore-not-found
kubectl delete constrainttemplate requireargorollouts --ignore-not-found
kubectl delete constrainttemplate falcorootprevention --ignore-not-found
kubectl delete constrainttemplate codecoveragesimple --ignore-not-found
kubectl delete constrainttemplate vulnerabilityscan --ignore-not-found
kubectl delete constrainttemplate k8srequiredlabels --ignore-not-found
echo ""

# ─── 3. RBAC ──────────────────────────────────────────────────────────────────
# Revoking write access from all service accounts before workloads are removed
# prevents the Teams Operator (still terminating) from recreating namespaces.
echo "[3/19] Removing RBAC..."
# Teams Operator cluster-scoped RBAC
kubectl delete clusterrolebinding teams-operator --ignore-not-found
kubectl delete clusterrole teams-operator --ignore-not-found
# Teams API cluster-scoped RBAC
kubectl delete clusterrolebinding teams-api --ignore-not-found
kubectl delete clusterrole teams-api --ignore-not-found
# IDP cluster-scoped RBAC
kubectl delete clusterrolebinding idp-namespace-creator-binding --ignore-not-found
kubectl delete clusterrole idp-namespace-creator --ignore-not-found
# IDP production-namespace RBAC
kubectl delete rolebinding idp-creator-binding -n production --ignore-not-found
kubectl delete role idp-creator -n production --ignore-not-found
# IDP per-team namespace RBAC (cascade-deleted with the namespace; explicit for clarity)
for ns in $TEAM_NAMESPACES; do
  kubectl delete rolebinding idp-creator-binding -n "$ns" --ignore-not-found
  kubectl delete role idp-creator -n "$ns" --ignore-not-found
done
echo ""

# ─── 4. Teams Operator ────────────────────────────────────────────────────────
# Stop the controller before deleting team namespaces so it cannot recreate them.
echo "[4/19] Stopping Teams Operator..."
kubectl delete deployment teams-operator -n engineering-platform --ignore-not-found
echo ""

# ─── 5. rollout-demo-api (in production namespace) ────────────────────────────
echo "[5/19] Removing rollout-demo-api..."
kubectl delete rollout rollout-demo-api -n production --ignore-not-found
kubectl delete ingress rollout-demo-api-ingress -n production --ignore-not-found
kubectl delete service rollout-demo-api-active rollout-demo-api-preview \
  -n production --ignore-not-found
echo ""

# ─── 6. Team-deployed Rollouts and Services ───────────────────────────────────
echo "[6/19] Removing team-deployed Rollouts and Services in team namespaces..."
for ns in $TEAM_NAMESPACES; do
  echo "  Cleaning up namespace: $ns"
  kubectl delete rollouts --all -n "$ns" --ignore-not-found
  kubectl delete services --all -n "$ns" --ignore-not-found
done
echo ""

# ─── 7. Team namespaces ───────────────────────────────────────────────────────
# Cascade-deletes all remaining namespaced resources (including per-namespace RBAC).
echo "[7/19] Removing team namespaces..."
for ns in $TEAM_NAMESPACES; do
  echo "  Deleting namespace: $ns"
  kubectl delete namespace "$ns" --ignore-not-found
done
echo ""

# ─── 8. Production namespace ──────────────────────────────────────────────────
echo "[8/19] Removing production namespace..."
kubectl delete namespace production --ignore-not-found
echo ""

# ─── 9. engineering-platform namespace ────────────────────────────────────────
echo "[9/19] Removing engineering-platform namespace (Teams Operator)..."
kubectl delete namespace engineering-platform --ignore-not-found
echo ""

# ─── 10. teams-api namespace ──────────────────────────────────────────────────
echo "[10/19] Removing teams-api namespace..."
kubectl delete namespace teams-api --ignore-not-found
echo ""

# ─── 11. teams-ui namespace ───────────────────────────────────────────────────
echo "[11/19] Removing teams-ui namespace..."
kubectl delete namespace teams-ui --ignore-not-found
echo ""

# ─── 12. Argo Rollouts ────────────────────────────────────────────────────────
echo "[12/19] Removing Argo Rollouts controller..."
# Deleting the namespace cascades all Argo Rollout CRD instances and controller pods.
kubectl delete namespace argo-rollouts --ignore-not-found
# Remove the Argo Rollout CRDs so they don't linger in other namespaces.
kubectl delete crd \
  rollouts.argoproj.io \
  analysisruns.argoproj.io \
  analysistemplates.argoproj.io \
  clusteranalysistemplates.argoproj.io \
  experiments.argoproj.io \
  --ignore-not-found
echo ""

# ─── 13. Keycloak ─────────────────────────────────────────────────────────────
echo "[13/19] Removing Keycloak..."
kubectl delete namespace keycloak --ignore-not-found
echo ""

# ─── 14. Kubescape ────────────────────────────────────────────────────────────
echo "[14/19] Removing Kubescape..."
helm uninstall kubescape -n kubescape 2>/dev/null || true
kubectl delete namespace kubescape --ignore-not-found
echo ""

# ─── 15. Falco ────────────────────────────────────────────────────────────────
echo "[15/19] Removing Falco..."
helm uninstall falco -n falco-system 2>/dev/null || true
kubectl delete namespace falco-system --ignore-not-found
echo ""

# ─── 16. Grafana / kube-prometheus-stack ──────────────────────────────────────
echo "[16/19] Removing Grafana stack (kube-prometheus-stack)..."
helm uninstall grafana-stack -n monitoring 2>/dev/null || true
# kube-prometheus-stack intentionally does NOT remove its CRDs on uninstall.
kubectl delete crd \
  alertmanagerconfigs.monitoring.coreos.com \
  alertmanagers.monitoring.coreos.com \
  podmonitors.monitoring.coreos.com \
  probes.monitoring.coreos.com \
  prometheusagents.monitoring.coreos.com \
  prometheuses.monitoring.coreos.com \
  prometheusrules.monitoring.coreos.com \
  scrapeconfigs.monitoring.coreos.com \
  servicemonitors.monitoring.coreos.com \
  thanosrulers.monitoring.coreos.com \
  --ignore-not-found
kubectl delete namespace monitoring --ignore-not-found
echo ""

# ─── 17. Ingress-Nginx ────────────────────────────────────────────────────────
echo "[17/19] Removing Ingress-Nginx..."
helm uninstall ingress-nginx -n ingress-nginx 2>/dev/null || true
kubectl delete namespace ingress-nginx --ignore-not-found
echo ""

# ─── 18. Metrics Server ───────────────────────────────────────────────────────
echo "[18/19] Removing Metrics Server..."
helm uninstall metrics-server -n kube-system 2>/dev/null || true
echo ""

# ─── 19. OPA Gatekeeper ───────────────────────────────────────────────────────
# Removed last: it is the admission webhook itself.
# By this point all constrained namespaces are gone so the webhook has nothing to intercept.
echo "[19/19] Removing OPA Gatekeeper..."
kubectl delete -f \
  https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.14/deploy/gatekeeper.yaml \
  --ignore-not-found 2>/dev/null || true
kubectl delete namespace gatekeeper-system --ignore-not-found
echo ""

# ─── Local Teams CLI binary ───────────────────────────────────────────────────
echo "[+] Removing local Teams CLI binary..."
rm -f "${SCRIPT_DIR}/tli"
echo ""

# ─── Summary ─────────────────────────────────────────────────────────────────
echo "=== Teardown complete (19/19 steps) ==="
echo ""
echo "Verify cleanup:"
echo "  kubectl get namespaces"
echo "  kubectl get constrainttemplates 2>/dev/null || echo 'Gatekeeper CRDs removed'"
echo "  kubectl get clusterroles   | grep -E 'idp-|teams-' || echo 'No IDP/teams ClusterRoles remain'"
echo "  kubectl get clusterrolebindings | grep -E 'idp-|teams-' || echo 'No IDP/teams ClusterRoleBindings remain'"
echo "  helm list -A"
