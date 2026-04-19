import boto3
import csv
from datetime import datetime

REGION = "eu-west-2"

def main():
    sso_admin = boto3.client("sso-admin", region_name=REGION)
    identitystore = boto3.client("identitystore", region_name=REGION)

    print("Fetching SSO instance...")
    instances = sso_admin.list_instances()["Instances"]
    if not instances:
        raise Exception("No SSO instances found")

    instance_arn = instances[0]["InstanceArn"]
    identity_store_id = instances[0]["IdentityStoreId"]

    print(f"Instance ARN: {instance_arn}")
    print(f"Identity Store ID: {identity_store_id}")

    output_file = f"PermissionSet_Report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"
    print(f"Output file: {output_file}")

    with open(output_file, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow([
            "GroupName",
            "GroupId",
            "AccountId",
            "PermissionSetName",
            "PermissionSetArn",
            "ManagedPolicies",
            "HasInlinePolicy"
        ])

        # Get all groups
        paginator = identitystore.get_paginator("list_groups")

        for page in paginator.paginate(IdentityStoreId=identity_store_id):
            for group in page["Groups"]:

                group_id = group["GroupId"]
                group_name = group.get("DisplayName", "Unknown")

                print(f"Processing group: {group_name}")

                # List permission sets
                ps_paginator = sso_admin.get_paginator("list_permission_sets")

                for ps_page in ps_paginator.paginate(InstanceArn=instance_arn):
                    for ps_arn in ps_page["PermissionSets"]:

                        # Get accounts where permission set is provisioned
                        acc_paginator = sso_admin.get_paginator(
                            "list_accounts_for_provisioned_permission_set"
                        )

                        for acc_page in acc_paginator.paginate(
                            InstanceArn=instance_arn,
                            PermissionSetArn=ps_arn
                        ):
                            for account_id in acc_page["AccountIds"]:

                                # Get assignments
                                assign_paginator = sso_admin.get_paginator("list_account_assignments")

                                for assign_page in assign_paginator.paginate(
                                    InstanceArn=instance_arn,
                                    AccountId=account_id,
                                    PermissionSetArn=ps_arn
                                ):
                                    for assignment in assign_page["AccountAssignments"]:

                                        if (
                                            assignment["PrincipalType"] == "GROUP"
                                            and assignment["PrincipalId"] == group_id
                                        ):

                                            # Describe permission set
                                            ps_desc = sso_admin.describe_permission_set(
                                                InstanceArn=instance_arn,
                                                PermissionSetArn=ps_arn
                                            )["PermissionSet"]

                                            ps_name = ps_desc["Name"]

                                            # Managed policies
                                            managed_policies = sso_admin.list_managed_policies_in_permission_set(
                                                InstanceArn=instance_arn,
                                                PermissionSetArn=ps_arn
                                            )["AttachedManagedPolicies"]

                                            managed_policy_names = [
                                                p["Name"] for p in managed_policies
                                            ]

                                            # Inline policy
                                            inline_policy = sso_admin.get_inline_policy_for_permission_set(
                                                InstanceArn=instance_arn,
                                                PermissionSetArn=ps_arn
                                            )["InlinePolicy"]

                                            has_inline = "Yes" if inline_policy else "No"

                                            writer.writerow([
                                                group_name,
                                                group_id,
                                                account_id,
                                                ps_name,
                                                ps_arn,
                                                ";".join(managed_policy_names),
                                                has_inline
                                            ])

    print("Done.")

if __name__ == "__main__":
    main()