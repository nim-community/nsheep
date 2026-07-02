# NimPack

A centralized Nim package registry. Hosted at [nimpack.org](https://nimpack.org).

## Architecture

```
src/
├── nsheep.nim           # Entry point
└── nsheep/
    ├── types.nim        # Domain types with invariants
    ├── config.nim       # Strict configuration loading
    ├── storage.nim      # Local filesystem storage
    ├── github.nim       # GitHub API client with ETag caching
    ├── ingest.nim       # Package ingestion logic
    ├── fetcher.nim      # Background fetcher from nimble packages
    └── server.nim       # HTTP server (mummy)
```

### Architecture

NimPack consists of two separate binaries:

1. **`nsheep`** - HTTP server that serves package metadata and tarballs
2. **`nsheep-fetcher`** - Background process that ingests packages from nimble registry

They communicate through the shared storage directory (local filesystem).

### Background Fetcher

The fetcher:
1. Fetches the official [nimble packages.json](https://github.com/nim-lang/packages) periodically
2. Validates packages by compiling them in Docker
3. Ingests all GitHub-hosted packages
4. Runs on a configurable interval (default: 1 hour)
5. Is resilient to individual package failures

The HTTP server is read-only - it only serves package data.


## Building

```bash
nimble build          # Debug build
nimble release        # Release build
```

## Running

```bash
# 1. Create config
cp cfg.example.yaml cfg.yaml
# Edit cfg.yaml

# 2. Run the server (serves packages)
./nsheep cfg.yaml

# 3. In another terminal, run the fetcher (ingests packages)
./nsheep-fetcher cfg.yaml
```

Or use Docker Compose to run both:

```bash
docker compose up -d
```

## Deployment

### VPS Requirements

- **OS**: Alpine 3.23+ or Ubuntu 22.04/24.04
- **RAM**: 2GB+ (Docker builds consume memory; previous OOM issues at ~939MB)
- **Disk**: 20GB+ (SQLite database + tarballs grow over time)
- **Docker**: Required for package build validation

### Docker Configuration

Enable IPv4 forwarding for container network access (needed for `nimble install` during validation):

```bash
echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf && sysctl -p
```

`/etc/docker/daemon.json`:

```json
{
  "iptables": true,
  "ip6tables": false,
  "storage-driver": "overlay2"
}
```

### Production Architecture

```
Cloudflare CDN → Nginx (SSL) → nsheep (:8080)
                               nsheep-fetcher (background)
```

- **Nginx**: SSL termination, static asset caching, reverse proxy
- **nsheep**: HTTP server serving package metadata and tarballs
- **nsheep-fetcher**: Background ingestion with Docker-based build validation

### Config

```yaml
server:
  bindAddr: "127.0.0.1"
  port: 8080

github:
  token: ""  # Optional: GitHub API token for higher rate limits

fetcher:
  interval: 28800  # 8 hours between cycles

validator:
  enabled: true
  dockerImage: "nimlang/nim:alpine"
  timeout: 300     # 5 minutes per build
  required: false  # Don't reject packages on build failure

local:
  dbPath: "./data/nsheep.db"
  tarballDir: "./data/tarballs"

storage: local
```

See [DEPLOY.md](DEPLOY.md) for full deployment instructions (nginx setup, OpenRC/systemd services, CI/CD, Cloudflare DNS).

## Configuration

```yaml
server:
  bindAddr: "127.0.0.1"
  port: 8080

github:
  token: ""  # Optional: GitHub API token for higher rate limits

local:
  tarballDir: "./data/tarballs"
  metadataDir: "./data/metadata"

storage: local
```

| Section | Description |
|---------|-------------|
| `server` | HTTP server bind address and port |
| `github` | GitHub API token (optional) |
| `local` | Local filesystem storage paths |
| `storage` | Storage backend (`local` only) |

## API

### GET /health
Health check.

### GET /packages.json
Nimble-compatible package list. Each entry uses `method: "download"` with a URL pointing to this server's `/download/:name/:version` endpoint.

### GET /api/v1/packages
List all packages.

### GET /api/v1/packages/:name
Get package details.

### GET /download/:name/:version
Download tarball.

## Error Handling

All errors are explicit:

- `StorageError` - File I/O failures
- `NotFoundError` - Resource doesn't exist  
- `CorruptionError` - Invalid data on disk
- `GitHubError` - API failures
- `IngestError` - Ingestion failures

No silent failures. No ignored return values.
