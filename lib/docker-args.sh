#!/bin/bash

# Docker argument builders for different repository types

# Build complete docker arguments based on repository type
# Optional parameters can be passed via associative array name
function build_docker_args {
    local docker_args=(
        --rm
        --name restic
        -v "${CACHE_VOLUME_NAME}:/root/.cache/restic"
        -v "$(dirname "${RESTIC_PASSWORD_FILE}"):/restic:ro"
        -v /etc/localtime:/etc/localtime:ro
        -v /etc/timezone:/etc/timezone:ro
        -e "RESTIC_PASSWORD_FILE=/restic/$(basename "${RESTIC_PASSWORD_FILE}")"
    )
    
    # Add repository-specific arguments
    if [[ "${REPOSITORY}" =~ ^s3: ]]; then
        # S3-compatible repository
        docker_args+=(
            -e "RESTIC_REPOSITORY=${REPOSITORY}"
            -e "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}"
            -e "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}"
        )
    elif [[ "${REPOSITORY}" =~ ^/ ]]; then
        # Local repository
        docker_args+=(
            -v "${REPOSITORY}:${REPOSITORY}"
            -e "RESTIC_REPOSITORY=${REPOSITORY}"
        )
    fi
    
    # Return the array by printing each element
    printf '%s\n' "${docker_args[@]}"
}

# Build docker arguments for backup with source mount
function build_backup_docker_args {
    local source_path="$1"
    local mount_target="$2"
    
    # Get base args
    local docker_args=()
    mapfile -t docker_args < <(build_docker_args)
    
    # Mount source at its original path to preserve path information in snapshots
    docker_args+=(-v "${source_path}:${source_path}:ro")
    
    # Return the array by printing each element
    printf '%s\n' "${docker_args[@]}"
}

# Build docker arguments for restore with target mount
function build_restore_docker_args {
    local target_path="$1"
    
    # Get base args
    local docker_args=()
    mapfile -t docker_args < <(build_docker_args)
    
    # Add target volume mount (read-write for restore)
    docker_args+=(-v "${target_path}:/restore")
    
    # Return the array by printing each element
    printf '%s\n' "${docker_args[@]}"
}

# Build docker arguments for docker volume backup
function build_volume_backup_docker_args {
    local volume_name="$1"
    local backup_path="/volumes/${volume_name}"
    
    # Get base args
    local docker_args=()
    mapfile -t docker_args < <(build_docker_args)
    
    # Mount docker volume to a specific path in container
    docker_args+=(-v "${volume_name}:${backup_path}:ro")
    
    # Return the array by printing each element
    printf '%s\n' "${docker_args[@]}"
}
