#!/usr/bin/env bash
#
# logging.sh - Structured logging for dostic with syslog/journal integration
#
# Architecture:
# - Primary: Logs go to syslog/systemd-journal via 'logger'
# - Structured: Key-value pairs for Loki compatibility
# - Optional: Colored output when running in interactive TTY (for debugging)
#
# Usage:
#   log_info "Backup started" "repo=prod" "type=postgres"
#   log_error "Backup failed" "repo=prod" "error=connection_timeout"
#   log_debug "Container details" "container=db-prod" "size=1.2GB"
#
# Environment Variables:
#   LOG_LEVEL        - Minimum log level: DEBUG, INFO, WARN, ERROR (default: INFO)
#   DOSTIC_LOG_TAG   - Syslog tag (default: dostic)
#   DEBUG            - Enable debug logging (set to 1 or true)
#   NO_COLOR         - Disable colored output even in TTY
#

set -euo pipefail

# Configuration
LOG_LEVEL="${LOG_LEVEL:-INFO}"
DOSTIC_LOG_TAG="${DOSTIC_LOG_TAG:-dostic}"
DEBUG="${DEBUG:-}"

# Log level priorities (for filtering)
declare -A LOG_PRIORITIES=(
    ["DEBUG"]=0
    ["INFO"]=1
    ["NOTICE"]=2
    ["WARN"]=3
    ["WARNING"]=3
    ["ERROR"]=4
    ["CRIT"]=5
    ["CRITICAL"]=5
)

# Current log level priority
CURRENT_LOG_LEVEL_PRIORITY="${LOG_PRIORITIES[${LOG_LEVEL}]:-1}"

# Color codes (only used when outputting to TTY)
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    COLOR_RESET="\033[0m"
    COLOR_RED="\033[0;31m"
    COLOR_YELLOW="\033[0;33m"
    COLOR_GREEN="\033[0;32m"
    COLOR_BLUE="\033[0;34m"
    COLOR_GRAY="\033[0;90m"
    COLOR_BOLD="\033[1m"
else
    COLOR_RESET=""
    COLOR_RED=""
    COLOR_YELLOW=""
    COLOR_GREEN=""
    COLOR_BLUE=""
    COLOR_GRAY=""
    COLOR_BOLD=""
fi

# Detect if we're running in a TTY
IS_TTY=false
if [[ -t 1 ]]; then
    IS_TTY=true
fi

#
# Internal function to format structured log data
#
# Args:
#   $1 - Log level
#   $2 - Message
#   $@ - Key-value pairs (optional)
#
function _format_log_message() {
    local level="$1"
    shift
    local message="$1"
    shift
    
    # Build structured log line
    local structured=""
    if [[ $# -gt 0 ]]; then
        structured=" $*"
    fi
    
    echo "${message}${structured}"
}

#
# Internal function to check if log level should be printed
#
function _should_log() {
    local level="$1"
    local level_priority="${LOG_PRIORITIES[${level}]:-1}"
    
    [[ ${level_priority} -ge ${CURRENT_LOG_LEVEL_PRIORITY} ]]
}

#
# Log to syslog/journal via logger
#
# Args:
#   $1 - Syslog priority (e.g., user.info, user.err)
#   $2 - Log level (for filtering)
#   $3 - Message
#   $@ - Additional structured data
#
function _log_to_syslog() {
    local priority="$1"
    shift
    local level="$1"
    shift
    
    if ! _should_log "${level}"; then
        return 0
    fi
    
    local formatted_message
    formatted_message="$(_format_log_message "${level}" "$@")"
    
    # Log to syslog with level prefix
    if command -v logger >/dev/null 2>&1; then
        logger -t "${DOSTIC_LOG_TAG}" -p "${priority}" "[${level}] ${formatted_message}"
    fi
}

#
# Output to console (only in TTY or when explicitly enabled)
#
function _log_to_console() {
    local level="$1"
    shift
    local color="$1"
    shift
    local stream="$1"
    shift
    
    if ! _should_log "${level}"; then
        return 0
    fi
    
    local formatted_message
    formatted_message="$(_format_log_message "${level}" "$@")"
    
    # Only output to console in TTY or if not piped
    if [[ "${IS_TTY}" == "true" ]]; then
        local timestamp
        timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
        echo -e "${COLOR_GRAY}${timestamp}${COLOR_RESET} ${color}[${level}]${COLOR_RESET} ${formatted_message}" >&${stream}
    fi
}

#
# Public logging functions
#

# Log DEBUG message (only if DEBUG is enabled)
function log_debug() {
    if [[ -z "${DEBUG}" ]]; then
        return 0
    fi
    
    _log_to_syslog "user.debug" "DEBUG" "$@"
    _log_to_console "DEBUG" "${COLOR_GRAY}" 1 "$@"
}

# Log INFO message
function log_info() {
    _log_to_syslog "user.info" "INFO" "$@"
    _log_to_console "INFO" "${COLOR_BLUE}" 1 "$@"
}

# Log NOTICE message (success-like operations)
function log_notice() {
    _log_to_syslog "user.notice" "NOTICE" "$@"
    _log_to_console "NOTICE" "${COLOR_GREEN}" 1 "$@"
}

# Alias for success messages
function log_success() {
    log_notice "$@"
}

# Log WARNING message
function log_warn() {
    _log_to_syslog "user.warning" "WARN" "$@"
    _log_to_console "WARN" "${COLOR_YELLOW}" 2 "$@"
}

# Alias
function log_warning() {
    log_warn "$@"
}

# Log ERROR message
function log_error() {
    _log_to_syslog "user.err" "ERROR" "$@"
    _log_to_console "ERROR" "${COLOR_RED}" 2 "$@"
}

# Log CRITICAL message
function log_critical() {
    _log_to_syslog "user.crit" "CRIT" "$@"
    _log_to_console "CRIT" "${COLOR_RED}${COLOR_BOLD}" 2 "$@"
}

# Alias
function log_crit() {
    log_critical "$@"
}

#
# Helper function to log command execution with timing
#
# Usage:
#   log_command "Backing up database" docker exec db pg_dump ...
#
function log_command() {
    local description="$1"
    shift
    
    log_debug "Executing command" "description=${description}" "command=$*"
    
    local start_time
    start_time=$(date +%s)
    
    if "$@"; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_debug "Command completed" "description=${description}" "duration=${duration}s"
        return 0
    else
        local exit_code=$?
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_error "Command failed" "description=${description}" "exit_code=${exit_code}" "duration=${duration}s"
        return ${exit_code}
    fi
}

#
# Helper to log a section/operation start
#
function log_section() {
    local section="$1"
    shift
    log_info "=== ${section} ===" "$@"
}

# Export functions for use in other scripts
export -f log_debug
export -f log_info
export -f log_notice
export -f log_success
export -f log_warn
export -f log_warning
export -f log_error
export -f log_critical
export -f log_crit
export -f log_command
export -f log_section
