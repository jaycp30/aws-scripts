import boto3
import csv
from datetime import datetime

# ==============================
# edit this block as necessary
# ==============================

REGION = "eu-west-2"
IDENTITY_STORE_ID = "d-12345abcde"
CUSTOMER_NAME = "Org-Name"

# ==============================
# MAIN EXPORT LOGIC
# ==============================

def main():
    # UTC timestamp for audit consistency
    from datetime import datetime, timezone

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")

    # New filename format
    output_file = f"{CUSTOMER_NAME}_AWS-IAMIdentityCenter_report_{timestamp}.csv"

    client = boto3.client("identitystore", region_name=REGION)

    print(f"Connecting to Identity Store in {REGION}...")
    print("Starting export...")
    print(f"Output file will be: {output_file}")

    with open(output_file, mode="w", newline="", encoding="utf-8") as file:
        writer = csv.writer(file)

        writer.writerow([
            "UserId",
            "UserName",
            "DisplayName",
            "Email",
            "UserStatus",
            "Groups",
            "CreatedAt",
            "CreatedBy",
            "UpdatedAt",
            "UpdatedBy"
        ])

        paginator = client.get_paginator("list_users")

        for page in paginator.paginate(IdentityStoreId=IDENTITY_STORE_ID):
            for user in page.get("Users", []):

                user_id = user.get("UserId", "")
                username = user.get("UserName", "")
                display_name = user.get("DisplayName", "")
                user_status = user.get("UserStatus", "")

                email = ""
                if user.get("Emails"):
                    email = user["Emails"][0].get("Value", "")

                created_at = user.get("CreatedDate", "")
                created_by = user.get("CreatedBy", "")
                updated_at = user.get("LastModifiedDate", "")
                updated_by = user.get("LastModifiedBy", "")

                memberships = client.list_group_memberships_for_member(
                    IdentityStoreId=IDENTITY_STORE_ID,
                    MemberId={"UserId": user_id}
                )

                group_names = []

                for membership in memberships.get("GroupMemberships", []):
                    group_id = membership["GroupId"]

                    group = client.describe_group(
                        IdentityStoreId=IDENTITY_STORE_ID,
                        GroupId=group_id
                    )

                    group_names.append(group.get("DisplayName", ""))

                groups_joined = "; ".join(sorted(group_names))

                writer.writerow([
                    user_id,
                    username,
                    display_name,
                    email,
                    user_status,
                    groups_joined,
                    created_at,
                    created_by,
                    updated_at,
                    updated_by
                ])

    print("\nExport completed successfully.")
    print(f"Output file created: {output_file}")


if __name__ == "__main__":
    main()
