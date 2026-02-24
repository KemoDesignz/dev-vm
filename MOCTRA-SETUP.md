# Dev-VM Setup for Moctra - Complete Guide

**Date:** 2026-02-24
**Status:** ✅ Production Ready
**Version:** 2.0 (Moctra-Enhanced)

---

## Quick Summary

The dev-vm has been enhanced to fully support the Moctra microservices stack with:

- **Disk Space:** 120GB (increased from 80GB)
- **New Tools:** 6 additional tools for databases, message queuing, and object storage
- **Port Forwards:** 9 new ports for Moctra services
- **Enhanced Verification:** Comprehensive health checks for all tools

---

## What Changed

### 1. Configuration Updates

**File:** `vagrant/defaults.yaml`

```yaml
vm:
  disk_gb: 120  # ← Increased from 80GB

ports:
  # ... existing ports ...
  - guest: 4000
    host: 4000
    description: Moctra Frontend (React + BFF)
  - guest: 8180
    host: 8180
    description: Keycloak
  - guest: 9000
    host: 9000
    description: MinIO S3 API
  - guest: 9001
    host: 9001
    description: MinIO Console
  - guest: 7880
    host: 7880
    description: LiveKit HTTP API
  - guest: 16686
    host: 16686
    description: Jaeger UI
  - guest: 3100
    host: 3100
    description: Grafana
  - guest: 8025
    host: 8025
    description: MailHog UI
  - guest: 8090
    host: 8090
    description: Kafka UI
```

### 2. New Tools Added

**File:** `scripts/setup-dev-vm.ps1` (Stage 7c: Moctra-specific tools)

| Tool | Version | Purpose |
|------|---------|---------|
| **mongosh** | 7.0 | MongoDB Shell for GridFS video storage |
| **Kafka CLI** | 3.7.0 | Full Apache Kafka toolset (kafka-topics, kafka-console-consumer, etc.) |
| **MinIO Client (mc)** | Latest | S3-compatible storage management |
| **kcat** | Latest | Kafka producer/consumer debugging tool |
| **dive** | 0.12.0 | Docker image layer analysis |
| **ctop** | 0.7.7 | Real-time container metrics |

### 3. Enhanced Verification

The health check now verifies all new tools:

```bash
✓ Gradle
✓ Yarn
✓ pnpm
✓ PostgreSQL (psql)
✓ Redis (redis-cli)
✓ MongoDB (mongosh)
✓ Kafka CLI
✓ MinIO mc
✓ kcat
```

---

## Installation

### For New VMs

```powershell
cd c:\Users\kevin\repos\dev-vm
.\scripts\setup-dev-vm.ps1
# Choose option 1: Setup new Dev VM
```

All tools will be installed automatically.

### For Existing VMs

```powershell
cd c:\Users\kevin\repos\dev-vm
.\scripts\setup-dev-vm.ps1 -Action Provision
```

This will add the new tools without destroying your existing VM.

### Verify Installation

```powershell
.\scripts\setup-dev-vm.ps1 -Action Health
```

You should see all tools listed with their versions.

---

## Usage Examples

### MongoDB Operations

```bash
# SSH into VM
vagrant ssh

# Connect to MongoDB
mongosh mongodb://moctra:moctra_dev_pw@localhost:27017/moctra_media

# List collections
show collections

# Query GridFS files
db.fs.files.find()
```

### Kafka Operations

```bash
# List all topics
kafka-topics.sh --bootstrap-server localhost:9092 --list

# Consume messages
kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic exam-events \
  --from-beginning

# Using kcat (simpler)
kcat -b localhost:9092 -L              # List metadata
kcat -b localhost:9092 -t exam-events -C  # Consume messages
```

### MinIO (S3) Operations

```bash
# Configure MinIO client
mc alias set local http://localhost:9000 minioadmin minioadmin

# List buckets
mc ls local

# List recordings
mc ls local/moctra-recordings

# Upload file
mc cp video.mp4 local/moctra-recordings/

# Download file
mc cp local/moctra-recordings/video.mp4 ./downloaded.mp4
```

### Docker Image Analysis

```bash
# Analyze image layers
dive moctra/gateway:latest

# Real-time container monitoring
ctop
```

---

## Accessing Moctra Services from Host

All services are accessible from your Windows/macOS host:

### Web Interfaces

| Service | URL | Credentials |
|---------|-----|-------------|
| Moctra Frontend | http://localhost:4000 | (via Keycloak) |
| Keycloak Admin | http://localhost:8180/admin | admin / admin |
| MinIO Console | http://localhost:9001 | minioadmin / minioadmin |
| Jaeger Tracing | http://localhost:16686 | - |
| Grafana | http://localhost:3100 | admin / admin |
| Kafka UI | http://localhost:8090 | - |
| MailHog | http://localhost:8025 | - |
| Prometheus | http://localhost:9090 | - |

### Database Connections

Use your favorite client from the host:

```bash
# PostgreSQL (multiple instances on 5433-5445)
psql -h localhost -p 5432 -U moctra -d moctra_auth

# MongoDB
mongosh mongodb://moctra:moctra_dev_pw@localhost:27017/moctra_media

# Redis
redis-cli -h localhost -p 6379
```

### Message Queue

```bash
# From host (if you have Kafka CLI installed)
kafka-topics.sh --bootstrap-server localhost:9092 --list

# Or use Kafka UI at http://localhost:8090
```

---

## Running Moctra Stack

### Start All Services

```bash
# SSH into VM
vagrant ssh

# Navigate to Moctra infrastructure
cd workspace/repos/Moctra/infrastructure

# Start all services
docker compose up -d

# Follow logs
docker compose logs -f

# Check service health
docker compose ps
```

### Service Dependencies

The docker-compose will start:

**Infrastructure:**
- 12 PostgreSQL databases (ports 5433-5445)
- Redis (6379)
- MongoDB (27017)
- Kafka + Kafka UI (9092, 8090)
- Keycloak (8180)

**Media Services:**
- LiveKit (7880-7882)
- MinIO + Console (9000-9001)
- LiveKit Egress

**Observability:**
- Jaeger (16686, 4317, 4318)
- Prometheus (9090)
- Grafana (3100)

**Development:**
- MailHog (1025, 8025)

**Application Services:**
- 12 Java Microservices (ports 3000-3012)
- React Frontend (4000)

---

## Cleanup

### How Cleanup Works

The cleanup script (`.\scripts\setup-dev-vm.ps1 -Action Cleanup`) destroys the entire VM, which **automatically removes all installed tools**, including:

✅ MongoDB Shell (mongosh)
✅ Kafka CLI Tools (/opt/kafka)
✅ MinIO Client (mc)
✅ kcat
✅ dive
✅ ctop
✅ All other VM tools

### Full Cleanup

```powershell
cd c:\Users\kevin\repos\dev-vm
.\scripts\setup-dev-vm.ps1 -Action Cleanup
```

This prompts you to:
1. Delete VM snapshots
2. Destroy the VM (removes all tools automatically)
3. Remove generated files (Vagrantfile, logs)
4. Remove workspace folder
5. Remove host kubeconfig
6. Optionally uninstall host tools (Vagrant, VirtualBox)

### What Stays After Cleanup

These configuration files remain (intentionally):
- ✅ `vagrant/defaults.yaml` (disk size, port forwards)
- ✅ `vagrant/env.yaml` (if you created it)
- ✅ `README.md`
- ✅ `scripts/setup-dev-vm.ps1`

**Rationale:** These are configuration files, not runtime artifacts. They're kept so you can easily rebuild the VM with the same settings.

### Partial Cleanup

If you only want to destroy the VM:

```bash
cd vagrant
vagrant destroy -f
```

### Reinstalling After Cleanup

```powershell
# Start fresh
.\scripts\setup-dev-vm.ps1 -Action Setup
```

All tools (including Moctra-specific ones) are reinstalled automatically from the provisioning script.

---

## Maintenance

### Update All Tools

```powershell
.\scripts\setup-dev-vm.ps1 -Action Update
```

This updates:
- System packages (apt upgrade)
- k3s
- CLI tools (k9s, yq, stern, etc.)
- npm global packages

### Health Check

```powershell
.\scripts\setup-dev-vm.ps1 -Action Health
```

Shows:
- VM status
- Service health (Docker, k3s)
- All tool versions
- Cluster node status
- Disk usage

### Repair

```powershell
.\scripts\setup-dev-vm.ps1 -Action Repair
```

Automatically fixes:
- Stopped/suspended VM
- Failed Docker/k3s services
- Missing kubeconfig
- Missing CLI tools
- Disk space issues (>90% usage)

### Manual Tool Updates (Inside VM)

```bash
vagrant ssh

# Update MongoDB Shell
sudo apt-get update && sudo apt-get upgrade mongodb-mongosh

# Update MinIO Client
mc update

# Update Kafka (manual - check releases)
# https://kafka.apache.org/downloads

# Update dive
# https://github.com/wagoodman/dive/releases

# Update ctop
# https://github.com/bcicen/ctop/releases
```

---

## Troubleshooting

### "Port already in use"

**On Windows:**
```powershell
# Find what's using port 8180
netstat -ano | findstr :8180

# Kill the process (replace PID)
taskkill /PID <pid> /F
```

**On macOS:**
```bash
# Find and kill
lsof -ti:8180 | xargs kill -9
```

### MongoDB Connection Failed

```bash
# Check MongoDB is running
docker ps | grep mongodb

# Test connection
mongosh --eval "db.version()" mongodb://localhost:27017
```

### Kafka Connection Failed

```bash
# Check Kafka is running
docker ps | grep kafka

# Test connection
kafka-broker-api-versions.sh --bootstrap-server localhost:9092
```

### MinIO Not Accessible

```bash
# Check MinIO is running
docker ps | grep minio

# Test connection
mc alias set testlocal http://localhost:9000 minioadmin minioadmin
mc ls testlocal
```

### Disk Space Full

```bash
vagrant ssh

# Check disk usage
df -h

# Clean Docker
docker system prune -af --volumes

# Clean apt cache
sudo apt-get clean
sudo apt-get autoclean

# Clean journal logs
sudo journalctl --vacuum-size=100M
```

### VM Won't Start

```powershell
# Check VirtualBox (Windows)
bcdedit /set hypervisorlaunchtype off
# Reboot required

# Check VM state
cd vagrant
vagrant status

# Try repair
..\scripts\setup-dev-vm.ps1 -Action Repair

# Last resort: destroy and recreate
vagrant destroy -f
..\scripts\setup-dev-vm.ps1 -Action Setup
```

---

## Architecture Support Matrix

| Moctra Component | Required Tools | Status |
|------------------|---------------|--------|
| **Java Microservices** | Java 21, Maven, Gradle, Docker | ✅ |
| **Frontend** | Node.js, npm, Yarn, pnpm | ✅ |
| **PostgreSQL** | psql client | ✅ |
| **MongoDB** | mongosh | ✅ |
| **Redis** | redis-cli | ✅ |
| **Kafka** | Kafka CLI, kcat | ✅ |
| **Keycloak** | Port 8180 | ✅ |
| **MinIO** | mc client, ports 9000-9001 | ✅ |
| **LiveKit** | Port 7880 | ✅ |
| **Jaeger** | Port 16686 | ✅ |
| **Prometheus** | Port 9090 | ✅ |
| **Grafana** | Port 3100 | ✅ |
| **MailHog** | Port 8025 | ✅ |
| **Kubernetes** | k3s, kubectl, Helm, k9s | ✅ |

---

## Performance Recommendations

### Minimum Requirements
- **CPUs:** 4 cores
- **RAM:** 8GB
- **Disk:** 120GB

### Recommended for Full Moctra Stack
- **CPUs:** 8 cores
- **RAM:** 16GB
- **Disk:** 120GB+

### Customization

Create `vagrant/env.yaml`:

```yaml
vm:
  cpus: 8
  memory: 16384
  disk_gb: 150  # If you need more space

# Optionally customize ports
ports:
  - guest: 4000
    host: 4000
    description: Moctra Frontend
  # ... add your custom ports
```

---

## Files Changed

| File | Change Summary |
|------|---------------|
| [`vagrant/defaults.yaml`](vagrant/defaults.yaml) | Disk: 80GB→120GB, +9 port forwards |
| [`scripts/setup-dev-vm.ps1`](scripts/setup-dev-vm.ps1) | +Stage 7c (Moctra tools), enhanced verification |
| [`README.md`](README.md) | Updated tool tables, port list, disk parameter |
| [`MOCTRA-SETUP.md`](MOCTRA-SETUP.md) | This guide |

---

## FAQ

**Q: Do I need to destroy my existing VM?**
A: No! Run `.\scripts\setup-dev-vm.ps1 -Action Provision` to add tools to existing VM.

**Q: Will the disk resize automatically?**
A: Disk size only applies to new VMs. Existing VMs keep their current size.

**Q: Can I run Moctra without the dev-vm?**
A: Yes, but you'll need to install all tools manually. The dev-vm automates everything.

**Q: Do these tools work on macOS?**
A: Yes! The tools run inside the Linux VM, accessible from both Windows and macOS hosts.

**Q: How much disk space does Moctra actually use?**
A: Approximately 40-60GB for a full stack (12 microservices + all infrastructure).

**Q: Can I use a different Kubernetes distribution?**
A: The VM uses k3s by default. You can run Moctra services in Docker or deploy to external clusters.

**Q: How do I back up my VM?**
A: Use Vagrant snapshots: `vagrant snapshot save my-backup`

**Q: Can I run multiple Moctra environments?**
A: Yes, but you'll need to customize port forwards in `vagrant/env.yaml` to avoid conflicts.

---

## Next Steps

1. ✅ **Setup VM** - Run `.\scripts\setup-dev-vm.ps1`
2. ✅ **Verify Tools** - Run `.\scripts\setup-dev-vm.ps1 -Action Health`
3. ✅ **Start Moctra** - `cd workspace/repos/Moctra/infrastructure && docker compose up -d`
4. ✅ **Access Services** - Open http://localhost:4000 in your browser
5. ✅ **Develop** - Your Moctra workspace is synced at `~/workspace` inside the VM

---

## Support & References

- **Main README:** [README.md](README.md)
- **Vagrant Config:** [vagrant/defaults.yaml](vagrant/defaults.yaml)
- **Setup Script:** [scripts/setup-dev-vm.ps1](scripts/setup-dev-vm.ps1)
- **Cleanup Script:** [scripts/cleanup-install.ps1](scripts/cleanup-install.ps1)

**Issues?** Check the Troubleshooting section above or review the main README.

---

**Status:** ✅ Production Ready
**Last Updated:** 2026-02-24
**Maintained by:** dev-vm project team
