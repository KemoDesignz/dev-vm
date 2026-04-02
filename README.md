# Dev VM — Ubuntu 24.04 LTS Full-Stack Development Environment

One-command setup for a **headless Ubuntu 24.04 LTS VM** on **Windows or macOS**. Runs inside VirtualBox, managed by Vagrant, with a full dev-tool stack pre-installed. Kubeconfig is automatically exported to the host so you can use `kubectl`, `helm`, and `docker` from your terminal without SSH.

---

## Installation

### Step 1: Prerequisites

#### Windows
1. **Windows 10 or 11** with hardware virtualization enabled in BIOS (VT-x / AMD-V)
2. **Hyper-V must be disabled** — VirtualBox cannot run alongside Hyper-V:
   ```powershell
   # Run as Administrator, then reboot
   bcdedit /set hypervisorlaunchtype off
   ```
3. **PowerShell 5.1+** (pre-installed on Windows 10/11)

#### macOS
1. **macOS 12+** (Monterey or later)
2. **Homebrew** — install if you don't have it:
   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```
3. **PowerShell Core** — required to run the setup script:
   ```bash
   brew install --cask powershell
   ```

> The script automatically installs VirtualBox, Vagrant, Helm, Docker CLI, Temurin JDK 21, and Maven via winget (Windows) or Homebrew (macOS). No manual installs needed beyond the prerequisites above.

### Step 2: Clone and Run

#### Windows

```powershell
# Allow script execution (one-time)
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Unrestricted

# Clone and run
git clone <repo-url>
cd dev-vm
.\scripts\setup-dev-vm.ps1
```

#### macOS

```bash
git clone <repo-url>
cd dev-vm
pwsh ./scripts/setup-dev-vm.ps1
```

### Step 3: Follow the Prompts

The interactive menu will appear:

```
  1) Setup new Dev VM
  2) Clean up / destroy Dev VM
  3) Health check
  4) Update VM software
  5) Re-provision VM
  6) Repair VM (diagnose & fix)
```

Select **1** to start setup. You'll be asked for:

| Prompt | What to enter | Required? |
|--------|--------------|-----------|
| VM name | Name for the VirtualBox VM | No (default: `dev-vm`) |
| CPUs | Number of vCPUs | No (default: `8`) |
| Memory | RAM in MB | No (default: `16384`) |
| Disk size | Root disk in GB | No (default: `120`) |
| VM private IP | Host-only network IP | No (default: `192.168.56.10`) |
| GitHub token | Personal access token for API calls | Optional but recommended |
| Docker Hub user/token | For `docker login` inside VM | Optional |

Press Enter to accept defaults. The full setup takes ~10-15 minutes depending on your internet speed.

### Step 4: Verify

After setup completes, connect to the VM and verify:

```powershell
# SSH into the VM
cd vagrant
vagrant ssh

# Inside the VM — check the stack
docker version
kubectl get nodes
java -version
mvn --version
node -v
helm version --short
k9s   # press Ctrl+C to exit
```

### Non-Interactive / CI Mode

Skip all prompts with `-SkipConfirm` and pass settings as parameters:

```powershell
.\scripts\setup-dev-vm.ps1 -Action Setup -CPUs 4 -Memory 8192 -DiskGB 50 -SkipConfirm
```

---

## Using the VM from Your Host

The setup script installs `kubectl`, `helm`, and `docker` on your host and exports the kubeconfig automatically. Set these environment variables to use them:

#### PowerShell (Windows or macOS)
```powershell
$env:KUBECONFIG = "$HOME/.kube/config-dev-vm"
$env:DOCKER_HOST = "tcp://192.168.56.10:2375"

kubectl get nodes
helm install my-release my-chart
docker ps
```

#### Bash / Zsh (macOS)
```bash
export KUBECONFIG="$HOME/.kube/config-dev-vm"
export DOCKER_HOST="tcp://192.168.56.10:2375"

kubectl get nodes
helm install my-release my-chart
docker ps
```

> **Tip:** Add these exports to your shell profile (`~/.bashrc`, `~/.zshrc`, or PowerShell `$PROFILE`) to make them permanent.

---

## Day-to-Day Management

All management is done through the same script. Either use the interactive menu or pass `-Action`:

| Action | Command | What it does |
|--------|---------|-------------|
| **Health check** | `.\scripts\setup-dev-vm.ps1 -Action Health` | Reports VM, service, disk, memory, and tool status |
| **Update** | `.\scripts\setup-dev-vm.ps1 -Action Update` | Updates all VM software (apt, k3s, CLI tools, npm) |
| **Repair** | `.\scripts\setup-dev-vm.ps1 -Action Repair` | Diagnoses and auto-fixes common issues |
| **Re-provision** | `.\scripts\setup-dev-vm.ps1 -Action Provision` | Re-runs all provisioning stages |
| **Cleanup** | `.\scripts\setup-dev-vm.ps1 -Action Cleanup` | Destroys VM and removes all generated files |

### Snapshots

A `fresh-install` snapshot is created automatically after setup. To restore:

```powershell
cd vagrant
vagrant snapshot restore fresh-install
```

### Repair

The repair engine handles common failure scenarios automatically:
- Starts the VM if stopped or suspended
- Restarts Docker or k3s if not active
- Waits for the Kubernetes node to become Ready
- Re-extracts the host kubeconfig if missing or broken
- Reinstalls missing CLI tools (k9s, yq, lazydocker, kubectx, kubens)
- Cleans disk space if usage exceeds 90%

Repair also runs automatically after initial setup and after provisioning retries.

---

## Configuration

Settings are driven by two YAML files in the `vagrant/` directory:

| File | Purpose | Committed? |
|------|---------|------------|
| `vagrant/defaults.yaml` | Default VM settings and port forwards | Yes |
| `vagrant/env.yaml` | Your personal overrides | No (gitignored) |

### Precedence

```
CLI params (-CPUs 8)  >  env.yaml  >  defaults.yaml  >  interactive prompt
```

### Customizing with env.yaml

Create `vagrant/env.yaml` to override any settings. Scalar values under `vm:` are merged per-key. The `ports` list is replaced entirely if present.

```yaml
# vagrant/env.yaml
vm:
  cpus: 8
  memory: 16384

# Override port forwards (replaces the entire list)
ports:
  - guest: 6443
    host: 6443
    description: k3s API
  - guest: 8080
    host: 8080
  - guest: 3000
    host: 3000
  - guest: 5432
    host: 5432
    description: PostgreSQL

# Store credentials locally (this file is gitignored)
credentials:
  github_token: ghp_xxxxxxxxxxxxxxxxxxxx
  dockerhub_user: myuser
  dockerhub_token: dckr_pat_xxxxxxxxxxxx
```

If you enter credentials interactively during setup, the script offers to save them to `env.yaml` automatically.

---

## VM Tool Stack

### Core
| Tool | Description |
|------|-------------|
| Docker CE | Container engine with Compose and Buildx plugins |
| k3s | Lightweight Kubernetes |
| Helm | Kubernetes package manager |
| kubectl | Kubernetes CLI (ships with k3s) |

### Languages & Build Tools
| Tool | Description |
|------|-------------|
| Java 21 | OpenJDK headless |
| Maven | Java build tool |
| Node.js LTS | JavaScript runtime + npm |
| Yarn / pnpm | Alternative Node.js package managers |
| Python 3 | Python 3 with pip and venv |

### Database & Messaging Clients
| Tool | Description |
|------|-------------|
| psql | PostgreSQL client |
| mysql | MySQL/MariaDB client |
| redis-cli | Redis client |
| Kafka CLI | Apache Kafka utilities (kafka-topics, kafka-console-consumer, etc.) |
| kcat | Kafka producer/consumer CLI (formerly kafkacat) |
| MinIO Client (mc) | S3-compatible object storage CLI |

### Infrastructure & DevOps
| Tool | Description |
|------|-------------|
| Terraform | Infrastructure as Code |
| GitHub CLI (gh) | GitHub from the command line |

### Monitoring & Debugging
| Tool | Description |
|------|-------------|
| k9s | Kubernetes terminal UI |
| stern | Multi-pod log tailing |
| kubectx / kubens | Fast context & namespace switching |
| lazydocker | Docker terminal UI |
| dive | Docker image layer explorer |
| ctop | Container metrics viewer |
| yq / jq | YAML / JSON processors |

---

## Parameters Reference

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-Action` | Skip menu: `Setup`, `Cleanup`, `Health`, `Update`, `Provision`, `Repair` | interactive |
| `-VMName` | VM name | `dev-vm` |
| `-CPUs` | vCPU count (1-32) | `8` |
| `-Memory` | RAM in MB (1024-65536) | `16384` |
| `-DiskGB` | Root disk in GB (10-500) | `120` |
| `-PrivateIP` | Host-only network IP | `192.168.56.10` |
| `-GitHubToken` | GitHub PAT (injected into VM, used for API calls) | optional |
| `-DockerHubToken` | Docker Hub token | optional |
| `-DockerHubUser` | Docker Hub username (enables `docker login`) | optional |
| `-K3sVersion` | Pin k3s version (e.g. `v1.31.4+k3s1`) | latest |
| `-NodeVersion` | Pin Node.js major version (e.g. `22`) | `lts` |
| `-DryRun` | Generate Vagrantfile and exit | `false` |
| `-SkipConfirm` | Skip all confirmation prompts | `false` |

### Default Port Forwards

Configured in `vagrant/defaults.yaml`. Override with `vagrant/env.yaml`.

| Guest | Host | Purpose |
|-------|------|---------|
| 6443 | 6443 | k3s API |
| 2375 | -- | Docker API (via private network IP, always on) |
| 8080 | 8080 | App server |
| 3000 | 3000 | Dev server |
| 3001 | 3001 | Additional dev server |
| 4200 | 4200 | Angular dev server |
| 5173 | 5173 | Vite dev server |
| 30000 | 30000 | NodePort |
| 443 | 8443 | Ingress HTTPS |
| 5432 | 5432 | PostgreSQL |
| 3306 | 3306 | MySQL/MariaDB |
| 6379 | 6379 | Redis |
| 9092 | 9092 | Kafka |
| 5672 | 5672 | RabbitMQ |
| 9200 | 9200 | Elasticsearch |
| 9090 | 9090 | Prometheus |
| 4000 | 4000 | Moctra Frontend |
| 8180 | 8180 | Keycloak |
| 9000 | 9000 | MinIO S3 API |
| 9001 | 9001 | MinIO Console |
| 7880 | 7880 | LiveKit HTTP API |
| 16686 | 16686 | Jaeger UI |
| 3100 | 3100 | Grafana |
| 8025 | 8025 | MailHog UI |
| 8090 | 8090 | Kafka UI |

---

## Project Structure

```
dev-vm/
  scripts/
    setup-dev-vm.ps1      # Main setup & management script
    cleanup-install.ps1    # Cleanup script (called by setup-dev-vm.ps1)
  vagrant/
    defaults.yaml          # Default VM settings and port forwards (committed)
    env.yaml               # Your personal overrides (gitignored)
    Vagrantfile            # Generated by setup script (gitignored)
    .vagrant/              # Vagrant state (gitignored)
    setup-dev-vm.log       # Session log (gitignored)
  README.md
```

The shared workspace folder is created at `~/workspace` and synced into the VM at `/home/vagrant/workspace`.

---

## Troubleshooting

### VM fails to boot
Ensure hardware virtualization is enabled in BIOS and Hyper-V is disabled on Windows:
```powershell
# Run as Administrator, then reboot
bcdedit /set hypervisorlaunchtype off
```

### Setup fails during provisioning
The script will offer to retry. You can also re-provision without destroying the VM:
```powershell
.\scripts\setup-dev-vm.ps1 -Action Provision
```
Check the full log at `vagrant/setup-dev-vm.log` for detailed error output including line numbers and diagnostic dumps.

### SSH timeout during setup
The VM boot timeout is 600 seconds. If it's consistently timing out, increase CPUs/memory or check that VirtualBox is functioning (`VBoxManage list vms`).

### Docker permission denied
Reload the VM to apply group membership:
```powershell
cd vagrant
vagrant reload
vagrant ssh
```

### kubectl fails on host
Verify `KUBECONFIG` is set:
```powershell
$env:KUBECONFIG = "$HOME/.kube/config-dev-vm"
kubectl get nodes
```

### GitHub API rate limit during setup
CLI tool downloads use the GitHub API (60 requests/hour unauthenticated). Provide a token to avoid this:
```powershell
.\scripts\setup-dev-vm.ps1 -Action Setup -GitHubToken ghp_your_token_here
```
Or store it in `vagrant/env.yaml` under `credentials.github_token`.

### Vagrant not found after install
Reboot to refresh PATH, then re-run the script.

### Uninstall failures during cleanup
If `winget uninstall` fails for VirtualBox, ensure no VMs are running and try running the cleanup as Administrator. The script stops VirtualBox services automatically, but a reboot may be needed if kernel drivers are locked.

### Viewing logs
All setup output is captured in `vagrant/setup-dev-vm.log`. On failure, the script dumps diagnostic information including PATH, installed tool locations, VirtualBox state, disk space, and (when possible) VM-side service status and system logs.
