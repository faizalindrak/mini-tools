# docker-updater

Docker Container Auto-Update Manager. A system-wide CLI tool for managing and auto-updating Docker containers with health checks, rollbacks, and notifications.

## Features

- **Automated Updates**: Scheduled container updates via cron integration.
- **Safe Rollbacks**: Automatic snapshot and rollback if an update or health check fails.
- **Health Monitoring**: Post-update verification to ensure all services are healthy.
- **Hook System**: Extensible `pre-update.sh` and `post-update.sh` scripts for custom logic.
- **Webhook Notifications**: Slack-compatible notifications for update status (success/failure).
- **Interactive CLI**: Easy-to-use menu-driven interface or direct command execution.
- **System Integration**: System-wide installation with bash completion support.
- **Security**: Lock mechanisms to prevent concurrent updates and hook ownership validation.
- **Centralized Logging**: Consistent logging for all automated update tasks.

## Prerequisites

- **Bash**: 4.0 or higher.
- **Docker**: Engine with `docker compose` (V2) plugin installed.
- **curl**: For webhook notifications and remote installation.
- **jq**: Required for safe JSON encoding in webhook notifications.
- **cron**: For scheduled auto-updates.

## Installation

### Method 1: Local Script
If you have already downloaded the script:
```bash
sudo ./docker-updater.sh install
```

### Method 2: Remote Install (recommended)
```bash
curl -fsSL https://raw.githubusercontent.com/user/repo/main/docker-updater.sh | sudo bash -s -- install
```

The tool will be installed to `/usr/local/bin/docker-updater` and configuration files will be created in `/etc/docker-updater/`.

## Quick Start

1. **Register a project**:
   Navigate to your project directory containing a `docker-compose.yml` file and run:
   ```bash
   sudo docker-updater add
   ```
   *This registers the project for auto-updates every 12 hours (default).*

2. **List registered projects**:
   ```bash
   docker-updater list
   ```

3. **Manually update a project**:
   ```bash
   docker-updater update
   ```

## Command Reference

### Project Management
| Command | Description |
|:---|:---|
| `add [dir] [hours]` | Register project for auto-updates (1-23 hours). |
| `remove [dir]` | Unregister project and remove cron job. |
| `list` | List all registered projects and their status. |
| `enable [dir]` | Enable auto-updates for a registered project. |
| `disable [dir]` | Disable auto-updates for a registered project. |

### Container Operations
| Command | Description |
|:---|:---|
| `update [dir]` | Pull latest images and recreate containers with health checks. |
| `update-all` | Run update for all enabled projects. |
| `status [dir]` | Show container and image status for the project. |
| `start [dir]` | Start containers (`docker compose up -d`). |
| `stop [dir]` | Stop containers (`docker compose stop`). |
| `restart [dir]` | Restart containers (`docker compose restart`). |
| `logs [dir] [lines]` | View update logs for the project. |

### System Commands
| Command | Description |
|:---|:---|
| `config [key] [val]` | Get or set global configuration variables. |
| `install` | Install the tool to the system. |
| `uninstall` | Remove the tool from the system (preserves config/logs). |
| `version` | Display version information. |
| `help` | Show full command help. |

## Configuration

Global configuration is stored in `/etc/docker-updater/config`. You can manage it using the `config` command:

```bash
# Set a Slack/Discord webhook URL for notifications
sudo docker-updater config WEBHOOK_URL "https://hooks.slack.com/services/..."

# Set health check timeout (default: 60 seconds)
sudo docker-updater config HEALTH_TIMEOUT 120
```

## Update Hooks

You can place executable scripts in your project directory to run custom logic during the update process:

1. **`pre-update.sh`**: Runs before the update process starts (before pulling images).
2. **`post-update.sh`**: Runs after a successful update and health check passing.

### Security Requirements
For security, when running as root, hooks must be owned by the root user. If a hook has incorrect ownership, it will be skipped with a warning.
```bash
sudo chown root:root pre-update.sh post-update.sh
sudo chmod +x pre-update.sh post-update.sh
```

## How Auto-Updates Work

When you `add` a project, a cron job is created in the root user's crontab.
- The job runs every `N` hours (as specified during `add`).
- It executes `docker-updater update-single [path]`.
- Output is redirected to `/var/log/docker-updater/[project-name].log`.
- A lock file is used to ensure that if an update takes longer than the interval, multiple instances won't conflict.

## Rollback Functionality

The tool ensures high availability by protecting against broken image updates:
1. **Snapshot**: Captures the current image ID for every service before updating.
2. **Pull & Up**: Attempts to pull new images and recreate containers.
3. **Health Check**: Waits for containers to reach a "healthy" state (or "running" if no health check is defined).
4. **Rollback**: If any step fails (Pull, Up, or Health Check), it retags the local images back to the previous IDs and restarts the containers.

## Troubleshooting

- **Logs**: Check `/var/log/docker-updater/` for detailed logs of automated updates.
- **Lock Files**: If a process is killed unexpectedly, you may need to manually remove lock files in `/var/run/docker-updater-*.lock`.
- **Permissions**: Ensure you run management commands (`add`, `remove`, `config`, `install`) with `sudo`.
- **Health Checks**: If a project always rolls back, ensure your `docker-compose.yml` has correct health check definitions or increase `HEALTH_TIMEOUT`.

## Uninstallation

To remove the tool from your system:
```bash
sudo docker-updater uninstall
```
Note: This removes the binary, cron jobs, and bash completion, but leaves your logs and configuration files in case you want to reinstall later.

## License

MIT License (Placeholder)
