#!/usr/bin/env bash
set -euo pipefail

INTERFACE="${1:-ens5}"
NETPLAN_CFG="/etc/netplan/50-cloud-init.yaml"

# Collect secondary IPs from the running config
mapfile -t SECONDARY_IPS < <(
  ip addr show "$INTERFACE" \
    | grep -oP 'inet \K[0-9./]+(?=.*secondary)'
)

if [[ ${#SECONDARY_IPS[@]} -eq 0 ]]; then
  echo "No secondary IPs found on $INTERFACE"
  exit 0
fi

echo "Found ${#SECONDARY_IPS[@]} secondary IP(s) on $INTERFACE:"
printf '  %s\n' "${SECONDARY_IPS[@]}"

# Back up the current netplan config
cp "$NETPLAN_CFG" "${NETPLAN_CFG}.bak.$(date +%s)"

# Build the YAML addresses block
ADDR_BLOCK=""
for ip in "${SECONDARY_IPS[@]}"; do
  ADDR_BLOCK+="        - ${ip}\n"
done

# Check if an 'addresses:' key already exists under the interface
if grep -qP "^\s+${INTERFACE}:" "$NETPLAN_CFG"; then
  if grep -A 50 "^\s\+${INTERFACE}:" "$NETPLAN_CFG" | grep -qP '^\s+addresses:'; then
    echo "addresses: block already exists — appending missing IPs"
    for ip in "${SECONDARY_IPS[@]}"; do
      if ! grep -qF "$ip" "$NETPLAN_CFG"; then
        # Insert the new IP right after the 'addresses:' line under the interface
        sed -i "/^\(\s*\)addresses:/a\\        - ${ip}" "$NETPLAN_CFG"
        echo "  added $ip"
      else
        echo "  $ip already present, skipping"
      fi
    done
  else
    echo "Adding addresses: block under $INTERFACE"
    sed -i "/^\(\s*\)${INTERFACE}:/a\\      addresses:\n${ADDR_BLOCK%\\n}" "$NETPLAN_CFG"
  fi
else
  echo "ERROR: Interface $INTERFACE not found in $NETPLAN_CFG"
  exit 1
fi

echo ""
echo "Updated netplan config:"
cat "$NETPLAN_CFG"

echo ""
echo "Validating and applying..."
netplan generate
netplan apply

echo "Done."
