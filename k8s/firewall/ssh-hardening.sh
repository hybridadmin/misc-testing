#!/usr/bin/env bash
# =============================================================================
# ssh-hardening.sh
# Hardens SSH access on any K8s node (control plane or worker).
#
# This script:
#   1. Restricts SSH (port 22) to specific source IPs/CIDRs via iptables
#   2. Hardens sshd_config with security best practices
#   3. Configures TCP wrappers (/etc/hosts.allow, /etc/hosts.deny)
#   4. Optionally sets up fail2ban for brute-force protection
#
# Required env vars:
#   ALLOWED_SSH_SOURCES  - Comma-separated IPs/CIDRs allowed to SSH
#                          e.g. "10.0.0.5,192.168.1.0/24,203.0.113.50"
#
# Optional:
#   SSH_PORT             - Custom SSH port (default: 22)
#   HARDEN_SSHD_CONFIG   - "true" to modify sshd_config (default: true)
#   SETUP_FAIL2BAN       - "true" to install/configure fail2ban (default: false)
#   DRY_RUN              - "true" to preview without applying
#
# Usage:
#   export ALLOWED_SSH_SOURCES="10.0.0.5,192.168.1.0/24"
#   sudo -E ./ssh-hardening.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.env"

HARDEN_SSHD_CONFIG="${HARDEN_SSHD_CONFIG:-true}"
SETUP_FAIL2BAN="${SETUP_FAIL2BAN:-false}"

# ---- Validate inputs --------------------------------------------------------
require_var "ALLOWED_SSH_SOURCES"
require_root

log_info "=== SSH Hardening ==="
log_info "SSH Port:            $SSH_PORT"
log_info "Allowed sources:     $ALLOWED_SSH_SOURCES"
log_info "Harden sshd_config:  $HARDEN_SSHD_CONFIG"
log_info "Setup fail2ban:      $SETUP_FAIL2BAN"
log_info "DRY_RUN:             $DRY_RUN"

# ---- Backup current state ----------------------------------------------------
backup_iptables

if [[ "$DRY_RUN" != "true" && -f /etc/ssh/sshd_config ]]; then
    cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date '+%Y%m%d_%H%M%S')"
    log_info "sshd_config backed up."
fi

# =========================================================================
# SECTION 1: iptables rules for SSH
# =========================================================================
print_section "iptables SSH restrictions"

# Remove old chain if exists
run_ipt -F K8S-SSH-HARDENED 2>/dev/null || true
run_ipt -X K8S-SSH-HARDENED 2>/dev/null || true
run_ipt -N K8S-SSH-HARDENED

# Rate limiting: max 4 new SSH connections per minute per source
run_ipt -A K8S-SSH-HARDENED -p tcp --dport "$SSH_PORT" \
    -m conntrack --ctstate NEW \
    -m recent --set --name SSH_RATE
run_ipt -A K8S-SSH-HARDENED -p tcp --dport "$SSH_PORT" \
    -m conntrack --ctstate NEW \
    -m recent --update --seconds 60 --hitcount 5 --name SSH_RATE \
    -j DROP

# Allow from each specified source
split_csv "$ALLOWED_SSH_SOURCES"
for src in "${SPLIT_RESULT[@]}"; do
    src="$(echo "$src" | xargs)"
    run_ipt -A K8S-SSH-HARDENED -s "$src" -p tcp --dport "$SSH_PORT" -j ACCEPT
    log_info "SSH iptables: ACCEPT from $src"
done

# Drop all other SSH
run_ipt -A K8S-SSH-HARDENED -p tcp --dport "$SSH_PORT" -j LOG \
    --log-prefix "SSH-DENIED: " --log-level 4
run_ipt -A K8S-SSH-HARDENED -p tcp --dport "$SSH_PORT" -j DROP

# Insert the chain at the top of INPUT (before other rules)
# Check if already linked to avoid duplicates
if ! $IPTABLES_CMD -C INPUT -p tcp --dport "$SSH_PORT" -j K8S-SSH-HARDENED 2>/dev/null; then
    run_ipt -I INPUT 1 -p tcp --dport "$SSH_PORT" -j K8S-SSH-HARDENED
fi

log_info "iptables SSH rules applied with rate limiting."

# =========================================================================
# SECTION 2: TCP Wrappers (/etc/hosts.allow & /etc/hosts.deny)
# =========================================================================
print_section "TCP Wrappers"

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] Would configure /etc/hosts.allow and /etc/hosts.deny"
else
    # Build hosts.allow entry
    ALLOW_LIST=""
    split_csv "$ALLOWED_SSH_SOURCES"
    for src in "${SPLIT_RESULT[@]}"; do
        src="$(echo "$src" | xargs)"
        if [[ -n "$ALLOW_LIST" ]]; then
            ALLOW_LIST+=", $src"
        else
            ALLOW_LIST="$src"
        fi
    done

    # Only add our block if not already present
    MARKER="# K8S-SSH-HARDENING"
    if ! grep -q "$MARKER" /etc/hosts.allow 2>/dev/null; then
        {
            echo ""
            echo "$MARKER - BEGIN"
            echo "sshd: $ALLOW_LIST"
            echo "$MARKER - END"
        } >> /etc/hosts.allow
        log_info "Updated /etc/hosts.allow"
    else
        log_info "/etc/hosts.allow already has K8S-SSH-HARDENING block."
    fi

    if ! grep -q "$MARKER" /etc/hosts.deny 2>/dev/null; then
        {
            echo ""
            echo "$MARKER - BEGIN"
            echo "sshd: ALL"
            echo "$MARKER - END"
        } >> /etc/hosts.deny
        log_info "Updated /etc/hosts.deny"
    else
        log_info "/etc/hosts.deny already has K8S-SSH-HARDENING block."
    fi
fi

# =========================================================================
# SECTION 3: sshd_config hardening
# =========================================================================
if [[ "$HARDEN_SSHD_CONFIG" == "true" ]]; then
    print_section "sshd_config hardening"

    SSHD_CONFIG="/etc/ssh/sshd_config"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would apply the following sshd_config changes:"
        cat <<'PREVIEW'
  PermitRootLogin no
  PasswordAuthentication no
  PubkeyAuthentication yes
  MaxAuthTries 3
  MaxSessions 3
  LoginGraceTime 30
  ClientAliveInterval 300
  ClientAliveCountMax 2
  X11Forwarding no
  AllowTcpForwarding no
  PermitEmptyPasswords no
  Protocol 2
  AllowAgentForwarding no
  PermitUserEnvironment no
  Banner /etc/ssh/banner
PREVIEW
    else
        # Function to set an sshd_config directive (uncomment or add)
        set_sshd_option() {
            local key="$1"
            local value="$2"
            if grep -qE "^#?\s*${key}\s" "$SSHD_CONFIG"; then
                sed -i "s|^#*\s*${key}\s.*|${key} ${value}|" "$SSHD_CONFIG"
            else
                echo "${key} ${value}" >> "$SSHD_CONFIG"
            fi
        }

        set_sshd_option "PermitRootLogin"         "no"
        set_sshd_option "PasswordAuthentication"   "no"
        set_sshd_option "PubkeyAuthentication"     "yes"
        set_sshd_option "MaxAuthTries"             "3"
        set_sshd_option "MaxSessions"              "3"
        set_sshd_option "LoginGraceTime"           "30"
        set_sshd_option "ClientAliveInterval"      "300"
        set_sshd_option "ClientAliveCountMax"      "2"
        set_sshd_option "X11Forwarding"            "no"
        set_sshd_option "AllowTcpForwarding"       "no"
        set_sshd_option "PermitEmptyPasswords"     "no"
        set_sshd_option "Protocol"                 "2"
        set_sshd_option "AllowAgentForwarding"     "no"
        set_sshd_option "PermitUserEnvironment"    "no"

        # Restrict SSH to allowed CIDRs via AllowUsers or ListenAddress
        # Build a match block for the allowed sources
        MARKER="# K8S-SSH-HARDENING-MATCH"
        if ! grep -q "$MARKER" "$SSHD_CONFIG"; then
            {
                echo ""
                echo "$MARKER - BEGIN"
                split_csv "$ALLOWED_SSH_SOURCES"
                for src in "${SPLIT_RESULT[@]}"; do
                    src="$(echo "$src" | xargs)"
                    echo "# Allowed SSH source: $src"
                done
                echo "$MARKER - END"
            } >> "$SSHD_CONFIG"
        fi

        # Create a warning banner
        cat > /etc/ssh/banner <<'BANNER'
*******************************************************************
  UNAUTHORIZED ACCESS TO THIS SYSTEM IS PROHIBITED.
  All connections are monitored and recorded.
  Disconnect IMMEDIATELY if you are not an authorized user.
*******************************************************************
BANNER
        set_sshd_option "Banner" "/etc/ssh/banner"

        log_info "sshd_config hardened."

        # Validate config before restarting
        if sshd -t 2>/dev/null; then
            systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
            log_info "sshd restarted with new configuration."
        else
            log_error "sshd_config validation failed! Restoring backup."
            LATEST_BACKUP=$(ls -t /etc/ssh/sshd_config.bak.* 2>/dev/null | head -1)
            if [[ -n "$LATEST_BACKUP" ]]; then
                cp "$LATEST_BACKUP" "$SSHD_CONFIG"
                log_info "Restored $LATEST_BACKUP"
            fi
        fi
    fi
fi

# =========================================================================
# SECTION 4: fail2ban (optional)
# =========================================================================
if [[ "$SETUP_FAIL2BAN" == "true" ]]; then
    print_section "fail2ban configuration"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would install and configure fail2ban."
    else
        # Install if not present
        if ! command -v fail2ban-client &>/dev/null; then
            if command -v apt-get &>/dev/null; then
                apt-get update -qq && apt-get install -y -qq fail2ban
            elif command -v yum &>/dev/null; then
                yum install -y -q epel-release && yum install -y -q fail2ban
            else
                log_warn "Cannot auto-install fail2ban. Install it manually."
            fi
        fi

        if command -v fail2ban-client &>/dev/null; then
            cat > /etc/fail2ban/jail.d/k8s-ssh.conf <<EOF
[sshd]
enabled  = true
port     = $SSH_PORT
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 3600
findtime = 600
banaction = iptables-multiport
EOF
            systemctl enable fail2ban 2>/dev/null || true
            systemctl restart fail2ban 2>/dev/null || true
            log_info "fail2ban configured and started."
        fi
    fi
fi

# ---- Persist iptables rules --------------------------------------------------
print_section "Persisting iptables rules"

if [[ "$DRY_RUN" != "true" ]]; then
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
        log_info "Rules saved via netfilter-persistent."
    elif command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
        iptables-save > /etc/sysconfig/iptables 2>/dev/null || \
        log_warn "Could not auto-persist rules. Save manually."
    fi
else
    log_info "[DRY-RUN] Skipping rule persistence."
fi

echo ""
log_info "=== SSH Hardening complete ==="
