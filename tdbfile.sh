#!/usr/bin/env bash
# TDB File Purge
# Author: Clumsy | HackTheBox
# Date: 2025-07-20
# Purpose: Securely purge Samba printing TDB files exceeding a size threshold,
#          with robust logging, error handling, concurrency-safe operations,
#          and audit trail generation.
set -euo pipefail
IFS=$'\n\t'
readonly TARGET_DIR="/var/lib/samba/printing"
readonly FILE_PATTERN="*.tdb"
readonly SIZE_THRESHOLD=50000
readonly LOG_FILE="/var/log/samba_tdb_purge.log"
readonly LOCK_FILE="/var/lock/samba_tdb_purge.lock"
timestamp() {
    date +"%Y-%m-%dT%H:%M:%S%z"
}
log() {
    local level="$1"
    local msg="$2"
    local ts
    ts=$(timestamp)
    # Audit-grade structured log format (ISO 8601 + level + message)
    printf '%s [%s] %s\n' "$ts" "$level" "$msg" | tee -a "$LOG_FILE" >&2
}
acquire_lock() {
    exec 200>"$LOCK_FILE"
    flock -n 200 || {
        log ERROR "Another instance of the script is running. Exiting."
        exit 1
    }
}
release_lock() {
    flock -u 200
    rm -f "$LOCK_FILE"
}
validate_environment() {
    # Ensure running as root or with sufficient privileges to delete files
    if (( EUID != 0 )); then
        log ERROR "This script must be run as root or with sudo privileges."
        exit 1
    fi
    # Validate that stat supports --format or fallback gracefully
    if ! stat --version &>/dev/null; then
        log ERROR "stat utility unavailable or incompatible."
        exit 1
    fi
    # Validate target directory
    if [[ ! -d "$TARGET_DIR" ]]; then
        log ERROR "Target directory '$TARGET_DIR' does not exist or is inaccessible."
        exit 1
    fi
}
secure_delete() {
    local file="$1"
    # Atomically move to a quarantine folder before deletion for forensic safety
    local quarantine_dir="${TARGET_DIR}/.quarantine"
    mkdir -p "$quarantine_dir"
    local basefile
    basefile=$(basename "$file")
    local timestamped_file="${quarantine_dir}/${basefile}.$(date +%s)"
    if mv -- "$file" "$timestamped_file"; then
        log INFO "Moved '$file' to quarantine as '$timestamped_file'."
        if shred -u -n 3 -- "$timestamped_file"; then
            log INFO "Securely deleted '$timestamped_file'."
        else
            log ERROR "Failed to securely delete '$timestamped_file'."
        fi
    else
        log ERROR "Failed to move '$file' to quarantine. Skipping deletion."
    fi
}
main() {
    validate_environment
    acquire_lock
    # Null-delimited safe find loop
    while IFS= read -r -d '' file; do
        local filesize
        filesize=$(stat --format='%s' "$file" 2>/dev/null) || {
            log ERROR "Failed to stat file '$file'; skipping."
            continue
        }
        if (( filesize > SIZE_THRESHOLD )); then
            secure_delete "$file"
        fi
    done < <(find "$TARGET_DIR" -type f -name "$FILE_PATTERN" -print0)

    release_lock
}
main "$@"
