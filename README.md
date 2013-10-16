keepalived-drbd-mysql
=====================

vrrp_script for keepalived, to handle MySQL servers on a DRBD partition.


## Architecture

2 servers, 1 DRBD partition. One is master, the other node is the failover one. The script check DRBD and MySQL to set
master or backup nodes.

## MySQL configuration

Those parameters are really important, cause when the script set the node to backup state, MySQL will be killed -9.

	innodb_flush_log_at_trx_commit  = 1
	sync_binlog                     = 1
	innodb_support_xa				= 1
	relay_log_recovery				= 1
	sync_relay_log					= 1
	sync_relay_log_info				= 1
	sync_master_info				= 1

Also, prefer InnoDB engine instead of MyISAM.

