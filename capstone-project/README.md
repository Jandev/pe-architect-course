# Capstone Project: Platform Security

A layered security platform built on OPA Gatekeeper, Falco, and Kubescape.

## Security Architecture

| Layer             | Tool           | Mechanism                                           |
| ----------------- | -------------- | --------------------------------------------------- |
| Admission control | OPA Gatekeeper | Blocks non-compliant workloads at deploy time       |
| Runtime detection | Falco          | Detects anomalous syscall activity at runtime       |
| Compliance audit  | Kubescape      | API-based scanning against NSA/MITRE/CIS frameworks |

### OPA Gatekeeper

Four constraint policies are enforced:

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

`deploy.sh` auto-detects OrbStack and skips Falco on that environment.

## Verification

```bash
./verify.sh
```

Falco checks are automatically skipped on OrbStack with a `[SKIP]` message.
