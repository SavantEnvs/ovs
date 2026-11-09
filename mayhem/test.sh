#!/usr/bin/env bash
#
# mayhem/test.sh — RUN Open vSwitch's own autotest suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# The daemon-free part of OVS's autotest suite: JSON parsing/serialisation, OpenFlow print/decode,
# OpenFlow error encoding, datapath-flow (odp) parsing and miniflow tests. Each test feeds known input
# to the real binaries (ovstest, ovs-ofctl) and diffs their output against golden text, so a program
# that exits 0 without doing the work fails. (Tests that start ovs-vswitchd/ovsdb-server are left out:
# they need the full daemon stack and are slow and flaky in a container.)
TESTBUILD="$SRC/mayhem/build-test"
[ -f "$TESTBUILD/tests/testsuite" ] || [ -f "$SRC/tests/testsuite" ] || { echo "test suite not built — mayhem/build.sh must run first" >&2; emit_ctrf "ovs-autotest" 0 1 0; exit 1; }

cd "$TESTBUILD"
make ALL_LOCAL= check TESTSUITEFLAGS="-j$MAYHEM_JOBS -k json -k ofp-print -k ofp-errors -k odp -k miniflow" >/tmp/ovs-check.out 2>&1
tail -n 15 /tmp/ovs-check.out

LOG="$TESTBUILD/tests/testsuite.log"
[ -f "$LOG" ] || { echo "no testsuite.log produced" >&2; emit_ctrf "ovs-autotest" 0 1 0; exit 1; }
passed=$(grep -cE '^[0-9]+\. .*: (ok|expected failure)( |$)' "$LOG" || true)
failed=$(grep -cE '^[0-9]+\. .*: (FAILED|ok \(unexpected pass\)|unexpected pass)' "$LOG" || true)
skipped=$(grep -cE '^[0-9]+\. .*: skipped' "$LOG" || true)
[ $(( passed + failed + skipped )) -gt 0 ] || failed=1
emit_ctrf "ovs-autotest" "$passed" "$failed" "$skipped"
