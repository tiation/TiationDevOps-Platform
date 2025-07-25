#!/bin/bash

# Universal SSH Connection Script
# Simplifies connecting to VPS instances with pre-configured settings

set -eo pipefail

# Configuration
HOSTS_FILE="${BASH_SOURCE%/*}/../config/hosts"
SSH_CONFIG_FILE="~/.ssh/config"
DEFAULT_USER="vpsuser"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to fetch host information from configuration file
get_host_info() {
    local host_alias="${1:-}"
    grep -E "^${host_alias}[\s:=]" "$HOSTS_FILE" | cut -d ':' -f2-
}

log() {
    echo -e "${GREEN}MESSAGE: $1${NC}" | tee -a /var/log/connect-script.log
}

warn() {
    echo -e "${YELLOW}WARNING: $1${NC}" | tee -a /var/log/connect-script.log
}

error() {
    echo -e "${RED}ERROR: $1${NC}" | tee -a /var/log/connect-script.log
}

# Enable SSH key forwarding
setup_ssh_forwarding() {
    local host="$1"
    local ssh_opts=()

    if grep -q "^Host ${host}.*ForwardAgent yes" "$SSH_CONFIG_FILE" 2>/dev/null; then
        return
    fi

    # Backup existing SSH config
    cp -np "$SSH_CONFIG_FILE" "$SSH_CONFIG_FILE.backup" 2>/dev/null || true

    cat << EOF >> "$SSH_CONFIG_FILE"
Host $host
    ForwardAgent yes
EOF

    log "SSH agent forwarding enabled for $host"
}

# Main connection function
connect_to_host() {
    local host_alias="$1"

    if [[ -z "$host_alias" ]]; then
        error "Usage: $0 <host_alias>"
        exit 1
    fi

    local host_info
    host_info=$(get_host_info "$host_alias")

    if [[ -z "$host_info" ]]; then
        error "Host alias '$host_alias' not found in $HOSTS_FILE"
        exit 1
    fi

    local ip
    ip=$(echo "$host_info" | awk '{print $1}')
    local port
    port=$(echo "$host_info" | awk '{print $2}')
    local user
    user="${DEFAULT_USER}"

    setup_ssh_forwarding "$host_alias"

    log "Connecting to $host_alias (IP: $ip, Port: $port) as $user..."
    ssh $SSH_OPTS -p "$port" "$user@$ip"
}

main() {
    connect_to_host "$@"
}

main "$@"
