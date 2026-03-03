
## Template network config

```bash
export IP_RANGE="10.12.0"
j2 -e START=100 -e END=114 01-netplan.yml.j2
```

## Apply config

```bash
netplan apply
```
