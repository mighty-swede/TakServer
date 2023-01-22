#!/bin/bash

# Script to set up the TAKServer database.
# This is meant to be run as root.
# Since it asks the user for confirmation before obliterating his database,
# it cannot be run by the RPM installer and must be a manual post-install step.
#
# Usage: takserver-db-setup.sh [db-name]
#

#if [ "$EUID" -ne 0 ]
#  then echo "$0 must be run as root."
#  exit 1
#fi

username='martiuser'
password=""
#
# try to get password from /opt/tak/CoreConfig.xml
#
if [ -f "/opt/tak/CoreConfig.xml" ]; then
  password=$(echo $(grep -m 1 "<connection" /opt/tak/CoreConfig.xml)  | sed 's/.*password="//; s/".*//')
fi
#
# try to get password from /opt/tak/CoreConfig.example.xml
#
if [ -z "$password" ]; then
  if [ -f "/opt/tak/CoreConfig.example.xml" ]; then
    password=$(echo $(grep -m 1 "<connection" /opt/tak/CoreConfig.example.xml)  | sed 's/.*password="//; s/".*//')
  fi
fi
#
# cant find password - request one from user
#
if [ -z "$password" ]; then
  : ${1?' Could not find a password in /opt/tak/CoreConfig.xml or /opt/tak/CoreConfig.example.xml. Please supply a plaintext database password as the first parameter'}
  password=$1
fi

md5pass=$(echo -n "md5" && echo -n "$password$username" | md5sum | tr -dc "a-zA-Z0-9\n")

#
# switch CWD to the location where this script resides
#
cd `dirname $0`

DB_NAME=$1
if [ $# -lt 1 ]; then
  DB_NAME=cot
fi

DB_INIT=""

#
# Get postgresql servicename 
#
PGSERVICE=$(systemctl list-unit-files | awk '/postgresql/{print $1}')
if [ -z "PGSERVICE" ]; then
	echo "Postgresql service not found - Exit"
	exit 1
fi 
#
# Get postgresql version
#
PGVERSION=$(psql -V | awk '{printf "%d\n", $3}')
if [ -z "PGVERSION" ]; then
	echo "Postgresql version not found - Exit"
	exit 1
fi 

#
# info to user
#
echo "Found postgresql service: ${PGSERVICE}"
echo "Found postgrelql version: ${PGVERSION}"

#
# DB init
#
if [ -x /usr/pgsql-${PGVERSION}/bin/postgresql-${PGVERSION}-setup ]; then
    DB_INIT="/usr/pgsql-${PGVERSION}/bin/postgresql-${PGVERSION}-setup initdb"
fi

if [ -n "$DB_INIT" ]; then
	echo -n "Database initialization: " 
	$DB_INIT 
	if [ $? -eq 0 ]; then
    	echo "PostgreSQL ${PGVERSION} database initialized successfully"
	else
    	echo "WARNING: Failed to initialize PostgreSQL ${PGVERSION} database"
    	echo "This could simply mean your database has already been initialized"
	fi
else
	echo "ERROR: Unable to automatically find setup for PostgreSQL ${PGVERSION} database"
	echo "ERROR: initdb fail. Exit"
	exit 1
fi
	
#
# check if service is enabled
#
if [ "$(systemctl is-enabled ${PGSERVICE})" = "disabled" ]; then
   	systemctl enable ${PGSERVICE}
   	if [ $? -eq 0 ]; then
    	echo "PostgreSQL ${PGVERSION} enable successfully"
	else
    	echo "ERROR: PostgreSQL ${PGVERSION} enable sevice fail!"
    fi
   	export PGDATA=/var/lib/pgsql/${PGVERSION}/data
fi  
#
# Start postgres 
#
if [ "$(systemctl is-active ${PGSERVICE})" = "inactive" ]; then
   	systemctl start ${PGSERVICE}
   	if [ $? -eq 0 ]; then
    	echo "PostgreSQL ${PGVERSION} start successfully"
	else
    	echo "ERROR: PostgreSQL ${PGVERSION} start fail!"
    fi
fi


if [ ! -d $PGDATA ]; then
	echo "ERROR: Cannot find PostgreSQL ${PGVERSION} data directory. Please set PGDATA manually and re-run"
	exit 1
fi
#
# Get user's permission before obliterating the database
#
DB_EXISTS=$(su postgres -c "psql -l 2>/dev/null" |  egrep ^[[:blank:]]?$DB_NAME[[:blank:]])

if [ -n "$DB_EXISTS" ]; then
	echo "WARNING: Database $DB_NAME' already exists!"
   	echo "Proceeding will DESTROY your existing data!"
   	echo "You can back up your data using the pg_dump command. (See 'man pg_dump' for details.)"
   	read -p "Type 'erase' (without quotes) to erase the '$DB_NAME' database now:" kickme
   	if [ "$kickme" != "erase" ]; then
    	echo "User didn't say 'erase'. Aborting"
      	exit 1
   	fi
   	su postgres -c "psql --command='drop database if exists $DB_NAME;'"
   	if [ $? -eq 0 ]; then
    	echo "Drop database $DB_NAME successfully"
	else
    	echo "ERROR: Drop database $DB_NAME fail!"
    fi
fi 

if [ -e pg_hba.conf ]; then
  IS_DOCKER='true'
fi

#
# Install our version of pg_hba.conf
#
echo "Installing TAKServer's version of PostgreSQL ${PGVERSION} access-control policy"
#
# Back up pg_hba.conf
#
BACKUP_SUFFIX=`date --rfc-3339='seconds' | sed 's/ /-/'`
HBA_BACKUP=$PGDATA/pg_hba.conf.backup-$BACKUP_SUFFIX

if [ -e /opt/tak/db-utils/pg_hba.conf ] || [ -e pg_hba.conf ]; then
	if [ -e $PGDATA/pg_hba.conf ]; then
    	mv $PGDATA/pg_hba.conf $HBA_BACKUP
    	echo "Copied existing PostgreSQL access-control policy to $HBA_BACKUP"
  	fi

   	# for docker install
  	if [ IS_DOCKER ]; then
    	cp pg_hba.conf $PGDATA
  	else
    	# for RPM install
    	echo "RPM db install"
     	cp /opt/tak/db-utils/pg_hba.conf $PGDATA
  	fi

  	chown postgres:postgres $PGDATA/pg_hba.conf
  	chmod 600 $PGDATA/pg_hba.conf
  	echo "Installed TAKServer's PostgreSQL access-control policy to $PGDATA/pg_hba.conf"
  	echo "Restarting PostgreSQL service"
  	systemctl restart ${PGSERVICE}
  	if [ $? -eq 0 ]; then
		echo "Restarting PostgreSQL service successfully"
  	else
  		echo "ERROR: Restarting PostgreSQL service fail"
  	fi
else
  	echo "ERROR: Unable to find pg_hba.conf!"
  	exit 1
fi
#
# Install our version of postgresql.conf
#
#
echo "Installing TAKServer's version of PostgreSQL ${PGVERSION} configuration"
#
# Back up postgresql.conf
#
CONF_BACKUP=$PGDATA/postgresql.conf.backup-$BACKUP_SUFFIX
if [ -e /opt/tak/db-utils/postgresql.conf ] || [ -e postgresql.conf ];  then
  	if [ -e $PGDATA/postgresql.conf ]; then
    	mv $PGDATA/postgresql.conf $CONF_BACKUP
   	 	echo "Copied existing PostgreSQL configuration to $CONF_BACKUP"
  	fi

  	 # for docker install
  	if [ IS_DOCKER ]; then
    	cp postgresql.conf $PGDATA
  	else
    	# for RPM install
    	echo "RPM db install"
      	cp /opt/tak/db-utils/postgresql.conf $PGDATA
  	fi

  	chown postgres:postgres $PGDATA/postgresql.conf
  	chmod 600 $PGDATA/postgresql.conf
  	echo "Installed TAKServer's PostgreSQL configuration to $PGDATA/postgresql.conf"
  	echo "Restarting PostgreSQL service"
  	systemctl restart ${PGSERVICE}
  	if [ $? -eq 0 ]; then
		echo "Restarting PostgreSQL service successfully"
  	fi
fi

#
# Create the user "martiuser" if it does not exist.
#
echo "Creating user \"martiuser\" ..."
su - postgres -c "psql -U postgres -c \"CREATE ROLE martiuser LOGIN ENCRYPTED PASSWORD '$md5pass' SUPERUSER INHERIT CREATEDB NOCREATEROLE;\""
if [ $? -eq 0 ]; then
	echo "Creating user \"martiuser\" succesfully"
else
	echo "ERROR: Creating user \"martiuser\" fail"
	exit 1
fi
#
# create the database
#
echo "Creating database $DB_NAME"
su - postgres -c "createdb -U postgres --owner=martiuser $DB_NAME"
if [ $? -eq 0 ]; then
	echo "Database $DB_NAME created successfully"
else
	echo "ERROR: Creating database $DB_NAME fail"
    exit 1
fi

#
# Create schema
#
echo "Create schema......"
if [ IS_DOCKER ]; then
   java -jar SchemaManager.jar upgrade
elif [ -e /opt/tak/db-utils/SchemaManager.jar ]; then
   java -jar /opt/tak/db-utils/SchemaManager.jar upgrade
else
   echo "ERROR: Unable to find SchemaManager.jar!"
   exit 1
fi

echo "Database $DB_NAME updated with SchemaManager.jar"