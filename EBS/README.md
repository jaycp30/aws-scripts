# EBS Encryption Migration: AWS-Managed Key to Customer-Managed Key

A Bash script that migrates all EBS volumes attached to an EC2 instance from an AWS-managed KMS key (AMK) to a Customer-Managed KMS key (CMK). It preserves the original volume type, IOPS, throughput, and user tags throughout the migration.

## Why this exists

When you create an EBS volume with default encryption, AWS uses the account's AWS-managed key (`aws/ebs`). Many organizations later decide they need a Customer-Managed Key instead, usually for compliance, cross-account sharing, or stricter key rotation and access control. You cannot re-encrypt a volume in place. The only supported path is: snapshot the volume, create a new volume from that snapshot using the new key, then swap it in. This script automates that swap end to end.

## What it does

Given an EC2 instance ID, the script:

1. Stops the instance if it is running.
2. Captures the current block device layout, including volume type, IOPS, throughput, and tags.
3. Creates an AMI of the instance, which generates EBS snapshots.
4. Waits for the AMI and all snapshots to reach `available` / `completed`.
5. Creates new encrypted volumes from those snapshots in the same Availability Zone, using the specified CMK, and preserving the original performance configuration.
6. Copies user tags to the new volumes. AWS-reserved tags (anything starting with `aws:`) are filtered out because AWS rejects them on `create-tags`.
7. Detaches the old volumes from the instance.
8. Attaches the new volumes to the same device names.
9. Sets `DeleteOnTermination=true` on each new volume.
10. Starts the instance.

All actions are logged to a timestamped file in the working directory.

## Prerequisites

- **Bash 4.0 or newer.** The script uses associative arrays (`declare -A`), which are not available in Bash 3.2. macOS ships with Bash 3.2 by default, so on a Mac you need to install a newer Bash via Homebrew and run the script with it explicitly.
- **AWS CLI v2**, configured with credentials that can:
  - Describe, stop, and start EC2 instances
  - Create AMIs and describe images and snapshots
  - Create, describe, attach, and detach EBS volumes
  - Create tags on volumes
  - Modify instance block device attributes
  - Use the target KMS key (`kms:CreateGrant`, `kms:Encrypt`, `kms:Decrypt`, `kms:GenerateDataKey*`, `kms:DescribeKey`)
- **jq** for JSON filtering of tags.
- The target CMK must exist in the same region as the instance and be accessible from the caller's IAM identity.

## Configuration

Two values are hard-coded near the top of the script and must be edited before use:

```bash
REGION="<aws-region-code>"
NEW_KMS_KEY_ID="arn:aws:kms:eu-west-2:<aws-accountID>:key/<customer-managed-kms-keyid>"
```

Replace these with your actual region and CMK ARN. There is no argument or environment variable override in this version.

## Usage

```bash
/opt/homebrew/bin/bash ./amk2cmk-ebs-encryption-change.sh <instance-id>
```

Example:

```bash
/opt/homebrew/bin/bash ./amk2cmk-ebs-encryption-change.sh i-001234qazwsxdfg
```

A log file named `<instance-id>-_amk2cmk_<timestamp>.log` is written in the current directory.

## Important caveats and limitations

Read these before running against anything you care about.

### 1. No automatic rollback

If the script fails partway through (for example, an `attach-volume` call fails after old volumes are already detached), the instance is left in a mixed state: old volumes detached, some new volumes attached, some not. Recovery is manual. The log file contains enough detail to reconstruct state, but you should be ready to intervene.

### 2. IOPS and throughput are only passed for gp3

The script only forwards IOPS and throughput values when the source volume type is `gp3`. If the instance has `io1`, `io2`, or `io2 Block Express` volumes, IOPS is required at creation time and will not be included, and the `create-volume` call will fail. If you know your fleet uses these types, extend the `if [[ "$TYPE" == "gp3" ]]` block accordingly. `gp2`, `st1`, `sc1`, and `standard` do not take IOPS arguments, so they are unaffected.

### 3. DeleteOnTermination is forced to true

Step 10 unconditionally sets `DeleteOnTermination=true` on every new volume. If the original volume had `DeleteOnTermination=false` (common on data volumes you want to survive instance termination), this behavior is silently changed. Adjust if your data volumes need to persist.

### 4. Old volumes, AMI, and snapshots are not cleaned up

After a successful migration, the old AMK-encrypted volumes remain detached in your account, and the AMI plus its snapshots remain in place. This is intentional. They act as a rollback artifact if something goes wrong after the instance starts. It also means you will continue to pay for them until you clean up. A reasonable pattern is to leave them for a defined retention window (say, 7 or 14 days) and then delete them.

### 5. Not idempotent, no dry-run

Re-running the script on an instance that is already mid-migration or partially migrated will create a new AMI and another set of volumes. It does not check whether the instance is already on a CMK. Run it once per instance and confirm the outcome before re-running.

### 6. Instance downtime

The instance is stopped for the entire duration of the migration. For a small root volume this is a few minutes; for large or many volumes it can be significantly longer because AMI creation waits for all snapshots to complete. Plan a maintenance window.

### 7. Placeholder values must be replaced

`REGION` and `NEW_KMS_KEY_ID` are placeholders in the committed script. Replace them before running. Do not commit real account IDs or key IDs back to a public repository.

### 8. Single instance only

The script processes one instance per invocation. For fleet-wide migrations, wrap it in an outer loop and consider adding concurrency limits so you do not stop too many instances at once.

## File output

- `<instance-id>-v8_amk2cmk_<timestamp>.log`: full timestamped log of the run, including every AWS CLI interaction the script performs.

## Verification after running

After the script reports success, confirm:

1. The instance is in the `running` state.
2. Each attached volume reports `KmsKeyId` equal to your CMK ARN (`aws ec2 describe-volumes`).
3. Application-level health checks pass.
4. Tag set on the new volumes matches expectations.

Once verified, you can delete the old volumes, the AMI, and its snapshots.

## License

Internal / client-specific. Adjust before publishing publicly.
