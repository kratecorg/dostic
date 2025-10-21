#!/bin/bash

set -euo pipefail

# Version
VERSION="0.2.0"

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PWD="$(pwd)"

# Load logging system first (before any output)
source "${SCRIPT_DIR}/lib/logging.sh"

# Show usage
function show_usage {
    cat << EOF
dostic v${VERSION} - Docker + Restic Backup Solution

Usage: $0 <command>

Commands:
  init              Initialize a new backup repository
  backup            Run full backup (postgres, mysql, volumes, folders)
  backup-postgres   Backup only PostgreSQL databases
  backup-mysql      Backup only MySQL databases
  backup-volumes    Backup only Docker volumes
  backup-folders    Backup only system folders
  snapshots         Show current snapshots
  stats             Show repository statistics
  restore           Restore a snapshot (usage: restore <snapshot-id> <target-path>)
  forget            Remove old snapshots (according to retention policy)
  prune             Remove old snapshot data from repository
  unlock            Unlock the repository
  check             Verify repository integrity
  version           Show version information

EOF
    exit 1
}

# Check if command is provided
if [ $# -eq 0 ]; then
    show_usage
fi

COMMAND=$1
shift

# Handle version and help before loading config
case "${COMMAND}" in
    -h|--help|help)
        show_usage
        ;;
    -v|--version|version)
        log_info "dostic v${VERSION}"
        exit 0
        ;;
esac

# Load configuration
if [ -f "${PWD}/.dostic.env" ]; then
    log_info "Loading configuration from .dostic.env" "path=${PWD}/.dostic.env"
    source "${PWD}/.dostic.env"
else
    log_error "Configuration file not found" "path=${PWD}/.dostic.env"
    log_error "Please create .dostic.env with required settings"
    log_info "Example configuration:"
    log_info "  REPOSITORY=\"b2:bucket-name\""
    log_info "  B2_ACCOUNT_ID=\"your-account-id\""
    log_info "  B2_ACCOUNT_KEY=\"your-account-key\""
    log_info "  HOST=\"\$(hostname)\""
    log_info "  BACKUP_BASEDIR=\"/tmp/backups\""
    exit 1
fi

# Load library functions
source "${SCRIPT_DIR}/lib/defaults.sh"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/config-validation.sh"
source "${SCRIPT_DIR}/lib/docker-args.sh"
source "${SCRIPT_DIR}/lib/restic-functions.sh"

# Default values if not set in config
HOST="${HOST:-$(hostname)}"
BACKUP_BASEDIR="${BACKUP_BASEDIR:-/backups}"

# Validate configuration
if ! validate_config; then
    log_error "Configuration validation failed" "action=check_config_above"
    exit 1
fi

# Execute command
case "${COMMAND}" in
    init)
        restic_init
        ;;
    backup)
        log_section "dostic v${VERSION} - Full Backup" "host=${HOST}"
        backup_postgres
        backup_mysql
        backup_docker_volumes
        backup_folders
        log_section "Backup Completed" "timestamp=$(format_date)"
        restic_snapshots
        ;;
    backup-postgres)
        backup_postgres
        ;;
    backup-mysql)
        backup_mysql
        ;;
    backup-volumes)
        backup_docker_volumes
        ;;
    backup-folders)
        backup_folders
        ;;
    snapshots)
        restic_snapshots
        ;;
    stats)
        restic_stats
        ;;
    restore)
        restic_restore "$@"
        ;;
    forget)
        restic_forget
        ;;
    prune)
        restic_prune
        ;;
    unlock)
        restic_unlock
        ;;
    check)
        restic_check
        ;;
    *)
        log_error "Unknown command" "command=${COMMAND}"
        show_usage
        ;;
esac
