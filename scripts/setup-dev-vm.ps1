# setup-dev-vm.ps1
# Fully automated Windows setup for a Linux dev VM
# Includes VirtualBox + Vagrant installation, VM provisioning with Docker, Kubernetes, Node.js, JDK21, VS Code, k9s

# -----------------------------
# Step 1: Prompt user for configuration
# -----------------------------
$VMName = Read-Host "Enter a name for your VM (default: dev-vm)"
if ([string]::IsNullOrEmpty($VMName)) { $VMName = "dev-vm" }

$CPUs = Read-Host "Enter number of CPUs for VM (default 4)"
if ([string]::IsNullOrEmpty($CPUs)) { $CPUs = 4 }

$Memory = Read-Host "Enter memory in MB for VM (default 8192)"
if ([string]::IsNullOrEmpty($Memory)) { $Memory = 8192 }

$Port = Read-Host "Enter host port to forward to VM (default 8080)"
if ([string]::IsNullOrEmpty($Port)) { $Port = 8080 }

$GitHubToken = Read-Host "Enter your GitHub token"
$DockerHubToken = Read-Host "Enter your Docker Hub token"

# -----------------------------
# Step 2: Install Scoop if missing
# -----------------------------
if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Scoop..."
    Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    iwr -useb get.scoop.sh | iex
}

# -----------------------------
# Step 3: Install VirtualBox with extension pack
# -----------------------------
Write-Host "Installing VirtualBox with extension pack..."
if (-not (scoop bucket list | Select-String "nonportable")) {
    scoop bucket add nonportable
}
scoop install nonportable/virtualbox-with-extension-pack-np

# Add VirtualBox to PATH
$VBoxPath = "$env:USERPROFILE\scoop\apps\virtualbox-with-extension-pack-np\current"
if (-not ($env:PATH -split ';' | Where-Object { $_ -eq $VBoxPath })) {
    Write-Host "Adding VirtualBox to PATH..."
    [Environment]::SetEnvironmentVariable("PATH", "$env:PATH;$VBoxPath", [EnvironmentVariableTarget]::User)
    $env:PATH += ";$VBoxPath"
}

# -----------------------------
# Step 4: Install Vagrant
# -----------------------------
Write-Host "Installing Vagrant..."
if (-not (scoop bucket list | Select-String "main")) {
    scoop bucket add main
}
scoop install main/vagrant

# Add Scoop shims to PATH (includes Vagrant)
$ScoopShims = "$env:USERPROFILE\scoop\shims"
if (-not ($env:PATH -split ';' | Where-Object { $_ -eq $ScoopShims })) {
    Write-Host "Adding Scoop shims to PATH..."
    [Environment]::SetEnvironmentVariable("PATH", "$env:PATH;$ScoopShims", [EnvironmentVariableTarget]::User)
    $env:PATH += ";$ScoopShims"
}

# -----------------------------
# Step 5: Install VS Code and vcredist2022
# -----------------------------
if (-not (scoop bucket list | Select-String "extras")) {
    Write-Host "Adding extras bucket..."
    scoop bucket add extras
}

Write-Host "Installing VS Code..."
scoop install extras/vscode

Write-Host "Installing Visual C++ Redistributable 2022 (vcredist2022)..."
scoop install extras/vcredist2022

# -----------------------------
# Step 6: Verify installations
# -----------------------------
vboxmanage --version
vagrant --version
code --version

# -----------------------------
# Step 7: Create workspace folder
# -----------------------------
$workspace = Join-Path $PWD "workspace"
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Path $workspace }

# -----------------------------
# Step 8: Generate Vagrantfile dynamically
# -----------------------------
$VagrantfilePath = Join-Path $PWD "Vagrantfile"

$VagrantfileContent = @"
Vagrant.configure("2") do |config|
  config.vm.box = "fedora/38-cloud-base"
  config.vm.hostname = "$VMName"
  config.vm.network "forwarded_port", guest: 8080, host: $Port
  config.vm.provider "virtualbox" do |vb|
    vb.memory = "$Memory"
    vb.cpus = $CPUs
  end
  config.vm.synced_folder "$workspace", "/home/vagrant/workspace", type: "virtualbox"
  
  config.vm.provision "shell", inline: <<-SHELL
    # Update system
    sudo dnf -y update

    # Install dependencies
    sudo dnf -y install curl git

    # Install Node.js
    curl -fsSL https://rpm.nodesource.com/setup_lts.x | sudo bash -
    sudo dnf -y install nodejs

    # Install JDK21
    sudo dnf -y install java-21-openjdk

    # Install Docker
    sudo dnf -y install dnf-plugins-core
    sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
    sudo dnf -y install docker-ce docker-ce-cli containerd.io
    sudo systemctl enable docker --now
    sudo usermod -aG docker vagrant

    # Install kind
    curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.22.0/kind-linux-amd64
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind

    # Install kubectl
    curl -LO "https://dl.k8s.io/release/$(curl -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/

    # Install k9s
    curl -s https://api.github.com/repos/derailed/k9s/releases/latest \
      | grep "browser_download_url.*linux_amd64.tar.gz" \
      | cut -d '"' -f 4 \
      | xargs curl -L -o k9s.tar.gz
    tar -xzf k9s.tar.gz
    sudo mv k9s /usr/local/bin/
    rm k9s.tar.gz

    # Add GitHub and DockerHub tokens to .bashrc
    echo "export GITHUB_TOKEN=$GitHubToken" >> /home/vagrant/.bashrc
    echo "export DOCKERHUB_TOKEN=$DockerHubToken" >> /home/vagrant/.bashrc

    # Create workspace folder inside VM
    mkdir -p /home/vagrant/workspace

    # Start kind cluster
    kind create cluster --name dev-cluster

  SHELL
end
"@

Set-Content -Path $VagrantfilePath -Value $VagrantfileContent -Force
Write-Host "Vagrantfile created at $VagrantfilePath"

# -----------------------------
# Step 9: Bring up the VM
# -----------------------------
Write-Host "Starting VM..."
vagrant up

Write-Host "`nDev VM setup complete!"
Write-Host "Connect to VM: vagrant ssh"
Write-Host "Workspace synced to VM: /home/vagrant/workspace"
Write-Host "Kubernetes cluster inside VM is ready."
