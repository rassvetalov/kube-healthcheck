# kube-healthcheck

**Kubernetes cluster health check toolkit** — operational health, CRD reconciliation, orphaned CRDs, state fingerprinting.

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![ShellCheck](https://github.com/rassvetalov/kube-healthcheck/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/rassvetalov/kube-healthcheck/actions/workflows/shellcheck.yml)

---

## Why

During a KEDA upgrade, a breaking change renamed the `type` parameter to `metricType` ([kedacore/keda#6698](https://github.com/kedacore/keda/pull/6698)). ScaledObject resources silently stopped being picked up. Pods were running, Helm showed "deployed", nodes were healthy — every standard check passed. But the application was broken.

**No existing tool catches this.** Popeye lints built-in resources. kubent/kubepug find deprecated APIs. Sonobuoy runs conformance tests. None of them inspect CRD `.status.conditions`, `observedGeneration` drift, or `status.phase` across arbitrary operators.

**kube-healthcheck** fills this gap with three zero-dependency bash scripts:

| Script | Purpose |
|--------|---------|
| `eks-healthcheck.sh` | Full cluster health check (8 sections) with universal CRD scan |
| `cluster-state.sh` | Save & compare operational state before/after changes |
| `crd-scanner.sh` | Standalone CRD health scanner (not-ready CRs + orphaned CRDs) |

## Quick Start

```bash
# Clone
git clone https://github.com/rassvetalov/kube-healthcheck.git
cd kube-healthcheck

# Run health check
./eks-healthcheck.sh

# Save state before upgrade, then compare after
./cluster-state.sh save --dir ./states
# ... perform upgrade ...
./cluster-state.sh check --dir ./states
```

## Requirements

- `kubectl` (configured with cluster access)
- `jq`
- `bash` 4+
- `helm` (optional, for Helm release checks)

---

## eks-healthcheck.sh

Full cluster health check in one command. Runs 8 sections, exits with code 1 if critical issues found.

### What it checks

| # | Section | What it catches |
|---|---------|-----------------|
| 1 | Kubernetes Versions & AMI | Kubelet vs control plane version mismatch, Karpenter AMI drift |
| 2 | Pod Health | Failed, CrashLoopBackOff, ImagePullBackOff, Pending pods |
| 3 | Node Status | NotReady nodes, MemoryPressure, DiskPressure, PIDPressure |
| 4 | DaemonSet Health | desired != ready counts |
| 5 | Helm Releases | Non-deployed releases (failed, pending-upgrade) |
| 6 | Kube-System & PVC | Unhealthy system pods, unbound PVCs |
| 7 | CRD Health | **Universal scan** of ALL CRDs — conditions, observedGeneration, phase |
| 8 | Orphaned CRDs | CRD definitions with no running controller |

**Section 7** is the key differentiator. It scans every CRD type in the cluster and detects:

- **Negative conditions**: Ready/Available/Active/Synced = False
- **Error conditions**: Error/Failed/Invalid/Degraded = True
- **observedGeneration drift**: operator stopped processing the resource
- **Bad phase**: status.phase not in a known-good set (Running, Active, Enabled, Completed, etc.)

This catches KEDA, cert-manager, Karpenter, Velero, VictoriaMetrics, Istio, Crossplane, Flux — **any operator**, no hardcoded names.

### Usage

```bash
# Basic run
./eks-healthcheck.sh

# Save report to file (ANSI-stripped for clean text)
./eks-healthcheck.sh --report-dir ./reports

# Watch mode
watch -n 60 ./eks-healthcheck.sh
```

### Example output

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EKS CLUSTER HEALTH CHECK — my-cluster — Control Plane v1.34
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[1/8] KUBERNETES VERSIONS & NODE AMI CHECK:
  --- Karpenter NodePools ---
  karpenter/default: AMI 1.34 (al2023@v20260209) ✓
    └─ 7 nodes kubelet v1.34.3-eks-70ce843 ✓
  --- Managed Node Groups ---
  addons-blue: 3 nodes kubelet v1.34.3-eks-70ce843 ✓

[2/8] POD HEALTH:
  All pods running ✓

[3/8] NODE STATUS:
  10 nodes ready ✓

[4/8] DAEMONSET HEALTH:
  14 DaemonSets healthy ✓

[5/8] HELM RELEASES:
  42 releases deployed ✓

[6/8] KUBE-SYSTEM & PVC:
  System pods: healthy ✓
  PVCs: 11 bound ✓

  Fetching 100 CRD types... done
[7/8] CRD HEALTH:
  ✗ scaledobjects.keda.sh — 1/3 unhealthy
    prod/imitator [Active=False, Fallback=False, Paused=False]

[8/8] ORPHANED CRDs:
  No orphaned CRDs detected ✓

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Result: 1 ISSUES DETECTED (30s)
  ✗ 1 unhealthy CRs across 1 types
```

### Status symbols

| Symbol | Meaning |
|--------|---------|
| ✓ | Healthy |
| ✗ | Problem detected (critical) |
| ! | Warning |
| ⊘ | No resources found (normal) |

---

## cluster-state.sh

Captures the **operational state** of a cluster (not manifests — live status, replica counts, conditions) into a JSON fingerprint. Compares two snapshots to detect regressions with severity classification.

### Why not just diff manifests?

Manifests show intent. State shows reality. After an upgrade, replicas might drop to 0, CRD conditions might flip to False, nodes might go NotReady — none of this shows in a manifest diff.

### Commands

```bash
# Save current state
./cluster-state.sh save --dir ./states

# Compare two snapshots
./cluster-state.sh compare states/before.json states/after.json

# Full check: save + compare with latest + run health check
./cluster-state.sh check --dir ./states

# List saved states
./cluster-state.sh list --dir ./states

# Cleanup old states (keep last N per cluster)
./cluster-state.sh cleanup --dir ./states --keep 10
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `--dir DIR` | Directory for state files | `./cluster_states` |
| `--keep N` | States to keep per cluster in cleanup | 30 |
| `--context CTX` | Use specific kubectl context | current |
| `-q, --quiet` | Suppress progress, only show results | off |

### Example comparison output

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CLUSTER STATE COMPARISON
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Before: my-cluster @ 2026-02-13 14:25:33
  After:  my-cluster @ 2026-02-13 15:30:00

[Nodes]
  HIGH     Ready nodes: 12 -> 11

[Pods]
  CRITICAL CrashLoop pods increased: 0 -> 3

[Workloads]
  CRITICAL deployments kube-system/karpenter: ready 2 -> 0

[Operators]
  CRITICAL KEDA ScaledObject prod/imitator: Ready=true -> false

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
4 issue(s) detected. Review CRITICAL and HIGH items above.
```

### Severity levels

| Severity | Meaning | Examples |
|----------|---------|---------|
| **CRITICAL** | Loss of functionality | Replicas -> 0, CRD Ready -> false, resource disappeared |
| **HIGH** | Degradation | Nodes NotReady, failed pods increased, Helm failed |
| **WARNING** | Deviation | Replicas decreased, resource deleted, pending pods |
| **INFO** | Expected change | Helm chart updated, new resource, HPA-managed scaling |

---

## crd-scanner.sh

Standalone CRD health scanner. The same checks are integrated into `eks-healthcheck.sh` sections 7-8, but this script is useful for targeted scans.

### Usage

```bash
# Run both checks (not-ready CRs + orphaned CRDs)
./crd-scanner.sh

# Only not-ready custom resources
./crd-scanner.sh --not-ready

# Only orphaned CRDs
./crd-scanner.sh --orphans

# Quiet mode (only show problems)
./crd-scanner.sh -q
```

---

## Upgrade Workflow

```bash
# 1. Before upgrade — save state
./cluster-state.sh save --dir ./states

# 2. Perform upgrade (EKS, Helm, operators, etc.)
# ...

# 3. After upgrade — full check (saves new state + compares + health check)
./cluster-state.sh check --dir ./states
```

For CI/CD automation:

```bash
# Exit code 0 = no regressions, 1 = issues found
./eks-healthcheck.sh || echo "HEALTH CHECK FAILED"
./cluster-state.sh compare before.json after.json || echo "REGRESSIONS FOUND"
```

---

## How it differs from other tools

| Feature | kube-healthcheck | Popeye | kubent/kubepug | Sonobuoy |
|---------|-----------------|--------|---------------|----------|
| CRD conditions scan | **All CRDs** | No | No | No |
| observedGeneration drift | **Yes** | No | No | No |
| status.phase validation | **Yes** | No | No | No |
| Orphaned CRD detection | **Yes** | No | No | No |
| Deprecated API check | No | No | **Yes** | No |
| State before/after compare | **Yes** | No | No | No |
| Resource linting | No | **Yes** | No | No |
| Conformance testing | No | No | No | **Yes** |
| Zero dependencies | **bash+kubectl+jq** | Go binary | Go binary | Go + pods |
| Execution time | ~30s | ~15s | ~5s | 1-2 hours |

**Best used together:** kubent (before upgrade) + kube-healthcheck (after upgrade) + Popeye (periodic linting).

---

## Contributing

Contributions are welcome. Please open an issue first to discuss what you'd like to change.

## License

[Apache-2.0](LICENSE)
