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

# CRD health classification — shared between save and compare
GOOD_PHASES="Running|Active|Enabled|Bound|Completed|Succeeded|Ready|Available|Operational|Healthy"

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
# COMPARISON SUB-FUNCTIONS
# ═══════════════════════════════════════════════════════════════════

ISSUES=0

_emit() {
  local sev="$1"; shift
  case "$sev" in
    CRITICAL) echo -e "  ${R}CRITICAL${N} $*";;
    HIGH)     echo -e "  ${R}HIGH${N}     $*";;
    WARNING)  echo -e "  ${Y}WARNING${N}  $*";;
    INFO)     echo -e "  ${DIM}INFO${N}     $*";;
  esac
  [[ "$sev" != "INFO" ]] && ISSUES=$((ISSUES + 1))
}

_cmp_scalar() {
  local label="$1" path="$2" sev="$3" fa="$4" fb="$5"
  local va vb
  va=$(jq -r "$path" "$fa"); vb=$(jq -r "$path" "$fb")
  [[ "$va" != "$vb" ]] && _emit "$sev" "$label: $va -> $vb"
}

_cmp_meta() {
  local fa="$1" fb="$2"
  echo -e "${B}[Meta]${N}"
  _cmp_scalar "K8s version" ".meta.k8s_version" "INFO" "$fa" "$fb"
  echo ""
}

_cmp_nodes() {
  local fa="$1" fb="$2" d="$3"
  echo -e "${B}[Nodes]${N}"
  _cmp_scalar "Total nodes" ".nodes.total" "HIGH" "$fa" "$fb"
  _cmp_scalar "Ready nodes" ".nodes.ready" "HIGH" "$fa" "$fb"

  jq -r '.nodes.by_nodepool | to_entries[] | "\(.key)=\(.value.count)"' "$fa" | sort > "$d/np_a"
  jq -r '.nodes.by_nodepool | to_entries[] | "\(.key)=\(.value.count)"' "$fb" | sort > "$d/np_b"
  if ! diff -q "$d/np_a" "$d/np_b" >/dev/null 2>&1; then
    _emit WARNING "NodePool composition changed:"
    diff --old-line-format="    - %l (removed)
" --new-line-format="    + %l (added)
" --unchanged-line-format="" "$d/np_a" "$d/np_b" 2>/dev/null || true
  fi

  # Per-nodepool kubelet version changes (supports both v1 and v2 schema)
  jq -r '.nodes.by_nodepool | to_entries[] | "\(.key)=\(.value.versions // [.value.version] | join(","))"' "$fa" 2>/dev/null | sort > "$d/npv_a"
  jq -r '.nodes.by_nodepool | to_entries[] | "\(.key)=\(.value.versions // [.value.version] | join(","))"' "$fb" 2>/dev/null | sort > "$d/npv_b"
  if ! diff -q "$d/npv_a" "$d/npv_b" >/dev/null 2>&1; then
    _emit INFO "NodePool kubelet versions changed"
  fi
  echo ""
}

_cmp_pods() {
  local fa="$1" fb="$2"
  echo -e "${B}[Pods]${N}"
  _cmp_scalar "Total pods" ".pods.total" "WARNING" "$fa" "$fb"

  local fail_a fail_b crash_a crash_b pend_a pend_b
  fail_a=$(jq '.pods.failed' "$fa"); fail_b=$(jq '.pods.failed' "$fb")
  crash_a=$(jq '.pods.crashloop' "$fa"); crash_b=$(jq '.pods.crashloop' "$fb")
  pend_a=$(jq '.pods.pending' "$fa"); pend_b=$(jq '.pods.pending' "$fb")
  [[ "$fail_b" -gt "$fail_a" ]] && _emit HIGH "Failed pods increased: $fail_a -> $fail_b"
  [[ "$crash_b" -gt "$crash_a" ]] && _emit CRITICAL "CrashLoop pods increased: $crash_a -> $crash_b"
  [[ "$pend_b" -gt "$pend_a" ]] && _emit WARNING "Pending pods increased: $pend_a -> $pend_b"

  local hr_a hr_b oom_a oom_b
  hr_a=$(jq '.pods.high_restarts // 0' "$fa"); hr_b=$(jq '.pods.high_restarts // 0' "$fb")
  oom_a=$(jq '.pods.oomkilled // 0' "$fa"); oom_b=$(jq '.pods.oomkilled // 0' "$fb")
  [[ "$hr_b" -gt "$hr_a" ]] && _emit WARNING "High-restart pods increased: $hr_a -> $hr_b"
  [[ "$oom_b" -gt "$oom_a" ]] && _emit HIGH "OOMKilled pods increased: $oom_a -> $oom_b"
  echo ""
}

_cmp_pvcs() {
  local fa="$1" fb="$2"
  echo -e "${B}[PVCs]${N}"
  local ub_a ub_b
  ub_a=$(jq '.pvcs.unbound' "$fa"); ub_b=$(jq '.pvcs.unbound' "$fb")
  [[ "$ub_b" -gt "$ub_a" ]] && _emit HIGH "Unbound PVCs increased: $ub_a -> $ub_b"
  [[ "$ub_a" == "$ub_b" && "$ub_a" == "0" ]] && echo -e "  ${G}ok${N}"
  echo ""
}

_cmp_workloads() {
  local fa="$1" fb="$2" d="$3"
  echo -e "${B}[Workloads]${N}"

  for wtype in deployments statefulsets daemonsets; do
    jq -r --arg w "$wtype" '.workloads[$w][]? | "\(.ns)/\(.name)\t\(.desired)\t\(.ready)"' "$fa" 2>/dev/null | sort > "$d/wl_a"
    jq -r --arg w "$wtype" '.workloads[$w][]? | "\(.ns)/\(.name)\t\(.desired)\t\(.ready)"' "$fb" 2>/dev/null | sort > "$d/wl_b"

    while IFS=$'\t' read -r name _desired_a ready_a; do
      local line_b
      line_b=$(grep -F "${name}	" "$d/wl_b" 2>/dev/null | head -1 || echo "")
      if [[ -z "$line_b" ]]; then
        _emit CRITICAL "$wtype $name: DISAPPEARED"
      else
        local desired_b ready_b
        desired_b=$(echo "$line_b" | cut -f2)
        ready_b=$(echo "$line_b" | cut -f3)
        if [[ "$ready_b" -eq 0 && "$ready_a" -gt 0 ]]; then
          _emit CRITICAL "$wtype $name: ready $ready_a -> 0"
        elif [[ "$ready_b" -lt "$ready_a" && "$ready_b" -gt 0 ]]; then
          local hpa_match
          hpa_match=$(jq --arg n "$name" '[.hpa[]? | select(.targetRef | endswith($n | split("/") | .[-1]))] | length' "$fb" 2>/dev/null || echo 0)
          if [[ "$hpa_match" -gt 0 ]]; then
            echo -e "  ${DIM}INFO${N}     $wtype $name: ready $ready_a -> $ready_b (HPA-managed)"
          else
            _emit WARNING "$wtype $name: ready $ready_a -> $ready_b"
          fi
        fi
      fi
    done < "$d/wl_a"

    while IFS=$'\t' read -r name desired_b ready_b; do
      grep -qF "${name}	" "$d/wl_a" 2>/dev/null || echo -e "  ${DIM}INFO${N}     $wtype $name: NEW (desired=$desired_b, ready=$ready_b)"
    done < "$d/wl_b"
  done

  # DaemonSet coverage gaps in current state
  while read -r line; do
    [[ -z "$line" ]] && continue
    _emit HIGH "DaemonSet coverage gap: $line"
  done < <(jq -r '.workloads.daemonsets[]? | select(.desired != .ready) | "\(.ns)/\(.name): desired=\(.desired) ready=\(.ready)"' "$fb" 2>/dev/null)
  echo ""
}

_cmp_hpa() {
  local fa="$1" fb="$2" d="$3"
  echo -e "${B}[HPA]${N}"
  jq -r '.hpa[]? | "\(.ns)/\(.name)\t\(.currentReplicas)\t\(.minReplicas)\t\(.maxReplicas)"' "$fa" 2>/dev/null | sort > "$d/hpa_a"
  jq -r '.hpa[]? | "\(.ns)/\(.name)\t\(.currentReplicas)\t\(.minReplicas)\t\(.maxReplicas)"' "$fb" 2>/dev/null | sort > "$d/hpa_b"

  while IFS=$'\t' read -r name cur_a min_a max_a; do
    local hline_b
    hline_b=$(grep -F "${name}	" "$d/hpa_b" 2>/dev/null | head -1 || echo "")
    if [[ -n "$hline_b" ]]; then
      local cur_b min_b max_b
      cur_b=$(echo "$hline_b" | cut -f2)
      min_b=$(echo "$hline_b" | cut -f3)
      max_b=$(echo "$hline_b" | cut -f4)
      [[ "$cur_b" -eq "$max_b" && "$cur_a" -lt "$max_b" ]] && _emit WARNING "HPA $name: hit max ($cur_a -> $cur_b/$max_b)"
      [[ "$cur_b" -eq 0 && "$cur_a" -gt 0 ]] && _emit CRITICAL "HPA $name: replicas dropped to 0 ($cur_a -> 0)"
      [[ "$min_a" != "$min_b" || "$max_a" != "$max_b" ]] && echo -e "  ${DIM}INFO${N}     HPA $name: bounds changed min=$min_a->$min_b max=$max_a->$max_b"
    fi
  done < "$d/hpa_a"
  echo ""
}

_cmp_helm() {
  local fa="$1" fb="$2" d="$3"
  echo -e "${B}[Helm]${N}"
  jq -r '.helm[]? | "\(.ns)/\(.name)\t\(.chart)\t\(.status)"' "$fa" 2>/dev/null | sort > "$d/helm_a"
  jq -r '.helm[]? | "\(.ns)/\(.name)\t\(.chart)\t\(.status)"' "$fb" 2>/dev/null | sort > "$d/helm_b"

  while IFS=$'\t' read -r name chart_a status_a; do
    local hline_b
    hline_b=$(grep -F "${name}	" "$d/helm_b" 2>/dev/null | head -1 || echo "")
    if [[ -z "$hline_b" ]]; then
      _emit WARNING "Helm $name: REMOVED (was $chart_a)"
    else
      local chart_b status_b
      chart_b=$(echo "$hline_b" | cut -f2)
      status_b=$(echo "$hline_b" | cut -f3)
      [[ "$chart_a" != "$chart_b" ]] && echo -e "  ${DIM}INFO${N}     Helm $name: $chart_a -> $chart_b"
      [[ "$status_a" == "deployed" && "$status_b" != "deployed" ]] && _emit HIGH "Helm $name: status $status_a -> $status_b"
    fi
  done < "$d/helm_a"

  while IFS=$'\t' read -r name chart_b status_b; do
    grep -qF "${name}	" "$d/helm_a" 2>/dev/null || echo -e "  ${DIM}INFO${N}     Helm $name: NEW ($chart_b, $status_b)"
  done < "$d/helm_b"
  echo ""
}

_cmp_services() {
  local fa="$1" fb="$2"
  echo -e "${B}[Services]${N}"
  local ne_a ne_b
  ne_a=$(jq '.services.no_endpoints // 0' "$fa")
  ne_b=$(jq '.services.no_endpoints // 0' "$fb")
  if [[ "$ne_b" -gt "$ne_a" ]]; then
    _emit WARNING "Services without endpoints increased: $ne_a -> $ne_b"
  elif [[ "$ne_b" == "0" ]]; then
    echo -e "  ${G}ok${N}"
  fi
  echo ""
}

_cmp_tls() {
  local fa="$1" fb="$2"
  echo -e "${B}[TLS Certificates]${N}"
  local exp_a exp_b expiring_a expiring_b
  exp_a=$(jq '.tls.expired // 0' "$fa"); exp_b=$(jq '.tls.expired // 0' "$fb")
  expiring_a=$(jq '.tls.expiring_30d // 0' "$fa"); expiring_b=$(jq '.tls.expiring_30d // 0' "$fb")
  [[ "$exp_b" -gt "$exp_a" ]] && _emit CRITICAL "Expired TLS certs increased: $exp_a -> $exp_b"
  [[ "$expiring_b" -gt "$expiring_a" ]] && _emit WARNING "Expiring TLS certs (30d) increased: $expiring_a -> $expiring_b"
  [[ "$exp_b" == "0" && "$expiring_b" == "0" ]] && echo -e "  ${G}ok${N}"
  echo ""
}

_cmp_crd_health() {
  local fa="$1" fb="$2" d="$3"
  echo -e "${B}[CRD Health]${N}"

  local has_a has_b
  has_a=$(jq 'has("crd_health")' "$fa")
  has_b=$(jq 'has("crd_health")' "$fb")
  if [[ "$has_a" != "true" || "$has_b" != "true" ]]; then
    echo -e "  ${Y}WARNING${N}  CRD health data not available in both files (schema v1 vs v2)"
    echo ""
    return
  fi

  # Extract per-type data: resource\ttotal\thealthy\tunhealthy
  jq -r '.crd_health.types | to_entries[] | "\(.key)\t\(.value.total)\t\(.value.healthy)\t\(.value.unhealthy)"' "$fa" 2>/dev/null | sort > "$d/crd_a"
  jq -r '.crd_health.types | to_entries[] | "\(.key)\t\(.value.total)\t\(.value.healthy)\t\(.value.unhealthy)"' "$fb" 2>/dev/null | sort > "$d/crd_b"
  cut -f1 "$d/crd_a" > "$d/crd_names_a"
  cut -f1 "$d/crd_b" > "$d/crd_names_b"

  # Disappeared CRD types with instances
  while read -r t; do
    [[ -z "$t" ]] && continue
    local total_a
    total_a=$(grep -F "${t}	" "$d/crd_a" | head -1 | cut -f2)
    [[ "${total_a:-0}" -gt 0 ]] && _emit WARNING "CRD type disappeared: $t ($total_a instances)"
  done < <(comm -23 "$d/crd_names_a" "$d/crd_names_b")

  # New CRD types
  while read -r t; do
    [[ -z "$t" ]] && continue
    echo -e "  ${DIM}INFO${N}     CRD type appeared: $t"
  done < <(comm -13 "$d/crd_names_a" "$d/crd_names_b")

  # Health regressions in common types
  while read -r t; do
    [[ -z "$t" ]] && continue
    local line_a line_b healthy_a healthy_b unhealthy_a unhealthy_b
    line_a=$(grep -F "${t}	" "$d/crd_a" | head -1)
    line_b=$(grep -F "${t}	" "$d/crd_b" | head -1)
    healthy_a=$(echo "$line_a" | cut -f3)
    healthy_b=$(echo "$line_b" | cut -f3)
    unhealthy_a=$(echo "$line_a" | cut -f4)
    unhealthy_b=$(echo "$line_b" | cut -f4)

    if [[ "${healthy_a:-0}" -gt 0 && "${healthy_b:-0}" -eq 0 && "${unhealthy_b:-0}" -gt 0 ]]; then
      _emit CRITICAL "$t: all instances unhealthy (healthy $healthy_a -> 0)"
    elif [[ "${unhealthy_b:-0}" -gt "${unhealthy_a:-0}" ]]; then
      _emit HIGH "$t: unhealthy ${unhealthy_a:-0} -> ${unhealthy_b:-0}"
    fi
  done < <(comm -12 "$d/crd_names_a" "$d/crd_names_b")
  echo ""
}

# ═══════════════════════════════════════════════════════════════════
# SAVE — collect operational fingerprint (schema v2)
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

  local tmpdir
  tmpdir=$(mktemp -d)

  log "${B}Saving cluster state: ${N}${context}"

  # ── Phase 1: Parallel core data collection ──
  log "  Collecting core resources..."

  # Pre-initialize with empty defaults (in case kubectl fails)
  echo '{"items":[]}' > "$tmpdir/nodes.json"
  echo '{"items":[]}' > "$tmpdir/workloads.json"
  echo '{"items":[]}' > "$tmpdir/ds.json"
  echo '{"items":[]}' > "$tmpdir/pods.json"
  echo '{"items":[]}' > "$tmpdir/hpa.json"
  echo '{"items":[]}' > "$tmpdir/pvc.json"
  echo '{"items":[]}' > "$tmpdir/svc.json"
  echo '{"items":[]}' > "$tmpdir/ep.json"
  echo '{"items":[]}' > "$tmpdir/tls.json"
  echo '[]' > "$tmpdir/helm.json"

  (kc get nodes -o json > "$tmpdir/nodes.json" 2>/dev/null || true) &
  (kc get deployments,statefulsets -A -o json > "$tmpdir/workloads.json" 2>/dev/null || true) &
  (kc get daemonsets -A -o json > "$tmpdir/ds.json" 2>/dev/null || true) &
  (kc get pods -A -o json > "$tmpdir/pods.json" 2>/dev/null || true) &
  (kc get hpa -A -o json > "$tmpdir/hpa.json" 2>/dev/null || true) &
  (kc get pvc -A -o json > "$tmpdir/pvc.json" 2>/dev/null || true) &
  (kc get services -A -o json > "$tmpdir/svc.json" 2>/dev/null || true) &
  (kc get endpoints -A -o json > "$tmpdir/ep.json" 2>/dev/null || true) &
  (kc get secrets -A --field-selector type=kubernetes.io/tls -o json > "$tmpdir/tls.json" 2>/dev/null || true) &
  if command -v helm >/dev/null 2>&1; then
    (helm list -A -o json > "$tmpdir/helm.json" 2>/dev/null || true) &
  fi
  wait
  log "  Core resources collected."

  # ── Phase 2: Universal CRD health scan ──
  log "  Scanning CRDs..."
  local crd_json crd_count
  crd_json=$(kc get crd -o json 2>/dev/null || echo '{"items":[]}')
  crd_count=$(echo "$crd_json" | jq '.items | length')

  mkdir -p "$tmpdir/crds"
  : > "$tmpdir/crd_results.jsonl"

  if [[ "$crd_count" -gt 0 ]]; then
    # Parallel fetch all CRD instances (max 10 concurrent)
    while IFS=$'\t' read -r resource plural group; do
      (kc get "$resource" -A -o json > "$tmpdir/crds/${plural}.${group}.json" 2>/dev/null \
        || echo '{"items":[]}' > "$tmpdir/crds/${plural}.${group}.json") &
      while [[ $(jobs -rp | wc -l) -ge 10 ]]; do sleep 0.1; done
    done < <(echo "$crd_json" | jq -r '.items[] | "\(.spec.names.plural).\(.spec.group)\t\(.spec.names.plural)\t\(.spec.group)"')
    wait

    # Classify health for each CRD type with instances
    while IFS=$'\t' read -r resource plural group; do
      local json_file="$tmpdir/crds/${plural}.${group}.json"
      [[ ! -f "$json_file" ]] && continue
      local total
      total=$(jq '.items | length' "$json_file")
      [[ "$total" -eq 0 ]] && continue

      jq -c --arg resource "$resource" --arg gp "$GOOD_PHASES" '
        [.items[] | select(
          (.status.conditions // [] | any(
            (.type | test("^(Ready|Available|Active|Synced|Established|Programmed)$"; "i")) and .status == "False"))
          or (.status.conditions // [] | any(
            (.type | test("Error|Failed|Invalid|Degraded"; "i")) and .status == "True"))
          or (.metadata.generation != null and .status.observedGeneration != null and
              .metadata.generation != .status.observedGeneration)
          or (.metadata.generation as $gen |
              .status.conditions // [] | any(.observedGeneration != null and .observedGeneration != $gen))
          or (.status.phase != null and (.status.phase | test("^(\($gp))$"; "i") | not))
        )] as $bad |
        {
          resource: $resource,
          total: (.items | length),
          healthy: ((.items | length) - ($bad | length)),
          unhealthy: ($bad | length),
          unhealthy_details: [$bad[:5][] | {
            resource: $resource,
            ns: (.metadata.namespace // "-"),
            name: .metadata.name,
            issues: ([
              (.status.conditions // [])[] |
              select(.status == "False" or ((.type | test("Error|Failed|Invalid|Degraded"; "i")) and .status == "True")) |
              "\(.type)=\(.status)"
            ] + (
              if (.metadata.generation != null and .status.observedGeneration != null and
                  .metadata.generation != .status.observedGeneration)
              then ["gen-drift"] else [] end
            ) + (
              if (.status.phase != null and (.status.phase | test("^(\($gp))$"; "i") | not))
              then ["phase=\(.status.phase)"] else [] end
            ))
          }]
        }' "$json_file" >> "$tmpdir/crd_results.jsonl"
    done < <(echo "$crd_json" | jq -r '.items[] | "\(.spec.names.plural).\(.spec.group)\t\(.spec.names.plural)\t\(.spec.group)"')
  fi
  log "  CRD scan complete ($crd_count types)."

  # ── Phase 3: Pre-process into final shapes ──
  log "  Building fingerprint..."

  # Nodes (versions is now an array per nodepool)
  jq '{
    total: (.items | length),
    ready: ([.items[] | select(.status.conditions[]? | .type == "Ready" and .status == "True")] | length),
    by_nodepool: ([.items[] |
      {pool: (.metadata.labels["karpenter.sh/nodepool"] // .metadata.labels["eks.amazonaws.com/nodegroup"] // "unmanaged"),
       version: .status.nodeInfo.kubeletVersion}] |
      group_by(.pool) | map({key: .[0].pool, value: {count: length, versions: ([.[].version] | unique)}}) | from_entries)
  }' "$tmpdir/nodes.json" > "$tmpdir/f_nodes.json"

  # Workloads
  jq '[.items[] | select(.kind == "Deployment") | {ns: .metadata.namespace, name: .metadata.name, desired: (.spec.replicas // 1), ready: (.status.readyReplicas // 0), available: (.status.availableReplicas // 0)}]' "$tmpdir/workloads.json" > "$tmpdir/f_deploy.json"
  jq '[.items[] | select(.kind == "StatefulSet") | {ns: .metadata.namespace, name: .metadata.name, desired: (.spec.replicas // 1), ready: (.status.readyReplicas // 0)}]' "$tmpdir/workloads.json" > "$tmpdir/f_sts.json"
  jq '[.items[] | {ns: .metadata.namespace, name: .metadata.name, desired: .status.desiredNumberScheduled, ready: (.status.numberReady // 0), available: (.status.numberAvailable // 0)}]' "$tmpdir/ds.json" > "$tmpdir/f_ds.json"

  # Pods — single JSON, extract all counters
  local pods_total pods_failed pods_crash pods_pending pods_hr pods_oom
  pods_total=$(jq '.items | length' "$tmpdir/pods.json")
  pods_failed=$(jq '[.items[] | select(.status.phase == "Failed")] | length' "$tmpdir/pods.json")
  pods_crash=$(jq '[.items[] | select(
    [(.status.containerStatuses // [])[], (.status.initContainerStatuses // [])[]]
    | any(.state.waiting.reason == "CrashLoopBackOff")
  )] | length' "$tmpdir/pods.json")
  pods_pending=$(jq '[.items[] | select(.status.phase == "Pending")] | length' "$tmpdir/pods.json")
  pods_hr=$(jq '[.items[] | select(
    [(.status.containerStatuses // [])[], (.status.initContainerStatuses // [])[]]
    | any(.restartCount > 5)
  )] | length' "$tmpdir/pods.json")
  pods_oom=$(jq '[.items[] | select(
    [(.status.containerStatuses // [])[], (.status.initContainerStatuses // [])[]]
    | any(.lastState.terminated.reason == "OOMKilled")
  )] | length' "$tmpdir/pods.json")

  # PVCs
  local pvc_total pvc_unbound
  pvc_total=$(jq '.items | length' "$tmpdir/pvc.json")
  pvc_unbound=$(jq '[.items[] | select(.status.phase != "Bound")] | length' "$tmpdir/pvc.json")

  # HPA
  jq '[.items[] | {ns: .metadata.namespace, name: .metadata.name, targetRef: "\(.spec.scaleTargetRef.kind)/\(.spec.scaleTargetRef.name)", minReplicas: (.spec.minReplicas // 1), maxReplicas: .spec.maxReplicas, currentReplicas: (.status.currentReplicas // 0)}]' "$tmpdir/hpa.json" > "$tmpdir/f_hpa.json"

  # Helm
  jq 'if type == "array" then [.[] | {ns: .namespace, name: .name, chart: .chart, app_version: .app_version, status: .status}] else [] end' "$tmpdir/helm.json" > "$tmpdir/f_helm.json"

  # Services without endpoints
  local svc_with_sel svc_no_ep
  svc_with_sel=$(jq '[.items[] | select(
    .spec.type != "ExternalName" and .spec.clusterIP != "None" and
    ((.spec.selector // {}) | length) > 0
  )] | length' "$tmpdir/svc.json")

  svc_no_ep=$(jq -n --slurpfile svc "$tmpdir/svc.json" --slurpfile ep "$tmpdir/ep.json" '
    ($ep[0].items | map({
      key: "\(.metadata.namespace)/\(.metadata.name)",
      value: ([(.subsets // [])[] | (.addresses // [])[] ] | length)
    }) | from_entries) as $ep_map |
    [$svc[0].items[] | select(
      .spec.type != "ExternalName" and .spec.clusterIP != "None" and
      ((.spec.selector // {}) | length) > 0 and
      ($ep_map["\(.metadata.namespace)/\(.metadata.name)"] // 0) == 0
    )] | length')

  # TLS certificates
  local tls_total tls_expired tls_expiring
  tls_total=0; tls_expired=0; tls_expiring=0
  if command -v openssl >/dev/null 2>&1; then
    tls_total=$(jq '.items | length' "$tmpdir/tls.json")
    if [[ "$tls_total" -gt 0 ]]; then
      local now_epoch warn_epoch
      now_epoch=$(date +%s)
      warn_epoch=$((now_epoch + 30 * 86400))
      while IFS=$'\t' read -r _ns _name cert_b64; do
        [[ -z "$cert_b64" || "$cert_b64" == "null" ]] && continue
        local expiry expiry_epoch
        expiry=$(echo "$cert_b64" | base64 -d 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')
        [[ -z "$expiry" ]] && continue
        expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null)
        [[ -z "$expiry_epoch" ]] && continue
        if [[ "$expiry_epoch" -lt "$now_epoch" ]]; then
          tls_expired=$((tls_expired + 1))
        elif [[ "$expiry_epoch" -lt "$warn_epoch" ]]; then
          tls_expiring=$((tls_expiring + 1))
        fi
      done < <(jq -r '.items[] | [.metadata.namespace, .metadata.name, (.data."tls.crt" // "")] | @tsv' "$tmpdir/tls.json")
    fi
  fi

  # CRD health assembly
  if [[ -s "$tmpdir/crd_results.jsonl" ]]; then
    jq -s --argjson n "$crd_count" '{
      scanned_types: $n,
      types: (map({key: .resource, value: {total: .total, healthy: .healthy, unhealthy: .unhealthy}}) | from_entries),
      unhealthy: [.[] | .unhealthy_details[]]
    }' "$tmpdir/crd_results.jsonl" > "$tmpdir/f_crd_health.json"
  else
    echo "{\"scanned_types\": $crd_count, \"types\": {}, \"unhealthy\": []}" > "$tmpdir/f_crd_health.json"
  fi

  # ── Final assembly ──
  jq -n \
    --arg context "$context" \
    --arg k8s_version "$k8s_ver" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg ts_local "$(date '+%Y-%m-%d %H:%M:%S')" \
    --argjson pods_total "${pods_total:-0}" \
    --argjson pods_failed "${pods_failed:-0}" \
    --argjson pods_crash "${pods_crash:-0}" \
    --argjson pods_pending "${pods_pending:-0}" \
    --argjson pods_hr "${pods_hr:-0}" \
    --argjson pods_oom "${pods_oom:-0}" \
    --argjson pvc_total "${pvc_total:-0}" \
    --argjson pvc_unbound "${pvc_unbound:-0}" \
    --argjson svc_with_sel "${svc_with_sel:-0}" \
    --argjson svc_no_ep "${svc_no_ep:-0}" \
    --argjson tls_total "${tls_total:-0}" \
    --argjson tls_expired "${tls_expired:-0}" \
    --argjson tls_expiring "${tls_expiring:-0}" \
    --slurpfile nodes "$tmpdir/f_nodes.json" \
    --slurpfile deployments "$tmpdir/f_deploy.json" \
    --slurpfile statefulsets "$tmpdir/f_sts.json" \
    --slurpfile daemonsets "$tmpdir/f_ds.json" \
    --slurpfile hpa "$tmpdir/f_hpa.json" \
    --slurpfile helm "$tmpdir/f_helm.json" \
    --slurpfile crd_health "$tmpdir/f_crd_health.json" \
  '{
    meta: {
      schema_version: 2,
      context: $context,
      k8s_version: $k8s_version,
      timestamp: $timestamp,
      timestamp_local: $ts_local
    },
    nodes: $nodes[0],
    pods: { total: $pods_total, failed: $pods_failed, crashloop: $pods_crash, pending: $pods_pending, high_restarts: $pods_hr, oomkilled: $pods_oom },
    pvcs: { total: $pvc_total, unbound: $pvc_unbound },
    workloads: { deployments: $deployments[0], statefulsets: $statefulsets[0], daemonsets: $daemonsets[0] },
    hpa: $hpa[0],
    helm: $helm[0],
    services: { with_selector: $svc_with_sel, no_endpoints: $svc_no_ep },
    tls: { total: $tls_total, expired: $tls_expired, expiring_30d: $tls_expiring },
    crd_health: $crd_health[0]
  }' > "$outfile"

  rm -rf "$tmpdir"
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

  local cmpdir
  cmpdir=$(mktemp -d)

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

  ISSUES=0

  _cmp_meta     "$file_a" "$file_b"
  _cmp_nodes    "$file_a" "$file_b" "$cmpdir"
  _cmp_pods     "$file_a" "$file_b"
  _cmp_pvcs     "$file_a" "$file_b"
  _cmp_workloads "$file_a" "$file_b" "$cmpdir"
  _cmp_hpa      "$file_a" "$file_b" "$cmpdir"
  _cmp_helm     "$file_a" "$file_b" "$cmpdir"
  _cmp_services "$file_a" "$file_b"
  _cmp_tls      "$file_a" "$file_b"
  _cmp_crd_health "$file_a" "$file_b" "$cmpdir"

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ "$ISSUES" -eq 0 ]]; then
    echo -e "${G}No regressions detected.${N}"
  else
    echo -e "${R}$ISSUES issue(s) detected.${N} Review CRITICAL and HIGH items above."
  fi

  rm -rf "$cmpdir"
  [[ "$ISSUES" -eq 0 ]] && return 0 || return 1
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
    latest=$(ls -1t "$STATE_DIR"/"${context}"_*.json 2>/dev/null | head -1 || true)
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
    local schema
    schema=$(jq '.meta.schema_version // 1' "$f" 2>/dev/null)

    if [[ "$ctx" != "$prev_ctx" ]]; then
      echo ""
      echo -e "${B}$ctx${N} (k8s $ver)"
      prev_ctx="$ctx"
    fi
    echo -e "  $ts  nodes=$nodes pods=$pods schema=v$schema  ${DIM}$(basename "$f")${N}"
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
    files=$(ls -1t "$STATE_DIR"/"${ctx}"_*.json 2>/dev/null)
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
  head -38 "${BASH_SOURCE[0]}" | tail -n +2 | sed 's/^# \?//'
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
