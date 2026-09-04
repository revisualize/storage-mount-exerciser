#!/usr/bin/env bash
#
# ---------------------------------------------------------------------
# Path:         storage_mount_exerciser.sh
# Filename:     storage_mount_exerciser.sh
# Project:      storage_mount_exerciser
# Description:  Data-path canary for NFS exports and SMB shares. Mounts,
#               writes, reads back, verifies, deletes, and unmounts,
#               timing every phase in milliseconds into a CSV history.
# Status:       production
# Revision:     2
# Updated:      2026-08-05
# Requires:     Bash 4.2 or newer, GNU coreutils, util-linux (flock,
#               mountpoint, findmnt), mount.nfs or mount.cifs
# Included by:  standalone command line tool; sourceable for testing
# Provides:     current_time_milliseconds, verify_scratch_marker,
#               build_csv_row, build_report_line, run_timed_phase,
#               append_history_row, exercise_data_path
# ---------------------------------------------------------------------
#
# Portability
#   Target shells:  bash 4.2+ (associative arrays require 4.0+).
#   Tested on:      bash 5.2 on Ubuntu 24.04. Data-path phases are
#                   exercised against a local directory in the test
#                   suite; the mount phases require real storage and
#                   must be shaken down in a lab before production use.
#   date +%s%N is GNU coreutils. BSD date does not support %N.
#
# Exit codes:
#   0  every phase passed
#   1  a phase failed (mount, write, read, delete, unmount)
#   2  configuration, dependency, lock, or safety contract error
#   3  INTEGRITY MISMATCH: bytes read back differ from bytes written
#
#   Exit 3 is deliberately distinct. A latency problem and a corruption
#   problem are not the same finding and must not share an exit code,
#   because the alerting that routes them should not be the same either.
#
# Environment (all optional; defaults shown):
#   EXERCISER_PROTOCOL          nfs
#   EXERCISER_NFS_SERVER        storage01.example.net
#   EXERCISER_NFS_EXPORT        /export/data
#   EXERCISER_SMB_SERVER        storage01.example.net
#   EXERCISER_SMB_SHARE         data
#   EXERCISER_SMB_CREDENTIALS   /etc/storage_mount_exerciser/smb_credentials
#   EXERCISER_SCRATCH_RELATIVE  monitoring/exerciser_scratch
#   EXERCISER_PAYLOAD_KB        1024
#   EXERCISER_WARN_MS           2000
#   EXERCISER_HISTORY_FILE      /var/lib/storage_mount_exerciser/history.csv
#   EXERCISER_LOG_FILE          /var/log/storage_mount_exerciser.log
#   EXERCISER_LOCK_FILE         /var/lock/storage_mount_exerciser.lock
#   EXERCISER_PHASE_TIMEOUT     30
#   EXERCISER_LIB_ONLY          set to 1 to source functions for testing
#

set -u

# ---------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------
storage_protocol="${EXERCISER_PROTOCOL:-nfs}"
nfs_server="${EXERCISER_NFS_SERVER:-storage01.example.net}"
nfs_export_path="${EXERCISER_NFS_EXPORT:-/export/data}"
smb_server="${EXERCISER_SMB_SERVER:-storage01.example.net}"
smb_share_name="${EXERCISER_SMB_SHARE:-data}"
smb_credentials_file="${EXERCISER_SMB_CREDENTIALS:-/etc/storage_mount_exerciser/smb_credentials}"

scratch_relative_path="${EXERCISER_SCRATCH_RELATIVE:-monitoring/exerciser_scratch}"
scratch_marker_filename=".mount_exerciser_scratch_area"
payload_size_kilobytes="${EXERCISER_PAYLOAD_KB:-1024}"
latency_warning_milliseconds="${EXERCISER_WARN_MS:-2000}"

csv_history_file="${EXERCISER_HISTORY_FILE:-/var/lib/storage_mount_exerciser/history.csv}"
log_file="${EXERCISER_LOG_FILE:-/var/log/storage_mount_exerciser.log}"
lock_file="${EXERCISER_LOCK_FILE:-/var/lock/storage_mount_exerciser.lock}"
phase_timeout_seconds="${EXERCISER_PHASE_TIMEOUT:-30}"

exerciser_phase_names=(mount write read verify delete unmount)
csv_header_line="timestamp,protocol,outcome,failed_phase,mount_ms,write_ms,read_ms,verify_ms,delete_ms,unmount_ms"

# Declared global so the script can be sourced from inside a shell
# function (which is how bats loads it) without the array becoming
# function-local and vanishing before any test runs.
declare -gA measured_milliseconds=()
mount_point_directory=""
local_staging_directory=""

# ---------------------------------------------------------------------
# Infrastructure
# ---------------------------------------------------------------------

log_message() {
    local log_directory
    log_directory="$(dirname "${log_file}")"
    [ -d "${log_directory}" ] || mkdir -p "${log_directory}" 2>/dev/null || return 0
    printf '%s %s\n' "$(date --iso-8601=seconds)" "${1}" >> "${log_file}" 2>/dev/null || true
}

current_time_milliseconds() {
    local nanosecond_timestamp
    nanosecond_timestamp="$(date +%s%N)"
    printf '%s' "$((nanosecond_timestamp / 1000000))"
}

cleanup_on_exit() {
    if [ -n "${mount_point_directory}" ] \
        && mountpoint -q "${mount_point_directory}" 2>/dev/null; then
        umount "${mount_point_directory}" 2>/dev/null \
            || umount -l "${mount_point_directory}" 2>/dev/null
    fi
    [ -n "${mount_point_directory}" ] && rmdir "${mount_point_directory}" 2>/dev/null
    [ -n "${local_staging_directory}" ] && rm -rf "${local_staging_directory}"
    return 0
}

# ---------------------------------------------------------------------
# Reporting helpers. Kept pure so they can be tested without storage.
# ---------------------------------------------------------------------

# build_csv_row <timestamp> <protocol> <outcome> <failed_phase>
# A failed run still produces a row. A history that only records
# successes cannot answer "how often does this break," which is half
# the question the CSV exists to answer. Unmeasured phases are empty
# fields, never zero, because zero is a latency claim and empty is not.
build_csv_row() {
    local row="${1},${2},${3},${4}"
    local phase_name
    for phase_name in "${exerciser_phase_names[@]}"; do
        row+=",${measured_milliseconds[${phase_name}]:-}"
    done
    printf '%s' "${row}"
}

build_report_line() {
    local outcome="${1}"
    local line="${outcome} ${storage_protocol}"
    local phase_name
    for phase_name in "${exerciser_phase_names[@]}"; do
        if [ -n "${measured_milliseconds[${phase_name}]:-}" ]; then
            line+=" ${phase_name}=${measured_milliseconds[${phase_name}]}ms"
        fi
    done
    printf '%s' "${line}"
}

append_history_row() {
    local row="${1}"
    local history_directory
    history_directory="$(dirname "${csv_history_file}")"
    mkdir -p "${history_directory}" 2>/dev/null || return 2
    if [ ! -f "${csv_history_file}" ]; then
        printf '%s\n' "${csv_header_line}" > "${csv_history_file}" || return 2
    fi
    printf '%s\n' "${row}" >> "${csv_history_file}" || return 2
    return 0
}

# finish_run <exit_code> <outcome> <failed_phase>
# Every exit path records a row and a log line, so the history is a
# complete record of what was attempted rather than a highlight reel.
finish_run() {
    local exit_code="${1}"
    local outcome="${2}"
    local failed_phase="${3:-}"
    local row
    row="$(build_csv_row "$(date --iso-8601=seconds)" "${storage_protocol}" \
        "${outcome}" "${failed_phase}")"
    append_history_row "${row}" || log_message "WARN: could not append to ${csv_history_file}"
    local report_line
    report_line="$(build_report_line "${outcome}")"
    log_message "${report_line}"
    if [ "${exit_code}" -eq 0 ]; then
        printf '%s\n' "${report_line}"
    else
        printf '%s%s\n' "${report_line}" \
            "${failed_phase:+ failed_phase=${failed_phase}}" >&2
    fi
    return "${exit_code}"
}

# ---------------------------------------------------------------------
# Safety contract
# ---------------------------------------------------------------------

# verify_scratch_marker <scratch_directory>
# Writes happen only inside a directory a human deliberately blessed by
# placing a marker file. A typo in the scratch path fails closed rather
# than scattering test files through a production tree.
verify_scratch_marker() {
    local scratch_directory="${1}"
    [ -f "${scratch_directory}/${scratch_marker_filename}" ]
}

# ---------------------------------------------------------------------
# Timed phases
# ---------------------------------------------------------------------

exerciser_failed_phase=""

# run_timed_phase <phase_name> <command...>
# Records the duration and returns nonzero on failure. It does not exit,
# so the caller owns the exit path and every failure still gets a row.
run_timed_phase() {
    local phase_name="${1}"
    shift
    local phase_start_milliseconds
    local phase_end_milliseconds
    phase_start_milliseconds="$(current_time_milliseconds)"
    if ! timeout "${phase_timeout_seconds}" "$@" > /dev/null 2>&1; then
        exerciser_failed_phase="${phase_name}"
        log_message "FAIL: phase ${phase_name} failed or exceeded ${phase_timeout_seconds}s"
        return 1
    fi
    phase_end_milliseconds="$(current_time_milliseconds)"
    measured_milliseconds["${phase_name}"]=$((phase_end_milliseconds - phase_start_milliseconds))
    if [ "${measured_milliseconds[${phase_name}]}" -gt "${latency_warning_milliseconds}" ]; then
        log_message "WARN: phase ${phase_name} took ${measured_milliseconds[${phase_name}]}ms (threshold ${latency_warning_milliseconds}ms)"
    fi
    return 0
}

# exercise_data_path <scratch_directory> <payload_file> <readback_file>
# The write, read, verify, and delete phases against an already-mounted
# path. Separated from mounting so the data-path logic is testable
# against a local directory without any storage at all.
#
# Returns: 0 success, 1 phase failure, 3 integrity mismatch.
exercise_data_path() {
    local scratch_directory="${1}"
    local payload_file="${2}"
    local readback_file="${3}"
    local short_host_name
    short_host_name="$(hostname -s 2>/dev/null || printf 'host')"
    local remote_test_file="${scratch_directory}/exerciser_${short_host_name}_$$.bin"

    run_timed_phase "write" dd if="${payload_file}" of="${remote_test_file}" \
        bs=1024 conv=fsync status=none || return 1

    run_timed_phase "read" dd if="${remote_test_file}" of="${readback_file}" \
        bs=1024 status=none || return 1

    # An integrity mismatch outranks every latency number in this run and
    # gets its own exit code so alert routing can treat it differently.
    if ! run_timed_phase "verify" cmp "${payload_file}" "${readback_file}"; then
        log_message "INTEGRITY MISMATCH: bytes read back differ from bytes written"
        rm -f "${remote_test_file}" 2>/dev/null
        return 3
    fi

    run_timed_phase "delete" rm -f "${remote_test_file}" || return 1
    return 0
}

# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------

main() {
    trap cleanup_on_exit EXIT

    local required_command
    local missing_commands=()
    for required_command in mount umount mountpoint dd cmp timeout flock mktemp date; do
        command -v "${required_command}" > /dev/null 2>&1 \
            || missing_commands+=("${required_command}")
    done
    if [ "${#missing_commands[@]}" -gt 0 ]; then
        printf 'FAIL: missing required command(s): %s\n' "${missing_commands[*]}" >&2
        return 2
    fi

    # A lock file that cannot be opened is a configuration error, not a
    # phase failure, and must not be reported as one.
    mkdir -p "$(dirname "${lock_file}")" 2>/dev/null
    if ! exec 200>"${lock_file}"; then
        printf 'FAIL: cannot open lock file %s\n' "${lock_file}" >&2
        return 2
    fi
    if ! flock -n 200; then
        log_message "Previous run still holds the lock, exiting."
        return 0
    fi

    mount_point_directory="$(mktemp -d)" || { printf 'FAIL: cannot create mount point\n' >&2; return 2; }
    local_staging_directory="$(mktemp -d)" || { printf 'FAIL: cannot create staging directory\n' >&2; return 2; }

    # Stage the payload locally before any clock starts, so entropy
    # generation is never billed to the storage.
    local local_payload_file="${local_staging_directory}/payload.bin"
    dd if=/dev/urandom of="${local_payload_file}" bs=1024 \
        count="${payload_size_kilobytes}" status=none \
        || { printf 'FAIL: payload staging failed\n' >&2; return 2; }

    local mount_status=0
    case "${storage_protocol}" in
        nfs)
            run_timed_phase "mount" mount -t nfs -o rw,soft,timeo=30,retrans=2 \
                "${nfs_server}:${nfs_export_path}" "${mount_point_directory}" \
                || mount_status=1
            ;;
        smb)
            if [ ! -r "${smb_credentials_file}" ]; then
                printf 'FAIL: SMB credentials file unreadable: %s\n' "${smb_credentials_file}" >&2
                return 2
            fi
            run_timed_phase "mount" mount -t cifs \
                -o "credentials=${smb_credentials_file},soft" \
                "//${smb_server}/${smb_share_name}" "${mount_point_directory}" \
                || mount_status=1
            ;;
        *)
            printf 'FAIL: unknown storage protocol: %s\n' "${storage_protocol}" >&2
            return 2
            ;;
    esac
    if [ "${mount_status}" -ne 0 ]; then
        finish_run 1 FAIL mount
        return 1
    fi

    local scratch_directory="${mount_point_directory}/${scratch_relative_path}"
    if ! verify_scratch_marker "${scratch_directory}"; then
        printf 'FAIL: scratch marker %s not found in %s; refusing to write\n' \
            "${scratch_marker_filename}" "${scratch_relative_path}" >&2
        log_message "SAFETY: scratch marker absent, refused to write"
        return 2
    fi

    local data_path_status=0
    exercise_data_path "${scratch_directory}" "${local_payload_file}" \
        "${local_staging_directory}/readback.bin" || data_path_status=$?

    if [ "${data_path_status}" -eq 3 ]; then
        finish_run 3 INTEGRITY_MISMATCH verify
        return 3
    fi
    if [ "${data_path_status}" -ne 0 ]; then
        finish_run 1 FAIL "${exerciser_failed_phase}"
        return 1
    fi

    run_timed_phase "unmount" umount "${mount_point_directory}" || {
        finish_run 1 FAIL unmount
        return 1
    }

    finish_run 0 PASS ""
    return 0
}

if [ "${EXERCISER_LIB_ONLY:-0}" != "1" ]; then
    main "$@"
    exit $?
fi
