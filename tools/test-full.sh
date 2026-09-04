#!/bin/bash
# FULL GUARD RUN — every TarabdaarCore suite including the slow DSP
# render/bench suites behind the TARABDAAR_SLOW_TESTS gate (see
# Tests/TarabdaarCoreTests/SlowTestGate.swift and CLAUDE.md "Building").
#
# Two phases, because parallelism and wall-clock assertions don't mix:
#
#   1. `swift test --parallel` for everything EXCEPT the suites that
#      assert wall-clock budgets — the render suites are independent
#      CPU-bound processes, so this phase is bounded by the longest
#      suite (~2 min LiveParamPush) instead of the serial sum.
#   2. RealtimePerformanceTests + RebuildCostTests run serially on a
#      quiet machine — they measure realtime/rebuild budgets, and CPU
#      contention from phase 1 would flake them (the reason they are
#      not in the parallel batch; do not "optimize" them into it).
#
# Each phase runs under a WATCHDOG: a wedged test fails the run loudly
# after $PHASE_TIMEOUT_S instead of hanging forever.
# macOS ships no `timeout`, hence the hand-rolled kill. Normal phases
# finish in a couple of minutes; the cap is generous on purpose.
#
# Bare `swift test` remains the seconds-long fast loop; this script is
# the pre-commit / CI invocation.
set -euo pipefail
cd "$(dirname "$0")/../Packages/TarabdaarCore"
export TARABDAAR_SLOW_TESTS=1

PHASE_TIMEOUT_S="${PHASE_TIMEOUT_S:-900}"

run_phase() {
    "$@" &
    local pid=$!
    # Watchdog stdout/stderr go to the terminal's fds via /dev/tty-less
    # detach: they MUST NOT inherit a pipe — the orphaned `sleep` child
    # would hold the pipe open and stall a piped caller (CI, `| tail`)
    # for the full timeout after a successful run. The timeout message
    # is echoed from the main shell instead (via the flag file).
    local flag
    flag="$(mktemp)"
    (
        exec >/dev/null 2>&1
        sleep "$PHASE_TIMEOUT_S"
        if kill -0 "$pid" 2>/dev/null; then
            echo timeout > "$flag"
            kill -TERM "$pid" 2>/dev/null
            sleep 5
            kill -9 "$pid" 2>/dev/null
            # swift-test's xctest children can outlive it
            pkill -9 -f TarabdaarCorePackageTests 2>/dev/null || true
        fi
    ) &
    local wd=$!
    local rc=0
    wait "$pid" || rc=$?
    # reap the watchdog AND its sleep child (kill of the subshell alone
    # leaves the sleep running)
    pkill -P "$wd" 2>/dev/null || true
    kill "$wd" 2>/dev/null || true
    wait "$wd" 2>/dev/null || true
    if [ -s "$flag" ]; then
        echo "!! phase TIMED OUT after ${PHASE_TIMEOUT_S}s — killed" \
             "(a wedged suite; sample the xctest process to get the" \
             "stack before rerunning)" >&2
    fi
    rm -f "$flag"
    return "$rc"
}

# Both phases always run: a phase-1 failure must not hide a phase-2 one
# (the settle pre-roll regression once sat unseen behind two phase-1
# failures). The exit code reports either.
RC1=0; RC2=0
echo "== phase 1/2: parallel (all suites except wall-clock guards) =="
run_phase swift test --parallel \
  --skip RealtimePerformanceTests \
  --skip RebuildCostTests || RC1=$?

echo "== phase 2/2: serial wall-clock guards =="
run_phase swift test \
  --filter RealtimePerformanceTests \
  --filter RebuildCostTests || RC2=$?

if [ "$RC1" -ne 0 ] || [ "$RC2" -ne 0 ]; then
    echo "== full guard run FAILED (phase 1 rc=$RC1, phase 2 rc=$RC2) ==" >&2
    exit 1
fi
echo "== full guard run passed =="
