#!/bin/sh
# Adaptive, isolated Git workload for PGO training and performance validation.
set -eu

git_bin=${GIT_PGO_GIT:-git}
time_budget=${GIT_PGO_TIME_BUDGET_SECONDS:-20}
disk_budget_mib=${GIT_PGO_DISK_BUDGET_MIB:-16}
report=${GIT_PGO_REPORT:-git-pgo-report.json}
max_regression=${GIT_PGO_MAX_REGRESSION_PERCENT:-5}
compare_report=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --git) git_bin=$2; shift 2 ;;
    --time-budget-seconds) time_budget=$2; shift 2 ;;
    --disk-budget-mib) disk_budget_mib=$2; shift 2 ;;
    --report) report=$2; shift 2 ;;
    --compare-report) compare_report=$2; shift 2 ;;
    --max-regression-percent) max_regression=$2; shift 2 ;;
    -h|--help)
      cat <<'EOF'
Usage: scripts/git-pgo-workload.sh [options]
  --git PATH                    Git executable (default: GIT_PGO_GIT or git)
  --time-budget-seconds N       Measured-phase time budget (default: 20)
  --disk-budget-mib N            Generated payload budget (default: 16)
  --report PATH                  JSON report path
  --compare-report PATH          Compare medians with a prior report
  --max-regression-percent N     Aggregate regression threshold (default: 5)
EOF
      exit 0 ;;
    *) echo "error: unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v "$git_bin" >/dev/null 2>&1 || {
  [ -x "$git_bin" ] || { echo "error: Git executable not found: $git_bin" >&2; exit 2; }
}
command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required for deterministic fixture/report JSON" >&2; exit 2; }
python3 - "$time_budget" "$disk_budget_mib" "$max_regression" <<'PY'
import math, sys
for label, value, allow_zero in (("time budget", sys.argv[1], False), ("disk budget", sys.argv[2], False), ("regression threshold", sys.argv[3], True)):
    try: n = float(value)
    except ValueError: raise SystemExit("error: invalid " + label)
    if not math.isfinite(n) or (n < 0 if allow_zero else n <= 0):
        raise SystemExit("error: invalid " + label)
PY

case "$git_bin" in */*) [ -x "$git_bin" ] || { echo "error: Git executable not found: $git_bin" >&2; exit 2; } ;;
*) git_bin=$(command -v "$git_bin") ;;
esac

disk_bytes=$(python3 - "$disk_budget_mib" <<'PY'
import sys
print(int(float(sys.argv[1]) * 1024 * 1024))
PY
)
mkdir -p "$(dirname "$report")"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/git-pgo.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
home="$tmp/home"
mkdir -p "$home"
export HOME="$home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_TERMINAL_PROMPT=0 LC_ALL=C TZ=UTC
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
unset GIT_COMMON_DIR GIT_PREFIX GIT_CONFIG GIT_CONFIG_COUNT

seed="$tmp/seed"
remote="$tmp/remote.git"
work="$tmp/work"
samples="$tmp/samples.tsv"
: > "$samples"

# GNU date is available on the Linux CI runner; use nanoseconds for short operations.
now_ns() { date +%s%N; }
timed() {
  name=$1; shift
  start=$(now_ns)
  "$@" >/dev/null
  finish=$(now_ns)
  printf '%s\t%s\n' "$name" "$((finish - start))" >> "$samples"
}

"$git_bin" init --quiet "$seed"
"$git_bin" -C "$seed" config user.name "Git PGO Fixture"
"$git_bin" -C "$seed" config user.email "git-pgo-fixture@example.invalid"
"$git_bin" -C "$seed" branch -M main
mkdir -p "$seed/fixture"
generated_bytes=0
generated_files=0
while [ $((generated_bytes + 4096)) -le "$disk_bytes" ]; do
  digest=$(printf '%s' "$generated_files" | sha256sum | cut -c1-64)
  target="$seed/fixture/${digest%????????????????????????????????????????????????????????????}/${digest#??}"
  # Hash-derived two-level fan-out; filenames are stable and no count ceiling is imposed.
  first=$(printf '%s' "$digest" | cut -c1-2)
  second=$(printf '%s' "$digest" | cut -c3-4)
  mkdir -p "$seed/fixture/$first/$second"
  python3 - "$generated_files" "$seed/fixture/$first/$second/blob-$generated_files.dat" <<'PY'
import hashlib, sys
i = int(sys.argv[1])
seed = ("git-pgo-fixture:%016x" % i).encode()
record = seed + b" " + hashlib.sha256(seed).hexdigest().encode() + b"\n"
payload = (record * (4096 // len(record) + 1))[:4096]
with open(sys.argv[2], "wb") as f: f.write(payload)
PY
  generated_bytes=$((generated_bytes + 4096))
  generated_files=$((generated_files + 1))
done
if [ "$generated_files" -eq 0 ]; then
  python3 - "$disk_bytes" "$seed/fixture/seed.dat" <<'PY'
import hashlib, sys
size = min(4096, int(sys.argv[1]))
seed = b"git-pgo-fixture:minimum"
record = seed + b" " + hashlib.sha256(seed).hexdigest().encode() + b"\n"
with open(sys.argv[2], "wb") as f: f.write((record * (size // len(record) + 1))[:size])
PY
  generated_bytes=$(python3 - "$disk_bytes" <<'PY'
import sys
print(min(4096, int(sys.argv[1])))
PY
)
  generated_files=1
fi
"$git_bin" -C "$seed" add fixture
"$git_bin" -C "$seed" commit --quiet -m "seed adaptive PGO fixture"
"$git_bin" clone --quiet --bare "$seed" "$remote"
"$git_bin" clone --quiet "$remote" "$work"
"$git_bin" -C "$work" config user.name "Git PGO Fixture"
"$git_bin" -C "$work" config user.email "git-pgo-fixture@example.invalid"

version=$("$git_bin" --version)
start_epoch=$(now_ns)
deadline=$(python3 - "$time_budget" <<'PY'
import sys, time
print(time.monotonic() + float(sys.argv[1]))
PY
)
cycles=0
while [ "$cycles" -eq 0 ] || python3 - "$deadline" <<'PY'
import sys, time
raise SystemExit(0 if time.monotonic() < float(sys.argv[1]) else 1)
PY
do
  timed status_clean "$git_bin" -C "$work" status --porcelain=v2 --branch
  timed ls_untracked "$git_bin" -C "$work" ls-files --others --exclude-standard
  timed diff_stat "$git_bin" -C "$work" diff --stat
  timed log "$git_bin" -C "$work" log --oneline --decorate -20
  timed rev_list "$git_bin" -C "$work" rev-list --objects --all
  timed refs "$git_bin" -C "$work" for-each-ref '--format=%(refname) %(objectname)'

  chosen=$(find "$work/fixture" -type f | sort | sed -n "$((cycles % generated_files + 1))p")
  printf '\nmodified-in-cycle=%s\n' "$cycles" >> "$chosen"
  if [ "$generated_files" -gt 1 ]; then
    delete_index=$(((cycles + 1) % generated_files + 1))
    deleted=$(find "$work/fixture" -type f | sort | sed -n "${delete_index}p")
    [ "$deleted" = "$chosen" ] || rm -f "$deleted"
  fi
  mkdir -p "$work/untracked"
  printf 'untracked-cycle=%s\n' "$cycles" > "$work/untracked/cycle-$cycles.txt"
  timed status_dirty "$git_bin" -C "$work" status --porcelain=v2 --branch --untracked-files=all
  timed diff_worktree "$git_bin" -C "$work" diff --stat
  "$git_bin" -C "$work" add -A
  timed diff_cached "$git_bin" -C "$work" diff --cached --stat
  timed commit "$git_bin" -C "$work" commit --quiet -m "adaptive workload cycle $cycles"
  topic="pgo/topic-$cycles"
  timed branch_switch sh -c '"$1" -C "$2" switch -c "$3" >/dev/null && "$1" -C "$2" switch main >/dev/null' sh "$git_bin" "$work" "$topic"
  "$git_bin" -C "$work" switch "$topic" >/dev/null
  "$git_bin" -C "$work" commit --allow-empty --quiet -m "topic marker $cycles"
  "$git_bin" -C "$work" switch main >/dev/null
  timed merge "$git_bin" -C "$work" merge --no-ff --quiet "$topic" -m "merge topic $cycles"
  timed repack "$git_bin" -C "$work" repack -ad
  clone="$tmp/clone-$cycles"
  timed clone "$git_bin" clone --quiet --no-local "$work" "$clone"
  timed fetch "$git_bin" -C "$clone" fetch --quiet "$remote"
  rm -rf "$clone"

  # Return to a fixed seed state so history/tree growth cannot skew later cycles.
  rm -rf "$work"
  "$git_bin" clone --quiet "$remote" "$work"
  "$git_bin" -C "$work" config user.name "Git PGO Fixture"
  "$git_bin" -C "$work" config user.email "git-pgo-fixture@example.invalid"
  cycles=$((cycles + 1))
done

elapsed=$(python3 - "$start_epoch" <<'PY'
import sys, time
print(round((time.time_ns() - int(sys.argv[1])) / 1e9, 4))
PY
)
python3 - "$samples" "$report" "$version" "$git_bin" "$time_budget" "$disk_bytes" "$generated_bytes" "$generated_files" "$cycles" "$elapsed" "$compare_report" "$max_regression" <<'PY'
import json, math, os, statistics, sys
(samples_path, report_path, version, git_bin, time_budget, disk_budget,
 generated_bytes, generated_files, cycles, elapsed, baseline_path, max_regression) = sys.argv[1:]
samples = {}
with open(samples_path, encoding="utf-8") as stream:
    for line in stream:
        name, ns = line.rstrip("\n").split("\t")
        samples.setdefault(name, []).append(int(ns) / 1e6)
medians = {name: round(statistics.median(values), 4) for name, values in samples.items() if values}
operations = ["status_clean","ls_untracked","diff_stat","log","rev_list","refs","status_dirty","diff_worktree","diff_cached","commit","branch_switch","merge","repack","clone","fetch"]
missing = sorted(set(operations) - set(medians))
disk_budget, generated_bytes, generated_files, cycles = map(int, (disk_budget, generated_bytes, generated_files, cycles))
acceptance = {
    "all_operations_exercised": not missing,
    "fixture_within_payload_budget": generated_bytes <= disk_budget,
    "workload_cycles_completed": cycles > 0,
    "performance_comparison": "not_requested",
}
all_passed = not missing and generated_bytes <= disk_budget and cycles > 0
if baseline_path:
    with open(baseline_path, encoding="utf-8") as stream: baseline = json.load(stream)
    if baseline.get("schema_version") != 1: raise SystemExit("error: baseline schema version does not match")
    if baseline.get("generated_payload_bytes") != generated_bytes: raise SystemExit("error: baseline fixture size differs; use matching disk budgets")
    ratios = [medians[n] / baseline["median_latency_ms"][n] for n in medians if n in baseline.get("median_latency_ms", {}) and baseline["median_latency_ms"][n] > 0]
    if not ratios: raise SystemExit("error: baseline has no comparable positive medians")
    change = (math.exp(sum(math.log(r) for r in ratios) / len(ratios)) - 1) * 100
    passed = change <= float(max_regression)
    acceptance["performance_comparison"] = {
        "baseline_report": baseline_path,
        "geometric_mean_latency_change_percent": round(change, 3),
        "max_regression_percent": float(max_regression),
        "passed": passed,
        "compared_operations": len(ratios),
    }
    all_passed = all_passed and passed
acceptance["all_checks_passed"] = all_passed
report = {
    "schema_version": 1, "git_executable": os.path.realpath(git_bin), "git_version": version,
    "time_budget_seconds": float(time_budget), "disk_budget_bytes": disk_budget,
    "generated_payload_bytes": generated_bytes, "generated_files": generated_files,
    "workload_cycles": cycles, "elapsed_seconds": float(elapsed),
    "operation_samples": {name: len(values) for name, values in samples.items()},
    "median_latency_ms": medians, "acceptance": acceptance,
}
os.makedirs(os.path.dirname(os.path.abspath(report_path)), exist_ok=True)
with open(report_path, "w", encoding="utf-8") as stream: json.dump(report, stream, indent=2, sort_keys=True); stream.write("\n")
print(json.dumps(report, indent=2, sort_keys=True))
raise SystemExit(0 if all_passed else 1)
PY
