#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Cluster State Fingerprint — save, compare & check
# Captures operational state (not manifests) and detects regressions
# ═══════════════════════════════════════════════════════════════════
#
# USAGE EXAMPLES:
#
#   # Save cluster state before making changes
#   ./cluster-state.sh save
#   ./cluster-state.sh save --dir ./states
#
#   # Make changes (upgrade, deploy, config change, etc.)
#   # ...
#
#   # Save state after changes
#   ./cluster-state.sh save --dir ./states
#
#   # Compare two snapshots
#   ./cluster-state.sh compare states/my-cluster_20260213_140000.json states/my-cluster_20260213_153000.json
#
#   # Full check: save new state + compare with latest + health check
#   ./cluster-state.sh check --dir ./states
#
#   # List saved states for current cluster
#   ./cluster-state.sh list --dir ./states
#
#   # Cleanup old states (keep last N per cluster, default 30)
#   ./cluster-state.sh cleanup --dir ./states --keep 10
#
# OPTIONS:
#   --dir DIR     Directory for state files (default: ./cluster_states)
#   --keep N      Number of states to keep per cluster in cleanup (default: 30)
#   --context CTX Use specific kubectl context
#   -q, --quiet   Suppress progress output, only show results
#   -h, --help    Show this help
#
# ═══════════════════════════════════════════════════════════════════

set -uo pipefail

# ── Colors ──
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[1;34m' DIM='\033[2m' N='\033[0m'

# ── Defaults ──
STATE_DIR="./cluster_states"
KEEP=30
QUIET=false
KUBE_CONTEXT=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse arguments ──
ACTION="${1:-help}"
shift 2>/dev/null || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)     STATE_DIR="$2"; shift 2;;
    --keep)    KEEP="$2"; shift 2;;
    --context) KUBE_CONTEXT="$2"; shift 2;;
    -q|--quiet) QUIET=true; shift;;
    -h|--help) ACTION="help"; shift;;
    *)
      # positional args for compare mode
      if [[ "$ACTION" == "compare" ]]; then
        if [[ -z "${FILE_A:-}" ]]; then FILE_A="$1"
        elif [[ -z "${FILE_B:-}" ]]; then FILE_B="$1"
        fi
      fi
      shift;;
  esac
done

log()  { $QUIET || echo -e "$@" >&2; }
err()  { echo -e "${R}ERROR: $*${N}" >&2; }

kc() {
  if [[ -n "$KUBE_CONTEXT" ]]; then
    kubectl --context="$KUBE_CONTEXT" "$@"
  else
    kubectl "$@"
  fi
}

# ═══════════════════════════════════════════════════════════════════
# SAVE — collect operational fingerprint
# ═══════════════════════════════════════════════════════════════════
do_save() {
  local context
  context=$(kc config current-context 2>/dev/null || echo "unknown")
  local k8s_ver
  k8s_ver=$(kc version 2>/dev/null | grep "Server Version" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
  local ts
  ts=$(date +%Y%m%d_%H%M%S)

  mkdir -p "$STATE_DIR"
  local outfile="$STATE_DIR/${context}_${ts}.json"

  # Temp dir for intermediate JSON (avoids "Argument list too long" on large clusters)
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  log "${B}Saving cluster state: ${N}${context}"

  # ── Collect raw data into temp files ──
  log "  Collecting nodes..."
  kc get nodes -o json 2>/dev/null > "$tmpdir/nodes.json" || echo '{"items":[]}' > "$tmpdir/nodes.json"

  log "  Collecting workloads..."
  kc get deployments -A -o json 2>/dev/null > "$tmpdir/deploy.json" || echo '{"items":[]}' > "$tmpdir/deploy.json"
  kc get statefulsets -A -o json 2>/dev/null > "$tmpdir/sts.json" || echo '{"items":[]}' > "$tmpdir/sts.json"
  kc get daemonsets -A -o json 2>/dev/null > "$tmpdir/ds.json" || echo '{"items":[]}' > "$tmpdir/ds.json"

  log "  Collecting HPA..."
  kc get hpa -A -o json 2>/dev/null > "$tmpdir/hpa.json" || echo '{"items":[]}' > "$tmpdir/hpa.json"

  log "  Collecting pods summary..."
  local pods_total pods_failed pods_crash pods_pending
  pods_total=$(kc get pods -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  pods_failed=$(kc get pods -A --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l | tr -d ' ')
  pods_crash=$(kc get pods -A 2>/dev/null | grep -c CrashLoopBackOff || true)
  pods_pending=$(kc get pods -A --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')
  : "${pods_total:=0}" "${pods_failed:=0}" "${pods_crash:=0}" "${pods_pending:=0}"

  log "  Collecting PVCs..."
  local pvc_total pvc_unbound
  local pvc_json
  pvc_json=$(kc get pvc -A -o json 2>/dev/null || echo '{"items":[]}')
  pvc_total=$(echo "$pvc_json" | jq '.items | length')
  pvc_unbound=$(echo "$pvc_json" | jq '[.items[] | select(.status.phase != "Bound")] | length')
  : "${pvc_total:=0}" "${pvc_unbound:=0}"

  log "  Collecting Helm releases..."
  if command -v helm >/dev/null 2>&1; then
    helm list -A -o json 2>/dev/null > "$tmpdir/helm.json" || echo '[]' > "$tmpdir/helm.json"
  else
    echo '[]' > "$tmpdir/helm.json"
  fi

  log "  Collecting operator CRDs..."

  # KEDA
  echo '{"items":[]}' > "$tmpdir/keda_so.json"
  echo '{"items":[]}' > "$tmpdir/keda_sj.json"
  if kc api-resources --api-group=keda.sh >/dev/null 2>&1; then
    kc get scaledobjects -A -o json 2>/dev/null > "$tmpdir/keda_so.json" || true
    kc get scaledjobs -A -o json 2>/dev/null > "$tmpdir/keda_sj.json" || true
  fi

  # cert-manager
  echo '{"items":[]}' > "$tmpdir/cm.json"
  if kc api-resources --api-group=cert-manager.io >/dev/null 2>&1; then
    kc get certificates -A -o json 2>/dev/null > "$tmpdir/cm.json" || true
  fi

  # Karpenter
  echo '{"items":[]}' > "$tmpdir/karp_np.json"
  echo '{"items":[]}' > "$tmpdir/karp_ec2.json"
  if kc api-resources --api-group=karpenter.sh >/dev/null 2>&1; then
    kc get nodepools -A -o json 2>/dev/null > "$tmpdir/karp_np.json" || true
  fi
  if kc api-resources --api-group=karpenter.k8s.aws >/dev/null 2>&1; then
    kc get ec2nodeclasses -A -o json 2>/dev/null > "$tmpdir/karp_ec2.json" || true
  fi

  # VictoriaMetrics
  echo '[]' > "$tmpdir/vm_core.json"
  echo '[]' > "$tmpdir/vm_config.json"
  if kc api-resources --api-group=operator.victoriametrics.com >/dev/null 2>&1; then
    (for r in vmagents vmalertmanagers vmalerts vmclusters vmsingles vmauths; do
      kc get "$r" -A -o json 2>/dev/null | jq --arg kind "$r" '.items[] | {kind: $kind, namespace: .metadata.namespace, name: .metadata.name, generation: .metadata.generation, observedGeneration: .status.observedGeneration, updateStatus: (.status.updateStatus // null)}'
    done) | jq -s '.' > "$tmpdir/vm_core.json"
    (for r in vmservicescrapes vmpodscrapes vmrules vmnodescrapes vmstaticscrapes vmprobes; do
      kc get "$r" -A -o json 2>/dev/null | jq --arg kind "$r" '.items[] | {kind: $kind, namespace: .metadata.namespace, name: .metadata.name, generation: .metadata.generation, observedGeneration: .status.observedGeneration, updateStatus: (.status.updateStatus // null), conditionsOk: ((.status.conditions // [] | all(.status == "True")) // null)}'
    done) | jq -s '.' > "$tmpdir/vm_config.json"
  fi

  # Velero
  echo '{"items":[]}' > "$tmpdir/velero_sched.json"
  echo 'null' > "$tmpdir/velero_bkp.json"
  if kc api-resources --api-group=velero.io >/dev/null 2>&1; then
    kc get schedules.velero.io -A -o json 2>/dev/null > "$tmpdir/velero_sched.json" || true
    kc get backups.velero.io -A -o json 2>/dev/null | jq '[.items | sort_by(.metadata.creationTimestamp) | reverse | .[0] | {name: .metadata.name, phase: .status.phase, timestamp: .metadata.creationTimestamp}] | .[0]' > "$tmpdir/velero_bkp.json" 2>/dev/null || true
  fi

  log "  Building fingerprint..."

  # ── Pre-process each source into its final shape ──
  # This avoids passing huge raw JSON through --argjson
  jq '{
    total: (.items | length),
    ready: ([.items[] | select(.status.conditions[]? | .type == "Ready" and .status == "True")] | length),
    by_nodepool: ([.items[] |
      {pool: (.metadata.labels["karpenter.sh/nodepool"] // .metadata.labels["eks.amazonaws.com/nodegroup"] // "unmanaged"),
       version: .status.nodeInfo.kubeletVersion}] |
      group_by(.pool) | map({key: .[0].pool, value: {count: length, version: .[0].version}}) | from_entries)
  }' "$tmpdir/nodes.json" > "$tmpdir/f_nodes.json"

  jq '[.items[] | {ns: .metadata.namespace, name: .metadata.name, desired: (.spec.replicas // 1), ready: (.status.readyReplicas // 0), available: (.status.availableReplicas // 0)}]' "$tmpdir/deploy.json" > "$tmpdir/f_deploy.json"
  jq '[.items[] | {ns: .metadata.namespace, name: .metadata.name, desired: (.spec.replicas // 1), ready: (.status.readyReplicas // 0)}]' "$tmpdir/sts.json" > "$tmpdir/f_sts.json"
  jq '[.items[] | {ns: .metadata.namespace, name: .metadata.name, desired: .status.desiredNumberScheduled, ready: (.status.numberReady // 0), available: (.status.numberAvailable // 0)}]' "$tmpdir/ds.json" > "$tmpdir/f_ds.json"

  jq '[.items[] | {ns: .metadata.namespace, name: .metadata.name, targetRef: "\(.spec.scaleTargetRef.kind)/\(.spec.scaleTargetRef.name)", minReplicas: (.spec.minReplicas // 1), maxReplicas: .spec.maxReplicas, currentReplicas: (.status.currentReplicas // 0)}]' "$tmpdir/hpa.json" > "$tmpdir/f_hpa.json"

  jq 'if type == "array" then [.[] | {ns: .namespace, name: .name, chart: .chart, app_version: .app_version, status: .status}] else [] end' "$tmpdir/helm.json" > "$tmpdir/f_helm.json"

  jq '[.items[] | {ns: .metadata.namespace, name: .metadata.name, ready: ((.status.conditions // []) | any(.type == "Ready" and .status == "True")), active: ((.status.conditions // []) | any(.type == "Active" and .status == "True")), conditions: [(.status.conditions // [])[] | {type: .type, status: .status}]}]' "$tmpdir/keda_so.json" > "$tmpdir/f_keda_so.json"
  jq '[.items[] | {ns: .metadata.namespace, name: .metadata.name, conditions: [(.status.conditions // [])[] | {type: .type, status: .status}]}]' "$tmpdir/keda_sj.json" > "$tmpdir/f_keda_sj.json"

  jq '[.items[] | {ns: .metadata.namespace, name: .metadata.name, ready: ((.status.conditions // []) | any(.type == "Ready" and .status == "True")), notAfter: (.status.notAfter // null)}]' "$tmpdir/cm.json" > "$tmpdir/f_cm.json"

  jq '[.items[] | {name: .metadata.name, ready: ((.status.conditions // []) | any(.type == "Ready" and .status == "True")), conditions: [(.status.conditions // [])[] | {type: .type, status: .status}]}]' "$tmpdir/karp_np.json" > "$tmpdir/f_karp_np.json"
  jq '[.items[] | {name: .metadata.name, ready: ((.status.conditions // []) | any(.type == "Ready" and .status == "True")), conditions: [(.status.conditions // [])[] | {type: .type, status: .status}]}]' "$tmpdir/karp_ec2.json" > "$tmpdir/f_karp_ec2.json"

  jq '[.items[] | {ns: .metadata.namespace, name: .metadata.name, phase: (.status.phase // null), lastBackup: (.status.lastBackup // null)}]' "$tmpdir/velero_sched.json" > "$tmpdir/f_velero_sched.json"

  # ── Final assembly from pre-processed small files ──
  jq -n \
    --arg context "$context" \
    --arg k8s_version "$k8s_ver" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg ts_local "$(date '+%Y-%m-%d %H:%M:%S')" \
    --argjson pods_total "$pods_total" \
    --argjson pods_failed "$pods_failed" \
    --argjson pods_crash "$pods_crash" \
    --argjson pods_pending "$pods_pending" \
    --argjson pvc_total "$pvc_total" \
    --argjson pvc_unbound "$pvc_unbound" \
    --slurpfile nodes "$tmpdir/f_nodes.json" \
    --slurpfile deployments "$tmpdir/f_deploy.json" \
    --slurpfile statefulsets "$tmpdir/f_sts.json" \
    --slurpfile daemonsets "$tmpdir/f_ds.json" \
    --slurpfile hpa "$tmpdir/f_hpa.json" \
    --slurpfile helm "$tmpdir/f_helm.json" \
    --slurpfile keda_so "$tmpdir/f_keda_so.json" \
    --slurpfile keda_sj "$tmpdir/f_keda_sj.json" \
    --slurpfile cm_certs "$tmpdir/f_cm.json" \
    --slurpfile karp_np "$tmpdir/f_karp_np.json" \
    --slurpfile karp_ec2 "$tmpdir/f_karp_ec2.json" \
    --slurpfile vm_core "$tmpdir/vm_core.json" \
    --slurpfile vm_config "$tmpdir/vm_config.json" \
    --slurpfile velero_sched "$tmpdir/f_velero_sched.json" \
    --slurpfile velero_bkp "$tmpdir/velero_bkp.json" \
  '{
    meta: {
      context: $context,
      k8s_version: $k8s_version,
      timestamp: $timestamp,
      timestamp_local: $ts_local
    },
    nodes: $nodes[0],
    pods: { total: $pods_total, failed: $pods_failed, crashloop: $pods_crash, pending: $pods_pending },
    pvcs: { total: $pvc_total, unbound: $pvc_unbound },
    workloads: { deployments: $deployments[0], statefulsets: $statefulsets[0], daemonsets: $daemonsets[0] },
    hpa: $hpa[0],
    helm: $helm[0],
    operators: {
      keda_scaledobjects: $keda_so[0],
      keda_scaledjobs: $keda_sj[0],
      certmanager_certs: $cm_certs[0],
      karpenter_nodepools: $karp_np[0],
      karpenter_ec2nodeclasses: $karp_ec2[0],
      vm_core: $vm_core[0],
      vm_config: $vm_config[0],
      velero_schedules: $velero_sched[0],
      velero_last_backup: $velero_bkp[0]
    }
  }' > "$outfile"

  log "${G}State saved:${N} $outfile"
  echo "$outfile"
}

# ═══════════════════════════════════════════════════════════════════
# COMPARE — semantic diff between two fingerprints
# ═══════════════════════════════════════════════════════════════════
do_compare() {
  local file_a="${FILE_A:-${1:-}}"
  local file_b="${FILE_B:-${2:-}}"

  [[ -z "$file_a" || -z "$file_b" ]] && { err "Usage: $0 compare <before.json> <after.json>"; exit 1; }
  [[ ! -f "$file_a" ]] && { err "File not found: $file_a"; exit 1; }
  [[ ! -f "$file_b" ]] && { err "File not found: $file_b"; exit 1; }

  local ctx_a ctx_b ts_a ts_b
  ctx_a=$(jq -r '.meta.context' "$file_a")
  ctx_b=$(jq -r '.meta.context' "$file_b")
  ts_a=$(jq -r '.meta.timestamp_local' "$file_a")
  ts_b=$(jq -r '.meta.timestamp_local' "$file_b")

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "CLUSTER STATE COMPARISON"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "  Before: ${DIM}$ctx_a @ $ts_a${N}"
  echo -e "  After:  ${DIM}$ctx_b @ $ts_b${N}"
  echo ""

  local issues=0

  # Helper: compare scalar
  compare_scalar() {
    local label="$1" path="$2" sev="$3"
    local va vb
    va=$(jq -r "$path" "$file_a")
    vb=$(jq -r "$path" "$file_b")
    if [[ "$va" != "$vb" ]]; then
      case "$sev" in
        CRITICAL) echo -e "  ${R}CRITICAL${N} $label: $va -> $vb";;
        HIGH)     echo -e "  ${R}HIGH${N}     $label: $va -> $vb";;
        WARNING)  echo -e "  ${Y}WARNING${N}  $label: $va -> $vb";;
        INFO)     echo -e "  ${DIM}INFO${N}     $label: $va -> $vb";;
      esac
      issues=$((issues + 1))
    fi
  }

  # ── 1. Cluster meta ──
  echo -e "${B}[Meta]${N}"
  compare_scalar "K8s version" ".meta.k8s_version" "INFO"
  echo ""

  # ── 2. Nodes ──
  echo -e "${B}[Nodes]${N}"
  compare_scalar "Total nodes" ".nodes.total" "HIGH"
  compare_scalar "Ready nodes" ".nodes.ready" "HIGH"

  # Per-nodepool changes
  jq -r '.nodes.by_nodepool | to_entries[] | "\(.key)=\(.value.count)"' "$file_a" | sort > /tmp/_cs_np_a.$$
  jq -r '.nodes.by_nodepool | to_entries[] | "\(.key)=\(.value.count)"' "$file_b" | sort > /tmp/_cs_np_b.$$
  local np_diff
  np_diff=$(diff /tmp/_cs_np_a.$$ /tmp/_cs_np_b.$$ 2>/dev/null || true)
  if [[ -n "$np_diff" ]]; then
    echo -e "  ${Y}WARNING${N}  NodePool composition changed:"
    diff --old-line-format="    - %l (removed)
" --new-line-format="    + %l (added)
" --unchanged-line-format="" /tmp/_cs_np_a.$$ /tmp/_cs_np_b.$$ 2>/dev/null || true
    issues=$((issues + 1))
  fi
  rm -f /tmp/_cs_np_a.$$ /tmp/_cs_np_b.$$
  echo ""

  # ── 3. Pods ──
  echo -e "${B}[Pods]${N}"
  compare_scalar "Total pods" ".pods.total" "WARNING"
  local fail_a fail_b crash_a crash_b pend_a pend_b
  fail_a=$(jq '.pods.failed' "$file_a"); fail_b=$(jq '.pods.failed' "$file_b")
  crash_a=$(jq '.pods.crashloop' "$file_a"); crash_b=$(jq '.pods.crashloop' "$file_b")
  pend_a=$(jq '.pods.pending' "$file_a"); pend_b=$(jq '.pods.pending' "$file_b")
  [[ "$fail_b" -gt "$fail_a" ]] && { echo -e "  ${R}HIGH${N}     Failed pods increased: $fail_a -> $fail_b"; issues=$((issues+1)); }
  [[ "$crash_b" -gt "$crash_a" ]] && { echo -e "  ${R}CRITICAL${N} CrashLoop pods increased: $crash_a -> $crash_b"; issues=$((issues+1)); }
  [[ "$pend_b" -gt "$pend_a" ]] && { echo -e "  ${Y}WARNING${N}  Pending pods increased: $pend_a -> $pend_b"; issues=$((issues+1)); }
  echo ""

  # ── 4. PVCs ──
  echo -e "${B}[PVCs]${N}"
  local ub_a ub_b
  ub_a=$(jq '.pvcs.unbound' "$file_a"); ub_b=$(jq '.pvcs.unbound' "$file_b")
  [[ "$ub_b" -gt "$ub_a" ]] && { echo -e "  ${R}HIGH${N}     Unbound PVCs increased: $ub_a -> $ub_b"; issues=$((issues+1)); }
  [[ "$ub_a" == "$ub_b" && "$ub_a" == "0" ]] && echo -e "  ${G}ok${N}"
  echo ""

  # ── 5. Workloads — the core regression detection ──
  echo -e "${B}[Workloads]${N}"

  # Build key->replicas maps and compare
  for wtype in deployments statefulsets daemonsets; do
    local field_ready="ready"

    # Before: {ns/name: {desired: N, ready: N}}
    jq -r --arg w "$wtype" '.workloads[$w][] | "\(.ns)/\(.name)\t\(.desired)\t\(.ready)"' "$file_a" 2>/dev/null | sort > /tmp/_cs_wl_a.$$
    jq -r --arg w "$wtype" '.workloads[$w][] | "\(.ns)/\(.name)\t\(.desired)\t\(.ready)"' "$file_b" 2>/dev/null | sort > /tmp/_cs_wl_b.$$

    # Find replica drops
    while IFS=$'\t' read -r name desired_a ready_a; do
      local line_b
      line_b=$(grep "^${name}	" /tmp/_cs_wl_b.$$ 2>/dev/null || echo "")
      if [[ -z "$line_b" ]]; then
        echo -e "  ${R}CRITICAL${N} $wtype $name: DISAPPEARED"
        issues=$((issues+1))
      else
        local desired_b ready_b
        desired_b=$(echo "$line_b" | cut -f2)
        ready_b=$(echo "$line_b" | cut -f3)
        if [[ "$ready_b" -eq 0 && "$ready_a" -gt 0 ]]; then
          echo -e "  ${R}CRITICAL${N} $wtype $name: ready $ready_a -> 0"
          issues=$((issues+1))
        elif [[ "$ready_b" -lt "$ready_a" && "$ready_b" -gt 0 ]]; then
          # Check if within HPA bounds — if so, it's INFO not WARNING
          local hpa_match
          hpa_match=$(jq --arg n "$name" '[.hpa[] | select(.targetRef | endswith($n | split("/") | .[-1]))] | length' "$file_b" 2>/dev/null || echo 0)
          if [[ "$hpa_match" -gt 0 ]]; then
            echo -e "  ${DIM}INFO${N}     $wtype $name: ready $ready_a -> $ready_b (HPA-managed)"
          else
            echo -e "  ${Y}WARNING${N}  $wtype $name: ready $ready_a -> $ready_b"
            issues=$((issues+1))
          fi
        fi
      fi
    done < /tmp/_cs_wl_a.$$

    # Find new workloads
    while IFS=$'\t' read -r name desired_b ready_b; do
      local exists_a
      exists_a=$(grep "^${name}	" /tmp/_cs_wl_a.$$ 2>/dev/null || echo "")
      if [[ -z "$exists_a" ]]; then
        echo -e "  ${DIM}INFO${N}     $wtype $name: NEW (desired=$desired_b, ready=$ready_b)"
      fi
    done < /tmp/_cs_wl_b.$$

    rm -f /tmp/_cs_wl_a.$$ /tmp/_cs_wl_b.$$
  done

  # DaemonSet coverage loss (desired vs ready)
  jq -r '.workloads.daemonsets[] | select(.desired != .ready) | "\(.ns)/\(.name): desired=\(.desired) ready=\(.ready)"' "$file_b" 2>/dev/null | while read -r line; do
    echo -e "  ${R}HIGH${N}     DaemonSet coverage gap: $line"
    issues=$((issues+1))
  done
  echo ""

  # ── 6. HPA ──
  echo -e "${B}[HPA]${N}"
  jq -r '.hpa[] | "\(.ns)/\(.name)\t\(.currentReplicas)\t\(.minReplicas)\t\(.maxReplicas)"' "$file_a" 2>/dev/null | sort > /tmp/_cs_hpa_a.$$
  jq -r '.hpa[] | "\(.ns)/\(.name)\t\(.currentReplicas)\t\(.minReplicas)\t\(.maxReplicas)"' "$file_b" 2>/dev/null | sort > /tmp/_cs_hpa_b.$$

  while IFS=$'\t' read -r name cur_a min_a max_a; do
    local hline_b
    hline_b=$(grep "^${name}	" /tmp/_cs_hpa_b.$$ 2>/dev/null || echo "")
    if [[ -n "$hline_b" ]]; then
      local cur_b min_b max_b
      cur_b=$(echo "$hline_b" | cut -f2)
      min_b=$(echo "$hline_b" | cut -f3)
      max_b=$(echo "$hline_b" | cut -f4)
      if [[ "$cur_b" -eq "$max_b" && "$cur_a" -lt "$max_b" ]]; then
        echo -e "  ${Y}WARNING${N}  HPA $name: hit max ($cur_a -> $cur_b/$max_b)"
        issues=$((issues+1))
      fi
      if [[ "$cur_b" -eq 0 && "$cur_a" -gt 0 ]]; then
        echo -e "  ${R}CRITICAL${N} HPA $name: replicas dropped to 0 ($cur_a -> 0)"
        issues=$((issues+1))
      fi
      if [[ "$min_a" != "$min_b" || "$max_a" != "$max_b" ]]; then
        echo -e "  ${DIM}INFO${N}     HPA $name: bounds changed min=$min_a->$min_b max=$max_a->$max_b"
      fi
    fi
  done < /tmp/_cs_hpa_a.$$
  rm -f /tmp/_cs_hpa_a.$$ /tmp/_cs_hpa_b.$$
  echo ""

  # ── 7. Helm releases ──
  echo -e "${B}[Helm]${N}"
  jq -r '.helm[] | "\(.ns)/\(.name)\t\(.chart)\t\(.status)"' "$file_a" 2>/dev/null | sort > /tmp/_cs_helm_a.$$
  jq -r '.helm[] | "\(.ns)/\(.name)\t\(.chart)\t\(.status)"' "$file_b" 2>/dev/null | sort > /tmp/_cs_helm_b.$$

  while IFS=$'\t' read -r name chart_a status_a; do
    local hline_b
    hline_b=$(grep "^${name}	" /tmp/_cs_helm_b.$$ 2>/dev/null || echo "")
    if [[ -z "$hline_b" ]]; then
      echo -e "  ${Y}WARNING${N}  Helm $name: REMOVED (was $chart_a)"
      issues=$((issues+1))
    else
      local chart_b status_b
      chart_b=$(echo "$hline_b" | cut -f2)
      status_b=$(echo "$hline_b" | cut -f3)
      [[ "$chart_a" != "$chart_b" ]] && echo -e "  ${DIM}INFO${N}     Helm $name: $chart_a -> $chart_b"
      if [[ "$status_a" == "deployed" && "$status_b" != "deployed" ]]; then
        echo -e "  ${R}HIGH${N}     Helm $name: status $status_a -> $status_b"
        issues=$((issues+1))
      fi
    fi
  done < /tmp/_cs_helm_a.$$

  # New helm releases
  while IFS=$'\t' read -r name chart_b status_b; do
    local exists_a
    exists_a=$(grep "^${name}	" /tmp/_cs_helm_a.$$ 2>/dev/null || echo "")
    [[ -z "$exists_a" ]] && echo -e "  ${DIM}INFO${N}     Helm $name: NEW ($chart_b, $status_b)"
  done < /tmp/_cs_helm_b.$$
  rm -f /tmp/_cs_helm_a.$$ /tmp/_cs_helm_b.$$
  echo ""

  # ── 8. Operators — CRD reconciliation regressions ──
  echo -e "${B}[Operators]${N}"

  # KEDA ScaledObjects: Ready regression
  jq -r '.operators.keda_scaledobjects[] | "\(.ns)/\(.name)\t\(.ready)"' "$file_a" 2>/dev/null | sort > /tmp/_cs_keda_a.$$
  jq -r '.operators.keda_scaledobjects[] | "\(.ns)/\(.name)\t\(.ready)"' "$file_b" 2>/dev/null | sort > /tmp/_cs_keda_b.$$
  while IFS=$'\t' read -r name ready_a; do
    local kline_b
    kline_b=$(grep "^${name}	" /tmp/_cs_keda_b.$$ 2>/dev/null || echo "")
    if [[ -n "$kline_b" ]]; then
      local ready_b
      ready_b=$(echo "$kline_b" | cut -f2)
      if [[ "$ready_a" == "true" && "$ready_b" == "false" ]]; then
        echo -e "  ${R}CRITICAL${N} KEDA ScaledObject $name: Ready=true -> false"
        issues=$((issues+1))
      fi
    elif [[ -n "$name" ]]; then
      echo -e "  ${R}CRITICAL${N} KEDA ScaledObject $name: DISAPPEARED"
      issues=$((issues+1))
    fi
  done < /tmp/_cs_keda_a.$$
  rm -f /tmp/_cs_keda_a.$$ /tmp/_cs_keda_b.$$

  # cert-manager: Ready regression
  jq -r '.operators.certmanager_certs[] | "\(.ns)/\(.name)\t\(.ready)"' "$file_a" 2>/dev/null | sort > /tmp/_cs_cm_a.$$
  jq -r '.operators.certmanager_certs[] | "\(.ns)/\(.name)\t\(.ready)"' "$file_b" 2>/dev/null | sort > /tmp/_cs_cm_b.$$
  while IFS=$'\t' read -r name ready_a; do
    local cline_b
    cline_b=$(grep "^${name}	" /tmp/_cs_cm_b.$$ 2>/dev/null || echo "")
    if [[ -n "$cline_b" ]]; then
      local ready_b
      ready_b=$(echo "$cline_b" | cut -f2)
      if [[ "$ready_a" == "true" && "$ready_b" == "false" ]]; then
        echo -e "  ${R}HIGH${N}     cert-manager Certificate $name: Ready=true -> false"
        issues=$((issues+1))
      fi
    fi
  done < /tmp/_cs_cm_a.$$
  rm -f /tmp/_cs_cm_a.$$ /tmp/_cs_cm_b.$$

  # Karpenter NodePools: Ready regression
  jq -r '.operators.karpenter_nodepools[] | "\(.name)\t\(.ready)"' "$file_a" 2>/dev/null | sort > /tmp/_cs_knp_a.$$
  jq -r '.operators.karpenter_nodepools[] | "\(.name)\t\(.ready)"' "$file_b" 2>/dev/null | sort > /tmp/_cs_knp_b.$$
  while IFS=$'\t' read -r name ready_a; do
    local kline_b
    kline_b=$(grep "^${name}	" /tmp/_cs_knp_b.$$ 2>/dev/null || echo "")
    if [[ -n "$kline_b" ]]; then
      local ready_b
      ready_b=$(echo "$kline_b" | cut -f2)
      if [[ "$ready_a" == "true" && "$ready_b" == "false" ]]; then
        echo -e "  ${R}CRITICAL${N} Karpenter NodePool $name: Ready=true -> false"
        issues=$((issues+1))
      fi
    fi
  done < /tmp/_cs_knp_a.$$
  rm -f /tmp/_cs_knp_a.$$ /tmp/_cs_knp_b.$$

  # VM operator: observedGeneration drift or updateStatus regression
  jq -r '.operators.vm_core[] | "\(.kind)/\(.namespace)/\(.name)\t\(.updateStatus // "null")\t\(.generation)\t\(.observedGeneration // "null")"' "$file_a" 2>/dev/null | sort > /tmp/_cs_vm_a.$$
  jq -r '.operators.vm_core[] | "\(.kind)/\(.namespace)/\(.name)\t\(.updateStatus // "null")\t\(.generation)\t\(.observedGeneration // "null")"' "$file_b" 2>/dev/null | sort > /tmp/_cs_vm_b.$$
  while IFS=$'\t' read -r name status_a gen_a obs_a; do
    local vline_b
    vline_b=$(grep "^${name}	" /tmp/_cs_vm_b.$$ 2>/dev/null || echo "")
    if [[ -n "$vline_b" ]]; then
      local status_b gen_b obs_b
      status_b=$(echo "$vline_b" | cut -f2)
      gen_b=$(echo "$vline_b" | cut -f3)
      obs_b=$(echo "$vline_b" | cut -f4)
      if [[ "$status_a" == "operational" && "$status_b" != "operational" && "$status_b" != "null" ]]; then
        echo -e "  ${R}HIGH${N}     VM $name: operational -> $status_b"
        issues=$((issues+1))
      fi
      if [[ "$obs_b" != "null" && "$gen_b" != "$obs_b" ]]; then
        echo -e "  ${R}HIGH${N}     VM $name: observedGeneration drift (gen=$gen_b, observed=$obs_b)"
        issues=$((issues+1))
      fi
    fi
  done < /tmp/_cs_vm_a.$$
  rm -f /tmp/_cs_vm_a.$$ /tmp/_cs_vm_b.$$

  # Velero: backup regression
  local vbkp_phase_a vbkp_phase_b
  vbkp_phase_a=$(jq -r '.operators.velero_last_backup.phase // "null"' "$file_a")
  vbkp_phase_b=$(jq -r '.operators.velero_last_backup.phase // "null"' "$file_b")
  if [[ "$vbkp_phase_a" == "Completed" && "$vbkp_phase_b" =~ Failed ]]; then
    echo -e "  ${R}HIGH${N}     Velero last backup: $vbkp_phase_a -> $vbkp_phase_b"
    issues=$((issues+1))
  fi
  echo ""

  # ── Summary ──
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ "$issues" -eq 0 ]]; then
    echo -e "${G}No regressions detected.${N}"
  else
    echo -e "${R}$issues issue(s) detected.${N} Review CRITICAL and HIGH items above."
  fi

  return $( [[ "$issues" -eq 0 ]] && echo 0 || echo 1 )
}

# ═══════════════════════════════════════════════════════════════════
# CHECK — save + compare with latest + health check
# ═══════════════════════════════════════════════════════════════════
do_check() {
  local context
  context=$(kc config current-context 2>/dev/null || echo "unknown")

  # Find latest existing state for this cluster
  local latest=""
  if [[ -d "$STATE_DIR" ]]; then
    latest=$(ls -1t "$STATE_DIR"/${context}_*.json 2>/dev/null | head -1 || true)
  fi

  # Save new state
  local new_file
  new_file=$(do_save)

  # Compare if previous state exists
  if [[ -n "$latest" && "$latest" != "$new_file" ]]; then
    echo ""
    FILE_A="$latest" FILE_B="$new_file" do_compare
  else
    echo ""
    echo -e "${Y}No previous state found for ${context}. First snapshot saved.${N}"
    echo -e "Run again after making changes to see comparison."
  fi

  # Run health check if available
  if [[ -f "$SCRIPT_DIR/eks-healthcheck.sh" ]]; then
    echo ""
    bash "$SCRIPT_DIR/eks-healthcheck.sh"
  fi
}

# ═══════════════════════════════════════════════════════════════════
# LIST — show saved states for current (or all) clusters
# ═══════════════════════════════════════════════════════════════════
do_list() {
  [[ ! -d "$STATE_DIR" ]] && { echo "No states directory: $STATE_DIR"; exit 0; }

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "SAVED CLUSTER STATES ($STATE_DIR)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  local prev_ctx=""
  for f in $(ls -1t "$STATE_DIR"/*.json 2>/dev/null); do
    local ctx ts ver
    ctx=$(jq -r '.meta.context' "$f" 2>/dev/null)
    ts=$(jq -r '.meta.timestamp_local' "$f" 2>/dev/null)
    ver=$(jq -r '.meta.k8s_version' "$f" 2>/dev/null)
    local nodes pods
    nodes=$(jq '.nodes.total' "$f" 2>/dev/null)
    pods=$(jq '.pods.total' "$f" 2>/dev/null)

    if [[ "$ctx" != "$prev_ctx" ]]; then
      echo ""
      echo -e "${B}$ctx${N} (k8s $ver)"
      prev_ctx="$ctx"
    fi
    echo -e "  $ts  nodes=$nodes pods=$pods  ${DIM}$(basename "$f")${N}"
  done
  echo ""
}

# ═══════════════════════════════════════════════════════════════════
# CLEANUP — rotate old states, keep last N per cluster
# ═══════════════════════════════════════════════════════════════════
do_cleanup() {
  [[ ! -d "$STATE_DIR" ]] && { echo "No states directory: $STATE_DIR"; exit 0; }

  local clusters
  clusters=$(ls -1 "$STATE_DIR"/*.json 2>/dev/null | xargs -I{} jq -r '.meta.context' {} 2>/dev/null | sort -u)
  local total_removed=0

  for ctx in $clusters; do
    local files
    files=$(ls -1t "$STATE_DIR"/${ctx}_*.json 2>/dev/null)
    local count
    count=$(echo "$files" | wc -l)
    if [[ "$count" -gt "$KEEP" ]]; then
      local to_remove
      to_remove=$(echo "$files" | tail -n +$((KEEP + 1)))
      local rm_count
      rm_count=$(echo "$to_remove" | wc -l)
      echo "$to_remove" | xargs rm -f
      echo -e "  $ctx: removed $rm_count old state(s), kept $KEEP"
      total_removed=$((total_removed + rm_count))
    else
      echo -e "  $ctx: $count state(s), nothing to clean"
    fi
  done
  echo ""
  echo "Total removed: $total_removed"
}

# ═══════════════════════════════════════════════════════════════════
# HELP
# ═══════════════════════════════════════════════════════════════════
do_help() {
  head -35 "${BASH_SOURCE[0]}" | tail -n +2 | sed 's/^# \?//'
}

# ═══════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════
case "$ACTION" in
  save)    do_save ;;
  compare) do_compare ;;
  check)   do_check ;;
  list)    do_list ;;
  cleanup) do_cleanup ;;
  help|-h|--help) do_help ;;
  *) err "Unknown action: $ACTION"; do_help; exit 1;;
esac
