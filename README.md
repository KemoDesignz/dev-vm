# Fedora Dev VM Setup with Kubernetes, Docker, Node.js, VS Code, and k9s

This project provides a **fully automated, configurable Fedora development environment** inside a VirtualBox VM on Windows. The VM comes pre-installed with **Node.js, JDK 21, VS Code, Docker, Kubernetes (via KIND), k9s**, and allows easy **GitHub and Docker Hub integration**. Kubernetes configuration is automatically synced back to your Windows host.

---

## Features

- Interactive setup prompts for:
  - GitHub token
  - Docker Hub token
  - VM CPU count
  - VM memory (GB)
- Automatic installation of:
  - **VirtualBox** and **Vagrant**
  - Fedora 39 Cloud Base VM
- VM provisions the following tools:
  - **Node.js LTS**
  - **Java 21 (JDK)**
  - **Visual Studio Code**
  - **Docker Engine**
  - **kubectl**
  - **KIND** (Kubernetes in Docker)
  - **k9s** (Kubernetes terminal UI)
- VM synced folder with host for:
  - Workspace (`/home/vagrant/workspace`)
  - kubeconfig for Kubernetes cluster access from Windows
- Configurable ports, CPUs, memory via YAML:
  - `default.yaml` (default configuration)
  - `env.yaml` (overrides based on interactive prompts)
- GitHub and Docker Hub tokens stored securely in VM for authentication
- Single command setup and provisioning

---

## Prerequisites (Windows Host)

- Windows 10 or 11
- PowerShell (latest recommended)
- Internet connection (downloads packages, Vagrant boxes, Docker images)

> No need to manually install VirtualBox, Vagrant, or Scoop — the script will handle it.

---

## How It Works

1. User runs the **interactive PowerShell script** `setup-dev-vm.ps1`.
2. Script prompts for:
   - GitHub token (for private repo access)
   - Docker Hub token (for pushing/pulling images)
   - VM CPU count
   - VM memory
3. Script installs required tools on the host:
   - Scoop (Windows package manager)
   - VirtualBox
   - Vagrant
4. Script creates project directory and configuration files:
   - `default.yaml` — default VM config
   - `env.yaml` — overrides from user input
   - `Vagrantfile` — drives VM creation
   - `provision.sh` — provisions the VM with all tools
5. Script runs `vagrant up` to:
   - Launch Fedora VM
   - Install all requested tools inside the VM
   - Create a local Kubernetes cluster using KIND
   - Install k9s
   - Copy kubeconfig to the synced folder for Windows access
6. VM is ready for development, container deployments, and Kubernetes testing.

---

## Setup Instructions

1. **Clone or download this repository** to your Windows machine.

```powershell
git clone <repo-url>
cd <repo-directory>
```

## Step 2: Run the interactive setup script
.\setup-dev-vm.ps1

You will be prompted for:

GitHub token (for private repo access)

Docker Hub token (for pushing/pulling images)

VM CPU count

VM memory in GB

Press Enter to accept defaults (4 CPUs, 8 GB memory)

Step 3: Wait for VM provisioning

The script will download the Fedora box, create the VM, and provision all the required tools.
This can take 10–20 minutes on the first run depending on your network speed.

## Step 4: Access the VM
cd $HOME\fedora-dev-vm
vagrant ssh

Inside the VM, you can verify installed tools:

# Verify Docker
docker version

# Verify Kubernetes
kubectl get nodes
kubectl get pods -A

# Launch k9s
k9s

## Step 5: Access kubeconfig from Windows

The kubeconfig is automatically synced to the shared folder:

C:\Users\<your-user>\fedora-dev-vm\workspace\kubeconfig

Set the KUBECONFIG environment variable in PowerShell:

$env:KUBECONFIG="$HOME\fedora-dev-vm\workspace\kubeconfig"
kubectl get nodes

You can also configure VS Code Kubernetes extension to use this kubeconfig file.

## Step 6: Reload VM for Docker permissions (if needed)

If you encounter permission issues with Docker inside the VM, reload it to apply group changes:

vagrant reload
vagrant ssh

## Step 7: Stopping and cleaning up the VM

### Halt the VM:

vagrant halt

### Destroy the VM and remove all associated storage:

vagrant destroy -f

### Configuration
default.yaml — default VM settings:

vm:
  name: fedora-dev-env
  cpus: 4
  memory: 8192

ports:
  - host: 8080
    guest: 8080

synced_folder:
  host: .
  guest: /home/vagrant/workspace

env.yaml — overrides created interactively by the script (CPU, memory, ports, etc.)

**Notes**

Docker group: You may need to reload the VM or log out/in for Docker group membership to take effect.

GitHub and Docker tokens: Stored inside VM only for authentication.

Kubernetes cluster: Managed by KIND inside the VM. You can deploy Helm charts or YAML manifests directly.

k9s: Terminal UI for cluster management. Launch with k9s.

Optional Enhancements

Add Helm for managing charts.

Configure Ingress and MetalLB for service exposure.

Sync multiple clusters for multi-environment testing.

Automatically set KUBECONFIG permanently on Windows profile.

Troubleshooting

VM fails to boot: Check VirtualBox installation and make sure Hyper-V is disabled.

Docker permission denied: Ensure the user is in the docker group. Reload VM if necessary.

Kubernetes commands fail on Windows: Verify $env:KUBECONFIG points to the synced kubeconfig.

## Summary

This setup provides a full-fledged, reproducible developer environment with:

Linux development VM on Windows

Node.js, JDK, VS Code

Docker & Kubernetes (local cluster)

k9s TUI

GitHub/Docker integration

Synced kubeconfig for Windows

All with one interactive script — ideal for team onboarding or local dev testing.