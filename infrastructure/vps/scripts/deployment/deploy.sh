#!/bin/bash

# Automated Deployment Script
# Handles application deployment with health checks, rollbacks, and monitoring

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/deployment.conf"
HOSTS_FILE="${SCRIPT_DIR}/../config/hosts"

# Default configuration
DEPLOYMENT_USER="deploy"
DEPLOYMENT_PATH="/opt/applications"
BACKUP_PATH="/opt/backups"
LOG_FILE="/var/log/deployment.log"
HEALTH_CHECK_TIMEOUT=300
ROLLBACK_ENABLED=true
NOTIFY_ON_SUCCESS=true
NOTIFY_ON_FAILURE=true

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Load configuration if exists
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
}

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

log_info() {
    log "INFO" "$@"
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    log "WARN" "$@"
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    log "ERROR" "$@"
    echo -e "${RED}[ERROR]${NC} $*"
}

log_success() {
    log "SUCCESS" "$@"
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

# Send notification
send_notification() {
    local subject="$1"
    local message="$2"
    local status="${3:-INFO}"
    
    # Use the monitoring system's alert function if available
    local monitor_script="${SCRIPT_DIR}/../monitoring/system-monitor.sh"
    if [[ -f "$monitor_script" ]]; then
        "$monitor_script" send-alert "$subject" "$message" "$status" || true
    fi
    
    # Also log the notification
    log_info "NOTIFICATION: $subject - $message"
}

# Get host information
get_host_info() {
    local host_alias="$1"
    if [[ -f "$HOSTS_FILE" ]]; then
        grep -E "^${host_alias}:" "$HOSTS_FILE" 2>/dev/null | cut -d':' -f2- | tr -d ' '
    fi
}

# Check if host is reachable
check_host_connectivity() {
    local host="$1"
    local port="${2:-22}"
    
    log_info "Checking connectivity to $host:$port..."
    
    if timeout 10 nc -z "$host" "$port" 2>/dev/null; then
        log_success "Host $host:$port is reachable"
        return 0
    else
        log_error "Host $host:$port is not reachable"
        return 1
    fi
}

# Execute command on remote host
remote_exec() {
    local host="$1"
    local command="$2"
    local user="${3:-$DEPLOYMENT_USER}"
    
    log_info "Executing on $host: $command"
    
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        "$user@$host" "$command"
}

# Transfer files to remote host
transfer_files() {
    local source="$1"
    local host="$2"
    local destination="$3"
    local user="${4:-$DEPLOYMENT_USER}"
    
    log_info "Transferring $source to $user@$host:$destination"
    
    rsync -avz --progress \
          -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
          "$source" "$user@$host:$destination"
}

# Create backup before deployment
create_backup() {
    local host="$1"
    local app_name="$2"
    local backup_name="${app_name}-$(date +%Y%m%d-%H%M%S)"
    
    log_info "Creating backup: $backup_name"
    
    remote_exec "$host" "
        mkdir -p $BACKUP_PATH
        if [[ -d $DEPLOYMENT_PATH/$app_name ]]; then
            tar -czf $BACKUP_PATH/$backup_name.tar.gz -C $DEPLOYMENT_PATH $app_name
            echo 'Backup created: $backup_name.tar.gz'
        else
            echo 'No existing deployment found, skipping backup'
        fi
    "
    
    echo "$backup_name"
}

# Deploy application
deploy_application() {
    local host="$1"
    local app_name="$2"
    local source_path="$3"
    local deploy_script="${4:-}"
    
    log_info "Deploying $app_name to $host"
    
    # Ensure deployment directory exists
    remote_exec "$host" "mkdir -p $DEPLOYMENT_PATH"
    
    # Transfer application files
    transfer_files "$source_path" "$host" "$DEPLOYMENT_PATH/$app_name"
    
    # Make deployment script executable if provided
    if [[ -n "$deploy_script" ]]; then
        remote_exec "$host" "chmod +x $DEPLOYMENT_PATH/$app_name/$deploy_script"
    fi
    
    # Run deployment script
    if [[ -n "$deploy_script" ]]; then
        log_info "Running deployment script: $deploy_script"
        remote_exec "$host" "cd $DEPLOYMENT_PATH/$app_name && ./$deploy_script"
    fi
    
    log_success "Application deployed successfully"
}

# Health check
perform_health_check() {
    local host="$1"
    local app_name="$2"
    local health_check_url="${3:-}"
    local health_check_command="${4:-}"
    
    log_info "Performing health check for $app_name on $host"
    
    local start_time
    start_time=$(date +%s)
    local timeout_time=$((start_time + HEALTH_CHECK_TIMEOUT))
    
    while [[ $(date +%s) -lt $timeout_time ]]; do
        local health_ok=false
        
        # URL-based health check
        if [[ -n "$health_check_url" ]]; then
            if curl -f -s "$health_check_url" >/dev/null 2>&1; then
                health_ok=true
            fi
        fi
        
        # Command-based health check
        if [[ -n "$health_check_command" ]]; then
            if remote_exec "$host" "$health_check_command" >/dev/null 2>&1; then
                health_ok=true
            fi
        fi
        
        # Default process check
        if [[ -z "$health_check_url" && -z "$health_check_command" ]]; then
            if remote_exec "$host" "pgrep -f $app_name" >/dev/null 2>&1; then
                health_ok=true
            fi
        fi
        
        if [[ "$health_ok" == "true" ]]; then
            log_success "Health check passed for $app_name"
            return 0
        fi
        
        log_info "Health check failed, retrying in 10 seconds..."
        sleep 10
    done
    
    log_error "Health check failed for $app_name after $HEALTH_CHECK_TIMEOUT seconds"
    return 1
}

# Rollback deployment
rollback_deployment() {
    local host="$1"
    local app_name="$2"
    local backup_name="$3"
    
    log_warn "Rolling back deployment for $app_name"
    
    # Stop current application
    remote_exec "$host" "
        cd $DEPLOYMENT_PATH
        if [[ -f $app_name/stop.sh ]]; then
            ./$app_name/stop.sh || true
        fi
        pkill -f $app_name || true
    " || true
    
    # Remove failed deployment
    remote_exec "$host" "rm -rf $DEPLOYMENT_PATH/$app_name" || true
    
    # Restore from backup
    if [[ -n "$backup_name" ]]; then
        remote_exec "$host" "
            cd $DEPLOYMENT_PATH
            if [[ -f $BACKUP_PATH/$backup_name.tar.gz ]]; then
                tar -xzf $BACKUP_PATH/$backup_name.tar.gz
                echo 'Rollback completed from backup: $backup_name'
            else
                echo 'Backup not found: $backup_name'
            fi
        "
        
        # Restart application from backup
        remote_exec "$host" "
            cd $DEPLOYMENT_PATH/$app_name
            if [[ -f start.sh ]]; then
                ./start.sh
            fi
        " || true
    fi
    
    log_success "Rollback completed"
}

# Cleanup old backups
cleanup_backups() {
    local host="$1"
    local app_name="$2"
    local retention_days="${3:-30}"
    
    log_info "Cleaning up backups older than $retention_days days"
    
    remote_exec "$host" "
        find $BACKUP_PATH -name '${app_name}-*.tar.gz' -mtime +$retention_days -delete
        echo 'Backup cleanup completed'
    " || true
}

# Main deployment function
deploy() {
    local host_alias="$1"
    local app_name="$2"
    local source_path="$3"
    local deploy_script="${4:-deploy.sh}"
    local health_check_url="${5:-}"
    local health_check_command="${6:-}"
    
    # Validate inputs
    if [[ -z "$host_alias" || -z "$app_name" || -z "$source_path" ]]; then
        log_error "Usage: $0 deploy <host_alias> <app_name> <source_path> [deploy_script] [health_check_url] [health_check_command]"
        return 1
    fi
    
    # Check if source path exists
    if [[ ! -d "$source_path" ]]; then
        log_error "Source path does not exist: $source_path"
        return 1
    fi
    
    # Get host information
    local host_info
    host_info=$(get_host_info "$host_alias")
    if [[ -z "$host_info" ]]; then
        log_error "Host alias not found: $host_alias"
        return 1
    fi
    
    local host
    host=$(echo "$host_info" | awk '{print $1}')
    
    # Check connectivity
    if ! check_host_connectivity "$host"; then
        log_error "Cannot connect to host: $host"
        return 1
    fi
    
    local backup_name=""
    local deployment_successful=false
    
    # Send deployment start notification
    if [[ "$NOTIFY_ON_SUCCESS" == "true" || "$NOTIFY_ON_FAILURE" == "true" ]]; then
        send_notification "Deployment Started" "Starting deployment of $app_name to $host_alias" "INFO"
    fi
    
    # Create backup
    backup_name=$(create_backup "$host" "$app_name")
    
    # Deploy application
    if deploy_application "$host" "$app_name" "$source_path" "$deploy_script"; then
        log_success "Deployment completed"
        
        # Perform health check
        if perform_health_check "$host" "$app_name" "$health_check_url" "$health_check_command"; then
            deployment_successful=true
            log_success "Deployment successful and healthy"
            
            # Send success notification
            if [[ "$NOTIFY_ON_SUCCESS" == "true" ]]; then
                send_notification "Deployment Successful" "$app_name deployed successfully to $host_alias" "SUCCESS"
            fi
        else
            log_error "Health check failed"
            
            # Rollback if enabled
            if [[ "$ROLLBACK_ENABLED" == "true" ]]; then
                rollback_deployment "$host" "$app_name" "$backup_name"
                
                # Send rollback notification
                if [[ "$NOTIFY_ON_FAILURE" == "true" ]]; then
                    send_notification "Deployment Failed - Rolled Back" "Health check failed for $app_name on $host_alias. Rolled back to previous version." "ERROR"
                fi
            else
                # Send failure notification
                if [[ "$NOTIFY_ON_FAILURE" == "true" ]]; then
                    send_notification "Deployment Failed" "Health check failed for $app_name on $host_alias. Rollback disabled." "ERROR"
                fi
            fi
            
            return 1
        fi
    else
        log_error "Deployment failed"
        
        # Rollback if enabled
        if [[ "$ROLLBACK_ENABLED" == "true" ]]; then
            rollback_deployment "$host" "$app_name" "$backup_name"
        fi
        
        # Send failure notification
        if [[ "$NOTIFY_ON_FAILURE" == "true" ]]; then
            send_notification "Deployment Failed" "Deployment of $app_name to $host_alias failed" "ERROR"
        fi
        
        return 1
    fi
    
    # Cleanup old backups
    cleanup_backups "$host" "$app_name"
    
    return 0
}

# List deployments
list_deployments() {
    local host_alias="$1"
    
    if [[ -z "$host_alias" ]]; then
        log_error "Usage: $0 list <host_alias>"
        return 1
    fi
    
    local host_info
    host_info=$(get_host_info "$host_alias")
    if [[ -z "$host_info" ]]; then
        log_error "Host alias not found: $host_alias"
        return 1
    fi
    
    local host
    host=$(echo "$host_info" | awk '{print $1}')
    
    echo -e "\n${BLUE}=== Deployments on $host_alias ($host) ===${NC}"
    
    remote_exec "$host" "
        if [[ -d $DEPLOYMENT_PATH ]]; then
            cd $DEPLOYMENT_PATH
            for app in */; do
                if [[ -d \"\$app\" ]]; then
                    echo \"Application: \${app%/}\"
                    echo \"  Path: $DEPLOYMENT_PATH/\$app\"
                    echo \"  Modified: \$(stat -c '%y' \"\$app\")\"
                    echo \"  Size: \$(du -sh \"\$app\" | cut -f1)\"
                    echo
                fi
            done
        else
            echo 'No deployments found'
        fi
    "
}

# List backups
list_backups() {
    local host_alias="$1"
    local app_name="${2:-}"
    
    if [[ -z "$host_alias" ]]; then
        log_error "Usage: $0 backups <host_alias> [app_name]"
        return 1
    fi
    
    local host_info
    host_info=$(get_host_info "$host_alias")
    if [[ -z "$host_info" ]]; then
        log_error "Host alias not found: $host_alias"
        return 1
    fi
    
    local host
    host=$(echo "$host_info" | awk '{print $1}')
    
    echo -e "\n${BLUE}=== Backups on $host_alias ($host) ===${NC}"
    
    local backup_filter="*"
    if [[ -n "$app_name" ]]; then
        backup_filter="${app_name}-*"
    fi
    
    remote_exec "$host" "
        if [[ -d $BACKUP_PATH ]]; then
            cd $BACKUP_PATH
            ls -la $backup_filter.tar.gz 2>/dev/null || echo 'No backups found'
        else
            echo 'Backup directory does not exist'
        fi
    "
}

# Show usage
show_usage() {
    cat << EOF
Usage: $0 <command> [arguments]

Commands:
  deploy <host_alias> <app_name> <source_path> [deploy_script] [health_check_url] [health_check_command]
    Deploy application to specified host
    
  list <host_alias>
    List all deployments on specified host
    
  backups <host_alias> [app_name]
    List backups on specified host (optionally filtered by app name)
    
  rollback <host_alias> <app_name> <backup_name>
    Manually rollback to specific backup
    
  health <host_alias> <app_name> [health_check_url] [health_check_command]
    Run health check for deployed application

Examples:
  $0 deploy web-server myapp /path/to/app deploy.sh http://localhost:8080/health
  $0 list web-server
  $0 backups web-server myapp
  $0 rollback web-server myapp myapp-20231225-143000

Configuration:
  Edit $CONFIG_FILE to customize deployment settings
  Edit $HOSTS_FILE to define host aliases

EOF
}

# Main function
main() {
    local command="${1:-}"
    
    case "$command" in
        deploy)
            load_config
            deploy "${@:2}"
            ;;
        list)
            list_deployments "${2:-}"
            ;;
        backups)
            list_backups "${2:-}" "${3:-}"
            ;;
        rollback)
            if [[ $# -lt 4 ]]; then
                log_error "Usage: $0 rollback <host_alias> <app_name> <backup_name>"
                exit 1
            fi
            load_config
            local host_info
            host_info=$(get_host_info "$2")
            local host
            host=$(echo "$host_info" | awk '{print $1}')
            rollback_deployment "$host" "$3" "$4"
            ;;
        health)
            if [[ $# -lt 3 ]]; then
                log_error "Usage: $0 health <host_alias> <app_name> [health_check_url] [health_check_command]"
                exit 1
            fi
            load_config
            local host_info
            host_info=$(get_host_info "$2")
            local host
            host=$(echo "$host_info" | awk '{print $1}')
            perform_health_check "$host" "$3" "${4:-}" "${5:-}"
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            show_usage
            exit 1
            ;;
    esac
}

# Install signal handlers for graceful shutdown
trap 'log_info "Deployment script interrupted"; exit 130' INT TERM

# Run main function
main "$@"
