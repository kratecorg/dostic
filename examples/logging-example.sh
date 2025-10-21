#!/usr/bin/env bash
#
# Example usage of dostic logging system
#
# This demonstrates how to use the structured logging functions
# and how they integrate with syslog/journal
#

set -euo pipefail

# Source the logging library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/logging.sh"

echo "=== Dostic Logging Examples ==="
echo ""
echo "Logs are sent to:"
echo "  1. Syslog/Journal (always)"
echo "  2. Console with colors (only in TTY)"
echo ""
echo "To view in journal: journalctl -t dostic -f"
echo ""

# Basic logging examples
log_info "Starting backup process"
sleep 1

log_info "Repository initialized" "repo=production" "backend=s3"
sleep 1

log_notice "Backup completed successfully" "size=1.5GB" "duration=45s" "files=1234"
sleep 1

log_warn "High memory usage detected" "memory=85%" "threshold=80%"
sleep 1

log_error "Failed to connect to database" "host=db.example.com" "port=5432" "error=connection_refused"
sleep 1

# Debug logging (only shown if DEBUG=1)
log_debug "Container inspection" "container=postgres-prod" "status=running" "uptime=5d"
sleep 1

# Section headers
log_section "Database Backup" "type=postgres" "database=myapp"
log_info "Dumping database..." "database=myapp" "size=500MB"
log_success "Database dump completed" "file=/tmp/dump.sql"
sleep 1

log_section "Volume Backup" "volume=app-data"
log_info "Creating snapshot..." "volume=app-data"
log_success "Snapshot created" "snapshot_id=abc123"
sleep 1

# Command execution with timing
log_section "Restic Operations"
log_command "Testing restic connection" sleep 2
sleep 1

# Simulating an error
log_section "Error Handling Example"
log_error "Backup failed for container" "container=web-01" "reason=disk_full" "available=0MB"
log_critical "System disk space critical" "mountpoint=/" "available=1%" "required=10%"

echo ""
echo "=== Examples completed ==="
echo ""
echo "View logs with:"
echo "  journalctl -t dostic -n 50"
echo "  journalctl -t dostic -f"
echo "  journalctl -t dostic -p err"  # Only errors
echo ""
