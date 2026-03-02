#!/bin/bash

# Ensure the script is run as root
if [[ "${EUID}" -ne 0 ]]; then
    echo "Error: This script must be run as root."
    exit 1
fi

# ==========================================
# Prompt for inputs
# ==========================================
read -r -p "Enter the new username: " USERNAME
if [[ -z "$USERNAME" ]]; then
    echo "Username cannot be empty."
    exit 1
fi

read -r -p "Enter the public key (e.g., ssh-rsa AAAAB3...): " PUBKEY
if [[ -z "$PUBKEY" ]]; then
    echo "Public key cannot be empty."
    exit 1
fi

read -r -p "Enter the custom SSH port (press Enter for default 22): " SSH_PORT
SSH_PORT=${SSH_PORT:-22} # Default to 22 if input is empty

# Validate port number
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] ||[ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    echo "Error: Invalid port number. Must be between 1 and 65535."
    exit 1
fi

# ==========================================
# 1. Create the user
# ==========================================
if id "$USERNAME" &>/dev/null; then
    echo "User $USERNAME already exists."
else
    echo "Creating user $USERNAME..."
    useradd -m -s /bin/bash "$USERNAME"
fi

# ==========================================
# 2. Grant sudo and configure passwordless sudo
# ==========================================
echo "Granting sudo permissions and configuring passwordless sudo for $USERNAME..."
if grep -q "^sudo:" /etc/group; then
    usermod -aG sudo "$USERNAME"
elif grep -q "^wheel:" /etc/group; then
    usermod -aG wheel "$USERNAME"
fi

echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$USERNAME-nopasswd"
chmod 0440 "/etc/sudoers.d/90-$USERNAME-nopasswd"

# ==========================================
# 3. Add the SSH key
# ==========================================
echo "Setting up the SSH key..."
USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
mkdir -p "$USER_HOME/.ssh"

echo "$PUBKEY" >> "$USER_HOME/.ssh/authorized_keys"

chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
chown -R "$USERNAME:" "$USER_HOME/.ssh"

# ==========================================
# 4. Test sudo permission
# ==========================================
echo "Testing sudo privileges for $USERNAME programmatically..."
SUDO_OUT=$(sudo -l -U "$USERNAME" 2>/dev/null)

if echo "$SUDO_OUT" | grep -qF "(ALL : ALL) ALL" && echo "$SUDO_OUT" | grep -q "NOPASSWD: ALL"; then
    echo "SUCCESS: Both standard Sudo and NOPASSWD privileges confirmed."
elif echo "$SUDO_OUT" | grep -q "NOPASSWD: ALL"; then
    echo "SUCCESS: NOPASSWD sudo confirmed (Standard sudo group missing)."
elif echo "$SUDO_OUT" | grep -qF "(ALL : ALL) ALL"; then
    echo "WARNING: Standard sudo is present, but NOPASSWD is MISSING! User will need a password."
else
    echo "WARNING: Could not automatically verify any sudo privileges."
fi

# ==========================================
# 5. First Manual Test
# ==========================================
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "$SERVER_IP" ]] && SERVER_IP="<YOUR_SERVER_IP>"

echo ""
echo "========================================================="
echo "ACTION REQUIRED: Test the initial SSH login and Sudo"
echo "Please open a NEW terminal window and run:"
echo "ssh $USERNAME@$SERVER_IP  (Add '-p <current_port>' if not 22)"
echo ""
echo "Once logged in, verify sudo access by running:"
echo "sudo ls /root"
echo "========================================================="

while true; do
    read -r -p "Did the SSH key login AND sudo command succeed? (Y/n): " yn
    case "$yn" in
	 [Yy]* ) 
            echo "Proceeding to harden SSH and change port..."
            break
            ;;
        [Nn]* ) 
            echo "Aborting script. Please fix the SSH connection or sudo setup and try again."
            exit 1
            ;;
        * ) echo "Please answer Y or n.";;
    esac
done

# ==========================================
# 6. Disable root login, pass auth, & Set Port
# ==========================================
echo "Configuring SSH hardening and custom port ($SSH_PORT)..."

# --- Systemd Socket Check (Ubuntu 22.04+ Fix) ---
if systemctl is-active --quiet ssh.socket; then
    echo "--> WARNING: systemd ssh.socket detected! This overrides sshd_config ports."
    echo "--> Disabling ssh.socket and switching to standard ssh.service..."
    systemctl disable --now ssh.socket
    systemctl enable --now ssh.service
fi

# --- Firewall Handling ---
if [ "$SSH_PORT" -ne 22 ]; then
    echo "Checking local firewalls to allow port $SSH_PORT..."
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        echo "--> UFW detected. Allowing port $SSH_PORT/tcp..."
        ufw allow "$SSH_PORT"/tcp
    fi
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        echo "--> Firewalld detected. Allowing port $SSH_PORT/tcp..."
        firewall-cmd --add-port="$SSH_PORT"/tcp --permanent
        firewall-cmd --reload
    fi

    # --- SELinux Handling ---
    if command -v getenforce &>/dev/null && [[ "$(getenforce)" == "Enforcing" ]]; then
        if command -v semanage &>/dev/null; then
            echo "--> SELinux is Enforcing. Updating SSH port context to allow $SSH_PORT..."
            semanage port -a -t ssh_port_t -p tcp "$SSH_PORT" 2>/dev/null || semanage port -m -t ssh_port_t -p tcp "$SSH_PORT"
        fi
    fi
fi

# --- Backup and Modify Main Config ---
cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# Fix: Comment out any active 'Port' declarations in the main config so we don't open multiple ports
sed -i -E 's/^([[:space:]]*Port[[:space:]]+[0-9]+)/#\1/ig' /etc/ssh/sshd_config

# Check if Include directive exists, add if missing
if ! grep -qEi "^Include.*sshd_config\.d" /etc/ssh/sshd_config; then
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
fi

# Create the drop-in configuration
mkdir -p /etc/ssh/sshd_config.d
cat <<EOF > /etc/ssh/sshd_config.d/99-custom-hardening.conf
# Custom SSH Hardening overrides
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
EOF

# Validate syntax and restart safely
echo "Testing SSH configuration syntax..."
if sshd -t; then
    echo "SSH configuration is valid. Restarting service..."
    
    # Identify the correct SSH service name
    SSH_SERVICE=""
    if systemctl is-active --quiet sshd; then SSH_SERVICE="sshd"
    elif systemctl is-active --quiet ssh; then SSH_SERVICE="ssh"
    fi

    if [[ -n "$SSH_SERVICE" ]]; then
        # Try to restart and catch failures (e.g. port binding issues)
        if ! systemctl restart "$SSH_SERVICE"; then
            echo "ERROR: $SSH_SERVICE failed to restart! (Possible port binding issue)."
            echo "Reverting configuration to prevent lockout..."
            mv /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
            rm -f /etc/ssh/sshd_config.d/99-custom-hardening.conf
            systemctl restart "$SSH_SERVICE"
            exit 1
        fi
    else
        echo "WARNING: Could not automatically restart ssh/sshd. Please restart it manually."
    fi
else
    echo "ERROR: SSH configuration syntax is invalid! Reverting changes..."
    mv /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
    rm -f /etc/ssh/sshd_config.d/99-custom-hardening.conf
    echo "Changes reverted safely. Aborting script."
    exit 1
fi

# ==========================================
# 7. Second Manual Test
# ==========================================
echo ""
echo "========================================================="
echo "ACTION REQUIRED: Test SSH login AGAIN"
echo "SSH has been hardened and the port updated to $SSH_PORT."
echo "Please test the SSH login one more time in a NEW terminal:"
echo "ssh -p $SSH_PORT $USERNAME@$SERVER_IP"
echo "========================================================="

while true; do
    read -r -p "Did the second SSH key login succeed? (Y/n): " yn
    case "$yn" in
        [Yy]* ) 
            echo "SSH successfully hardened."
            # Remove the backup as we successfully verified everything
            rm -f /etc/ssh/sshd_config.bak
            break
            ;;
        [Nn]* ) 
            echo "Reverting SSH configuration to prevent lockout..."
            mv /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
            rm -f /etc/ssh/sshd_config.d/99-custom-hardening.conf
            [[ -n "$SSH_SERVICE" ]] && systemctl restart "$SSH_SERVICE"
            echo "Changes reverted safely. Aborting script."
            exit 1
            ;;
        * ) echo "Please answer Y or n.";;
    esac
done

# ==========================================
# 8. Setup Complete
# ==========================================
echo ""
echo "========================================================="
echo "Setup Complete!"
echo "User '$USERNAME' is configured with passwordless sudo."
echo "Root login and password authentication are disabled."
echo "SSH is now exclusively running on port $SSH_PORT."
echo "========================================================="
