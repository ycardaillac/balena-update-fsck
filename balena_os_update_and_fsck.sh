#!/bin/bash
set -euo pipefail

# Configuration
DEVICE_UUID="${DEVICE_UUID:-fda36b59babced29486dc795442ed4d7}"
# Wait at least 3 minutes after triggering update before checking version.
WAIT_TIME="${WAIT_TIME:-180}"
RETRY_WAIT="${RETRY_WAIT:-15}"     # seconds between version checks
MAX_TRIES="${MAX_TRIES:-10}"       # number of version checks after initial wait (10*15s = 150s)
UPDATE_RETRY_WAIT="${UPDATE_RETRY_WAIT:-10}"  # seconds between os-update retries on HTML error
UPDATE_MAX_TRIES="${UPDATE_MAX_TRIES:-5}"     # number of os-update retries on HTML error

# List of OS versions to upgrade to
OS_VERSIONS=(
    # "6.1.21"
    # "6.1.21+rev1"
    # "6.1.24"
    # "6.1.24+rev1"
    # "6.3.18"
    # "6.3.23"
    # "6.4.1+rev1"
    # "6.4.1+rev2"
    # "6.4.1+rev3"
    # "6.4.2"
    # "6.4.2+rev1"
    # "6.4.3"
    "6.4.3+rev1"
    "6.5.1"
)

# Partitions to check
PARTITIONS=(
    "/dev/mmcblk0p2"
    "/dev/mmcblk0p3"
)

# Output directory for logs
LOG_DIR="${LOG_DIR:-./logs}"
mkdir -p "$LOG_DIR"

START_TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_LOG_DIR="${LOG_DIR}/${START_TS}"
mkdir -p "$RUN_LOG_DIR"

SCRIPT_LOG="${RUN_LOG_DIR}/script.log"
: > "$SCRIPT_LOG"

log() {
    echo "$*"
    echo "$*" >> "$SCRIPT_LOG"
}

log "Starting balenaOS update process for device: $DEVICE_UUID"
log "Will process ${#OS_VERSIONS[@]} OS version(s)"
log "Script log: $SCRIPT_LOG"
log "Run log dir: $RUN_LOG_DIR"
echo ""

is_html_error() {
    grep -qiE '<!DOCTYPE html|<html'
}

os_update_with_retry() {
    local target_version="$1"
    local attempt out rc

    for ((attempt=1; attempt<=UPDATE_MAX_TRIES; attempt++)); do
        out="$(balena device os-update -y "$DEVICE_UUID" --version "$target_version" 2>&1)" && rc=0 || rc=$?
        if [ "$rc" -eq 0 ]; then
            return 0
        fi

        if printf '%s\n' "$out" | is_html_error; then
            log "os-update got HTML error page, retrying in ${UPDATE_RETRY_WAIT}s (try ${attempt}/${UPDATE_MAX_TRIES})"
            sleep "$UPDATE_RETRY_WAIT"
            continue
        fi

        log "os-update failed for $target_version (rc=$rc): $(printf '%s\n' "$out" | head -n 1)"
        return "$rc"
    done

    log "os-update kept failing with HTML error page for $target_version (tries=${UPDATE_MAX_TRIES})"
    return 1
}

version_applied() {
    local target_version="$1"
    # If SSH is down, this fails and we treat as "not yet".
    local os_release
    os_release="$( (echo "cat /etc/os-release; exit;" | balena device ssh "$DEVICE_UUID" 2>/dev/null) || true )"
    printf '%s\n' "$os_release" | grep -Fq -- "$target_version"
}

wait_for_version() {
    local target_version="$1"
    local i

    log "Waiting at least ${WAIT_TIME}s before checking /etc/os-release..."
    sleep "$WAIT_TIME"

    for ((i=1; i<=MAX_TRIES; i++)); do
        if version_applied "$target_version"; then
            log "Version $target_version updated"
            return 0
        fi
        log "Version not updated yet (try ${i}/${MAX_TRIES}), waiting ${RETRY_WAIT}s..."
        sleep "$RETRY_WAIT"
    done
    return 1
}

previous_os_version=""
for os_version in "${OS_VERSIONS[@]}"; do
    log "=========================================="
    log "Processing OS version: $os_version"
    log "=========================================="
    
    # Trigger OS update
    if [ -n "$previous_os_version" ]; then
        log "updating from $previous_os_version to $os_version"
    else
        log "updating from current to $os_version"
    fi
    log "Triggering OS update to $os_version..."
    if ! os_update_with_retry "$os_version"; then
        log "Failed to start OS update for $os_version"
        exit 1
    fi
    log "Update command succeeded"

    # Wait for update to be applied (verify by grepping /etc/os-release)
    log "Waiting for /etc/os-release to show version $os_version..."
    if ! wait_for_version "$os_version"; then
        log "update did not apply to $os_version"
        exit 1
    fi
    
    # Print disk state before fsck
    log "Checking /dev/disk/by-state/..."
    disk_state="$( (echo "ls -l /dev/disk/by-state/ | grep active; exit;" | balena device ssh "$DEVICE_UUID" 2>&1) || true )"
    log "$disk_state"
    
    # Run fsck on each partition and collect logs
    for partition in "${PARTITIONS[@]}"; do
        partition_name=$(basename "$partition")
        log_file="${RUN_LOG_DIR}/${partition_name}_${os_version}.log"

        log "Running fsck on $partition..."

        # Run fsck via SSH and capture output + exit code
        # Remote command outputs exit code separately so we can capture it
        fsck_output="$( (echo "fsck.ext4 -f -n $partition; rc=\$?; echo FSCK_EXIT_CODE:\$rc; exit;" | balena device ssh "$DEVICE_UUID" 2>&1) || true )"
        fsck_exit_code=$(printf '%s\n' "$fsck_output" | awk -F: '/^FSCK_EXIT_CODE:/{code=$2} END{if(code=="") print "unknown"; else print code}')
        fsck_log=$(printf '%s\n' "$fsck_output" | sed '/^FSCK_EXIT_CODE:/d')

        # Write log file locally
        {
            echo "=== fsck.ext4 -f -n $partition ==="
            echo "OS Version: $os_version"
            if [ -n "$previous_os_version" ]; then
                echo "Previous OS Version: $previous_os_version"
            fi
            echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo ""
            echo "$fsck_log"
            echo ""
            echo "=== Exit code: $fsck_exit_code ==="
        } > "$log_file"

        log "  Log saved to: $log_file (exit code: $fsck_exit_code)"

        if [ "$fsck_exit_code" != "0" ] && [ "$fsck_exit_code" != "unknown" ]; then
            log "fsck encountered error for $partition"
        fi

    done
    
    # Update previous OS version for next iteration
    previous_os_version="$os_version"
    echo ""
done

log "All OS versions processed. Logs saved in: $LOG_DIR"
log "Script log: $SCRIPT_LOG"

