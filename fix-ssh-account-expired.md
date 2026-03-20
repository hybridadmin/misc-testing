# Fix: SSH Account Expired

## Error

```
Authorized uses only. All activity may be monitored and reported.
Your account has expired; please contact your system administrator.
Connection closed by 52.30.5.28 port 22
```

## 1. Contact your system administrator (most common fix)

This is what the message explicitly tells you to do. The admin needs to:

- Extend your account expiration date
- On Linux, they would run something like:
  ```bash
  sudo chage -E -1 <username>    # remove expiration
  # or
  sudo chage -E 2027-01-01 <username>  # set new expiration date
  ```

## 2. If you ARE the system administrator

Check and fix the account expiration:

```bash
# Check account expiration info (run on the server, not via SSH)
sudo chage -l <username>

# Remove the expiration entirely
sudo chage -E -1 <username>

# Or check if the password expired (different from account expiry)
sudo passwd -S <username>

# Reset password expiration if needed
sudo passwd -e <username>
```

## 3. If it's a password expiration (not account)

Sometimes "account expired" actually means the password expired. The admin can:

```bash
sudo passwd <username>          # reset the password
sudo chage -M 99999 <username>  # set max password age to effectively never
```

## Key distinction

- **Account expired** (`chage -E`): The account itself has a hard expiration date. You cannot log in at all.
- **Password expired** (`chage -M`): The password needs to be changed. Some SSH configs reject expired passwords outright instead of prompting for a change.

## Bottom line

If you don't have physical/console access to the server, you need to contact whoever manages it. There's no client-side fix for this -- the server is rejecting your login before authentication even completes.
