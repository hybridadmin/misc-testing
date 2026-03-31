# Icinga2 NRPE SSL Handshake Failure

## Problem

NRPE daemon on a remote server fails SSL handshake with the Icinga2 monitoring server.

**Remote server (NRPE) logs:**

```
Error: (!log_opts) Could not complete SSL handshake with 18.202.97.153: 1
```

**Icinga2 server logs:**

```
Error: (!log_opts) Could not complete SSL handshake with 13.244.154.185: sslv3 alert handshake failure
```

The `sslv3 alert handshake failure` message means the two sides cannot agree on a common cipher suite or TLS version.

## Common Causes

- NRPE is configured with ADH (Anonymous Diffie-Hellman) ciphers but `check_nrpe` expects certificate-based TLS (or vice versa)
- OpenSSL version mismatch between the two hosts (e.g. OpenSSL 3.x vs 1.x)
- Expired or missing NRPE SSL certificates

## Diagnosis

### 1. Check NRPE SSL config on the remote server

```bash
grep -i ssl /etc/nagios/nrpe.cfg
```

Look for `ssl_version`, `ssl_use_adh`, `ssl_cipher_list`, `ssl_cert_file`, and `ssl_privatekey_file`.

### 2. Check OpenSSL versions on both sides

```bash
# On the remote server
openssl version

# On the Icinga2 server
openssl version
```

### 3. Test the connection from the Icinga2 server

```bash
/usr/lib/nagios/plugins/check_nrpe -H <remote_ip> -t 30 -2
```

The `-2` flag forces TLSv1.2+ which often resolves the mismatch.

### 4. Debug cipher negotiation

```bash
openssl s_client -connect <remote_ip>:5666 -tls1_2
```

This shows exactly what the NRPE daemon presents (certificate, cipher, TLS version) and where negotiation breaks down.

## Fix

### Option A: Align TLS settings (most common fix)

Edit `/etc/nagios/nrpe.cfg` on the remote server:

```ini
# Disable ADH
ssl_use_adh=0

# Force TLSv1.2 or higher
ssl_version=TLSv1.2+

# Use a broad but secure cipher list
ssl_cipher_list=ALL:!MD5:!RC4:!ADH:!DES:!3DES
```

Then restart:

```bash
systemctl restart nagios-nrpe-server
```

### Option B: Enable ADH if check_nrpe expects it

In `/etc/nagios/nrpe.cfg`:

```ini
ssl_use_adh=1
```

And pass `-2 -a ADH` to `check_nrpe` on the Icinga side.

**Note:** Disabling ADH and using certificate-based TLS (Option A) is the preferred approach.

### Option C: Regenerate NRPE SSL certificates

If certificates are expired or missing:

```bash
openssl x509 -in /etc/ssl/certs/nrpe.crt -noout -dates 2>/dev/null
```

Regenerate if expired and reference them in `nrpe.cfg`.

## Additional Note

The following warning is harmless and can be ignored:

```
socket: Address family not supported by protocol
```

This means IPv6 is disabled on the host but NRPE tried to listen on `::`. It falls back to IPv4 (0.0.0.0:5666) successfully. Suppress it by setting `server_address=0.0.0.0` in `nrpe.cfg`.
