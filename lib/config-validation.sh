#!/bin/bash

# Configuration validation functions

# Validate required configuration
function validate_config {
    local errors=0
    
    # Check if RESTIC_PASSWORD_FILE is set
    if [[ -z "${RESTIC_PASSWORD_FILE:-}" ]]; then
        echo "ERROR: RESTIC_PASSWORD_FILE is not set in configuration" >&2
        errors=$((errors + 1))
    else
        # Check if password file exists
        if [[ ! -f "${RESTIC_PASSWORD_FILE}" ]]; then
            echo "ERROR: Password file '${RESTIC_PASSWORD_FILE}' does not exist" >&2
            errors=$((errors + 1))
        else
            # Check file permissions (must be 0600 or 0700)
            local perms=$(stat -c "%a" "${RESTIC_PASSWORD_FILE}")
            if [[ "${perms}" != "600" ]] && [[ "${perms}" != "700" ]]; then
                echo "ERROR: Password file '${RESTIC_PASSWORD_FILE}' must have permissions 0600 or 0700 (current: ${perms})" >&2
                echo "Fix with: chmod 600 ${RESTIC_PASSWORD_FILE}" >&2
                errors=$((errors + 1))
            fi
        fi
    fi
    
    # Check repository type and required variables
    if [[ -z "${REPOSITORY:-}" ]]; then
        echo "ERROR: REPOSITORY is not set in configuration" >&2
        errors=$((errors + 1))
    else
        # Detect repository type
        if [[ "${REPOSITORY}" =~ ^s3: ]]; then
            # S3-compatible repository
            if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
                echo "ERROR: AWS_ACCESS_KEY_ID required for S3 repository" >&2
                errors=$((errors + 1))
            fi
            if [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
                echo "ERROR: AWS_SECRET_ACCESS_KEY required for S3 repository" >&2
                errors=$((errors + 1))
            fi
        elif [[ "${REPOSITORY}" =~ ^/ ]]; then
            # Local repository - ensure parent directory exists
            local repo_parent=$(dirname "${REPOSITORY}")
            if [[ ! -d "${repo_parent}" ]]; then
                echo "ERROR: Parent directory '${repo_parent}' for local repository does not exist" >&2
                errors=$((errors + 1))
            fi
        else
            echo "ERROR: Unsupported repository type: ${REPOSITORY}" >&2
            echo "Supported types: local path (/path/to/repo) or S3 (s3:endpoint/bucket)" >&2
            errors=$((errors + 1))
        fi
    fi
    
    return ${errors}
}
