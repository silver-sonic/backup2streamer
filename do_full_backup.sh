#!/bin/bash

# ToDos
#
# 

SOURCE_FOLDER="/opt/data/backup/backup_folders"
LTO_DEV="/dev/st0"
BACKUP_NAME="full_backup"
TAPE_FOLDER="/opt/data/backup/tape_info"
TAPE_CHECK="1440"
TAPE_DELAY="30s"
MAIL="backup_phex@stefan.heinrichsen.net"
MAX_TAPE_SIZE="500G"

DATE="$(date +%Y-%m-%d)" 
TIME="$(date +%H-%M)"
LOGFILE="$(mktemp -t tar_output_XXX.txt)"
MESSAGE=""
TAPE_OLDFILE="$(ls -tC1 ${TAPE_FOLDER} | tail -n 1)"


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


# loop to wait for valid tape (check for 24h (288 time with 5 minutes delay), then give up
# Format der Serieal ist: C140604093

COUNTER=0

TAPE_SERIAL="$(sg_rmsn -r /dev/st0 2> /dev/null)" 
EXIT_CODE=$?

while [ $COUNTER -lt $TAPE_CHECK -a $EXIT_CODE -ne 0 ]; do
   # above check was negativ: send mail, wait and recheck

   echo $TAPE_SERIAL
   if [ $EXIT_CODE -ne 0 -a $COUNTER -eq 0 ]; then
      mail -s "Backup - ${BACKUP_NAME} - no tape found" $MAIL <<EOM
      Hi Admin,

      it seems there is currently no tape insert into the tape drive.
      Please insert a tape into the drive to store the backup. It should be
      a new one or the oldest of the backup-set.

      Currently the oldest tape file seems to be:
      $TAPE_OLDFILE

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

      even after waiting for the defined timout values: ${TAPE_CHECK} time ${TAPE_DELAY}
      no tape was inserted. I gave up...

      Best regards,
        backup-script
EOM
   echo timeout
   exit 1;
fi

# For development only
# TAPE_SERIAL="C140604093"

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

         Please remove the old serial logfile or use another tape.

         Best regards,
           backup-script
EOM
      exit 1
   fi
fi

touch $TAPE_FILE

# rewind this tape (just to be sure)
MESSAGE="$(mt -f /dev/nst0 rewind)"

# do the backup
# Something wrong here... MESSAGE="$(tar -c -f - ${SOURCE_FOLDER} &> ${LOGFILE} | mbuffer -q -L -s 256k -m 1G -P 95 -o ${LTO_DEV})"
MESSAGE="$(tar -c -f - ${SOURCE_FOLDER} | mbuffer -q -L -s 256k -m 1G -P 95 -o ${LTO_DEV})"
#echo       "tar -c -f - ${SOURCE_FOLDER} | mbuffer -L -s 256k -m 1G -P 95 -o ${LTO_DEV}"

ERROR_CODE=$?

if [ $ERROR_CODE -ne 0 ]; then
   mail -s "Backup -${BACKUP_NAME}- exited with error(s)" -a $LOGFILE $MAIL <<EOM
   Hi Admin,
   the backup for $SOURCE_FOLDER exited with error code $ERROR_CODE. Please check on addtional actions. Detailed output:

   $MESSAGE

   Best regards,
     your backup-script
EOM

else
   mail -s "Backup -${BACKUP_NAME}- was successful" -a $LOGFILE $MAIL <<EOM
   Hi Admin,
   the backup for $SOURCE_FOLDER went fine. Details at the of the mail.
   Please make sure to savely store the tape.

   Best regards, 
     your backup-script

   ---------
   $MESSAGE
EOM
fi
