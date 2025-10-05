# 🐳 dostic - Docker + Restic Backup Solution

**dostic** is a lightweight backup solution that combines Docker and Restic to provide seamless backups of Docker volumes, databases, and folders. The name reflects its primary purpose: **Do**cker + Re**stic**.

## 🌟 Key Features

### Primary Focus: Docker Volume Backups
- **Native Docker Volume Support** - Directly backup named Docker volumes without stopping containers
- **Automatic Volume Discovery** - Finds and backs up all named volumes automatically
- **Flexible Exclusion** - Exclude volumes by exact name or regex pattern
- **Individual Volume Snapshots** - Each volume gets its own snapshot for selective restore

### Database-Aware Backups
- **PostgreSQL Support** - Automatic `pg_dumpall` with multiple user fallback strategies
- **MySQL/MariaDB Support** - Automatic `mysqldump` for complete database exports
- **Container-Specific Dumps** - Each database container is backed up separately
- **Zero Downtime** - Databases remain online during backup

### Additional Features
- **Folder Archiving** - Backup any local directory (nice-to-have feature)
- **S3-Compatible Storage** - Support for AWS S3, Backblaze B2, MinIO, etc.
- **Local Storage** - Simple file-system based repositories
- **Pure Restic Repository** - Creates standard Restic repositories for maximum compatibility
- **Tagged Snapshots** - Organized tagging system for easy snapshot identification

## 🎯 Why dostic?

**Minimal Requirements:**
- ✅ Docker (for running containers)
- ✅ Bash (for scripting)
- ❌ **No Restic installation required!** (runs in Docker container)

**Key Advantages:**
- 🐳 **Docker-Native** - Built specifically for Docker environments
- 💾 **Database-Aware** - Proper dump handling, not just file copying
- 📦 **Pure Restic** - Standard Restic repository format, use any Restic client
- 🔧 **Zero Dependencies** - Only Docker and Bash needed
- 🏷️ **Smart Tagging** - Clear organization with `postgres/container-name`, `volume/volume-name`, etc.
- 🔄 **Standard Workflows** - Backup, restore, forget, prune - all familiar Restic commands

## 📦 Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/dostic.git
cd dostic

# Create configuration file
cp .dostic.env.example .dostic.env
chmod 600 .dostic.env

# Edit configuration
vim .dostic.env
```

## ⚙️ Configuration

Create a `.dostic.env` file in your working directory:

### Local Repository Example
```bash
# Repository location (local path)
REPOSITORY="/mnt/backups/my-restic-repo"

# Password file (must have 0600 or 0700 permissions)
RESTIC_PASSWORD_FILE="/path/to/password-file"

# Cache volume name (optional, default: dostic_cache)
CACHE_VOLUME_NAME="dostic_cache"

# Backup configuration (optional)
BACKUP_BASEDIR="/tmp/backups"
HOST="$(hostname)"

# Folders to backup (optional, comma-separated)
# Format: /path/to/folder:tag-name or just /path/to/folder
BACKUP_FOLDERS="/etc:system-config,/home/user/data:user-data"

# Volume exclusions (optional)
EXCLUDE_VOLUMES="temp-volume,cache-volume"
EXCLUDE_VOLUMES_REGEX="^test-.*|.*-tmp$"

# Retention policy (optional, defaults shown)
KEEP_DAILY=14
KEEP_WEEKLY=12
KEEP_MONTHLY=12
KEEP_YEARLY=5
```

### S3-Compatible Repository Example
```bash
# Repository location (S3)
REPOSITORY="s3:s3.amazonaws.com/my-bucket/restic-repo"

# AWS credentials
AWS_ACCESS_KEY_ID="your-access-key"
AWS_SECRET_ACCESS_KEY="your-secret-key"

# Password file
RESTIC_PASSWORD_FILE="/path/to/password-file"

# Other settings...
```

### Backblaze B2 Example
```bash
# Repository location
REPOSITORY="s3:s3.us-west-002.backblazeb2.com/my-bucket/restic-repo"

# Backblaze credentials
AWS_ACCESS_KEY_ID="your-b2-key-id"
AWS_SECRET_ACCESS_KEY="your-b2-application-key"

# Password file
RESTIC_PASSWORD_FILE="/path/to/password-file"
```

## 🚀 Usage

### Initialize Repository
```bash
./dostic.sh init
```

### Full Backup
Backs up all PostgreSQL, MySQL databases, Docker volumes, and configured folders:
```bash
./dostic.sh backup
```

### Selective Backups
```bash
# Only PostgreSQL databases
./dostic.sh backup-postgres

# Only MySQL databases
./dostic.sh backup-mysql

# Only Docker volumes
./dostic.sh backup-volumes

# Only folders
./dostic.sh backup-folders
```

### View Snapshots
```bash
./dostic.sh snapshots
```

Example output:
```
ID        Time                 Host    Tags                      Paths
-------------------------------------------------------------------------
a1b2c3d4  2025-10-05 10:00:00  alice   postgres/my-db           /backups/postgres/my-db
e5f6g7h8  2025-10-05 10:01:00  alice   mysql/app-db             /backups/mysql/app-db
i9j0k1l2  2025-10-05 10:02:00  alice   volume/app-data          /backups/volumes/app-data
m3n4o5p6  2025-10-05 10:03:00  alice   folders/etc-config       /backups/folders/etc-config
```

### Restore Snapshot
```bash
# Restore latest snapshot
./dostic.sh restore latest /path/to/restore/target

# Restore specific snapshot
./dostic.sh restore a1b2c3d4 /path/to/restore/target
```

### Repository Statistics
```bash
./dostic.sh stats
```

### Remove Old Snapshots
```bash
# Apply retention policy and prune in one step
./dostic.sh forget

# Manual prune (only if needed)
./dostic.sh prune
```

### Check Repository Integrity
```bash
./dostic.sh check
```

### Unlock Repository
If a backup was interrupted:
```bash
./dostic.sh unlock
```

## 🏗️ Architecture

### Backup Structure

All backups are organized under `/backups/` in the container:

```
/backups/
├── postgres/
│   └── container-name/
│       └── container-name.dump.sql
├── mysql/
│   └── container-name/
│       └── container-name.dump.sql
├── volumes/
│   └── volume-name/
│       └── [volume contents]
└── folders/
    └── folder-tag/
        └── [folder contents]
```

### Snapshot Tags

- **PostgreSQL**: `postgres/container-name`
- **MySQL**: `mysql/container-name`
- **Docker Volumes**: `volume/volume-name`
- **Folders**: `folders/folder-tag`

### Container Detection

- **PostgreSQL**: Detects containers with port 5432 exposed
- **MySQL**: Detects containers with port 3306 exposed
- **Docker Volumes**: Lists all named volumes (excludes hash-only volumes)

### Database Backup Process

**PostgreSQL:**
1. Detects all PostgreSQL containers
2. Tries multiple user strategies: `postgres`, `${POSTGRES_USER}`, `$(whoami)`, default
3. Runs `pg_dumpall` inside the container
4. Copies dump to host
5. Creates Restic snapshot

**MySQL:**
1. Detects all MySQL containers
2. Runs `mysqldump` with `${MYSQL_ROOT_PASSWORD}` from container environment
3. Copies dump to host
4. Creates Restic snapshot

## 🔒 Security

### Password File
The password file must have strict permissions:
```bash
chmod 600 /path/to/password-file
```

dostic validates this on startup and will refuse to run with insecure permissions.

### Secrets
- Database passwords are read from container environment variables
- No passwords are exposed in command line arguments
- All sensitive data is mounted read-only in backup containers

## 📋 Examples

### Automated Daily Backups

Create a cron job:
```bash
# /etc/cron.d/dostic-backup
0 2 * * * root cd /path/to/dostic && ./dostic.sh backup >> /var/log/dostic-backup.log 2>&1
```

### Backup Only Specific Containers

Edit your `.dostic.env`:
```bash
# Exclude test databases
EXCLUDE_VOLUMES_REGEX="^test-.*"
```

### Restore PostgreSQL Database

```bash
# 1. Find the snapshot
./dostic.sh snapshots | grep postgres/my-db

# 2. Restore to temporary location
./dostic.sh restore a1b2c3d4 /tmp/restore

# 3. Import the dump
docker exec -i my-db psql -U postgres < /tmp/restore/backups/postgres/my-db/my-db.dump.sql
```

### Restore Docker Volume

```bash
# 1. Stop the container using the volume
docker stop my-app

# 2. Restore the snapshot
./dostic.sh restore e5f6g7h8 /tmp/restore

# 3. Copy data back to volume
docker run --rm -v my-volume:/volume -v /tmp/restore/backups/volumes/my-volume:/backup alpine cp -r /backup/. /volume/

# 4. Start the container
docker start my-app
```

## 🔧 Troubleshooting

### "Password file must have permissions 0600 or 0700"
```bash
chmod 600 /path/to/password-file
```

### "Repository does not exist"
Initialize the repository first:
```bash
./dostic.sh init
```

### "Failed to dump database from container"
Check if the container is running and the database is accessible:
```bash
docker exec -it container-name psql -U postgres -c '\l'  # PostgreSQL
docker exec -it container-name mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "SHOW DATABASES;"  # MySQL
```

### Repository Locked
If a backup was interrupted:
```bash
./dostic.sh unlock
```

## 🤝 Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## 📄 License

MIT License - see [LICENSE](LICENSE) file for details.

Copyright (c) 2025 Peter Kranz

## 🙏 Credits

- [Restic](https://restic.net/) - The excellent backup program that powers dostic
- Built with ❤️ for the Docker community

## 🔗 Links

- [Restic Documentation](https://restic.readthedocs.io/)
- [Docker Documentation](https://docs.docker.com/)

---

**Note**: dostic creates standard Restic repositories. You can use the official Restic client to access, restore, or manage backups created by dostic. The Docker wrapper is only needed for the backup creation process.
