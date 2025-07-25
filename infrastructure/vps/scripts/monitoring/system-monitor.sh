#!/bin/bash

# Comprehensive VPS Monitoring System
# Monitors system health, services, and sends alerts when thresholds are exceeded

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/monitoring.conf"
LOG_FILE="/var/log/system-monitor.log"
METRICS_FILE="/var/log/system-metrics.json"
STATE_FILE="/var/run/system-monitor.state"

# Default thresholds (can be overridden in config file)
CPU_THRESHOLD=80
MEMORY_THRESHOLD=85
DISK_THRESHOLD=85
LOAD_THRESHOLD=5.0
TEMP_THRESHOLD=70
NETWORK_ERROR_THRESHOLD=100

# Alert configuration
ALERT_EMAIL=""
SLACK_WEBHOOK=""
DISCORD_WEBHOOK=""
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

# Service monitoring
MONITOR_SERVICES=("ssh" "nginx" "apache2" "mysql" "postgresql" "redis" "openvpn" "gitlab")

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
}

log_warn() {
    log "WARN" "$@"
}

log_error() {
    log "ERROR" "$@"
}

# Check if running as root for certain operations
check_privileges() {
    if [[ $EUID -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

# Get system information
get_system_info() {
    local hostname
    local uptime
    local kernel
    local distribution
    
    hostname=$(hostname -f 2>/dev/null || hostname)
    uptime=$(uptime -p 2>/dev/null || echo "Unknown")
    kernel=$(uname -r)
    
    if [[ -f /etc/os-release ]]; then
        distribution=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d'"' -f2)
    else
        distribution="Unknown"
    fi
    
    cat << EOF
{
    "hostname": "$hostname",
    "uptime": "$uptime",
    "kernel": "$kernel",
    "distribution": "$distribution",
    "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF
}

# Monitor CPU usage
monitor_cpu() {
    local cpu_usage
    local load_avg
    local core_count
    
    # Get CPU usage percentage
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | sed 's/%us,//' | sed 's/,//')
    if [[ -z "$cpu_usage" ]]; then
        cpu_usage=$(grep 'cpu ' /proc/stat | awk '{usage=($2+$4)*100/($2+$3+$4+$5)} END {print usage}')
    fi
    
    # Get load average
    load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    
    # Get core count
    core_count=$(nproc)
    
    # Round CPU usage to 2 decimal places
    cpu_usage=$(printf "%.2f" "$cpu_usage")
    
    cat << EOF
{
    "cpu_usage_percent": $cpu_usage,
    "load_average_1min": $load_avg,
    "core_count": $core_count,
    "status": "$([[ $(echo "$cpu_usage > $CPU_THRESHOLD" | bc -l) -eq 1 ]] && echo "WARNING" || echo "OK")"
}
EOF

    # Alert if CPU usage is high
    if [[ $(echo "$cpu_usage > $CPU_THRESHOLD" | bc -l) -eq 1 ]]; then
        send_alert "HIGH CPU USAGE" "CPU usage is at ${cpu_usage}% (threshold: ${CPU_THRESHOLD}%)"
    fi
}

# Monitor memory usage
monitor_memory() {
    local mem_info
    local total_mem
    local used_mem
    local free_mem
    local cached_mem
    local available_mem
    local usage_percent
    local swap_total
    local swap_used
    local swap_free
    
    mem_info=$(free -m)
    total_mem=$(echo "$mem_info" | awk 'NR==2{print $2}')
    used_mem=$(echo "$mem_info" | awk 'NR==2{print $3}')
    free_mem=$(echo "$mem_info" | awk 'NR==2{print $4}')
    cached_mem=$(echo "$mem_info" | awk 'NR==2{print $6}')
    available_mem=$(echo "$mem_info" | awk 'NR==2{print $7}')
    
    # Calculate usage percentage
    usage_percent=$(echo "scale=2; $used_mem * 100 / $total_mem" | bc)
    
    # Get swap information
    swap_total=$(echo "$mem_info" | awk 'NR==3{print $2}')
    swap_used=$(echo "$mem_info" | awk 'NR==3{print $3}')
    swap_free=$(echo "$mem_info" | awk 'NR==3{print $4}')
    
    cat << EOF
{
    "total_mb": $total_mem,
    "used_mb": $used_mem,
    "free_mb": $free_mem,
    "cached_mb": $cached_mem,
    "available_mb": $available_mem,
    "usage_percent": $usage_percent,
    "swap_total_mb": $swap_total,
    "swap_used_mb": $swap_used,
    "swap_free_mb": $swap_free,
    "status": "$([[ $(echo "$usage_percent > $MEMORY_THRESHOLD" | bc -l) -eq 1 ]] && echo "WARNING" || echo "OK")"
}
EOF

    # Alert if memory usage is high
    if [[ $(echo "$usage_percent > $MEMORY_THRESHOLD" | bc -l) -eq 1 ]]; then
        send_alert "HIGH MEMORY USAGE" "Memory usage is at ${usage_percent}% (threshold: ${MEMORY_THRESHOLD}%)"
    fi
}

# Monitor disk usage
monitor_disk() {
    local disk_data=()
    local alert_disks=()
    
    # Get disk usage for all mounted filesystems
    while IFS= read -r line; do
        local filesystem usage_percent mount_point
        filesystem=$(echo "$line" | awk '{print $1}')
        usage_percent=$(echo "$line" | awk '{print $5}' | sed 's/%//')
        mount_point=$(echo "$line" | awk '{print $6}')
        
        # Skip special filesystems
        if [[ "$filesystem" =~ ^(tmpfs|devtmpfs|udev|proc|sys|run) ]]; then
            continue
        fi
        
        disk_data+=("{\"filesystem\": \"$filesystem\", \"usage_percent\": $usage_percent, \"mount_point\": \"$mount_point\", \"status\": \"$([[ $usage_percent -gt $DISK_THRESHOLD ]] && echo "WARNING" || echo "OK")\"}")
        
        # Check for high usage
        if [[ $usage_percent -gt $DISK_THRESHOLD ]]; then
            alert_disks+=("$mount_point (${usage_percent}%)")
        fi
    done < <(df -h | grep -E '^/dev/')
    
    # Join disk data with commas
    local disk_json
    disk_json=$(IFS=','; echo "[${disk_data[*]}]")
    
    echo "$disk_json"
    
    # Send alert if any disk is over threshold
    if [[ ${#alert_disks[@]} -gt 0 ]]; then
        local alert_message="High disk usage detected: $(IFS=', '; echo "${alert_disks[*]}")"
        send_alert "HIGH DISK USAGE" "$alert_message"
    fi
}

# Monitor network interfaces
monitor_network() {
    local interfaces=()
    local network_errors=0
    
    # Get network interface statistics
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*([^:]+): ]]; then
            local interface="${BASH_REMATCH[1]}"
            
            # Skip loopback interface
            if [[ "$interface" == "lo" ]]; then
                continue
            fi
            
            # Get interface statistics
            local rx_bytes rx_packets rx_errors tx_bytes tx_packets tx_errors
            read -r rx_bytes rx_packets rx_errors _ _ _ _ _ tx_bytes tx_packets tx_errors _ <<< "$line"
            
            # Calculate total errors
            local total_errors=$((rx_errors + tx_errors))
            network_errors=$((network_errors + total_errors))
            
            interfaces+=("{\"interface\": \"$interface\", \"rx_bytes\": $rx_bytes, \"tx_bytes\": $tx_bytes, \"rx_errors\": $rx_errors, \"tx_errors\": $tx_errors}")
        fi
    done < /proc/net/dev
    
    # Join interface data
    local network_json
    network_json=$(IFS=','; echo "[${interfaces[*]}]")
    
    cat << EOF
{
    "interfaces": $network_json,
    "total_errors": $network_errors,
    "status": "$([[ $network_errors -gt $NETWORK_ERROR_THRESHOLD ]] && echo "WARNING" || echo "OK")"
}
EOF

    # Alert on high network errors
    if [[ $network_errors -gt $NETWORK_ERROR_THRESHOLD ]]; then
        send_alert "HIGH NETWORK ERRORS" "Network error count is $network_errors (threshold: $NETWORK_ERROR_THRESHOLD)"
    fi
}

# Monitor system temperature (if available)
monitor_temperature() {
    local temperatures=()
    local max_temp=0
    
    # Check if thermal sensors are available
    if command -v sensors >/dev/null 2>&1; then
        while IFS= read -r line; do
            if [[ "$line" =~ ([0-9]+\.[0-9]+)°C ]]; then
                local temp="${BASH_REMATCH[1]}"
                temperatures+=("$temp")
                
                # Track maximum temperature
                if (( $(echo "$temp > $max_temp" | bc -l) )); then
                    max_temp="$temp"
                fi
            fi
        done < <(sensors 2>/dev/null)
    fi
    
    # If no sensors command, try reading from thermal zones
    if [[ ${#temperatures[@]} -eq 0 ]] && [[ -d /sys/class/thermal ]]; then
        for thermal_zone in /sys/class/thermal/thermal_zone*/temp; do
            if [[ -r "$thermal_zone" ]]; then
                local temp_millicelsius
                temp_millicelsius=$(cat "$thermal_zone")
                local temp_celsius=$((temp_millicelsius / 1000))
                temperatures+=("$temp_celsius")
                
                if [[ $temp_celsius -gt $max_temp ]]; then
                    max_temp=$temp_celsius
                fi
            fi
        done
    fi
    
    cat << EOF
{
    "temperatures": [$(IFS=','; echo "${temperatures[*]}")],
    "max_temperature": $max_temp,
    "status": "$([[ $(echo "$max_temp > $TEMP_THRESHOLD" | bc -l) -eq 1 ]] && echo "WARNING" || echo "OK")"
}
EOF

    # Alert on high temperature
    if [[ $(echo "$max_temp > $TEMP_THRESHOLD" | bc -l) -eq 1 ]]; then
        send_alert "HIGH TEMPERATURE" "Maximum system temperature is ${max_temp}°C (threshold: ${TEMP_THRESHOLD}°C)"
    fi
}

# Monitor system services
monitor_services() {
    local services=()
    local failed_services=()
    
    for service in "${MONITOR_SERVICES[@]}"; do
        local status="unknown"
        local active="false"
        
        if systemctl is-active "$service" >/dev/null 2>&1; then
            status="active"
            active="true"
        elif systemctl list-unit-files | grep -q "^${service}.service"; then
            status="inactive"
            failed_services+=("$service")
        fi
        
        services+=("{\"name\": \"$service\", \"status\": \"$status\", \"active\": $active}")
    done
    
    # Join service data
    local services_json
    services_json=$(IFS=','; echo "[${services[*]}]")
    
    cat << EOF
{
    "services": $services_json,
    "failed_count": ${#failed_services[@]},
    "status": "$([[ ${#failed_services[@]} -gt 0 ]] && echo "WARNING" || echo "OK")"
}
EOF

    # Alert on failed services
    if [[ ${#failed_services[@]} -gt 0 ]]; then
        local alert_message="Services not running: $(IFS=', '; echo "${failed_services[*]}")"
        send_alert "SERVICE FAILURES" "$alert_message"
    fi
}

# Check for security updates
check_security_updates() {
    local updates_available=0
    local security_updates=0
    
    if command -v apt >/dev/null 2>&1; then
        # Update package lists
        if check_privileges; then
            apt update >/dev/null 2>&1 || true
        fi
        
        # Count available updates
        updates_available=$(apt list --upgradable 2>/dev/null | grep -c upgradable || echo 0)
        
        # Count security updates
        security_updates=$(apt list --upgradable 2>/dev/null | grep -i security | wc -l || echo 0)
        
    elif command -v yum >/dev/null 2>&1; then
        updates_available=$(yum check-update 2>/dev/null | grep -E '^\w' | wc -l || echo 0)
        security_updates=$(yum --security check-update 2>/dev/null | grep -E '^\w' | wc -l || echo 0)
    fi
    
    cat << EOF
{
    "updates_available": $updates_available,
    "security_updates": $security_updates,
    "status": "$([[ $security_updates -gt 0 ]] && echo "WARNING" || echo "OK")"
}
EOF

    # Alert on security updates
    if [[ $security_updates -gt 0 ]]; then
        send_alert "SECURITY UPDATES AVAILABLE" "$security_updates security updates are available for installation"
    fi
}

# Send alert via email
send_email_alert() {
    local subject="$1"
    local message="$2"
    
    if [[ -n "$ALERT_EMAIL" ]] && command -v mail >/dev/null 2>&1; then
        echo "$message" | mail -s "[$HOSTNAME] $subject" "$ALERT_EMAIL" 2>/dev/null || true
    fi
}

# Send alert via Slack
send_slack_alert() {
    local subject="$1"
    local message="$2"
    
    if [[ -n "$SLACK_WEBHOOK" ]]; then
        local payload
        payload=$(cat << EOF
{
    "text": "🚨 *Alert from $HOSTNAME*",
    "attachments": [
        {
            "color": "danger",
            "title": "$subject",
            "text": "$message",
            "footer": "System Monitor",
            "ts": $(date +%s)
        }
    ]
}
EOF
)
        curl -X POST -H 'Content-type: application/json' \
             --data "$payload" \
             "$SLACK_WEBHOOK" >/dev/null 2>&1 || true
    fi
}

# Send alert via Discord
send_discord_alert() {
    local subject="$1"
    local message="$2"
    
    if [[ -n "$DISCORD_WEBHOOK" ]]; then
        local payload
        payload=$(cat << EOF
{
    "embeds": [
        {
            "title": "🚨 Alert from $HOSTNAME",
            "description": "**$subject**\n\n$message",
            "color": 15158332,
            "footer": {
                "text": "System Monitor"
            },
            "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        }
    ]
}
EOF
)
        curl -X POST -H 'Content-type: application/json' \
             --data "$payload" \
             "$DISCORD_WEBHOOK" >/dev/null 2>&1 || true
    fi
}

# Send alert via Telegram
send_telegram_alert() {
    local subject="$1"
    local message="$2"
    
    if [[ -n "$TELEGRAM_BOT_TOKEN" ]] && [[ -n "$TELEGRAM_CHAT_ID" ]]; then
        local text="🚨 *Alert from $HOSTNAME*\n\n*$subject*\n\n$message"
        local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
        
        curl -X POST "$url" \
             -d "chat_id=$TELEGRAM_CHAT_ID" \
             -d "text=$text" \
             -d "parse_mode=Markdown" >/dev/null 2>&1 || true
    fi
}

# Main alert function
send_alert() {
    local subject="$1"
    local message="$2"
    local alert_key="${subject// /_}"
    local current_time
    current_time=$(date +%s)
    
    # Check if we've recently sent this alert (prevent spam)
    if [[ -f "$STATE_FILE" ]]; then
        local last_alert_time
        last_alert_time=$(grep "^${alert_key}:" "$STATE_FILE" 2>/dev/null | cut -d: -f2 || echo 0)
        
        # Don't send alert if sent within last 30 minutes
        if [[ $((current_time - last_alert_time)) -lt 1800 ]]; then
            return 0
        fi
    fi
    
    # Update state file
    touch "$STATE_FILE"
    sed -i "/^${alert_key}:/d" "$STATE_FILE" 2>/dev/null || true
    echo "${alert_key}:${current_time}" >> "$STATE_FILE"
    
    # Send alerts
    log_warn "ALERT: $subject - $message"
    send_email_alert "$subject" "$message"
    send_slack_alert "$subject" "$message"
    send_discord_alert "$subject" "$message"
    send_telegram_alert "$subject" "$message"
}

# Generate metrics report
generate_metrics() {
    local system_info cpu_metrics memory_metrics disk_metrics network_metrics temperature_metrics service_metrics security_metrics
    
    log_info "Collecting system metrics..."
    
    system_info=$(get_system_info)
    cpu_metrics=$(monitor_cpu)
    memory_metrics=$(monitor_memory)
    disk_metrics=$(monitor_disk)
    network_metrics=$(monitor_network)
    temperature_metrics=$(monitor_temperature)
    service_metrics=$(monitor_services)
    security_metrics=$(check_security_updates)
    
    cat << EOF > "$METRICS_FILE"
{
    "system": $system_info,
    "cpu": $cpu_metrics,
    "memory": $memory_metrics,
    "disk": $disk_metrics,
    "network": $network_metrics,
    "temperature": $temperature_metrics,
    "services": $service_metrics,
    "security": $security_metrics
}
EOF
    
    log_info "Metrics saved to $METRICS_FILE"
}

# Display current status
show_status() {
    if [[ ! -f "$METRICS_FILE" ]]; then
        echo -e "${RED}No metrics file found. Run monitoring first.${NC}"
        return 1
    fi
    
    local metrics
    metrics=$(cat "$METRICS_FILE")
    
    echo -e "\n${GREEN}=== System Monitor Status ===${NC}"
    echo -e "${BLUE}Hostname:${NC} $(echo "$metrics" | jq -r '.system.hostname')"
    echo -e "${BLUE}Uptime:${NC} $(echo "$metrics" | jq -r '.system.uptime')"
    echo -e "${BLUE}Last Check:${NC} $(echo "$metrics" | jq -r '.system.timestamp')"
    
    echo -e "\n${CYAN}CPU Usage:${NC} $(echo "$metrics" | jq -r '.cpu.cpu_usage_percent')% ($(echo "$metrics" | jq -r '.cpu.status'))"
    echo -e "${CYAN}Memory Usage:${NC} $(echo "$metrics" | jq -r '.memory.usage_percent')% ($(echo "$metrics" | jq -r '.memory.status'))"
    echo -e "${CYAN}Load Average:${NC} $(echo "$metrics" | jq -r '.cpu.load_average_1min')"
    
    local disk_status
    disk_status=$(echo "$metrics" | jq -r '.disk[] | "\(.mount_point): \(.usage_percent)% (\(.status))"')
    echo -e "${CYAN}Disk Usage:${NC}"
    while IFS= read -r line; do
        echo -e "  $line"
    done <<< "$disk_status"
    
    echo -e "${CYAN}Max Temperature:${NC} $(echo "$metrics" | jq -r '.temperature.max_temperature')°C ($(echo "$metrics" | jq -r '.temperature.status'))"
    
    local failed_services
    failed_services=$(echo "$metrics" | jq -r '.services.failed_count')
    echo -e "${CYAN}Service Status:${NC} $failed_services failed ($(echo "$metrics" | jq -r '.services.status'))"
    
    local security_updates
    security_updates=$(echo "$metrics" | jq -r '.security.security_updates')
    echo -e "${CYAN}Security Updates:${NC} $security_updates available ($(echo "$metrics" | jq -r '.security.status'))"
    
    echo
}

# Main function
main() {
    local action="${1:-monitor}"
    
    case "$action" in
        monitor)
            load_config
            generate_metrics
            ;;
        status)
            show_status
            ;;
        test-alerts)
            load_config
            send_alert "TEST ALERT" "This is a test alert from the system monitor"
            echo "Test alert sent"
            ;;
        install)
            # Install dependencies
            if check_privileges; then
                apt-get update
                apt-get install -y jq bc lm-sensors mailutils curl
                sensors-detect --auto 2>/dev/null || true
                echo "Dependencies installed successfully"
            else
                echo "Please run as root to install dependencies"
                exit 1
            fi
            ;;
        *)
            echo "Usage: $0 {monitor|status|test-alerts|install}"
            echo "  monitor      - Run monitoring and collect metrics"
            echo "  status       - Display current system status"
            echo "  test-alerts  - Send test alert to all configured channels"
            echo "  install      - Install required dependencies"
            exit 1
            ;;
    esac
}

# Install signal handlers for graceful shutdown
trap 'log_info "System monitor interrupted"; exit 0' INT TERM

# Run main function
main "$@"
