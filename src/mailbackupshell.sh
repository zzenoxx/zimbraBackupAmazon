#!/bin/bash
 
# Backup Script For zimbra
# Requires s3cmd configured to run
# This script is intended to run local or from the crontab as root
# Free to use and free of any warranty!  Daniel W. Martin, 5 Dec 2008, Modified Thomas Valgaeren nov 2016
# This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
 
# variables 

bucket=$1
if [ -z "$2" ]
then
keepfor=$2
echo backup files older then $2 days will be deleted
else 
keepfor=7
fi

 
 
# Outputs the time the backup started, for log/tracking purposes
echo Time backup started = $(date +%T)
before="$(date +%s)"

# Live sync before stopping Zimbra to minimize sync time with the services down
# Comment out the following rsync line if you want to try single cold-sync only, add v parameter for more output.
echo pre rsync start
rsync -aHK --delete /opt/zimbra/ /backup/zimbra
echo pre rsync done

# which is the same as: /opt/zimbra /backup 
# Including --delete option gets rid of files in the dest folder that don't exist at the src 
# this prevents logfile/extraneous bloat from building up overtime.

# Now we need to shut down Zimbra to rsync any files that were/are locked
# whilst backing up when the server was up and running.
before2="$(date +%s)"

# Stop Zimbra Services
su - zimbra -c"/opt/zimbra/bin/zmcontrol stop"
sleep 15

# Kill any orphaned Zimbra processes
ORPHANED=`ps -u zimbra -o "pid="` && kill -9 $ORPHANED

# Only enable the following command if you need all Zimbra user owned
# processes to be killed before syncing
# ps auxww | awk '{print $1" "$2}' | grep zimbra | kill -9 `awk '{print $2}'`
 
# Sync to backup directory
echo rsync start
rsync -aHK --delete /opt/zimbra/ /backup/zimbra
echo rsync done

# Restart Zimbra Services
su - zimbra -c "/opt/zimbra/bin/zmcontrol start"

# Calculates and outputs amount of time the server was down for
after="$(date +%s)"
elapsed="$(expr $after - $before2)"
hours=$(($elapsed / 3600))
elapsed=$(($elapsed - $hours * 3600))
minutes=$(($elapsed / 60))
seconds=$(($elapsed - $minutes * 60))
echo Server was down for: "$hours hours $minutes minutes $seconds seconds"


timestamp=`(date +%F_%H.%M.%S)`


# Create a txt file in the backup directory that'll contains the current Zimbra
# server version. Handy for knowing what version of Zimbra a backup can be restored to.
su - zimbra -c "zmcontrol -v > /backup/zimbra/conf/zimbra_version_${timestamp}.txt"
# or examine your /opt/zimbra/.install_history

# Display Zimbra services status
echo Displaying Zimbra services status...
su - zimbra -c "/opt/zimbra/bin/zmcontrol status"
 
# Create archive of backed-up directory for offsite transfer
# cd /backup/zimbra
# umask 0177
# add v parameter to tar command for more output if necesery
echo start tar
if [ ! -d "/tmp/zimbrabackup" ]; then
  mkdir /tmp/zimbrabackup
fi
tar -zcf /tmp/zimbrabackup/backup_${timestamp}_zimbra.tgz -C /backup .
echo done tar
 
# Transfer file to backup server
s3cmd put /tmp/zimbrabackup/backup_${timestamp}_zimbra.tgz s3://$bucket/backup_${timestamp}_zimbra.tgz

#checking if more than 2 backups are present local and if true, deleting older than keepfor variable days
cd /tmp/zimbrabackup/
countbackup=$((`(ls -l | wc -l )` - 1))
echo number of backups $countbackup
if [ "$countbackup" -ge "2" ]
then
delprep="+$keepfor"
echo deleting following file:
find /tmp/zimbrabackup/* -mtime $delprep
find /tmp/zimbrabackup/* -mtime $delprep -exec rm {} \;
else
echo not more than 2 backups pressent
fi

# rm /tmp/zimbrabackup/backup_${timestamp}_zimbra.tgz

# checking if more than 2 backups are present on S3 and if true deleting older than keepfor variable days
s3prep="$keepfor days"

countbackup=$((`(s3cmd ls s3://$bucket | wc -l )`))
if [ "$countbackup" -ge "2" ]
then
s3cmd ls s3://$bucket | while read -r line;
  do
    createDate=`echo $line|awk {'print $1" "$2'}`
    createDate=`date -d"$createDate" +%s`
    olderThan=`date -d"-$s3prep" +%s`
    if [[ $createDate -lt $olderThan ]]
      then 
        fileName=`echo $line|awk {'print $4'}`
        echo $fileName
        if [[ $fileName != "" ]]
          then
            s3cmd del "$fileName"
        fi
    fi
  done;
else
echo not more than 2 backups pressent on amazon
fi


# Outputs the time the backup finished
echo Time backup finished = $(date +%T)

# Calculates and outputs total time taken
after="$(date +%s)"
elapsed="$(expr $after - $before)"
hours=$(($elapsed / 3600))
elapsed=$(($elapsed - $hours * 3600))
minutes=$(($elapsed / 60))
seconds=$(($elapsed - $minutes * 60))
echo Time taken: "$hours hours $minutes minutes $seconds seconds"