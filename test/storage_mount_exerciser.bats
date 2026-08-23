#!/usr/bin/env bats
#
# ---------------------------------------------------------------------
# Path:         test/storage_mount_exerciser.bats
# Filename:     storage_mount_exerciser.bats
# Project:      storage_mount_exerciser
# Description:  Behavioural tests for the safety contract, the data-path
#               phases, exit-code selection, and CSV history recording.
# Status:       production
# Revision:     1
# Updated:      2026-08-05
# Requires:     bats, bash 4.2 or newer
# Included by:  .github/workflows/ci.yml
# Provides:     test coverage for storage_mount_exerciser.sh
# ---------------------------------------------------------------------
#
# Run with:  bats test/
#
# The data path is exercised against a local directory, which tests
# everything except the mount and unmount phases. Those need real
# storage and are called out as untested in the project writeup.
#

setup() {
  export EXERCISER_LIB_ONLY=1
  WORK="$(mktemp -d)"
  export WORK
  mkdir -p "${WORK}/bin" "${WORK}/marked" "${WORK}/unmarked"
  touch "${WORK}/marked/.mount_exerciser_scratch_area"
  dd if=/dev/urandom of="${WORK}/payload.bin" bs=1024 count=32 status=none

  export EXERCISER_HISTORY_FILE="${WORK}/history.csv"
  export EXERCISER_LOG_FILE="${WORK}/exerciser.log"
  source "${BATS_TEST_DIRNAME}/../storage_mount_exerciser.sh"
  csv_history_file="${WORK}/history.csv"
  log_file="${WORK}/exerciser.log"
  unset measured_milliseconds
  declare -gA measured_milliseconds=()
  exerciser_failed_phase=""
}

teardown() {
  rm -rf "${WORK}"
}

# ---------------------------------------------------------------------
# Safety contract
# ---------------------------------------------------------------------

@test "an unmarked scratch directory is refused" {
  run verify_scratch_marker "${WORK}/unmarked"
  [ "${status}" -ne 0 ]
}

@test "a marked scratch directory is accepted" {
  run verify_scratch_marker "${WORK}/marked"
  [ "${status}" -eq 0 ]
}

@test "a nonexistent scratch directory is refused" {
  run verify_scratch_marker "${WORK}/no_such_directory"
  [ "${status}" -ne 0 ]
}

# ---------------------------------------------------------------------
# Data path
# ---------------------------------------------------------------------

@test "a clean round trip through the data path succeeds" {
  run exercise_data_path "${WORK}/marked" "${WORK}/payload.bin" "${WORK}/readback.bin"
  [ "${status}" -eq 0 ]
}

@test "the round trip returns the bytes that were written" {
  exercise_data_path "${WORK}/marked" "${WORK}/payload.bin" "${WORK}/readback.bin"
  cmp "${WORK}/payload.bin" "${WORK}/readback.bin"
}

@test "every data-path phase records a duration" {
  exercise_data_path "${WORK}/marked" "${WORK}/payload.bin" "${WORK}/readback.bin"
  for phase in write read verify delete; do
    [ -n "${measured_milliseconds[${phase}]:-}" ]
  done
}

@test "the test file is removed from the scratch area afterwards" {
  exercise_data_path "${WORK}/marked" "${WORK}/payload.bin" "${WORK}/readback.bin"
  run bash -c "ls '${WORK}/marked' | grep -c exerciser_ || true"
  [[ "${output}" == "0" ]]
}

@test "a write to an unwritable path fails and names the phase" {
  run exercise_data_path "${WORK}/no_such_directory" "${WORK}/payload.bin" "${WORK}/readback.bin"
  [ "${status}" -eq 1 ]
}

# ---------------------------------------------------------------------
# Regression: integrity mismatch gets its own exit code
# ---------------------------------------------------------------------

@test "REGRESSION an integrity mismatch returns 3, not the generic 1" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${WORK}/bin/cmp"
  chmod +x "${WORK}/bin/cmp"
  PATH="${WORK}/bin:${PATH}" run exercise_data_path \
    "${WORK}/marked" "${WORK}/payload.bin" "${WORK}/readback.bin"
  [ "${status}" -eq 3 ]
}

@test "an integrity mismatch still removes the test file" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${WORK}/bin/cmp"
  chmod +x "${WORK}/bin/cmp"
  PATH="${WORK}/bin:${PATH}" exercise_data_path \
    "${WORK}/marked" "${WORK}/payload.bin" "${WORK}/readback.bin" || true
  run bash -c "ls '${WORK}/marked' | grep -c exerciser_ || true"
  [[ "${output}" == "0" ]]
}

# ---------------------------------------------------------------------
# CSV history
# ---------------------------------------------------------------------

@test "the history file is created with a header on first write" {
  append_history_row "row"
  head -n 1 "${csv_history_file}" | grep -q "^timestamp,protocol,outcome,failed_phase,"
}

@test "REGRESSION a failed run still records a history row" {
  declare -gA measured_milliseconds=([mount]=12 [write]=340)
  finish_run 1 FAIL read || true
  grep -q ",FAIL,read," "${csv_history_file}"
}

@test "an integrity mismatch is recorded as its own outcome" {
  declare -gA measured_milliseconds=([mount]=11 [write]=201 [read]=180)
  finish_run 3 INTEGRITY_MISMATCH verify || true
  grep -q ",INTEGRITY_MISMATCH,verify," "${csv_history_file}"
}

@test "a passing run is recorded as PASS with no failed phase" {
  declare -gA measured_milliseconds=([mount]=10 [write]=20 [read]=15 [verify]=5 [delete]=3 [unmount]=8)
  finish_run 0 PASS ""
  grep -q ",PASS,," "${csv_history_file}"
}

@test "unmeasured phases are empty fields, never a fabricated zero" {
  declare -gA measured_milliseconds=([mount]=12)
  run build_csv_row "2026-08-05T00:00:00Z" "nfs" "FAIL" "write"
  [[ "${output}" == "2026-08-05T00:00:00Z,nfs,FAIL,write,12,,,,," ]]
}

@test "the CSV column count matches the header column count" {
  declare -gA measured_milliseconds=([mount]=1 [write]=2 [read]=3 [verify]=4 [delete]=5 [unmount]=6)
  local row; row="$(build_csv_row "2026-08-05T00:00:00Z" "nfs" "PASS" "")"
  local header_fields row_fields
  header_fields="$(printf '%s' "${csv_header_line}" | awk -F, '{print NF}')"
  row_fields="$(printf '%s' "${row}" | awk -F, '{print NF}')"
  [ "${header_fields}" -eq "${row_fields}" ]
}

@test "history rows append rather than overwrite" {
  append_history_row "row_one"
  append_history_row "row_two"
  [ "$(wc -l < "${csv_history_file}")" -eq 3 ]
}

# ---------------------------------------------------------------------
# Timing and reporting
# ---------------------------------------------------------------------

@test "the millisecond clock advances monotonically" {
  local first second
  first="$(current_time_milliseconds)"
  sleep 0.1
  second="$(current_time_milliseconds)"
  [ "${second}" -gt "${first}" ]
}

@test "the millisecond clock returns a bare integer" {
  run current_time_milliseconds
  [[ "${output}" =~ ^[0-9]+$ ]]
}

@test "the report line names only the phases that were measured" {
  declare -gA measured_milliseconds=([mount]=10 [write]=20)
  run build_report_line PASS
  [[ "${output}" == *"mount=10ms"* ]]
  [[ "${output}" == *"write=20ms"* ]]
  [[ "${output}" != *"verify="* ]]
}

@test "a timed phase records a duration on success" {
  run_timed_phase "probe" true
  [ -n "${measured_milliseconds[probe]:-}" ]
}

@test "a timed phase reports failure without exiting the shell" {
  run run_timed_phase "probe" false
  [ "${status}" -eq 1 ]
}

@test "sourcing with EXERCISER_LIB_ONLY does not execute a run" {
  run bash -c "EXERCISER_LIB_ONLY=1 source '${BATS_TEST_DIRNAME}/../storage_mount_exerciser.sh' && echo sourced_clean"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"sourced_clean"* ]]
}
