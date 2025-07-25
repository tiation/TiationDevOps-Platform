# VPS Infrastructure Management

This directory contains comprehensive scripts and configurations for managing the Tiation VPS infrastructure across all environments.

## Infrastructure Overview

### VPS Hosts Configuration

| Hostname | IP Address | OS | Role | SSH Port |
|----------|------------|----|----|----------|
| `openvpn.tiation.net` | 93.127.167.157 | Ubuntu 22.04 | OpenVPN Server / Gateway | 22 |
| `gitlab.sxc.codes` | 149.28.135.83 | Ubuntu 22.04 | GitLab CI/CD Server | 22 |
| `grafana.sxc.codes` | 149.28.135.84 | Ubuntu 22.04 | Monitoring / Grafana | 22 |
| `docker.sxc.codes` | 149.28.135.85 | Ubuntu 22.04 | Docker Registry | 22 |
| `helm.sxc.codes` | 149.28.135.86 | Ubuntu 22.04 | Helm Charts / K8s | 22 |

### Network Configuration
- **Tailscale Network**: Secure mesh networking for internal communication
- **OpenVPN Gateway**: Primary external access point via `openvpn.tiation.net`
- **SSH Configuration**: Key-based authentication with hardened security

## Directory Structure

```
infrastructure/vps/
├── README.md                    # This documentation
├── config/                      # Configuration files
│   ├── ssh-config              # SSH client configuration
│   ├── tailscale.conf          # Tailscale configuration
│   └── hosts                   # Host definitions
├── scripts/                     # Setup and management scripts
│   ├── setup/                  # Initial setup scripts
│   │   ├── bootstrap.sh        # Bootstrap all VPS instances
│   │   ├── setup-openvpn.sh    # OpenVPN server setup
│   │   ├── setup-gitlab.sh     # GitLab CI/CD setup
│   │   ├── setup-grafana.sh    # Grafana monitoring setup
│   │   ├── setup-docker.sh     # Docker registry setup
│   │   └── setup-helm.sh       # Helm/K8s setup
│   ├── connect/                # Connection utilities
│   │   ├── connect.sh          # Universal connection script
│   │   ├── tunnel.sh           # SSH tunnel management
│   │   └── sync.sh             # File synchronization
│   ├── monitoring/             # Health check scripts
│   │   ├── health-check.sh     # System health monitoring
│   │   └── alert.sh            # Alert notification system
│   └── maintenance/            # Maintenance utilities
│       ├── backup.sh           # Backup management
│       ├── update.sh           # System updates
│       └── cleanup.sh          # Cleanup utilities
├── templates/                  # Configuration templates
│   ├── nginx/                  # Nginx configurations
│   ├── docker/                 # Docker configurations
│   └── systemd/                # Systemd service files
└── ansible/                   # Ansible playbooks (optional)
    ├── inventory.yml           # Ansible inventory
    ├── site.yml                # Main playbook
    └── roles/                  # Ansible roles
```

## Quick Start

### Prerequisites
1. SSH key pair generated and configured
2. Access to VPS instances
3. Tailscale account and auth key (optional)

### Initial Setup
```bash
# Make all scripts executable
chmod +x infrastructure/vps/scripts/**/*.sh

# Bootstrap all VPS instances
./infrastructure/vps/scripts/setup/bootstrap.sh

# Connect to any VPS
./infrastructure/vps/scripts/connect/connect.sh openvpn
./infrastructure/vps/scripts/connect/connect.sh gitlab
./infrastructure/vps/scripts/connect/connect.sh grafana
```

### Common Operations
```bash
# Health check all systems
./infrastructure/vps/scripts/monitoring/health-check.sh

# Update all systems
./infrastructure/vps/scripts/maintenance/update.sh

# Backup all systems
./infrastructure/vps/scripts/maintenance/backup.sh

# Sync files across VPS instances
./infrastructure/vps/scripts/connect/sync.sh source-host target-host /path/to/files
```

## Security Best Practices

1. **SSH Key Management**: Use dedicated SSH keys for each environment
2. **Firewall Configuration**: Implement UFW rules on all instances
3. **SSL/TLS**: Use Let's Encrypt certificates for all web services
4. **Monitoring**: Centralized logging and alerting via Grafana
5. **Backup Strategy**: Automated daily backups with retention policies

## Monitoring & Alerting

All VPS instances are monitored via:
- **Grafana Dashboard**: `https://grafana.sxc.codes`
- **System Metrics**: CPU, Memory, Disk, Network
- **Service Health**: Application-specific health checks
- **Alert Channels**: Email, Slack, Discord notifications

## Troubleshooting

### Common Issues
1. **SSH Connection Refused**: Check firewall and SSH service status
2. **Certificate Expired**: Renew Let's Encrypt certificates
3. **Disk Space Full**: Run cleanup scripts and check log rotation
4. **Service Down**: Check systemd service status and logs

### Emergency Procedures
1. **System Recovery**: Boot from rescue mode and restore from backup
2. **Network Issues**: Verify Tailscale connectivity and DNS resolution
3. **Service Failures**: Restart services and check configuration files

For detailed troubleshooting, see the individual setup scripts and configuration files.
