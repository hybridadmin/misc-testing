# add_secondary_ips_to_netplan

Persist secondary IPs (assigned at runtime via `ip addr add`) into Netplan so they survive a reboot.

## Problem

On EC2 (or similar environments), secondary private IPs attached to an ENI appear in `ip addr show` but are not written to Netplan by default. After a reboot they are gone unless something re-adds them.

## What the script does

1. Parses `ip addr show <interface>` for all IPs flagged `secondary`.
2. Creates a timestamped backup of the Netplan config.
3. Adds the secondary IPs to the `addresses:` block under the target interface, skipping any that are already present.
4. Validates with `netplan generate` and applies with `netplan apply`.

## Usage

```bash
sudo ./add_secondary_ips_to_netplan.sh          # defaults to ens5
sudo ./add_secondary_ips_to_netplan.sh eth0      # specify a different interface
```

## Configuration

Edit the variables at the top of the script if your setup differs:

| Variable      | Default                            | Description                  |
|---------------|------------------------------------|------------------------------|
| `INTERFACE`   | `ens5` (or first argument)         | Network interface to inspect |
| `NETPLAN_CFG` | `/etc/netplan/50-cloud-init.yaml`  | Path to the Netplan config   |

## Example

Given this runtime state:

```
2: ens5: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9001 qdisc mq state UP group default qlen 1000
    inet 10.103.23.34/20 metric 100 brd 10.103.31.255 scope global dynamic ens5
    inet 10.103.18.141/20 scope global secondary ens5
    inet 10.103.23.224/20 scope global secondary ens5
    inet 10.103.24.223/20 scope global secondary ens5
```

The script adds the three secondary IPs to Netplan:

```yaml
network:
  ethernets:
    ens5:
      dhcp4: true
      addresses:
        - 10.103.18.141/20
        - 10.103.23.224/20
        - 10.103.24.223/20
```

The primary IP (`10.103.23.34`) remains managed by DHCP and is not duplicated.

## Requirements

- Ubuntu with Netplan (18.04+)
- Bash 4+ (for `mapfile`)
- Root / sudo privileges
- `grep` with `-P` (Perl regex) support (GNU grep)

## Restoring from backup

Every run creates a backup at `<config>.bak.<unix_timestamp>`. To restore:

```bash
sudo cp /etc/netplan/50-cloud-init.yaml.bak.1234567890 /etc/netplan/50-cloud-init.yaml
sudo netplan apply
```
