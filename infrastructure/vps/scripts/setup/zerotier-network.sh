#!/bin/bash

# ZeroTier Network Setup Script
# Automatically configures ZeroTier client and joins specified networks

set -euo pipefail

# Configuration
ZEROTIER_CLI="/usr/sbin/zerotier-cli"
ZEROTIER_SERVICE="zerotier-one"
ZEROTIER_CONFIG_DIR="/var/lib/zerotier-one"
LOG_FILE="/var/log/zerotier-setup.log"

# Default ZeroTier network configuration
# You can override these in your configuration or pass as parameters
TIATION_NETWORK_ID=""     # Main Tiation network ID
DEV_NETWORK_ID=""         # Development network ID  
STAGING_NETWORK_ID=""     # Staging network ID
PROD_NETWORK_ID=""        # Production network ID

# Node configuration
NODE_NAME=""              # Human-readable node name
NODE_DESCRIPTION=""       # Node description
NODE_TAGS=""              # Comma-separated tags

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO:${NC} $1" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] SUCCESS:${NC} $1" | tee -a "$LOG_FILE"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

install_zerotier() {
    local os
    os=$(detect_os)
    
    log "Installing ZeroTier for OS: $os"
    
    case "$os" in
        ubuntu|debian)
            # Install ZeroTier repository key and source
            curl -s https://install.zerotier.com/ | bash
            ;;
        centos|rhel|fedora)
            # Install ZeroTier repository and package
            curl -s https://install.zerotier.com/ | bash
            ;;
        *)
            warn "Unsupported OS: $os. Attempting generic installation..."
            curl -s https://install.zerotier.com/ | bash
            ;;
    esac
    
    # Verify installation
    if command -v zerotier-cli >/dev/null 2>&1; then
        success "ZeroTier installed successfully"
    else
        error "ZeroTier installation failed"
    fi
}

start_zerotier_service() {
    log "Starting ZeroTier service..."
    
    # Enable and start ZeroTier service
    systemctl enable "$ZEROTIER_SERVICE"
    systemctl start "$ZEROTIER_SERVICE"
    
    # Wait for service to initialize
    sleep 5
    
    # Check service status
    if systemctl is-active --quiet "$ZEROTIER_SERVICE"; then
        success "ZeroTier service started successfully"
    else
        error "Failed to start ZeroTier service"
    fi
}

get_node_id() {
    local node_id
    node_id=$("$ZEROTIER_CLI" info | awk '{print $3}')
    echo "$node_id"
}

join_network() {
    local network_id="$1"
    local network_name="${2:-Network}"
    
    if [[ -z "$network_id" ]]; then
        warn "No network ID provided for $network_name, skipping..."
        return 0
    fi
    
    log "Joining $network_name (ID: $network_id)..."
    
    # Join the network
    if "$ZEROTIER_CLI" join "$network_id"; then
        success "Successfully joined $network_name"
        
        # Wait for network to be configured
        info "Waiting for network configuration..."
        sleep 10
        
        # Check network status
        local status
        status=$("$ZEROTIER_CLI" listnetworks | grep "$network_id" | awk '{print $7}' || echo "UNKNOWN")
        
        if [[ "$status" == "OK" ]]; then
            success "$network_name is configured and ready"
        else
            warn "$network_name status: $status (may need authorization on network controller)"
        fi
    else
        error "Failed to join $network_name"
    fi
}

leave_network() {
    local network_id="$1"
    local network_name="${2:-Network}"
    
    if [[ -z "$network_id" ]]; then
        warn "No network ID provided for $network_name"
        return 1
    fi
    
    log "Leaving $network_name (ID: $network_id)..."
    
    if "$ZEROTIER_CLI" leave "$network_id"; then
        success "Successfully left $network_name"
    else
        error "Failed to leave $network_name"
    fi
}

configure_firewall() {
    log "Configuring firewall for ZeroTier..."
    
    # Install UFW if not present
    if ! command -v ufw >/dev/null 2>&1; then
        case $(detect_os) in
            ubuntu|debian)
                apt-get update && apt-get install -y ufw
                ;;
            centos|rhel|fedora)
                yum install -y ufw || dnf install -y ufw
                ;;
        esac
    fi
    
    # Configure UFW rules
    if command -v ufw >/dev/null 2>&1; then
        # Allow ZeroTier UDP port
        ufw allow 9993/udp comment "ZeroTier"
        
        # Allow traffic on ZeroTier interfaces
        ufw allow in on zt+ comment "ZeroTier networks"
        ufw allow out on zt+ comment "ZeroTier networks"
        
        success "Firewall configured for ZeroTier"
    else
        warn "UFW not available, please configure firewall manually"
        info "Required: Allow UDP port 9993 and traffic on zt* interfaces"
    fi
}

set_node_name() {
    local name="$1"
    
    if [[ -n "$name" ]]; then
        log "Setting node name to: $name"
        
        # Create identity.public.name file
        echo "$name" > "$ZEROTIER_CONFIG_DIR/identity.public.name"
        
        # Restart service to apply changes
        systemctl restart "$ZEROTIER_SERVICE"
        sleep 5
        
        success "Node name set to: $name"
    fi
}

create_management_scripts() {
    log "Creating ZeroTier management scripts..."
    
    # Status script
    cat > /usr/local/bin/zerotier-status << 'EOF'
#!/bin/bash

echo "=== ZeroTier Node Status ==="
zerotier-cli info

echo -e "\n=== ZeroTier Service Status ==="
systemctl status zerotier-one --no-pager -l

echo -e "\n=== Joined Networks ==="
zerotier-cli listnetworks

echo -e "\n=== Network Interfaces ==="
ip addr show | grep -A 5 "zt"

echo -e "\n=== Routing Table (ZeroTier) ==="
ip route | grep zt || echo "No ZeroTier routes found"

echo -e "\n=== Firewall Status ==="
if command -v ufw >/dev/null 2>&1; then
    ufw status | grep -E "(9993|zt)" || echo "No ZeroTier firewall rules found"
else
    echo "UFW not installed"
fi
EOF

    # Network management script
    cat > /usr/local/bin/zerotier-network << 'EOF'
#!/bin/bash

set -e

ZEROTIER_CLI="/usr/sbin/zerotier-cli"

show_usage() {
    echo "Usage: $0 {join|leave|list|info|authorize} [network_id] [options]"
    echo
    echo "Commands:"
    echo "  join <network_id>    - Join a ZeroTier network"
    echo "  leave <network_id>   - Leave a ZeroTier network"
    echo "  list                 - List all joined networks"
    echo "  info                 - Show node information"
    echo "  authorize <network_id> - Show authorization instructions"
    echo
    echo "Examples:"
    echo "  $0 join a1b2c3d4e5f6g7h8"
    echo "  $0 leave a1b2c3d4e5f6g7h8"
    echo "  $0 list"
}

case "${1:-}" in
    join)
        if [[ -z "${2:-}" ]]; then
            echo "Error: Network ID required"
            show_usage
            exit 1
        fi
        
        echo "Joining network: $2"
        $ZEROTIER_CLI join "$2"
        
        echo "Waiting for network configuration..."
        sleep 5
        
        echo "Network status:"
        $ZEROTIER_CLI listnetworks | grep "$2" || echo "Network not found in list"
        
        echo
        echo "Note: If the network shows as 'REQUESTING_CONFIGURATION',"
        echo "you may need to authorize this node in the ZeroTier Central web interface."
        echo "Node ID: $($ZEROTIER_CLI info | awk '{print $3}')"
        ;;
    leave)
        if [[ -z "${2:-}" ]]; then
            echo "Error: Network ID required"
            show_usage
            exit 1
        fi
        
        echo "Leaving network: $2"
        $ZEROTIER_CLI leave "$2"
        echo "Successfully left network"
        ;;
    list)
        echo "=== Joined Networks ==="
        $ZEROTIER_CLI listnetworks
        ;;
    info)
        echo "=== Node Information ==="
        $ZEROTIER_CLI info
        echo
        echo "=== Node Configuration ==="
        echo "Config directory: /var/lib/zerotier-one"
        if [[ -f /var/lib/zerotier-one/identity.public.name ]]; then
            echo "Node name: $(cat /var/lib/zerotier-one/identity.public.name)"
        fi
        ;;
    authorize)
        if [[ -z "${2:-}" ]]; then
            echo "Error: Network ID required"
            show_usage
            exit 1
        fi
        
        local node_id
        node_id=$($ZEROTIER_CLI info | awk '{print $3}')
        
        echo "=== Network Authorization Instructions ==="
        echo "Network ID: $2"
        echo "Node ID: $node_id"
        echo
        echo "To authorize this node:"
        echo "1. Go to https://my.zerotier.com/"
        echo "2. Select network: $2"
        echo "3. Find node: $node_id"
        echo "4. Check the 'Auth' checkbox"
        echo "5. Optionally set a name and description"
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
EOF

    # Monitoring script
    cat > /usr/local/bin/zerotier-monitor << 'EOF'
#!/bin/bash

# ZeroTier Network Monitoring Script
LOG_FILE="/var/log/zerotier-monitor.log"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

check_service() {
    if ! systemctl is-active --quiet zerotier-one; then
        log "WARNING: ZeroTier service is not running"
        systemctl restart zerotier-one
        log "INFO: ZeroTier service restarted"
    fi
}

check_networks() {
    local networks
    networks=$(zerotier-cli listnetworks 2>/dev/null | grep -c "OK" || echo 0)
    
    if [[ $networks -eq 0 ]]; then
        log "WARNING: No active ZeroTier networks found"
    else
        log "INFO: $networks active ZeroTier network(s)"
    fi
}

check_connectivity() {
    # Test connectivity to ZeroTier infrastructure
    if ! ping -c 1 -W 5 my.zerotier.com >/dev/null 2>&1; then
        log "WARNING: Cannot reach ZeroTier infrastructure"
    fi
}

main() {
    log "Starting ZeroTier health check"
    check_service
    check_networks
    check_connectivity
    log "ZeroTier health check completed"
}

main "$@"
EOF

    # Make scripts executable
    chmod +x /usr/local/bin/zerotier-status
    chmod +x /usr/local/bin/zerotier-network
    chmod +x /usr/local/bin/zerotier-monitor
    
    success "Management scripts created"
}

setup_monitoring() {
    log "Setting up ZeroTier monitoring..."
    
    # Create monitoring cron job
    cat > /etc/cron.d/zerotier-monitor << 'EOF'
# ZeroTier monitoring - check every 5 minutes
*/5 * * * * root /usr/local/bin/zerotier-monitor
EOF
    
    # Setup log rotation
    cat > /etc/logrotate.d/zerotier << 'EOF'
/var/log/zerotier*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 644 root root
    postrotate
        systemctl reload zerotier-one > /dev/null 2>&1 || true
    endscript
}
EOF
    
    success "Monitoring configured"
}

get_network_config() {
    echo "Please provide ZeroTier network configuration:"
    
    if [[ -z "$TIATION_NETWORK_ID" ]]; then
        echo -n "Main Tiation Network ID (required): "
        read -r TIATION_NETWORK_ID
    fi
    
    echo -n "Development Network ID (optional): "
    read -r DEV_NETWORK_ID
    
    echo -n "Staging Network ID (optional): "
    read -r STAGING_NETWORK_ID
    
    echo -n "Production Network ID (optional): "
    read -r PROD_NETWORK_ID
    
    echo -n "Node name (optional): "
    read -r NODE_NAME
    
    echo -n "Node description (optional): "
    read -r NODE_DESCRIPTION
}

show_networks_info() {
    local node_id
    node_id=$(get_node_id)
    
    echo -e "\n${CYAN}=== ZeroTier Network Information ===${NC}"
    echo -e "${BLUE}Node ID:${NC} $node_id"
    
    if [[ -n "$NODE_NAME" ]]; then
        echo -e "${BLUE}Node Name:${NC} $NODE_NAME"
    fi
    
    echo -e "\n${YELLOW}Joined Networks:${NC}"
    "$ZEROTIER_CLI" listnetworks
    
    echo -e "\n${YELLOW}Network Interfaces:${NC}"
    ip addr show | grep -A 3 "zt" || echo "No ZeroTier interfaces found yet"
    
    echo -e "\n${YELLOW}Authorization Required:${NC}"
    echo "To complete setup, authorize this node in ZeroTier Central:"
    echo "1. Visit: https://my.zerotier.com/"
    echo "2. Select your network(s)"
    echo "3. Find and authorize node: $node_id"
    
    if [[ -n "$NODE_NAME" ]]; then
        echo "4. Set node name to: $NODE_NAME"
    fi
}

print_summary() {
    local node_id
    node_id=$(get_node_id)
    
    echo -e "\n${GREEN}=== ZeroTier Setup Complete ===${NC}"
    echo -e "${BLUE}Node ID:${NC} $node_id"
    echo -e "${BLUE}Service Status:${NC} $(systemctl is-active zerotier-one)"
    echo -e "${BLUE}Config Directory:${NC} $ZEROTIER_CONFIG_DIR"
    echo
    echo -e "${YELLOW}Management Commands:${NC}"
    echo -e "  ${BLUE}zerotier-status${NC}           - View ZeroTier status"
    echo -e "  ${BLUE}zerotier-network join <id>${NC} - Join a network"
    echo -e "  ${BLUE}zerotier-network leave <id>${NC} - Leave a network"
    echo -e "  ${BLUE}zerotier-network list${NC}     - List joined networks"
    echo -e "  ${BLUE}zerotier-network info${NC}     - Show node information"
    echo
    echo -e "${YELLOW}Log Files:${NC}"
    echo -e "  Setup log: ${BLUE}$LOG_FILE${NC}"
    echo -e "  Monitor log: ${BLUE}/var/log/zerotier-monitor.log${NC}"
    echo -e "  Service logs: ${BLUE}journalctl -u zerotier-one${NC}"
    echo
    echo -e "${YELLOW}Next Steps:${NC}"
    echo -e "  1. Authorize node in ZeroTier Central: ${BLUE}https://my.zerotier.com/${NC}"
    echo -e "  2. Check network status: ${BLUE}zerotier-network list${NC}"
    echo -e "  3. Test connectivity between nodes"
    echo -e "  4. Configure application-specific firewall rules as needed"
}

main() {
    log "Starting ZeroTier network setup..."
    
    check_root
    
    # Get configuration if not provided
    if [[ -z "$TIATION_NETWORK_ID" ]]; then
        get_network_config
    fi
    
    # Validate required configuration
    if [[ -z "$TIATION_NETWORK_ID" ]]; then
        error "Main Tiation Network ID is required"
    fi
    
    # Install and configure ZeroTier
    install_zerotier
    start_zerotier_service
    configure_firewall
    
    # Set node name if provided
    if [[ -n "$NODE_NAME" ]]; then
        set_node_name "$NODE_NAME"
    fi
    
    # Join networks
    join_network "$TIATION_NETWORK_ID" "Main Tiation Network"
    
    if [[ -n "$DEV_NETWORK_ID" ]]; then
        join_network "$DEV_NETWORK_ID" "Development Network"
    fi
    
    if [[ -n "$STAGING_NETWORK_ID" ]]; then
        join_network "$STAGING_NETWORK_ID" "Staging Network"
    fi
    
    if [[ -n "$PROD_NETWORK_ID" ]]; then
        join_network "$PROD_NETWORK_ID" "Production Network"
    fi
    
    # Create management tools
    create_management_scripts
    setup_monitoring
    
    # Show network information
    show_networks_info
    
    print_summary
    
    success "ZeroTier network setup completed successfully"
}

# Handle command line arguments
case "${1:-setup}" in
    setup)
        main
        ;;
    join)
        if [[ -z "${2:-}" ]]; then
            error "Usage: $0 join <network_id> [network_name]"
        fi
        join_network "$2" "${3:-Network}"
        ;;
    leave)
        if [[ -z "${2:-}" ]]; then
            error "Usage: $0 leave <network_id> [network_name]"
        fi
        leave_network "$2" "${3:-Network}"
        ;;
    status)
        if command -v zerotier-cli >/dev/null 2>&1; then
            /usr/local/bin/zerotier-status 2>/dev/null || {
                echo "ZeroTier Status:"
                zerotier-cli info
                echo
                echo "Networks:"
                zerotier-cli listnetworks
            }
        else
            error "ZeroTier not installed"
        fi
        ;;
    *)
        echo "Usage: $0 {setup|join|leave|status}"
        echo "  setup              - Install and configure ZeroTier"
        echo "  join <network_id>  - Join a specific network"
        echo "  leave <network_id> - Leave a specific network"
        echo "  status             - Show current status"
        exit 1
        ;;
esac
