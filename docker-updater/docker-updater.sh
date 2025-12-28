#!/bin/bash
# Docker Auto-Update Manager
# A system-wide CLI tool for managing and auto-updating Docker containers
#
# Installation:
#   sudo ./docker-updater.sh install
#   or
#   curl -fsSL https://raw.githubusercontent.com/user/repo/main/docker-updater.sh | sudo bash -s -- install
#
# Usage: docker-updater [command]

set -e

# ═══════════════════════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════════════════════

APP_NAME="docker-updater"
APP_VERSION="1.2.0"
APP_DESCRIPTION="Docker Container Auto-Update Manager"

INSTALL_PATH="/usr/local/bin/$APP_NAME"
CONFIG_DIR="/etc/$APP_NAME"
PROJECTS_FILE="$CONFIG_DIR/projects"
GLOBAL_CONFIG_FILE="$CONFIG_DIR/config"
LOG_DIR="/var/log/$APP_NAME"
CRON_MARKER="# docker-updater-managed"
LOCK_FILE="/var/run/$APP_NAME.lock"

# Temp files tracking for cleanup
TEMP_FILES=()

cleanup() {
    local file
    for file in "${TEMP_FILES[@]}"; do
        rm -f "$file" 2>/dev/null
    done
    # Release lock if held
    [ -n "${LOCK_FD:-}" ] && exec {LOCK_FD}>&- 2>/dev/null
}
trap cleanup EXIT INT TERM

# Create tracked temp file
create_temp() {
    local tmp
    tmp=$(mktemp)
    TEMP_FILES+=("$tmp")
    echo "$tmp"
}

# Colors - check terminal capability
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    MAGENTA=''
    BOLD=''
    DIM=''
    NC=''
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════════════════

normalize_day_token() {
    local token="$1"
    local upper
    upper=$(echo "$token" | tr '[:lower:]' '[:upper:]')

    case "$upper" in
        SUN|SUNDAY) echo "Sun" ;;
        MON|MONDAY) echo "Mon" ;;
        TUE|TUESDAY|TUES) echo "Tue" ;;
        WED|WEDNESDAY) echo "Wed" ;;
        THU|THURSDAY|THUR) echo "Thu" ;;
        FRI|FRIDAY) echo "Fri" ;;
        SAT|SATURDAY) echo "Sat" ;;
        *) echo "" ;;
    esac
}

normalize_days() {
    local raw="$1"
    local cleaned
    cleaned=$(echo "$raw" | tr -d ' ' | tr ';' ',')

    if [ -z "$cleaned" ]; then
        echo ""
        return 1
    fi

    local result=""
    local item
    IFS=',' read -r -a items <<< "$cleaned"

    for item in "${items[@]}"; do
        [ -z "$item" ] && continue
        local normalized
        normalized=$(normalize_day_token "$item")
        if [ -z "$normalized" ]; then
            echo ""
            return 1
        fi
        if [ -z "$result" ]; then
            result="$normalized"
        else
            result="$result,$normalized"
        fi
    done

    echo "$result"
}

normalize_time_input() {
    local raw="$1"
    local trimmed
    trimmed=$(echo "$raw" | tr -d ' ')

    if [[ "$trimmed" =~ ^([0-9]{1,2})[.:]([0-9]{2})([AaPp][Mm])$ ]]; then
        local hour="${BASH_REMATCH[1]}"
        local minute="${BASH_REMATCH[2]}"
        local ampm="${BASH_REMATCH[3]}"
        if [ "$hour" -lt 1 ] || [ "$hour" -gt 12 ]; then
            return 1
        fi
        if [ "$minute" -gt 59 ]; then
            return 1
        fi
        hour=$((10#$hour))
        minute=$((10#$minute))
        local hour24
        local upper_ampm
        upper_ampm=$(echo "$ampm" | tr '[:lower:]' '[:upper:]')
        if [ "$upper_ampm" == "AM" ]; then
            if [ "$hour" -eq 12 ]; then
                hour24=0
            else
                hour24=$hour
            fi
        else
            if [ "$hour" -eq 12 ]; then
                hour24=12
            else
                hour24=$((hour + 12))
            fi
        fi
        printf "%02d:%02d" "$hour24" "$minute"
        return 0
    fi

    if [[ "$trimmed" =~ ^([0-9]{1,2})[.:]([0-9]{2})$ ]]; then
        local hour="${BASH_REMATCH[1]}"
        local minute="${BASH_REMATCH[2]}"
        if [ "$hour" -gt 23 ] || [ "$minute" -gt 59 ]; then
            return 1
        fi
        hour=$((10#$hour))
        minute=$((10#$minute))
        printf "%02d:%02d" "$hour" "$minute"
        return 0
    fi

    return 1
}

acquire_lock() {
    local lock_name="${1:-global}"
    local lock_path="/var/run/$APP_NAME-${lock_name}.lock"
    
    exec {LOCK_FD}>"$lock_path"
    if ! flock -n "$LOCK_FD"; then
        log_error "Another update is already running for: $lock_name"
        log_info "If this is incorrect, remove: $lock_path"
        return 1
    fi
    return 0
}

log() {
    echo -e "$1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}!${NC} $1"
}

log_info() {
    echo -e "${BLUE}→${NC} $1"
}

send_notification() {
    local status="$1"
    local message="$2"
    local project_name="$3"
    
    if [ ! -f "$GLOBAL_CONFIG_FILE" ]; then
        return 0
    fi
    
    local webhook_url
    webhook_url=$(grep -- "^WEBHOOK_URL=" "$GLOBAL_CONFIG_FILE" | cut -d'=' -f2-)
    
    if [ -z "$webhook_url" ]; then
        return 0
    fi
    
    if ! command -v jq >/dev/null 2>&1; then
        log_warn "jq not installed - skipping notification (required for safe JSON encoding)"
        return 0
    fi
    
    local color="#36a64f"
    if [ "$status" == "failure" ]; then
        color="#ff0000"
    fi
    
    local payload
    payload=$(jq -n \
        --arg color "$color" \
        --arg title "Docker Updater: $project_name" \
        --arg text "$message" \
        --arg footer "docker-updater v$APP_VERSION" \
        --argjson ts "$(date +%s)" \
        '{attachments: [{color: $color, title: $title, text: $text, footer: $footer, ts: $ts}]}')
    
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$webhook_url" >/dev/null 2>&1 || true
}

run_hook() {
    local dir="$1"
    local hook_name="$2"
    local hook_path="$dir/$hook_name"
    
    if [ -f "$hook_path" ] && [ -x "$hook_path" ]; then
        local hook_owner
        hook_owner=$(stat -c '%u' "$hook_path" 2>/dev/null || stat -f '%u' "$hook_path" 2>/dev/null)
        
        if [ "$EUID" -eq 0 ] && [ "$hook_owner" != "0" ]; then
            log_warn "Hook $hook_name not owned by root (owner: $hook_owner). Skipping for security."
            log_warn "Fix with: sudo chown root:root \"$hook_path\""
            return 1
        fi
        
        log_info "Running $hook_name..."
        if ! "$hook_path"; then
            log_error "Hook $hook_name failed with exit code $?"
            return 1
        fi
    elif [ -f "$hook_path" ]; then
        log_warn "Found $hook_name but it is not executable. Skipping."
        log_warn "Fix with: chmod +x \"$hook_path\""
    fi
}

require_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This command requires root privileges. Run with sudo."
        exit 1
    fi
}

get_compose_file() {
    local dir="$1"
    if [ -f "$dir/docker-compose.yml" ]; then
        echo "$dir/docker-compose.yml"
    elif [ -f "$dir/docker-compose.yaml" ]; then
        echo "$dir/docker-compose.yaml"
    elif [ -f "$dir/compose.yml" ]; then
        echo "$dir/compose.yml"
    elif [ -f "$dir/compose.yaml" ]; then
        echo "$dir/compose.yaml"
    else
        return 1
    fi
}

get_project_name() {
    local dir="$1"
    basename "$dir" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g'
}

get_services() {
    local dir="$1"
    cd "$dir"
    docker compose config --services 2>/dev/null | tr '\n' ' '
}

get_container_image_ids() {
    docker compose ps --format '{{.Service}}' | while read -r service; do
        local cid=$(docker compose ps -q "$service")
        if [ -n "$cid" ]; then
            local iid=$(docker inspect --format='{{.Image}}' "$cid")
            echo "$service:$iid"
        fi
    done
}

wait_for_health() {
    local timeout="${1:-60}"
    local start_time=$(date +%s)
    local healthy=1
    
    log_info "Waiting for services to become healthy (timeout: ${timeout}s)..."
    
    while [ $(( $(date +%s) - start_time )) -lt "$timeout" ]; do
        local all_healthy=true
        local has_running_containers=false
        
        local services=$(docker compose ps --services)
        
        for service in $services; do
            local cid=$(docker compose ps -q "$service")
            [ -z "$cid" ] && continue
            
            has_running_containers=true
            
            local state=$(docker inspect --format='{{.State.Status}}' "$cid")
            if [ "$state" == "exited" ] || [ "$state" == "dead" ]; then
                log_warn "Service $service is $state"
                all_healthy=false
                break
            fi
            
            local health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")
            if [ "$health" == "unhealthy" ]; then
                all_healthy=false
                break
            elif [ "$health" == "starting" ]; then
                all_healthy=false
            fi
        done
        
        if [ "$all_healthy" == "true" ] && [ "$has_running_containers" == "true" ]; then
            healthy=0
            break
        fi
        
        sleep 5
    done
    
    return $healthy
}

perform_rollback() {
    local previous_state_file="$1"
    
    if [ ! -f "$previous_state_file" ]; then
        log_error "No rollback state found."
        return 1
    fi
    
    log_warn "Initiating rollback..."
    
    while IFS=':' read -r service image_id; do
        if [ -n "$service" ] && [ -n "$image_id" ]; then
            log_info "Rolling back $service to $image_id..."
            local repo_tag
            repo_tag=$(docker compose images --format '{{.Repository}}:{{.Tag}}' "$service" 2>/dev/null) || true
            
            if [ -n "$repo_tag" ] && [ "$repo_tag" != "<none>:<none>" ]; then
                if docker tag "$image_id" "$repo_tag"; then
                    log "  Retagged $repo_tag -> $image_id"
                else
                    log_warn "  Failed to retag $service"
                fi
            else
                log_warn "  Could not determine image tag for $service. Skipping."
            fi
        fi
    done < "$previous_state_file"
    
    log_info "Recreating containers with previous images..."
    if docker compose up -d --force-recreate; then
        log_success "Rollback successful."
        return 0
    else
        log_error "Rollback failed."
        return 1
    fi
}

ensure_config() {
    if [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR"
    fi
    if [ ! -f "$PROJECTS_FILE" ]; then
        touch "$PROJECTS_FILE"
    fi
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Project Management
# ═══════════════════════════════════════════════════════════════════════════════

project_exists() {
    local dir="$1"
    grep -q -- "^$dir|" "$PROJECTS_FILE" 2>/dev/null
}

add_project() {
    local dir="$1"
    local interval="${2:-12}"
    local name
    name=$(get_project_name "$dir")

    if project_exists "$dir"; then
        local tmp
        tmp=$(create_temp)
        grep -v -- "^$dir|" "$PROJECTS_FILE" > "$tmp" || true
        echo "$dir|$name|$interval|enabled" >> "$tmp"
        mv "$tmp" "$PROJECTS_FILE"
    else
        echo "$dir|$name|$interval|enabled" >> "$PROJECTS_FILE"
    fi
}

remove_project() {
    local dir="$1"
    if [ -f "$PROJECTS_FILE" ]; then
        local tmp
        tmp=$(create_temp)
        grep -v -- "^$dir|" "$PROJECTS_FILE" > "$tmp" || true
        mv "$tmp" "$PROJECTS_FILE"
    fi
}

set_project_status() {
    local dir="$1"
    local status="$2"

    if project_exists "$dir"; then
        local tmp
        tmp=$(create_temp)
        while IFS='|' read -r path name interval old_status; do
            if [ "$path" == "$dir" ]; then
                echo "$path|$name|$interval|$status"
            else
                echo "$path|$name|$interval|$old_status"
            fi
        done < "$PROJECTS_FILE" > "$tmp"
        mv "$tmp" "$PROJECTS_FILE"
    fi
}

list_projects() {
    if [ ! -f "$PROJECTS_FILE" ] || [ ! -s "$PROJECTS_FILE" ]; then
        return 1
    fi
    cat "$PROJECTS_FILE"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Cron Management
# ═══════════════════════════════════════════════════════════════════════════════

rebuild_cron() {
    require_root

    local tmp
    tmp=$(create_temp)
    crontab -l 2>/dev/null | grep -v -- "$CRON_MARKER" > "$tmp" || true

    if [ -f "$PROJECTS_FILE" ]; then
        while IFS='|' read -r path name interval status; do
            if [ "$status" == "enabled" ] && [ -n "$path" ]; then
                local log_file="$LOG_DIR/${name}.log"
                local cron_schedule
                
                if [[ "$interval" =~ ^[0-9]+$ ]]; then
                    cron_schedule="0 */$interval * * *"
                else
                    cron_schedule="$interval"
                fi
                
                echo "$cron_schedule $INSTALL_PATH update-single \"$path\" >> \"$log_file\" 2>&1 $CRON_MARKER" >> "$tmp"
            fi
        done < "$PROJECTS_FILE"
    fi

    crontab "$tmp"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Commands
# ═══════════════════════════════════════════════════════════════════════════════

cmd_config() {
    require_root
    ensure_config
    
    local key="$1"
    local value="$2"
    
    if [ -z "$key" ]; then
        log ""
        log "${CYAN}Global Configuration:${NC}"
        if [ -f "$GLOBAL_CONFIG_FILE" ]; then
            cat "$GLOBAL_CONFIG_FILE"
        else
            log "${DIM}No configuration set.${NC}"
        fi
        log ""
        log "Set config: ${BOLD}$APP_NAME config <key> <value>${NC}"
        log ""
        return
    fi
    
    if [ -z "$value" ]; then
        if [ -f "$GLOBAL_CONFIG_FILE" ]; then
            grep -- "^$key=" "$GLOBAL_CONFIG_FILE" | cut -d'=' -f2-
        fi
    else
        if [ ! -f "$GLOBAL_CONFIG_FILE" ]; then
            touch "$GLOBAL_CONFIG_FILE"
        fi
        
        local tmp
        tmp=$(create_temp)
        grep -v -- "^$key=" "$GLOBAL_CONFIG_FILE" > "$tmp" || true
        echo "$key=$value" >> "$tmp"
        mv "$tmp" "$GLOBAL_CONFIG_FILE"
        log_success "Set $key=$value"
    fi
}

SCRIPT_URL="https://raw.githubusercontent.com/faizalindrak/mini-tools/master/docker-updater/docker-updater.sh"

cmd_self_update() {
    require_root
    
    log_info "Checking for newer version..."
    local tmp
    tmp=$(create_temp)
    
    if ! curl -fsSL "$SCRIPT_URL" -o "$tmp"; then
        log_error "Failed to download update script"
        return 1
    fi
    
    if ! grep -q "^#!/bin/bash" "$tmp"; then
        log_error "Downloaded file is not a valid script"
        return 1
    fi
    
    local remote_version
    remote_version=$(grep '^APP_VERSION=' "$tmp" | cut -d'"' -f2)
    
    if [ -z "$remote_version" ]; then
        log_error "Could not detect version in remote script"
        return 1
    fi
    
    log_info "Current version: $APP_VERSION"
    log_info "Remote version:  $remote_version"
    
    if [ "$APP_VERSION" == "$remote_version" ] && [ "$1" != "--force" ]; then
        log_success "Already up to date."
        return 0
    fi
    
    log_info "Updating..."
    cp "$tmp" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    
    log_success "Updated to version $remote_version"
}

cmd_install() {
    require_root

    log ""
    log "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    log "${CYAN}║      Installing $APP_NAME v$APP_VERSION                    ║${NC}"
    log "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    log ""

    local script_source="${BASH_SOURCE[0]}"
    
    if [ "$script_source" == "bash" ] || [ -z "$script_source" ] || [ ! -f "$script_source" ] || [ ! -r "$script_source" ]; then
        log_info "Downloading script..."
        script_source="/tmp/docker-updater-install.sh"
        if ! curl -fsSL "$SCRIPT_URL" -o "$script_source"; then
            log_error "Failed to download script"
            exit 1
        fi
        chmod +x "$script_source"
    fi

    # Copy to install path
    cp "$script_source" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    log_success "Installed to $INSTALL_PATH"

    # Create directories
    ensure_config
    log_success "Created config directory $CONFIG_DIR"
    log_success "Created log directory $LOG_DIR"

    # Add bash completion
    if [ -d /etc/bash_completion.d ]; then
        cat > "/etc/bash_completion.d/$APP_NAME" << 'COMPLETION'
_docker_updater_completions() {
    local commands="add remove list check update update-all enable disable logs status start stop restart help version install uninstall self-update"

    if [ "${#COMP_WORDS[@]}" == "2" ]; then
        COMPREPLY=($(compgen -W "$commands" -- "${COMP_WORDS[1]}"))
    fi
}
complete -F _docker_updater_completions docker-updater
COMPLETION
        log_success "Added bash completion"
    fi

    log ""
    log "${GREEN}Installation complete!${NC}"
    log ""
    log "Quick Start:"
    log "  ${BOLD}cd /path/to/your/docker-compose/project${NC}"
    log "  ${BOLD}sudo $APP_NAME add${NC}              # Register current directory"
    log "  ${BOLD}$APP_NAME list${NC}                  # View registered projects"
    log "  ${BOLD}$APP_NAME help${NC}                  # Show all commands"
    log ""

    [ -f /tmp/docker-updater-install.sh ] && rm /tmp/docker-updater-install.sh
}

cmd_uninstall() {
    require_root

    log "${YELLOW}Uninstalling $APP_NAME...${NC}"

    local tmp
    tmp=$(create_temp)
    crontab -l 2>/dev/null | grep -v -- "$CRON_MARKER" > "$tmp" || true
    crontab "$tmp"
    log_success "Removed cron jobs"

    [ -f "$INSTALL_PATH" ] && rm -f "$INSTALL_PATH" && log_success "Removed $INSTALL_PATH"
    [ -f "/etc/bash_completion.d/$APP_NAME" ] && rm -f "/etc/bash_completion.d/$APP_NAME"

    log ""
    log "${GREEN}Uninstalled successfully!${NC}"
    log_info "Config preserved at $CONFIG_DIR (remove manually if needed)"
    log_info "Logs preserved at $LOG_DIR"
}

cmd_add() {
    require_root
    ensure_config

    local dir=""
    local at_time=""
    local days=""
    local interval=""
    local custom_cron=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --at)
                if [ -z "$2" ]; then
                    log_error "Option --at requires a value"
                    exit 1
                fi
                at_time="$2"
                shift 2
                ;;
            --days)
                if [ -z "$2" ]; then
                    log_error "Option --days requires a value"
                    exit 1
                fi
                days="$2"
                shift 2
                ;;
            --interval)
                if [ -z "$2" ]; then
                    log_error "Option --interval requires a value"
                    exit 1
                fi
                interval="$2"
                shift 2
                ;;
            --cron)
                if [ -z "$2" ]; then
                    log_error "Option --cron requires a value"
                    exit 1
                fi
                custom_cron="$2"
                shift 2
                ;;
            -*)
                log_error "Unknown option: $1"
                exit 1
                ;;
            *)
                if [ -z "$dir" ]; then
                    dir="$1"
                elif [ -z "$interval" ] && [ -z "$at_time" ] && [ -z "$custom_cron" ]; then
                    interval="$1"
                fi
                shift
                ;;
        esac
    done

    dir="${dir:-$(pwd)}"

    # Resolve to absolute path
    dir="$(cd "$dir" 2>/dev/null && pwd)" || {
        log_error "Directory not found: $dir"
        exit 1
    }

    # Check for compose file
    local compose_file=$(get_compose_file "$dir") || {
        log_error "No docker-compose.yml found in $dir"
        exit 1
    }

    local name=$(get_project_name "$dir")
    local services=$(get_services "$dir")
    local final_schedule
    local display_schedule

    if [ -n "$custom_cron" ]; then
        final_schedule="$custom_cron"
        display_schedule="Cron: $custom_cron"
    elif [ -n "$at_time" ]; then
        local parsed
        parsed=$(normalize_time_input "$at_time") || {
            log_error "Invalid time format: $at_time"
            log_info "Use HH:MM, HH.MM, or hh:mm AM/PM"
            exit 1
        }

        local hour
        hour=$(echo "$parsed" | cut -d: -f1)
        local minute
        minute=$(echo "$parsed" | cut -d: -f2)

        hour=$((10#$hour))
        minute=$((10#$minute))

        local cron_days="*"
        local display_days=""
        if [ -n "$days" ]; then
            local normalized_days
            normalized_days=$(normalize_days "$days") || {
                log_error "Invalid days format: $days"
                log_info "Use Mon,Tue or full names like Tuesday"
                exit 1
            }
            cron_days="$normalized_days"
            display_days="$normalized_days"
        fi

        final_schedule="$minute $hour * * $cron_days"
        display_schedule="At $parsed"
        if [ "$cron_days" != "*" ]; then
            display_schedule="$display_schedule on $display_days"
        else
            display_schedule="$display_schedule daily"
        fi

    elif [ -n "$interval" ]; then
        if ! [[ "$interval" =~ ^[1-9][0-9]*$ ]] || [ "$interval" -gt 23 ]; then
            log_error "Interval must be a positive integer between 1 and 23 hours"
            log_info "For specific times, use --at \"HH:MM\""
            exit 1
        fi
        final_schedule="$interval"
        display_schedule="Every $interval hours"
    else
        final_schedule="12"
        display_schedule="Every 12 hours"
    fi

    log ""
    log "${CYAN}Registering Docker Project${NC}"
    log ""
    log "  Directory:  $dir"
    log "  Name:       $name"
    log "  Compose:    $compose_file"
    log "  Services:   $services"
    log "  Schedule:   $display_schedule"
    log ""

    add_project "$dir" "$final_schedule"
    log_success "Project registered"

    rebuild_cron
    log_success "Cron job configured"

    log ""
    log "Commands:"
    log "  ${BOLD}$APP_NAME update${NC}     - Update this project now"
    log "  ${BOLD}$APP_NAME list${NC}       - View all projects"
    log "  ${BOLD}$APP_NAME logs${NC}       - View update logs"
}





cmd_remove() {
    require_root
    ensure_config

    local dir="${1:-$(pwd)}"
    dir="$(cd "$dir" 2>/dev/null && pwd)" || dir="$1"

    if ! project_exists "$dir"; then
        log_error "Project not registered: $dir"
        exit 1
    fi

    remove_project "$dir"
    log_success "Project removed: $dir"

    rebuild_cron
    log_success "Cron jobs updated"
}

cmd_list() {
    ensure_config

    log ""
    log "${CYAN}${BOLD}Registered Docker Projects${NC}"
    log ""

    if ! list_projects > /dev/null 2>&1; then
        log_warn "No projects registered"
        log_info "Run '${BOLD}cd /path/to/project && sudo $APP_NAME add${NC}' to register"
        log ""
        return
    fi

    printf "${DIM}%-40s %-15s %-15s %-10s${NC}\n" "DIRECTORY" "NAME" "SCHEDULE" "STATUS"
    printf "${DIM}%-40s %-15s %-15s %-10s${NC}\n" "─────────" "────" "────────" "──────"

    while IFS='|' read -r path name interval status; do
        [ -z "$path" ] && continue

        # Truncate long paths
        local display_path="$path"
        if [ ${#path} -gt 38 ]; then
            display_path="...${path: -35}"
        fi

        local status_color="${GREEN}"
        [ "$status" != "enabled" ] && status_color="${YELLOW}"
        
        local display_schedule
        if [[ "$interval" =~ ^[0-9]+$ ]]; then
            display_schedule="Every ${interval}h"
        else
            local min hour dom mon dow extra
            read -r min hour dom mon dow extra <<< "$interval"

            if [ -n "$extra" ] || [ -z "$dow" ]; then
                display_schedule="Custom"
            elif [ "$dom" == "*" ] && [ "$mon" == "*" ] && [ "$dow" == "*" ]; then
                printf -v display_schedule "Daily %02d:%02d" "$hour" "$min"
            elif [ "$dom" == "*" ] && [ "$mon" == "*" ]; then
                printf -v display_schedule "%s %02d:%02d" "Wkly $dow" "$hour" "$min"
            else
                display_schedule="Custom"
            fi
        fi

        printf "%-40s %-15s %-15s ${status_color}%-10s${NC}\n" "$display_path" "$name" "$display_schedule" "$status"
    done < "$PROJECTS_FILE"

    log ""

    # Show cron status
    local cron_count=$(crontab -l 2>/dev/null | grep -c "$CRON_MARKER" || echo "0")
    log "${DIM}Active cron jobs: $cron_count${NC}"
    log ""
}

cmd_check() {
    local dir="${1:-$(pwd)}"
    dir="$(cd "$dir" 2>/dev/null && pwd)" || {
        log_error "Directory not found: $1"
        exit 1
    }

    local compose_file
    compose_file=$(get_compose_file "$dir") || {
        log_error "No docker-compose.yml found in $dir"
        exit 1
    }

    local name
    name=$(get_project_name "$dir")

    log ""
    log "${CYAN}Checking updates for: $name${NC}"
    log "${DIM}$dir${NC}"
    log ""

    cd "$dir" || exit 1

    log_info "Pulling latest images (this may take a moment)..."
    if ! docker compose pull --quiet; then
        log_error "Failed to pull images"
        return 1
    fi

    local updates_found=0
    local services
    services=$(docker compose ps --services)

    log_info "Comparing running containers with pulled images..."
    log ""
    
    printf "${DIM}%-20s %-30s %-15s${NC}\n" "SERVICE" "IMAGE" "STATUS"
    printf "${DIM}%-20s %-30s %-15s${NC}\n" "───────" "─────" "──────"

    for service in $services; do
        local cid
        cid=$(docker compose ps -q "$service")
        
        if [ -z "$cid" ]; then
            printf "%-20s %-30s ${YELLOW}%-15s${NC}\n" "$service" "-" "Not Running"
            continue
        fi

        local running_image_id
        running_image_id=$(docker inspect --format='{{.Image}}' "$cid")
        
        local image_name
        image_name=$(docker inspect --format='{{.Config.Image}}' "$cid")
        
        local current_tag_id
        current_tag_id=$(docker inspect --format='{{.Id}}' "$image_name" 2>/dev/null)

        local display_image="$image_name"
        if [ ${#image_name} -gt 28 ]; then
            display_image="...${image_name: -25}"
        fi

        if [ -z "$current_tag_id" ]; then
             printf "%-20s %-30s ${RED}%-15s${NC}\n" "$service" "$display_image" "Unknown"
        elif [ "$running_image_id" != "$current_tag_id" ]; then
            printf "%-20s %-30s ${GREEN}%-15s${NC}\n" "$service" "$display_image" "Update Available"
            ((updates_found++))
        else
            printf "%-20s %-30s ${DIM}%-15s${NC}\n" "$service" "$display_image" "Up to date"
        fi
    done

    log ""
    if [ "$updates_found" -gt 0 ]; then
        log "${GREEN}Found $updates_found update(s). Run '$APP_NAME update' to apply.${NC}"
    else
        log "${GREEN}All services are up to date.${NC}"
    fi
    log ""
}

cmd_update() {
    local dir="${1:-$(pwd)}"
    dir="$(cd "$dir" 2>/dev/null && pwd)" || {
        log_error "Directory not found: $1"
        exit 1
    }

    local compose_file
    compose_file=$(get_compose_file "$dir") || {
        log_error "No docker-compose.yml found in $dir"
        exit 1
    }

    local name
    name=$(get_project_name "$dir")
    
    acquire_lock "$name" || exit 1

    log ""
    log "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    log "${CYAN}  Updating: ${BOLD}$name${NC}"
    log "${CYAN}  Directory: $dir${NC}"
    log "${CYAN}  Time: $(date)${NC}"
    log "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    log ""

    cd "$dir" || {
        log_error "Failed to change directory to $dir"
        exit 1
    }

    run_hook "$dir" "pre-update.sh"

    log_info "Snapshotting current state for rollback..."
    local rollback_file
    rollback_file=$(create_temp)
    get_container_image_ids > "$rollback_file"

    log_info "Pulling latest images..."
    if ! docker compose pull; then
        log_error "Failed to pull images. Aborting update."
        send_notification "failure" "Failed to pull images for $name" "$name"
        return 1
    fi
    log ""

    log_info "Recreating containers..."
    if ! docker compose up -d --remove-orphans; then
        log_error "Failed to recreate containers."
        perform_rollback "$rollback_file"
        send_notification "failure" "Failed to recreate containers for $name" "$name"
        return 1
    fi
    log ""
    
    local health_timeout
    health_timeout=$(grep -- "^HEALTH_TIMEOUT=" "$GLOBAL_CONFIG_FILE" 2>/dev/null | cut -d'=' -f2-) || true
    health_timeout="${health_timeout:-60}"
    
    if wait_for_health "$health_timeout"; then
        log_success "All services healthy."
        
        run_hook "$dir" "post-update.sh"
        
        log_info "Cleaning up old images..."
        docker image prune -f
        
        log "${GREEN}═══════════════════════════════════════════════════════════${NC}"
        log "${GREEN}  Update completed successfully at $(date)${NC}"
        log "${GREEN}═══════════════════════════════════════════════════════════${NC}"
        send_notification "success" "Update completed successfully for $name" "$name"
    else
        log_error "Health check failed!"
        perform_rollback "$rollback_file"
        log "${RED}═══════════════════════════════════════════════════════════${NC}"
        log "${RED}  Update failed and rolled back at $(date)${NC}"
        log "${RED}═══════════════════════════════════════════════════════════${NC}"
        send_notification "failure" "Update failed and rolled back for $name (Health Check Failed)" "$name"
        return 1
    fi
    
    log ""
}

cmd_update_single() {
    local dir="$1"

    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        echo "[$(date)] ERROR: Invalid directory: $dir"
        exit 1
    fi

    cd "$dir" || {
        echo "[$(date)] ERROR: Failed to change directory to $dir"
        exit 1
    }
    
    local name
    name=$(get_project_name "$dir")
    
    acquire_lock "$name" || exit 1

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Update started at $(date)"
    echo "  Directory: $dir"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    run_hook "$dir" "pre-update.sh"

    local rollback_file
    rollback_file=$(create_temp)
    get_container_image_ids > "$rollback_file"

    if ! docker compose pull; then
        echo "ERROR: Failed to pull images."
        send_notification "failure" "Failed to pull images for $name" "$name"
        exit 1
    fi

    if ! docker compose up -d --remove-orphans; then
        echo "ERROR: Failed to recreate containers."
        perform_rollback "$rollback_file"
        send_notification "failure" "Failed to recreate containers for $name" "$name"
        exit 1
    fi

    local health_timeout
    health_timeout=$(grep -- "^HEALTH_TIMEOUT=" "$GLOBAL_CONFIG_FILE" 2>/dev/null | cut -d'=' -f2-) || true
    health_timeout="${health_timeout:-60}"

    if wait_for_health "$health_timeout"; then
        run_hook "$dir" "post-update.sh"
        docker image prune -f
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "  Update completed at $(date)"
        echo "═══════════════════════════════════════════════════════════"
        echo ""
        send_notification "success" "Update completed successfully for $name" "$name"
    else
        echo "ERROR: Health check failed! Rolling back..."
        perform_rollback "$rollback_file"
        echo "Rollback completed."
        send_notification "failure" "Update failed and rolled back for $name (Health Check Failed)" "$name"
        exit 1
    fi
}

cmd_update_all() {
    ensure_config

    if ! list_projects > /dev/null 2>&1; then
        log_warn "No projects registered"
        return
    fi

    log ""
    log "${CYAN}${BOLD}Updating all registered projects${NC}"
    log ""

    local count=0
    local failed=0

    while IFS='|' read -r path name interval status; do
        [ -z "$path" ] && continue
        [ "$status" != "enabled" ] && continue

        log "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        log "${MAGENTA}  Project: $name${NC}"
        log "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        if cmd_update "$path"; then
            ((count++))
        else
            ((failed++))
            log_error "Failed to update: $name"
        fi

        log ""
    done < "$PROJECTS_FILE"

    log "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log "${GREEN}Updated: $count projects${NC}"
    [ $failed -gt 0 ] && log "${RED}Failed: $failed projects${NC}"
    log ""
}

cmd_enable() {
    require_root
    ensure_config

    local dir="${1:-$(pwd)}"
    dir="$(cd "$dir" 2>/dev/null && pwd)" || dir="$1"

    if ! project_exists "$dir"; then
        log_error "Project not registered: $dir"
        log_info "Run 'sudo $APP_NAME add' first"
        exit 1
    fi

    set_project_status "$dir" "enabled"
    rebuild_cron
    log_success "Auto-update enabled for: $dir"
}

cmd_disable() {
    require_root
    ensure_config

    local dir="${1:-$(pwd)}"
    dir="$(cd "$dir" 2>/dev/null && pwd)" || dir="$1"

    if ! project_exists "$dir"; then
        log_error "Project not registered: $dir"
        exit 1
    fi

    set_project_status "$dir" "disabled"
    rebuild_cron
    log_success "Auto-update disabled for: $dir"
}

cmd_logs() {
    local dir="${1:-$(pwd)}"
    local lines="${2:-50}"

    dir="$(cd "$dir" 2>/dev/null && pwd)" || dir="$1"
    local name=$(get_project_name "$dir")
    local log_file="$LOG_DIR/${name}.log"

    if [ -f "$log_file" ]; then
        log "${CYAN}Logs for: $name${NC}"
        log "${DIM}$log_file${NC}"
        log ""
        tail -n "$lines" "$log_file"
    else
        log_warn "No logs found for: $name"
        log_info "Logs will appear after the first scheduled update"
    fi
}

cmd_status() {
    local dir="${1:-$(pwd)}"
    dir="$(cd "$dir" 2>/dev/null && pwd)" || {
        log_error "Directory not found: $1"
        exit 1
    }

    local compose_file
    compose_file=$(get_compose_file "$dir") || {
        log_error "No docker-compose.yml found in $dir"
        exit 1
    }

    local name
    name=$(get_project_name "$dir")

    log ""
    log "${CYAN}${BOLD}Project: $name${NC}"
    log "${DIM}$dir${NC}"
    log ""

    cd "$dir" || exit 1

    log "${CYAN}Container Status:${NC}"
    docker compose ps
    log ""

    log "${CYAN}Images:${NC}"
    docker compose images
    log ""

    if project_exists "$dir"; then
        local interval
        local status
        interval=$(grep -- "^$dir|" "$PROJECTS_FILE" | cut -d'|' -f3)
        status=$(grep -- "^$dir|" "$PROJECTS_FILE" | cut -d'|' -f4)

        log "${CYAN}Auto-Update:${NC}"
        if [ "$status" == "enabled" ]; then
            log_success "Enabled (every ${interval}h)"
        else
            log_warn "Disabled"
        fi
    else
        log "${CYAN}Auto-Update:${NC}"
        log_warn "Not registered"
        log_info "Run 'sudo $APP_NAME add' to enable auto-updates"
    fi
    log ""
}

cmd_start() {
    local dir="${1:-$(pwd)}"
    dir="$(cd "$dir" 2>/dev/null && pwd)" || {
        log_error "Directory not found: $1"
        exit 1
    }
    cd "$dir" || exit 1

    log_info "Starting containers..."
    docker compose up -d
    log_success "Containers started"
}

cmd_stop() {
    local dir="${1:-$(pwd)}"
    dir="$(cd "$dir" 2>/dev/null && pwd)" || {
        log_error "Directory not found: $1"
        exit 1
    }
    cd "$dir" || exit 1

    log_info "Stopping containers..."
    docker compose stop
    log_success "Containers stopped"
}

cmd_restart() {
    local dir="${1:-$(pwd)}"
    dir="$(cd "$dir" 2>/dev/null && pwd)" || {
        log_error "Directory not found: $1"
        exit 1
    }
    cd "$dir" || exit 1

    log_info "Restarting containers..."
    docker compose restart
    log_success "Containers restarted"
}

cmd_help() {
    log ""
    log "${CYAN}${BOLD}$APP_NAME${NC} v$APP_VERSION - $APP_DESCRIPTION"
    log ""
    log "${BOLD}USAGE:${NC}"
    log "  $APP_NAME <command> [options]"
    log ""
    log "${BOLD}PROJECT MANAGEMENT:${NC}"
    log "  ${GREEN}add${NC} [dir] [options]   Register project for auto-updates"
    log "      --interval <hrs>    Every N hours (default: 12)"
    log "      --at <HH:MM>        Daily at specific time"
    log "      --days <Mon,Tue>    Specific days (used with --at)"
    log "      --cron <expr>       Custom cron expression"
    log "  ${GREEN}remove${NC} [dir]          Unregister project"
    log "  ${GREEN}list${NC}                  List all registered projects"
    log "  ${GREEN}enable${NC} [dir]          Enable auto-updates for project"
    log "  ${GREEN}disable${NC} [dir]         Disable auto-updates for project"
    log ""
    log "${BOLD}CONTAINER OPERATIONS:${NC}"
    log "  ${GREEN}check${NC} [dir]           Check for available updates (dry-run)"
    log "  ${GREEN}update${NC} [dir]          Pull latest images and recreate containers"
    log "  ${GREEN}update-all${NC}            Update all registered projects"
    log "  ${GREEN}status${NC} [dir]          Show container status"
    log "  ${GREEN}start${NC} [dir]           Start containers"
    log "  ${GREEN}stop${NC} [dir]            Stop containers"
    log "  ${GREEN}restart${NC} [dir]         Restart containers"
    log "  ${GREEN}logs${NC} [dir] [lines]    Show update logs (default: 50 lines)"
    log ""
    log "${BOLD}SYSTEM:${NC}"
    log "  ${GREEN}config${NC} [key] [val]    Get or set global configuration"
    log "  ${GREEN}self-update${NC}           Update this tool to the latest version"
    log "  ${GREEN}install${NC}               Install $APP_NAME to system"
    log "  ${GREEN}uninstall${NC}             Remove $APP_NAME from system"
    log "  ${GREEN}version${NC}               Show version"
    log "  ${GREEN}help${NC}                  Show this help"
    log ""
    log "${BOLD}EXAMPLES:${NC}"
    log "  ${DIM}# Install the tool${NC}"
    log "  sudo $APP_NAME install"
    log ""
    log "  ${DIM}# Register current directory for 12-hour updates${NC}"
    log "  cd /opt/my-app && sudo $APP_NAME add"
    log ""
    log "  ${DIM}# Register with specific time${NC}"
    log "  sudo $APP_NAME add --at 03:00"
    log ""
    log "  ${DIM}# Register for specific days${NC}"
    log "  sudo $APP_NAME add --at 03:00 --days Mon,Fri"
    log ""
    log "  ${DIM}# Update a specific project now${NC}"
    log "  $APP_NAME update /opt/my-app"
    log ""
}

cmd_version() {
    log "$APP_NAME version $APP_VERSION"
}

cmd_interactive() {
    ensure_config

    while true; do
        clear
        log "${CYAN}"
        log "╔══════════════════════════════════════════════════════════╗"
        log "║       Docker Auto-Update Manager v$APP_VERSION               ║"
        log "╚══════════════════════════════════════════════════════════╝"
        log "${NC}"

        local current_dir="$(pwd)"
        local compose_file=$(get_compose_file "$current_dir" 2>/dev/null) || true

        log "${BLUE}Current directory:${NC} $current_dir"
        if [ -n "$compose_file" ]; then
            local name=$(get_project_name "$current_dir")
            log "${BLUE}Detected project:${NC} $name"
            if project_exists "$current_dir"; then
                log "${GREEN}Status: Registered for auto-updates${NC}"
            else
                log "${YELLOW}Status: Not registered${NC}"
            fi
        else
            log "${YELLOW}No docker-compose.yml in current directory${NC}"
        fi

        log ""
        log "${YELLOW}Select an option:${NC}"
        log ""
        log "  ${BOLD}Current Project:${NC}"
        log "  1) Update now              - Pull & restart"
        log "  2) Container status        - Show containers"
        log "  3) Start containers"
        log "  4) Stop containers"
        log "  5) Restart containers"
        log ""
        log "  ${BOLD}Auto-Update Management:${NC}"
        log "  a) Add/Register project    - Enable auto-updates (sudo)"
        log "  r) Remove project          - Disable auto-updates (sudo)"
        log "  c) Global Configuration    - Set webhook URL, etc."
        log "  l) List all projects"
        log "  u) Update all projects"
        log ""
        log "  v) View update logs"
        log "  h) Help"
        log "  0) Exit"
        log ""

        read -p "Enter choice: " choice
        log ""

        case $choice in
            1) cmd_update "$current_dir" ;;
            2) cmd_status "$current_dir" ;;
            3) cmd_start "$current_dir" ;;
            4) cmd_stop "$current_dir" ;;
            5) cmd_restart "$current_dir" ;;
            a|A)
                log "Schedule Options:"
                log "  Enter number (e.g. 12) for every N hours"
                log "  Enter time (e.g. 01:00) for daily update"
                log ""
                read -p "Schedule [12]: " input
                if [[ "$input" =~ : ]]; then
                    cmd_add "$current_dir" --at "$input"
                else
                    input="${input:-12}"
                    cmd_add "$current_dir" --interval "$input"
                fi
                ;;
            r|R) cmd_remove "$current_dir" ;;
            c|C) 
                read -p "Config Key (e.g. WEBHOOK_URL): " key
                if [ -n "$key" ]; then
                    read -p "Value: " value
                    cmd_config "$key" "$value"
                else
                    cmd_config
                fi
                ;;
            l|L) cmd_list ;;
            u|U) cmd_update_all ;;
            v|V) cmd_logs "$current_dir" ;;
            h|H) cmd_help ;;
            0)
                log "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                log_error "Invalid option"
                ;;
        esac

        log ""
        read -p "Press Enter to continue..."
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    local command="${1:-}"
    shift 2>/dev/null || true

    case "$command" in
        install)        cmd_install "$@" ;;
        self-update)    cmd_self_update "$@" ;;
        uninstall)      cmd_uninstall "$@" ;;
        config)         cmd_config "$@" ;;
        add)            cmd_add "$@" ;;
        remove|rm)      cmd_remove "$@" ;;
        list|ls)        cmd_list "$@" ;;
        check)          cmd_check "$@" ;;
        update)         cmd_update "$@" ;;
        update-single)  cmd_update_single "$@" ;;
        update-all)     cmd_update_all "$@" ;;
        enable)         cmd_enable "$@" ;;
        disable)        cmd_disable "$@" ;;
        logs)           cmd_logs "$@" ;;
        status)         cmd_status "$@" ;;
        start)          cmd_start "$@" ;;
        stop)           cmd_stop "$@" ;;
        restart)        cmd_restart "$@" ;;
        help|-h|--help) cmd_help ;;
        version|-v|--version) cmd_version ;;
        "")             cmd_interactive ;;
        *)
            log_error "Unknown command: $command"
            log_info "Run '$APP_NAME help' for usage"
            exit 1
            ;;
    esac
}

main "$@"
