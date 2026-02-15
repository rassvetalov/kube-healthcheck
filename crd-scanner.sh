#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# CRD Health Scanner — find unhealthy CRs and orphaned CRDs
# ═══════════════════════════════════════════════════════════════════
#
# USAGE:
#   ./crd-scanner.sh                    # Run both checks
#   ./crd-scanner.sh --not-ready        # Only: CRs in not-ready state
#   ./crd-scanner.sh --orphans          # Only: orphaned CRDs
#   ./crd-scanner.sh --context CTX      # Use specific kubectl context
#   ./crd-scanner.sh -q, --quiet        # Only show problems (skip OK lines)
#   ./crd-scanner.sh -h, --help         # Show this help
#
# WHAT IT CHECKS:
#
#   1. NOT-READY CUSTOM RESOURCES:
#      Scans ALL CRDs and finds CR instances where:
#      - status.conditions has Ready/Available/Synced = False
#      - status.conditions has Error/Failed/Degraded = True
#      - metadata.generation != status.observedGeneration (drift)
#
#   2. ORPHANED CRDs:
#      Finds CRDs whose controller is likely not running:
#      - CRD has status subresource + instances, but ALL have empty .status
#      - CRD has instances with observedGeneration stuck at null
#        while controller should be tracking it
#      - CRD's API group has no matching running operator pod
#
# EXAMPLES:
#   # Quick scan before upgrade
#   ./crd-scanner.sh -q
#
#   # Check only cert-manager and keda health
#   ./crd-scanner.sh --not-ready
#
#   # Find leftover CRDs after operator removal
#   ./crd-scanner.sh --orphans
#
# ═══════════════════════════════════════════════════════════════════

set -uo pipefail

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[1;34m' DIM='\033[2m' N='\033[0m'

CHECK_READY=true
CHECK_ORPHANS=true
QUIET=false
KUBE_CONTEXT=""
MAX_PARALLEL=10

while [[ $# -gt 0 ]]; do
  case "$1" in
    --not-ready)   CHECK_READY=true; CHECK_ORPHANS=false; shift;;
    --orphans)     CHECK_READY=false; CHECK_ORPHANS=true; shift;;
    --context)     KUBE_CONTEXT="$2"; shift 2;;
    -q|--quiet)    QUIET=true; shift;;
    -h|--help)     head -38 "$0" | tail -35; exit 0;;
    *) shift;;
  esac
done

kc() {
  if [[ -n "$KUBE_CONTEXT" ]]; then
    kubectl --context "$KUBE_CONTEXT" "$@"
  else
    kubectl "$@"
  fi
}

CONTEXT=$(kc config current-context 2>/dev/null || echo "unknown")

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CRD HEALTH SCANNER"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Cluster: $CONTEXT | Time: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ── Phase 1: Collect all CRD metadata ──────────────────────────
CRD_JSON=$(kc get crd -o json 2>/dev/null)
CRD_COUNT=$(echo "$CRD_JSON" | jq '.items | length')
echo -e "Scanning ${B}$CRD_COUNT${N} CRDs..."

# Build list: resource.group hasStatus scope
CRD_LIST=$(echo "$CRD_JSON" | jq -r '.items[] | {
    resource: "\(.spec.names.plural).\(.spec.group)",
    plural: .spec.names.plural,
    group: .spec.group,
    hasStatus: ([.spec.versions[]? | .subresources.status != null] | any),
    scope: .spec.scope
  } | "\(.resource)\t\(.plural)\t\(.group)\t\(.hasStatus)\t\(.scope)"')

# ── Phase 2: Fetch all CR instances in parallel ────────────────
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

TOTAL_CRDS=$(echo "$CRD_LIST" | wc -l)
DONE=0

fetch_crd() {
  local resource="$1" outfile="$2"
  kc get "$resource" -A -o json 2>/dev/null > "$outfile" || echo '{"items":[]}' > "$outfile"
}

while IFS=$'\t' read -r resource plural group hasStatus scope; do
  outfile="$TMPDIR/${plural}.${group}.json"
  meta="$TMPDIR/${plural}.${group}.meta"
  echo -e "${hasStatus}\t${group}\t${plural}\t${resource}" > "$meta"

  fetch_crd "$resource" "$outfile" &

  # Limit parallelism
  while [[ $(jobs -r | wc -l) -ge $MAX_PARALLEL ]]; do
    sleep 0.1
  done

  DONE=$((DONE + 1))
  if [[ "$QUIET" == "false" ]]; then
    printf "\r  Progress: %d/%d CRDs fetched..." "$DONE" "$TOTAL_CRDS" >&2
  fi
done <<< "$CRD_LIST"
wait
[[ "$QUIET" == "false" ]] && printf "\r  Progress: %d/%d CRDs fetched. Done.     \n" "$TOTAL_CRDS" "$TOTAL_CRDS" >&2
echo ""

# ── Phase 3: Analyze — Not-Ready CRs ──────────────────────────
if [[ "$CHECK_READY" == "true" ]]; then
  echo "1️⃣  NOT-READY CUSTOM RESOURCES:"
  echo ""

  NOT_READY_TOTAL=0
  CRDS_WITH_ISSUES=0

  for meta_file in "$TMPDIR"/*.meta; do
    IFS=$'\t' read -r hasStatus group plural resource < "$meta_file"
    json_file="$TMPDIR/${plural}.${group}.json"
    [[ ! -f "$json_file" ]] && continue

    total=$(jq '.items | length' "$json_file")
    [[ "$total" -eq 0 ]] && continue

    # Find CRs with bad conditions or observedGeneration drift
    not_ready_items=$(jq '[.items[] | select(
      # Ready/Available/Synced/Established = False
      (.status.conditions // [] | any(
        (.type | test("^(Ready|Available|Synced|Established|Programmed)$"; "i")) and .status == "False"
      ))
      or
      # Error/Failed/Degraded/Invalid = True
      (.status.conditions // [] | any(
        (.type | test("Error|Failed|Invalid|Degraded"; "i")) and .status == "True"
      ))
      or
      # observedGeneration drift (top-level status)
      (
        .metadata.generation != null and
        .status.observedGeneration != null and
        .metadata.generation != .status.observedGeneration
      )
      or
      # observedGeneration drift (inside conditions)
      (
        .metadata.generation as $gen |
        .status.conditions // [] | any(
          .observedGeneration != null and .observedGeneration != $gen
        )
      )
    )]' "$json_file")

    count=$(echo "$not_ready_items" | jq 'length')
    [[ "$count" -eq 0 ]] && continue

    NOT_READY_TOTAL=$((NOT_READY_TOTAL + count))
    CRDS_WITH_ISSUES=$((CRDS_WITH_ISSUES + 1))

    echo -e "  ${R}✗${N} ${B}${resource}${N} — $count/$total not ready:"

    # Show details for each not-ready CR
    echo "$not_ready_items" | jq -r '.[] | {
        ns: .metadata.namespace,
        name: .metadata.name,
        gen: .metadata.generation,
        obsGen: .status.observedGeneration,
        badConditions: [
          (.status.conditions // [] | .[] |
            select(
              ((.type | test("^(Ready|Available|Synced|Established|Programmed)$"; "i")) and .status == "False")
              or
              ((.type | test("Error|Failed|Invalid|Degraded"; "i")) and .status == "True")
            ) | "\(.type)=\(.status) (\(.reason // "?"))"
          )
        ],
        genDrift: (
          if .metadata.generation != null and .status.observedGeneration != null and .metadata.generation != .status.observedGeneration
          then "gen=\(.metadata.generation)/obs=\(.status.observedGeneration)"
          else null end
        )
      } | "    \(.ns)/\(.name)"
        + (if (.badConditions | length) > 0 then " [\(.badConditions | join(", "))]" else "" end)
        + (if .genDrift != null then " [\(.genDrift)]" else "" end)
    ' 2>/dev/null | head -10

    echo ""
  done

  if [[ "$NOT_READY_TOTAL" -eq 0 ]]; then
    echo -e "  All custom resources healthy ${G}✓${N}"
  else
    echo -e "  Total: ${R}$NOT_READY_TOTAL${N} not-ready CRs across $CRDS_WITH_ISSUES CRD types"
  fi
  echo ""
fi

# ── Phase 4: Analyze — Orphaned CRDs ──────────────────────────
if [[ "$CHECK_ORPHANS" == "true" ]]; then
  echo "2️⃣  ORPHANED CRDs (controller likely not running):"
  echo ""

  # Get all running deployments and statefulsets for cross-reference
  ALL_CONTROLLERS=$(kc get deployments,statefulsets -A -o json 2>/dev/null | jq -r '[.items[] | {
    ns: .metadata.namespace,
    name: .metadata.name,
    ready: (.status.readyReplicas // 0),
    # Normalize name: remove hyphens for fuzzy matching
    nameNorm: (.metadata.name | ascii_downcase | gsub("-";"")),
    labelVals: [(.metadata.labels // {} | to_entries[].value | ascii_downcase | gsub("-";""))]
  }]')

  # Extract keywords from API group for controller matching.
  # "operator.victoriametrics.com" → ["operator","victoriametrics"]
  # "cert-manager.io" → ["certmanager"]
  # "capacity.playrix.com" → ["capacity","playrix"]
  # Tries all group parts (minus TLD), both raw and hyphen-stripped.
  has_running_controller() {
    local group="$1"
    local stripped
    stripped=$(echo "$group" | sed 's/\.io$//; s/\.sh$//; s/\.com$//; s/\.aws$//; s/\.k8s$//')

    # Generate keywords: each dot-separated part, normalized (no hyphens)
    local keywords
    keywords=$(echo "$stripped" | tr '.' '\n' | while read -r part; do
      echo "$part" | tr -d '-'
    done | sort -u)

    for kw in $keywords; do
      # Skip very short keywords (< 4 chars) — too generic
      [[ ${#kw} -lt 4 ]] && continue

      local match
      match=$(echo "$ALL_CONTROLLERS" | jq --arg kw "$kw" '[.[] | select(
        .ready > 0 and (
          (.nameNorm | contains($kw)) or
          (.labelVals[] | contains($kw))
        )
      )] | length')

      [[ "$match" -gt 0 ]] && return 0
    done
    return 1
  }

  ORPHAN_COUNT=0

  for meta_file in "$TMPDIR"/*.meta; do
    IFS=$'\t' read -r hasStatus group plural resource < "$meta_file"
    json_file="$TMPDIR/${plural}.${group}.json"
    [[ ! -f "$json_file" ]] && continue

    # Skip CRDs without status subresource — they don't use reconciliation
    [[ "$hasStatus" != "true" ]] && continue

    # Skip well-known k8s-internal groups
    case "$group" in
      apiextensions.k8s.io|apiregistration.k8s.io) continue ;;
    esac
    # Skip *.k8s.io (EKS/AWS/networking built-ins)
    [[ "$group" == *.k8s.io ]] && continue

    total=$(jq '.items | length' "$json_file")

    # Check 0: CRD has 0 instances AND no running controller → leftover CRD definition
    if [[ "$total" -eq 0 ]]; then
      if ! has_running_controller "$group"; then
        # Track per API group to report once (e.g. 11 Kong CRDs → one line)
        orphan_group_file="$TMPDIR/_orphan_groups_${group//[^a-zA-Z0-9]/_}"
        echo "$resource" >> "$orphan_group_file"
      fi
      continue
    fi

    # Check 1: ALL instances have completely empty status
    empty_status=$(jq '[.items[] | select(
      (.status == null) or (.status == {}) or
      ((.status | keys | length) == 0)
    )] | length' "$json_file")

    if [[ "$empty_status" -eq "$total" ]]; then
      # Only flag if no running controller found (otherwise it's by design)
      if ! has_running_controller "$group"; then
        ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
        echo -e "  ${R}✗${N} ${B}${resource}${N} — $total instances, ALL with empty status, no controller"
        echo -e "    ${DIM}Controller never reconciled these resources${N}"
        jq -r '.items[:5][] | "    \(.metadata.namespace // "-")/\(.metadata.name) (age: \(.metadata.creationTimestamp))"' "$json_file"
        echo ""
      elif [[ "$QUIET" == "false" ]]; then
        echo -e "  ${DIM}ℹ ${resource} — $total instances, empty status (controller running, likely by design)${N}"
      fi
      continue
    fi

    # Check 2: Some instances use observedGeneration, but some are stuck
    has_obs_gen=$(jq '[.items[] | select(.status.observedGeneration != null)] | length' "$json_file")
    if [[ "$has_obs_gen" -gt 0 ]]; then
      stuck=$(jq '[.items[] | select(
        .metadata.generation != null and
        .metadata.generation > 1 and
        (.status.observedGeneration == null or .status.observedGeneration == 0)
      )] | length' "$json_file")

      if [[ "$stuck" -gt 0 ]]; then
        ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
        echo -e "  ${Y}!${N} ${B}${resource}${N} — $stuck/$total instances with stale observedGeneration"
        echo -e "    ${DIM}Controller may have stopped reconciling${N}"
        jq -r '.items[] | select(
          .metadata.generation > 1 and
          (.status.observedGeneration == null or .status.observedGeneration == 0)
        ) | "    \(.metadata.namespace // "-")/\(.metadata.name) (gen=\(.metadata.generation), obsGen=\(.status.observedGeneration // "null"))"' "$json_file" | head -5
        echo ""
      fi
    fi

    # Check 3: Instances have conditions (controller was active at some point)
    # but no matching controller is running now
    has_conditions=$(jq '[.items[] | select((.status.conditions // []) | length > 0)] | length' "$json_file")
    if [[ "$has_conditions" -gt 0 ]]; then
      if ! has_running_controller "$group"; then
        ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
        echo -e "  ${Y}!${N} ${B}${resource}${N} — $total instances, no running controller for ${DIM}$group${N}"
        jq -r '.items[:3][] | "    \(.metadata.namespace // "-")/\(.metadata.name)"' "$json_file"
        echo ""
      fi
    fi
  done

  # Report orphaned CRD definitions (0 instances, no controller) grouped by API group
  shopt -s nullglob
  for gfile in "$TMPDIR"/_orphan_groups_*; do
    crds_in_group=$(sort -u "$gfile")
    crd_count=$(echo "$crds_in_group" | wc -l)
    first_crd=$(echo "$crds_in_group" | head -1)
    group_name=$(echo "$first_crd" | sed 's/^[^.]*\.//')

    ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
    echo -e "  ${Y}!${N} ${B}${group_name}${N} — $crd_count orphaned CRD definitions, 0 instances, no controller"
    echo -e "    ${DIM}CRDs left after operator removal — safe to delete${N}"
    echo "$crds_in_group" | head -5 | while read -r c; do echo "    $c"; done
    [[ "$crd_count" -gt 5 ]] && echo "    ... and $((crd_count - 5)) more"
    echo ""
  done
  shopt -u nullglob

  if [[ "$ORPHAN_COUNT" -eq 0 ]]; then
    echo -e "  No orphaned CRDs detected ${G}✓${N}"
  else
    echo -e "  Total: ${R}$ORPHAN_COUNT${N} potentially orphaned CRD types"
  fi
  echo ""
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Scan complete."
