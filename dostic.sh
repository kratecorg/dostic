#!/bin/bash

set -euo pipefail

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PWD="$(pwd)"

# Load configuration
if [ -f "${PWD}/.dostic.env" ]; then
    echo "Loading configuration from .dostic.env"
    source "${PWD}/.dostic.env"
else
    echo "ERROR: Configuration file .dostic.env not found!" >&2
    echo "Please create .dostic.env with required settings." >&2
    echo "" >&2
    echo "Example .dostic.env:" >&2
    echo "  REPOSITORY=\"b2:bucket-name\"" >&2
    echo "  B2_ACCOUNT_ID=\"your-account-id\"" >&2
    echo "  B2_ACCOUNT_KEY=\"your-account-key\"" >&2
    echo "  HOST=\"\$(hostname)\"" >&2
    echo "  BACKUP_BASEDIR=\"/tmp/backups\"" >&2
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
BACKUP_BASEDIR="${BACKUP_BASEDIR:-/tmp/backups}"

# Show usage
function show_usage {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  init              Initialize a new backup repository"
    echo "  backup            Run full backup (postgres, mysql, volumes, folders)"
    echo "  backup-postgres   Backup only PostgreSQL databases"
    echo "  backup-mysql      Backup only MySQL databases"
    echo "  backup-volumes    Backup only Docker volumes"
    echo "  backup-folders    Backup only system folders"
    echo "  snapshots         Show current snapshots"
    echo "  stats             Show repository statistics"
    echo "  forget            Remove old snapshots (according to retention policy)"
    echo "  prune             Remove old snapshot data from repository"
    echo "  unlock            Unlock the repository"
    echo "  check             Verify repository integrity"
    echo ""
    exit 1
}

# Check if command is provided
if [ $# -eq 0 ]; then
    show_usage
fi

COMMAND=$1
shift

# Validate configuration for all commands that need it
# (skip for help/info commands that don't interact with the repository)
case "${COMMAND}" in
    -h|--help|help)
        show_usage
        ;;
esac

# Now validate config for all other commands
if ! validate_config; then
    echo ""
    echo "ERROR: Configuration validation failed. Please fix the errors above." >&2
    exit 1
fi

# Execute command
case "${COMMAND}" in
    init)
        backup_init
        ;;
    backup)
        echo "=========================================="
        echo "Starting full backup at $(format_date)"
        echo "=========================================="
        backup_postgres
        backup_mysql
        backup_docker_volumes
        backup_folders
        echo ""
        echo "=========================================="
        echo "Backup completed at $(format_date)"
        echo "=========================================="
        display_current_state
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
        display_current_state
        ;;
    stats)
        display_sizes
        ;;
    forget)
        remove_old
        ;;
    prune)
        prune
        ;;
    unlock)
        unlock
        ;;
    check)
        echo ""
        echo "$(format_date) checking repository integrity"
        echo ""
        docker run --rm --name restic \
            -v backup_cache:/root/.cache/restic \
            -v ~/.restic/:/restic \
            -v /etc/localtime:/etc/localtime:ro \
            -e RESTIC_REPOSITORY=${REPOSITORY} \
            -e B2_ACCOUNT_ID=${B2_ACCOUNT_ID} \
            -e B2_ACCOUNT_KEY=${B2_ACCOUNT_KEY} \
            restic/restic check -p /restic/passfile
        ;;
    *)
        echo "ERROR: Unknown command '${COMMAND}'" >&2
        echo "" >&2
        show_usage
        ;;
esac
