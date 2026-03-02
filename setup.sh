#!/bin/bash

# Ensure the script is run as root
if [[ "${EUID}" -ne 0 ]]; then
    echo "Error: This script must be run as root."
    exit 1
fi

# Prompt for inputs
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

# 1. Create the user
if id "$USERNAME" &>/dev/null; then
    echo "User $USERNAME already exists."
else
    echo "Creating user $USERNAME..."
    useradd -m -s /bin/bash "$USERNAME"
fi

# 2. Grant sudo permission and configure passwordless sudo
echo "Granting sudo permissions and configuring passwordless sudo for $USERNAME..."
if grep -q "^sudo:" /etc/group; then
    # Debian/Ubuntu systems
    usermod -aG sudo "$USERNAME"
elif grep -q "^wheel:" /etc/group; then
    # RHEL/CentOS systems
    usermod -aG wheel "$USERNAME"
fi

# Set passwordless sudo now so it can be verified during the manual test
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$USERNAME-nopasswd"
chmod 0440 "/etc/sudoers.d/90-$USERNAME-nopasswd"

# 3. Add the SSH key
echo "Setting up the SSH key..."
USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
mkdir -p "$USER_HOME/.ssh"

# Safely append key to avoid overwriting existing ones
echo "$PUBKEY" >> "$USER_HOME/.ssh/authorized_keys"

# Set proper permissions using safer chown syntax
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
chown -R "$USERNAME:" "$USER_HOME/.ssh"

# 4. Test sudo permission
echo "Testing sudo permissions for $USERNAME programmatically..."
if sudo -l -U "$USERNAME" | grep -q -E "(ALL : ALL) NOPASSWD: ALL|(ALL) NOPASSWD: ALL|(ALL : ALL) ALL|(ALL) ALL"; then
    echo "SUCCESS: Sudo privileges confirmed."
else
    echo "WARNING: Could not automatically verify sudo privileges."
fi

# 5. First Manual Test (Wait for user)
SERVER_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "========================================================="
echo "ACTION REQUIRED: Test the initial SSH login and Sudo"
echo "Please open a NEW terminal window and run:"
echo "ssh $USERNAME@$SERVER_IP"
echo ""
echo "Once logged in, verify sudo access by running:"
echo "sudo ls /root"
echo "========================================================="

while true; do
    read -r -p "Did the SSH key login AND sudo command succeed? (Y/n): " yn
    case $yn in[Yy]* | "" ) 
            echo "Proceeding to harden SSH..."
            break
            ;;[Nn]* ) 
            echo "Aborting script. Please fix the SSH connection or sudo setup and try again."
            exit 1
            ;;
        * ) echo "Please answer Y or n.";;
    esac
done

# 6. Disable root login and password authentication
echo "Disabling root login and password authentication..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak # Create backup just in case

# Disable in the main config
if grep -qE '^#?PermitRootLogin' /etc/ssh/sshd_config; then
    sed -i -E 's/^#?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
else
    echo "PermitRootLogin no" >> /etc/ssh/sshd_config
fi

if grep -qE '^#?PasswordAuthentication' /etc/ssh/sshd_config; then
    sed -i -E 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
else
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
fi

# Apply a drop-in config to ensure cloud-init files don't override the settings
mkdir -p /etc/ssh/sshd_config.d
echo -e "PermitRootLogin no\nPasswordAuthentication no" > /etc/ssh/sshd_config.d/99-custom-hardening.conf

# Validate the SSH configuration syntax before attempting a restart
echo "Testing SSH configuration syntax..."
if sshd -t; then
    echo "SSH configuration is valid. Restarting service..."
    if systemctl is-active --quiet sshd; then
        systemctl restart sshd
    elif systemctl is-active --quiet ssh; then
        systemctl restart ssh
    else
        echo "Could not find ssh/sshd service to restart. Please restart it manually."
    fi
else
    echo "ERROR: SSH configuration syntax is invalid! Reverting changes..."
    mv /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
    rm -f /etc/ssh/sshd_config.d/99-custom-hardening.conf
    echo "Changes reverted safely. Aborting script."
    exit 1
fi

# 7. Second Manual Test (Wait for user)
echo ""
echo "========================================================="
echo "ACTION REQUIRED: Test SSH login AGAIN"
echo "SSH has been hardened. To ensure you are not locked out,"
echo "please test the SSH login one more time in a NEW terminal:"
echo "ssh $USERNAME@$SERVER_IP"
echo "========================================================="

while true; do
    read -r -p "Did the second SSH key login succeed? (Y/n): " yn
    case $yn in
        [Yy]* | "" ) 
            echo "SSH successfully hardened."
            break
            ;;
        [Nn]* ) 
            echo "Reverting SSH configuration to prevent lockout..."
            mv /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
            rm -f /etc/ssh/sshd_config.d/99-custom-hardening.conf
            systemctl restart sshd || systemctl restart ssh
            echo "Changes reverted safely. Aborting script."
            exit 1
            ;;
        * ) echo "Please answer Y or n.";;
    esac
done

# 8. Setup Complete
echo ""
echo "========================================================="
echo "Setup Complete!"
echo "User '$USERNAME' is fully configured with passwordless sudo."
echo "Root login and password authentication are now disabled."
echo "========================================================="
