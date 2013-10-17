#!/bin/dash
# Copyright (c) 2013 Gregory Duchatelet
# Script to handle MySQL from keepalived.
#
# (Dash is really much faster than Bash)
#
# Usage: checkdrbd.sh action
#
# Where action is :
#
# check	: check that the DRBD resource is Primary, Connected and UpToDate
#	and that MySQL is running
#
# backup: set to backup state. Just checking than DRBD is connected and syncing...
# fault	: set to fault state. Killing MySQL, unmount partition, set the DRBD resource to Secondary
# master: set to master state. Set the DRBD resource to Primary, mount partition, start MySQL
# 	then invalidate remote DRBD resource
#
# Note: you can use $MAINTENANCE (/etc/keepalived/maintenance) to disable MySQL checks
# in case of short MySQL maintenance
#

# Usage func :
[ "$1" = "--help" ] && { sed -n -e '/^# Usage:/,/^$/ s/^# \?//p' < $0; exit; }


#
# CONFIG
#
DRBDADM="/sbin/drbdadm"
MYSQL="/usr/local/mysql/bin/mysql"
# must return "1" string:
CHECKSQL="SELECT 1"
CHECKSQLSTR="1"
# MySQL server settings
MYSQLSOCK="/var/run/mysqld/mysqld.sock"
MYSQLPID="/var/run/mysqld/mysqld.pid"
MYSQLINIT="/etc/init.d/mysql.server"
# DRBD resource
DRBDRESOURCE="mysql"
# local mount point
MOUNTPOINT="/var/local"
# warmup delay
MAXWAIT=240
# MySQL fatal errors, which will provoke a node switch
# (should be completed with next bad events...)
MYSQL_FATAL_ERRORS='(2000|2001|2002|2003|2005|2008)'
# how to handle potential split-brain
# 0: manual
# 1: invalidate local data
# 2: invalidate remote data
SPLIT_BRAIN_METHOD=0
# maintenance flag: used to do maintenance on MySQL without switch between nodes
MAINTENANCE="/etc/keepalived/maintenance"

# Finally, to overwrite those defaults :
CONFIG="/etc/keepalived/check_config.sh"


#
# CONFIG LOGGER
#
# tail -f /var/log/syslog | grep Keep
LOG="logger -t KeepDRBD[$$] -p syslog" # do not use -i
LOGDEBUG="$LOG.debug"
LOGINFO="$LOG.info"
LOGWARN="$LOG.warn"
LOGERR="$LOG.err"
LOGFIFO=$( mktemp -u /var/tmp/$( basename $0 )_fifo.XXXXXX )
LOGPID=0


#
# local vars
#
LOCKACTIONFILE="/tmp/keep_drbd_"
status=
role=
cstate=
dstate=
warmstate="${LOCKACTIONFILE}_warm_state"

init_status() {
	# start with NOK status
	if [ -z "$status" ]
	then
		status=1
	fi
	role=$( $DRBDADM role $DRBDRESOURCE )
	cstate=$( $DRBDADM cstate $DRBDRESOURCE )
	dstate=$( $DRBDADM dstate $DRBDRESOURCE )
}

set_status() {
	status=$1
	if [ -n "$role" ]
	then
		$LOGDEBUG "CheckDRBD: $role $cstate $dstate => $status"
	fi
	return $status
}

check() {
	# Do nothing during warm state
	if [ -e $warmstate ]
	then
		warmat=$( stat -t $warmstate | awk '{print $13}' )
		now=$( date +%s )
		warmat=$(( $now - $warmat ))

		# Wait 1min before asking mysql for its state
		if [ $warmat -le 10 ]
		then
			$LOGWARN "Still in warm state ($warmat)"
			set_status 0
			return $?
		fi
	fi
	# CHECK DRBD
	init_status
	status=1

	# at least UpToDate
	if echo $dstate | grep -q ^UpToDate/
	then
		# Primary + UpToDate
		status=0
		if [ "$cstate" = "StandAlone" ]
		then
			$LOGWARN "$role but not connected"
		fi
	else
		$LOGDEBUG "DSTATE: $dstate"
		# status=1 ?
		status=0
	fi

	# Stop checking if already in fault ...
	if [ $status -gt 0 ]
	then
		set_status $status
		return $?
	fi


	# if in warm state, check mysql to stop warm state if success
	# (only if Primary)
	if [ $status -eq 0 ] && echo "$role" | grep -q ^Primary
	then
		if check_mysql
		then
			if [ -e $warmstate ]
			then
				rm -f $warmstate
				$LOGWARN "Warm state terminated."
				reconnect_drbd
			# else: MySQL is OK
			fi
		else
			# ckeck mysql failed and not in warmstate
			if [ ! -e $warmstate ]
			then
				$LOGWARN "(debug: MySQL is unavailable !)"
				# Testing: do not disable this server if MySQL is down
				#status=1
			fi
		fi
	fi
	
	sync
	set_status $status
	return $?
}


set_fault() {
	# Lock : 1 set_fault at a time
	LOCKACTIONFILE="${LOCKACTIONFILE}fault_lock"
	lockd=$( mkdir $LOCKACTIONFILE 2>&1 )
	if [ "$?" -gt 0 ]
	then
		$LOGDEBUG "Already setting to fault state...$$ $lockd"
		return 1
	fi
	trap "rm -rf \"$LOCKACTIONFILE\"" 0

	set_backup
	return $?
}


kill_mysql() {
	$LOGDEBUG "Kill mysql"
	# Remove mysql stats crontab
	if [ -e "$MYSQLPID" ] # File exist
	then
		if /bin/kill -0 $( cat "$MYSQLPID" ) # process exist
		then
			${MYSQL}admin flush-logs
			mysqlpid=$( cat "$MYSQLPID" )
			$LOGWARN "KILLING -9 mysqld[$mysqlpid]"
			# mysqld_safe will not restart mysqld if pidfile is removed
			rm -f "$MYSQLPID"
			/bin/kill -9 $mysqlpid
		fi
		sync
	fi
}


set_backup() {
	kill_mysql
	# We must be sure to be in replication and secondary state
	ensure_drbd_secondary
}

set_drbd_secondary() {
	if awk '{print $2}' /etc/mtab | grep -q "^$MOUNTPOINT"
	then
		$LOGWARN "Unmounting $MOUNTPOINT ..."
		sleep 1
		fuser -k -9 $MOUNTPOINT/
		sleep 1

#        -f     Force unmount (in case of an unreachable NFS system).  (Requires kernel 2.1.116 or later.)
#        -l     Lazy unmount. Detach the filesystem from the filesystem hierarchy now, and cleanup all references to the filesystem as soon as it is  not  busy  anymore.   (Requires
#              kernel 2.4.11 or later.)
		umount $MOUNTPOINT
	fi
	
	$LOGDEBUG "Set DRBD to secondary"
	$DRBDADM disconnect $DRBDRESOURCE
	sleep 1
	# A ce moment, les 2 nodes sont Secondary. On ne peut pas demander a l'autre node de passer
	# Primary, parce qu'on est théoriquement pas connecté.
	if ! $DRBDADM secondary $DRBDRESOURCE 
	then
		$LOGWARN "Unable to set $DRBDRESOURCE to secondary state"
		echo LSOF:
		lsof /var/local | while read line
		do
			$LOGWARN "lsof: $line"
		done
		
		return 1
	fi
	$LOGDEBUG "Sync DRBD"
	if [ $SPLIT_BRAIN_METHOD -eq 1 ]
	then
		$DRBDADM invalidate $DRBDRESOURCE
	fi
	$DRBDADM connect $DRBDRESOURCE
	sleep 1
	init_status
	$LOGDEBUG "ROLE=$role CSTATE=$cstate DSTATE=$dstate"
}


ensure_drbd_secondary() {
	if ! is_drbd_secondary
	then
		set_drbd_secondary
		return $?
	fi
}

is_drbd_secondary() {
	init_status
	# If already Secondary and Connected, do nothing ...
	if echo $role | grep -q ^Secondary
	then
		if [ "$cstate" != 'StandAlone' ]
		then
			$LOGDEBUG "Already in BACKUP state..."
			return 0
		fi
	fi
	return 1
}

reconnect_drbd() {
	init_status
	if [ "$cstate" = "StandAlone" ]
	then
		$DRBDADM connect $DRBDRESOURCE
	fi
}



# WARNING set_master is called at keepalived start
# So if already in "good" state we must do nothing :)
set_master() {
	init_status
	if ! echo "$role" | grep -q ^Primary
	then
		$LOGDEBUG "Set DRBD to Primary"
		$DRBDADM disconnect $DRBDRESOURCE
		$DRBDADM primary $DRBDRESOURCE
		init_status
		if ! echo "$role" | grep -q ^Primary
		then
			$LOGWARN "Need to force PRIMARY ..."
			$DRBDADM -- --overwrite-data-of-peer primary $DRBDRESOURCE
			init_status
			if ! echo "$role" | grep -q ^Primary
			then
				$LOGWARN "Unable to set PRIMARY"
				return 1
			else
				$LOGWARN "Forced to PRIMARY : OK"
			fi
		fi
	fi
	if ! awk '{print $2}' /etc/mtab | grep "^$MOUNTPOINT" >/dev/null
	then
		device=$( $DRBDADM sh-dev $DRBDRESOURCE )
		$LOGDEBUG "Filesystem check ..."

		#FSTYPE="ext4"
		#MOUNTOPTS=sync,noauto,noatime,noexec
		FSTYPE=$( grep -F $MOUNTPOINT /etc/fstab | grep -F $( $DRBDADM sh-dev $DRBDRESOURCE ) | awk '{print $3}' )

		# Add "-f" to force ?
		if [ "$FSTYPE" != "xfs" ]
		then
			fsck.$FSTYPE -pD $device >&2
		fi

		$LOGDEBUG "Mount ..."
		#if ! mount -t $FSTYPE $device $MOUNTPOINT
		if ! mount $MOUNTPOINT
		then
			$LOGERR "Unable to mount $MOUNTPOINT"
			return 1
		fi
	fi

	# Starting MySQL
	if [ $( pidof mysqld | wc -w ) -gt 0 ]
	then
		$LOGWARN "MySQL already started ? What did I have to do ?"
	else
		$LOGDEBUG "Starting MySQL ..."
		touch $warmstate
		$MYSQLINIT start
		# Install mysql stats crontab
		
		$LOGDEBUG "Waiting for MySQL ..."
		for i in $( seq 1 $MAXWAIT )
		do
			sleep 1
			if check_mysql
			then
				break
			fi
		done
	fi

	if check_mysql
	then
		$LOGDEBUG "Checking MySQL MyISAM tables ..."
		mysql_check mysql
		$MYSQL -ABN -e "select TABLE_SCHEMA, TABLE_NAME from tables WHERE ENGINE='MyISAM' AND TABLE_SCHEMA NOT LIKE '%_schema' AND TABLE_SCHEMA NOT LIKE 'mysql'" information_schema | while read db table
		do
			mysql_check $db $table
		done

		if ! check_replic
		then
			$LOGDEBUG "Starting MySQL Replication..."
			${MYSQL}admin start-slave
			sleep 2
		fi
		

		# Check that replication has started
		
		if ! check_replic
		then
			$LOGWARN "MySQL replication is broken, you need to repair it with your hands"
		fi
	else
		$LOGWARN "MySQL is broken and need a manual repair :("
	fi

	# We connect to DRBD _after_ MySQL has started, to limit IOPS
	if [ $SPLIT_BRAIN_METHOD -eq 2 ]
	then
		$DRBDADM invalidate-remote $DRBDRESOURCE
	fi
	$LOGDEBUG "SyncTarget..."
	reconnect_drbd
}


check_replic() {
	m=$( $MYSQL --connect-timeout=2 -e "show slave status" --vertical mysql 2>&1 | grep -E 'Slave_.+Running' | grep Yes | wc -l )
	$LOGDEBUG "CheckReplic: $m"
	if [ $m -lt 2 ]
	then
		return 1
	fi
	return 0
}

# Do a mysqlcheck
mysql_check() {
	db=$1
	table=$2
	param="$db $table"
	if [ -z "$table" ]
	then
		param="-B $db"
	fi
	cmd="${MYSQL}check --medium-check -F --auto-repair $param"
	$LOGDEBUG "$cmd"
	$cmd 2>&1 | while read l
	do
		$LOGDEBUG "$l"
	done
}

# Check that MySQL is responding
# Return:
# 0 if everything is OK (or in maintenance mode)
# 1 if SQL did not return the expected string
# 2 if MySQL did not reply
check_mysql() {
	if [ -e $MAINTENANCE ]
	then
		return 0
	fi

	m=$( $MYSQL --connect-timeout=2 -ABN -e "$CHECKSQL" mysql 2>&1 )
	mcode=$?

	# Check MySQL error codes. Not all errors are fatal, like "1023 too many connections"
	if [ $mcode -gt 0 ]
	then
		merrno=$( echo "$m" | grep -Eo 'ERROR ([0-9]+) ' | cut -d" " -f2 )
		$LOGWARN "[MySQL is unavailable] $m"
		if echo "$merrno" | grep -qE "$MYSQL_FATAL_ERRORS"
		then
			return 2
		else
			return 0 # not fatal ...
		fi
	
	# Check MySQL reply to SQL query
	elif [ "$m" = "$CHECKSQLSTR" ]
	then
		return 0
	else
		$LOGWARN "MySQL did not return expected value: '$CHECKSQLSTR' != '$m'"
		return 1
	fi
	return 1
}

cleanup() {
	kill $LOGPID
	#$LOGDEBUG "Cleanup $LOGPID and $LOGFIFO"
	# Workarround to log something if there is something ...
	# logger will wait for stdin if argument is empty
	# and "rm -f $file" will output nothing
	yvain=$( mktemp -u /tmp/$( basename $0 )_yvain.XXXXXX )
	rm -f $LOGFIFO 2>$yvain || $LOGDEBUG "Remove $LOGFIFO failed: $( cat $yvain )"
	test -e $yvain && rm -f $yvain
	#wait
}




# Redirect stderr to log
trap "cleanup" INT QUIT TERM TSTP EXIT
mkfifo $LOGFIFO
$LOGWARN < $LOGFIFO &
LOGPID=$!
exec 2>$LOGFIFO


if [ -e $CONFIG ]
then
	. $CONFIG
fi

case "$1" in
	check)
		check
		exit $?
	;;
	backup)
		$LOGWARN "=> set to backup state <="
		set_backup
		exit $?
	;;
	fault)
		$LOGWARN "=> set to fault state <="
		set_fault
		exit $?
	;;
	master)
		$LOGWARN "=> set to master state <="
		set_master
		exit $?
	;;
esac

