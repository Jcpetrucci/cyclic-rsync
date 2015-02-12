#!/bin/bash
# Create: 2014-03-05 John C. Petrucci
# http://johncpetrucci.com
# Purpose: Cyclic backups with rsync.
# Usage: Intended to be run from [ana]cron but also works ad-hoc.  No arguments.
# *-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-
# WARNING! READ THIS!!  
# If the rsync stage of the script is interrupted before it completes, the next time the script runs it will have to re-transfer EVERYTHING that didn't get copied/hard-linked -- even if that data already exists in one of the cyclic directories (higher than .0).  
# This is because the link-dest containing the data that was either: 
#		(A)not copied--if new OR 
#		(B)not linked--if existing 
# ....before the rsync aborted would be dereferenced and at this point rsync has no idea that it exists on the target.
# If the rsync had already scanned a file that existed in "instance.0" and created the hard-link in "instance", then the data does not need to be re-copied.  
# This is why it is CRITICAL to not interrupt rsync - especially if the link is slow.  
#
# In the worst case when an rsync is interrupted unavoidably, we should be able to minimize losses by modifying this script: commenting out the fileRotation function call and running ad-hoc once.

export log_tag='Desktop Backup' # What tag to use for syslog messages.
export destination_path="/bigvolume/backups/johnshome/" # Path on destination device where backups should be kept.  Must have trailing slash.
export source_path="/home/john/" # Path on this device that we want to backup.  Must have trailing slash.
export ssh_host='nas.local' # Hostname or IP where backups will be kept.
export ssh_key='/home/john/.ssh/id_rsa' # Path on this device to an SSH private key which is authorized to access the remote host.
export ssh_user='nasadmin' # User account to use when logging into remote host.
export most_kept='9' # How many versions to keep.
inhibit_shutdown=''
which systemctl >/dev/null 2>&1 && inhibit_shutdown='systemd-inhibit --why Data_backup_in_progress'
# Other variables: rsync exclusions

EchoQuit() {
        [[ $2 != "0" ]] && PRIORITY="emerg"
        [[ $2 != "0" ]] && which zenity && zenity --error --title "$log_tag" --text "$1" --display=:0.0 &
        logger -t "$log_tag" -s -p ${PRIORITY:-info} <<<"$1"
        exit ${2:-0}
}

# Pre-run checks begin
[[ -d "$source_path" ]] || EchoQuit "Source is not accessible." 1
pidof shutdown && EchoQuit "There is a shutdown in progress.  Refusing to start the backup." 1

# Check for failure lock-file (which is produced as a result of failed rsync.) This is needed so that this script doesnt re-run on the schedule and cycle out all legitimate backups while the rsync fails to produce fresh ones.
[[ -e "${source_path}.$(basename $0).failed" ]] && EchoQuit "The previous rsync failed.  Refusing to proceed so we do not delete good copies.  Investigation IS REQUIRED." 1
# Pre-run checks end

function fileRotation {
	ssh -i "$ssh_key" ${ssh_user}@${ssh_host} <<-EOF
	declare -i most_kept=${most_kept}
	cd $destination_path || exit 100

	rm -rf "${destination_path}instance.\${most_kept}"

	for ((i=most_kept-1; i>=0; i--));
	do
		# It is desirable to use mv -v for verbose output but in some cases -v is not supported.
		mv "${destination_path}instance.\${i}" "${destination_path}instance.\${most_kept}"
		(( --most_kept ))
	done

	mv "${destination_path}instance" "${destination_path}instance.0" || exit 101
	EOF
}
fileRotation

# Informational message if unable to move instance to instance.0.  One reason for this is simply that the rsync never ran and produced the directory.  Other reasons could be permissions problems.
case "$?" in
	(100)	EchoQuit "Destination directory is not accessible on SSH target." 1;;
	(101)	printf "%s\n" "Moving instance to instance.0 failed.  This could mean rsync has never run." >&2;;
esac

$inhibit_shutdown rsync -va --chmod=+rX --delete --no-group --no-owner --exclude={/lost+found,/.Trash*,/SteamLibrary,/Data/recup_dir*} --link-dest="${destination_path}instance.0/" --log-format="%f -- Bytes on wire: %b -- Modified: %M -- Changes: %i" -e "ssh -i \"$ssh_key\"" "$source_path" "${ssh_user}@${ssh_host}:${destination_path}instance/"
	# Explanation of all rsync options:
	# -v					Verbose.  This is so that we get a summary at the end showing the total bytes transferred.
	# -a					Archive.  This sets some basics such as recursion.
	# --chmod=+rX			Enables world readability.  This is specific to my needs, as a secondary backup job then copies the resulting data off.  You may want to remove this for security!
	# --no-{group|owner}	The remote system does not have same users and groups existing, nor do I care about ownership.
	# --exclude				These are files/folders which do not make sense to backup.
	# --link-dest			Use the specified directory; if a file we would copy already exists here just create a hard link instead of copying the file over the network.
	# --log-format			Configures how output of this job will be formatted.  No --log-file is specified so this goes to stdout.  In my case this is redirected by anacron to logger, then to journalctl.
	# Can throttle rsync with:
	# --bwlimit=KBPS

# Check exit status of the rsync.  If non-zero we need to touch a lockfile and prevent future cyclic deletions from obliterating our good copies.
[[ "$?" -ne "0" ]] && { touch "${source_path}.$(basename $0).failed"; EchoQuit "rsync exited with non-zero code.  Please investigate further in logs." 1; } || EchoQuit "rsync completed successfully." 1
