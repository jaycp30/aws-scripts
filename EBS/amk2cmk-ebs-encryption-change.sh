#!/bin/bash
set -Eeuo pipefail

# NOTE: This script requires Bash 4.x or newer.
# This is sample command when ran in macbook terminal:
# /opt/homebrew/bin/bash <script-name> <instance-id>
# jaycpantinople@CB-L097 amk2cmk %  /opt/homebrew/bin/bash ./amk2cmk-ebs-encryption-change.sh i-001234qazwsxdfg

INSTANCE_ID="$1"
REGION="<aws-region-code>"
NEW_KMS_KEY_ID="arn:aws:kms:eu-west-2:<aws-accountID>:key/<customer-managed-kms-keyid>"

echo $INSTANCE_ID

# === Logging config block ====
TS=$(date '+%y%m%d%H%M%S')
LOG_FILE="${INSTANCE_ID}-_amk2cmk_${TS}.log"

log() {
  echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE"
}
# =============================

# === Error handling block ====
handle_error() {
  local exit_code=$?
  local line_no=$1
  local cmd="$BASH_COMMAND"

  log "ERROR: Command failed"
  log "  Line: $line_no"
  log "  Exit Code: $exit_code"
  log "  Command: $cmd"

  exit $exit_code
}

trap 'handle_error $LINENO' ERR
# ===============================

log "START: AMI → CMK Migration"

log "STEP 1: Stopping instance..."

STATE=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --region $REGION \
  --query "Reservations[0].Instances[0].State.Name" \
  --output text)

log "Current instance state: $STATE"

if [[ "$STATE" == "running" ]]; then
  log "Stopping instance..."

  aws ec2 stop-instances \
    --instance-ids $INSTANCE_ID \
    --region $REGION

  log "Waiting for instance to stop..."

  aws ec2 wait instance-stopped \
    --instance-ids $INSTANCE_ID \
    --region $REGION

else
  log "Instance is already in Stopped state. Skipping stop step."
fi


log "STEP 2: Creating AMI..."

log "PRE-STEP: Capturing original volume attributes..."

declare -A VOL_ID_MAP
declare -A VOL_TYPE_MAP
declare -A VOL_IOPS_MAP
declare -A VOL_TP_MAP

# Get device → volumeId mapping
ORIGINAL_MAPPINGS=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[*].[DeviceName,Ebs.VolumeId]' \
  --output text)

while read -r DEVICE VOL_ID; do
  [[ -z "$DEVICE" || -z "$VOL_ID" ]] && continue

  # Get performance config (text is fine here)
  read TYPE IOPS TP <<< $(aws ec2 describe-volumes \
    --volume-ids "$VOL_ID" \
    --region "$REGION" \
    --query 'Volumes[0].[VolumeType,Iops,Throughput]' \
    --output text)

  log "Original: $DEVICE → $VOL_ID ($TYPE, IOPS=$IOPS, TP=$TP)"

  VOL_ID_MAP["$DEVICE"]="$VOL_ID"
  VOL_TYPE_MAP["$DEVICE"]="$TYPE"
  VOL_IOPS_MAP["$DEVICE"]="$IOPS"
  VOL_TP_MAP["$DEVICE"]="$TP"

done <<< "$ORIGINAL_MAPPINGS"

AMI_ID=$(aws ec2 create-image \
  --instance-id "$INSTANCE_ID" \
  --name "cmk-migration-$(date +%s)" \
  --region "$REGION" \
  --query 'ImageId' \
  --output text)

log "AMI_ID: $AMI_ID"


log "STEP 3: Waiting for AMI..."

while true; do
  AMI_STATE=$(aws ec2 describe-images \
    --image-ids "$AMI_ID" \
    --region "$REGION" \
    --query 'Images[0].State' \
    --output text)

  log "  AMI state: $AMI_STATE"

  [[ "$AMI_STATE" == "available" ]] && break

  if [[ "$AMI_STATE" == "failed" ]]; then
    log "ERROR: AMI $AMI_ID entered failed state. Aborting."
    exit 1
  fi

  sleep 30
done

log "AMI is now in 'available' state."


log "STEP 4: Fetch mappings..."

MAPPINGS=$(aws ec2 describe-images \
  --image-ids "$AMI_ID" \
  --region "$REGION" \
  --query 'Images[0].BlockDeviceMappings[?Ebs.SnapshotId!=`null`].[DeviceName,Ebs.SnapshotId]' \
  --output text)

log "Mappings:"
log "$MAPPINGS"


log "STEP 5: Wait snapshots..."

while read -r DEVICE SNAP; do
  [[ -z "$DEVICE" || -z "$SNAP" ]] && continue

  log "Waiting for snapshot $SNAP ($DEVICE)..."

  while true; do
    read STATUS PROGRESS <<< $(aws ec2 describe-snapshots \
      --snapshot-ids "$SNAP" \
      --region "$REGION" \
      --query "Snapshots[0].[State,Progress]" \
      --output text)

    log "  $SNAP → $STATUS $PROGRESS"

    [[ "$STATUS" == "completed" ]] && break
    sleep 30
  done
done <<< "$MAPPINGS"

log "All snapshots completed."


log "STEP 6: Get AZ..."

AZ=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' \
  --output text)

log "AZ: $AZ"


log "STEP 7: Create volumes..."

declare -A NEW_VOLUMES

while read -r DEVICE SNAP; do
  [[ -z "$DEVICE" || -z "$SNAP" ]] && continue

  if [[ -z "${VOL_TYPE_MAP[$DEVICE]+x}" ]]; then
    log "WARNING: No original config for $DEVICE. Skipping..."
    continue
  fi

  TYPE="${VOL_TYPE_MAP[$DEVICE]}"
  IOPS="${VOL_IOPS_MAP[$DEVICE]}"
  TP="${VOL_TP_MAP[$DEVICE]}"
  ORIG_VOL_ID="${VOL_ID_MAP[$DEVICE]}"

  log "Creating volume for $DEVICE from $SNAP"
  log "Using config: type=$TYPE iops=$IOPS throughput=$TP"

  CREATE_ARGS=(
    --snapshot-id "$SNAP"
    --availability-zone "$AZ"
    --encrypted
    --kms-key-id "$NEW_KMS_KEY_ID"
    --volume-type "$TYPE"
    --region "$REGION"
  )

  if [[ "$TYPE" == "gp3" ]]; then
    [[ "$IOPS" != "None" ]] && CREATE_ARGS+=(--iops "$IOPS")
    [[ "$TP" != "None" ]] && CREATE_ARGS+=(--throughput "$TP")
  fi

  NEW_VOL_ID=$(aws ec2 create-volume "${CREATE_ARGS[@]}" \
    --query 'VolumeId' \
    --output text)

  log "  Created volume: $NEW_VOL_ID"

  # Re-fetch tags directly from the original volume
  # Avoids bash associative array JSON corruption
  TAGS_JSON=$(aws ec2 describe-volumes \
    --volume-ids "$ORIG_VOL_ID" \
    --region "$REGION" \
    --query 'Volumes[0].Tags' \
    --output json)

  # Filter out aws: reserved tags, handle null safely
  FILTERED_TAGS=$(echo "$TAGS_JSON" | jq 'if . == null then [] else [.[] | select(.Key | startswith("aws:") | not)] end')

  if [[ "$FILTERED_TAGS" != "[]" ]]; then
    log "Applying tags to $NEW_VOL_ID"

    TAG_FILE=$(mktemp)
    echo "$FILTERED_TAGS" > "$TAG_FILE"

    aws ec2 create-tags \
      --resources "$NEW_VOL_ID" \
      --region "$REGION" \
      --tags "file://$TAG_FILE"

    rm -f "$TAG_FILE"
  fi

  NEW_VOLUMES["$DEVICE"]="$NEW_VOL_ID"

done <<< "$MAPPINGS"

log "STEP 8: Wait volumes..."

for VOL in "${NEW_VOLUMES[@]}"; do
  log "Waiting for volume $VOL"
  aws ec2 wait volume-available \
    --volume-ids "$VOL" \
    --region "$REGION"
done

log "All new volumes ready."


log "STEP 9: Detach old volumes..."

OLD_MAPPINGS=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[*].[DeviceName,Ebs.VolumeId]' \
  --output text)

while read -r DEVICE VOL; do
  [[ -z "$DEVICE" || -z "$VOL" ]] && continue

  log "Detaching volume $VOL ($DEVICE)"

  aws ec2 detach-volume \
    --volume-id "$VOL" \
    --region "$REGION"
done <<< "$OLD_MAPPINGS"

log "Waiting for old volumes to detach..."

while read -r DEVICE VOL; do
  [[ -z "$DEVICE" || -z "$VOL" ]] && continue

  aws ec2 wait volume-available \
    --volume-ids "$VOL" \
    --region "$REGION"

  log "Detached: $VOL"
done <<< "$OLD_MAPPINGS"


log "STEP 10: Attach new volumes..."

for DEVICE in "${!NEW_VOLUMES[@]}"; do
  VOL="${NEW_VOLUMES[$DEVICE]}"

  log "Attaching $VOL to $DEVICE"

  aws ec2 attach-volume \
    --volume-id "$VOL" \
    --instance-id "$INSTANCE_ID" \
    --device "$DEVICE" \
    --region "$REGION"

  log "Setting DeleteOnTermination=true for $VOL"

  aws ec2 modify-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --region "$REGION" \
    --block-device-mappings "DeviceName=$DEVICE,Ebs={DeleteOnTermination=true}"
done


log "STEP 11: Starting instance..."

aws ec2 start-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION"

log "===== SUCCESS: Migration completed ====="
