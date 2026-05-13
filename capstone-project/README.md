# Capstone Project: Internal Developer Platform

A Kubernetes-based Internal Developer Platform combining team management, identity, observability, and layered security.

## Platform Architecture

| Layer             | Tool(s)              | Mechanism                                                     |
| ----------------- | -------------------- | ------------------------------------------------------------- |
| Identity          | Keycloak             | OIDC/SSO for Teams UI; realm pre-seeded with users and client |
| Teams management  | Teams API + Teams UI | REST API + Angular SPA for creating and listing teams         |
| Namespace control | Teams Operator       | Kubernetes operator that provisions namespaces per team       |
| Ingress           | Ingress-NGINX        | Routes traffic to all platform services                       |
| Observability     | Grafana / Prometheus | Metrics, dashboards, and alerting                             |
| Admission control | OPA Gatekeeper       | Blocks non-compliant workloads at deploy time                 |
| Runtime detection | Falco                | Detects anomalous syscall activity at runtime                 |
| Compliance audit  | Kubescape            | API-based scanning against NSA/MITRE/CIS frameworks           |

## Application Layer

### Keycloak (SSO / Identity Provider)

Deployed in the `keycloak` namespace backed by a Postgres 15 database.
Exposed at `http://platform-auth.127.0.0.1.sslip.io:30080` via Ingress-NGINX.

The `teams` realm is imported on startup and pre-configured with:

- **Client `teams-ui`** — public OIDC client with redirect URIs for Teams UI
- **User `teamlead1`** — password `teamlead1`, role `team-leader`
- **User `admin`** — password `admin123`, roles `admin` + `team-leader`

### Teams UI (Angular SPA)

Deployed in the `teams-ui` namespace. Exposed at `http://teams-ui.127.0.0.1.sslip.io:30080`.

- Authenticates via Keycloak OIDC (silent SSO check, auth guard on all routes)
- Displays the list of teams fetched from the Teams API
- Allows authenticated users to create new teams via a form
- Bearer token injected into every API request by an HTTP interceptor
- Built as a Docker image inside the cluster using the `app/deploy.sh` helper; served by nginx

### Teams API (FastAPI)

Deployed in the `teams-api` namespace. Exposed at `http://teams-api.127.0.0.1.sslip.io:30080`.

- **RBAC**: a `ServiceAccount` + `ClusterRole` + `ClusterRoleBinding` allow the pod to query the Kubernetes API. The ClusterRole grants: get/list on `namespaces`; get/list/create/update/patch on `services`; get/list/create/update/patch on `argoproj.io/rollouts`; get/update/patch on `argoproj.io/rollouts/status` (needed by the promote endpoint, which mirrors `kubectl argo rollouts promote`)
- **Startup seeding**: on startup the API lists all namespaces labelled `app.kubernetes.io/managed-by=teams-operator` and populates the in-memory store from their labels and annotations (`teams.example.com/team-id`, `teams.example.com/original-team-name`, `teams.example.com/created-at`). This ensures state survives pod restarts.
- Requires `kubernetes==28.1.0` (added to `requirements.txt`)

### Teams Operator (Kubernetes Operator)

Deployed in the `engineering-platform` namespace. Polls the Teams API every 30 seconds and reconciles team namespaces.

- **Startup seeding**: on startup the operator lists all namespaces labelled `app.kubernetes.io/managed-by=teams-operator` and pre-populates `known_teams` / `team_namespaces`. This prevents spurious re-creation attempts on the first reconciliation loop after a restart.
- **RBAC**: `ClusterRole` with get/list/create/update/patch/delete on namespaces, bound to the `teams-operator` ServiceAccount
- **Security context**: runs as UID 1001 (non-root), read-only root filesystem, all capabilities dropped, `seccompProfile: RuntimeDefault`
- **Gatekeeper**: registered in the `CodeCoverageSimple` constraint (`commit-sha: "af2100f"` → 85% coverage, ≥80% required)

## Security Layer

### OPA Gatekeeper

Four constraint policies are enforced across all namespaces (including `teams-ui` and `engineering-platform`):

- **`K8sRequiredLabels`** — every namespace must carry `admission: "true"`
- **`VulnerabilityScan`** — rejects images with critical CVEs above threshold
- **`CodeCoverageSimple`** — rejects deployments whose commit has test coverage below 80%
- **`FalcoRootPrevention`** — rejects containers running as UID 0 or with `privileged: true`

### Falco

Deployed as a DaemonSet in the `falco-system` namespace using the `modern_ebpf` driver.
Custom rules (`falco/custom_rules.yaml`) add two detections:

- **Container Running as Root** (WARNING) — any container process executing as UID 0
- **Root Process in User Namespace** (CRITICAL) — privilege escalation via user namespace

> **Note for OrbStack users:** Falco cannot run on OrbStack's ARM64 kernel
> (`6.19.x-orbstack-*`). The BPF verifier rejects the `modern_ebpf` driver because
> the `recvmmsg_x` tail-call program compiles to 1,000,001 instructions, exceeding the
> kernel's 1,000,000-instruction limit. The `ebpf` and `kmod` drivers also fail because
> OrbStack does not expose kernel headers at `/lib/modules/*/build`.
>
> `deploy.sh` detects OrbStack automatically and skips the Falco step. Falco deploys
> correctly in the Coder / production environment where a standard Linux kernel is used.

### Kubescape

Deployed as a Helm operator in the `kubescape` namespace. Does **not** require a kernel
driver — all scanning is API-based. Capabilities enabled:

- `configurationScan` — checks workload YAML against NSA hardening guidance
- `continuousScan` — re-evaluates on every resource change
- `vulnerabilityScan` — scans container images for CVEs

`runtimeDetection` is disabled because it also requires eBPF (same OrbStack limitation).

## Deployment

```bash
./deploy.sh
```

The script runs 32 steps end-to-end:

| Steps | What is deployed                                                     |
| ----- | -------------------------------------------------------------------- |
| 1     | Add Helm repositories                                                |
| 2     | Ingress-NGINX                                                        |
| 3     | Grafana / kube-prometheus-stack                                      |
| 4     | OPA Gatekeeper                                                       |
| 5–7   | Gatekeeper constraints (namespace labels, CVE, code coverage)        |
| 8     | Falco (skipped on OrbStack)                                          |
| 9     | Kubescape                                                            |
| 10    | Gatekeeper secops constraint (root prevention)                       |
| 11    | Metrics Server                                                       |
| 12–13 | Keycloak (Postgres + Keycloak rollout)                               |
| 14    | Teams CLI (build + install as `./tli`)                               |
| 15–18 | Teams API (image build, kind load, deploy, rollout wait)             |
| 19–21 | Teams UI (image build, kind load, deploy)                            |
| 22–24 | Teams Operator (image build, kind load, deploy)                      |
| 25    | Argo Rollouts controller + kubectl plugin                            |
| 26    | Production namespace + RequireArgoRollouts constraint                |
| 27    | RequireIDPOrigin RBAC (ClusterRole + Role in production)             |
| 28    | RequireIDPOrigin constraint template + constraint                    |
| 29–31 | rollout-demo-api images (build v1+v2, push to Docker Hub, kind load) |
| 32    | Deploy rollout-demo-api via Argo Rollouts (blue/green, paused)       |

`deploy.sh` auto-detects OrbStack and skips Falco and the `kind load` steps on that environment.

## Verification

```bash
./verify.sh
```

`verify.sh` validates every layer in order: Ingress-NGINX → Grafana → Gatekeeper constraints → Falco → Kubescape → Keycloak → Teams API → Teams UI → Teams Operator.

The Teams Operator smoke test POSTs a team via the API, waits up to 40 s for the operator to create the namespace, asserts the `admission`, `created-by`, and `created-at` labels/annotations, then tears down by DELETEing the team and waiting for the namespace to be removed.

Falco checks are automatically skipped on OrbStack with a `[SKIP]` message.

## Service URLs

| Service      | URL                                           | Credentials      |
| ------------ | --------------------------------------------- | ---------------- |
| Grafana      | http://grafana.127.0.0.1.sslip.io:30080       | admin / admin123 |
| Prometheus   | http://prometheus.127.0.0.1.sslip.io:30080    |                  |
| AlertManager | http://alertmanager.127.0.0.1.sslip.io:30080  |                  |
| Keycloak     | http://platform-auth.127.0.0.1.sslip.io:30080 | admin / admin123 |
| Teams API    | http://teams-api.127.0.0.1.sslip.io:30080     |                  |
| Teams UI     | http://teams-ui.127.0.0.1.sslip.io:30080      | admin / admin123 |

## Teardown

```bash
./teardown.sh
```

Removes every resource deployed by `deploy.sh` in the safe reverse order: Gatekeeper
policies are revoked first (so the admission webhook cannot block deletions), then all
RBAC is stripped (so service accounts lose write access while workloads are still
running), then the Teams Operator is stopped, then workloads and namespaces are deleted,
and finally the cluster infrastructure (Argo Rollouts, Keycloak, Kubescape, Falco,
Grafana, Ingress-NGINX, Metrics Server, OPA Gatekeeper) is uninstalled.
