#!/bin/bash

# Ensure the script is run as root
if [[ "${EUID}" -ne 0 ]]; then
    echo "Error: This script must be run as root."
    exit 1
fi

# Prompt for inputs
read -p "Enter the new username: " USERNAME
if [[ -z "$USERNAME" ]]; then
    echo "Username cannot be empty."
    exit 1
fi

read -p "Enter the public key (e.g., ssh-rsa AAAAB3...): " PUBKEY
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

# 2. Grant sudo permission
echo "Granting sudo permissions to $USERNAME..."
if grep -q "^sudo:" /etc/group; then
    # Debian/Ubuntu systems
    usermod -aG sudo "$USERNAME"
elif grep -q "^wheel:" /etc/group; then
    # RHEL/CentOS systems
    usermod -aG wheel "$USERNAME"
else
    # Fallback if standard groups don't exist
    echo "$USERNAME ALL=(ALL:ALL) ALL" > "/etc/sudoers.d/80-$USERNAME-init"
    chmod 0440 "/etc/sudoers.d/80-$USERNAME-init"
fi

# 3. Add the SSH key
echo "Setting up the SSH key..."
USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
mkdir -p "$USER_HOME/.ssh"
echo "$PUBKEY" > "$USER_HOME/.ssh/authorized_keys"

# Set proper permissions
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"

# 4. Test sudo permission
echo "Testing sudo permissions for $USERNAME programmatically..."
if sudo -l -U "$USERNAME" | grep -q -E "(ALL : ALL) ALL|(ALL) ALL"; then
    echo "SUCCESS: Sudo privileges confirmed."
else
    echo "WARNING: Could not automatically verify sudo privileges."
fi

# 5. First Manual Test (Wait for user)
SERVER_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "========================================================="
echo "ACTION REQUIRED: Test the initial SSH login"
echo "Please open a NEW terminal window and run:"
echo "ssh $USERNAME@$SERVER_IP"
echo "========================================================="

while true; do
    read -p "Did the SSH key login succeed? (Y/n): " yn
    case $yn in
        [Yy]* | "" ) 
            echo "Proceeding to harden SSH..."
            break
            ;;
        [Nn]* ) 
            echo "Aborting script. Please fix the SSH connection and try again."
            exit 1
            ;;
        * ) echo "Please answer Y or n.";;
    esac
done

# 6. Disable root login and password authentication
echo "Disabling root login and password authentication..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak # Create backup just in case

# Disable PermitRootLogin
if grep -qE '^#?PermitRootLogin' /etc/ssh/sshd_config; then
    sed -i -E 's/^#?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
else
    echo "PermitRootLogin no" >> /etc/ssh/sshd_config
fi

# Disable PasswordAuthentication
if grep -qE '^#?PasswordAuthentication' /etc/ssh/sshd_config; then
    sed -i -E 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
else
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
fi

# Restart SSH service
if systemctl is-active --quiet sshd; then
    systemctl restart sshd
elif systemctl is-active --quiet ssh; then
    systemctl restart ssh
else
    echo "Could not find ssh/sshd service to restart. Please restart it manually."
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
    read -p "Did the second SSH key login succeed? (Y/n): " yn
    case $yn in
        [Yy]* | "" ) 
            echo "SSH successfully hardened."
            break
            ;;
        [Nn]* ) 
            echo "Reverting SSH configuration to prevent lockout..."
            mv /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
            systemctl restart sshd || systemctl restart ssh
            echo "Changes reverted safely. Aborting script."
            exit 1
            ;;
        * ) echo "Please answer Y or n.";;
    esac
done

# 8. Configure passwordless sudo
echo "Configuring passwordless sudo for $USERNAME..."
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$USERNAME-nopasswd"
chmod 0440 "/etc/sudoers.d/90-$USERNAME-nopasswd"

# Clean up initial fallback sudo file if it was created
rm -f "/etc/sudoers.d/80-$USERNAME-init"

echo ""
echo "========================================================="
echo "Setup Complete!"
echo "User '$USERNAME' is fully configured with passwordless sudo."
echo "Root login and password authentication are now disabled."
echo "========================================================="
