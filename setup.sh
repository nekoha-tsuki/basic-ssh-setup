#!/bin/bash

# ==========================================
# Color Definitions
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Ensure the script is run as root
if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run as root.${NC}"
    exit 1
fi

# ==========================================
# Prompt for inputs
# ==========================================
echo -ne "${CYAN}Enter the new username: ${NC}"
read -r USERNAME
if [[ -z "$USERNAME" ]]; then
    echo -e "${RED}Error: Username cannot be empty.${NC}"
    exit 1
fi

echo -ne "${CYAN}Enter the public key (e.g., ssh-rsa AAAAB3...): ${NC}"
read -r PUBKEY
if [[ -z "$PUBKEY" ]]; then
    echo -e "${RED}Error: Public key cannot be empty.${NC}"
    exit 1
fi

echo -ne "${CYAN}Enter the custom SSH port (press Enter for default 22): ${NC}"
read -r SSH_PORT
SSH_PORT=${SSH_PORT:-22} # Default to 22 if input is empty

# Validate port number
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] ||[ "$SSH_PORT" -lt 1 ] ||[ "$SSH_PORT" -gt 65535 ]; then
    echo -e "${RED}Error: Invalid port number. Must be between 1 and 65535.${NC}"
    exit 1
fi

# ==========================================
# 1. Create the user
# ==========================================
if id "$USERNAME" &>/dev/null; then
    echo -e "${YELLOW}User $USERNAME already exists.${NC}"
else
    echo -e "${BLUE}Creating user $USERNAME...${NC}"
    useradd -m -s /bin/bash "$USERNAME"
fi

# ==========================================
# 2. Grant sudo and configure passwordless sudo
# ==========================================
echo -e "${BLUE}Granting sudo permissions and configuring passwordless sudo for $USERNAME...${NC}"
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
echo -e "${BLUE}Setting up the SSH key...${NC}"
USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
mkdir -p "$USER_HOME/.ssh"

echo "$PUBKEY" >> "$USER_HOME/.ssh/authorized_keys"

chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
chown -R "$USERNAME:" "$USER_HOME/.ssh"

# ==========================================
# 4. Test sudo permission
# ==========================================
echo -e "${BLUE}Testing sudo privileges for $USERNAME programmatically...${NC}"
SUDO_OUT=$(sudo -l -U "$USERNAME" 2>/dev/null)

if echo "$SUDO_OUT" | grep -qF "(ALL : ALL) ALL" && echo "$SUDO_OUT" | grep -q "NOPASSWD: ALL"; then
    echo -e "${GREEN}SUCCESS: Both standard Sudo and NOPASSWD privileges confirmed.${NC}"
elif echo "$SUDO_OUT" | grep -q "NOPASSWD: ALL"; then
    echo -e "${GREEN}SUCCESS: NOPASSWD sudo confirmed (Standard sudo group missing).${NC}"
elif echo "$SUDO_OUT" | grep -qF "(ALL : ALL) ALL"; then
    echo -e "${YELLOW}WARNING: Standard sudo is present, but NOPASSWD is MISSING! User will need a password.${NC}"
else
    echo -e "${RED}WARNING: Could not automatically verify any sudo privileges.${NC}"
fi

# ==========================================
# 5. First Manual Test
# ==========================================
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "$SERVER_IP" ]] && SERVER_IP="<YOUR_SERVER_IP>"

echo ""
echo -e "${CYAN}=========================================================${NC}"
echo -e "${CYAN}ACTION REQUIRED: Test the initial SSH login and Sudo${NC}"
echo -e "Please open a NEW terminal window and run:"
echo -e "${BOLD}${GREEN}ssh $USERNAME@$SERVER_IP${NC}  (Add '-p <current_port>' if not 22)"
echo ""
echo -e "Once logged in, verify sudo access by running:"
echo -e "${BOLD}${GREEN}sudo ls /root${NC}"
echo -e "${CYAN}=========================================================${NC}"

while true; do
    echo -ne "${YELLOW}Did the SSH key login AND sudo command succeed? (Y/n): ${NC}"
    read -r yn
    case "$yn" in
        [Yy]* ) 
            echo -e "${GREEN}Proceeding to harden SSH and change port...${NC}"
            break
            ;;
        [Nn]* ) 
            echo -e "${RED}Aborting script. Please fix the SSH connection or sudo setup and try again.${NC}"
            exit 1
            ;;
        * ) echo -e "${YELLOW}Please answer Y or n.${NC}";;
    esac
done

# ==========================================
# 6. Disable root login, pass auth, & Set Port
# ==========================================
echo -e "${BLUE}Configuring SSH hardening and custom port ($SSH_PORT)...${NC}"

# --- Systemd Socket Check (Ubuntu 22.04+ Fix) ---
if systemctl is-active --quiet ssh.socket; then
    echo -e "${YELLOW}--> WARNING: systemd ssh.socket detected! This overrides sshd_config ports.${NC}"
    echo -e "${YELLOW}--> Disabling ssh.socket and switching to standard ssh.service...${NC}"
    systemctl disable --now ssh.socket
    systemctl enable --now ssh.service
fi

# --- Firewall Handling ---
if [ "$SSH_PORT" -ne 22 ]; then
    echo -e "${BLUE}Checking local firewalls to allow port $SSH_PORT...${NC}"
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        echo -e "${YELLOW}--> UFW detected. Allowing port $SSH_PORT/tcp...${NC}"
        ufw allow "$SSH_PORT"/tcp
    fi
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        echo -e "${YELLOW}--> Firewalld detected. Allowing port $SSH_PORT/tcp...${NC}"
        firewall-cmd --add-port="$SSH_PORT"/tcp --permanent
        firewall-cmd --reload
    fi

    # --- SELinux Handling ---
    if command -v getenforce &>/dev/null && [[ "$(getenforce)" == "Enforcing" ]]; then
        if command -v semanage &>/dev/null; then
            echo -e "${YELLOW}--> SELinux is Enforcing. Updating SSH port context to allow $SSH_PORT...${NC}"
            semanage port -a -t ssh_port_t -p tcp "$SSH_PORT" 2>/dev/null || semanage port -m -t ssh_port_t -p tcp "$SSH_PORT"
        fi
    fi
fi

# --- Backup and Modify Main Config ---
cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# Comment out any active 'Port' declarations in the main config
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
echo -e "${BLUE}Testing SSH configuration syntax...${NC}"
if sshd -t; then
    echo -e "${GREEN}SSH configuration is valid. Restarting service...${NC}"
    
    # Identify the correct SSH service name
    SSH_SERVICE=""
    if systemctl is-active --quiet sshd; then SSH_SERVICE="sshd"
    elif systemctl is-active --quiet ssh; then SSH_SERVICE="ssh"
    fi

    if [[ -n "$SSH_SERVICE" ]]; then
        # Try to restart and catch failures
        if ! systemctl restart "$SSH_SERVICE"; then
            echo -e "${RED}ERROR: $SSH_SERVICE failed to restart! (Possible port binding issue).${NC}"
            echo -e "${YELLOW}Reverting configuration to prevent lockout...${NC}"
            mv /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
            rm -f /etc/ssh/sshd_config.d/99-custom-hardening.conf
            systemctl restart "$SSH_SERVICE"
            exit 1
        fi
    else
        echo -e "${YELLOW}WARNING: Could not automatically restart ssh/sshd. Please restart it manually.${NC}"
    fi
else
    echo -e "${RED}ERROR: SSH configuration syntax is invalid! Reverting changes...${NC}"
    mv /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
    rm -f /etc/ssh/sshd_config.d/99-custom-hardening.conf
    echo -e "${YELLOW}Changes reverted safely. Aborting script.${NC}"
    exit 1
fi

# ==========================================
# 7. Second Manual Test
# ==========================================
echo ""
echo -e "${CYAN}=========================================================${NC}"
echo -e "${CYAN}ACTION REQUIRED: Test SSH login AGAIN${NC}"
echo -e "SSH has been hardened and the port updated to ${BOLD}$SSH_PORT${NC}."
echo -e "Please test the SSH login one more time in a NEW terminal:"
echo -e "${BOLD}${GREEN}ssh -p $SSH_PORT $USERNAME@$SERVER_IP${NC}"
echo -e "${CYAN}=========================================================${NC}"

while true; do
    echo -ne "${YELLOW}Did the second SSH key login succeed? (Y/n): ${NC}"
    read -r yn
    case "$yn" in
        [Yy]* ) 
            echo -e "${GREEN}SSH successfully hardened.${NC}"
            rm -f /etc/ssh/sshd_config.bak
            break
            ;;
        [Nn]* ) 
            echo -e "${RED}Reverting SSH configuration to prevent lockout...${NC}"
            mv /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
            rm -f /etc/ssh/sshd_config.d/99-custom-hardening.conf
            [[ -n "$SSH_SERVICE" ]] && systemctl restart "$SSH_SERVICE"
            echo -e "${YELLOW}Changes reverted safely. Aborting script.${NC}"
            exit 1
            ;;
        * ) echo -e "${YELLOW}Please answer Y or n.${NC}";;
    esac
done

# ==========================================
# 8. Setup Complete
# ==========================================
echo ""
echo -e "${GREEN}=========================================================${NC}"
echo -e "${BOLD}${GREEN}Setup Complete!${NC}"
echo -e "User ${BOLD}'$USERNAME'${NC} is configured with passwordless sudo."
echo -e "Root login and password authentication are disabled."
echo -e "SSH is now exclusively running on port ${BOLD}$SSH_PORT${NC}."
echo -e "${GREEN}=========================================================${NC}"
