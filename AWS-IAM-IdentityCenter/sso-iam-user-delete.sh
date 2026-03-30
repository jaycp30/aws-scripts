#!/bin/bash

IDENTITY_STORE_ID="d-9c677da824"
INPUT_FILE="users.txt"

while read -r USERNAME; do
  echo "Processing user: $USERNAME"

  # Step 1: Get UserId
  USER_ID=$(aws identitystore list-users \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --filters AttributePath=UserName,AttributeValue="$USERNAME" \
    --query 'Users[0].UserId' \
    --output text)

  if [[ "$USER_ID" == "None" || -z "$USER_ID" ]]; then
    echo "User not found: $USERNAME"
    continue
  fi

  echo "UserId: $USER_ID"

  # Step 2: List group memberships
  MEMBERSHIPS=$(aws identitystore list-group-memberships-for-member \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --member-id UserId="$USER_ID" \
    --query 'GroupMemberships[].MembershipId' \
    --output text)

  # Step 3: Remove from groups
  if [[ -n "$MEMBERSHIPS" ]]; then
    for MEMBERSHIP_ID in $MEMBERSHIPS; do
      echo "Removing membership: $MEMBERSHIP_ID"

      aws identitystore delete-group-membership \
        --identity-store-id "$IDENTITY_STORE_ID" \
        --membership-id "$MEMBERSHIP_ID"
    done
  else
    echo "No group memberships found"
  fi

  # Step 4: Delete user
  echo "Deleting user: $USERNAME"
  aws identitystore delete-user \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --user-id "$USER_ID"

  echo "Done: $USERNAME"

done < "$INPUT_FILE"