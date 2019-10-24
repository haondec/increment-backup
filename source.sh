#!/bin/bash
# Backup increment

#-------------------------------------------------------------------------------------------------
###   Pernament script var
#-------------------------------------------------------------------------------------------------

# Root script directory
ROOT_SCRIPT_DIR="/etc/backup-tool/"
CONFIG_FILE="${ROOT_SCRIPT_DIR}/settings.conf"

TIME_FORMAT_DAY="%Y-%m-%d"
TIME_FORMAT_SECOND="%Y-%m-%d %H-%M-%S"

EXCLUDE_RSYNC=""					# call by func_get_exclude()
EXCLUDE_BORG=""

# Set settings
if [[ ! -f $CONFIG_FILE ]]; then
	mkdir -p "$ROOT_SCRIPT_DIR/logs"
	echo "[Error] Missing \"${ROOT_SCRIPT_DIR}/settings.conf\" file." | tee -a "$ROOT_SCRIPT_DIR/logs/source.log"
	exit 1
fi

source $CONFIG_FILE

#-------------------------------------------------------------------------------------------------

RSYNC_OPTS="--force --ignore-errors --delete --delete-excluded -aqr"
SSH_OPTS="-i $GLOBAL_SFTP_PRIVATE_KEY -p $GLOBAL_SFTP_PORT -x -q -m hmac-sha2-512,hmac-sha2-256,hmac-md5,hmac-sha1 -o Compression=no -o ServerAliveInterval=15 -o Batchmode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no"

# Check slash
[[ "$(echo -en "$ROOT_SCRIPT_DIR" | tail -c 1)" != "/" ]] && { ROOT_SCRIPT_DIR="${ROOT_SCRIPT_DIR}/"; }

#-------------------------------------------------------------------------------------------------
###   Function zone
#-------------------------------------------------------------------------------------------------
func_write_log() {
	# File log
	local var_LOG_FILE="$1"
	local var_MESSAGE="$2"
	local var_TIME=$(date +"${TIME_FORMAT_SECOND}")
	
	# Create log dir
	[[ "$(echo -en "$GLOBAL_LOG_DIR" | tail -c 1)" != "/" ]] && { GLOBAL_LOG_DIR="${GLOBAL_LOG_DIR}/"; }
	local var_DEFAULT_LOG_DIR="${GLOBAL_LOG_DIR}logs"
	mkdir -p "$var_DEFAULT_LOG_DIR"
	
	if [[ "$GLOBAL_DEBUG_MODE" == "1" || "$GLOBAL_DEBUG_MODE" == "true" ]]; then
		if [[ $var_LOG_FILE == "-d" ]]; then
			echo -e "${var_TIME} ${var_MESSAGE}" | tee -a "${var_DEFAULT_LOG_DIR}/main.log"
		else
			echo -e "${var_TIME} ${var_MESSAGE}" | tee -a "$var_LOG_FILE"
		fi
	else
		if [[ $var_LOG_FILE == "-d" ]]; then
			echo -e "${var_TIME} ${var_MESSAGE}" >> "${var_DEFAULT_LOG_DIR}/main.log"
		else
			echo -e "${var_TIME} ${var_MESSAGE}" >> "$var_LOG_FILE"
		fi
	fi
}

func_get_exclude_rsync() {
	# Clear it
	EXCLUDE_RSYNC=""
	for dir in "${GLOBAL_EXCLUDE_DIR[@]}"
	do
		[[ "$dir" == "" ]] && { continue; }
		EXCLUDE_RSYNC="$EXCLUDE_RSYNC""--exclude '$dir' "
	done
}

func_get_exclude_borg() {
	# Clear it
	EXCLUDE_BORG=""
	# Get list from settings.conf
	#var_GLOBAL_EXCLUDE_DIR="$(echo "$GLOBAL_EXCLUDE_DIR" | tr -s ' ')"
	#[[ "$(echo -en "$var_GLOBAL_EXCLUDE_DIR" | head -c 1)" == " " ]] && { var_GLOBAL_EXCLUDE_DIR="${var_GLOBAL_EXCLUDE_DIR:1}"; }
	#[[ "$(echo -en "$var_GLOBAL_EXCLUDE_DIR" | tail -c 1)" == " " ]] && { var_GLOBAL_EXCLUDE_DIR="${var_GLOBAL_EXCLUDE_DIR:0:-1}"; }
	
	# Check slash
	[[ "$(echo -en "$GLOBAL_SOURCE_TO_DIR" | tail -c 1)" != "/" ]] && { GLOBAL_SOURCE_TO_DIR="${GLOBAL_SOURCE_TO_DIR}/"; }
	
	# Create list exclude
	for dir in "${GLOBAL_EXCLUDE_DIR[@]}"
	do
		[[ "$dir" == "" ]] && { continue; }
		EXCLUDE_BORG="$EXCLUDE_BORG""--exclude '${GLOBAL_SOURCE_FROM_DIR}${dir}' "
	done
}

func_init_borg() {
	mkdir -p "$GLOBAL_BORG_DIR"

	# If empty dir, run init
	if [[ -z "$(ls -A "$GLOBAL_BORG_DIR")" ]]; then
		var_OUTPUT="$("$GLOBAL_TOOL_BORG" init --encryption=none "$GLOBAL_BORG_DIR" 2>&1)"
		var_RETURN="$?"
		if [[ $var_RETURN -ne 0 ]]; then
			func_write_log -d "[Error] Borg backup init, return $var_RETURN, fail with error:\n${var_OUTPUT}"
			func_mail_notify "[Error] Backup source, Borg init fail." "Borg backup init, fail with error:\n${var_OUTPUT}"
			exit 2
		fi
		# Repo created
		return 0
	fi

	# If not empty dir
	if [[ ! -z "$(ls -A "$GLOBAL_BORG_DIR")" ]]; then
		# Borg list
		var_OUTPUT="$("$GLOBAL_TOOL_BORG" list "$GLOBAL_BORG_DIR" 2>&1 | grep -c "$GLOBAL_MESSAGE_LIST_FAIL")"
		# If config repo not exist
		if [[ $var_OUTPUT -lt 0 ]]; then
			func_write_log -d "[Error] Init borg $GLOBAL_BORG_DIR not empty and recognize borg config."
			func_mail_notify "[Error] Backup source, Borg init fail." "Init borg $GLOBAL_BORG_DIR not empty and recognize borg config."
			exit 2
		fi
		# Repo created
		return 0
	fi
}

func_do_borg_rotate() {
	func_write_log -d "[Info] Do borg backup rotate."
	# Checking number
	local var_FULL_BORG_CMD="$GLOBAL_TOOL_BORG list ${GLOBAL_BORG_DIR}"
	var_OUTPUT="$(set -o pipefail ; eval $var_FULL_BORG_CMD 2>&1)"
	var_RETURN="$?"
	if [[ $var_RETURN -ne 0 && $GLOBAL_FORCE_NEW_BACKUP -eq 0 ]]; then
		func_write_log -d "[Error] Borg backup list rotate, return $var_RETURN, fail with error:\n${var_OUTPUT}"
		func_mail_notify "[Error] Backup source, Borg backup list rotate fail." "Borg backup list rotate, fail with error:\n${var_OUTPUT}"
		exit 2
	fi
	
	#var_CURRENT_VERSION="$(echo "$var_OUTPUT" | grep "$GLOBAL_SOURCE_BK_PREFIX" | wc -l)"
	#var_CURRENT_VERSION="$(echo "$var_OUTPUT" | wc -l)"

	#if [[ $var_CURRENT_VERSION -gt $GLOBAL_NUMBER_KEEP ]]; then
		if [[ $GLOBAL_SOURCE_RETAINDAYS -gt 0 ]]; then
			var_FULL_BORG_CMD="$GLOBAL_TOOL_BORG prune --stats --keep-within ${GLOBAL_SOURCE_RETAINDAYS}d ${GLOBAL_BORG_DIR}"
			var_OUTPUT="$(set -o pipefail ; eval $var_FULL_BORG_CMD 2>&1)"
			var_RETURN="$?"
			if [[ $var_RETURN -ne 0 ]]; then
				func_write_log -d "[Error] Borg backup rotate retaindays, return $var_RETURN, fail with error:\n${var_OUTPUT}"
				func_mail_notify "[Error] Backup source, Borg backup rotate retaindays fail." "Borg backup rotate retaindays, fail with error:\n${var_OUTPUT}"
				exit 2
			fi
		fi
		#var_FULL_BORG_CMD="$GLOBAL_TOOL_BORG prune --stats --keep-last $GLOBAL_NUMBER_KEEP"
		#var_OUTPUT="$(set -o pipefail ; eval $var_full_borg_cmd 2>&1)"
		#if [[ $? -ne 0 ]]; then
		#	func_write_log -d "[Error] Borg backup rotate by number keep, fail with error:\n${var_OUTPUT}"
		#	exit 2
		#fi
	#fi
	func_write_log -d "[Info] Borg backup rotate success."
}

func_do_borg_backup() {
	func_write_log -d "[Info] Do borg backup \"$GLOBAL_BORG_DIR\"."
	
	# Rotate before backup
	if [[ $GLOBAL_ROTATE_ORDER -eq 1 ]]; then
		func_do_borg_rotate
	fi

	# Get time day
	local var_TIME=$(date +"${TIME_FORMAT_DAY}")
	local var_BORG_NEW_CONTENT="${GLOBAL_SOURCE_BK_PREFIX}${var_TIME}"

	# Run init
	func_init_borg
	# Check force
	local var_FULL_BORG_CMD="$GLOBAL_TOOL_BORG list ${GLOBAL_BORG_DIR}"
	var_OUTPUT="$(set -o pipefail ; eval $var_FULL_BORG_CMD 2>&1)"
	var_RETURN="$?"
	if [[ $var_RETURN -ne 0 && $GLOBAL_FORCE_NEW_BACKUP -eq 0 ]]; then
		func_write_log -d "[Error] Borg backup list check force, return $var_RETURN, fail with error:\n${var_OUTPUT}"
		func_mail_notify "[Error] Backup source, Borg backup list check force fail." "Borg backup list check force, fail with error:\n${var_OUTPUT}"
		exit 2
	fi
	local var_VERSION_EXIST="$(echo "$var_OUTPUT" | grep -c "$var_BORG_NEW_CONTENT")"

	if [[ $var_VERSION_EXIST -ne 0 && $GLOBAL_FORCE_NEW_BACKUP -eq 0 ]]; then
		func_write_log -d "[Error] Borg backup, fail with error: \"${var_VERSION_EXIST}\" exist."
		func_mail_notify "[Error] Backup source, Borg backup fail." "Borg backup, fail with error: \"${var_VERSION_EXIST}\" exist."
		exit 2
	fi
	# Delete exist by force
	if [[ $var_VERSION_EXIST -ne 0 ]]; then
		var_FULL_BORG_CMD="$GLOBAL_TOOL_BORG delete --force ${GLOBAL_BORG_DIR}::${var_BORG_NEW_CONTENT}"
		var_OUTPUT="$(set -o pipefail ; eval $var_FULL_BORG_CMD 2>&1)"
		var_RETURN="$?"
		if [[ $var_RETURN -ne 0 ]]; then
			func_write_log -d "[Error] Borg backup delete \"${var_BORG_NEW_CONTENT}\", return $var_RETURN, fail with error:\n${var_OUTPUT}"
			func_mail_notify "[Error] Backup source, Borg backup delete fail." "Borg backup delete \"${var_BORG_NEW_CONTENT}\", fail with error:\n${var_OUTPUT}"
			exit 2
		fi
		func_write_log -d "[Info] Borg backup delete \"${var_BORG_NEW_CONTENT}\" success, force create new one."
	fi
	#var_CURRENT_VERSION="$(echo "$var_OUTPUT" | grep "$GLOBAL_SOURCE_BK_PREFIX" | wc -l)"
	local var_CURRENT_VERSION="$(echo "$var_OUTPUT" | wc -l)"

	# Get exclude
	func_get_exclude_borg

	# Run backup
	var_FULL_BORG_CMD="$GLOBAL_TOOL_BORG create -v --stats ${EXCLUDE_BORG} ${GLOBAL_BORG_DIR}::${var_BORG_NEW_CONTENT} $GLOBAL_SOURCE_FROM_DIR"

	var_OUTPUT="$(set -o pipefail ; eval $var_FULL_BORG_CMD 2>&1)"
	var_RETURN="$?"
	if [[ $var_RETURN -ne 0 ]]; then
		func_write_log -d "[Error] Borg backup create \"${var_BORG_NEW_CONTENT}\", return $var_RETURN, fail with error:\n${var_OUTPUT}"
		func_mail_notify "[Error] Backup source, Borg backup create fail." "Borg backup create \"${var_BORG_NEW_CONTENT}\", fail with error:\n${var_OUTPUT}"
		exit 2
	fi
	# Success
	func_write_log -d "[Info] Borg backup \"$var_BORG_NEW_CONTENT\" success."
	func_mail_notify "[Info] Backup source, Borg backup fail." "Borg backup \"$var_BORG_NEW_CONTENT\" success."

	# Rotate after backup
	if [[ $GLOBAL_ROTATE_ORDER -eq 0 ]]; then
		func_do_borg_rotate
	fi

	# None
	local var_PUT_TARGET="$GLOBAL_BORG_DIR"
	[[ "$(echo -en "$var_PUT_TARGET" | tr -s '/' | tail -c 1)" == "/" ]] && { var_PUT_TARGET="${var_PUT_TARGET:0:-1}"; }
	# If commpress
	if [[ "$GLOBAL_COMPRESS_CONTROL" != "none" ]]; then
		var_DIR="$GLOBAL_BORG_DIR"
		# Check slash
		[[ "$(echo -en "$GLOBAL_BORG_COMPRESS_DIR" | tail -c 1)" != "/" ]] && { GLOBAL_BORG_COMPRESS_DIR="${GLOBAL_BORG_COMPRESS_DIR}/"; }
		var_DEST="${GLOBAL_BORG_COMPRESS_DIR}borg.${var_TIME}"
		# If tar.gz
		if [[ "$GLOBAL_COMPRESS_CONTROL" == "tar" ]]; then
			ar_PUT_TARGET="$var_DEST.tar.gz"
		fi
		# If zip
		if [[ "$GLOBAL_COMPRESS_CONTROL" == "zip" ]]; then
			var_PUT_TARGET="$var_DEST.zip"
		fi
		func_do_compress_borg "$var_DEST"
		# Compress fail
		if [[ $? -ne 0 ]]; then
			var_PUT_TARGET="$GLOBAL_BORG_DIR"
			[[ "$(echo -en "$var_PUT_TARGET" | tr -s '/' | tail -c 1)" == "/" ]] && { var_PUT_TARGET="${var_PUT_TARGET:0:-1}"; }
		fi
		if [[ $GLOBAL_ROTATE_COMPRESS -eq 1 ]]; then
			func_do_compress_rotate "borg"
		fi
	fi

	# Put FTP
	if [[ "$GLOBAL_PUT_FTP" == "yes" ]]; then
		func_put_ftp "borg" "$var_PUT_TARGET"
	fi

	# Put SFTP
	if [[ "$GLOBAL_PUT_SFTP" == "yes" ]]; then
		func_put_sftp "borg" "$var_PUT_TARGET"
	fi

	# Put GDRIVE/RCLONE
	if [[ "$GLOBAL_PUT_GDRIVE" == "yes" ]]; then
		func_put_gdrive "borg" "$var_PUT_TARGET"
	fi
}

func_make_new_full_backup() {
	# Get time day
	local var_TIME=$(date +"${TIME_FORMAT_DAY}")
	local var_TIME_SECOND="$(date +"%Y%m%d%H%M").00"

	# Checking slash for GLOBAL_SOURCE_FROM_DIR + GLOBAL_SOURCE_TO_DIR
	[[ "$(echo -en "$GLOBAL_SOURCE_FROM_DIR" | tail -c 1)" != "/" ]] && { GLOBAL_SOURCE_FROM_DIR="${GLOBAL_SOURCE_FROM_DIR}/"; }
	[[ "$(echo -en "$GLOBAL_SOURCE_TO_DIR" | tail -c 1)" != "/" ]] && { GLOBAL_SOURCE_TO_DIR="${GLOBAL_SOURCE_TO_DIR}/"; }

	# Check GLOBAL_SOURCE_TO_DIR
	if [[ $GLOBAL_SOURCE_TO_DIR != "" && ! -d $GLOBAL_SOURCE_TO_DIR ]]; then
		mkdir -p $GLOBAL_SOURCE_TO_DIR
	fi

	local var_SOURCE_TO_DIR_BACKUP="${GLOBAL_SOURCE_TO_DIR}""${GLOBAL_SOURCE_BK_PREFIX}${var_TIME}"

	# Log
	func_write_log -d "[Info] Make new full rsync backup \"${var_SOURCE_TO_DIR_BACKUP}\"."

	# Check force
	if [[ -d "$var_SOURCE_TO_DIR_BACKUP" && $GLOBAL_FORCE_NEW_BACKUP -eq 0 ]]; then
		func_write_log -d "[Error] Do new full rsync backup, fail with error: \"${var_SOURCE_TO_DIR_BACKUP}\" exist."
		func_mail_notify "[Error] Backup source, Do new full rsync backup fail." "Make new full rsync backup, fail with error: \"${var_SOURCE_TO_DIR_BACKUP}\" exist."
		exit 2
	fi

	# Recreate, for new time
	mkdir -p "$var_SOURCE_TO_DIR_BACKUP"
	
	# Get exclude parameters
	func_get_exclude_rsync

	# Run backup
	local var_RSYNC_CMD="$GLOBAL_TOOL_RSYNC $RSYNC_OPTS $EXCLUDE_RSYNC $GLOBAL_SOURCE_FROM_DIR $var_SOURCE_TO_DIR_BACKUP"
	var_OUTPUT="$(set -o pipefail ; eval $var_RSYNC_CMD 2>&1)"
	var_RETURN="$?"
	if [[ $var_RETURN -ne 0 ]]; then
		func_write_log -d "[Error] Make new full rsync backup, return $var_RETURN, fail with error:\n${var_OUTPUT}"
		func_mail_notify "[Error] Backup source, Make new full rsync backup fail." "Make new full rsync backup, fail with error:\n${var_OUTPUT}"
		exit 2
	fi
	
	# Change timestamp if folder exist, for retain day
	if [[ -d "$var_SOURCE_TO_DIR_BACKUP" ]]; then
		func_write_log -d "[Info] Do new full rsync backup, change timestamp \"${var_SOURCE_TO_DIR_BACKUP}\" to \"$var_TIME_SECOND\"."
		touch -t $var_TIME_SECOND "${var_SOURCE_TO_DIR_BACKUP}"
	fi
}

func_do_rsync_rotate() {
	func_write_log -d "[Info] Do rsync rotate."
	# Check slash
	[[ "$(echo -en "$GLOBAL_SOURCE_TO_DIR" | tail -c 1)" != "/" ]] && { GLOBAL_SOURCE_TO_DIR="${GLOBAL_SOURCE_TO_DIR}/"; }

	# Get number current
	#var_LIST_CMD="find $GLOBAL_SOURCE_TO_DIR -maxdepth 1 -type d -name \"${GLOBAL_SOURCE_BK_PREFIX}*\""
	#var_LIST_DAILY_SOURCE="$(eval $var_LIST_CMD)"

	if [[ -d $GLOBAL_SOURCE_TO_DIR && $GLOBAL_SOURCE_RETAINDAYS -gt 0 ]]; then
		local var_LIST_OVER_DAY="$(find $GLOBAL_SOURCE_TO_DIR -maxdepth 1 -type d -name "${GLOBAL_SOURCE_BK_PREFIX}*" -mtime +$GLOBAL_SOURCE_RETAINDAYS)"
		while read LINE
		do
			[[ "$LINE" == "" ]] && { continue; }
			func_write_log -d "[Info] Do rsync rotate: remove $LINE"
			rm -rf "$LINE"
		done < <(echo "$var_LIST_OVER_DAY")
	fi
	func_write_log -d "[Info] Do rsync rotate success."
}

func_do_rsync_backup() {
	# Rotate before backup
	if [[ $GLOBAL_ROTATE_ORDER -eq 1 ]]; then
		func_do_rsync_rotate
	fi

	# Checking slash for GLOBAL_SOURCE_FROM_DIR + GLOBAL_SOURCE_TO_DIR
	[[ "$(echo -en "$GLOBAL_SOURCE_FROM_DIR" | tail -c 1)" != "/" ]] && { GLOBAL_SOURCE_FROM_DIR="${GLOBAL_SOURCE_FROM_DIR}/"; }
	[[ "$(echo -en "$GLOBAL_SOURCE_TO_DIR" | tail -c 1)" != "/" ]] && { GLOBAL_SOURCE_TO_DIR="${GLOBAL_SOURCE_TO_DIR}/"; }

	# Get today
	local var_TODAY_BACKUP="${GLOBAL_SOURCE_TO_DIR}${GLOBAL_SOURCE_BK_PREFIX}$(date +"${TIME_FORMAT_DAY}")"
	local var_TIME_SECOND="$(date +"%Y%m%d%H%M").00"

	if [[ $GLOBAL_INCREMENT_RSYNC -eq 0 ]]; then
		# New full rsync backup
		func_write_log -d "[Info] Do new full rsync backup."
		func_make_new_full_backup

		# Success
		func_write_log -d "[Info] Do new full rsync backup \"$var_TODAY_BACKUP\" success."
		func_mail_notify "[Info] Backup source, Do new full rsync backup success success." "Do new full rsync backup \"$var_TODAY_BACKUP\" success."
	else
		# New increment rsync backup
		func_write_log -d "[Info] Do new increment rsync backup."
		
		# Check slash
		[[ "$(echo -en "$GLOBAL_SOURCE_TO_DIR" | tail -c 1)" != "/" ]] && { GLOBAL_SOURCE_TO_DIR="${GLOBAL_SOURCE_TO_DIR}/"; }

		# Check GLOBAL_SOURCE_TO_DIR
		if [[ $GLOBAL_SOURCE_TO_DIR != "" && ! -d $GLOBAL_SOURCE_TO_DIR ]]; then
			mkdir -p $GLOBAL_SOURCE_TO_DIR
		fi

		# Today backup
		local var_TODAY_BACKUP="${GLOBAL_SOURCE_TO_DIR}${GLOBAL_SOURCE_BK_PREFIX}$(date +"${TIME_FORMAT_DAY}")"
		# Last day backup
		local var_LIST_LAST_BACKUP="$(find $GLOBAL_SOURCE_TO_DIR -maxdepth 1 -type d -name "${GLOBAL_SOURCE_BK_PREFIX}*" | sort -nr)"
		if [[ "$var_LIST_LAST_BACKUP" != "" ]]; then
			while read -r LINE
			do
				if [[ "$LINE" == "$var_TODAY_BACKUP" ]]; then
					continue
				else
					local var_LAST_BACKUP="$LINE"
					break
				fi
			done < <(echo "$var_LIST_LAST_BACKUP")
		fi

		# Check force
		if [[ -d $var_TODAY_BACKUP && $GLOBAL_FORCE_NEW_BACKUP -eq 0 ]]; then
			func_write_log -d "[Error] Make new increment rsync backup, fail with error: \"${var_TODAY_BACKUP}\" exist."
			func_mail_notify "[Error] Backup source, Make new increment rsync backup fail." "Make new increment rsync backup, fail with error: \"${var_TODAY_BACKUP}\" exist."
			exit 2
		fi

		# Check new full or increment
		if [[ ! -d $var_LAST_BACKUP ]]; then
			# New full rsync backup
			func_write_log -d "[Info] Not found last backup, do new full backup first."
			func_make_new_full_backup
			func_write_log -d "[Info] Do new full rsync backup \"$var_TODAY_BACKUP\" success."
		else
			if [[ -d $var_TODAY_BACKUP ]]; then
				func_write_log -d "[Info] Remove \"${var_TODAY_BACKUP}\" before increment."
				rm -rf "$var_TODAY_BACKUP"
			fi
			
			# Copy hardlink
			cp -alp "$var_LAST_BACKUP" "$var_TODAY_BACKUP"

			# Run backup
			func_get_exclude_rsync

			local var_RSYNC_CMD="$GLOBAL_TOOL_RSYNC $RSYNC_OPTS $EXCLUDE_RSYNC $GLOBAL_SOURCE_FROM_DIR $var_TODAY_BACKUP"
			var_OUTPUT="$(set -o pipefail ; eval $var_RSYNC_CMD 2>&1)"
			var_RETURN="$?"
			if [[ $var_RETURN -ne 0 ]]; then
				func_write_log -d "[Error] Make new increment rsync backup, return $var_RETURN, fail with error:\n${var_OUTPUT}"
				func_mail_notify "[Error] Backup source, Make new increment rsync backup fail." "Make new increment rsync backup, fail with error:\n${var_OUTPUT}"
				exit 2
			fi

			# Change timestamp if folder exist, for retain day
			if [[ -d "$var_TODAY_BACKUP" ]]; then
				func_write_log -d "[Info] Do new increment rsync backup, change timestamp \"${var_TODAY_BACKUP}\" to \"$var_TIME_SECOND\"."
				touch -t $var_TIME_SECOND "${var_TODAY_BACKUP}"
			fi

		fi

		# Success
		func_write_log -d "[Info] Do new increment rsync backup \"$var_TODAY_BACKUP\" success."
		func_mail_notify "[Info] Backup source, Do new increment rsync backup success" "Do new increment rsync backup \"$var_TODAY_BACKUP\" success."
	fi

	# Rotate after backup
	if [[ $GLOBAL_ROTATE_ORDER -eq 0 ]]; then
		func_do_rsync_rotate
	fi

	# None
	local var_PUT_TARGET="$var_TODAY_BACKUP"
	[[ "$(echo -en "$var_PUT_TARGET" | tr -s '/' | tail -c 1)" == "/" ]] && { var_PUT_TARGET="${var_PUT_TARGET:0:-1}"; }
	# If commpress
	if [[ "$GLOBAL_COMPRESS_CONTROL" != "none" ]]; then
		local var_DEST="$var_TODAY_BACKUP"
		# Check slash
		[[ "$(echo -en "$var_DEST" | tr -s '/' | tail -c 1)" == "/" ]] && { var_DEST="${var_DEST:0:-1}"; }
		# If tar.gz
		if [[ "$GLOBAL_COMPRESS_CONTROL" == "tar" ]]; then
			var_PUT_TARGET="$var_DEST.tar.gz"
		fi
		# If zip
		if [[ "$GLOBAL_COMPRESS_CONTROL" == "zip" ]]; then
			var_PUT_TARGET="$var_TODAY_BACKUP.zip"
		fi
		func_do_compress_dir "$var_DEST"
		# Compress fail
		if [[ $? -ne 0 ]]; then
			local var_PUT_TARGET="$var_TODAY_BACKUP"
			[[ "$(echo -en "$var_PUT_TARGET" | tr -s '/' | tail -c 1)" == "/" ]] && { var_PUT_TARGET="${var_PUT_TARGET:0:-1}"; }
		fi
		if [[ $GLOBAL_ROTATE_COMPRESS -eq 1 ]]; then
			func_do_compress_rotate "rsync"
		fi
	fi

	# Put FTP
	if [[ "$GLOBAL_PUT_FTP" == "yes" ]]; then
		func_put_ftp "rsync" "$var_PUT_TARGET"
	fi

	# Put SFTP
	if [[ "$GLOBAL_PUT_SFTP" == "yes" ]]; then
		func_put_sftp "rsync" "$var_PUT_TARGET"
	fi
	
	# Put GDRIVE/RCLONE
	if [[ "$GLOBAL_PUT_GDRIVE" == "yes" ]]; then
		func_put_gdrive "rsync" "$var_PUT_TARGET"
	fi
}

# Put FTP
func_put_ftp() {
	local var_TYPE="$1"
	local var_DIR_PUT="$(echo "$2" | tr -s '/')"

	# Rsync, database, borg type
	if [[ "$var_TYPE" == "rsync" || "$var_TYPE" == "database" || "$var_TYPE" == "borg" ]]; then
		func_write_log -d "[Info] Do FTP put \"$var_DIR_PUT\"."
		if [[ ! -d $var_DIR_PUT && ! -f $var_DIR_PUT ]]; then
			func_write_log -d "[Error] FTP put $var_TYPE, fail with error: \"$var_DIR_PUT\" not exist."
			func_mail_notify "[Error] Backup $var_TYPE, FTP put fail." "FTP put $var_TYPE, fail with error: \"$var_DIR_PUT\" not exist."
			return 2
		fi
		# Check slash
		if [[ -d "$var_DIR_PUT" ]]; then
			[[ "$(echo -en "$var_DIR_PUT" | tail -c 1)" != "/" ]] && { var_DIR_PUT="${var_DIR_PUT}/"; }
			local var_NOW="$(echo "$var_DIR_PUT" | awk -F'/' '{print $(NF-1)}')"
		else
			[[ "$(echo -en "$var_DIR_PUT" | tr -s '/' | tail -c 1)" == "/" ]] && { var_DIR_PUT="${var_DIR_PUT:0:-1}"; }
			local var_NOW="$(echo "$var_DIR_PUT" | awk -F'/' '{print $NF}')"
		fi
		[[ "$(echo -en "$GLOBAL_FTP_DEST" | tail -c 1)" != "/" ]] && { GLOBAL_FTP_DEST="${GLOBAL_FTP_DEST}/"; }

		if [[ "$var_NOW" == "" ]]; then
			func_write_log -d "[Error] FTP put $var_TYPE, fail with error: var_NOW missing."
			func_mail_notify "[Error] Backup $var_TYPE, FTP put fail." "FTP put $var_TYPE, fail with error: var_NOW missing."
			return 2
		fi
		
		# LFTP CMD
		local var_LFTP_CMD="$GLOBAL_TOOL_LFTP -e \"set ftp:ssl-allow no; rm -rf ${GLOBAL_FTP_DEST}${var_NOW}; mkdir ${GLOBAL_FTP_DEST}${var_NOW}; mirror -R $var_DIR_PUT ${GLOBAL_FTP_DEST}${var_NOW}; bye\" -u $GLOBAL_FTP_USER,\"$GLOBAL_FTP_PASS\" $GLOBAL_FTP_IP"
		if [[ -f "$var_DIR_PUT" ]]; then	
			var_LFTP_CMD="$GLOBAL_TOOL_LFTP -e \"set ftp:ssl-allow no; rm -rf ${GLOBAL_FTP_DEST}${var_NOW}; mkdir ${GLOBAL_FTP_DEST}${var_NOW}; put -O ${GLOBAL_FTP_DEST}${var_NOW} $var_DIR_PUT; bye\" -u $GLOBAL_FTP_USER,\"$GLOBAL_FTP_PASS\" $GLOBAL_FTP_IP"
		fi
		var_OUTPUT="$(set -o pipefail ; eval $var_LFTP_CMD 2>&1)"
		var_RETURN="$?"
		if [[ $var_RETURN -ne 0 ]]; then
			func_write_log -d "[Error] FTP put $var_TYPE, return $var_RETURN, fail with error:\n${var_OUTPUT}"
			func_mail_notify "[Error] Backup $var_TYPE, FTP put fail." "FTP put $var_TYPE, fail with error:\n${var_OUTPUT}"
			return 2
		fi

		# Success
		func_write_log -d "[Info] Do FTP put \"$var_DIR_PUT\" success."
		func_mail_notify "[Info] Backup $var_TYPE, Do FTP put success." "Do FTP put \"$var_DIR_PUT\" success."
	fi
	return 0
}

# Put SFTP
func_put_sftp() {
	local var_TYPE="$1"
	local var_DIR_PUT="$(echo "$2" | tr -s '/')"

	# Check connection
	local var_SSH_CHECK="$GLOBAL_TOOL_SSH -T $SSH_OPTS $GLOBAL_SFTP_USER@$GLOBAL_SFTP_IP exit"
	var_OUTPUT="$(set -o pipefail ; eval $var_SSH_CHECK 2>&1)"
	var_RETURN="$?"
	if [ $var_RETURN -ne 0 ]; then
		func_write_log -d "[Error] SFTP check SSH $GLOBAL_SFTP_USER@$GLOBAL_SFTP_IP, return $var_RETURN, fail with error:\n${var_OUTPUT}"
		func_mail_notify "[Error] Backup $var_TYPE, SFTP check fail." "SFTP check SSH $GLOBAL_SFTP_USER@$GLOBAL_SFTP_IP, fail with error:\n${var_OUTPUT}"
		return 2
	fi

	# Rsync type, database, borg type
	if [[ "$var_TYPE" == "rsync" || "$var_TYPE" == "database" || "$var_TYPE" == "borg" ]]; then
		func_write_log -d "[Info] Do SFTP put \"$var_DIR_PUT\"."
		if [[ ! -d $var_DIR_PUT && ! -f $var_DIR_PUT ]]; then
			func_write_log -d "[Error] SFTP put $var_TYPE, fail with error: \"$var_DIR_PUT\" not exist."
			func_mail_notify "[Error] Backup $var_TYPE, SFTP put fail." "SFTP put $var_TYPE, fail with error: \"$var_DIR_PUT\" not exist."
			return 2
		fi
		# Check remove slash
		[[ "$(echo -en "$var_DIR_PUT" | tr -s '/' | tail -c 1)" == "/" ]] && { var_DIR_PUT="${var_DIR_PUT:0:-1}"; }
		# Check add slash
		[[ "$(echo -en "$GLOBAL_SFTP_DEST" | tail -c 1)" != "/" ]] && { GLOBAL_SFTP_DEST="${GLOBAL_SFTP_DEST}/"; }

		# RSYNC CMD
		local var_RSYNC_CMD="$GLOBAL_TOOL_RSYNC $RSYNC_OPTS -e \"$GLOBAL_TOOL_SSH -T ${SSH_OPTS}\" $var_DIR_PUT $GLOBAL_SFTP_USER@$GLOBAL_SFTP_IP:$GLOBAL_SFTP_DEST"
		var_OUTPUT="$(set -o pipefail ; eval $var_RSYNC_CMD 2>&1)"
		var_RETURN="$?"
		if [[ $var_RETURN -ne 0 ]]; then
			func_write_log -d "[Error] SFTP put $var_TYPE, return $var_RETURN, fail with error:\n${var_OUTPUT}"
			func_mail_notify "[Error] Backup $var_TYPE, SFTP put fail." "SFTP put $var_TYPE, fail with error:\n${var_OUTPUT}"
			return 2
		fi

		# Success
		func_write_log -d "[Info] Do SFTP put \"$var_DIR_PUT\" success."
		func_mail_notify "[Info] Backup $var_TYPE, Do SFTP put success." "Do SFTP put \"$var_DIR_PUT\" success."
	fi
	return 0
}

# Put GDrive
func_put_gdrive() {	
	local var_TYPE="$1"
	local var_DIR_PUT="$(echo "$2" | tr -s '/')"

	# Check remote exist
	local var_RCLONE_REMOTE_CHECK="$GLOBAL_TOOL_RCLONE listremotes"
	var_OUTPUT="$(set -o pipefail ; eval $var_RCLONE_REMOTE_CHECK 2>&1)"
	var_RETURN="$?"
	if [[ $var_RETURN -ne 0 ]]; then
		func_write_log -d "[Error] GDRIVE/RCLONE put \"$var_DIR_PUT\", return $var_RETURN, fail with error:\n${var_OUTPUT}"
		func_mail_notify "[Error] Backup $var_TYPE, GDRIVE/RCLONE put fail." "GDRIVE/RCLONE put \"$var_DIR_PUT\", fail with error:\n${var_OUTPUT}"
		return 2
	else
		if [[ $(echo "$var_OUTPUT" | grep -c "$GLOBAL_RCLONE_REMOTE:") -eq 0 ]]; then
			func_write_log -d "[Error] GDRIVE/RCLONE put \"$var_DIR_PUT\", remote \"$GLOBAL_RCLONE_REMOTE\" not exist."
			func_mail_notify "[Error] Backup $var_TYPE, GDRIVE/RCLONE put fail." "GDRIVE/RCLONE put \"$var_DIR_PUT\", remote \"$GLOBAL_RCLONE_REMOTE\" not exist."
			return 2
		fi
	fi

	# Rsync type, database, borg type
	if [[ "$var_TYPE" == "rsync" || "$var_TYPE" == "database" || "$var_TYPE" == "borg" ]]; then
		func_write_log -d "[Info] Do GDRIVE/RCLONE put \"$var_DIR_PUT\"."
		if [[ ! -d $var_DIR_PUT && ! -f $var_DIR_PUT ]]; then
			func_write_log -d "[Error] GDRIVE/RCLONE put $var_TYPE, fail with error: \"$var_DIR_PUT\" not exist."
			func_mail_notify "[Error] Backup $var_TYPE, GDRIVE/RCLONE put fail." "GDRIVE/RCLONE put $var_TYPE, fail with error: \"$var_DIR_PUT\" not exist."
			return 2
		fi

		# Check slash
		[[ "$(echo -en "$var_DIR_PUT" | tail -c 1)" != "/" ]] && { var_DIR_PUT="${var_DIR_PUT}/"; }
		local var_NOW="$(echo "$var_DIR_PUT" | awk -F'/' '{print $(NF-1)}')"
		if [[ "$var_NOW" == "" ]]; then
			func_write_log -d "[Error] GDRIVE/RCLONE put $var_TYPE, fail with error: var_NOW missing."
			func_mail_notify "[Error] Backup $var_TYPE, GDRIVE/RCLONE put fail." "FTP put $var_TYPE, fail with error: var_NOW missing."
			return 2
		fi

		# RDRIVE / CLONE CMD
		local var_RCLONE_CMD="$GLOBAL_TOOL_RCLONE sync $var_DIR_PUT $GLOBAL_RCLONE_REMOTE:$var_NOW --create-empty-src-dirs"
		var_OUTPUT="$(set -o pipefail ; eval $var_RCLONE_CMD 2>&1)"
		var_RETURN="$?"
		if [[ $var_RETURN -ne 0 ]]; then
			func_write_log -d "[Error] GDRIVE/RCLONE put $var_TYPE, return $var_RETURN, fail with error:\n${var_OUTPUT}"
			func_mail_notify "[Error] Backup $var_TYPE, GDRIVE/RCLONE put fail." "GDRIVE/RCLONE put $var_TYPE, fail with error:\n${var_OUTPUT}"
			return 2
		fi

		# Success
		func_write_log -d "[Info] Do GDRIVE/RCLONE put \"$var_DIR_PUT\" success."
		func_mail_notify "[Info] Backup $var_TYPE, Do GDRIVE/RCLONE put success." "Do GDRIVE/RCLONE put \"$var_DIR_PUT\" success."
	fi
	return 0
}

# Mail notification
func_mail_notify() {
	# Enable or not
	if [[ $GLOBAL_SMTP_ENABLE -eq 0 ]]; then
		return 0
	fi

	local var_SUBJECT="$1"
	local var_BODY="$2"

	if [[ "$GLOBAL_SMTP_SERVER" == "" || "$GLOBAL_SMTP_AUTH_USER" == "" || "$GLOBAL_SMTP_AUTH_PASSWORD" == "" || "$GLOBAL_SMTP_TO_ADDRESS" == "" || "$GLOBAL_TOOL_MAIL" == "" ]]; then
		func_write_log -d "[Error] Do Mail notify, some configure missing."
		return 2
	fi
	func_write_log -d "[Info] Do Email notify."
	local var_MAIL_CMD="echo -e \"$var_BODY\" | $GLOBAL_TOOL_MAIL -s \"$var_SUBJECT\" -S smtp=\"$GLOBAL_SMTP_SERVER\" -S smtp-use-starttls -S ssl-verify=ignore -S smtp-auth=login -S smtp-auth-user=\"$GLOBAL_SMTP_AUTH_USER\" -S smtp-auth-password=\"$GLOBAL_SMTP_AUTH_PASSWORD\" -S from=\"Backup source <${GLOBAL_SMTP_FROM_ADDRESS}>\" -S nss-config-dir=\"/etc/pki/nssdb/\" $GLOBAL_SMTP_TO_ADDRESS"
	var_OUTPUT="$(set -o pipefail ; eval $var_MAIL_CMD 2>&1)"
	var_RETURN="$?"
	if [[ $var_RETURN -ne 0 ]]; then
		func_write_log -d "[Error] Do Email notify $var_TYPE, return $var_RETURN, fail with error:\n${var_OUTPUT}"
		return 2
	fi
	func_write_log -d "[Info] Do Email notify success."
}

# Compress function
func_do_compress_dir() {
	local var_TYPE="$GLOBAL_COMPRESS_CONTROL"
	local var_DIR="$1"
	local var_TIME_SECOND="$(date +"%Y%m%d%H%M").00"

	if [[ "$var_TYPE" == "tar" ]]; then
		if [[ ! -d "$var_DIR" ]]; then
			func_write_log -d "[Error] Do Compress type \"$var_TYPE\", fail with error \"$var_DIR\" not exist."
			return 2
		fi
		func_write_log -d "[Info] Do Compress type \"$var_TYPE\" for \"$var_DIR\"."
		# Dont delete source
		if [[ $GLOBAL_DELETE_SOURCE -eq 0 ]]; then
			#var_PARRENT="$(dirname -- "$var_DIR")"
			local var_TAR_CMD="$GLOBAL_TOOL_TAR -czf \"${var_DIR}.tar.gz\" \"$var_DIR\""
			var_OUTPUT="$(set -o pipefail ; eval $var_TAR_CMD 2>&1)"
			var_RETURN="$?"
			if [[ $var_RETURN -ne 0 || ! -f "${var_DIR}.tar.gz" ]]; then
				func_write_log -d "[Error] Do Compress type \"$var_TYPE\", return $var_RETURN, fail with error:\n${var_OUTPUT}"
				return 2
			fi
		fi
		# Delete source
		if [[ $GLOBAL_DELETE_SOURCE -eq 1 ]]; then
			local var_TAR_CMD="$GLOBAL_TOOL_TAR -czf \"${var_DIR}.tar.gz\" \"$var_DIR\""
			var_OUTPUT="$(set -o pipefail ; eval $var_TAR_CMD 2>&1)"
			var_RETURN="$?"
			if [[ $var_RETURN -ne 0 || ! -f "${var_DIR}.tar.gz" ]]; then
				func_write_log -d "[Error] Do Compress type \"$var_TYPE\", return $var_RETURN, fail with error:\n${var_OUTPUT}"
				return 2
			fi

			if [[ -f "${var_DIR}.tar.gz" ]]; then
				rm -rf "$var_DIR"
				func_write_log -d "[Info] Do Compress type \"$var_TYPE\", remove origin \"$var_DIR\"."
			fi
		fi
		# Change timestamp if folder exist, for retain day
		if [[ -f "${var_DIR}.tar.gz" ]]; then
			func_write_log -d "[Info] Do Compress type $var_TYPE, change timestamp \"${var_DIR}.tar.gz\" to \"$var_TIME_SECOND\"."
			touch -t $var_TIME_SECOND "${var_DIR}.tar.gz"
		fi
		func_write_log -d "[Info] Do Compress type \"$var_TYPE\" for \"${var_DIR}.tar.gz\" success."
	fi

	if [[ "$var_TYPE" == "zip" ]]; then
		if [[ ! -d "$var_DIR" ]]; then
			func_write_log -d "[Error] Do Compress type \"$var_TYPE\", fail with error \"$var_DIR\" not exist."
			return 2
		fi
		func_write_log -d "[Info] Do Compress type \"$var_TYPE\" for \"$var_DIR\"."
		# Dont delete source
		if [[ $GLOBAL_DELETE_SOURCE -eq 0 ]]; then
			local var_ZIP_CMD="$GLOBAL_TOOL_ZIP -r \"${var_DIR}.zip\" \"$var_DIR\""
			var_OUTPUT="$(set -o pipefail ; eval $var_ZIP_CMD 2>&1)"
			var_RETURN="$?"
			if [[ $var_RETURN -ne 0 || ! -f "${var_DIR}.zip" ]]; then
				func_write_log -d "[Error] Do Compress type \"$var_TYPE\", return $var_RETURN, fail with error:\n${var_OUTPUT}"
				return 2
			fi
		fi
		# Delete source
		if [[ $GLOBAL_DELETE_SOURCE -eq 1 ]]; then
			local var_ZIP_CMD="$GLOBAL_TOOL_ZIP -r \"${var_DIR}.zip\" \"$var_DIR\""
			var_OUTPUT="$(set -o pipefail ; eval $var_ZIP_CMD 2>&1)"
			var_RETURN="$?"
			if [[ $var_RETURN -ne 0 || ! -f "${var_DIR}.zip" ]]; then
				func_write_log -d "[Error] Do Compress type \"$var_TYPE\", return $var_RETURN, fail with error:\n${var_OUTPUT}"
				return 2
			fi

			if [[ -f "${var_DIR}.zip" ]]; then
				rm -rf "$var_DIR"
				func_write_log -d "[Info] Do Compress type \"$var_TYPE\", remove origin \"$var_DIR\"."
			fi
		fi
		# Change timestamp if folder exist, for retain day
		if [[ -f "${var_DIR}.zip" ]]; then
			func_write_log -d "[Info] Do Compress type $var_TYPE, change timestamp \"${var_DIR}.zip\" to \"$var_TIME_SECOND\"."
			touch -t $var_TIME_SECOND "${var_DIR}.zip"
		fi
		func_write_log -d "[Info] Do Compress type \"$var_TYPE\" for \"${var_DIR}.zip\" success."
	fi
	return 0
}

func_do_compress_borg() {
	local var_TYPE="$GLOBAL_COMPRESS_CONTROL"
	local var_DEST="$1"
	local var_TIME_SECOND="$(date +"%Y%m%d%H%M").00"

	if [[ "$var_TYPE" == "tar" ]]; then
		if [[ ! -d "$var_DIR" ]]; then
			func_write_log -d "[Error] Do Compress type \"$var_TYPE\", fail with error \"$var_DIR\" not exist."
			return 2
		fi
		func_write_log -d "[Info] Do Compress type \"$var_TYPE\" for \"$var_DIR\"."
		local var_TAR_CMD="$GLOBAL_TOOL_TAR -czf \"$var_DEST.tar.gz\" \"$var_DIR\""
		var_OUTPUT="$(set -o pipefail ; eval $var_TAR_CMD 2>&1)"
		var_RETURN="$?"2>&1
		if [[ $var_RETURN -ne 0 ]]; then
			func_write_log -d "[Error] Do Compress type \"$var_TYPE\", return $var_RETURN, fail with error:\n${var_OUTPUT}"
			return 2
		fi
		# Change timestamp if folder exist, for retain day
		if [[ -f "$var_DEST.tar.gz" ]]; then
			func_write_log -d "[Info] Do Compress type $var_TYPE, change timestamp \"$var_DEST.tar.gz\" to \"$var_TIME_SECOND\"."
			touch -t $var_TIME_SECOND "$var_DEST.tar.gz"
		fi
		func_write_log -d "[Info] Do Compress type \"$var_TYPE\" for \"$var_DEST.tar.gz\" success."
	fi

	if [[ "$var_TYPE" == "zip" ]]; then
		if [[ ! -d "$var_DIR" ]]; then
			func_write_log -d "[Error] Do Compress type \"$var_TYPE\", fail with error \"$var_DIR\" not exist."
			return 2
		fi
		func_write_log -d "[Info] Do Compress type \"$var_TYPE\" for \"$var_DIR\"."
		local var_ZIP_CMD="$GLOBAL_TOOL_ZIP -r \"$var_DEST.zip\" \"$var_DIR\""
		var_OUTPUT="$(set -o pipefail ; eval $var_ZIP_CMD 2>&1)"
		var_RETURN="$?"
		if [[ $var_RETURN -ne 0 ]]; then
			func_write_log -d "[Error] Do Compress type \"$var_TYPE\", return $var_RETURN, fail with error:\n${var_OUTPUT}"
			return 2
		fi
		# Change timestamp if folder exist, for retain day
		if [[ -f "$var_DEST.zip" ]]; then
			func_write_log -d "[Info] Do Compress type $var_TYPE, change timestamp \"$var_DEST.zip\" to \"$var_TIME_SECOND\"."
			touch -t $var_TIME_SECOND "$var_DEST.zip"
		fi
		func_write_log -d "[Info] Do Compress type \"$var_TYPE\" for \"$var_DEST.zip\" success."
	fi
	return 0
}

func_do_compress_rotate() {
	local var_WHAT="$1"
	# Rotate rsync
	if [[ "$var_WHAT" == "rsync" ]]; then
		func_write_log -d "[Info] Do Compress rotate $var_WHAT."
		# Check slash
		local var_SOURCE_TO_DIR="$GLOBAL_SOURCE_TO_DIR"
		[[ "$(echo -en "$var_SOURCE_TO_DIR" | tail -c 1)" != "/" ]] && { var_SOURCE_TO_DIR="${var_SOURCE_TO_DIR}/"; }

		# Get number current
		#var_LIST_CMD="find $GLOBAL_SOURCE_TO_DIR -maxdepth 1 -type d -name \"${GLOBAL_SOURCE_BK_PREFIX}*\""
		#var_LIST_DAILY_SOURCE="$(eval $var_LIST_CMD)"

		if [[ -d $var_SOURCE_TO_DIR && $GLOBAL_SOURCE_RETAINDAYS -gt 0 ]]; then
			# tar rotate
			if [[ "$GLOBAL_COMPRESS_CONTROL" == "tar" ]]; then
				local var_LIST_OVER_DAY="$(find $var_SOURCE_TO_DIR -maxdepth 1 -type f -name "${GLOBAL_SOURCE_BK_PREFIX}*.tar.gz" -mtime +$GLOBAL_SOURCE_RETAINDAYS)"
				while read LINE
				do
					[[ "$LINE" == "" ]] && { continue; }
					func_write_log -d "[Info] Do compress \"$GLOBAL_COMPRESS_CONTROL\" rotate: remove $LINE"
					rm -rf "$LINE"
				done < <(echo "$var_LIST_OVER_DAY")
			fi
			# zip rotate
			if [[ "$GLOBAL_COMPRESS_CONTROL" == "zip" ]]; then
				local var_LIST_OVER_DAY="$(find $var_SOURCE_TO_DIR -maxdepth 1 -type f -name "${GLOBAL_SOURCE_BK_PREFIX}*.zip" -mtime +$GLOBAL_SOURCE_RETAINDAYS)"
				while read LINE
				do
					[[ "$LINE" == "" ]] && { continue; }
					func_write_log -d "[Info] Do compress \"$GLOBAL_COMPRESS_CONTROL\" rotate: remove $LINE"
					rm -rf "$LINE"
				done < <(echo "$var_LIST_OVER_DAY")
			fi
		fi
		func_write_log -d "[Info] Do Compress rotate $var_WHAT success."
	fi

	# Rotate database
	if [[ "$var_WHAT" == "database" ]]; then
		func_write_log -d "[Info] Do Compress rotate $var_WHAT."
		# Check slash
		local var_DATABASE_TO_DIR="$GLOBAL_DATABASE_TO_DIR"
		[[ "$(echo -en "$var_DATABASE_TO_DIR" | tail -c 1)" != "/" ]] && { var_DATABASE_TO_DIR="${var_DATABASE_TO_DIR}/"; }

		if [[ -d $var_DATABASE_TO_DIR ]]; then
			local var_LIST_OVER_DAY=""
			# tar rotate
			if [[ "$GLOBAL_COMPRESS_CONTROL" == "tar" ]]; then
				if [[ $GLOBAL_DATABASE_RETAIN_UNIT == "hour" ]]; then
					local var_HOUR=$(($GLOBAL_DATABASE_RETAIN_HOUR * 60))
					var_LIST_OVER_DAY="$(find $var_DATABASE_TO_DIR -maxdepth 1 -type f -name "${GLOBAL_DATABASE_BK_REFIX}*.tar.gz" -mmin +$var_HOUR)"
				fi
				if [[ $GLOBAL_DATABASE_RETAIN_UNIT == "day" ]]; then
					local var_DAY="$GLOBAL_DATABASE_RETAIN_DAY"
					var_LIST_OVER_DAY="$(find $var_DATABASE_TO_DIR -maxdepth 1 -type f -name "${GLOBAL_DATABASE_BK_REFIX}*.tar.gz" -mtime +$var_DAY)"
				fi
			fi
			# zip rotate
			if [[ "$GLOBAL_COMPRESS_CONTROL" == "zip" ]]; then	
				if [[ $GLOBAL_DATABASE_RETAIN_UNIT == "hour" ]]; then
					local var_HOUR=$(($GLOBAL_DATABASE_RETAIN_HOUR * 60))
					var_LIST_OVER_DAY="$(find $var_DATABASE_TO_DIR -maxdepth 1 -type f -name "${GLOBAL_DATABASE_BK_REFIX}*.zip" -mmin +$var_HOUR)"
				fi
				if [[ $GLOBAL_DATABASE_RETAIN_UNIT == "day" ]]; then
					local var_DAY="$GLOBAL_DATABASE_RETAIN_DAY"
					var_LIST_OVER_DAY="$(find $var_DATABASE_TO_DIR -maxdepth 1 -type f -name "${GLOBAL_DATABASE_BK_REFIX}*.zip" -mtime +$var_DAY)"
				fi
			fi
			# Start remove
			while read LINE
			do
				[[ "$LINE" == "" ]] && { continue; }
				func_write_log -d "[Info] Do compress \"$GLOBAL_COMPRESS_CONTROL\" rotate: remove $LINE"
				rm -rf "$LINE"
			done < <(echo "$var_LIST_OVER_DAY")
		fi
		func_write_log -d "[Info] Do Compress rotate $var_WHAT success."
	fi

	# Rotate borg
	if [[ "$var_WHAT" == "borg" ]]; then
		func_write_log -d "[Info] Do Compress rotate $var_WHAT."
		# Check slash
		local var_BORG_TO_DIR="$GLOBAL_BORG_COMPRESS_DIR"
		local var_BORG_PREFIX="borg"
		[[ "$(echo -en "$var_BORG_TO_DIR" | tail -c 1)" != "/" ]] && { var_BORG_TO_DIR="${var_BORG_TO_DIR}/"; }

		if [[ -d $var_BORG_TO_DIR && $GLOBAL_SOURCE_RETAINDAYS -gt 0 ]]; then
			# tar rotate
			if [[ "$GLOBAL_COMPRESS_CONTROL" == "tar" ]]; then
				local var_LIST_OVER_DAY="$(find $var_BORG_TO_DIR -maxdepth 1 -type f -name "${var_BORG_PREFIX}*.tar.gz" -mtime +$GLOBAL_SOURCE_RETAINDAYS)"
				while read LINE
				do
					[[ "$LINE" == "" ]] && { continue; }
					func_write_log -d "[Info] Do compress \"$GLOBAL_COMPRESS_CONTROL\" rotate: remove $LINE"
					rm -rf "$LINE"
				done < <(echo "$var_LIST_OVER_DAY")
			fi
			# zip rotate
			if [[ "$GLOBAL_COMPRESS_CONTROL" == "zip" ]]; then
				local var_LIST_OVER_DAY="$(find $var_BORG_TO_DIR -maxdepth 1 -type f -name "${var_BORG_PREFIX}*.zip" -mtime +$GLOBAL_SOURCE_RETAINDAYS)"
				while read LINE
				do
					[[ "$LINE" == "" ]] && { continue; }
					func_write_log -d "[Info] Do compress \"$GLOBAL_COMPRESS_CONTROL\" rotate: remove $LINE"
					rm -rf "$LINE"
				done < <(echo "$var_LIST_OVER_DAY")
			fi
		fi
		func_write_log -d "[Info] Do Compress rotate $var_WHAT success."
	fi
}

# Main run
if [[ "$1" == "rsync" ]]; then
	func_do_rsync_backup
fi
if [[ "$1" == "borg" ]]; then
	func_do_borg_backup
fi
