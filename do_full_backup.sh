#!/bin/bash

# The folder which should be backuped (hint: use links to backup more than one folder at a time)
SOURCE_FOLDER="/opt/data/backup/backup_folders"

# The device to store the tar file to
LTO_DEV="/dev/st0"

# Name of the Backup-Set
BACKUP_NAME="full_backup"

# Where to store information about used tapes
TAPE_FOLDER="/opt/data/backup/tape_info"

# How long to wait between tape checks (if a tape has been inserted)
TAPE_DELAY="30s"

# How often to try to find a tape (1440 and 30s above will lead to 12h of trying)
TAPE_CHECK="1440"

# Receiver of result mail
MAIL=""

# set maximum Tape Size
MAX_TAPE_SIZE="500G"

# compress tar index file (with many files the index file can grow quite big); 
# "y" = yes, "n" = no
LOGFILE_COMPRESS="y"

#
# You shouldn't need to change some below here
#

# Todays timestamp
DATE="$(date +%Y-%m-%d)" 
TIME="$(date +%H-%M)"

# Create a temporary filename
LOGFILE_BASENAME="$(mktemp -t backup_XXX)"

# Search in Tape_Folder for the oldest file in the backup-set
TAPE_OLDFILE="$(ls -tC1 ${TAPE_FOLDER} | tail -n 1)"

MESSAGE=""

#
# First some general sanity checks
#

if [ ! -r $SOURCE_FOLDER ]; then
   MESSAGE="ERROR: Source folder does not exist or is not readable."
fi

if [ ! -w $LTO_DEV ]; then
   MESSAGE="ERROR: Output file/device does not exist or is not writeable."
fi

if [ ! -w $TAPE_FOLDER ]; then
   MESSAGE="ERROR: Tape info-folder does not exist or is not writeable."
fi

if [ ! -z "$MESSAGE" ]; then
   echo $MESSAGE; exit 1
fi

#
# Loop to wait for valid tape (see TAPE_CHECK and TYPE_DELAY parameters); give up after specified tries
# Hint: Format of serials is similar to C140604093

COUNTER=0

TAPE_SERIAL="$(sg_rmsn -r /dev/st0 2> /dev/null)" 
EXIT_CODE=$?

while [ $COUNTER -lt $TAPE_CHECK -a $EXIT_CODE -ne 0 ]; do
   # above check was negativ: send one mail, wait and recheck

   echo $TAPE_SERIAL
   if [ $EXIT_CODE -ne 0 -a $COUNTER -eq 0 ]; then
      mail -s "Backup - ${BACKUP_NAME} - no tape found" $MAIL <<EOM
      Hi Admin,

      it seems there is currently no tape insert into the tape drive.
      Please insert a tape into the drive to store the backup. It should be
      a new one or the oldest of the backup-set.

      Currently the oldest tape file seems to be:
      ${TAPE_OLDFILE%.log}

      Best regards,
        backup-script
EOM
   fi
   sleep $TAPE_DELAY
   TAPE_SERIAL="$(sg_rmsn -r /dev/st0 2> /dev/null)" 
   EXIT_CODE=$?

   let COUNTER=COUNTER+1
done

echo Tape suche abgeschlossen

# Check if we had a timeout. If so we send a mail an exit
if [ $COUNTER -eq $TAPE_CHECK ]; then
   # Timeout!

   mail -s "Backup - ${BACKUP_NAME} - tape-timeout" $MAIL <<EOM
      Hi Admin,

      even after waiting for the defined timout values: ${TAPE_CHECK} times ${TAPE_DELAY}
      no tape was inserted. I gave up...

      Best regards,
        backup-script
EOM
   echo timeout
   exit 1;
fi

TAPE_FILE="${TAPE_FOLDER}/${TAPE_SERIAL}.log"

# So we should have a tape serial now, will check existing tape infos now

# First check if it is a new tape; this will be ok to use
# Else check if it is the oldest tape we used previously; this will be ok as well
# Else we will abort and send a mail...

if [ "$(ls -A ${TAPE_FILE} 2> /dev/null)" ]; then
# We found an existing file. Now we check if it is the oldest file in our log-folder.

   if [ $TAPE_OLDFILE != $TAPE_SERIAL.log ]; then

      mail -s "Backup - ${BACKUP_NAME} - invalid tape" $MAIL <<EOM
         Hi Admin,

         the inserted tape is not a valid one because it was used before and is not the oldest
         tape in the current backup-set.

         inserted serial   : ${TAPE_SERIAL}
         oldest used serial: ${TAPE_OLDFILE%.log}

         Please remove the old serial logfile or use another or new tape.

         Best regards,
           backup-script
EOM
      exit 1
   fi
fi

touch $TAPE_FILE

#
# Now we have everything we need. So finnally do the backup.
#

# rewind this tape (just to be sure)
MESSAGE="$(mt -f /dev/nst0 rewind)"

# Start the backup
MESSAGE="$(tar -c -v --index-file=${LOGFILE_BASENAME}.index --totals -f - ${SOURCE_FOLDER} 2> ${LOGFILE_BASENAME}.err.txt | mbuffer -q -L -s 256k -m 1G -P 95 -o ${LTO_DEV})"

ERROR_CODE=$?

LOGFILE_INDEX="${LOGFILE_BASENAME}.index"
if [ $LOGFILE_COMPRESS = "y" ]; then
   bzip2 ${LOGFILE_INDEX}
   LOGFILE_INDEX="${LOGFILE_BASENAME}.index.bz2"
fi

echo $LOGFILE_INDEX

if [ $ERROR_CODE -ne 0 ]; then
   mail -s "Backup -${BACKUP_NAME}- exited with error(s)" -a ${LOGFILE_INDEX} -a ${LOGFILE_BASENAME}.err.txt $MAIL <<EOM
   Hi Admin,
   the backup for $SOURCE_FOLDER exited with error code $ERROR_CODE. Please check on addtional actions. Detailed output or the script below:

   $MESSAGE

   Please also check attached index and .err.txt file for further information.

   Best regards,
     your backup-script
EOM

else
   mail -s "Backup -${BACKUP_NAME}- was successful" -a ${LOGFILE_INDEX} -a ${LOGFILE_BASENAME}.err.txt $MAIL <<EOM
   Hi Admin,
   the backup for $SOURCE_FOLDER went fine. Please see the .index file for a list of stored files and the .err.txt file for error output of the tar command (there shouldn\'t be anything).

   Please make sure to savely store the tape.

   Best regards, 
     your backup-script

   ---------
   $MESSAGE
EOM
fi

# Cleanup of temporary files
rm ${LOGFILE_INDEX}
rm ${LOGFILE_BASENAME}
rm ${LOGFILE_BASENAME}.err.txt

