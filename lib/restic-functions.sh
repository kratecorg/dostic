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
        -e RESTIC_REPOSITORY=${REPOSITORY} \
	-e B2_ACCOUNT_ID=${B2_ACCOUNT_ID} \
        -e B2_ACCOUNT_KEY=${B2_ACCOUNT_KEY} \
        restic/restic backup -p /restic/passfile --verbose --host ${HOST} /data/${TARGET}/
}


function backup_init {
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

