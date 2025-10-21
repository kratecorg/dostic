#!/bin/bash

# Configuration validation functions

# Validate required configuration
function validate_config {
    local errors=0
    
    # Check if RESTIC_PASSWORD_FILE is set
    if [[ -z "${RESTIC_PASSWORD_FILE:-}" ]]; then
        log_error "RESTIC_PASSWORD_FILE not set in configuration"
        errors=$((errors + 1))
    else
        # Check if password file exists
        if [[ ! -f "${RESTIC_PASSWORD_FILE}" ]]; then
            log_error "Password file does not exist" "file=${RESTIC_PASSWORD_FILE}"
            errors=$((errors + 1))
        else
            # Check file permissions (must be 0600 or 0700)
            local perms=$(stat -c "%a" "${RESTIC_PASSWORD_FILE}")
            if [[ "${perms}" != "600" ]] && [[ "${perms}" != "700" ]]; then
                log_error "Password file has insecure permissions" "file=${RESTIC_PASSWORD_FILE}" "current=${perms}" "required=0600"
                log_info "Fix with: chmod 600 ${RESTIC_PASSWORD_FILE}"
                errors=$((errors + 1))
            fi
        fi
    fi
    
    # Check repository type and required variables
    if [[ -z "${REPOSITORY:-}" ]]; then
        log_error "REPOSITORY not set in configuration"
        errors=$((errors + 1))
    else
        # Detect repository type
        if [[ "${REPOSITORY}" =~ ^s3: ]]; then
            # S3-compatible repository
            if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
                log_error "AWS_ACCESS_KEY_ID required for S3 repository" "repo=${REPOSITORY}"
                errors=$((errors + 1))
            fi
            if [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
                log_error "AWS_SECRET_ACCESS_KEY required for S3 repository" "repo=${REPOSITORY}"
                errors=$((errors + 1))
            fi
        elif [[ "${REPOSITORY}" =~ ^/ ]]; then
            # Local repository - ensure parent directory exists
            local repo_parent=$(dirname "${REPOSITORY}")
            if [[ ! -d "${repo_parent}" ]]; then
                log_error "Parent directory for local repository does not exist" "dir=${repo_parent}"
                errors=$((errors + 1))
            fi
        else
            log_error "Unsupported repository type" "repo=${REPOSITORY}"
            log_info "Supported types: local path (/path/to/repo) or S3 (s3:endpoint/bucket)"
            errors=$((errors + 1))
        fi
    fi
    
    return ${errors}
}
