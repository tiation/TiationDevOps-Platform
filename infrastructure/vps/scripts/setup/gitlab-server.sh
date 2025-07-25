#!/bin/bash

# GitLab Server Setup Script
# Automatically installs and configures GitLab CE with security hardening

set -euo pipefail

# Configuration
GITLAB_EXTERNAL_URL=""
GITLAB_EMAIL=""
GITLAB_SMTP_SERVER=""
GITLAB_SMTP_PORT="587"
GITLAB_SMTP_USERNAME=""
GITLAB_SMTP_PASSWORD=""
GITLAB_BACKUP_DIR="/var/opt/gitlab/backups"
GITLAB_CONFIG_DIR="/etc/gitlab"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a /var/log/gitlab-setup.log
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" | tee -a /var/log/gitlab-setup.log
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a /var/log/gitlab-setup.log
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
    fi
}

check_system_requirements() {
    log "Checking system requirements..."
    
    # Check RAM (minimum 4GB recommended)
    local ram_gb
    ram_gb=$(free -m | awk 'NR==2{printf "%.1f", $2/1024}')
    if (( $(echo "$ram_gb < 4.0" | bc -l) )); then
        warn "System has ${ram_gb}GB RAM. GitLab recommends at least 4GB for optimal performance"
    fi
    
    # Check disk space (minimum 10GB free)
    local free_space_gb
    free_space_gb=$(df / | awk 'NR==2 {printf "%.1f", $4/1024/1024}')
    if (( $(echo "$free_space_gb < 10.0" | bc -l) )); then
        error "Insufficient disk space. GitLab requires at least 10GB free space"
    fi
    
    log "System requirements check passed"
}

get_configuration() {
    log "Gathering configuration information..."
    
    # Get external URL
    while [[ -z "$GITLAB_EXTERNAL_URL" ]]; do
        echo -n "Enter GitLab external URL (e.g., https://gitlab.example.com): "
        read -r GITLAB_EXTERNAL_URL
    done
    
    # Get email configuration
    echo -n "Enter admin email address: "
    read -r GITLAB_EMAIL
    
    # SMTP configuration (optional)
    echo -n "Configure SMTP? (y/n): "
    read -r configure_smtp
    if [[ "$configure_smtp" =~ ^[Yy]$ ]]; then
        echo -n "SMTP server: "
        read -r GITLAB_SMTP_SERVER
        echo -n "SMTP port (default 587): "
        read -r smtp_port
        GITLAB_SMTP_PORT="${smtp_port:-587}"
        echo -n "SMTP username: "
        read -r GITLAB_SMTP_USERNAME
        echo -n "SMTP password: "
        read -rs GITLAB_SMTP_PASSWORD
        echo
    fi
    
    log "Configuration gathered successfully"
}

install_dependencies() {
    log "Installing dependencies..."
    
    # Update system
    apt-get update
    apt-get upgrade -y
    
    # Install required packages
    apt-get install -y curl openssh-server ca-certificates tzdata perl postfix bc
    
    # Install GitLab repository
    curl -fsSL https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | bash
    
    log "Dependencies installed successfully"
}

install_gitlab() {
    log "Installing GitLab CE..."
    
    # Set external URL for installation
    export EXTERNAL_URL="$GITLAB_EXTERNAL_URL"
    
    # Install GitLab
    apt-get install -y gitlab-ce
    
    log "GitLab CE installed successfully"
}

configure_gitlab() {
    log "Configuring GitLab..."
    
    # Backup original config
    cp "$GITLAB_CONFIG_DIR/gitlab.rb" "$GITLAB_CONFIG_DIR/gitlab.rb.backup"
    
    # Create GitLab configuration
    cat > "$GITLAB_CONFIG_DIR/gitlab.rb" << EOF
# GitLab Configuration
# Generated on $(date)

# External URL
external_url '$GITLAB_EXTERNAL_URL'

# GitLab Rails Settings
gitlab_rails['gitlab_email_enabled'] = true
gitlab_rails['gitlab_email_from'] = '$GITLAB_EMAIL'
gitlab_rails['gitlab_email_display_name'] = 'GitLab'
gitlab_rails['gitlab_email_reply_to'] = '$GITLAB_EMAIL'

# Time zone
gitlab_rails['time_zone'] = 'UTC'

# Session settings
gitlab_rails['session_expire_delay'] = 10080

# User settings
gitlab_rails['gitlab_default_can_create_group'] = false
gitlab_rails['gitlab_username_changing_enabled'] = false

# Repository settings
gitlab_rails['gitlab_default_projects_features_issues'] = true
gitlab_rails['gitlab_default_projects_features_merge_requests'] = true
gitlab_rails['gitlab_default_projects_features_wiki'] = true
gitlab_rails['gitlab_default_projects_features_snippets'] = false
gitlab_rails['gitlab_default_projects_features_builds'] = true
gitlab_rails['gitlab_default_projects_features_container_registry'] = false

# Backup settings
gitlab_rails['manage_backup_path'] = true
gitlab_rails['backup_path'] = "$GITLAB_BACKUP_DIR"
gitlab_rails['backup_archive_permissions'] = 0644
gitlab_rails['backup_keep_time'] = 604800

# Git settings
gitlab_rails['gitlab_shell_ssh_port'] = 22
gitlab_rails['git_timeout'] = 10

# Security settings
nginx['ssl_certificate'] = "/etc/ssl/certs/gitlab.crt"
nginx['ssl_certificate_key'] = "/etc/ssl/private/gitlab.key"
nginx['ssl_protocols'] = "TLSv1.2 TLSv1.3"
nginx['ssl_ciphers'] = "ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256"
nginx['ssl_prefer_server_ciphers'] = "on"
nginx['ssl_session_cache'] = "builtin:1000 shared:SSL:10m"
nginx['ssl_session_timeout'] = "5m"

# Rate limiting
gitlab_rails['rack_attack_git_basic_auth'] = {
  'enabled' => true,
  'ip_whitelist' => [],
  'maxretry' => 10,
  'findtime' => 60,
  'bantime' => 3600
}

# Monitoring
prometheus_monitoring['enable'] = true
grafana['enable'] = false

# Logging
logging['svlogd_size'] = 200 * 1024 * 1024 # rotate after 200 MB
logging['svlogd_num'] = 30 # keep 30 rotated log files
logging['svlogd_timeout'] = 24 * 60 * 60 # rotate after 24 hours
logging['svlogd_filter'] = "gzip" # compress logs
logging['svlogd_udp'] = nil
logging['svlogd_prefix'] = nil

# PostgreSQL settings
postgresql['shared_preload_libraries'] = nil
postgresql['log_statement'] = 'all'
postgresql['log_min_duration_statement'] = 1000

# Redis settings
redis['maxmemory'] = "256mb"
redis['maxmemory_policy'] = "allkeys-lru"

EOF

    # Add SMTP configuration if provided
    if [[ -n "$GITLAB_SMTP_SERVER" ]]; then
        cat >> "$GITLAB_CONFIG_DIR/gitlab.rb" << EOF

# SMTP Settings
gitlab_rails['smtp_enable'] = true
gitlab_rails['smtp_address'] = "$GITLAB_SMTP_SERVER"
gitlab_rails['smtp_port'] = $GITLAB_SMTP_PORT
gitlab_rails['smtp_user_name'] = "$GITLAB_SMTP_USERNAME"
gitlab_rails['smtp_password'] = "$GITLAB_SMTP_PASSWORD"
gitlab_rails['smtp_domain'] = "$(echo "$GITLAB_EXTERNAL_URL" | sed 's|https\?://||')"
gitlab_rails['smtp_authentication'] = "login"
gitlab_rails['smtp_enable_starttls_auto'] = true
gitlab_rails['smtp_tls'] = false
gitlab_rails['smtp_openssl_verify_mode'] = 'peer'

EOF
    fi
    
    log "GitLab configuration created"
}

setup_ssl() {
    log "Setting up SSL certificates..."
    
    # Create SSL directory
    mkdir -p /etc/ssl/certs /etc/ssl/private
    
    # Generate self-signed certificate (replace with Let's Encrypt in production)
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/ssl/private/gitlab.key \
        -out /etc/ssl/certs/gitlab.crt \
        -subj "/C=US/ST=State/L=City/O=Organization/CN=$(echo "$GITLAB_EXTERNAL_URL" | sed 's|https\?://||')"
    
    # Set permissions
    chmod 600 /etc/ssl/private/gitlab.key
    chmod 644 /etc/ssl/certs/gitlab.crt
    
    log "SSL certificates configured (using self-signed for now)"
}

configure_firewall() {
    log "Configuring firewall..."
    
    # Install UFW if not present
    apt-get install -y ufw
    
    # Configure firewall rules
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    
    # Allow SSH
    ufw allow 22/tcp
    
    # Allow HTTP/HTTPS
    ufw allow 80/tcp
    ufw allow 443/tcp
    
    # Enable firewall
    ufw --force enable
    
    log "Firewall configured successfully"
}

reconfigure_gitlab() {
    log "Reconfiguring GitLab..."
    
    # Reconfigure GitLab
    gitlab-ctl reconfigure
    
    # Start GitLab services
    gitlab-ctl start
    
    log "GitLab reconfiguration completed"
}

setup_backup_cron() {
    log "Setting up automated backups..."
    
    # Create backup directory
    mkdir -p "$GITLAB_BACKUP_DIR"
    chown git:git "$GITLAB_BACKUP_DIR"
    
    # Create backup script
    cat > /usr/local/bin/gitlab-backup << 'EOF'
#!/bin/bash

# GitLab Backup Script
set -e

LOG_FILE="/var/log/gitlab-backup.log"
BACKUP_DIR="/var/opt/gitlab/backups"
RETENTION_DAYS=7

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "Starting GitLab backup..."

# Create backup
gitlab-backup create CRON=1

# Clean old backups
find "$BACKUP_DIR" -name "*_gitlab_backup.tar" -mtime +$RETENTION_DAYS -delete

# Backup configuration files
tar -czf "$BACKUP_DIR/gitlab-config-$(date +%Y%m%d_%H%M%S).tar.gz" \
    /etc/gitlab/gitlab.rb \
    /etc/gitlab/gitlab-secrets.json 2>/dev/null || true

# Clean old config backups
find "$BACKUP_DIR" -name "gitlab-config-*.tar.gz" -mtime +$RETENTION_DAYS -delete

log "GitLab backup completed successfully"
EOF

    chmod +x /usr/local/bin/gitlab-backup
    
    # Add cron job for daily backups at 2 AM
    cat > /etc/cron.d/gitlab-backup << EOF
# GitLab backup cron job
0 2 * * * root /usr/local/bin/gitlab-backup
EOF
    
    log "Automated backups configured"
}

create_management_scripts() {
    log "Creating management scripts..."
    
    # Status script
    cat > /usr/local/bin/gitlab-status << 'EOF'
#!/bin/bash

echo "=== GitLab Status ==="
gitlab-ctl status

echo -e "\n=== GitLab Version ==="
gitlab-rake gitlab:env:info

echo -e "\n=== System Health ==="
gitlab-rake gitlab:check

echo -e "\n=== Backup Status ==="
ls -la /var/opt/gitlab/backups/ | head -10

echo -e "\n=== Recent Logs ==="
tail -20 /var/log/gitlab/gitlab-rails/production.log 2>/dev/null || echo "No production log found"
EOF

    # Maintenance script
    cat > /usr/local/bin/gitlab-maintenance << 'EOF'
#!/bin/bash

set -e

ACTION="${1:-}"

case "$ACTION" in
    start)
        echo "Starting GitLab maintenance mode..."
        gitlab-ctl deploy-page up
        echo "Maintenance mode enabled"
        ;;
    stop)
        echo "Stopping GitLab maintenance mode..."
        gitlab-ctl deploy-page down
        echo "Maintenance mode disabled"
        ;;
    backup)
        echo "Creating manual backup..."
        /usr/local/bin/gitlab-backup
        echo "Backup completed"
        ;;
    restore)
        if [[ -z "${2:-}" ]]; then
            echo "Usage: $0 restore <backup_timestamp>"
            echo "Available backups:"
            ls /var/opt/gitlab/backups/*_gitlab_backup.tar 2>/dev/null | sed 's/.*\///' | sed 's/_gitlab_backup.tar//' || echo "No backups found"
            exit 1
        fi
        echo "Restoring from backup: $2"
        gitlab-ctl stop unicorn
        gitlab-ctl stop puma
        gitlab-ctl stop sidekiq
        gitlab-backup restore BACKUP="$2"
        gitlab-ctl restart
        echo "Restore completed"
        ;;
    update)
        echo "Updating GitLab..."
        apt-get update
        apt-get install -y gitlab-ce
        gitlab-ctl reconfigure
        echo "Update completed"
        ;;
    *)
        echo "Usage: $0 {start|stop|backup|restore|update}"
        echo "  start     - Enable maintenance mode"
        echo "  stop      - Disable maintenance mode"
        echo "  backup    - Create manual backup"
        echo "  restore   - Restore from backup"
        echo "  update    - Update GitLab"
        exit 1
        ;;
esac
EOF

    chmod +x /usr/local/bin/gitlab-status
    chmod +x /usr/local/bin/gitlab-maintenance
    
    log "Management scripts created"
}

setup_monitoring() {
    log "Setting up monitoring..."
    
    # Create monitoring script
    cat > /usr/local/bin/gitlab-monitor << 'EOF'
#!/bin/bash

# GitLab Health Monitoring Script
set -e

LOG_FILE="/var/log/gitlab-monitor.log"
ALERT_EMAIL="${GITLAB_EMAIL:-root@localhost}"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

send_alert() {
    local subject="$1"
    local message="$2"
    echo "$message" | mail -s "$subject" "$ALERT_EMAIL" 2>/dev/null || true
    log "ALERT: $subject - $message"
}

# Check GitLab services
if ! gitlab-ctl status | grep -q "run:"; then
    send_alert "GitLab Services Down" "One or more GitLab services are not running"
fi

# Check disk space
DISK_USAGE=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
if [[ $DISK_USAGE -gt 85 ]]; then
    send_alert "High Disk Usage" "Disk usage is at ${DISK_USAGE}%"
fi

# Check memory usage
MEM_USAGE=$(free | awk 'NR==2{printf "%.2f", $3*100/$2}')
if (( $(echo "$MEM_USAGE > 90" | bc -l) )); then
    send_alert "High Memory Usage" "Memory usage is at ${MEM_USAGE}%"
fi

# Check GitLab health
if ! timeout 30 gitlab-rake gitlab:check SANITIZE=true > /dev/null 2>&1; then
    send_alert "GitLab Health Check Failed" "GitLab health check is failing"
fi

log "Health check completed"
EOF

    chmod +x /usr/local/bin/gitlab-monitor
    
    # Add monitoring cron job every 5 minutes
    cat > /etc/cron.d/gitlab-monitor << EOF
# GitLab monitoring cron job
*/5 * * * * root /usr/local/bin/gitlab-monitor
EOF
    
    log "Monitoring configured"
}

get_initial_password() {
    log "Retrieving initial root password..."
    
    local password_file="/etc/gitlab/initial_root_password"
    if [[ -f "$password_file" ]]; then
        local password
        password=$(grep -E "^Password:" "$password_file" | awk '{print $2}')
        echo -e "\n${YELLOW}=== Initial Root Password ===${NC}"
        echo -e "${BLUE}Username:${NC} root"
        echo -e "${BLUE}Password:${NC} $password"
        echo -e "${YELLOW}Please change this password after first login!${NC}\n"
    else
        warn "Initial password file not found. Check GitLab logs for the generated password."
    fi
}

print_summary() {
    echo -e "\n${GREEN}=== GitLab Server Setup Complete ===${NC}"
    echo -e "${BLUE}GitLab URL:${NC} $GITLAB_EXTERNAL_URL"
    echo -e "${BLUE}Admin Email:${NC} $GITLAB_EMAIL"
    echo -e "${BLUE}Backup Directory:${NC} $GITLAB_BACKUP_DIR"
    echo
    echo -e "${YELLOW}Management Commands:${NC}"
    echo -e "  ${BLUE}gitlab-status${NC}           - View GitLab status and health"
    echo -e "  ${BLUE}gitlab-maintenance start${NC} - Enable maintenance mode"
    echo -e "  ${BLUE}gitlab-maintenance stop${NC}  - Disable maintenance mode"
    echo -e "  ${BLUE}gitlab-maintenance backup${NC} - Create manual backup"
    echo -e "  ${BLUE}gitlab-maintenance update${NC} - Update GitLab"
    echo -e "  ${BLUE}gitlab-ctl reconfigure${NC}   - Reconfigure GitLab"
    echo -e "  ${BLUE}gitlab-ctl restart${NC}       - Restart all services"
    echo
    echo -e "${YELLOW}Important Files:${NC}"
    echo -e "  Configuration: ${BLUE}$GITLAB_CONFIG_DIR/gitlab.rb${NC}"
    echo -e "  Secrets: ${BLUE}$GITLAB_CONFIG_DIR/gitlab-secrets.json${NC}"
    echo -e "  Logs: ${BLUE}/var/log/gitlab/${NC}"
    echo
    echo -e "${YELLOW}Next Steps:${NC}"
    echo -e "  1. Access GitLab at: ${BLUE}$GITLAB_EXTERNAL_URL${NC}"
    echo -e "  2. Login with username: ${BLUE}root${NC}"
    echo -e "  3. Change the default password"
    echo -e "  4. Configure LDAP/OAuth if needed"
    echo -e "  5. Set up Let's Encrypt for production SSL"
    echo -e "  6. Configure email notifications"
}

main() {
    log "Starting GitLab server setup..."
    
    check_root
    check_system_requirements
    get_configuration
    install_dependencies
    install_gitlab
    configure_gitlab
    setup_ssl
    configure_firewall
    reconfigure_gitlab
    setup_backup_cron
    create_management_scripts
    setup_monitoring
    get_initial_password
    
    print_summary
    
    log "GitLab server setup completed successfully"
}

# Run main function
main "$@"
