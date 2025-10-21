#!/bin/bash

# Source library files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/logging.sh"
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
    
    log_info "Starting backup" "source=${source_path}" "target=${target_name}"
    
    local docker_args=()
    mapfile -t docker_args < <(build_backup_docker_args "${source_path}" "${container_path}")
    
    # Add hostname if set
    local host_arg=()
    if [[ -n "${HOST:-}" ]]; then
        host_arg=(--host "${HOST}")
    fi
    
    # Add tags for better organization
    local tag_args=(--tag "${target_name}")
    
    if ! docker run "${docker_args[@]}" \
        restic/restic backup "${host_arg[@]}" "${tag_args[@]}" --verbose "${container_path}"; then
        log_error "Backup failed" "target=${target_name}" "source=${source_path}"
        return 1
    fi
    
    log_success "Backup completed" "target=${target_name}"
}

function restic_init {
    log_info "Initializing restic repository" "repo=${REPOSITORY}"
    
    local docker_args=()
    mapfile -t docker_args < <(build_docker_args)
    
    if ! docker run "${docker_args[@]}" \
        restic/restic init --verbose; then
        log_error "Repository initialization failed" "repo=${REPOSITORY}"
        return 1
    fi
    
    log_success "Repository initialized" "repo=${REPOSITORY}"
}

function backup_postgres {
    log_section "PostgreSQL Backup" "type=postgres"

    # Use BACKUP_BASEDIR or fallback to /tmp/backups
    local backup_base="${BACKUP_BASEDIR}/postgres"
    mkdir -p "${backup_base}"
    
    # Find all postgres containers (port 5432)
    local postgres_containers=$(docker ps -a --format '{{.Names}}\t{{.Ports}}' | grep 5432/tcp | awk '{ print $1 }')
    
    if [[ -z "${postgres_containers}" ]]; then
        log_info "No PostgreSQL containers found, skipping" "port=5432"
        return 0
    fi
    
    # Dump each postgres database separately
    echo "${postgres_containers}" | while read -r container; do
        log_info "Extracting database" "container=${container}" "type=postgres"
        
        # Create container-specific directory
        local container_dir="${backup_base}/${container}"
        mkdir -p "${container_dir}"
        rm -f "${container_dir}"/*
        
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
            log_debug "Trying pg_dumpall" "container=${container}" "user=${user:-default}"
            if docker exec -t "${container}" sh -c "pg_dumpall -v --lock-wait-timeout=600 -c ${user_arg} -f /tmp/export.sql" 2>/dev/null; then
                dump_success=true
                dump_user="${user:-default}"
                break
            fi
        done
        
        if [[ "${dump_success}" == "true" ]]; then
            docker cp "${container}:/tmp/export.sql" "${container_dir}/${container}.dump.sql"
            docker exec -t "${container}" rm /tmp/export.sql
            log_success "Database dump completed" "container=${container}" "user=${dump_user}"
            
            # Backup this specific container's dump with absolute path
            local abs_container_dir="$(cd "${container_dir}" && pwd)"
            if ! backup "${abs_container_dir}" "postgres/${container}"; then
                log_error "Backup failed" "container=${container}" "type=postgres"
                return 1
            fi
        else
            log_warn "Failed to dump database with any user" "container=${container}"
        fi
    done
}

function backup_mysql {
    log_section "MySQL Backup" "type=mysql"

    # Use BACKUP_BASEDIR or fallback to /tmp/backups
    local backup_base="${BACKUP_BASEDIR}/mysql"
    mkdir -p "${backup_base}"
    
    # Find all mysql containers (port 3306)
    local mysql_containers=$(docker ps -a --format '{{.Names}}\t{{.Ports}}' | grep 3306/tcp | awk '{ print $1 }')
    
    if [[ -z "${mysql_containers}" ]]; then
        log_info "No MySQL containers found, skipping" "port=3306"
        return 0
    fi
    
    # Dump each mysql database separately
    echo "${mysql_containers}" | while read -r container; do
        log_info "Extracting database" "container=${container}" "type=mysql"
        
        # Create container-specific directory
        local container_dir="${backup_base}/${container}"
        mkdir -p "${container_dir}"
        rm -f "${container_dir}"/*
        
        local dump_success=false
        
        # Try to dump with root user and MYSQL_ROOT_PASSWORD env var
        log_debug "Trying mysqldump" "container=${container}" "user=root"
        if docker exec -t "${container}" sh -c 'mysqldump -uroot -p"${MYSQL_ROOT_PASSWORD}" -A -r /tmp/export.sql' 2>/dev/null; then
            dump_success=true
        fi
        
        if [[ "${dump_success}" == "true" ]]; then
            docker cp "${container}:/tmp/export.sql" "${container_dir}/${container}.dump.sql"
            docker exec -t "${container}" rm /tmp/export.sql
            log_success "Database dump completed" "container=${container}"
            
            # Backup this specific container's dump with absolute path
            local abs_container_dir="$(cd "${container_dir}" && pwd)"
            if ! backup "${abs_container_dir}" "mysql/${container}"; then
                log_error "Backup failed" "container=${container}" "type=mysql"
                return 1
            fi
        else
            log_warn "Failed to dump database" "container=${container}"
        fi
    done
}


function backup_docker_volumes {
    log_section "Docker Volumes Backup" "type=volumes"

    # Get list of named volumes (exclude hash-only volumes)
    local volumes=$(docker volume list -q | egrep -v '^.{64}$')
    
    if [[ -z "${volumes}" ]]; then
        log_info "No Docker volumes found, skipping"
        return 0
    fi
    
    # Backup each volume separately
    echo "${volumes}" | while read -r volume; do
        # Skip cache volume
        if [[ "${volume}" == "${CACHE_VOLUME_NAME}" ]]; then
            log_debug "Skipping cache volume" "volume=${volume}"
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
                    log_info "Skipping excluded volume" "volume=${volume}" "reason=exact_match"
                    should_skip=true
                    break
                fi
            done
        fi
        
        # Check EXCLUDE_VOLUMES_REGEX (regex pattern)
        if [[ "${should_skip}" == "false" ]] && [[ -n "${EXCLUDE_VOLUMES_REGEX:-}" ]]; then
            if [[ "${volume}" =~ ${EXCLUDE_VOLUMES_REGEX} ]]; then
                log_info "Skipping excluded volume" "volume=${volume}" "reason=regex_match"
                should_skip=true
            fi
        fi
        
        # Skip if matched any exclude pattern
        if [[ "${should_skip}" == "true" ]]; then
            continue
        fi
        
        log_info "Backing up Docker volume" "volume=${volume}"
        
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
        if ! docker run "${docker_args[@]}" \
            restic/restic backup "${host_arg[@]}" "${tag_args[@]}" --verbose "/backups/volumes/${volume}"; then
            log_error "Volume backup failed" "volume=${volume}"
            return 1
        fi
        
        log_success "Volume backup completed" "volume=${volume}"
    done
}

function backup_folders {
    log_section "Folders Backup" "type=folders"

    # Check if BACKUP_FOLDERS is set
    if [[ -z "${BACKUP_FOLDERS:-}" ]]; then
        log_warn "BACKUP_FOLDERS not set in configuration, skipping folder backup"
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
            log_warn "Folder does not exist, skipping" "path=${source_path}"
            continue
        fi
        
        log_info "Backing up folder" "source=${source_path}" "target=${target_name}"
        if ! backup "${source_path}" "folders/${target_name}"; then
            log_error "Folder backup failed" "path=${source_path}"
            return 1
        fi
    done
}

function restic_stats {
    log_section "Repository Statistics"
    
    local docker_args=()
    mapfile -t docker_args < <(build_docker_args)
    
    if ! docker run "${docker_args[@]}" \
        restic/restic stats --mode raw-data; then
        log_error "Failed to retrieve repository statistics" "repo=${REPOSITORY}"
        return 1
    fi
}

function restic_snapshots {
    log_section "Current Snapshots"
    
    local docker_args=()
    mapfile -t docker_args < <(build_docker_args)
    
    if ! docker run "${docker_args[@]}" \
        restic/restic snapshots; then
        log_error "Failed to retrieve snapshots" "repo=${REPOSITORY}"
        return 1
    fi
}

function restic_forget {
    log_section "Removing Old Snapshots"

    local docker_args=()
    mapfile -t docker_args < <(build_docker_args)
    
    # Use configurable retention policy or defaults
    local keep_daily="${KEEP_DAILY:-14}"
    local keep_weekly="${KEEP_WEEKLY:-12}"
    local keep_monthly="${KEEP_MONTHLY:-12}"
    local keep_yearly="${KEEP_YEARLY:-5}"
    
    log_info "Applying retention policy" "daily=${keep_daily}" "weekly=${keep_weekly}" "monthly=${keep_monthly}" "yearly=${keep_yearly}"
    
    if ! docker run "${docker_args[@]}" \
        restic/restic forget \
            --keep-daily "${keep_daily}" \
            --keep-weekly "${keep_weekly}" \
            --keep-monthly "${keep_monthly}" \
            --keep-yearly "${keep_yearly}" \
            --prune; then
        log_error "Failed to remove old snapshots" "repo=${REPOSITORY}"
        return 1
    fi
    
    log_success "Old snapshots removed"
}

function restic_prune {
    log_section "Pruning Repository"

    local docker_args=()
    mapfile -t docker_args < <(build_docker_args)
    
    if ! docker run "${docker_args[@]}" \
        restic/restic prune; then
        log_error "Failed to prune repository" "repo=${REPOSITORY}"
        return 1
    fi
    
    log_success "Repository pruned"
}


function restic_unlock {
    log_section "Unlocking Repository"
    
    local docker_args=()
    mapfile -t docker_args < <(build_docker_args)
    
    if ! docker run "${docker_args[@]}" \
        restic/restic unlock; then
        log_error "Failed to unlock repository" "repo=${REPOSITORY}"
        return 1
    fi
    
    log_success "Repository unlocked"
}

function restic_check {
    log_section "Checking Repository Integrity"
    
    local docker_args=()
    mapfile -t docker_args < <(build_docker_args)
    
    if ! docker run "${docker_args[@]}" \
        restic/restic check; then
        log_error "Repository integrity check failed" "repo=${REPOSITORY}"
        return 1
    fi
    
    log_success "Repository integrity verified"
}

function restic_restore {
    local snapshot_id="$1"
    local target_path="$2"
    
    # Validate parameters
    if [[ -z "${snapshot_id}" ]]; then
        log_error "Snapshot ID is required"
        log_info "Usage: restic_restore <snapshot-id> <target-path>"
        return 1
    fi
    
    if [[ -z "${target_path}" ]]; then
        log_error "Target path is required"
        log_info "Usage: restic_restore <snapshot-id> <target-path>"
        return 1
    fi
    
    # Create target directory if it doesn't exist
    if [[ ! -d "${target_path}" ]]; then
        log_info "Creating target directory" "path=${target_path}"
        mkdir -p "${target_path}"
    fi
    
    # Make path absolute
    target_path="$(cd "${target_path}" && pwd)"
    
    log_section "Restoring Snapshot" "snapshot=${snapshot_id}" "target=${target_path}"
    
    local docker_args=()
    mapfile -t docker_args < <(build_restore_docker_args "${target_path}")
    
    if ! docker run "${docker_args[@]}" \
        restic/restic restore "${snapshot_id}" --target /restore --verbose; then
        log_error "Restore failed" "snapshot=${snapshot_id}" "target=${target_path}"
        return 1
    fi
    
    log_success "Restore completed" "snapshot=${snapshot_id}" "target=${target_path}"
}

