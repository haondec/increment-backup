#!/bin/bash
# Backup database

#-------------------------------------------------------------------------------------------------
###   Pernament script var
#-------------------------------------------------------------------------------------------------

# Root script directory
ROOT_SCRIPT_DIR="/etc/backup-tool/"
CONFIG_FILE="${ROOT_SCRIPT_DIR}/settings.conf"
CREDENTIAL_FILE="${ROOT_SCRIPT_DIR}/credentials.txt"

# Local script varibales
ALL_DB=""
LIST_ALL_DB_EXCLUDE=""
TIME_FORMAT_DAY="%Y-%m-%d"
TIME_FORMAT_HOUR="%Y-%m-%d_%H"
TIME_FORMAT_SECOND="%Y-%m-%d %H-%M-%S"

MYSQL_OPTS="--single-transaction --skip-lock-tables"
MYSQL_LOCK="--lock-tables"

# Set settings
if [[ ! -f $CONFIG_FILE ]]; then
	mkdir -p "$ROOT_SCRIPT_DIR/logs"
	echo "[Error] Missing \"${ROOT_SCRIPT_DIR}/settings.conf\" file." | tee -a "$ROOT_SCRIPT_DIR/logs/database.log"
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

#func_get_exclude_table() {
	# Clear it
#	EXCLUDE_TABLE=""
#	for dir in "${GLOBAL_EXCLUDE_DIR[@]}"
#	do
#		[[ "$dir" == "" ]] && { continue; }
#		EXCLUDE_RSYNC="$EXCLUDE_RSYNC""--exclude '$dir' "
#	done
#}

# List all database
func_get_all_db() {
	local ALL_DB="$(set -o pipefail ; $GLOBAL_TOOL_MYSQL --defaults-extra-file=$CREDENTIAL_FILE -h $GLOBAL_MYSQL_HOST -P $GLOBAL_MYSQL_PORT -Bse 'show databases' 2>&1)"
	if [[ $? -ne 0 ]]; then
		func_write_log -d "[Error] List all databases, fail with error:\n${ALL_DB}"
		func_mail_notify "[Error] Backup database, List all databases fail." "List all databases, fail with error:\n${ALL_DB}"
		exit 2
	fi
}

func_get_all_db_exclude() {
	local var_LIST_EXCLUDE=""
	LIST_ALL_DB_EXCLUDED=""
	for db in "${GLOBAL_DATABASE_EXCLUDE[@]}"
	do
		[[ "$db" == "" ]] && { continue; }
		if [[ "$var_LIST_EXCLUDE" == "" ]]; then
			var_LIST_EXCLUDE="$var_LIST_EXCLUDE""$db"
		else
			var_LIST_EXCLUDE="$var_LIST_EXCLUDE""\\|$db"
		fi
	done
	LIST_ALL_DB_EXCLUDE="$(set -o pipefail ; $GLOBAL_TOOL_MYSQL --defaults-extra-file=$CREDENTIAL_FILE -h $GLOBAL_MYSQL_HOST -P $GLOBAL_MYSQL_PORT -Bse 'show databases' | grep -x -v "$var_LIST_EXCLUDE" 2>&1)"
}

# Backup signle database with parameter
func_do_backup_single_db() {
	local var_DB_NAME="$1"
	local var_LIST_TABLE_EXCLUDE="$2"
	local var_LIST_TABLE_SCHEME_ONLY="$3"
	local var_TODAY_BACKUP="$4"

	# Create new folder
	if [[ "$var_TODAY_BACKUP" == "" ]]; then
		func_write_log -d "[Error] Mysqldump \"$var_DB_NAME\", fail with error:\n\"var_TODAY_BACKUP\" save backup empty."
		return 2
	fi
	mkdir -p "$var_TODAY_BACKUP"

	# Check slash
	[[ "$(echo -en "$var_TODAY_BACKUP" | tail -c 1)" != "/" ]] && { var_TODAY_BACKUP="${var_TODAY_BACKUP}/"; }

	# Create dump command
	local var_MYSQLDUMP_OPTS="--defaults-extra-file=$CREDENTIAL_FILE -h $GLOBAL_MYSQL_HOST -P $GLOBAL_MYSQL_PORT"
	if [[ "$GLOBAL_DATABASE_LOCK_BY_DAY" != "yes" ]]; then
		var_MYSQLDUMP_OPTS="${var_MYSQLDUMP_OPTS} ${MYSQL_OPTS}"
	else
		var_MYSQLDUMP_OPTS="${var_MYSQLDUMP_OPTS} ${MYSQL_LOCK}"
	fi
	local var_MYSQLDUMP_CMD="$GLOBAL_TOOL_MYSQLDUMP $var_MYSQLDUMP_OPTS $var_LIST_TABLE_EXCLUDE $var_DB_NAME > ${var_TODAY_BACKUP}${var_DB_NAME}.sql"

	# Start dump tables + data
	var_OUTPUT="$(set -o pipefail ; eval $var_MYSQLDUMP_CMD 2>&1)"
	var_RETURN="$?"
	if [[ $var_RETURN -ne 0 ]]; then
		func_write_log -d "[Error] Mysqldump \"$var_DB_NAME\", return $var_RETURN, fail with error:\n${var_OUTPUT}"
		# Clear dump false
		if [[ $GLOBAL_DATABASE_CLEAR_DUMP_FALSE -eq 1 ]]; then
			rm -f "${var_TODAY_BACKUP}${var_DB_NAME}"
		fi
		return 2
	fi

	# Start dump table scheme only
	while read -r LINE
	do
		[[ "$LINE" == "" ]] && { continue; }
		local var_MYSQLDUMP_CMD="$GLOBAL_TOOL_MYSQLDUMP $var_MYSQLDUMP_OPTS $var_DB_NAME -d $LINE >> ${var_TODAY_BACKUP}${var_DB_NAME}.sql"
		var_OUTPUT="$(set -o pipefail ; eval $var_MYSQLDUMP_CMD 2>&1)"
		var_RETURN="$?"
		if [[ $var_RETURN -ne 0 ]]; then
			func_write_log -d "[Error] Mysqldump \"$var_DB_NAME\" table scheme \"$LINE\", return $var_RETURN, fail with error:\n${var_OUTPUT}"
			continue
		fi
		func_write_log -d "[Info] Mysqldump \"$var_DB_NAME\" table scheme \"$LINE\" success."
	done < <(echo "$var_LIST_TABLE_SCHEME_ONLY")

	func_write_log -d "[Info] Mysqldump \"${var_TODAY_BACKUP}${var_DB_NAME}.sql\" success."
}

# Do rotate database
func_do_db_rotate() {
	func_write_log -d "[Info] Do database rotate."
	# Check slash
	[[ "$(echo -en "$GLOBAL_DATABASE_TO_DIR" | tail -c 1)" != "/" ]] && { GLOBAL_DATABASE_TO_DIR="${GLOBAL_DATABASE_TO_DIR}/"; }

	# Get number current
	#var_LIST_CMD="find $GLOBAL_DATABASE_TO_DIR -maxdepth 1 -type d -name \"${GLOBAL_DATABASE_BK_REFIX}*\""
	#var_LIST_DAILY_SOURCE="$(eval $var_LIST_CMD)"

	if [[ -d $GLOBAL_DATABASE_TO_DIR ]]; then
		if [[ $GLOBAL_DATABASE_RETAIN_UNIT == "hour" ]]; then
			local var_HOUR=$(($GLOBAL_DATABASE_RETAIN_HOUR * 60))
			local var_LIST_OVER_DAY="$(find $GLOBAL_DATABASE_TO_DIR -maxdepth 1 -type d -name "${GLOBAL_DATABASE_BK_REFIX}*" -mmin +$var_HOUR)"
	       		while read LINE
			do
				[[ "$LINE" == "" ]] && { continue; }
				func_write_log -d "[Info] Do database rotate by hour: remove $LINE"
				rm -rf "$LINE"
			done < <(echo "$var_LIST_OVER_DAY")
		fi
		if [[ $GLOBAL_DATABASE_RETAIN_UNIT == "day" ]]; then
			local var_DAY="$GLOBAL_DATABASE_RETAIN_DAY"
			local var_LIST_OVER_DAY="$(find $GLOBAL_DATABASE_TO_DIR -maxdepth 1 -type d -name "${GLOBAL_DATABASE_BK_REFIX}*" -mtime +$var_DAY)"
	       		while read LINE
			do
				[[ "$LINE" == "" ]] && { continue; }
				func_write_log -d "[Info] Do database rotate by day: remove $LINE"
				rm -rf "$LINE"
			done < <(echo "$var_LIST_OVER_DAY")
		fi
	fi
	func_write_log -d "[Info] Do database rotate success."
}

# Do backup all database
func_do_backup_dbs() {
	func_get_all_db

	# Rotate after backup
	if [[ $GLOBAL_ROTATE_ORDER -eq 1 ]]; then
		func_do_db_rotate
	fi

	# Check slash
	[[ "$(echo -en "$GLOBAL_DATABASE_TO_DIR" | tail -c 1)" != "/" ]] && { GLOBAL_DATABASE_TO_DIR="${GLOBAL_DATABASE_TO_DIR}/"; }
	# RETAIN by hour
	if [[ $GLOBAL_DATABASE_RETAIN_UNIT == "hour" ]]; then
		local var_TIME=$(date +"${TIME_FORMAT_HOUR}")
		local var_TODAY_BACKUP="$GLOBAL_DATABASE_TO_DIR""${GLOBAL_DATABASE_BK_REFIX}hour.${var_TIME}"
	else
		local var_TIME=$(date +"${TIME_FORMAT_DAY}")
		local var_TODAY_BACKUP="$GLOBAL_DATABASE_TO_DIR""${GLOBAL_DATABASE_BK_REFIX}day.${var_TIME}"	
	fi

	# Check force
	if [[ -d $var_TODAY_BACKUP && $GLOBAL_FORCE_NEW_BACKUP -eq 0 ]]; then
		func_write_log -d "[Error] Make new database backup, fail with error: \"${var_TODAY_BACKUP}\" exist."
		func_mail_notify "[Error] Backup database, Make new database backup fail." "Make new database backup, fail with error: \"${var_TODAY_BACKUP}\" exist."
		exit 2
	fi

	# List database with dump
	local var_LIST_DB="$GLOBAL_DATABASE_CERTAIN"
	if [[ $GLOBAL_EXPORT_ALL -eq 1 ]]; then
		func_write_log -d "[Info] Do export all database."
		func_get_all_db_exclude
		var_LIST_DB="$LIST_ALL_DB_EXCLUDE"
	else
		func_write_log -d "[Info] Do export certain database."
	fi

	while read -r LINE
	do
		[[ "$LINE" == "" ]] && { continue; }
		local var_DBNAME="$LINE"

		# Get list table exclude of certain database
		local var_LIST_TABLE_EXCLUDE=""
		for tb in "${GLOBAL_TABLE_EXCLUDE[@]}"
		do
			[[ "$tb" == "" ]] && { continue; }
			local var_DBNAME_TABLE="$(echo "$tb" | awk -F'.' '{print $1}')"
			if [[ "$var_DBNAME" == "$var_DBNAME_TABLE" ]]; then
				if [[ "$var_LIST_TABLE_EXCLUDE" == "" ]]; then
					var_LIST_TABLE_EXCLUDE="$var_LIST_TABLE_EXCLUDE""--ignore-table={$tb"
				else
					var_LIST_TABLE_EXCLUDE="$var_LIST_TABLE_EXCLUDE"",$tb"
				fi
			fi
		done
	
		# Get list table scheme only
		local var_LIST_TABLE_SCHEME_ONLY=""
		for tb in "${GLOBAL_TABLE_SCHEME_ONLY[@]}"
		do
			[[ "$tb" == "" ]] && { continue; }
			local var_DBNAME_TABLE="$(echo "$tb" | awk -F'.' '{print $1}')"
			local var_TABLE="$(echo "$tb" | awk -F'.' '{print $2}')"
			if [[ "$var_DBNAME" == "$var_DBNAME_TABLE" ]]; then
				local var_NEWLINE=$'\n'
				if [[ $(echo "$var_LIST_TABLE_EXCLUDE" | grep -c "$tb") -eq 0 ]]; then
					if [[ "$var_LIST_TABLE_EXCLUDE" == "" && "$var_TABLE" != "" ]]; then
						var_LIST_TABLE_EXCLUDE="$var_LIST_TABLE_EXCLUDE""--ignore-table={$tb"
					else
						var_LIST_TABLE_EXCLUDE="$var_LIST_TABLE_EXCLUDE"",$tb"
					fi
				fi
					if [[ "$var_LIST_TABLE_SCHEME_ONLY" == "" && "$var_TABLE" != "" ]]; then
					var_LIST_TABLE_SCHEME_ONLY="$var_LIST_TABLE_SCHEME_ONLY""$tb"
				else
					var_LIST_TABLE_SCHEME_ONLY="$var_LIST_TABLE_SCHEME_ONLY""${var_NEWLINE}${tb}"
				fi
			fi
		done

		# Close var_LIST_TABLE_EXCLUDE
		if [[ "$var_LIST_TABLE_EXCLUDE" != "" ]]; then
			var_LIST_TABLE_EXCLUDE="$var_LIST_TABLE_EXCLUDE""}"
		fi
		#echo "$var_LIST_TABLE_EXCLUDE"
		#echo  "$var_LIST_TABLE_SCHEME_ONLY"

		func_do_backup_single_db "$var_DBNAME" "$var_LIST_TABLE_EXCLUDE" "$var_LIST_TABLE_SCHEME_ONLY" "$var_TODAY_BACKUP"
	done < <(echo "$var_LIST_DB")

	# Success
	func_write_log -d "[Info] Do export databases success."
	func_mail_notify "[Info] Backup database, Do export databases success." "Do export databases success."

	# Rotate after backup
	if [[ $GLOBAL_ROTATE_ORDER -eq 0 ]]; then
		func_do_db_rotate
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
			func_do_compress_rotate "database"
		fi
	fi

	# Put FTP
	if [[ "$GLOBAL_PUT_FTP" == "yes" ]]; then
		func_put_ftp "database" "$var_PUT_TARGET"
	fi

	# Put SFTP
	if [[ "$GLOBAL_PUT_SFTP" == "yes" ]]; then
		func_put_sftp "database" "$var_PUT_TARGET"
	fi

	# Put GDRIVE/RCLONE
	if [[ "$GLOBAL_PUT_GDRIVE" == "yes" ]]; then
		func_put_gdrive "database" "$var_PUT_TARGET"
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
if [[ "$1" == "hour" ]]; then
	GLOBAL_DATABASE_RETAIN_UNIT="hour"
fi
if [[ "$1" == "day" ]]; then
	GLOBAL_DATABASE_RETAIN_UNIT="day"
fi

func_do_backup_dbs
