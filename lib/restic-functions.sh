#!/bin/bash

# Default cache volume name if not set in env
CACHE_VOLUME_NAME="${CACHE_VOLUME_NAME:-dostic_cache}"

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
        elif [[ "${REPOSITORY}" =~ ^/ ]] || [[ "${REPOSITORY}" =~ ^\. ]]; then
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

format_date() {
    date "+%Y-%m-%d %H:%M:%S"
}

function backup {
    SOURCE=$1
    TARGET=$2
    
    echo ""
    echo "$(format_date) backing up from ${SOURCE} to ${TARGET}"
    echo ""

    docker run --rm --name restic \
        -v backup_cache:/root/.cache/restic \
        -v ~/.restic/:/restic \
        -v /etc/localtime:/etc/localtime:ro \
        -v ${SOURCE}:/data/${TARGET}:ro \
        -e RESTIC_REPOSITORY=${REPOSITORY} \
	-e B2_ACCOUNT_ID=${B2_ACCOUNT_ID} \
        -e B2_ACCOUNT_KEY=${B2_ACCOUNT_KEY} \
        restic/restic backup -p /restic/passfile --verbose --host ${HOST} /data/${TARGET}/
}

function backup_init {
    echo ""
    echo "$(format_date) initializing restic repository"
    echo ""
    
    # Validate configuration before proceeding
    if ! validate_config; then
        echo "$(format_date) Configuration validation failed. Aborting." >&2
        return 1
    fi
    
    local docker_args=(
        --rm
        --name restic
        -v "${CACHE_VOLUME_NAME}:/root/.cache/restic"
        -v "$(dirname "${RESTIC_PASSWORD_FILE}"):/restic:ro"
        -v /etc/localtime:/etc/localtime:ro
        -e "RESTIC_PASSWORD_FILE=/restic/$(basename "${RESTIC_PASSWORD_FILE}")"
    )
    
    # Add S3 credentials if using S3 repository
    if [[ "${REPOSITORY}" =~ ^s3: ]]; then
        docker_args+=(
            -e "RESTIC_REPOSITORY=${REPOSITORY}"
            -e "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}"
            -e "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}"
        )
    fi
    
    # Add local repository mount if using local path
    if [[ "${REPOSITORY}" =~ ^/ ]] || [[ "${REPOSITORY}" =~ ^\. ]]; then
        docker_args+=(
            -v "${REPOSITORY}:/local/repository"
            -e "RESTIC_REPOSITORY=/local/repository"
        )
    fi
    
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

    backup /home system/home
    backup /root system/root
    backup /etc system/etc
}

function display_sizes {
    echo ""
    echo "$(format_date) current sizes"
    echo ""
    docker run --rm --name restic \
        -v backup_cache:/root/.cache/restic \
        -v ~/.restic/:/restic \
        -v /etc/localtime:/etc/localtime:ro \
        -v /backups/system/:/target/ \
        -e RESTIC_REPOSITORY=${REPOSITORY} \
        -e B2_ACCOUNT_ID=${B2_ACCOUNT_ID} \
        -e B2_ACCOUNT_KEY=${B2_ACCOUNT_KEY} \
        restic/restic stats --mode raw-data --json -p /restic/passfile

#    echo ${FOO} > /tmp/stats2.json
#    for id in $(echo ${FOO} | jq -r '.[].short_id'); do
#        echo $id

#    BAR=$(docker run --rm --name restic \
#        -v backup_cache:/root/.cache/restic \
#        -v ~/.restic/:/restic \
#        -v /etc/localtime:/etc/localtime:ro \
#        -v /backups/system/:/target/ \
#        -e RESTIC_REPOSITORY=${REPOSITORY} \
#        -e B2_ACCOUNT_ID=${B2_ACCOUNT_ID} \
#        -e B2_ACCOUNT_KEY=${B2_ACCOUNT_KEY} \
#        restic/restic stats --mode restored --snapshot ${id} -p /restic/passfile)
#    echo ${BAR}
#    RESULT=$(echo $BAR| grep 'Total File Size' | awk '{print $NF}')
#    echo "${id} - ${RESULT}"
#    size=$(restic stats --mode restored --snapshot $id | grep 'Total File Size' | awk '{print $NF}')
#    echo "$id - $size"
#    done

}

function display_current_state {
    echo ""
    echo "$(format_date) current snapshots"
    echo ""

    docker run --rm --name restic \
        -v backup_cache:/root/.cache/restic \
        -v ~/.restic/:/restic \
        -v /etc/localtime:/etc/localtime:ro \
        -e RESTIC_REPOSITORY=${REPOSITORY} \
	-e B2_ACCOUNT_ID=${B2_ACCOUNT_ID} \
        -e B2_ACCOUNT_KEY=${B2_ACCOUNT_KEY} \
        restic/restic snapshots -p /restic/passfile
}

function remove_old {
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

function prune {
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


function unlock {
    echo ""
    echo "$(format_date) unlocking repo"
    echo ""

    docker run --rm --name restic \
        -v backup_cache:/root/.cache/restic \
        -v ~/.restic/:/restic \
        -v /etc/localtime:/etc/localtime:ro \
        -e RESTIC_REPOSITORY=${REPOSITORY} \
	-e B2_ACCOUNT_ID=${B2_ACCOUNT_ID} \
        -e B2_ACCOUNT_KEY=${B2_ACCOUNT_KEY} \
        restic/restic unlock -p /restic/passfile
}

