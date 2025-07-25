#!/bin/bash

# Tiation DevOps Platform - VPS Bootstrap Script
# This script initializes all VPS instances with basic security and configuration

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
LOG_FILE="/tmp/tiation-bootstrap-$(date +%Y%m%d-%H%M%S).log"

# VPS Configuration
declare -A VPS_HOSTS=(
    ["openvpn"]="93.127.167.157"
    ["gitlab"]="149.28.135.83"
    ["grafana"]="149.28.135.84"
    ["docker"]="149.28.135.85"
    ["helm"]="149.28.135.86"
)

declare -A VPS_ROLES=(
    ["openvpn"]="OpenVPN Gateway"
    ["gitlab"]="GitLab CI/CD"
    ["grafana"]="Monitoring/Grafana" 
    ["docker"]="Docker Registry"
    ["helm"]="Helm/Kubernetes"
)

# Logging function
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

# Print colored output
print_color() {
    local color=$1
    shift
    echo -e "${color}$*${NC}"
}

# Check if SSH key exists
check_ssh_key() {
    local host=$1
    local key_file="$HOME/.ssh/tiation_${host}_ed25519"
    
    if [[ ! -f "$key_file" ]]; then
        print_color $YELLOW "SSH key for $host not found. Generating..."
        ssh-keygen -t ed25519 -f "$key_file" -C "${host}@tiation.net" -N ""
        print_color $GREEN "SSH key generated: $key_file"
    else
        print_color $BLUE "SSH key exists: $key_file"
    fi
}

# Install SSH configuration
install_ssh_config() {
    local ssh_config_file="$HOME/.ssh/config"
    local tiation_config="$CONFIG_DIR/ssh-config"
    
    print_color $BLUE "Installing SSH configuration..."
    
    # Backup existing SSH config
    if [[ -f "$ssh_config_file" ]]; then
        cp "$ssh_config_file" "${ssh_config_file}.backup.$(date +%Y%m%d-%H%M%S)"
        log "INFO" "Backed up existing SSH config"
    fi
    
    # Add Tiation configuration
    if ! grep -q "# Tiation VPS Infrastructure SSH Configuration" "$ssh_config_file" 2>/dev/null; then
        echo "" >> "$ssh_config_file"
        echo "# Tiation VPS Infrastructure SSH Configuration" >> "$ssh_config_file"
        echo "Include $tiation_config" >> "$ssh_config_file"
        print_color $GREEN "SSH configuration installed"
    else
        print_color $YELLOW "SSH configuration already installed"
    fi
}

# Test SSH connection
test_ssh_connection() {
    local host=$1
    local ip=$2
    
    print_color $BLUE "Testing SSH connection to $host ($ip)..."
    
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" "echo 'SSH connection successful'" 2>/dev/null; then
        print_color $GREEN "✓ SSH connection to $host successful"
        return 0
    else
        print_color $RED "✗ SSH connection to $host failed"
        return 1
    fi
}

# Bootstrap individual VPS
bootstrap_vps() {
    local host=$1
    local ip=$2
    local role=$3
    
    print_color $BLUE "Bootstrapping $host ($ip) - $role"
    
    # Create bootstrap script for remote execution
    local bootstrap_script=$(cat << 'EOF'
#!/bin/bash
set -euo pipefail

# Update system
apt-get update
apt-get upgrade -y

# Install essential packages
apt-get install -y \
    curl \
    wget \
    git \
    vim \
    htop \
    tree \
    unzip \
    jq \
    fail2ban \
    ufw \
    certbot \
    python3-certbot-nginx

# Configure UFW firewall
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow http
ufw allow https
ufw --force enable

# Configure fail2ban
systemctl enable fail2ban
systemctl start fail2ban

# Create tiation user (if not exists)
if ! id "tiation" &>/dev/null; then
    useradd -m -s /bin/bash -G sudo tiation
    mkdir -p /home/tiation/.ssh
    chmod 700 /home/tiation/.ssh
    # Copy root's authorized_keys to tiation user
    cp /root/.ssh/authorized_keys /home/tiation/.ssh/authorized_keys 2>/dev/null || true
    chown -R tiation:tiation /home/tiation/.ssh
    chmod 600 /home/tiation/.ssh/authorized_keys
fi

# Install Docker
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    usermod -aG docker tiation
    systemctl enable docker
    systemctl start docker
    rm get-docker.sh
fi

# Install Docker Compose
if ! command -v docker-compose &> /dev/null; then
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

# Create directories
mkdir -p /opt/tiation/{config,data,logs,backups}
chown -R tiation:tiation /opt/tiation

# Configure log rotation
cat > /etc/logrotate.d/tiation << 'LOGROTATE_EOF'
/opt/tiation/logs/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 644 tiation tiation
}
LOGROTATE_EOF

echo "Bootstrap completed successfully"
EOF
    )
    
    # Execute bootstrap script on remote host
    if ssh "$host" "bash -s" <<< "$bootstrap_script"; then
        print_color $GREEN "✓ Bootstrap completed for $host"
        log "INFO" "Bootstrap completed for $host ($ip)"
    else
        print_color $RED "✗ Bootstrap failed for $host"
        log "ERROR" "Bootstrap failed for $host ($ip)"
        return 1
    fi
}

# Deploy SSH keys to all hosts
deploy_ssh_keys() {
    print_color $BLUE "Deploying SSH keys to all hosts..."
    
    for host in "${!VPS_HOSTS[@]}"; do
        local ip="${VPS_HOSTS[$host]}"
        local key_file="$HOME/.ssh/tiation_${host}_ed25519.pub"
        
        if [[ -f "$key_file" ]]; then
            print_color $BLUE "Deploying key to $host ($ip)..."
            if ssh-copy-id -i "$key_file" "root@$ip" 2>/dev/null; then
                print_color $GREEN "✓ SSH key deployed to $host"
            else
                print_color $YELLOW "⚠ Could not deploy SSH key to $host (may already exist)"
            fi
        else
            print_color $RED "✗ SSH key not found for $host: $key_file"
        fi
    done
}

# Setup monitoring
setup_monitoring() {
    print_color $BLUE "Setting up monitoring configuration..."
    
    # Create monitoring script
    local monitoring_script="$SCRIPT_DIR/../monitoring/health-check.sh"
    if [[ -f "$monitoring_script" ]]; then
        chmod +x "$monitoring_script"
        print_color $GREEN "✓ Monitoring script configured"
    fi
    
    # Setup cron job for health checks
    (crontab -l 2>/dev/null; echo "*/5 * * * * $monitoring_script") | crontab -
    print_color $GREEN "✓ Health check cron job installed"
}

# Main bootstrap function
main() {
    print_color $GREEN "=== Tiation DevOps Platform VPS Bootstrap ==="
    print_color $BLUE "Log file: $LOG_FILE"
    
    log "INFO" "Starting VPS bootstrap process"
    
    # Generate SSH keys
    print_color $YELLOW "Generating SSH keys..."
    for host in "${!VPS_HOSTS[@]}"; do
        check_ssh_key "$host"
    done
    
    # Install SSH configuration
    install_ssh_config
    
    # Deploy SSH keys (optional - may require manual setup first)
    if [[ "${1:-}" == "--deploy-keys" ]]; then
        deploy_ssh_keys
    else
        print_color $YELLOW "Skipping SSH key deployment. Run with --deploy-keys to deploy keys."
        print_color $YELLOW "You may need to manually copy public keys to servers first."
    fi
    
    # Test connections
    print_color $YELLOW "Testing SSH connections..."
    failed_connections=0
    for host in "${!VPS_HOSTS[@]}"; do
        local ip="${VPS_HOSTS[$host]}"
        if ! test_ssh_connection "$host" "$ip"; then
            ((failed_connections++))
        fi
    done
    
    if [[ $failed_connections -eq 0 ]]; then
        print_color $GREEN "All SSH connections successful!"
        
        # Bootstrap each VPS
        print_color $YELLOW "Bootstrapping VPS instances..."
        for host in "${!VPS_HOSTS[@]}"; do
            local ip="${VPS_HOSTS[$host]}"
            local role="${VPS_ROLES[$host]}"
            bootstrap_vps "$host" "$ip" "$role"
        done
        
        # Setup monitoring
        setup_monitoring
        
        print_color $GREEN "=== Bootstrap completed successfully! ==="
        print_color $BLUE "Next steps:"
        print_color $BLUE "1. Run specific setup scripts for each service"
        print_color $BLUE "2. Configure SSL certificates"
        print_color $BLUE "3. Setup monitoring dashboards"
        
    else
        print_color $RED "Some SSH connections failed. Please check connectivity and try again."
        print_color $YELLOW "You may need to:"
        print_color $YELLOW "1. Ensure VPS instances are running"
        print_color $YELLOW "2. Manually copy SSH public keys to servers"
        print_color $YELLOW "3. Check firewall settings"
    fi
    
    log "INFO" "Bootstrap process completed"
    print_color $BLUE "Detailed log: $LOG_FILE"
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
