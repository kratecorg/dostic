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
    
    # Convert to absolute path if relative
    if [[ ! "${source_path}" =~ ^/ ]]; then
        source_path="$(cd "${source_path}" 2>/dev/null && pwd)" || source_path="$(realpath "${source_path}" 2>/dev/null)"
    fi
    
    # Build target path for container (always under /backups/)
    local container_path="/backups/${target_name}"
    
    echo ""
    echo "$(format_date) backing up '${source_path}' as '${target_name}'"
    echo ""
    
    local docker_args=()
    mapfile -t docker_args < <(build_backup_docker_args "${source_path}" "${container_path}")
    
    # Add hostname if set
    local host_arg=()
    if [[ -n "${HOST:-}" ]]; then
        host_arg=(--host "${HOST}")
    fi
    
    # Add tags for better organization
    local tag_args=(--tag "${target_name}")
    
    docker run "${docker_args[@]}" \
        restic/restic backup "${host_arg[@]}" "${tag_args[@]}" --verbose "${container_path}"
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

function backup_postgres {
    echo ""
    echo "$(format_date) backing up postgres databases"
    echo ""

    # Use BACKUP_BASEDIR or fallback to /tmp/backups
    local backup_base="${BACKUP_BASEDIR}/postgres"
    mkdir -p "${backup_base}"
    
    # Find all postgres containers (port 5432)
    local postgres_containers=$(docker ps -a --format '{{.Names}}\t{{.Ports}}' | grep 5432/tcp | awk '{ print $1 }')
    
    if [[ -z "${postgres_containers}" ]]; then
        echo "$(format_date) no postgres containers found, skipping"
        return 0
    fi
    
    # Dump each postgres database separately
    echo "${postgres_containers}" | while read -r container; do
        echo "$(format_date) extracting database from container '${container}'"
        
        # Create container-specific directory
        local container_dir="${backup_base}/${container}"
        mkdir -p "${container_dir}"
        rm -f "${container_dir}"/*
        echo "container_dir: ${container_dir}"
        
        local dump_success=false
        local dump_user=""
        
        # Try different postgres users in order
        for user in "postgres" "\${POSTGRES_USER}" "\$(whoami)" ""; do
            local user_arg=""
            
            if [[ -n "${user}" ]]; then
                # Expand environment variable if it looks like one
                if [[ "${user}" == \$* ]]; then
                    user_arg="-U ${user}"
                else
                    user_arg="-U ${user}"
                fi
            fi
            
            # Try to dump with this user
            if docker exec -t "${container}" sh -c "pg_dumpall -v --lock-wait-timeout=600 -c ${user_arg} -f /tmp/export.sql" 2>/dev/null; then
                dump_success=true
                dump_user="${user:-default}"
                break
            fi
        done
        
        if [[ "${dump_success}" == "true" ]]; then
            docker cp "${container}:/tmp/export.sql" "${container_dir}/${container}.dump.sql"
            docker exec -t "${container}" rm /tmp/export.sql
            echo "$(format_date) successfully dumped database from '${container}' (user: ${dump_user})"
            
            # Backup this specific container's dump with absolute path
            local abs_container_dir="$(cd "${container_dir}" && pwd)"
            backup "${abs_container_dir}" "postgres/${container}"
        else
            echo "$(format_date) WARNING: failed to dump database from '${container}' with any user" >&2
        fi
    done
}

function backup_mysql {
    echo ""
    echo "$(format_date) backing up mysql databases"
    echo ""

    # Use BACKUP_BASEDIR or fallback to /tmp/backups
    local backup_base="${BACKUP_BASEDIR}/mysql"
    mkdir -p "${backup_base}"
    
    # Find all mysql containers (port 3306)
    local mysql_containers=$(docker ps -a --format '{{.Names}}\t{{.Ports}}' | grep 3306/tcp | awk '{ print $1 }')
    
    if [[ -z "${mysql_containers}" ]]; then
        echo "$(format_date) no mysql containers found, skipping"
        return 0
    fi
    
    # Dump each mysql database separately
    echo "${mysql_containers}" | while read -r container; do
        echo "$(format_date) extracting database from container '${container}'"
        
        # Create container-specific directory
        local container_dir="${backup_base}/${container}"
        mkdir -p "${container_dir}"
        rm -f "${container_dir}"/*
        
        local dump_success=false
        
        # Try to dump with root user and MYSQL_ROOT_PASSWORD env var
        if docker exec -t "${container}" sh -c 'mysqldump -uroot -p"${MYSQL_ROOT_PASSWORD}" -A -r /tmp/export.sql' 2>/dev/null; then
            dump_success=true
        fi
        
        if [[ "${dump_success}" == "true" ]]; then
            docker cp "${container}:/tmp/export.sql" "${container_dir}/${container}.dump.sql"
            docker exec -t "${container}" rm /tmp/export.sql
            echo "$(format_date) successfully dumped database from '${container}'"
            
            # Backup this specific container's dump with absolute path
            local abs_container_dir="$(cd "${container_dir}" && pwd)"
            backup "${abs_container_dir}" "mysql/${container}"
        else
            echo "$(format_date) WARNING: failed to dump database from '${container}'" >&2
        fi
    done
}


function backup_docker_volumes {
    echo ""
    echo "$(format_date) backing up docker volumes"
    echo ""

    # Get list of named volumes (exclude hash-only volumes)
    local volumes=$(docker volume list -q | egrep -v '^.{64}$')
    
    if [[ -z "${volumes}" ]]; then
        echo "$(format_date) no docker volumes found, skipping"
        return 0
    fi
    
    # Backup each volume separately
    echo "${volumes}" | while read -r volume; do
        # Skip cache volume
        if [[ "${volume}" == "${CACHE_VOLUME_NAME}" ]]; then
            echo "$(format_date) skipping cache volume '${volume}'"
            continue
        fi
        
        # Check if volume should be excluded
        local should_skip=false
        
        # Check EXCLUDE_VOLUMES (comma-separated list of exact names)
        if [[ -n "${EXCLUDE_VOLUMES:-}" ]]; then
            IFS=',' read -ra exclude_list <<< "${EXCLUDE_VOLUMES}"
            for exclude_pattern in "${exclude_list[@]}"; do
                exclude_pattern=$(echo "${exclude_pattern}" | xargs)  # trim whitespace
                if [[ "${volume}" == "${exclude_pattern}" ]]; then
                    echo "$(format_date) skipping excluded volume '${volume}' (exact match)"
                    should_skip=true
                    break
                fi
            done
        fi
        
        # Check EXCLUDE_VOLUMES_REGEX (regex pattern)
        if [[ "${should_skip}" == "false" ]] && [[ -n "${EXCLUDE_VOLUMES_REGEX:-}" ]]; then
            if [[ "${volume}" =~ ${EXCLUDE_VOLUMES_REGEX} ]]; then
                echo "$(format_date) skipping excluded volume '${volume}' (regex match)"
                should_skip=true
            fi
        fi
        
        # Skip if matched any exclude pattern
        if [[ "${should_skip}" == "true" ]]; then
            continue
        fi
        
        echo "$(format_date) backing up docker volume '${volume}'"
        
        local docker_args=()
        mapfile -t docker_args < <(build_volume_backup_docker_args "${volume}")
        
        # Add hostname if set
        local host_arg=()
        if [[ -n "${HOST:-}" ]]; then
            host_arg=(--host "${HOST}")
        fi
        
        # Add tags for better organization
        local tag_args=(--tag "volume/${volume}")
        
        # Backup the volume
        docker run "${docker_args[@]}" \
            restic/restic backup "${host_arg[@]}" "${tag_args[@]}" --verbose "/backups/volumes/${volume}"
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

    local docker_args=()
    mapfile -t docker_args < <(build_docker_args)
    
    # Use configurable retention policy or defaults
    local keep_daily="${KEEP_DAILY:-14}"
    local keep_weekly="${KEEP_WEEKLY:-12}"
    local keep_monthly="${KEEP_MONTHLY:-12}"
    local keep_yearly="${KEEP_YEARLY:-5}"
    
    echo "$(format_date) retention policy: daily=${keep_daily}, weekly=${keep_weekly}, monthly=${keep_monthly}, yearly=${keep_yearly}"
    
    docker run "${docker_args[@]}" \
        restic/restic forget \
            --keep-daily "${keep_daily}" \
            --keep-weekly "${keep_weekly}" \
            --keep-monthly "${keep_monthly}" \
            --keep-yearly "${keep_yearly}" \
            --prune
}

function restic_prune {
    echo ""
    echo "$(format_date) removing old snapshot data"
    echo ""

    local docker_args=()
    mapfile -t docker_args < <(build_docker_args)
    
    docker run "${docker_args[@]}" \
        restic/restic prune
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

