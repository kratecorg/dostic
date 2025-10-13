# Changelog

All notable changes to dostic will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2025-10-13

### Added
- Version information system
- `--version` / `-v` command line flag to display version
- Version number in help output
- Version number displayed at backup start
- CHANGELOG.md to track project changes

### Changed
- Help output now shows "dostic v0.2.0 - Docker + Restic Backup Solution" header
- Backup command now displays version in startup banner

## [0.1.0] - 2025-10-05

### Added
- Initial release of dostic
- Docker volume backup functionality
- PostgreSQL database backup with pg_dumpall
- MySQL/MariaDB database backup with mysqldump
- System folder backup capability
- Restic repository management (init, backup, restore, forget, prune, check)
- Comprehensive error handling for all Docker commands
- `.dostic.env` configuration file support
- `.dostic.env.example` with extensive documentation
- Support for multiple storage backends (S3, Backblaze B2, local)
- Smart tagging system (postgres/container, mysql/container, volume/name, folder/path)
- Volume exclusion by name or regex pattern
- Flexible retention policies
- MIT License
- Comprehensive README.md with:
  - Installation instructions
  - Configuration examples
  - Usage guide
  - Command reference
  - Restore examples
  - Troubleshooting section

### Security
- Password file permission validation (must be 0600)
- Credentials isolated in .dostic.env file
- `set -euo pipefail` for safe bash execution

### Technical
- Modular architecture with lib/ directory structure
- Separation of concerns (config, validation, docker-args, restic functions)
- Automatic container discovery via Docker API
- Anonymous volume filtering (excludes 64-character hash volumes)
- Absolute path resolution for reliable backups

[Unreleased]: https://github.com/kratecorg/dostic/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/kratecorg/dostic/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/kratecorg/dostic/releases/tag/v0.1.0
