#!/bin/bash

# Source library files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/defaults.sh"
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/config-validation.sh"
source "${SCRIPT_DIR}/docker-args.sh"

function backup {
    local source_path="$1"
    local target_name="$2"
    
    echo ""
    echo "$(format_date) backing up from ${source_path} as ${target_name}"
    echo ""
    
    local docker_args=()
    mapfile -t docker_args < <(build_backup_docker_args "${source_path}" "${target_name}")
    
    # Add hostname if set
    local host_arg=()
    if [[ -n "${HOST:-}" ]]; then
        host_arg=(--host "${HOST}")
    fi
    
    # Add tags for better organization
    local tag_args=(--tag "${target_name}")
    
    docker run "${docker_args[@]}" \
        restic/restic backup "${host_arg[@]}" "${tag_args[@]}" --verbose /backup
}

function restic_init {
    echo ""
    echo "$(format_date) initializing restic repository"
    echo ""
    
    local docker_args=()
    mapfile -t docker_args < <(build_docker_args)
    
    docker run "${docker_args[@]}" \
        restic/restic init --verbose
}

function backup_init_old {
    docker run --rm --name restic \
        -v backup_cache:/root/.cache/restic \
        -v ~/.restic/:/restic \
        -v /etc/localtime:/etc/localtime:ro \
        -e RESTIC_REPOSITORY=${REPOSITORY} \
	    -e B2_ACCOUNT_ID=${B2_ACCOUNT_ID} \
	    -e B2_ACCOUNT_KEY=${B2_ACCOUNT_KEY} \
        restic/restic init --verbose -p /restic/passfile
}


function backup_postgres {
    echo ""
    echo "$(format_date) backing up postgres databases"
    echo ""

    mkdir -p ${BACKUP_BASEDIR}/postgres/
    rm ${BACKUP_BASEDIR}/postgres/*
    docker ps -a --format '{{.Names}}\t{{.Ports}}' | grep 5432/tcp | awk '{ print $1 }' | while read -r line; do
        echo "$(format_date) extracting database from container '${line}'"
        docker exec -t ${line} pg_dumpall -v --lock-wait-timeout=600 -c -U postgres -f /tmp/export.sql
        docker cp ${line}:/tmp/export.sql ${BACKUP_BASEDIR}/postgres/${line}.sql
        docker exec -t ${line} rm /tmp/export.sql
    done
    backup ${BACKUP_BASEDIR}/postgres/ postgres
}

function backup_mysql {
    echo ""
    echo "$(format_date) backing up mysql databases"
    echo ""

    mkdir -p ${BACKUP_BASEDIR}/mysql/
    rm ${BACKUP_BASEDIR}/mysql/*
    docker ps -a --format '{{.Names}}\t{{.Ports}}' | grep 3306/tcp | awk '{ print $1 }' | while read -r line; do
        echo "$(format_date) extracting database from container '${line}'"
        docker exec -t ${line} sh -c 'mysqldump -uroot -p"${MYSQL_ROOT_PASSWORD}" -A -r /tmp/export.sql'
        docker cp ${line}:/tmp/export.sql ${BACKUP_BASEDIR}/mysql/${line}.sql
        docker exec -t ${line} rm /tmp/export.sql
    done
    backup ${BACKUP_BASEDIR}/mysql/ mysql
}


function backup_docker_volumes {
    echo ""
    echo "$(format_date) backing up docker volumes"
    echo ""

    docker volume list -q | egrep -v '^.{64}$' | while read -r volume; do
        echo "$(format_date) backing up docker volume '${volume}'"
        if [[ "${volume}" == "backup_cache" ]]; then
            echo "ignoring volume '${volume}'"
            continue
        fi
        backup ${volume} docker/${volume}
    done
}

function backup_folders {
    echo ""
    echo "$(format_date) backing up folders"
    echo ""

    # Check if BACKUP_FOLDERS is set
    if [[ -z "${BACKUP_FOLDERS:-}" ]]; then
        echo "WARNING: BACKUP_FOLDERS not set in configuration, skipping folder backup" >&2
        return 0
    fi

    # Split BACKUP_FOLDERS by comma and iterate
    IFS=',' read -ra folders <<< "${BACKUP_FOLDERS}"
    for folder_spec in "${folders[@]}"; do
        # Trim whitespace
        folder_spec=$(echo "${folder_spec}" | xargs)
        
        # Skip empty entries
        [[ -z "${folder_spec}" ]] && continue
        
        # Split by colon to get source:target
        if [[ "${folder_spec}" == *:* ]]; then
            source_path="${folder_spec%%:*}"
            target_name="${folder_spec#*:}"
        else
            # If no target specified, use folder name as target
            source_path="${folder_spec}"
            target_name="$(basename "${source_path}")"
        fi
        
        # Check if source exists
        if [[ ! -d "${source_path}" ]]; then
            echo "WARNING: Folder '${source_path}' does not exist, skipping" >&2
            continue
        fi
        
        echo "$(format_date) backing up folder '${source_path}' as '${target_name}'"
        backup "${source_path}" "folders/${target_name}"
    done
}

function restic_stats {
    echo ""
    echo "$(format_date) repository statistics"
    echo ""
    
    local docker_args=()
    mapfile -t docker_args < <(build_docker_args)
    
    docker run "${docker_args[@]}" \
        restic/restic stats --mode raw-data
}

function restic_snapshots {
    echo ""
    echo "$(format_date) current snapshots"
    echo ""
    
    local docker_args=()
    mapfile -t docker_args < <(build_docker_args)
    
    docker run "${docker_args[@]}" \
        restic/restic snapshots
}

function restic_forget {
    echo ""
    echo "$(format_date) removing old snapshots"
    echo ""

    docker run --rm --name restic \
        -v backup_cache:/root/.cache/restic \
        -v ~/.restic/:/restic \
        -v /etc/localtime:/etc/localtime:ro \
        -e RESTIC_REPOSITORY=${REPOSITORY} \
	-e B2_ACCOUNT_ID=${B2_ACCOUNT_ID} \
        -e B2_ACCOUNT_KEY=${B2_ACCOUNT_KEY} \
        restic/restic forget -p /restic/passfile --keep-daily 14 --keep-weekly 12 --keep-monthly 12 --keep-yearly 5
}

function restic_prune {
    echo ""
    echo "$(format_date) removing old snapshot data"
    echo ""

    docker run --rm --name restic \
        -v backup_cache:/root/.cache/restic \
        -v ~/.restic/:/restic \
        -v /etc/localtime:/etc/localtime:ro \
        -e RESTIC_REPOSITORY=${REPOSITORY} \
	-e B2_ACCOUNT_ID=${B2_ACCOUNT_ID} \
        -e B2_ACCOUNT_KEY=${B2_ACCOUNT_KEY} \
        restic/restic prune -p /restic/passfile
}


function restic_unlock {
    echo ""
    echo "$(format_date) unlocking repository"
    echo ""
    
    local docker_args=()
    mapfile -t docker_args < <(build_docker_args)
    
    docker run "${docker_args[@]}" \
        restic/restic unlock
}

function restic_check {
    echo ""
    echo "$(format_date) checking repository integrity"
    echo ""
    
    local docker_args=()
    mapfile -t docker_args < <(build_docker_args)
    
    docker run "${docker_args[@]}" \
        restic/restic check
}

function restic_restore {
    local snapshot_id="$1"
    local target_path="$2"
    
    # Validate parameters
    if [[ -z "${snapshot_id}" ]]; then
        echo "ERROR: Snapshot ID is required" >&2
        echo "Usage: restic_restore <snapshot-id> <target-path>" >&2
        return 1
    fi
    
    if [[ -z "${target_path}" ]]; then
        echo "ERROR: Target path is required" >&2
        echo "Usage: restic_restore <snapshot-id> <target-path>" >&2
        return 1
    fi
    
    # Create target directory if it doesn't exist
    if [[ ! -d "${target_path}" ]]; then
        echo "$(format_date) creating target directory: ${target_path}"
        mkdir -p "${target_path}"
    fi
    
    # Make path absolute
    target_path="$(cd "${target_path}" && pwd)"
    
    echo ""
    echo "$(format_date) restoring snapshot '${snapshot_id}' to '${target_path}'"
    echo ""
    
    local docker_args=()
    mapfile -t docker_args < <(build_restore_docker_args "${target_path}")
    
    docker run "${docker_args[@]}" \
        restic/restic restore "${snapshot_id}" --target /restore --verbose
    
    echo ""
    echo "$(format_date) restore completed"
    echo ""
}

