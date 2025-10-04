#!/bin/bash

# Source library files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/defaults.sh"
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/config-validation.sh"
source "${SCRIPT_DIR}/docker-args.sh"

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

    backup /home system/home
    backup /root system/root
    backup /etc system/etc
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

