#!/bin/bash

# Docker argument builders for different repository types

# Build complete docker arguments based on repository type
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

