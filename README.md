# btrfs backup

usage: ./backup.sh btrfs_root_main btrfs_root_mirror

This script will create snapshots in btrfs_root_main/$BACKUP_DIR and incrementally copy them to btrfs_root_mirror/$BACKUP_DIR. A btrfs scrub is done when the current time is $SCRUB_DAYS past the last completed scrub, but only if any scrub was ever done on the main drive (The scrub status is available).
The cleanup algorithm will remove old snapshots but keep snapshots from:
* all $KEEP_LAST days below the current time
* one per day for $KEEP_DAY days below the current time
* one per week for $KEEP_WEEK weeks below the current time
* one per month for $KEEP_MONTH months below the current time
* one for every year

The cleanup will exit when snapshot dates from the future are discovered.

when to use:

You have two identical drives for backup storage and want to use one as failover mirror. Instead of using any kind of raid, this script can work as an on demand snapshot and mirror solution. Whenever new files are copied to the main backup drive, which can potentially replace old versions, this script can be called to make a snapshot and mirror the data to the failover backup drive. If either disk dies, the recovery strategy is to simply copy the content of the remaining disk to an equal new one. And if the replaced disk was the mirror, remove the root files and only keep the snapshot directory. If the replaced disk was the main disk, copy the top snapshot to the root directory. ("cp -aRx --remove-destination --reflink=always main_top/* main_root/") If both disks die, all data is lost obviously. Therefore this should only be one backup and not a file storage solution. For an only ever two disk backup system, this can make more sense compared to a parity based solution.
