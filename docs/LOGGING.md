# Dostic Logging System

## Overview

The Dostic logging system is optimized for automated backup systems and uses **Syslog/systemd-journal** as the primary log destination. This enables centralized log aggregation and easy integration with modern monitoring systems like Loki.

## Architecture

```
┌─────────────┐
│   dostic    │
└──────┬──────┘
       │
       ├─────► syslog/journal (via logger)
       │       └─► Promtail → Loki
       │
       └─────► Console (only in TTY, optional with colors)
```

### Design Decisions

1. **Syslog First**: All logs go primarily to syslog/journal
2. **Structured Logging**: Key-value pairs for better filterability
3. **TTY Detection**: Colored output only in interactive shells
4. **No Timestamps**: Syslog/Journal automatically add timestamps
5. **Standard Priorities**: Uses syslog severity levels (info, warning, err, etc.)

## Usage

### Basic Logging

```bash
#!/usr/bin/env bash
source "lib/logging.sh"

# Simple logs
log_info "Backup started"
log_warn "High memory usage"
log_error "Connection failed"
log_success "Backup completed"
```

### Structured Logging

```bash
# With key-value pairs for Loki
log_info "Backup completed" "repo=production" "size=1.5GB" "duration=45s"
log_error "Connection failed" "host=db.example.com" "port=5432" "error=timeout"
log_debug "Container details" "container=postgres-prod" "status=running"
```

### Log Levels

```bash
LOG_LEVEL=DEBUG ./dostic.sh backup    # All logs including debug
LOG_LEVEL=WARN ./dostic.sh backup     # Only warnings and errors
LOG_LEVEL=ERROR ./dostic.sh backup    # Only errors
```

Available levels (ascending):
- `DEBUG` - Only when `DEBUG=1` or `LOG_LEVEL=DEBUG`
- `INFO` - Standard information (default)
- `NOTICE` - Successful operations
- `WARN` / `WARNING` - Warnings
- `ERROR` - Errors
- `CRIT` / `CRITICAL` - Critical errors

### Helper Functions

```bash
# Section headers
log_section "Database Backup" "type=postgres"

# Command execution with timing
log_command "Creating snapshot" docker exec db pg_dump ...
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LOG_LEVEL` | `INFO` | Minimum log level |
| `DOSTIC_LOG_TAG` | `dostic` | Syslog tag |
| `DEBUG` | - | Enables debug logging (set to `1`) |
| `NO_COLOR` | - | Disables colors even in TTY |

## Syslog/Journal Integration

### Viewing Logs

```bash
# All dostic logs (live)
journalctl -t dostic -f

# Last 50 entries
journalctl -t dostic -n 50

# Only errors
journalctl -t dostic -p err

# Time range
journalctl -t dostic --since "1 hour ago"

# JSON format (for parsing)
journalctl -t dostic -o json
```

### Log Format

Logs in the journal have the following format:
```
[LEVEL] message key1=value1 key2=value2
```

Example:
```
[INFO] Backup completed repo=production size=1.5GB duration=45s
[ERROR] Connection failed host=db.example.com error=timeout
```

## Loki Integration

### Promtail Configuration

```yaml
scrape_configs:
  - job_name: dostic
    journal:
      labels:
        job: dostic
      matches: _SYSTEMD_UNIT=syslog.service
    relabel_configs:
      - source_labels: ['__journal__systemd_unit']
        target_label: 'unit'
      - source_labels: ['__journal_syslog_identifier']
        regex: 'dostic'
        action: keep
    pipeline_stages:
      - regex:
          expression: '\[(?P<level>\w+)\] (?P<message>.*)'
      - labels:
          level:
```

### LogQL Queries

```logql
# Alle dostic logs
{job="dostic"}

# Nur Errors
{job="dostic"} |= "[ERROR]"

# Bestimmte Repository
{job="dostic"} |= "repo=production"

# Fehler mit Pattern
{job="dostic"} |= "[ERROR]" |= "connection"

# Backup-Dauer extrahieren
{job="dostic"} |= "Backup completed" | regexp "duration=(?P<duration>\d+)s"
```

## Testing

Test the logging system with:

```bash
# Basic test (with TTY output)
./examples/logging-example.sh

# Debug mode
DEBUG=1 ./examples/logging-example.sh

# Without colors
NO_COLOR=1 ./examples/logging-example.sh

# Only errors
LOG_LEVEL=ERROR ./examples/logging-example.sh

# View logs in journal
journalctl -t dostic -f
```

## Migration from Existing Code

### Before (echo)
```bash
echo "Starting backup..." >&2
echo "Backup completed: $size bytes"
echo "ERROR: Connection failed" >&2
```

### After (structured logging)
```bash
log_info "Starting backup..."
log_success "Backup completed" "size=${size}"
log_error "Connection failed" "host=${host}" "error=${error_msg}"
```

## Best Practices

### ✅ DO

```bash
# Structured data
log_info "Backup started" "repo=${repo}" "type=${backup_type}"

# Errors with context
log_error "Database connection failed" "host=${db_host}" "port=${db_port}" "error=${error}"

# Success with metrics
log_success "Backup completed" "duration=${duration}s" "size=${size_mb}MB" "files=${file_count}"
```

### ❌ DON'T

```bash
# Don't log secrets!
log_info "Connected to DB" "password=${DB_PASSWORD}"  # ❌

# Don't log binary data
log_info "File content: $(cat /dev/urandom | head -c 100)"  # ❌

# Don't log excessively in loops
for file in $(find / -type f); do
    log_debug "Processing ${file}"  # ❌ Too many logs
done
```

## Performance

- `logger` is very efficient (< 1ms per log)
- Logs are written asynchronously
- No custom log files = no rotation problems
- Journal compresses automatically

## Troubleshooting

### Logs Don't Appear in Journal

```bash
# Check if logger is available
which logger

# Test logger directly
logger -t dostic-test "Test message"
journalctl -t dostic-test -n 1

# Check journal service
systemctl status systemd-journald
```

### No Colors in Terminal

```bash
# Check if TTY is detected
[[ -t 1 ]] && echo "Is TTY" || echo "Not TTY"

# Force colors (not recommended)
unset NO_COLOR
```

### Debug Logs Don't Appear

```bash
# DEBUG must be set
DEBUG=1 ./dostic.sh backup

# Or set LOG_LEVEL to DEBUG
LOG_LEVEL=DEBUG ./dostic.sh backup
```
