#!/bin/bash
# Reset expired passwords for all users in /home/

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root (or with sudo)."
  exit 1
fi

# Users to skip
SKIP_USERS="ejabberd haproxy binu moya moyaadmin"

for user_dir in /home/*/; do
  username=$(basename "$user_dir")

  # Skip excluded users
  if echo "$SKIP_USERS" | grep -qw "$username"; then
    echo "Skipping user: $username"
    continue
  fi

  echo "----------------------------------------"
  echo "Processing user: $username"

  # Generate a random 32-character password
  password=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)

  # Set the new password
  echo "$username:$password" | chpasswd
  echo "Password set for $username"

  # Force password expiration so user must change it on next login
  passwd -e "$username"
  echo "Password expired for $username (must change on next login)"

  # Log the generated password
  echo "Temporary password for $username: $password"
  echo "----------------------------------------"
done

echo ""
echo "Done. All users have been processed."
