#!/usr/bin/env bash
RCDIR="$(dirname "${BASH_SOURCE[0]}")"
RCFILE="$RCDIR/ec2init.rc"
if [[ -f "$RCFILE" ]] ; then
		# shellcheck source=/dev/null
        source "$RCFILE"
fi
$PKG_CMD install -y lvm2
##
## Variables
##
LVNAME="data"
MKFS="mkfs -t xfs"
MOUNTPOINT="/bigdisk/tmp"
LVM_SUPPRESS_FD_WARNINGS=1	# LVM seems to get annoyed in cloud-init settings, so suppress warnings
EBS_SIZE=30
case $OSDISTRIBUTION in
    Amazon)
		ROOT_DEVICE_LABLE="/"
		;;
	Ubuntu|Debian)
		ROOT_DEVICE_LABLE="cloudimg-rootfs"
		;;
	*)
		echo "Linux distribution not detected:"
		exit 127
		;;
esac
ROOT_DRIVE=$(blkid -L "$ROOT_DEVICE_LABLE" -o device)
ROOT_DRIVE=${ROOT_DRIVE##*/}
case $ROOT_DRIVE in
	sda1)
		IGNORE_DRIVE_PATTERN="sda"
		EBS_DEVICENAME="sdz"
	;;
	xvda1)
		IGNORE_DRIVE_PATTERN="xvda"
		EBS_DEVICENAME="xvdz"
	;;
	nvme0n1p1)
		IGNORE_DRIVE_PATTERN="nvme0n1"
		EBS_DEVICENAME="xvdz"
	;;
	nvme1n1p1)
		IGNORE_DRIVE_PATTERN="nvme1n1"
		EBS_DEVICENAME="xvdz"
	;;
	*)
		echo "Unknown naming scheme, exiting ...."
		exit 4
	;;
esac
##
## Functions
##
# Create EBS (if ephemeral storage is not sufficient)
function create_ebs {
	local EBS_DEVICE="$1"
	local EBS_SIZE=$2
	local VOLUME_ID
	VOLUME_ID="$(runAwsCommand ec2 create-volume \
		--size "$EBS_SIZE" \
		--availability-zone "$AVAILABILITY_ZONE" \
		--query VolumeId)" 
	local VOLUME_STATE="none"
	while [ "$VOLUME_STATE" != "available" ] ; do 
		local VOLUME_STATE
		# shellcheck disable=SC2102	
		VOLUME_STATE=$(runAwsCommand ec2 describe-volumes \
			--volume-id "$VOLUME_ID" \
			--query Volumes[*].[State])
	done	
	local VOLUME_ATTACHMENT_STATE="none"
	VOLUME_ATTACHMENT_STATE=$(runAwsCommand ec2 attach-volume \
		--device "$EBS_DEVICE" \
		--instance-id "$INSTANCE_ID" \
		--volume-id "$VOLUME_ID" \
		--query State)
	while [ "$VOLUME_ATTACHMENT_STATE" != "attached" ] ; do 
		local VOLUME_ATTACHMENT_STATE
		VOLUME_ATTACHMENT_STATE=$(runAwsCommand ec2 describe-volumes \
			--volume-id "$VOLUME_ID" \
			--query Volumes[*].[Attachments[*].State])
	done
	if [[ -z "$INSTANCE_NAME" ]] ; then
	local INSTANCE_NAME
	INSTANCE_NAME=$(runAwsCommand ec2 describe-tags \
		--filters Name=resource-id,Values="$INSTANCE_ID" Name=key,Values=Name --query Tags[*].ResourceId)
	fi
	runAwsCommand ec2 modify-instance-attribute \
		--instance-id  "$INSTANCE_ID" \
		--block-device-mappings DeviceName="$EBS_DEVICE",Ebs=\{DeleteOnTermination=true\}
	runAwsCommand ec2 create-tags \
		--resources "$VOLUME_ID" \
		--tags Key=Name,Value="${INSTANCE_NAME}" > /dev/null
	echo "/dev/${EBS_DEVICE}"
}

function detect_devices { 
	local DEVICES_LIST
	DEVICES_LIST=$(find /dev -type b | grep -Ev "$IGNORE_DRIVE_PATTERN|loop|dm|xvdcz")
	if [[ -z $DEVICES_LIST ]] ; then
		if [[ -n $EBS_SIZE ]] && [[ $EBS_SIZE -gt 0 ]] ; then
			local DEVICES
			DEVICES=$(create_ebs $EBS_DEVICENAME "$EBS_SIZE")
		else
			echo "No ephemeral devices found and no fallback EBS devices configured"
			exit 4
		fi
	else
		for DEVICE in $DEVICES_LIST ; do
			if grep -q "$(readlink -f "$DEVICE")" /proc/mounts ; then
				umount "$DEVICE"
				sed -i.bak /"${DEVICE//\//\\/}"/d /etc/fstab
			fi
			local DEVICES+="$DEVICE"
		done
	fi
       	echo ${DEVICES[@]}
}

# Creates a new LVM volume. Accepts an array of block devices to use as physical storage. 
function create_volume { 	
	for device in "$@" ; do
		pvcreate "$device" --yes --verbose
	done 
	vgcreate $LVNAME "$@" --verbose
	lvcreate -l 100%FREE $LVNAME --yes --verbose
	local VOLUME=$(lvdisplay --columns --options "lv_path" --noheading)
	echo $VOLUME
} 


VOLUME=$(lvdisplay --columns --options "lv_path" --noheading)
if [[ -z "$VOLUME" ]] ; then 	
	VOLUME=$(create_volume "$(detect_devices)")
fi 
$MKFS $VOLUME
mkdir -p $MOUNTPOINT
mount $VOLUME $MOUNTPOINT 
chown "$DEFUSER".users $MOUNTPOINT
chmod 2777 $MOUNTPOINT
echo "export TMPDIR=$MOUNTPOINT" > /etc/profile.d/tempdir.sh
echo "export TMP=$MOUNTPOINT" >> /etc/profile.d/tempdir.sh
echo "export TEMP=$MOUNTPOINT" >> /etc/profile.d/tempdir.sh

echo "Mounted $VOLUME"
