#!/bin/bash

ROOT_SCRIPT_DIR="/etc/backup-tool/"
CONFIG_FILE="${ROOT_SCRIPT_DIR}/settings.conf"

source "$CONFIG_FILE"

## Start install tool

chmod +x /etc/backup-tool/borg
mount -o remount,exec /tmp

yum install rsync lftp mailx zip -y
if [[ "$GLOBAL_TOOL_RCLONE" == "" ]]; then
	curl https://rclone.org/install.sh | sudo bash
fi

# Create GDRIVE/RCLONE
GLOBAL_TOOL_RCLONE="$(which rclone)"

# Init remote gdrive
if [[ $GLOBAL_RCLONE_GDRIVE_INIT -eq 1 ]]; then
	var_RCLONE_REMOTE_CHECK="$GLOBAL_TOOL_RCLONE listremotes"
	var_OUTPUT="$(set -o pipefail ; eval $var_RCLONE_REMOTE_CHECK 2>&1)"
	if [[ $? -ne 0 ]]; then
		echo "[Error] rclone check listremotes, fail with error:\n${var_OUTPUT}"
	else
		echo "---------------------------------------------------------------"
		if [[ $(echo "$var_OUTPUT" | grep -c "$GLOBAL_RCLONE_REMOTE:") -ne 0 ]]; then
			$GLOBAL_TOOL_RCLONE config delete "$GLOBAL_RCLONE_REMOTE"
		fi
		$GLOBAL_TOOL_RCLONE config create "$GLOBAL_RCLONE_REMOTE" drive scope drive.file client_id "$GLOBAL_RCLONE_CLIENT_ID" client_secret "$GLOBAL_RCLONE_CLIENT_SECRET" root_folder_id "$GLOBAL_RCLONE_ROOTFOLDER_ID" config_is_local false
	fi
fi
