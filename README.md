# VM Migration RCA Analyzer

Heuristic root-cause analysis for **mass OpenShift Virtualization (KubeVirt) live migrations**.

Use this toolkit when many VMs migrate in a short window and the question is which cluster-wide trigger is most likely:

- Kube Descheduler (`KubeVirtRelieveAndMigrate` / soft-tainter)
- Node drain / MachineConfigPool rolling reboot
- Node pressure / kubelet eviction
- KubeVirt / HyperConverged WorkloadUpdate live-migration policy

The collector mines `oc adm inspect` / must-gather trees. The analyzer scores those artifacts and writes a `VERDICT.md`.

Scores are **heuristic**, not proof. Always validate the top hypothesis against live cluster state and timestamps.

## Scripts

| Script | Role |
|--------|------|
| `vm-mass-migration-rca.sh` | Collect migration + trigger signals from inspect directories into `rca-out-<timestamp>/` |
| `vm-migration-rca-analyze.sh` | Score artifacts and print / write `VERDICT.md` |

## Requirements

- `bash`
- `python3`
- [`ripgrep`](https://github.com/BurntSushi/ripgrep) (`rg`)

## Quick start

```bash
git clone https://github.com/ardey-hash/vm-migration-rca-analyzer.git
cd vm-migration-rca-analyzer
chmod +x vm-mass-migration-rca.sh vm-migration-rca-analyze.sh
```

### 1) Collect artifacts from inspect / must-gather

```bash
./vm-mass-migration-rca.sh /path/to/inspect.local.* 

# Multiple roots (e.g. DC + DRC)
./vm-mass-migration-rca.sh /path/to/dc-inspect /path/to/drc-inspect

# Optional time window (UTC)
WINDOW_START="2026-10-27T18:00:00Z" WINDOW_END="2026-10-28T06:00:00Z" \
  ./vm-mass-migration-rca.sh /path/to/inspects

# Optional output directory
OUT_DIR=./rca-out-custom ./vm-mass-migration-rca.sh /path/to/inspects
```

Default output: `./rca-out-<timestamp>/` with `RCA-SUMMARY.md`, `migrations/`, `triggers/`, `timeline/`, and related files.

### 2) Analyze and score

```bash
./vm-migration-rca-analyze.sh ./rca-out-<timestamp>
```

Stdout shows the verdict. The same report is written to:

```text
./rca-out-<timestamp>/VERDICT.md
```

Flat folders also work if key files sit at the root or under `migrations/`, `triggers/`, `timeline/`, or `summary/`.

## Analyzer inputs

Any subset is accepted; more files improve confidence.

- `RCA-SUMMARY.md`
- `migrations/event-lines.txt` (or `event-lines.txt`)
- `migrations/vmim-table.json` (or `vmim-table.json`)
- `timeline/hourly-counts.txt` (or `hourly-counts.txt`)
- `triggers/descheduler.txt`
- `triggers/descheduler-config-extract.txt`
- `triggers/drain-cordon.txt`
- `triggers/mcp.txt`
- `triggers/soft-taints.txt`
- `triggers/pressure.txt`
- `triggers/kubevirt.txt`

Optional extras if present: `vmim-refs.txt`, `migration-events.txt`.

## Analyzer output

`VERDICT.md` includes:

- Most likely cause, score, confidence, and runner-up
- Scoreboard across hypotheses
- Evidence bullets for the top cause
- Key signal values (migration volume, descheduler markers, MCP/drain, pressure, WorkloadUpdate)
- Suggested next validation steps

Confidence bands: `HIGH`, `MEDIUM`, `LOW-MEDIUM`, `LOW` (based on score and gap vs runner-up).

## Suggested inspect coverage

For stronger results, include namespaces / objects such as:

- `openshift-kube-descheduler-operator`
- `openshift-cnv` / HyperConverged / KubeVirt
- Node / MCP / MachineConfig related inspects
- Events and `VirtualMachineInstanceMigration` (VMIM) data for the incident window

## Disclaimer

This tooling assists triage. It does not replace cluster review, vendor support analysis, or change-window correlation.

## License

Provided as-is for operational troubleshooting.
