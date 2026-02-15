#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# EKS Cluster Health Check
# ═══════════════════════════════════════════════════════════════════
#
# USAGE:
#   ./eks-healthcheck.sh                     # Full health check
#   ./eks-healthcheck.sh --report-dir ./out  # Save report to file
#   ./eks-healthcheck.sh -h                  # Help
#
# EXIT CODES:
#   0 — no critical issues found
#   1 — critical issues detected
#
# ═══════════════════════════════════════════════════════════════════

set -uo pipefail

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[1;34m' DIM='\033[2m' N='\033[0m'
REPORT_DIR=""
EXIT_CODE=0


# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --report-dir) REPORT_DIR="$2"; shift 2;;
    -h|--help) head -16 "$0" | tail -13; exit 0;;
    *) echo "Unknown option: $1" >&2; exit 1;;
  esac
done

main() {

CP=$(kubectl version 2>/dev/null | grep "Server Version" | grep -oE 'v[0-9]+\.[0-9]+' || echo "")
[[ -z "$CP" ]] && { echo "ERROR: Cannot get Kubernetes version"; return 1; }
CP_SHORT=$(echo "$CP" | sed 's/v//')

CONTEXT=$(kubectl config current-context 2>/dev/null || echo "unknown")

# Temp directory for CRD cache
CRD_TMPDIR=$(mktemp -d)
trap 'rm -rf "$CRD_TMPDIR"' EXIT

SECONDS=0
ISSUES=()
issue() { ISSUES+=("$1"); EXIT_CODE=1; }

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "EKS CLUSTER HEALTH CHECK — $CONTEXT — Control Plane $CP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# CRD list — fetched once, instances loaded later before CRD sections
CRD_JSON=$(kubectl get crd -o json 2>/dev/null || echo '{"items":[]}')
CRD_COUNT=$(echo "$CRD_JSON" | jq '.items | length')

# ═══════════════════════════════════════════════════════════
# 1) KUBERNETES VERSIONS & NODE AMI CHECK
# ═══════════════════════════════════════════════════════════
echo "[1/11] KUBERNETES VERSIONS & NODE AMI CHECK:"

NODES_JSON=$(kubectl get nodes -o json 2>/dev/null || echo '{"items":[]}')

# --- Karpenter NodePools ---
if kubectl api-resources --api-group=karpenter.sh >/dev/null 2>&1; then
  echo "  --- Karpenter NodePools ---"
  NODEPOOLS_JSON=$(kubectl get nodepools.karpenter.sh -o json 2>/dev/null || echo '{"items":[]}')
  EC2NC_JSON=$(kubectl get ec2nodeclasses.karpenter.k8s.aws -o json 2>/dev/null || echo '{"items":[]}')

  echo "$NODEPOOLS_JSON" | jq -r '.items[].metadata.name' | while read -r pool; do
    nc_name=$(echo "$NODEPOOLS_JSON" | jq -r ".items[] | select(.metadata.name == \"$pool\") | .spec.template.spec.nodeClassRef.name")
    ami_versions=$(echo "$EC2NC_JSON" | jq -r ".items[] | select(.metadata.name == \"$nc_name\") | [.status.amis[]?.name | capture(\"(?<v>[0-9]+\\\\.[0-9]+)-v[0-9]{8}$\") | .v] | unique | .[]" 2>/dev/null)
    ami_alias=$(echo "$EC2NC_JSON" | jq -r ".items[] | select(.metadata.name == \"$nc_name\") | [.spec.amiSelectorTerms[]?.alias // empty] | first // \"custom\"" 2>/dev/null)
    node_count=$(echo "$NODES_JSON" | jq "[.items[] | select(.metadata.labels[\"karpenter.sh/nodepool\"] == \"$pool\")] | length")
    kubelet_versions=$(echo "$NODES_JSON" | jq -r ".items[] | select(.metadata.labels[\"karpenter.sh/nodepool\"] == \"$pool\") | .status.nodeInfo.kubeletVersion" 2>/dev/null | sort -u)

    if [[ -z "$ami_versions" ]]; then
      echo -e "  karpenter/$pool: AMI version unknown (EC2NodeClass $nc_name has no resolved AMIs) ${Y}!${N}"
    else
      for av in $ami_versions; do
        if [[ "$av" == "$CP_SHORT" ]]; then
          echo -e "  karpenter/$pool: AMI $av ($ami_alias) ${G}✓${N}"
        else
          echo -e "  karpenter/$pool: AMI $av ($ami_alias) — expected $CP_SHORT ${R}✗${N}"
          issue "AMI mismatch: karpenter/$pool"
        fi
      done
    fi

    if [[ "$node_count" -eq 0 ]]; then
      echo -e "    └─ 0 running nodes (pool is empty)"
    else
      for kv in $kubelet_versions; do
        kv_count=$(echo "$NODES_JSON" | jq "[.items[] | select(.metadata.labels[\"karpenter.sh/nodepool\"] == \"$pool\" and .status.nodeInfo.kubeletVersion == \"$kv\")] | length")
        kv_major=$(echo "$kv" | grep -oE 'v[0-9]+\.[0-9]+' | sed 's/v//' | head -1)
        if [[ "$kv_major" == "$CP_SHORT" ]]; then
          echo -e "    └─ $kv_count nodes kubelet $kv ${G}✓${N}"
        else
          echo -e "    └─ $kv_count nodes kubelet $kv — expected $CP_SHORT ${R}✗${N}"
          issue "Kubelet mismatch: karpenter/$pool"
        fi
      done
    fi
  done
fi

# --- Managed Node Groups ---
MNG_NODES=$(echo "$NODES_JSON" | jq -r '[.items[] | select(.metadata.labels["karpenter.sh/nodepool"] == null and .metadata.labels["eks.amazonaws.com/nodegroup"] != null)] | length')
if [[ "$MNG_NODES" -gt 0 ]]; then
  echo "  --- Managed Node Groups ---"
  echo "$NODES_JSON" | jq -r '[.items[] | select(.metadata.labels["karpenter.sh/nodepool"] == null and .metadata.labels["eks.amazonaws.com/nodegroup"] != null)] | group_by(.metadata.labels["eks.amazonaws.com/nodegroup"])[] | {ng: .[0].metadata.labels["eks.amazonaws.com/nodegroup"], versions: [.[].status.nodeInfo.kubeletVersion] | group_by(.) | map({version: .[0], count: length})} | "\(.ng)|\(.versions | map("\(.version)x\(.count)") | join(","))"' 2>/dev/null | while IFS='|' read -r ng versions; do
    IFS=',' read -ra ver_entries <<< "$versions"
    for entry in "${ver_entries[@]}"; do
      ver=$(echo "$entry" | cut -dx -f1)
      cnt=$(echo "$entry" | cut -dx -f2)
      ver_major=$(echo "$ver" | grep -oE 'v[0-9]+\.[0-9]+' | sed 's/v//' | head -1)
      if [[ "$ver_major" == "$CP_SHORT" ]]; then
        echo -e "  $ng: $cnt nodes kubelet $ver ${G}✓${N}"
      else
        echo -e "  $ng: $cnt nodes kubelet $ver — expected $CP_SHORT ${R}✗${N}"
        issue "Kubelet mismatch: MNG $ng"
      fi
    done
  done
fi

# --- Other nodes ---
OTHER_NODES=$(echo "$NODES_JSON" | jq '[.items[] | select(.metadata.labels["karpenter.sh/nodepool"] == null and .metadata.labels["eks.amazonaws.com/nodegroup"] == null)] | length')
if [[ "$OTHER_NODES" -gt 0 ]]; then
  echo "  --- Other Nodes ---"
  echo "$NODES_JSON" | jq -r '.items[] | select(.metadata.labels["karpenter.sh/nodepool"] == null and .metadata.labels["eks.amazonaws.com/nodegroup"] == null) | "\(.metadata.name)\t\(.status.nodeInfo.kubeletVersion)"' | while IFS=$'\t' read -r nname nver; do
    nver_major=$(echo "$nver" | grep -oE 'v[0-9]+\.[0-9]+' | sed 's/v//' | head -1)
    if [[ "$nver_major" == "$CP_SHORT" ]]; then
      echo -e "  $nname: $nver ${G}✓${N}"
    else
      echo -e "  $nname: $nver — expected $CP_SHORT ${R}✗${N}"
      issue "Version mismatch: node $nname"
    fi
  done
fi
echo ""

# ═══════════════════════════════════════════════════════════
# 2) POD HEALTH (single API call, checks CrashLoop + ImagePull)
# ═══════════════════════════════════════════════════════════
echo "[2/11] POD HEALTH:"

PODS_JSON=$(kubectl get pods -A -o json 2>/dev/null || echo '{"items":[]}')

FAILED=$(echo "$PODS_JSON" | jq '[.items[] | select(.status.phase == "Failed")] | length')
PENDING=$(echo "$PODS_JSON" | jq '[.items[] | select(.status.phase == "Pending")] | length')
CRASH=$(echo "$PODS_JSON" | jq '[.items[] | select(
  [(.status.containerStatuses // [])[], (.status.initContainerStatuses // [])[]]
  | any(.state.waiting.reason == "CrashLoopBackOff")
)] | length')
IMAGE_ERR=$(echo "$PODS_JSON" | jq '[.items[] | select(
  [(.status.containerStatuses // [])[], (.status.initContainerStatuses // [])[]]
  | any(.state.waiting.reason | . != null and test("ImagePull|ErrImage"))
)] | length')

POD_OK=true

if [[ "$FAILED" -gt 0 ]]; then
  echo -e "  Failed pods: $FAILED ${R}✗${N}"
  echo "$PODS_JSON" | jq -r '.items[] | select(.status.phase == "Failed") | "    \(.metadata.namespace)/\(.metadata.name)"' | head -5
  POD_OK=false; issue "$FAILED failed pods"
fi

if [[ "$CRASH" -gt 0 ]]; then
  echo -e "  CrashLoop pods: $CRASH ${R}✗${N}"
  echo "$PODS_JSON" | jq -r '.items[] | select(
    [(.status.containerStatuses // [])[], (.status.initContainerStatuses // [])[]]
    | any(.state.waiting.reason == "CrashLoopBackOff")
  ) | "    \(.metadata.namespace)/\(.metadata.name)"' | head -5
  POD_OK=false; issue "$CRASH CrashLoop pods"
fi

if [[ "$IMAGE_ERR" -gt 0 ]]; then
  echo -e "  ImagePull errors: $IMAGE_ERR ${R}✗${N}"
  echo "$PODS_JSON" | jq -r '.items[] | select(
    [(.status.containerStatuses // [])[], (.status.initContainerStatuses // [])[]]
    | any(.state.waiting.reason | . != null and test("ImagePull|ErrImage"))
  ) | "    \(.metadata.namespace)/\(.metadata.name)"' | head -5
  POD_OK=false; issue "$IMAGE_ERR ImagePull errors"
fi

if [[ "$PENDING" -gt 0 ]]; then
  echo -e "  Pending pods: $PENDING ${Y}!${N}"
  echo "$PODS_JSON" | jq -r '.items[] | select(.status.phase == "Pending") | "    \(.metadata.namespace)/\(.metadata.name)"' | head -5
  POD_OK=false
fi

# --- High restart count ---
RESTART_THRESHOLD=5
HIGH_RESTART=$(echo "$PODS_JSON" | jq --argjson t "$RESTART_THRESHOLD" '[.items[] | select(
  [(.status.containerStatuses // [])[], (.status.initContainerStatuses // [])[]]
  | any(.restartCount > $t)
)] | length')

if [[ "$HIGH_RESTART" -gt 0 ]]; then
  echo -e "  High restarts (>$RESTART_THRESHOLD): $HIGH_RESTART pods ${Y}!${N}"
  echo "$PODS_JSON" | jq -r --argjson t "$RESTART_THRESHOLD" '.items[] | select(
    [(.status.containerStatuses // [])[], (.status.initContainerStatuses // [])[]]
    | any(.restartCount > $t)
  ) | "    \(.metadata.namespace)/\(.metadata.name) (\([(.status.containerStatuses // [])[] | select(.restartCount > $t) | "\(.name)=\(.restartCount)"] | join(", ")))"' | head -5
  POD_OK=false; issue "$HIGH_RESTART pods with high restart count"
fi

# --- OOMKilled ---
OOM_KILLED=$(echo "$PODS_JSON" | jq '[.items[] | select(
  [(.status.containerStatuses // [])[], (.status.initContainerStatuses // [])[]]
  | any(.lastState.terminated.reason == "OOMKilled")
)] | length')

if [[ "$OOM_KILLED" -gt 0 ]]; then
  echo -e "  OOMKilled: $OOM_KILLED pods ${R}✗${N}"
  echo "$PODS_JSON" | jq -r '.items[] | select(
    [(.status.containerStatuses // [])[], (.status.initContainerStatuses // [])[]]
    | any(.lastState.terminated.reason == "OOMKilled")
  ) | "    \(.metadata.namespace)/\(.metadata.name)"' | head -5
  POD_OK=false; issue "$OOM_KILLED pods with OOMKilled"
fi

[[ "$POD_OK" == "true" ]] && echo -e "  All pods healthy ${G}✓${N}"
echo ""

# ═══════════════════════════════════════════════════════════
# 3) NODE STATUS (reuses NODES_JSON, adds pressure conditions)
# ═══════════════════════════════════════════════════════════
echo "[3/11] NODE STATUS:"

TOTAL_NODES=$(echo "$NODES_JSON" | jq '.items | length')
NOT_READY=$(echo "$NODES_JSON" | jq '[.items[] | select(
  .status.conditions // [] | any(.type == "Ready" and .status != "True")
)] | length')
PRESSURE=$(echo "$NODES_JSON" | jq '[.items[] | select(
  .status.conditions // [] | any((.type | test("Pressure$")) and .status == "True")
)] | length')

if [[ "$NOT_READY" -gt 0 ]]; then
  echo -e "  NotReady: $NOT_READY/$TOTAL_NODES nodes ${R}✗${N}"
  echo "$NODES_JSON" | jq -r '.items[] | select(
    .status.conditions // [] | any(.type == "Ready" and .status != "True")
  ) | "    \(.metadata.name)"' | head -5
  issue "$NOT_READY NotReady nodes"
elif [[ "$TOTAL_NODES" -gt 0 ]]; then
  echo -e "  $TOTAL_NODES nodes ready ${G}✓${N}"
fi

if [[ "$PRESSURE" -gt 0 ]]; then
  echo -e "  Pressure conditions: $PRESSURE nodes ${Y}!${N}"
  echo "$NODES_JSON" | jq -r '.items[] | select(
    .status.conditions // [] | any((.type | test("Pressure$")) and .status == "True")
  ) | "    \(.metadata.name) [\([.status.conditions[] | select((.type | test("Pressure$")) and .status == "True") | .type] | join(", "))]"' | head -5
fi
echo ""

# ═══════════════════════════════════════════════════════════
# 4) WORKLOAD HEALTH (Deployments, StatefulSets, DaemonSets)
# ═══════════════════════════════════════════════════════════
echo "[4/11] WORKLOAD HEALTH:"

# Fetch Deployments + StatefulSets (reused later in orphan detection)
WORKLOADS_JSON=$(kubectl get deployments,statefulsets -A -o json 2>/dev/null || echo '{"items":[]}')

# --- Deployments ---
DEPLOY_TOTAL=$(echo "$WORKLOADS_JSON" | jq '[.items[] | select(.kind == "Deployment")] | length')
DEPLOY_BAD=$(echo "$WORKLOADS_JSON" | jq '[.items[] | select(
  .kind == "Deployment" and (.spec.replicas // 0) != (.status.availableReplicas // 0)
)] | length')

if [[ "$DEPLOY_TOTAL" -eq 0 ]]; then
  echo -e "  Deployments: none ${Y}⊘${N}"
elif [[ "$DEPLOY_BAD" -eq 0 ]]; then
  echo -e "  Deployments: $DEPLOY_TOTAL healthy ${G}✓${N}"
else
  echo -e "  Deployments: $DEPLOY_BAD/$DEPLOY_TOTAL not fully available ${R}✗${N}"
  echo "$WORKLOADS_JSON" | jq -r '.items[] | select(
    .kind == "Deployment" and (.spec.replicas // 0) != (.status.availableReplicas // 0)
  ) | "    \(.metadata.namespace)/\(.metadata.name) (want=\(.spec.replicas // 0), available=\(.status.availableReplicas // 0))"' | head -5
  issue "$DEPLOY_BAD Deployments not fully available"
fi

# --- StatefulSets ---
STS_TOTAL=$(echo "$WORKLOADS_JSON" | jq '[.items[] | select(.kind == "StatefulSet")] | length')
STS_BAD=$(echo "$WORKLOADS_JSON" | jq '[.items[] | select(
  .kind == "StatefulSet" and (.spec.replicas // 0) != (.status.readyReplicas // 0)
)] | length')

if [[ "$STS_TOTAL" -eq 0 ]]; then
  echo -e "  StatefulSets: none ${Y}⊘${N}"
elif [[ "$STS_BAD" -eq 0 ]]; then
  echo -e "  StatefulSets: $STS_TOTAL healthy ${G}✓${N}"
else
  echo -e "  StatefulSets: $STS_BAD/$STS_TOTAL not fully ready ${R}✗${N}"
  echo "$WORKLOADS_JSON" | jq -r '.items[] | select(
    .kind == "StatefulSet" and (.spec.replicas // 0) != (.status.readyReplicas // 0)
  ) | "    \(.metadata.namespace)/\(.metadata.name) (want=\(.spec.replicas // 0), ready=\(.status.readyReplicas // 0))"' | head -5
  issue "$STS_BAD StatefulSets not fully ready"
fi

# --- DaemonSets ---
DS_JSON=$(kubectl get daemonsets -A -o json 2>/dev/null || echo '{"items":[]}')
DS_TOTAL=$(echo "$DS_JSON" | jq '.items | length')
DS_BAD=$(echo "$DS_JSON" | jq '[.items[] | select(
  .status.desiredNumberScheduled != .status.numberReady
)] | length')

if [[ "$DS_TOTAL" -eq 0 ]]; then
  echo -e "  DaemonSets: none ${Y}⊘${N}"
elif [[ "$DS_BAD" -eq 0 ]]; then
  echo -e "  DaemonSets: $DS_TOTAL healthy ${G}✓${N}"
else
  echo -e "  DaemonSets: $DS_BAD/$DS_TOTAL not fully ready ${R}✗${N}"
  echo "$DS_JSON" | jq -r '.items[] | select(.status.desiredNumberScheduled != .status.numberReady) |
    "    \(.metadata.namespace)/\(.metadata.name) (desired=\(.status.desiredNumberScheduled), ready=\(.status.numberReady // 0))"' | head -5
  issue "$DS_BAD DaemonSets not ready"
fi
echo ""

# ═══════════════════════════════════════════════════════════
# 5) HELM RELEASES
# ═══════════════════════════════════════════════════════════
echo "[5/11] HELM RELEASES:"
HELM_JSON='[]'
HELM_TOTAL=0
if command -v helm >/dev/null 2>&1; then
  HELM_JSON=$(helm list -A -o json 2>/dev/null || echo '[]')
  HELM_TOTAL=$(echo "$HELM_JSON" | jq 'length')
  if [[ "$HELM_TOTAL" -eq 0 ]]; then
    echo -e "  No Helm releases ${Y}⊘${N}"
  else
    HELM_FAILED=$(echo "$HELM_JSON" | jq '[.[] | select(.status != "deployed")] | length')
    if [[ "$HELM_FAILED" -eq 0 ]]; then
      echo -e "  $HELM_TOTAL releases deployed ${G}✓${N}"
    else
      echo -e "  $HELM_FAILED/$HELM_TOTAL releases not deployed ${R}✗${N}"
      echo "$HELM_JSON" | jq -r '.[] | select(.status != "deployed") | "    \(.namespace)/\(.name) — \(.status)"' | head -5
      issue "$HELM_FAILED Helm releases not deployed"
    fi
  fi
else
  echo -e "  Helm not installed ${Y}⊘${N}"
fi
echo ""

# ═══════════════════════════════════════════════════════════
# 6) KUBE-SYSTEM & PVC
# ═══════════════════════════════════════════════════════════
echo "[6/11] KUBE-SYSTEM & PVC:"

SYS_FAILED=$(echo "$PODS_JSON" | jq '[.items[] | select(
  .metadata.namespace == "kube-system" and
  .status.phase != "Running" and .status.phase != "Succeeded"
)] | length')

if [[ "$SYS_FAILED" -eq 0 ]]; then
  echo -e "  System pods: healthy ${G}✓${N}"
else
  echo -e "  System pods: $SYS_FAILED unhealthy ${R}✗${N}"
  echo "$PODS_JSON" | jq -r '.items[] | select(
    .metadata.namespace == "kube-system" and
    .status.phase != "Running" and .status.phase != "Succeeded"
  ) | "    \(.metadata.name) (\(.status.phase))"' | head -5
  issue "$SYS_FAILED unhealthy system pods"
fi

PVC_JSON=$(kubectl get pvc -A -o json 2>/dev/null || echo '{"items":[]}')
PV_TOTAL=$(echo "$PVC_JSON" | jq '.items | length')
PV_FAILED=$(echo "$PVC_JSON" | jq '[.items[] | select(.status.phase != "Bound")] | length')

if [[ "$PV_TOTAL" -eq 0 ]]; then
  echo -e "  PVCs: none ${Y}⊘${N}"
elif [[ "$PV_FAILED" -eq 0 ]]; then
  echo -e "  PVCs: $PV_TOTAL bound ${G}✓${N}"
else
  echo -e "  PVCs: $PV_FAILED/$PV_TOTAL unbound ${R}✗${N}"
  echo "$PVC_JSON" | jq -r '.items[] | select(.status.phase != "Bound") | "    \(.metadata.namespace)/\(.metadata.name) (\(.status.phase))"' | head -5
  issue "$PV_FAILED unbound PVCs"
fi
echo ""

# ═══════════════════════════════════════════════════════════
# 7) SERVICE ENDPOINTS
# ═══════════════════════════════════════════════════════════
echo "[7/11] SERVICE ENDPOINTS:"

# Save to temp files to avoid "argument list too long" in large clusters
kubectl get services -A -o json 2>/dev/null > "$CRD_TMPDIR/_svc.json" || echo '{"items":[]}' > "$CRD_TMPDIR/_svc.json"
kubectl get endpoints -A -o json 2>/dev/null > "$CRD_TMPDIR/_ep.json" || echo '{"items":[]}' > "$CRD_TMPDIR/_ep.json"

# Services with selectors (not headless, not ExternalName)
SVC_WITH_SEL=$(jq '[.items[] | select(
  .spec.type != "ExternalName" and
  .spec.clusterIP != "None" and
  ((.spec.selector // {}) | length) > 0
)] | length' "$CRD_TMPDIR/_svc.json")

NO_EP_LIST=$(jq -n --slurpfile svc "$CRD_TMPDIR/_svc.json" --slurpfile ep "$CRD_TMPDIR/_ep.json" '
  ($ep[0].items | map({
    key: "\(.metadata.namespace)/\(.metadata.name)",
    value: ([(.subsets // [])[] | (.addresses // [])[] ] | length)
  }) | from_entries) as $ep_map |
  [
    $svc[0].items[] | select(
      .spec.type != "ExternalName" and
      .spec.clusterIP != "None" and
      ((.spec.selector // {}) | length) > 0 and
      ($ep_map["\(.metadata.namespace)/\(.metadata.name)"] // 0) == 0
    ) | "\(.metadata.namespace)/\(.metadata.name)"
  ]')

NO_EP_COUNT=$(echo "$NO_EP_LIST" | jq 'length')

if [[ "$SVC_WITH_SEL" -eq 0 ]]; then
  echo -e "  No services with selectors ${Y}⊘${N}"
elif [[ "$NO_EP_COUNT" -eq 0 ]]; then
  echo -e "  $SVC_WITH_SEL services — all have endpoints ${G}✓${N}"
else
  echo -e "  $NO_EP_COUNT/$SVC_WITH_SEL services have no ready endpoints ${R}✗${N}"
  echo "$NO_EP_LIST" | jq -r '.[:5][] | "    \(.)"'
  issue "$NO_EP_COUNT services without endpoints"
fi
echo ""

# ═══════════════════════════════════════════════════════════
# 8) TLS CERTIFICATES
# ═══════════════════════════════════════════════════════════
echo "[8/11] TLS CERTIFICATES:"

if command -v openssl >/dev/null 2>&1; then
  TLS_WARN_DAYS=30
  kubectl get secrets -A --field-selector type=kubernetes.io/tls -o json 2>/dev/null > "$CRD_TMPDIR/_tls.json" || echo '{"items":[]}' > "$CRD_TMPDIR/_tls.json"
  TLS_COUNT=$(jq '.items | length' "$CRD_TMPDIR/_tls.json")

  if [[ "$TLS_COUNT" -eq 0 ]]; then
    echo -e "  No TLS secrets found ${Y}⊘${N}"
  else
    TLS_EXPIRED=0
    TLS_EXPIRING=0
    TLS_SHOWN=0
    NOW_EPOCH=$(date +%s)
    WARN_EPOCH=$((NOW_EPOCH + TLS_WARN_DAYS * 86400))

    while IFS=$'\t' read -r ns name cert_b64; do
      [[ -z "$cert_b64" || "$cert_b64" == "null" ]] && continue
      expiry=$(echo "$cert_b64" | base64 -d 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')
      [[ -z "$expiry" ]] && continue
      expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null)
      [[ -z "$expiry_epoch" ]] && continue

      if [[ "$expiry_epoch" -lt "$NOW_EPOCH" ]]; then
        TLS_EXPIRED=$((TLS_EXPIRED + 1))
        [[ "$TLS_SHOWN" -lt 5 ]] && echo -e "    ${R}EXPIRED${N}: $ns/$name (expired: $expiry)"
        TLS_SHOWN=$((TLS_SHOWN + 1))
      elif [[ "$expiry_epoch" -lt "$WARN_EPOCH" ]]; then
        TLS_EXPIRING=$((TLS_EXPIRING + 1))
        days_left=$(( (expiry_epoch - NOW_EPOCH) / 86400 ))
        [[ "$TLS_SHOWN" -lt 5 ]] && echo -e "    ${Y}EXPIRING${N}: $ns/$name (${days_left}d left)"
        TLS_SHOWN=$((TLS_SHOWN + 1))
      fi
    done < <(jq -r '.items[] | [.metadata.namespace, .metadata.name, (.data."tls.crt" // "")] | @tsv' "$CRD_TMPDIR/_tls.json")

    if [[ "$TLS_EXPIRED" -gt 0 ]]; then
      echo -e "  $TLS_EXPIRED expired + $TLS_EXPIRING expiring within ${TLS_WARN_DAYS}d (of $TLS_COUNT total) ${R}✗${N}"
      issue "$TLS_EXPIRED expired TLS certificates"
      [[ "$TLS_EXPIRING" -gt 0 ]] && issue "$TLS_EXPIRING TLS certs expiring within ${TLS_WARN_DAYS}d"
    elif [[ "$TLS_EXPIRING" -gt 0 ]]; then
      echo -e "  $TLS_EXPIRING expiring within ${TLS_WARN_DAYS}d (of $TLS_COUNT total) ${Y}!${N}"
      issue "$TLS_EXPIRING TLS certs expiring within ${TLS_WARN_DAYS}d"
    else
      echo -e "  $TLS_COUNT TLS certificates valid ${G}✓${N}"
    fi
  fi
else
  echo -e "  openssl not available ${Y}⊘${N}"
fi
echo ""

# ═══════════════════════════════════════════════════════════
# 9) DEPRECATED HELM APIS
# ═══════════════════════════════════════════════════════════
echo "[9/11] DEPRECATED HELM APIS:"

if command -v helm >/dev/null 2>&1 && [[ "$HELM_TOTAL" -gt 0 ]]; then
  AVAIL_APIS=$(kubectl api-versions 2>/dev/null | sort -u)

  # Fetch manifests in parallel, extract apiVersions
  HELM_API_DIR="$CRD_TMPDIR/_helm_apis"
  mkdir -p "$HELM_API_DIR"
  echo -n "  Scanning $HELM_TOTAL releases..."

  while IFS=$'\t' read -r ns name; do
    (helm get manifest "$name" -n "$ns" 2>/dev/null \
      | grep -E '^apiVersion:' | sed 's/apiVersion: *//; s/"//g; s/'\''//g' | sort -u \
      > "$HELM_API_DIR/${ns}__${name}.txt") &
    while [[ $(jobs -rp | wc -l) -ge 10 ]]; do sleep 0.1; done
  done < <(echo "$HELM_JSON" | jq -r '.[] | "\(.namespace)\t\(.name)"')
  wait
  echo " done"

  DEP_COUNT=0
  shopt -s nullglob
  for f in "$HELM_API_DIR"/*.txt; do
    [[ ! -s "$f" ]] && continue
    fname=$(basename "$f" .txt)
    ns="${fname%%__*}"
    release="${fname#*__}"

    while read -r av; do
      [[ -z "$av" ]] && continue
      if ! echo "$AVAIL_APIS" | grep -qxF "$av"; then
        DEP_COUNT=$((DEP_COUNT + 1))
        [[ "$DEP_COUNT" -le 5 ]] && echo -e "    ${R}✗${N} $ns/$release uses removed API: ${B}$av${N}"
        break
      fi
    done < "$f"
  done
  shopt -u nullglob

  if [[ "$DEP_COUNT" -eq 0 ]]; then
    echo -e "  All Helm manifests use current APIs ${G}✓${N}"
  else
    [[ "$DEP_COUNT" -gt 5 ]] && echo "    ... and $((DEP_COUNT - 5)) more"
    echo -e "  $DEP_COUNT releases with removed/unavailable APIs ${R}✗${N}"
    issue "$DEP_COUNT Helm releases with removed APIs"
  fi
else
  echo -e "  Helm not available or no releases ${Y}⊘${N}"
fi
echo ""

# ═══════════════════════════════════════════════════════════
# CRD FETCH — parallel (max 10), feeds sections 10-11
# Safe: main() runs in subshell via pipe, wait won't see tee
# ═══════════════════════════════════════════════════════════
if [[ "$CRD_COUNT" -gt 0 ]]; then
  CRD_LIST=$(echo "$CRD_JSON" | jq -r '.items[] | {
      resource: "\(.spec.names.plural).\(.spec.group)",
      plural: .spec.names.plural,
      group: .spec.group,
      hasStatus: ([.spec.versions[]? | .subresources.status != null] | any),
      scope: .spec.scope
    } | "\(.resource)\t\(.plural)\t\(.group)\t\(.hasStatus)\t\(.scope)"')

  echo -n "  Fetching $CRD_COUNT CRD types..."
  while IFS=$'\t' read -r resource plural group hasStatus scope; do
    outfile="$CRD_TMPDIR/${plural}.${group}.json"
    echo -e "${hasStatus}\t${group}\t${plural}\t${resource}" > "$CRD_TMPDIR/${plural}.${group}.meta"
    (kubectl get "$resource" -A -o json 2>/dev/null > "$outfile" || echo '{"items":[]}' > "$outfile") &
    while [[ $(jobs -rp | wc -l) -ge 10 ]]; do sleep 0.1; done
  done <<< "$CRD_LIST"
  wait
  echo " done"
fi

# ═══════════════════════════════════════════════════════════
# 10) CRD HEALTH — universal scan, no hardcoded operators
# ═══════════════════════════════════════════════════════════
echo "[10/11] CRD HEALTH:"

# "Good" phases — everything else is a problem
GOOD_PHASES="Running|Active|Enabled|Bound|Completed|Succeeded|Ready|Available|Operational|Healthy"

NOT_READY_TOTAL=0
CRD_ISSUES=0

for meta_file in "$CRD_TMPDIR"/*.meta; do
  IFS=$'\t' read -r hasStatus group plural resource < "$meta_file"
  json_file="$CRD_TMPDIR/${plural}.${group}.json"
  [[ ! -f "$json_file" ]] && continue

  total=$(jq '.items | length' "$json_file")
  [[ "$total" -eq 0 ]] && continue

  # Universal health check: conditions + observedGeneration + phase
  count=$(jq --arg gp "$GOOD_PHASES" '[.items[] | select(
    # 1. Negative conditions: Ready/Available/Synced/etc = False
    (.status.conditions // [] | any(
      (.type | test("^(Ready|Available|Active|Synced|Established|Programmed)$"; "i")) and .status == "False"
    ))
    or
    # 2. Error conditions: Error/Failed/Degraded/Invalid = True
    (.status.conditions // [] | any(
      (.type | test("Error|Failed|Invalid|Degraded"; "i")) and .status == "True"
    ))
    or
    # 3. observedGeneration drift (top-level)
    (.metadata.generation != null and .status.observedGeneration != null and
     .metadata.generation != .status.observedGeneration)
    or
    # 4. observedGeneration drift (in conditions)
    (.metadata.generation as $gen |
      .status.conditions // [] | any(.observedGeneration != null and .observedGeneration != $gen))
    or
    # 5. Bad phase (if present and not in known-good set)
    (.status.phase != null and (.status.phase | test("^(\($gp))$"; "i") | not))
  )] | length' "$json_file")
  [[ "$count" -eq 0 ]] && continue

  NOT_READY_TOTAL=$((NOT_READY_TOTAL + count))
  CRD_ISSUES=$((CRD_ISSUES + 1))

  # Build detail line for each unhealthy item
  echo -e "  ${R}✗${N} ${B}${resource}${N} — $count/$total unhealthy"
  jq -r --arg gp "$GOOD_PHASES" '.items[] | select(
    (.status.conditions // [] | any(
      (.type | test("^(Ready|Available|Active|Synced|Established|Programmed)$"; "i")) and .status == "False"
    )) or
    (.status.conditions // [] | any(
      (.type | test("Error|Failed|Invalid|Degraded"; "i")) and .status == "True"
    )) or
    (.metadata.generation != null and .status.observedGeneration != null and
     .metadata.generation != .status.observedGeneration) or
    (.metadata.generation as $gen |
      .status.conditions // [] | any(.observedGeneration != null and .observedGeneration != $gen)) or
    (.status.phase != null and (.status.phase | test("^(\($gp))$"; "i") | not))
  ) | "    \(.metadata.namespace // "-")/\(.metadata.name)"
    + (if .status.phase != null then " [phase=\(.status.phase)]" else "" end)
    + (if (.metadata.generation != null and .status.observedGeneration != null and .metadata.generation != .status.observedGeneration) then " [gen=\(.metadata.generation)/obs=\(.status.observedGeneration)]" else "" end)
    + (if (.status.conditions // [] | any(.status == "False" or ((.type | test("Error|Failed|Invalid|Degraded"; "i")) and .status == "True")))
       then " [\([.status.conditions // [] | .[] | select(.status == "False" or ((.type | test("Error|Failed|Invalid|Degraded"; "i")) and .status == "True")) | "\(.type)=\(.status)"] | join(", "))]"
       else "" end)
  ' "$json_file" 2>/dev/null | head -5
done

if [[ "$NOT_READY_TOTAL" -eq 0 ]]; then
  echo -e "  All CRDs healthy ($CRD_COUNT types scanned) ${G}✓${N}"
else
  echo -e "  Total: ${R}$NOT_READY_TOTAL${N} unhealthy CRs across $CRD_ISSUES CRD types"
  issue "$NOT_READY_TOTAL unhealthy CRs across $CRD_ISSUES types"
fi
echo ""

# ═══════════════════════════════════════════════════════════
# 11) ORPHANED CRDs (reuses WORKLOADS_JSON from section 4)
# ═══════════════════════════════════════════════════════════
echo "[11/11] ORPHANED CRDs:"

ALL_CONTROLLERS=$(echo "$WORKLOADS_JSON" | jq -r '[.items[] | {
  ns: .metadata.namespace, name: .metadata.name,
  ready: (.status.readyReplicas // 0),
  nameNorm: (.metadata.name | ascii_downcase | gsub("-";"")),
  labelVals: [(.metadata.labels // {} | to_entries[].value | ascii_downcase | gsub("-";""))]
}]')

# Cache controller lookups per API group
declare -A _CTRL_CACHE
has_running_controller() {
  local group="$1"
  if [[ -v _CTRL_CACHE["$group"] ]]; then
    return "${_CTRL_CACHE[$group]}"
  fi

  local stripped
  stripped=$(echo "$group" | sed 's/\.io$//; s/\.sh$//; s/\.com$//; s/\.aws$//; s/\.k8s$//')
  local keywords
  keywords=$(echo "$stripped" | tr '.' '\n' | while read -r part; do echo "$part" | tr -d '-'; done | sort -u)

  for kw in $keywords; do
    [[ ${#kw} -lt 4 ]] && continue
    local match
    match=$(echo "$ALL_CONTROLLERS" | jq --arg kw "$kw" '[.[] | select(
      .ready > 0 and ((.nameNorm | contains($kw)) or (.labelVals[] | contains($kw)))
    )] | length')
    if [[ "$match" -gt 0 ]]; then
      _CTRL_CACHE["$group"]=0
      return 0
    fi
  done
  _CTRL_CACHE["$group"]=1
  return 1
}

ORPHAN_COUNT=0

for meta_file in "$CRD_TMPDIR"/*.meta; do
  IFS=$'\t' read -r hasStatus group plural resource < "$meta_file"
  json_file="$CRD_TMPDIR/${plural}.${group}.json"
  [[ ! -f "$json_file" ]] && continue
  [[ "$hasStatus" != "true" ]] && continue

  # Skip system CRDs (managed by EKS/Kubernetes itself)
  [[ "$group" == *.k8s.io || "$group" == *.k8s.aws ]] && continue

  total=$(jq '.items | length' "$json_file")

  # Check 0: 0 instances + no controller → leftover CRD
  if [[ "$total" -eq 0 ]]; then
    if ! has_running_controller "$group"; then
      orphan_group_file="$CRD_TMPDIR/_orphan_groups_${group//[^a-zA-Z0-9]/_}"
      echo "$resource" >> "$orphan_group_file"
    fi
    continue
  fi

  # Check 1: ALL instances have empty status + no controller
  empty_status=$(jq '[.items[] | select(
    (.status == null) or (.status == {}) or ((.status | keys | length) == 0)
  )] | length' "$json_file")

  if [[ "$empty_status" -eq "$total" ]]; then
    if ! has_running_controller "$group"; then
      ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
      echo -e "  ${R}✗${N} ${B}${resource}${N} — $total instances, ALL with empty status, no controller"
      jq -r '.items[:5][] | "    \(.metadata.namespace // "-")/\(.metadata.name) (age: \(.metadata.creationTimestamp))"' "$json_file"
      echo -e "    ${DIM}# Remove only if confirmed unused: kubectl delete $resource -A --all && kubectl delete crd $resource${N}"
      echo ""
    fi
    continue
  fi

  # Check 2: observedGeneration stuck
  has_obs_gen=$(jq '[.items[] | select(.status.observedGeneration != null)] | length' "$json_file")
  if [[ "$has_obs_gen" -gt 0 ]]; then
    stuck=$(jq '[.items[] | select(
      .metadata.generation != null and .metadata.generation > 1 and
      (.status.observedGeneration == null or .status.observedGeneration == 0)
    )] | length' "$json_file")
    if [[ "$stuck" -gt 0 ]]; then
      ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
      echo -e "  ${Y}!${N} ${B}${resource}${N} — $stuck/$total instances with stale observedGeneration"
      jq -r '.items[] | select(.metadata.generation > 1 and (.status.observedGeneration == null or .status.observedGeneration == 0)) |
        "    \(.metadata.namespace // "-")/\(.metadata.name) (gen=\(.metadata.generation), obsGen=\(.status.observedGeneration // "null"))"' "$json_file" | head -5
      echo -e "    ${DIM}# Remove only if confirmed unused: kubectl delete $resource -A --all && kubectl delete crd $resource${N}"
      echo ""
    fi
  fi

  # Check 3: conditions exist but no controller
  has_conditions=$(jq '[.items[] | select((.status.conditions // []) | length > 0)] | length' "$json_file")
  if [[ "$has_conditions" -gt 0 ]]; then
    if ! has_running_controller "$group"; then
      ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
      echo -e "  ${Y}!${N} ${B}${resource}${N} — $total instances, no running controller for ${DIM}$group${N}"
      jq -r '.items[:3][] | "    \(.metadata.namespace // "-")/\(.metadata.name)"' "$json_file"
      echo -e "    ${DIM}# Remove only if confirmed unused: kubectl delete $resource -A --all && kubectl delete crd $resource${N}"
      echo ""
    fi
  fi
done

# Report orphaned CRD groups (0 instances, no controller)
shopt -s nullglob
for gfile in "$CRD_TMPDIR"/_orphan_groups_*; do
  crds_in_group=$(sort -u "$gfile")
  crd_count=$(echo "$crds_in_group" | wc -l)
  first_crd=$(echo "$crds_in_group" | head -1)
  group_name=$(echo "$first_crd" | sed 's/^[^.]*\.//')

  ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
  echo -e "  ${Y}!${N} ${B}${group_name}${N} — $crd_count orphaned CRD definitions, 0 instances, no controller"
  echo "$crds_in_group" | head -5 | while read -r c; do echo "    $c"; done
  [[ "$crd_count" -gt 5 ]] && echo "    ... and $((crd_count - 5)) more"
  # Generate delete command for all CRDs in group
  delete_list=$(echo "$crds_in_group" | tr '\n' ' ')
  echo -e "    ${DIM}# Remove only if confirmed unused: kubectl delete crd ${delete_list}${N}"
  echo ""
done
shopt -u nullglob

if [[ "$ORPHAN_COUNT" -eq 0 ]]; then
  echo -e "  No orphaned CRDs detected ${G}✓${N}"
else
  echo -e "  Total: ${R}$ORPHAN_COUNT${N} potentially orphaned CRD types"
fi
echo ""

# ═══════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ "${#ISSUES[@]}" -eq 0 ]]; then
  echo -e "Result: ${G}HEALTHY${N} — no issues found (${SECONDS}s)"
else
  echo -e "Result: ${R}${#ISSUES[@]} ISSUES DETECTED${N} (${SECONDS}s)"
  for i in "${ISSUES[@]}"; do
    echo -e "  ${R}✗${N} $i"
  done
fi

return "$EXIT_CODE"
}

# ═══════════════════════════════════════════════════════════
# RUN
# ═══════════════════════════════════════════════════════════
if [[ -n "$REPORT_DIR" ]]; then
  mkdir -p "$REPORT_DIR"
  CONTEXT=$(kubectl config current-context 2>/dev/null || echo "unknown")
  REPORT_FILE="$REPORT_DIR/health_${CONTEXT}_$(date +%Y%m%d_%H%M%S).txt"
  main 2>&1 | tee >(sed 's/\x1b\[[0-9;]*m//g' > "$REPORT_FILE")
  rc=${PIPESTATUS[0]}
  echo ""
  echo "Report saved: $REPORT_FILE" >&2
  exit "$rc"
else
  main
  exit $?
fi
