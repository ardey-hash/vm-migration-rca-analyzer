#!/usr/bin/env bash
# =============================================================================
# Analyze RCA artifact files and score the most likely mass-migration cause
# =============================================================================
# Usage:
#   ./vm-migration-rca-analyze.sh /path/to/rca-out-<timestamp>
#   ./vm-migration-rca-analyze.sh /path/to/folder-with-key-files
#
# Expected inputs (any subset works; more files = better verdict):
#   RCA-SUMMARY.md
#   migrations/event-lines.txt          (or event-lines.txt)
#   migrations/vmim-table.json          (or vmim-table.json)
#   timeline/hourly-counts.txt          (or hourly-counts.txt)
#   triggers/descheduler.txt
#   triggers/descheduler-config-extract.txt
#   triggers/drain-cordon.txt
#   triggers/mcp.txt
#   triggers/soft-taints.txt
#   triggers/pressure.txt
#   triggers/kubevirt.txt
#
# Output:
#   - Printed verdict to stdout
#   - VERDICT.md written into the input directory
# =============================================================================
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <rca-out-dir-or-folder-with-artifacts>" >&2
  exit 1
fi

ROOT=$(cd "$1" && pwd)
OUT="$ROOT/VERDICT.md"
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need python3
need rg

# Resolve file whether nested under migrations/triggers/timeline or flat
find_file() {
  local name="$1"
  local cand
  for cand in \
    "$ROOT/$name" \
    "$ROOT/migrations/$name" \
    "$ROOT/triggers/$name" \
    "$ROOT/timeline/$name" \
    "$ROOT/summary/$name"
  do
    if [[ -f "$cand" ]]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  # basename search one level
  local hit
  hit=$(find "$ROOT" -maxdepth 3 -type f -name "$name" 2>/dev/null | head -1 || true)
  if [[ -n "$hit" ]]; then
    printf '%s\n' "$hit"
    return 0
  fi
  return 1
}

echo "Analyzing artifacts under: $ROOT"
echo

python3 - "$ROOT" "$OUT" <<'PY'
import os, re, sys, json
from pathlib import Path
from collections import Counter

root = Path(sys.argv[1])
out_path = Path(sys.argv[2])

def find_file(name: str):
    for cand in [
        root / name,
        root / "migrations" / name,
        root / "triggers" / name,
        root / "timeline" / name,
        root / "summary" / name,
    ]:
        if cand.is_file():
            return cand
    hits = list(root.rglob(name))
    return hits[0] if hits else None

def read_text(path):
    if not path:
        return ""
    try:
        return path.read_text(errors="ignore")
    except Exception:
        return ""

def count_lines(text):
    return len([l for l in text.splitlines() if l.strip()])

def count_matches(text, pattern, flags=re.I):
    return len(re.findall(pattern, text, flags))

files = {
    "summary": find_file("RCA-SUMMARY.md"),
    "events": find_file("event-lines.txt"),
    "vmim": find_file("vmim-table.json"),
    "hourly": find_file("hourly-counts.txt"),
    "descheduler": find_file("descheduler.txt"),
    "desched_cfg": find_file("descheduler-config-extract.txt"),
    "drain": find_file("drain-cordon.txt"),
    "mcp": find_file("mcp.txt"),
    "soft": find_file("soft-taints.txt"),
    "pressure": find_file("pressure.txt"),
    "kubevirt": find_file("kubevirt.txt"),
    "vmim_refs": find_file("vmim-refs.txt"),
    "mig_events": find_file("migration-events.txt"),
}

texts = {k: read_text(v) for k, v in files.items()}

# --- Signals ---
sig = {}

# Descheduler / KubeVirt relieve-migrate
d = texts["descheduler"] + "\n" + texts["desched_cfg"]
sig["descheduler_hits"] = count_lines(texts["descheduler"])
sig["desched_cfg_hits"] = count_lines(texts["desched_cfg"])
sig["has_kv_relieve"] = bool(re.search(r'KubeVirtRelieveAndMigrate|DevKubeVirtRelieveAndMigrate', d, re.I))
sig["has_softtainter"] = bool(re.search(r'soft-?tainter|softtainter', d, re.I))
sig["has_descheduler_ns"] = bool(re.search(r'openshift-kube-descheduler|KubeDescheduler', d, re.I))
sig["has_evict_bg"] = bool(re.search(r'EvictionsInBackground', d, re.I))

# Drain / cordon
dr = texts["drain"]
sig["drain_hits"] = count_lines(dr)
sig["scheduling_disabled"] = count_matches(dr, r'SchedulingDisabled|spec:\s*unschedulable:\s*true|cordon')
sig["drain_words"] = count_matches(dr, r'\bdrain\b|TaintManagerEviction|NodeNotReady')

# MCP / reboot
m = texts["mcp"]
sig["mcp_hits"] = count_lines(m)
sig["mcp_reboot"] = count_matches(m, r'reboot|Rebooting|Drain|UpdatedMachineConfig|MachineConfigPool|rendered-worker')

# Soft taints / PSI
s = texts["soft"]
sig["soft_hits"] = count_lines(s)
sig["prefer_no_schedule"] = count_matches(s, r'PreferNoSchedule|descheduler\.openshift\.io|PSI|LoadAverage')

# Pressure
p = texts["pressure"]
sig["pressure_hits"] = count_lines(p)
sig["mem_disk_pressure"] = count_matches(p, r'MemoryPressure|DiskPressure|PIDPressure|eviction manager|OOMKilled')

# KubeVirt / workload update
k = texts["kubevirt"]
sig["kubevirt_hits"] = count_lines(k)
sig["workload_update"] = count_matches(k, r'WorkloadUpdate|migrationCreatedByWorkloadUpdate|liveMigration|parallelMigrationsPerCluster')

# Migration volume / timeline
events = texts["events"] or texts["mig_events"]
sig["migration_event_lines"] = count_lines(events)
sig["migration_succeeded"] = count_matches(events, r'MigrationSucceeded')
sig["migration_failed"] = count_matches(events, r'MigrationFailed')

hourly = {}
for line in texts["hourly"].splitlines():
    parts = line.split()
    if len(parts) >= 2 and parts[-1].isdigit():
        hourly[parts[0]] = int(parts[-1])

sig["hourly_buckets"] = len(hourly)
sig["hourly_peak"] = max(hourly.values()) if hourly else 0
sig["hourly_peak_hour"] = max(hourly, key=hourly.get) if hourly else ""

vmim_count = 0
vmim_phases = Counter()
if files["vmim"] and files["vmim"].exists():
    try:
        rows = json.loads(files["vmim"].read_text() or "[]")
        if isinstance(rows, list):
            vmim_count = len(rows)
            for r in rows:
                vmim_phases[(r.get("phase") or "?" )] += 1
    except Exception:
        pass
sig["vmim_count"] = vmim_count
sig["vmim_phases"] = dict(vmim_phases)

# --- Score hypotheses ---
# Scores are heuristic, not absolute proof.
scores = {
    "descheduler_kubevirt_relieve": 0,
    "mcp_drain_reboot": 0,
    "node_pressure_eviction": 0,
    "kubevirt_workload_update": 0,
    "unknown_or_insufficient_data": 0,
}
evidence = {k: [] for k in scores}

# Descheduler path
if sig["has_kv_relieve"]:
    scores["descheduler_kubevirt_relieve"] += 40
    evidence["descheduler_kubevirt_relieve"].append("Found KubeVirtRelieveAndMigrate / DevKubeVirtRelieveAndMigrate references")
if sig["has_softtainter"]:
    scores["descheduler_kubevirt_relieve"] += 15
    evidence["descheduler_kubevirt_relieve"].append("Soft-tainter references present")
if sig["has_descheduler_ns"]:
    scores["descheduler_kubevirt_relieve"] += 10
    evidence["descheduler_kubevirt_relieve"].append("Descheduler operator / KubeDescheduler CR references present")
if sig["prefer_no_schedule"] > 0:
    scores["descheduler_kubevirt_relieve"] += 10
    evidence["descheduler_kubevirt_relieve"].append(f"Soft-taint / PreferNoSchedule / PSI signals: {sig['prefer_no_schedule']}")
if sig["has_evict_bg"]:
    scores["descheduler_kubevirt_relieve"] += 5
    evidence["descheduler_kubevirt_relieve"].append("EvictionsInBackground referenced (typical with relieve/migrate)")

# MCP / drain
if sig["scheduling_disabled"] > 0:
    scores["mcp_drain_reboot"] += 25
    evidence["mcp_drain_reboot"].append(f"SchedulingDisabled/cordon signals: {sig['scheduling_disabled']}")
if sig["drain_words"] > 0:
    scores["mcp_drain_reboot"] += 15
    evidence["mcp_drain_reboot"].append(f"Drain / NodeNotReady / TaintManager signals: {sig['drain_words']}")
if sig["mcp_reboot"] > 0:
    scores["mcp_drain_reboot"] += 25
    evidence["mcp_drain_reboot"].append(f"MCP/reboot/MachineConfig signals: {sig['mcp_reboot']}")
if sig["mcp_hits"] > 50 and sig["mcp_reboot"] > 0:
    scores["mcp_drain_reboot"] += 10
    evidence["mcp_drain_reboot"].append("Dense MCP-related hit volume")

# Pressure
if sig["mem_disk_pressure"] > 0:
    scores["node_pressure_eviction"] += 30
    evidence["node_pressure_eviction"].append(f"Memory/Disk/PID pressure or eviction manager hits: {sig['mem_disk_pressure']}")
if sig["pressure_hits"] > 20:
    scores["node_pressure_eviction"] += 10
    evidence["node_pressure_eviction"].append("Elevated pressure hit volume")

# Workload update
if sig["workload_update"] > 0:
    scores["kubevirt_workload_update"] += 35
    evidence["kubevirt_workload_update"].append(f"WorkloadUpdate / liveMigration config signals: {sig['workload_update']}")

# Migration volume boosts confidence of "something real happened"
volume_boost = 0
if sig["migration_succeeded"] >= 20 or sig["vmim_count"] >= 20 or sig["hourly_peak"] >= 20:
    volume_boost = 15
elif sig["migration_succeeded"] >= 5 or sig["vmim_count"] >= 5 or sig["hourly_peak"] >= 5:
    volume_boost = 8
elif sig["migration_event_lines"] > 0 or sig["vmim_count"] > 0:
    volume_boost = 3

for k in ("descheduler_kubevirt_relieve", "mcp_drain_reboot", "node_pressure_eviction", "kubevirt_workload_update"):
    if scores[k] > 0 and volume_boost:
        scores[k] += volume_boost
        evidence[k].append(f"Migration volume support (+{volume_boost})")

# Insufficient data?
present = sum(1 for p in files.values() if p)
strong = max(scores[k] for k in scores if k != "unknown_or_insufficient_data")
if present < 3 or (sig["migration_event_lines"] == 0 and sig["vmim_count"] == 0 and strong < 20):
    scores["unknown_or_insufficient_data"] = 50
    evidence["unknown_or_insufficient_data"].append("Too few migration artifacts or trigger files to conclude confidently")
elif strong < 25:
    scores["unknown_or_insufficient_data"] = 30
    evidence["unknown_or_insufficient_data"].append("Signals present but weak; need descheduler NS / CNV / MCP inspects")

# Rank
ranked = sorted(scores.items(), key=lambda kv: kv[1], reverse=True)
top_name, top_score = ranked[0]
second_name, second_score = ranked[1]

labels = {
    "descheduler_kubevirt_relieve": "Kube Descheduler (KubeVirtRelieveAndMigrate / soft-tainter)",
    "mcp_drain_reboot": "Node drain / MachineConfig rolling reboot (MCP)",
    "node_pressure_eviction": "Node pressure / eviction wave",
    "kubevirt_workload_update": "KubeVirt WorkloadUpdate / live-migration policy",
    "unknown_or_insufficient_data": "Insufficient data — cannot confirm cause yet",
}

confidence = "LOW"
if top_score >= 70 and top_score - second_score >= 20:
    confidence = "HIGH"
elif top_score >= 45 and top_score - second_score >= 10:
    confidence = "MEDIUM"
elif top_score >= 25:
    confidence = "LOW-MEDIUM"

# Expected vs unexpected blurb
expected = (
    "Unexpected as normal day-2 noise if essentially all VMs across namespaces "
    "moved in a short window on both DC and DRC. That pattern implies a cluster-wide "
    "(or dual-site) trigger, not isolated per-VM maintenance."
)

lines = []
lines.append("# Mass VM Migration — Automated Verdict")
lines.append("")
lines.append(f"- Artifact root: `{root}`")
lines.append(f"- Files detected: **{present}**")
lines.append("")
lines.append("## Verdict")
lines.append("")
lines.append(f"- **Most likely cause:** {labels[top_name]}")
lines.append(f"- **Score:** {top_score}")
lines.append(f"- **Confidence:** {confidence}")
lines.append(f"- **Runner-up:** {labels[second_name]} (score {second_score})")
lines.append("")
lines.append(f"**Expected vs unexpected:** {expected}")
lines.append("")
lines.append("## Scoreboard")
lines.append("")
lines.append("| Hypothesis | Score |")
lines.append("|------------|------:|")
for name, score in ranked:
    lines.append(f"| {labels[name]} | {score} |")
lines.append("")
lines.append("## Evidence for top cause")
lines.append("")
if evidence[top_name]:
    for e in evidence[top_name]:
        lines.append(f"- {e}")
else:
    lines.append("- No strong positive evidence collected for the top hypothesis.")
lines.append("")
lines.append("## Key signals")
lines.append("")
lines.append("| Signal | Value |")
lines.append("|--------|------:|")
for k in [
    "migration_event_lines", "migration_succeeded", "migration_failed", "vmim_count",
    "hourly_peak", "hourly_peak_hour",
    "has_kv_relieve", "has_softtainter", "has_descheduler_ns",
    "scheduling_disabled", "drain_words", "mcp_reboot",
    "prefer_no_schedule", "mem_disk_pressure", "workload_update",
]:
    lines.append(f"| {k} | {sig.get(k)} |")
lines.append("")
if vmim_phases:
    lines.append("### VMIM phases")
    lines.append("")
    for ph, n in vmim_phases.most_common():
        lines.append(f"- {ph}: {n}")
    lines.append("")
if hourly:
    lines.append("### Migration event density by hour")
    lines.append("")
    lines.append("| hour | count |")
    lines.append("|------|------:|")
    for h, c in sorted(hourly.items()):
        marker = " ← peak" if h == sig["hourly_peak_hour"] else ""
        lines.append(f"| {h} | {c}{marker} |")
    lines.append("")

lines.append("## Files used")
lines.append("")
for k, p in files.items():
    status = f"`{p}`" if p else "_missing_"
    lines.append(f"- {k}: {status}")
lines.append("")

lines.append("## What to do next")
lines.append("")
if top_name == "descheduler_kubevirt_relieve":
    lines.append("1. Confirm `oc get kubedescheduler -n openshift-kube-descheduler-operator -o yaml` on DC and DRC.")
    lines.append("2. Check profiles include `KubeVirtRelieveAndMigrate` and review evictionLimits / cooldowns / thresholds.")
    lines.append("3. Correlate peak hour with descheduler logs (`evict`, `utilization`, soft-tainter taints).")
    lines.append("4. Preventive: tune or disable relieve/migrate outside maintenance windows; alert on VMIM creation spikes.")
elif top_name == "mcp_drain_reboot":
    lines.append("1. Review MCP status and MachineConfig change window on both sites.")
    lines.append("2. Confirm workers went SchedulingDisabled / drained around peak hour.")
    lines.append("3. Preventive: maintenance windows, controlled drains, verify VM live-migrate eviction strategy.")
elif top_name == "node_pressure_eviction":
    lines.append("1. Identify nodes with MemoryPressure/DiskPressure around peak hour.")
    lines.append("2. Check kubelet eviction and virt-handler logs.")
    lines.append("3. Preventive: capacity headroom, disk cleanup, memory limits, node alerts.")
elif top_name == "kubevirt_workload_update":
    lines.append("1. Inspect HyperConverged / KubeVirt WorkloadUpdateStrategy and annotations on VMIMs.")
    lines.append("2. Check if a CNV/HCO upgrade or config change landed on both sites.")
    lines.append("3. Preventive: control workload update methods; stagger upgrades.")
else:
    lines.append("1. Re-run collection including `openshift-kube-descheduler-operator`, `openshift-cnv`, and MCP/node inspects on **both** DC and DRC.")
    lines.append("2. Export `oc get vmim -A -o yaml` and MigrationSucceeded events for the suspected window.")
    lines.append("3. Re-run `vm-mass-migration-rca.sh` then this analyzer.")
lines.append("")

report = "\n".join(lines)
out_path.write_text(report)
print(report)
print(f"\nWrote: {out_path}")
PY
