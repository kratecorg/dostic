#!/bin/bash

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
        -v ${BACKUP_BASEDIR}/dostic/restic:/restic_data/ \
        -e RESTIC_REPOSITORY=/restic_data/ \
        restic/restic backup -p /restic/passfile --verbose --host ${HOST} /data/${TARGET}/
}


function backup_init {
    docker run --rm --name restic \
        -v backup_cache:/root/.cache/restic \
        -v ~/.restic/:/restic \
        -v /etc/localtime:/etc/localtime:ro \
        -v ${BACKUP_BASEDIR}/dostic/restic:/restic_data/ \
        -e RESTIC_REPOSITORY=/restic_data/ \
        restic/restic init -p /restic/passfile
}


function backup_postgres {
    echo ""
    echo "$(format_date) backing up postgres databases"
    echo ""

    mkdir -p ${BACKUP_DIR}/postgres/
    rm ${BACKUP_DIR}/postgres/*
    docker ps -a --format '{{.Names}}\t{{.Ports}}' | grep 5432/tcp | awk '{ print $1 }' | while read -r line; do
        echo "$(format_date) extracting database from container '${line}'"
        docker exec -t ${line} pg_dumpall -v --lock-wait-timeout=600 -c -U postgres -f /tmp/export.sql
        docker cp ${line}:/tmp/export.sql ${BACKUP_DIR}/postgres/${line}.sql
        docker exec -t ${line} rm /tmp/export.sql
    done
    backup ${BACKUP_DIR}/postgres/ postgres
}

function backup_mysql {
    echo ""
    echo "$(format_date) backing up mysql databases"
    echo ""

    mkdir -p ${BACKUP_DIR}/mysql/
    rm ${BACKUP_DIR}/mysql/*
    docker ps -a --format '{{.Names}}\t{{.Ports}}' | grep 3306/tcp | awk '{ print $1 }' | while read -r line; do
        echo "$(format_date) extracting database from container '${line}'"
        docker exec -t ${line} sh -c 'mysqldump -uroot -p"${MYSQL_ROOT_PASSWORD}" -A -r /tmp/export.sql'
        docker cp ${line}:/tmp/export.sql ${BACKUP_DIR}/mysql/${line}.sql
        docker exec -t ${line} rm /tmp/export.sql
    done
    backup ${BACKUP_DIR}/mysql/ mysql
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

function display_current_state {
    echo ""
    echo "$(format_date) current snapshots"
    echo ""

    docker run --rm --name restic \
        -v backup_cache:/root/.cache/restic \
        -v ~/.restic/:/restic \
        -v /etc/localtime:/etc/localtime:ro \
        -v ${BACKUP_BASEDIR}/dostic/restic:/restic_data/ \
        -e RESTIC_REPOSITORY=/restic_data/ \
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
        -v ${BACKUP_BASEDIR}/dostic/restic:/restic_data/ \
        -e RESTIC_REPOSITORY=/restic_data/ \
        restic/restic forget -p /restic/passfile --keep-daily 14 --keep-weekly 12 --keep-monthly 12 --keep-yearly 5
}
