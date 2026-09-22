#!/usr/bin/env bash
# Shared setup, variables, and helper functions for scripts/*.sh. Source this near
# the top of a script, right after the shebang and header comment:
#   source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ -f .venv/bin/activate ]; then
  # shellcheck disable=SC1091
  source .venv/bin/activate
fi

# The variables below are used by the scripts that source this file.
# shellcheck disable=SC2034
INVENTORY="inventories/homelab/hosts"
# shellcheck disable=SC2034
ALL_NODES="ubuntu,win11,omv,jellyfin"
# shellcheck disable=SC2034
STORAGE="omv"
# shellcheck disable=SC2034
OTHERS="jellyfin,ubuntu,win11"

phase() {
  echo
  echo "=== $* ==="
}

declare -a PHASE_NAMES=()
declare -a PHASE_DURATIONS=()

# Runs one stage, timing it, and records the duration for print_time_table. A
# failing stage aborts the script (set -e) after being recorded.
# Usage: run_phase "Phase N: label" cmd_or_function [args...]
run_phase() {
  local name="$1"
  shift

  phase "$name"
  local start end rc
  start=$(date +%s)
  # if/else, not a bare "$@" line: under set -e a failing command as its own
  # simple statement would abort before the bookkeeping below.
  if "$@"; then
    rc=0
  else
    rc=$?
  fi
  end=$(date +%s)
  PHASE_NAMES+=("$name")
  PHASE_DURATIONS+=("$((end - start))")
  return "$rc"
}

print_time_table() {
  local total=0 i d
  phase "Time analysis"
  printf '%-62s %10s\n' "Stage" "Duration"
  printf '%-62s %10s\n' "-----" "--------"
  for i in "${!PHASE_NAMES[@]}"; do
    d="${PHASE_DURATIONS[$i]}"
    total=$((total + d))
    printf '%-62s %6dm%02ds\n' "${PHASE_NAMES[$i]}" $((d / 60)) $((d % 60))
  done
  printf '%-62s %10s\n' "-----" "--------"
  printf '%-62s %6dm%02ds\n' "TOTAL" $((total / 60)) $((total % 60))
}
