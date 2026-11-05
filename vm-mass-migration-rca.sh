#!/usr/bin/env bash
# =============================================================================
# OpenShift Virtualization — mass VM migration RCA against namespace inspects
# =============================================================================
# Usage:
#   ./vm-mass-migration-rca.sh /path/to/inspect.local.* [/path/to/another ...]
#   ./vm-mass-migration-rca.sh /path/to/dir-with-many-inspects
#   WINDOW_START="2026-10-27T18:00:00Z" WINDOW_END="2026-10-28T06:00:00Z" \
#     ./vm-mass-migration-rca.sh ./inspects
#
# Optional env:
#   WINDOW_START / WINDOW_END  ISO8601 UTC window to focus (default: last 24h from inspect timestamp if present)
#   OUT_DIR                    report output dir (default: ./rca-out-<timestamp>)
# =============================================================================
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <inspect-dir|parent-of-inspects> [more...]" >&2
  exit 1
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need rg
need python3

OUT_DIR="${OUT_DIR:-./rca-out-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT_DIR"/{summary,migrations,triggers,logs,timeline}
REPORT="$OUT_DIR/RCA-SUMMARY.md"

# Collect inspect roots (dirs that contain namespaces/ or are inspect.local.*)
collect_roots() {
  local arg
  for arg in "$@"; do
    if [[ -d "$arg/namespaces" ]]; then
      printf '%s\n' "$arg"
    elif [[ -d "$arg" ]]; then
      find "$arg" -maxdepth 3 -type d \( -name 'inspect.local.*' -o -name 'must-gather*' \) 2>/dev/null
      # also treat any child that has namespaces/
      find "$arg" -maxdepth 3 -type d -name namespaces 2>/dev/null | while read -r ns; do dirname "$ns"; done
    fi
  done | awk 'NF' | sort -u
}

mapfile -t ROOTS < <(collect_roots "$@")
if [[ ${#ROOTS[@]} -eq 0 ]]; then
  echo "No inspect roots found under: $*" >&2
  exit 1
fi

echo "# Mass VM Migration RCA" >"$REPORT"
echo >>"$REPORT"
echo "- Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$REPORT"
echo "- Inspect roots: ${#ROOTS[@]}" >>"$REPORT"
echo >>"$REPORT"

echo "== Inspect roots =="
printf ' - %s\n' "${ROOTS[@]}"
echo

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
section() { echo; echo "=== $* ==="; echo >>"$REPORT"; echo "## $*" >>"$REPORT"; echo >>"$REPORT"; }

append_note() { printf '%s\n' "$*" >>"$REPORT"; }

# Search all inspects for a pattern; write hits file
search_all() {
  local label="$1" pattern="$2" out="$3"
  : >"$out"
  local root
  for root in "${ROOTS[@]}"; do
    rg -n -i --no-messages -g '!*.gz' -g '!*.tar' -g '!*.zip' -e "$pattern" "$root" 2>/dev/null \
      | sed "s|^|[$(basename "$root")] |" >>"$out" || true
  done
  local n
  n=$(wc -l <"$out" | tr -d ' ')
  append_note "- **${label}**: ${n} hits → \`${out#$OUT_DIR/}\`"
  echo "$label: $n hits → $out"
}

# -----------------------------------------------------------------------------
# 1) Inventory of namespaces / virt APIs present
# -----------------------------------------------------------------------------
section "1) Inspect inventory"
{
  echo '```'
  for root in "${ROOTS[@]}"; do
    echo "ROOT: $root"
    [[ -f "$root/timestamp" ]] && echo "  timestamp: $(cat "$root/timestamp")"
    if [[ -d "$root/namespaces" ]]; then
      echo "  namespaces ($(ls "$root/namespaces" | wc -l | tr -d ' ')):"
      ls "$root/namespaces" | sed 's/^/    - /'
    fi
  done
  echo '```'
} | tee -a "$REPORT" >/dev/null
append_note ""

# -----------------------------------------------------------------------------
# 2) Migration objects & events (primary signal)
# -----------------------------------------------------------------------------
section "2) Migration objects and events (primary signal)"

search_all "VirtualMachineInstanceMigration YAML" \
  'kind:[[:space:]]*VirtualMachineInstanceMigration|VirtualMachineInstanceMigration' \
  "$OUT_DIR/migrations/vmim-refs.txt"

search_all "MigrationSucceeded / MigrationFailed events" \
  'MigrationSucceeded|MigrationFailed|Migrating|LiveMigration|TargetPod|SourcePod' \
  "$OUT_DIR/migrations/migration-events.txt"

search_all "VMI migration state fields" \
  'migrationState:|completed:|failed:|startTimestamp:|endTimestamp:|reason:|mode:.*(Live|Offline)' \
  "$OUT_DIR/migrations/vmi-migration-state.txt"

# Extract VMIM summaries with python (best-effort across yaml dumps)
python3 - "$OUT_DIR" "${ROOTS[@]}" <<'PY' >>"$REPORT" 2>"$OUT_DIR/migrations/extract-errors.txt" || true
import os, sys, json, re
from pathlib import Path

out_dir = Path(sys.argv[1])
roots = [Path(p) for p in sys.argv[2:]]
rows = []

def load_yaml_docs(text):
    # Minimal split on --- ; avoid requiring PyYAML
    docs = []
    cur = []
    for line in text.splitlines():
        if line.strip() == "---":
            if cur:
                docs.append("\n".join(cur))
                cur = []
        else:
            cur.append(line)
    if cur:
        docs.append("\n".join(cur))
    return docs

def field(doc, key):
    m = re.search(rf'(?m)^{re.escape(key)}:\s*(.*)$', doc)
    return m.group(1).strip().strip('"') if m else ""

for root in roots:
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        name = path.name.lower()
        if not (name.endswith(".yaml") or name.endswith(".yml") or "event" in name):
            continue
        try:
            text = path.read_text(errors="ignore")
        except Exception:
            continue
        if "VirtualMachineInstanceMigration" not in text and "kind: VirtualMachineInstanceMigration" not in text:
            # still scan events later
            pass
        for doc in load_yaml_docs(text):
            if re.search(r'(?m)^kind:\s*VirtualMachineInstanceMigration\s*$', doc):
                rows.append({
                    "root": root.name,
                    "file": str(path),
                    "name": field(doc, "name") or field(doc, "  name"),
                    "namespace": field(doc, "namespace") or field(doc, "  namespace"),
                    "phase": field(doc, "phase") or field(doc, "  phase"),
                    "created": field(doc, "creationTimestamp") or field(doc, "  creationTimestamp"),
                })

# Also grep-ish parse of events mentioning migrations
event_hits = []
pat = re.compile(r'(MigrationSucceeded|MigrationFailed|Migrating VirtualMachineInstance|Created migration)', re.I)
for root in roots:
    for path in root.rglob("*events*.yaml"):
        try:
            text = path.read_text(errors="ignore")
        except Exception:
            continue
        for i, line in enumerate(text.splitlines(), 1):
            if pat.search(line):
                event_hits.append(f"{root.name}:{path}:{i}:{line.strip()[:240]}")

print(f"- Parsed VMIM-like docs: **{len(rows)}**")
print(f"- Migration-related event lines: **{len(event_hits)}**")
print()
if rows:
    print("### VMIM objects (best-effort parse)")
    print()
    print("| root | namespace | name | phase | created |")
    print("|------|-----------|------|-------|---------|")
    for r in sorted(rows, key=lambda x: (x.get("created") or "", x.get("namespace") or "", x.get("name") or ""))[:200]:
        print(f"| {r['root']} | {r['namespace']} | {r['name']} | {r['phase']} | {r['created']} |")
    if len(rows) > 200:
        print(f"| ... | ... | ... | ... | ({len(rows)-200} more) |")
    print()

(out_dir / "migrations" / "vmim-table.json").write_text(json.dumps(rows, indent=2))
(out_dir / "migrations" / "event-lines.txt").write_text("\n".join(event_hits[:5000]))
print(f"- Raw event lines saved to `migrations/event-lines.txt`")
print()
PY

# -----------------------------------------------------------------------------
# 3) Trigger classes (ranked hypotheses for ALL namespaces + BOTH sites)
# -----------------------------------------------------------------------------
section "3) Trigger hunt (cluster-wide hypotheses)"

append_note "Mass migration across **all namespaces** and **both DC+DRC** is usually **not** random per-VM noise. Ranked causes:"
append_note ""
append_note "1. **Kube Descheduler** profile \`KubeVirtRelieveAndMigrate\` / soft-tainter"
append_note "2. **Node drain / cordon / MachineConfig reboot / MCP** rolling update"
append_note "3. **Node NotReady / pressure / eviction** wave"
append_note "4. **Manual or automated VirtualMachineInstanceMigration** (script/operator/CD)"
append_note "5. **Workload update** (VM template / DataVolume / HCO / SSP) causing restarts misread as migrations"
append_note ""

search_all "Descheduler / KubeVirtRelieveAndMigrate" \
  'KubeVirtRelieveAndMigrate|DevKubeVirtRelieveAndMigrate|openshift-kube-descheduler|soft-tainter|softtainter|descheduler|LowNodeUtilization|EvictionsInBackground|descheduler\.alpha\.kubernetes\.io' \
  "$OUT_DIR/triggers/descheduler.txt"

search_all "Soft taints / PreferNoSchedule" \
  'descheduler\.openshift\.io|PreferNoSchedule|soft.?taint|LoadAverage|PSI|node\.kubernetes\.io/unschedulable' \
  "$OUT_DIR/triggers/soft-taints.txt"

search_all "Node drain / cordon / unschedulable" \
  'SchedulingDisabled|cordon|drain|NodeNotReady|NodeReady|Evicted|TaintManagerEviction|DeletionCandidateOf|machineconfiguration\.openshift\.io' \
  "$OUT_DIR/triggers/drain-cordon.txt"

search_all "MachineConfig / MCP / reboot" \
  'MachineConfigPool|rendered-worker|Drain|reboot|Rebooting|UpdatedMachineConfig|mcp-|machine-config-daemon' \
  "$OUT_DIR/triggers/mcp.txt"

search_all "KubeVirt / HCO / SSP controllers" \
  'kubevirt|hyperconverged|ssp-operator|virt-controller|virt-handler|MigrationConfig|parallelMigrationsPerCluster|liveMigration' \
  "$OUT_DIR/triggers/kubevirt.txt"

search_all "Node pressure / disk / memory" \
  'MemoryPressure|DiskPressure|PIDPressure|NodeHasDiskPressure|eviction manager|signal: killed|OOMKilled' \
  "$OUT_DIR/triggers/pressure.txt"

# -----------------------------------------------------------------------------
# 4) Descheduler CR / policy if inspect includes operator ns
# -----------------------------------------------------------------------------
section "4) Descheduler configuration (if present in inspects)"

: >"$OUT_DIR/triggers/descheduler-config-extract.txt"
for root in "${ROOTS[@]}"; do
  for ns in openshift-kube-descheduler-operator kube-descheduler descheduler; do
    base="$root/namespaces/$ns"
    [[ -d "$base" ]] || continue
    echo "FOUND_NS $base" >>"$OUT_DIR/triggers/descheduler-config-extract.txt"
    rg -n -i 'profiles:|KubeVirtRelieveAndMigrate|deschedulingInterval|evictionLimits|devActualUtilization|devLowNodeUtilization|soft' \
      "$base" 2>/dev/null >>"$OUT_DIR/triggers/descheduler-config-extract.txt" || true
  done
  # also scan any kubedescheduler CR dumps
  rg -l -i 'kind:[[:space:]]*KubeDescheduler' "$root" 2>/dev/null | while read -r f; do
    echo "CR $f" >>"$OUT_DIR/triggers/descheduler-config-extract.txt"
    rg -n 'profiles:|KubeVirtRelieveAndMigrate|deschedulingInterval|evictionLimits|profileCustomizations' "$f" \
      >>"$OUT_DIR/triggers/descheduler-config-extract.txt" || true
  done
done
n=$(wc -l <"$OUT_DIR/triggers/descheduler-config-extract.txt" | tr -d ' ')
append_note "- Descheduler config extract lines: **$n** → \`triggers/descheduler-config-extract.txt\`"
echo "Descheduler config extract: $n lines"

# -----------------------------------------------------------------------------
# 5) Timeline builder from migration events
# -----------------------------------------------------------------------------
section "5) Timeline (best-effort)"

python3 - "$OUT_DIR" <<'PY' >>"$REPORT" || true
import re
from pathlib import Path
from collections import Counter
out = Path(__import__('sys').argv[1])
lines = (out/"migrations"/"event-lines.txt").read_text(errors="ignore").splitlines() if (out/"migrations"/"event-lines.txt").exists() else []
# pull ISO timestamps
ts_re = re.compile(r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)')
hours = Counter()
for line in lines:
    m = ts_re.search(line)
    if m:
        hours[m.group(1)[:13]] += 1  # YYYY-MM-DDTHH
print("### Event density by hour (UTC)")
print()
if not hours:
    print("_No timestamped migration event lines found in inspects._")
else:
    print("| hour (UTC) | count |")
    print("|------------|------:|")
    for h, c in sorted(hours.items()):
        print(f"| {h}:00Z | {c} |")
print()
(out/"timeline"/"hourly-counts.txt").write_text("\n".join(f"{h} {c}" for h,c in sorted(hours.items())))
PY

# -----------------------------------------------------------------------------
# 6) Gap analysis — what is missing from inspects
# -----------------------------------------------------------------------------
section "6) Gap analysis (what to request if missing)"

have_desched=false
have_virt=false
have_nodes=false
for root in "${ROOTS[@]}"; do
  ls "$root/namespaces" 2>/dev/null | rg -q 'kube-descheduler|openshift-kube-descheduler' && have_desched=true || true
  ls "$root/namespaces" 2>/dev/null | rg -q 'openshift-cnv|openshift-kubevirt|kubevirt' && have_virt=true || true
  [[ -d "$root/cluster-scoped-resources" || -d "$root/nodes" ]] && have_nodes=true || true
done

append_note "| Signal | Present in inspects? | Why needed |"
append_note "|--------|----------------------|------------|"
append_note "| openshift-kube-descheduler-operator | $([[ $have_desched == true ]] && echo YES || echo **NO**) | Confirm \`KubeVirtRelieveAndMigrate\` + soft-tainter |"
append_note "| openshift-cnv / virt-controller logs | $([[ $have_virt == true ]] && echo YES || echo **NO**) | Migration creator + reason |"
append_note "| cluster-scoped nodes / MCP | $([[ $have_nodes == true ]] && echo YES || echo **NO**) | Drain/cordon/reboot correlation |"
append_note ""
append_note "If any row is **NO**, ask customer for:"
append_note ""
append_note '```bash'
append_note '# Prefer a targeted must-gather for Virtualization + descheduler'
append_note 'oc adm must-gather --image=registry.redhat.io/container-native-virtualization/cnv-must-gather-rhel9:v4.21'
append_note ''
append_note '# Plus these namespace inspects on BOTH DC and DRC'
append_note 'oc adm inspect ns/openshift-kube-descheduler-operator ns/openshift-cnv \'
append_note '  ns/openshift-machine-config-operator --dest-dir=/tmp/inspect-triggers'
append_note ''
append_note '# Cluster-scoped context'
append_note 'oc get nodes -o wide > nodes.txt'
append_note 'oc get mcp,mc -o yaml > mcp.yaml'
append_note 'oc get kubedescheduler -A -o yaml > kubedescheduler.yaml'
append_note 'oc get vmim -A -o yaml > vmim-all.yaml'
append_note 'oc get events -A --field-selector reason=MigrationSucceeded --sort-by=.lastTimestamp > mig-events.txt'
append_note '```'

# -----------------------------------------------------------------------------
# 7) Live-cluster companion commands (if you still have access)
# -----------------------------------------------------------------------------
section "7) Live-cluster companion commands (run on DC and DRC if still accessible)"

cat >>"$REPORT" <<'EOF'
```bash
# A) Was descheduler driving migrations?
oc get kubedescheduler -n openshift-kube-descheduler-operator -o yaml
oc get deploy -n openshift-kube-descheduler-operator
oc logs -n openshift-kube-descheduler-operator deploy/descheduler --since=24h | egrep -i 'evict|migrate|utilization|soft'
oc logs -n openshift-kube-descheduler-operator deploy/soft-tainter --since=24h | egrep -i 'taint|node|utilization' || true

# B) Migration storm inventory
oc get vmim -A --sort-by=.metadata.creationTimestamp | tail -200
oc get events -A --field-selector reason=MigrationSucceeded --sort-by=.lastTimestamp | tail -200
oc get vmi -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,NODE:.status.nodeName,PHASE:.status.phase,MIGRATION:.status.migrationState.completed

# C) Node / MCP triggers
oc get nodes -o custom-columns=NAME:.metadata.name,READY:.status.conditions[?\(@.type==\"Ready\"\)].status,SCHED:.spec.unschedulable,TAINTS:.spec.taints
oc get mcp
oc adm top nodes

# D) Who created VMIMs? (look at .metadata.annotations / owner / events)
oc get vmim -A -o json | jq -r '
  .items[] | [
    .metadata.creationTimestamp,
    .metadata.namespace,
    .metadata.name,
    (.status.phase // ""),
    (.metadata.annotations["kubevirt.io/migrationCreatedByWorkloadUpdate"] // ""),
    (.metadata.annotations // {})
  ] | @tsv'
```
EOF

# -----------------------------------------------------------------------------
# 8) Preliminary conclusion template
# -----------------------------------------------------------------------------
section "8) Preliminary assessment template"

cat >>"$REPORT" <<'EOF'
**Expected vs unexpected**

- Occasional live migrations for a subset of VMs can be expected with OpenShift Virtualization (node maintenance, `WorkloadUpdateStrategy`, descheduler relieve/migrate, storage/network policies).
- **Simultaneous migration of essentially all VMs across all namespaces on both DC and DRC** is **not** normal day-2 noise. Treat as a **cluster-wide (or dual-site) trigger** until proven otherwise.

**Most likely buckets to prove/disprove (in order)**

1. `KubeVirtRelieveAndMigrate` / soft-tainter active on both clusters with aggressive thresholds / load spike.
2. Rolling MachineConfig / worker reboot / drain on both sites (same change window).
3. Orchestrated migration job / Ansible / script / COE runbook executed against both sites.
4. Platform incident (large node NotReady wave) causing eviction/migration.

**Preventive measures (after root cause confirmed)**

- If descheduler-driven: review `KubeDescheduler` profiles; tune `evictionLimits`, cooldowns (`devMigrationCooldown` / `devMaxMigrationCooldown`), utilization thresholds; consider disabling `KubeVirtRelieveAndMigrate` outside maintenance windows.
- If MCP/drain-driven: use proper maintenance windows; ensure PDB / `LiveMigrate` eviction strategy expectations are understood.
- Alert on spike: `count(vmim created in 15m) > N` and `MigrationSucceeded` rate.
- Require change control for any dual-site automation that can create VMIMs.
EOF

section "Done"
append_note "Full report: \`$REPORT\`"
append_note "Artifacts under: \`$OUT_DIR\`"

echo
echo "============================================"
echo "RCA report written to: $REPORT"
echo "Artifacts: $OUT_DIR"
echo "============================================"
