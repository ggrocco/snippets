#!/bin/bash

if [ -z "$1" ] ; then
    echo "Needs to informe the db instance identifier"
    echo "./aws_mysql_download_slow_queries.sh DATABASE_INSTANCE_IDENTIFIER"
    exit 1;
fi


echo "Downloading the file slowquery/mysql-slowquery.log"
aws rds download-db-log-file-portion \
        --db-instance-identifier $1 \
        --log-file-name slowquery/mysql-slowquery.log  \
        --output text \
        > slowquery-`date +'%Y-%m-%d'`.log

for i in {0..23}
do
    echo "Downloading the file slowquery/mysql-slowquery.log.$i"
    aws rds download-db-log-file-portion \
        --db-instance-identifier $1 \
        --log-file-name slowquery/mysql-slowquery.log.$i  \
        --output text \
        >> slowquery-`date +'%Y-%m-%d'`.log
done
