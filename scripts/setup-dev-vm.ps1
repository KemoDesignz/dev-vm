$ErrorActionPreference = "Stop"

$ProjectDir = "$HOME\fedora-dev-vm"

Write-Host ""
Write-Host "🚀 Fedora Dev VM Interactive Setup"
Write-Host ""

# -------------------------------------------------
# Prompt user for configuration
# -------------------------------------------------
$GithubToken   = Read-Host "🔐 Enter your GitHub token (leave blank to skip)"
$DockerToken  = Read-Host "🐳 Enter your Docker Hub token (leave blank to skip)"
$CpuCount     = Read-Host "🧠 Number of CPUs for the VM (default: 4)"
$MemoryGB     = Read-Host "💾 Memory in GB for the VM (default: 8)"

if (-not $CpuCount) { $CpuCount = 4 }
if (-not $MemoryGB) { $MemoryGB = 8 }

$MemoryMB = [int]$MemoryGB * 1024

Write-Host ""
Write-Host "📋 Configuration Summary"
Write-Host "  CPUs:    $CpuCount"
Write-Host "  Memory:  $MemoryGB GB"
Write-Host "  GitHub:  $([bool]$GithubToken)"
Write-Host "  Docker:  $([bool]$DockerToken)"
Write-Host ""

# -------------------------------------------------
# Allow script execution
# -------------------------------------------------
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force

# -------------------------------------------------
# Install Scoop
# -------------------------------------------------
if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    Write-Host "📦 Installing Scoop..."
    Invoke-RestMethod https://get.scoop.sh | Invoke-Expression
}

scoop bucket add main    | Out-Null
scoop bucket add extras | Out-Null

# -------------------------------------------------
# Install VirtualBox
# -------------------------------------------------
if (-not (Get-Command VBoxManage -ErrorAction SilentlyContinue)) {
    Write-Host "📦 Installing VirtualBox..."
    scoop install virtualbox
}

# -------------------------------------------------
# Install Vagrant
# -------------------------------------------------
if (-not (Get-Command vagrant -ErrorAction SilentlyContinue)) {
    Write-Host "📦 Installing Vagrant..."
    scoop install vagrant
}

# -------------------------------------------------
# Create project directory
# -------------------------------------------------
New-Item -ItemType Directory -Force -Path $ProjectDir | Out-Null
Set-Location $ProjectDir

# -------------------------------------------------
# default.yaml
# -------------------------------------------------
@'
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
'@ | Out-File -Encoding UTF8 default.yaml

# -------------------------------------------------
# env.yaml (generated from prompts)
# -------------------------------------------------
@"
vm:
  cpus: $CpuCount
  memory: $MemoryMB
"@ | Out-File -Encoding UTF8 env.yaml

# -------------------------------------------------
# Vagrantfile
# -------------------------------------------------
@'
require "yaml"

default_config = YAML.load_file("default.yaml")
env_config = File.exist?("env.yaml") ? YAML.load_file("env.yaml") : {}

def deep_merge(a, b)
  a.merge(b) do |_, old, new|
    old.is_a?(Hash) && new.is_a?(Hash) ? deep_merge(old, new) : new
  end
end

config_data = deep_merge(default_config, env_config)

Vagrant.configure("2") do |config|
  config.vm.box = "fedora/39-cloud-base"

  config.vm.provider "virtualbox" do |vb|
    vb.name   = config_data.dig("vm", "name")
    vb.cpus   = config_data.dig("vm", "cpus")
    vb.memory = config_data.dig("vm", "memory")
  end

  Array(config_data["ports"]).each do |p|
    config.vm.network "forwarded_port",
      guest: p["guest"],
      host: p["host"],
      auto_correct: true
  end

  sf = config_data["synced_folder"]
  config.vm.synced_folder sf["host"], sf["guest"],
    create: true,
    mount_options: ["dmode=775,fmode=664"]

  config.vm.provision "shell", path: "provision.sh"
end
'@ | Out-File -Encoding UTF8 Vagrantfile

# -------------------------------------------------
# provision.sh
# -------------------------------------------------
@"
#!/usr/bin/env bash
set -e

GITHUB_TOKEN="$GithubToken"
DOCKER_TOKEN="$DockerToken"

sudo dnf update -y

sudo dnf install -y curl wget git unzip tar gcc-c++ make ca-certificates gnupg lsb-release

# Node.js
curl -fsSL https://rpm.nodesource.com/setup_lts.x | sudo bash -
sudo dnf install -y nodejs

# Java
sudo dnf install -y java-21-openjdk java-21-openjdk-devel

# VS Code
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
cat <<REPO | sudo tee /etc/yum.repos.d/vscode.repo
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
REPO
sudo dnf install -y code

# Docker
sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker vagrant

# kubectl
KUBECTL_VERSION=\$(curl -Ls https://dl.k8s.io/release/stable.txt)
curl -LO "https://dl.k8s.io/release/\${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl
rm -f kubectl

# kind
curl -Lo kind https://kind.sigs.k8s.io/dl/v0.22.0/kind-linux-amd64
chmod +x kind
sudo mv kind /usr/local/bin/kind

# k9s
curl -L https://github.com/derailed/k9s/releases/download/v0.32.5/k9s_Linux_amd64.tar.gz -o /tmp/k9s.tar.gz
tar -xzf /tmp/k9s.tar.gz -C /tmp
sudo mv /tmp/k9s /usr/local/bin/k9s
sudo chmod +x /usr/local/bin/k9s
rm -f /tmp/k9s.tar.gz

# Bash env
mkdir -p /home/vagrant/.bashrc.d

cat <<EOF > /home/vagrant/.bashrc.d/dev-env.sh
export WORKSPACE="\$HOME/workspace"
export NODE_ENV=development

export JAVA_HOME="\$(dirname \$(dirname \$(readlink -f \$(which javac))))"
export PATH="\$JAVA_HOME/bin:\$PATH"

# GitHub token
if [ -n "$GithubToken" ]; then
  export GITHUB_TOKEN="$GithubToken"
  git config --global url."https://$GithubToken@github.com/".insteadOf "https://github.com/"
fi

# Docker Hub token
if [ -n "$DockerToken" ]; then
  echo "$DockerToken" | docker login --username "$GithubToken" --password-stdin || true
fi
EOF

# Load bashrc.d
if ! grep -q bashrc.d /home/vagrant/.bashrc; then
cat <<EOF >> /home/vagrant/.bashrc
if [ -d "\$HOME/.bashrc.d" ]; then
  for f in "\$HOME/.bashrc.d/"*.sh; do
    [ -r "\$f" ] && source "\$f"
  done
fi
EOF
fi

# Kubernetes cluster
sudo -u vagrant bash <<EOF
if ! kind get clusters | grep -q dev-cluster; then
  kind create cluster --name dev-cluster
fi
EOF

sudo usermod -aG vboxsf vagrant
chown -R vagrant:vagrant /home/vagrant/.bashrc.d
"@ | Out-File -Encoding UTF8 provision.sh

# -------------------------------------------------
# Start VM
# -------------------------------------------------
Write-Host ""
Write-Host "🐧 Starting VM (this may take several minutes)..."
vagrant up

Write-Host ""
Write-Host "🎉 SETUP COMPLETE"
Write-Host "Next:"
Write-Host "  cd $ProjectDir"
Write-Host "  vagrant reload"
Write-Host "  vagrant ssh"
Write-Host ""
Write-Host "Inside the VM:"
Write-Host "  kubectl get nodes"
Write-Host "  k9s"
