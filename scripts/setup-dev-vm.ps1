# ============================================================
# Dev VM Setup Script  (v4 – cross-platform Windows & macOS)
# Requires: Windows 10/11 or macOS, admin rights recommended
# macOS: brew install --cask powershell && pwsh ./setup-dev-vm.ps1
# ============================================================
#Requires -Version 5.1

<#
.SYNOPSIS
    Provisions an Ubuntu 24.04 LTS dev VM with Docker, k3s, Helm, Java 21, Node.js, and CLI tools.

.DESCRIPTION
    Cross-platform (Windows & macOS) interactive or parameterised script that:
      1. Installs VirtualBox & Vagrant on the host (via winget or Homebrew).
      2. Generates a Vagrantfile with the chosen settings.
      3. Boots the VM and provisions it with a full dev-tool stack.
      4. Exports a kubeconfig so the host can manage the cluster.

    Run without parameters for an interactive menu, or pass -Action to
    skip the menu (e.g. -Action Setup, -Action Cleanup).

.PARAMETER Action
    Skip the interactive menu. Valid values: Setup, Cleanup, Health, Update, Provision.

.PARAMETER VMName
    Name of the Vagrant / VirtualBox VM. Default: dev-vm

.PARAMETER CPUs
    Number of vCPUs to allocate (1-32). Default: 4

.PARAMETER Memory
    RAM in megabytes (1024-65536). Default: 8192

.PARAMETER DiskGB
    Root disk size in gigabytes (10-500). Default: 80

.PARAMETER PrivateIP
    Host-only network IP for the VM. Default: 192.168.56.10

.PARAMETER GitHubToken
    Optional GitHub personal access token (injected into VM environment).

.PARAMETER DockerHubToken
    Optional Docker Hub access token (injected into VM environment).

.PARAMETER DockerHubUser
    Optional Docker Hub username (used with DockerHubToken for docker login inside VM).

.PARAMETER K3sVersion
    Pin a specific k3s version (e.g. v1.31.4+k3s1). Default: latest.

.PARAMETER NodeVersion
    Pin Node.js major version (e.g. 22). Default: lts.

.PARAMETER DryRun
    Generate the Vagrantfile and exit without running vagrant up.

.PARAMETER SkipConfirm
    Skip confirmation prompts before destructive operations.

.EXAMPLE
    .\setup-dev-vm.ps1
    # Interactive menu.

.EXAMPLE
    .\setup-dev-vm.ps1 -Action Setup -VMName myvm -CPUs 8 -Memory 16384 -SkipConfirm
    # Non-interactive setup with custom values.

.EXAMPLE
    .\setup-dev-vm.ps1 -Action Cleanup -SkipConfirm
    # Non-interactive full cleanup.
#>

[CmdletBinding()]
param(
    [ValidateSet('', 'Setup', 'Cleanup', 'Health', 'Update', 'Provision', 'Repair')]
    [string]$Action,
    [string]$VMName,
    [int]$CPUs,
    [int]$Memory,
    [int]$DiskGB,
    [string]$PrivateIP,
    [string]$GitHubToken,
    [string]$DockerHubToken,
    [string]$DockerHubUser,
    [string]$K3sVersion,
    [string]$NodeVersion,
    [switch]$DryRun,
    [switch]$SkipConfirm
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Platform detection ──────────────────────────────────────
$IsMac = if ($null -ne (Get-Variable IsMacOS -ErrorAction SilentlyContinue)) { $IsMacOS } else { $false }
$IsWin = -not $IsMac

# ─── Directory layout ───────────────────────────────────────
$RepoRoot   = Split-Path $PSScriptRoot -Parent
$VagrantDir = Join-Path $RepoRoot 'vagrant'
$homeDir    = if ($IsWin) { $env:USERPROFILE } else { $env:HOME }

# Tell vagrant where to find the Vagrantfile
$env:VAGRANT_CWD = $VagrantDir

# ─── YAML support ───────────────────────────────────────────
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Host '  ! Installing powershell-yaml module...' -ForegroundColor Yellow
    Install-Module -Name powershell-yaml -Force -Scope CurrentUser
}
Import-Module powershell-yaml -ErrorAction Stop

# ─── Utilities ──────────────────────────────────────────────
function Write-Step  { param([string]$Msg) Write-Host "`n>>> $Msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "  + $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "  ! $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "  X $Msg" -ForegroundColor Red }

function Refresh-Path {
    if ($IsWin) {
        $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'User') + ';' +
                    [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
    } else {
        # macOS: use path_helper and ensure Homebrew paths are included
        $pathHelper = & /usr/libexec/path_helper -s 2>$null
        if ($pathHelper) {
            $newPath = ($pathHelper -replace 'PATH="(.*?)";.*', '$1')
            if ($newPath) { $env:PATH = $newPath }
        }
        foreach ($prefix in '/opt/homebrew/bin', '/usr/local/bin') {
            if ((Test-Path $prefix) -and $env:PATH -notlike "*${prefix}*") {
                $env:PATH = "${prefix}:$env:PATH"
            }
        }
    }
}

function Assert-Command {
    param([string]$Name, [string]$Hint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-Err "$Name not found after install. $Hint"
        Read-Host 'Press Enter to exit'; exit 1
    }
}

function Read-Default {
    param([string]$Prompt, [string]$Default)
    $val = Read-Host "  $Prompt (default: $Default)"
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default } else { return $val }
}

function Read-DefaultInt {
    param([string]$Prompt, [int]$Default, [int]$Min, [int]$Max)
    while ($true) {
        $raw = Read-Host "  $Prompt (default: $Default, range ${Min}-${Max})"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        $parsed = 0
        if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge $Min -and $parsed -le $Max) {
            return $parsed
        }
        Write-Warn "Please enter a number between $Min and $Max."
    }
}

function Read-Secret {
    param([string]$Prompt)
    $secure = Read-Host "  $Prompt" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try   { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Read-YamlConfig {
    param([string]$ScriptDir)
    $defaultsFile = Join-Path $ScriptDir 'defaults.yaml'
    $envFile      = Join-Path $ScriptDir 'env.yaml'

    # Load defaults (required)
    if (-not (Test-Path $defaultsFile)) {
        Write-Err "defaults.yaml not found at: $defaultsFile"
        exit 1
    }
    $config = Get-Content $defaultsFile -Raw | ConvertFrom-Yaml

    # Merge env.yaml overrides (optional)
    if (Test-Path $envFile) {
        Write-Ok 'Loading overrides from env.yaml'
        $envConfig = Get-Content $envFile -Raw | ConvertFrom-Yaml

        # Deep merge vm section (scalar overrides)
        if ($envConfig.ContainsKey('vm')) {
            foreach ($key in $envConfig.vm.Keys) {
                $config.vm[$key] = $envConfig.vm[$key]
            }
        }

        # Replace ports list entirely if specified
        if ($envConfig.ContainsKey('ports')) {
            $config['ports'] = $envConfig.ports
        }

        # Deep merge credentials section (scalar overrides)
        if ($envConfig.ContainsKey('credentials')) {
            if (-not $config.ContainsKey('credentials')) {
                $config['credentials'] = @{}
            }
            foreach ($key in $envConfig.credentials.Keys) {
                $config.credentials[$key] = $envConfig.credentials[$key]
            }
        }
    }

    # Ensure credentials key exists
    if (-not $config.ContainsKey('credentials')) {
        $config['credentials'] = @{}
    }

    return $config
}

# ─── Self-Healing / Repair ─────────────────────────────────
function Invoke-Repair {
    param([switch]$Quiet)

    if (-not $Quiet) {
        Write-Host ''
        Write-Host '======================================================' -ForegroundColor Cyan
        Write-Host '               Dev VM Repair                           ' -ForegroundColor Cyan
        Write-Host '======================================================' -ForegroundColor Cyan
        Write-Host ''
    }

    $allHealthy = $true

    # ── Pre-check: Vagrantfile must exist ──
    if (-not (Test-Path (Join-Path $VagrantDir 'Vagrantfile'))) {
        Write-Err "No Vagrantfile found in $VagrantDir. Run Setup first."
        return $false
    }

    # ══════════════════════════════════════════════════════════
    # Phase 1: VM State
    # ══════════════════════════════════════════════════════════
    Write-Step 'Checking VM state'
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $vmState = vagrant status --machine-readable 2>$null |
               Select-String -Pattern ',state,' |
               ForEach-Object { ($_ -split ',')[3] }
    $ErrorActionPreference = $prevEAP

    if (-not $vmState -or $vmState -eq 'not_created') {
        Write-Err "VM does not exist (state: $vmState). Run Setup first."
        return $false
    }

    if ($vmState -eq 'saved' -or $vmState -eq 'suspended') {
        Write-Warn "VM is suspended. Resuming..."
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        vagrant resume 2>&1 | ForEach-Object { Write-Host "    $_" }
        $resumeExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP
        if ($resumeExit -ne 0) {
            Write-Err "Failed to resume VM (exit $resumeExit)."
            return $false
        }
        Write-Ok 'VM resumed.'
    }
    elseif ($vmState -eq 'poweroff' -or $vmState -eq 'aborted' -or $vmState -eq 'gurumeditation') {
        Write-Warn "VM is stopped (state: $vmState). Starting without re-provisioning..."
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        vagrant up --no-provision 2>&1 | ForEach-Object { Write-Host "    $_" }
        $upExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP
        if ($upExit -ne 0) {
            Write-Err "Failed to start VM (exit $upExit)."
            return $false
        }
        Write-Ok 'VM started.'
    }
    elseif ($vmState -eq 'running') {
        Write-Ok 'VM is running.'
    }
    else {
        Write-Warn "Unexpected VM state: $vmState. Attempting vagrant up --no-provision..."
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        vagrant up --no-provision 2>&1 | ForEach-Object { Write-Host "    $_" }
        $ErrorActionPreference = $prevEAP
    }

    # ══════════════════════════════════════════════════════════
    # Phase 2: Service Health (Docker, k3s)
    # ══════════════════════════════════════════════════════════
    Write-Step 'Checking services'
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'

    # --- Docker ---
    $dockerStatus = (vagrant ssh -c 'systemctl is-active docker 2>/dev/null' 2>$null | Out-String).Trim()
    if ($dockerStatus -ne 'active') {
        Write-Warn "Docker service is '$dockerStatus'. Restarting..."
        vagrant ssh -c 'sudo systemctl restart docker && sleep 3' 2>$null | Out-Null
        $dockerRecheck = (vagrant ssh -c 'systemctl is-active docker 2>/dev/null' 2>$null | Out-String).Trim()
        if ($dockerRecheck -eq 'active') {
            Write-Ok 'Docker service recovered.'
        } else {
            Write-Err "Docker service still not active after restart (state: $dockerRecheck)."
            $allHealthy = $false
        }
    } else {
        Write-Ok 'Docker service: active'
    }

    # --- k3s ---
    $k3sStatus = (vagrant ssh -c 'systemctl is-active k3s 2>/dev/null' 2>$null | Out-String).Trim()
    if ($k3sStatus -ne 'active') {
        Write-Warn "k3s service is '$k3sStatus'. Restarting..."
        vagrant ssh -c 'sudo systemctl restart k3s' 2>$null | Out-Null
        Write-Warn 'Waiting for k3s node to become Ready...'
        $k3sReady = (vagrant ssh -c @'
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
for i in $(seq 1 60); do
    kubectl get nodes 2>/dev/null | grep -q ' Ready' && break
    sleep 2
done
kubectl get nodes 2>/dev/null | grep -q ' Ready' && echo "READY" || echo "NOT_READY"
'@ 2>$null | Out-String).Trim()
        if ($k3sReady -match 'NOT_READY') {
            Write-Err 'k3s node did not become Ready within 120 seconds.'
            $allHealthy = $false
        } else {
            Write-Ok 'k3s service recovered and node is Ready.'
        }
    } else {
        Write-Ok 'k3s service: active'
        # Even if service is active, verify node is Ready
        $nodeCount = (vagrant ssh -c 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready"' 2>$null | Out-String).Trim()
        if ($nodeCount -ge 1) {
            Write-Ok 'k3s node: Ready'
        } else {
            Write-Warn 'k3s service is active but node is not Ready. Waiting...'
            $k3sReady = (vagrant ssh -c @'
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
for i in $(seq 1 30); do
    kubectl get nodes 2>/dev/null | grep -q ' Ready' && break
    sleep 2
done
kubectl get nodes 2>/dev/null | grep -q ' Ready' && echo "READY" || echo "NOT_READY"
'@ 2>$null | Out-String).Trim()
            if ($k3sReady -match 'NOT_READY') {
                Write-Err 'k3s node still not Ready. May need manual investigation.'
                $allHealthy = $false
            } else {
                Write-Ok 'k3s node became Ready.'
            }
        }
    }
    $ErrorActionPreference = $prevEAP

    # ══════════════════════════════════════════════════════════
    # Phase 3: Kubeconfig
    # ══════════════════════════════════════════════════════════
    Write-Step 'Checking host kubeconfig'

    # Resolve VMName and PrivateIP (fall back to YAML config defaults)
    $repairVMName = if ($VMName) { $VMName } else { $yamlConfig.vm.name }
    if (-not $repairVMName) { $repairVMName = 'dev-vm' }
    $repairIP = if ($PrivateIP) { $PrivateIP } else { $yamlConfig.vm.private_ip }
    if (-not $repairIP) { $repairIP = '192.168.56.10' }

    $kubeconfigDir  = Join-Path $homeDir '.kube'
    $kubeconfigDest = Join-Path $kubeconfigDir "config-$repairVMName"

    $needKubeconfig = $false
    if (-not (Test-Path $kubeconfigDest)) {
        Write-Warn "Kubeconfig not found at $kubeconfigDest. Re-extracting..."
        $needKubeconfig = $true
    } else {
        # Test connectivity if kubectl is on host
        if (Get-Command kubectl -ErrorAction SilentlyContinue) {
            $prevKC = $env:KUBECONFIG
            $env:KUBECONFIG = $kubeconfigDest
            $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            $nodes = kubectl get nodes --no-headers --request-timeout=5s 2>$null
            $ErrorActionPreference = $prevEAP
            $env:KUBECONFIG = $prevKC
            if (-not $nodes) {
                Write-Warn 'Kubeconfig exists but cluster is unreachable from host. Re-extracting...'
                $needKubeconfig = $true
            } else {
                Write-Ok "Kubeconfig valid: $kubeconfigDest"
            }
        } else {
            Write-Ok "Kubeconfig exists: $kubeconfigDest"
        }
    }

    if ($needKubeconfig) {
        if (-not (Test-Path $kubeconfigDir)) {
            New-Item -ItemType Directory -Path $kubeconfigDir -Force | Out-Null
        }
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        vagrant ssh -c 'sudo cat /etc/rancher/k3s/k3s.yaml' 2>$null |
            ForEach-Object { $_ -replace 'server: https://127\.0\.0\.1:6443', "server: https://${repairIP}:6443" } |
            Set-Content -Path $kubeconfigDest -Force
        $ErrorActionPreference = $prevEAP
        if (Test-Path $kubeconfigDest) {
            Write-Ok "Kubeconfig re-extracted: $kubeconfigDest"
        } else {
            Write-Err 'Failed to extract kubeconfig from VM.'
            $allHealthy = $false
        }
    }

    # ══════════════════════════════════════════════════════════
    # Phase 4: CLI Tools
    # ══════════════════════════════════════════════════════════
    Write-Step 'Checking CLI tools'
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $script:toolsToRepair = $null
    $toolCheckOutput = (vagrant ssh -c @'
MISSING=""
for tool in docker k3s kubectl helm java node npm k9s yq lazydocker kubectx kubens; do
    if ! command -v "$tool" &>/dev/null; then
        MISSING="$MISSING $tool"
    fi
done
if [ -z "$MISSING" ]; then
    echo "ALL_PRESENT"
else
    echo "MISSING:$MISSING"
fi
'@ 2>$null | Out-String).Trim()
    $ErrorActionPreference = $prevEAP

    if ($toolCheckOutput -match '^ALL_PRESENT') {
        Write-Ok 'All CLI tools present.'
    }
    elseif ($toolCheckOutput -match 'MISSING:(.+)') {
        $script:toolsToRepair = $Matches[1].Trim() -split '\s+'
        foreach ($t in $script:toolsToRepair) {
            Write-Warn "Missing tool: $t"
        }
    }
    else {
        Write-Warn 'Could not determine tool status.'
    }

    # Repair missing tools
    if ($script:toolsToRepair) {
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        foreach ($tool in $script:toolsToRepair) {
            switch ($tool) {
                'helm' {
                    Write-Warn "Reinstalling $tool..."
                    vagrant ssh -c 'curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash' 2>$null |
                        ForEach-Object { Write-Host "    $_" }
                    Write-Ok 'Helm reinstalled.'
                }
                'k9s' {
                    Write-Warn "Reinstalling $tool..."
                    vagrant ssh -c @'
URL=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | grep "browser_download_url.*Linux_amd64.tar.gz" | head -1 | cut -d'"' -f4)
if [ -n "$URL" ]; then
    curl -sL -o /tmp/k9s.tar.gz "$URL"
    tar -xzf /tmp/k9s.tar.gz -C /tmp k9s
    sudo mv /tmp/k9s /usr/local/bin/
    rm -f /tmp/k9s.tar.gz
    echo "REINSTALLED"
else
    echo "FAILED"
fi
'@ 2>$null | ForEach-Object {
                        if ($_ -match 'REINSTALLED') { Write-Ok 'k9s reinstalled.' }
                        elseif ($_ -match 'FAILED') { Write-Err 'Failed to get k9s download URL.'; $allHealthy = $false }
                    }
                }
                'yq' {
                    Write-Warn "Reinstalling $tool..."
                    vagrant ssh -c @'
URL=$(curl -s https://api.github.com/repos/mikefarah/yq/releases/latest | grep 'browser_download_url.*yq_linux_amd64"' | head -1 | cut -d'"' -f4)
if [ -n "$URL" ]; then
    sudo curl -sL -o /usr/local/bin/yq "$URL"
    sudo chmod +x /usr/local/bin/yq
    echo "REINSTALLED"
else
    echo "FAILED"
fi
'@ 2>$null | ForEach-Object {
                        if ($_ -match 'REINSTALLED') { Write-Ok 'yq reinstalled.' }
                        elseif ($_ -match 'FAILED') { Write-Err 'Failed to get yq download URL.'; $allHealthy = $false }
                    }
                }
                'lazydocker' {
                    Write-Warn "Reinstalling $tool..."
                    vagrant ssh -c @'
URL=$(curl -s https://api.github.com/repos/jesseduffield/lazydocker/releases/latest | grep "browser_download_url.*Linux_x86_64.tar.gz" | head -1 | cut -d'"' -f4)
if [ -n "$URL" ]; then
    curl -sL -o /tmp/lazydocker.tar.gz "$URL"
    tar -xzf /tmp/lazydocker.tar.gz -C /tmp lazydocker
    sudo mv /tmp/lazydocker /usr/local/bin/
    rm -f /tmp/lazydocker.tar.gz
    echo "REINSTALLED"
else
    echo "FAILED"
fi
'@ 2>$null | ForEach-Object {
                        if ($_ -match 'REINSTALLED') { Write-Ok 'lazydocker reinstalled.' }
                        elseif ($_ -match 'FAILED') { Write-Err 'Failed to get lazydocker download URL.'; $allHealthy = $false }
                    }
                }
                { $_ -in 'kubectx', 'kubens' } {
                    Write-Warn "Reinstalling $_..."
                    $toolName = $_
                    vagrant ssh -c "URL=`$(curl -s https://api.github.com/repos/ahmetb/kubectx/releases/latest | grep `"browser_download_url.*${toolName}_.*_linux_x86_64.tar.gz`" | head -1 | cut -d'`"' -f4); if [ -n `"`$URL`" ]; then curl -sL -o /tmp/${toolName}.tar.gz `"`$URL`"; tar -xzf /tmp/${toolName}.tar.gz -C /tmp ${toolName}; sudo mv /tmp/${toolName} /usr/local/bin/; rm -f /tmp/${toolName}.tar.gz; echo REINSTALLED; else echo FAILED; fi" 2>$null | ForEach-Object {
                        if ($_ -match 'REINSTALLED') { Write-Ok "$toolName reinstalled." }
                        elseif ($_ -match 'FAILED') { Write-Err "Failed to get $toolName download URL."; $allHealthy = $false }
                    }
                }
                default {
                    Write-Warn "$tool is package-managed. Run Re-provision (option 5) to reinstall."
                    $allHealthy = $false
                }
            }
        }
        $ErrorActionPreference = $prevEAP
        $script:toolsToRepair = $null
    }

    # ══════════════════════════════════════════════════════════
    # Phase 5: Disk Space
    # ══════════════════════════════════════════════════════════
    Write-Step 'Checking disk space'
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $diskOutput = (vagrant ssh -c @'
USAGE=$(df / | tail -1 | awk '{print $5}' | tr -d '%')
echo "DISK_USAGE:${USAGE}"
if [ "$USAGE" -gt 90 ]; then
    echo "DISK_CRITICAL"
else
    echo "DISK_OK"
fi
'@ 2>$null | Out-String).Trim()
    $ErrorActionPreference = $prevEAP

    $diskPct = 0
    if ($diskOutput -match 'DISK_USAGE:(\d+)') { $diskPct = [int]$Matches[1] }

    if ($diskOutput -match 'DISK_CRITICAL') {
        Write-Warn "Root disk usage is ${diskPct}% (>90%). Cleaning up..."
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        vagrant ssh -c @'
echo "  Pruning unused Docker images..."
docker image prune -af 2>/dev/null | tail -2
echo "  Pruning Docker build cache..."
docker builder prune -af 2>/dev/null | tail -2
echo "  Cleaning apt cache..."
sudo apt-get clean 2>/dev/null
echo "  Cleaning journal logs older than 3 days..."
sudo journalctl --vacuum-time=3d 2>/dev/null | tail -1
NEW_USAGE=$(df / | tail -1 | awk '{print $5}')
echo "  Disk usage after cleanup: ${NEW_USAGE}"
'@ 2>$null | ForEach-Object { Write-Host "    $_" }
        $ErrorActionPreference = $prevEAP
        Write-Ok 'Disk cleanup complete.'
    }
    elseif ($diskOutput -match 'DISK_OK') {
        Write-Ok "Root disk usage: ${diskPct}%"
    }
    else {
        Write-Warn 'Could not determine disk usage.'
    }

    # ══════════════════════════════════════════════════════════
    # Summary
    # ══════════════════════════════════════════════════════════
    Write-Host ''
    if ($allHealthy) {
        Write-Host '======================================================' -ForegroundColor Green
        Write-Host '  All checks passed.' -ForegroundColor Green
        Write-Host '======================================================' -ForegroundColor Green
    } else {
        Write-Host '======================================================' -ForegroundColor Yellow
        Write-Host '  Some issues could not be auto-resolved.' -ForegroundColor Yellow
        Write-Host '  Consider Re-provision (option 5) or snapshot restore:' -ForegroundColor Yellow
        Write-Host '    vagrant snapshot restore fresh-install' -ForegroundColor Yellow
        Write-Host '======================================================' -ForegroundColor Yellow
    }
    Write-Host ''

    return $allHealthy
}

# ─── Menu ───────────────────────────────────────────────────
if (-not $Action) {
    Write-Host ''
    Write-Host '======================================================' -ForegroundColor Cyan
    Write-Host '               Dev VM Manager                         ' -ForegroundColor Cyan
    Write-Host '======================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  1) Setup new Dev VM' -ForegroundColor White
    Write-Host '  2) Clean up / destroy Dev VM' -ForegroundColor White
    Write-Host '  3) Health check' -ForegroundColor White
    Write-Host '  4) Update VM software' -ForegroundColor White
    Write-Host '  5) Re-provision VM' -ForegroundColor White
    Write-Host '  6) Repair VM (diagnose & fix)' -ForegroundColor White
    Write-Host ''
    Write-Host '------------------------------------------------------' -ForegroundColor DarkGray

    while ($true) {
        $choice = Read-Host '  Select an option (1-6, or Q to quit)'
        switch ($choice) {
            '1' { $Action = 'Setup';     break }
            '2' { $Action = 'Cleanup';   break }
            '3' { $Action = 'Health';    break }
            '4' { $Action = 'Update';    break }
            '5' { $Action = 'Provision'; break }
            '6' { $Action = 'Repair';    break }
            { $_ -match '^[Qq]$' } { Write-Host '  Goodbye.'; exit 0 }
            default { Write-Warn "Invalid choice '$choice'. Enter 1-6, or Q." }
        }
        if ($Action) { break }
    }
}

# ─── Dispatch: Cleanup ──────────────────────────────────────
if ($Action -eq 'Cleanup') {
    $cleanupScript = Join-Path $PSScriptRoot 'cleanup-install.ps1'
    if (-not (Test-Path $cleanupScript)) {
        Write-Err "Cleanup script not found at: $cleanupScript"
        exit 1
    }
    $cleanupArgs = @{}
    if ($VMName)      { $cleanupArgs['VMName']      = $VMName }
    if ($SkipConfirm) { $cleanupArgs['SkipConfirm'] = $true }
    & $cleanupScript @cleanupArgs
    exit $LASTEXITCODE
}

# ─── Dispatch: Health ─────────────────────────────────────────
if ($Action -eq 'Health') {
    Write-Host ''
    Write-Host '======================================================' -ForegroundColor Cyan
    Write-Host '               Dev VM Health Check                     ' -ForegroundColor Cyan
    Write-Host '======================================================' -ForegroundColor Cyan
    Write-Host ''

    # Check if Vagrantfile exists
    if (-not (Test-Path (Join-Path $VagrantDir 'Vagrantfile'))) {
        Write-Err "No Vagrantfile found in $VagrantDir. Run Setup first."
        exit 1
    }

    # Check VM status
    Write-Step 'VM Status'
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $vmStatus = vagrant status --machine-readable 2>$null |
                Select-String -Pattern ',state,' |
                ForEach-Object { ($_ -split ',')[3] }
    $ErrorActionPreference = $prevEAP

    if (-not $vmStatus -or $vmStatus -eq 'not_created') {
        Write-Err "VM is not running (state: $vmStatus). Run Setup first."
        exit 1
    }
    if ($vmStatus -ne 'running') {
        Write-Warn "VM state: $vmStatus (expected: running)"
        if (-not $SkipConfirm) {
            $fix = Read-Host '  Attempt to repair? (y/N)'
            if ($fix -match '^[Yy]') {
                $yamlConfig = Read-YamlConfig -ScriptDir $VagrantDir
                if (-not $VMName)    { $VMName    = $yamlConfig.vm.name }
                if (-not $PrivateIP) { $PrivateIP = $yamlConfig.vm.private_ip }
                $repairResult = Invoke-Repair
                exit $(if ($repairResult) { 0 } else { 1 })
            }
        }
        exit 1
    }
    Write-Ok "VM state: $vmStatus"

    # Run health checks inside VM
    Write-Step 'Service Status'
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    vagrant ssh -c @'
echo "  Services:"
for svc in docker k3s; do
    status=$(systemctl is-active $svc 2>/dev/null || echo "not found")
    if [ "$status" = "active" ]; then
        printf "    %-20s \033[32m%s\033[0m\n" "$svc" "$status"
    else
        printf "    %-20s \033[31m%s\033[0m\n" "$svc" "$status"
    fi
done
'@ 2>$null | ForEach-Object { Write-Host $_ }

    Write-Step 'Docker'
    vagrant ssh -c 'docker info --format "  Version: {{.ServerVersion}}  Containers: {{.Containers}}  Images: {{.Images}}"' 2>$null |
        ForEach-Object { Write-Host "  $($_)" }

    Write-Step 'Kubernetes'
    vagrant ssh -c 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; echo "  $(k3s --version | head -1)"; echo ""; kubectl get nodes -o wide 2>/dev/null | sed "s/^/  /"' 2>$null |
        ForEach-Object { Write-Host $_ }

    Write-Step 'Disk Usage'
    vagrant ssh -c 'df -h / /home/vagrant 2>/dev/null | sed "s/^/  /"' 2>$null |
        ForEach-Object { Write-Host $_ }

    Write-Step 'Memory'
    vagrant ssh -c 'free -h | sed "s/^/  /"' 2>$null |
        ForEach-Object { Write-Host $_ }

    Write-Step 'Tool Versions'
    vagrant ssh -c @'
printf "  %-14s %s\n" "Docker:"      "$(docker --version 2>/dev/null || echo 'NOT FOUND')"
printf "  %-14s %s\n" "k3s:"         "$(k3s --version 2>/dev/null | head -1 || echo 'NOT FOUND')"
printf "  %-14s %s\n" "kubectl:"     "$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1 || echo 'NOT FOUND')"
printf "  %-14s %s\n" "Helm:"        "$(helm version --short 2>/dev/null || echo 'NOT FOUND')"
printf "  %-14s %s\n" "Java:"        "$(java -version 2>&1 | head -1 || echo 'NOT FOUND')"
printf "  %-14s %s\n" "Node:"        "$(node -v 2>/dev/null || echo 'NOT FOUND')"
printf "  %-14s %s\n" "npm:"         "$(npm -v 2>/dev/null || echo 'NOT FOUND')"
printf "  %-14s %s\n" "k9s:"         "$(k9s version --short 2>/dev/null || echo 'installed')"
printf "  %-14s %s\n" "yq:"          "$(yq --version 2>/dev/null || echo 'NOT FOUND')"
printf "  %-14s %s\n" "lazydocker:"  "$(lazydocker --version 2>/dev/null | head -1 || echo 'installed')"
'@ 2>$null | ForEach-Object { Write-Host $_ }
    $ErrorActionPreference = $prevEAP

    Write-Host ''
    Write-Host '======================================================' -ForegroundColor Green
    Write-Host '  Health check complete.' -ForegroundColor Green
    Write-Host '======================================================' -ForegroundColor Green
    Write-Host ''

    if (-not $SkipConfirm) {
        $runRepair = Read-Host '  Run repair to fix any detected issues? (y/N)'
        if ($runRepair -match '^[Yy]') {
            $yamlConfig = Read-YamlConfig -ScriptDir $VagrantDir
            if (-not $VMName)    { $VMName    = $yamlConfig.vm.name }
            if (-not $PrivateIP) { $PrivateIP = $yamlConfig.vm.private_ip }
            Invoke-Repair | Out-Null
        }
    }
    exit 0
}

# ─── Dispatch: Update ────────────────────────────────────────
if ($Action -eq 'Update') {
    Write-Host ''
    Write-Host '======================================================' -ForegroundColor Cyan
    Write-Host '               Dev VM Software Update                  ' -ForegroundColor Cyan
    Write-Host '======================================================' -ForegroundColor Cyan
    Write-Host ''

    if (-not (Test-Path (Join-Path $VagrantDir 'Vagrantfile'))) {
        Write-Err "No Vagrantfile found in $VagrantDir. Run Setup first."
        exit 1
    }

    # Check VM is running
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $vmStatus = vagrant status --machine-readable 2>$null |
                Select-String -Pattern ',state,' |
                ForEach-Object { ($_ -split ',')[3] }
    $ErrorActionPreference = $prevEAP

    if ($vmStatus -ne 'running') {
        Write-Err "VM is not running (state: $vmStatus). Start it first: vagrant up"
        exit 1
    }

    # System packages
    Write-Step 'Updating system packages (apt)'
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    vagrant ssh -c 'sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y 2>&1 | tail -5' 2>$null |
        ForEach-Object { Write-Host "  $_" }
    Write-Ok 'System packages updated.'

    # k3s update
    Write-Step 'Checking k3s update'
    vagrant ssh -c @'
set -e
CURRENT=$(k3s --version 2>/dev/null | head -1 | awk '{print $3}')
LATEST=$(curl -s https://update.k3s.io/v1-release/channels/stable | grep -oP '"latest":"[^"]*"' | head -1 | cut -d'"' -f4)
echo "  Current: $CURRENT"
echo "  Latest:  $LATEST"
if [ "$CURRENT" = "$LATEST" ]; then
    echo "  + k3s is up to date."
else
    echo "  ! Updating k3s to $LATEST ..."
    curl -sfL https://get.k3s.io | sh - 2>&1 | tail -3
    echo "  + k3s updated to $(k3s --version | head -1 | awk '{print $3}')"
fi
'@ 2>$null | ForEach-Object { Write-Host $_ }

    # CLI tools update
    Write-Step 'Checking CLI tool updates'
    vagrant ssh -c @'
set -e
gh_api() {
    local url="$1"
    local args=(-s)
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        args+=(-H "Authorization: token $GITHUB_TOKEN")
    fi
    curl "${args[@]}" "$url"
}

check_update() {
    local name="$1" repo="$2" current="$3" asset_pattern="$4" extract_cmd="$5"
    local latest
    latest=$(gh_api "https://api.github.com/repos/$repo/releases/latest" | grep '"tag_name"' | cut -d'"' -f4)
    if [ -z "$latest" ]; then
        echo "  ! $name: could not fetch latest version (rate limited?)"
        return
    fi
    # Normalize versions (strip leading v)
    local cur_norm="${current#v}" lat_norm="${latest#v}"
    if [ "$cur_norm" = "$lat_norm" ]; then
        echo "  + $name: $current (up to date)"
    else
        echo "  ! $name: $current -> $latest (updating...)"
        local url
        url=$(gh_api "https://api.github.com/repos/$repo/releases/latest" | grep "browser_download_url.*${asset_pattern}" | head -1 | cut -d'"' -f4)
        if [ -n "$url" ]; then
            curl -sL -o /tmp/${name}_download "$url"
            eval "$extract_cmd"
            echo "  + $name updated to $latest"
        else
            echo "  X $name: download URL not found"
        fi
    fi
}

# k9s
K9S_VER=$(k9s version --short 2>/dev/null | grep -oP 'v[\d.]+' | head -1 || echo "unknown")
check_update "k9s" "derailed/k9s" "$K9S_VER" "Linux_amd64.tar.gz" \
    "tar -xzf /tmp/k9s_download -C /tmp k9s && sudo mv /tmp/k9s /usr/local/bin/ && rm -f /tmp/k9s_download"

# yq
YQ_VER=$(yq --version 2>/dev/null | grep -oP 'v[\d.]+' | head -1 || echo "unknown")
check_update "yq" "mikefarah/yq" "$YQ_VER" 'yq_linux_amd64"' \
    "sudo mv /tmp/yq_download /usr/local/bin/yq && sudo chmod +x /usr/local/bin/yq"

# lazydocker
LD_VER=$(lazydocker --version 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo "unknown")
check_update "lazydocker" "jesseduffield/lazydocker" "$LD_VER" "Linux_x86_64.tar.gz" \
    "tar -xzf /tmp/lazydocker_download -C /tmp lazydocker && sudo mv /tmp/lazydocker /usr/local/bin/ && rm -f /tmp/lazydocker_download"

# kubectx/kubens
for TOOL in kubectx kubens; do
    TOOL_VER=$($TOOL --version 2>/dev/null || echo "unknown")
    check_update "$TOOL" "ahmetb/kubectx" "$TOOL_VER" "${TOOL}_.*_linux_x86_64.tar.gz" \
        "tar -xzf /tmp/${TOOL}_download -C /tmp $TOOL && sudo mv /tmp/$TOOL /usr/local/bin/ && rm -f /tmp/${TOOL}_download"
done
'@ 2>$null | ForEach-Object { Write-Host $_ }

    # Node.js / npm
    Write-Step 'Checking Node.js updates'
    vagrant ssh -c @'
echo "  Node: $(node -v)  npm: $(npm -v)"
sudo npm install -g npm@latest 2>&1 | tail -2
echo "  + npm updated to $(npm -v)"
'@ 2>$null | ForEach-Object { Write-Host $_ }
    $ErrorActionPreference = $prevEAP

    # Re-export kubeconfig in case k3s was updated
    Write-Step 'Re-exporting kubeconfig'
    $kubeconfigDir  = Join-Path $homeDir '.kube'
    if (-not $VMName) { $VMName = 'dev-vm' }
    $kubeconfigDest = Join-Path $kubeconfigDir "config-$VMName"
    if (-not $PrivateIP) { $PrivateIP = '192.168.56.10' }

    if (-not (Test-Path $kubeconfigDir)) {
        New-Item -ItemType Directory -Path $kubeconfigDir -Force | Out-Null
    }
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    vagrant ssh -c 'sudo cat /etc/rancher/k3s/k3s.yaml' 2>$null |
        ForEach-Object { $_ -replace 'server: https://127\.0\.0\.1:6443', "server: https://${PrivateIP}:6443" } |
        Set-Content -Path $kubeconfigDest -Force
    $ErrorActionPreference = $prevEAP
    Write-Ok "Kubeconfig refreshed: $kubeconfigDest"

    Write-Host ''
    Write-Host '======================================================' -ForegroundColor Green
    Write-Host '  Update complete.' -ForegroundColor Green
    Write-Host '======================================================' -ForegroundColor Green
    Write-Host ''
    exit 0
}

# ─── Dispatch: Provision ─────────────────────────────────────
if ($Action -eq 'Provision') {
    Write-Host ''
    Write-Host '======================================================' -ForegroundColor Cyan
    Write-Host '               Re-provision Dev VM                     ' -ForegroundColor Cyan
    Write-Host '======================================================' -ForegroundColor Cyan
    Write-Host ''

    if (-not (Test-Path (Join-Path $VagrantDir 'Vagrantfile'))) {
        Write-Err "No Vagrantfile found in $VagrantDir. Run Setup first."
        exit 1
    }

    if (-not $SkipConfirm) {
        $go = Read-Host '  This will re-run all provisioning stages. Continue? (y/N)'
        if ($go -notmatch '^[Yy]') {
            Write-Host '  Aborted.'
            exit 0
        }
    }

    Write-Step 'Running vagrant provision...'
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    vagrant provision 2>&1 | ForEach-Object { Write-Host $_ }
    $provExitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP

    if ($provExitCode -eq 0) {
        Write-Host ''
        Write-Host '======================================================' -ForegroundColor Green
        Write-Host '  Re-provision complete.' -ForegroundColor Green
        Write-Host '======================================================' -ForegroundColor Green
    } else {
        Write-Err "vagrant provision failed (exit $provExitCode). Check output above."
    }
    Write-Host ''
    exit $provExitCode
}

# ─── Dispatch: Repair ──────────────────────────────────────
if ($Action -eq 'Repair') {
    $yamlConfig = Read-YamlConfig -ScriptDir $VagrantDir
    if (-not $VMName)    { $VMName    = $yamlConfig.vm.name }
    if (-not $PrivateIP) { $PrivateIP = $yamlConfig.vm.private_ip }
    $result = Invoke-Repair
    exit $(if ($result) { 0 } else { 1 })
}

# ═════════════════════════════════════════════════════════════
#  Action: Setup
# ═════════════════════════════════════════════════════════════

# ─── Elapsed-time tracking & log ─────────────────────────────
$ScriptStart = Get-Date
$LogFile     = Join-Path $VagrantDir 'setup-dev-vm.log'
Start-Transcript -Path $LogFile -Append | Out-Null

# ─── Admin check ─────────────────────────────────────────────
if ($IsWin) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
} else {
    $isAdmin = (id -u) -eq '0'
}
if (-not $isAdmin) {
    Write-Warn 'Running without administrator/root privileges. VirtualBox/Vagrant installs may require elevation.'
}

# ─────────────────────────────────────────────────────────────
# 1. Configuration (defaults.yaml + env.yaml + CLI params)
# ─────────────────────────────────────────────────────────────
Write-Step 'Configuration'

$yamlConfig = Read-YamlConfig -ScriptDir $VagrantDir

# Precedence: CLI params > env.yaml > defaults.yaml > interactive prompt
if (-not $VMName)    { $VMName    = Read-Default    'VM name'          $yamlConfig.vm.name }
if ($CPUs   -le 0)   { $CPUs      = Read-DefaultInt 'CPUs'             $yamlConfig.vm.cpus 1 32 }
if ($Memory -le 0)   { $Memory    = Read-DefaultInt 'Memory in MB'     $yamlConfig.vm.memory 1024 65536 }
if ($DiskGB -le 0)   { $DiskGB    = Read-DefaultInt 'Disk size in GB'  $yamlConfig.vm.disk_gb 10 500 }
if (-not $PrivateIP) { $PrivateIP = Read-Default    'VM private IP'    $yamlConfig.vm.private_ip }

# Validate IP format
if ($PrivateIP -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
    Write-Err "Invalid IP address format: $PrivateIP"
    Stop-Transcript | Out-Null
    exit 1
}

# Credentials: CLI params > env.yaml > interactive prompt
$credentialsEnteredInteractively = $false
$creds = $yamlConfig.credentials

if (-not $PSBoundParameters.ContainsKey('GitHubToken')) {
    if ($creds.ContainsKey('github_token') -and $creds.github_token) {
        $GitHubToken = $creds.github_token
        Write-Ok 'GitHub token loaded from env.yaml'
    } else {
        $GitHubToken = Read-Secret 'GitHub token     (optional, Enter to skip)'
        if ($GitHubToken) { $credentialsEnteredInteractively = $true }
    }
}
if (-not $PSBoundParameters.ContainsKey('DockerHubUser')) {
    if ($creds.ContainsKey('dockerhub_user') -and $creds.dockerhub_user) {
        $DockerHubUser = $creds.dockerhub_user
        Write-Ok "Docker Hub user loaded from env.yaml ($DockerHubUser)"
    } else {
        $DockerHubUser = Read-Default 'Docker Hub user  (optional, Enter to skip)' ''
        if ($DockerHubUser) { $credentialsEnteredInteractively = $true }
    }
}
if (-not $PSBoundParameters.ContainsKey('DockerHubToken')) {
    if ($creds.ContainsKey('dockerhub_token') -and $creds.dockerhub_token) {
        $DockerHubToken = $creds.dockerhub_token
        Write-Ok 'Docker Hub token loaded from env.yaml'
    } else {
        $DockerHubToken = Read-Secret 'Docker Hub token (optional, Enter to skip)'
        if ($DockerHubToken) { $credentialsEnteredInteractively = $true }
    }
}

Write-Ok "VM=$VMName  CPUs=$CPUs  RAM=${Memory}MB  Disk=${DiskGB}GB  IP=$PrivateIP"
Write-Ok "Ports: $(($yamlConfig.ports | ForEach-Object { "$($_.guest):$($_.host)" }) -join ', ')"
Write-Ok "GitHub token: $(if ($GitHubToken) { '(provided)' } else { '(none)' })"
Write-Ok "Docker Hub: $(if ($DockerHubUser) { "$DockerHubUser (provided)" } else { '(none)' })"

# ─── Confirmation ────────────────────────────────────────────
if (-not $SkipConfirm) {
    Write-Host ''
    $confirm = Read-Host '  Proceed with this configuration? (Y/n)'
    if ($confirm -and $confirm -notmatch '^[Yy]') {
        Write-Warn 'Aborted by user.'
        Stop-Transcript | Out-Null
        exit 0
    }
}

# ─── Save credentials to env.yaml ─────────────────────────────
if ($credentialsEnteredInteractively -and -not $SkipConfirm) {
    $saveCreds = Read-Host '  Save credentials to vagrant/env.yaml for next time? (y/N)'
    if ($saveCreds -match '^[Yy]') {
        $envFile = Join-Path $VagrantDir 'env.yaml'
        if (Test-Path $envFile) {
            $envYaml = Get-Content $envFile -Raw | ConvertFrom-Yaml
        } else {
            $envYaml = [ordered]@{}
        }

        if (-not $envYaml.ContainsKey('credentials')) {
            $envYaml['credentials'] = [ordered]@{}
        }
        if ($GitHubToken)    { $envYaml.credentials['github_token']    = $GitHubToken }
        if ($DockerHubUser)  { $envYaml.credentials['dockerhub_user']  = $DockerHubUser }
        if ($DockerHubToken) { $envYaml.credentials['dockerhub_token'] = $DockerHubToken }

        $envYaml | ConvertTo-Yaml | Set-Content -Path $envFile -Force
        Write-Ok "Credentials saved to $envFile"
    }
}

# ─────────────────────────────────────────────────────────────
# 2. Install VirtualBox (if missing)
# ─────────────────────────────────────────────────────────────
Write-Step 'Checking VirtualBox'

if ($IsWin) {
    function Add-VBoxToPath {
        $reg     = Get-ItemProperty 'HKLM:\SOFTWARE\Oracle\VirtualBox' -ErrorAction SilentlyContinue
        $regPath = if ($reg -and $reg.PSObject.Properties['InstallDir']) { $reg.InstallDir } else { $null }
        if ($regPath) {
            $regPath = $regPath.TrimEnd('\')
            if ($regPath -and ($env:PATH -notlike "*$regPath*")) {
                $env:PATH += ";$regPath"
            }
        }
    }

    function Install-VirtualBox {
        Write-Warn 'VirtualBox not found - installing via winget...'
        winget install --id Oracle.VirtualBox --source winget `
            --accept-package-agreements --accept-source-agreements
        Refresh-Path; Add-VBoxToPath

        if (-not (Get-Command VBoxManage -ErrorAction SilentlyContinue)) {
            Write-Err 'VirtualBox install failed. Install manually from https://www.virtualbox.org/wiki/Downloads and re-run.'
            Read-Host 'Press Enter to exit'; exit 1
        }
    }

    # Clean stale registry key pointing to a removed install
    $regEntry = Get-ItemProperty 'HKLM:\SOFTWARE\Oracle\VirtualBox' -ErrorAction SilentlyContinue
    if ($regEntry -and $regEntry.PSObject.Properties['InstallDir']) {
        if (-not (Test-Path (Join-Path $regEntry.InstallDir.TrimEnd('\') 'VBoxManage.exe'))) {
            Write-Warn 'Removing stale VirtualBox registry entry.'
            Remove-Item 'HKLM:\SOFTWARE\Oracle\VirtualBox' -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Add-VBoxToPath
    if (-not (Get-Command VBoxManage -ErrorAction SilentlyContinue)) { Install-VirtualBox }
} else {
    # macOS
    function Install-VirtualBox {
        Write-Warn 'VirtualBox not found - installing via Homebrew...'
        brew install --cask virtualbox
        Refresh-Path

        if (-not (Get-Command VBoxManage -ErrorAction SilentlyContinue)) {
            Write-Err 'VirtualBox install failed. Install manually from https://www.virtualbox.org/wiki/Downloads and re-run.'
            Write-Warn 'macOS may require you to allow the kernel extension in System Settings > Privacy & Security.'
            Read-Host 'Press Enter to exit'; exit 1
        }
    }

    if (-not (Get-Command VBoxManage -ErrorAction SilentlyContinue)) { Install-VirtualBox }
}
Assert-Command 'VBoxManage' 'Install VirtualBox manually and re-run.'
Write-Ok "VirtualBox $(VBoxManage --version)"

# Ensure a host-only network exists for the chosen IP range
Write-Step 'Ensuring VirtualBox host-only network for private IP'
$subnet  = ($PrivateIP -replace '\.\d+$', '')
$hostNet = VBoxManage list hostonlyifs 2>$null |
           Select-String -Pattern "IPAddress:\s+$subnet\."
if (-not $hostNet) {
    Write-Warn 'Creating host-only network adapter...'
    if ($IsMac) { Write-Warn 'macOS may prompt you to allow the VirtualBox kernel extension in System Settings > Privacy & Security.' }
    VBoxManage hostonlyif create 2>$null
}

# ─────────────────────────────────────────────────────────────
# 3. Install Vagrant (if missing)
# ─────────────────────────────────────────────────────────────
Write-Step 'Checking Vagrant'

if (-not (Get-Command vagrant -ErrorAction SilentlyContinue)) {
    if ($IsWin) {
        Write-Warn 'Vagrant not found - installing via winget...'
        winget install --id HashiCorp.Vagrant --source winget `
            --accept-package-agreements --accept-source-agreements
    } else {
        Write-Warn 'Vagrant not found - installing via Homebrew...'
        brew install --cask vagrant
    }
    Refresh-Path
}
Assert-Command 'vagrant' 'Reboot may be required after Vagrant install.'
Write-Ok "$(vagrant --version)"

# Install the vagrant-disksize plugin for disk resizing
Write-Step 'Checking Vagrant plugins'
$plugins = vagrant plugin list 2>$null
if ($plugins -notmatch 'vagrant-disksize') {
    Write-Warn 'Installing vagrant-disksize plugin...'
    vagrant plugin install vagrant-disksize
}
Write-Ok 'Vagrant plugins ready'

# ─────────────────────────────────────────────────────────────
# 3b. Install Helm on host (if missing)
# ─────────────────────────────────────────────────────────────
Write-Step 'Checking Helm (host)'
if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
    if ($IsWin) {
        Write-Warn 'Helm not found - installing via winget...'
        winget install --id Helm.Helm --source winget `
            --accept-package-agreements --accept-source-agreements
    } else {
        Write-Warn 'Helm not found - installing via Homebrew...'
        brew install helm
    }
    Refresh-Path
}
if (Get-Command helm -ErrorAction SilentlyContinue) {
    Write-Ok "Helm $(helm version --short 2>$null)"
} else {
    Write-Warn 'Helm not found after install. Install manually and re-run.'
}

# ─────────────────────────────────────────────────────────────
# 3c. Install Docker CLI on host (if missing)
# ─────────────────────────────────────────────────────────────
Write-Step 'Checking Docker CLI (host)'
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    if ($IsWin) {
        Write-Warn 'Docker CLI not found - installing via winget...'
        # Install just the CLI (not Docker Desktop)
        winget install --id Docker.DockerCLI --source winget `
            --accept-package-agreements --accept-source-agreements 2>$null
        if ($LASTEXITCODE -ne 0) {
            # Fallback: try the Docker CE CLI package
            Write-Warn 'Docker.DockerCLI not found in winget, trying Docker.DockerCli...'
            winget install --id Docker.DockerCli --source winget `
                --accept-package-agreements --accept-source-agreements 2>$null
        }
    } else {
        Write-Warn 'Docker CLI not found - installing via Homebrew...'
        brew install docker
    }
    Refresh-Path
}
if (Get-Command docker -ErrorAction SilentlyContinue) {
    Write-Ok "Docker CLI: $(docker --version 2>$null)"
} else {
    Write-Warn 'Docker CLI not found after install attempt.'
    if ($IsWin) {
        Write-Warn 'Install manually: https://docs.docker.com/engine/install/binaries/#install-client-binaries-on-windows'
    } else {
        Write-Warn 'Install manually: brew install docker'
    }
}

# ─────────────────────────────────────────────────────────────
# 4. Create workspace folder
# ─────────────────────────────────────────────────────────────
$workspace = Join-Path $homeDir 'workspace'
if (-not (Test-Path $workspace)) {
    New-Item -ItemType Directory -Path $workspace | Out-Null
    Write-Ok "Created workspace: $workspace"
}

# ─────────────────────────────────────────────────────────────
# 5. Generate SSH keypair for VM access
# ─────────────────────────────────────────────────────────────
Write-Step 'SSH keypair for VM access'

$vagrantSshDir    = Join-Path $homeDir '.ssh'
$vagrantPrivateKey = Join-Path $vagrantSshDir 'id_ed25519'
$vagrantPublicKey  = Join-Path $vagrantSshDir 'id_ed25519.pub'

if (-not (Test-Path $vagrantPrivateKey)) {
    if (-not (Test-Path $vagrantSshDir)) {
        New-Item -ItemType Directory -Path $vagrantSshDir -Force | Out-Null
    }
    Write-Warn 'Generating SSH keypair...'
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    if ($IsWin) {
        # PowerShell 5.1 drops empty string args; use cmd /c to pass -N "" correctly
        $keyPath = $vagrantPrivateKey -replace '\\', '/'
        cmd /c "ssh-keygen -t ed25519 -q -f `"$keyPath`" -N `"`" -C dev-vm-vagrant 2>nul"
    } else {
        ssh-keygen -t ed25519 -q -f "$vagrantPrivateKey" -N '' -C 'dev-vm-vagrant' 2>/dev/null
    }
    $ErrorActionPreference = $prevEAP
    if (Test-Path $vagrantPrivateKey) {
        Write-Ok "SSH keypair generated: $vagrantSshDir"
    } else {
        Write-Err 'Failed to generate SSH keypair. Is ssh-keygen available?'
    }
} else {
    Write-Ok "SSH keypair exists: $vagrantSshDir"
}

# ─────────────────────────────────────────────────────────────
# 6. Generate Vagrantfile
# ─────────────────────────────────────────────────────────────
Write-Step 'Generating Vagrantfile'

# Escape single quotes in tokens for safe embedding inside bash single-quoted strings
$ghEscaped = if ($GitHubToken)    { $GitHubToken    -replace "'", "'\\''" } else { '' }
$dhEscaped = if ($DockerHubToken) { $DockerHubToken -replace "'", "'\\''" } else { '' }
$dhUserEscaped = if ($DockerHubUser) { $DockerHubUser -replace "'", "'\\''" } else { '' }

# Collect host SSH public keys
$sshDir = Join-Path $homeDir '.ssh'
$sshPubKeys = ''
if (Test-Path $sshDir) {
    $pubKeyFiles = @(Get-ChildItem -Path $sshDir -Filter 'id_*.pub' -ErrorAction SilentlyContinue)
    if ($pubKeyFiles.Count -gt 0) {
        $sshPubKeys = ($pubKeyFiles | ForEach-Object { Get-Content $_.FullName -ErrorAction SilentlyContinue }) -join "`n"
        Write-Ok "Found $($pubKeyFiles.Count) host SSH public key(s) to inject"
    }
}

# Resolve Node.js version placeholder
$nodeVersionValue = if ($NodeVersion) { $NodeVersion } else { 'lts' }

# Resolve k3s version placeholder
$k3sVersionValue = if ($K3sVersion) { $K3sVersion } else { '' }

# NOTE: The Vagrantfile template uses a LITERAL here-string (@'...'@) so that
# bash $variables, $(subshells), and Ruby #{interpolation} are preserved as-is.
# Dynamic values are injected via %%PLACEHOLDER%% tokens replaced with .Replace().
$VagrantfileTemplate = @'
# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  # -- Base box --
  config.vm.box      = "bento/ubuntu-24.04"
  config.vm.hostname = "%%VM_NAME%%"

  # -- Disk --
  config.disksize.size = "%%DISK_GB%%GB"

  # -- Network --
  # Private network so the host can reach the k8s API directly.
  config.vm.network "private_network", ip: "%%PRIVATE_IP%%"

  # Port forwards (configured via defaults.yaml / env.yaml)
%%PORT_FORWARDS%%

  # -- Provider --
  config.vm.provider "virtualbox" do |vb|
    vb.name   = "%%VM_NAME%%"
    vb.memory = %%MEMORY%%
    vb.cpus   = %%CPUS%%

    # Performance tweaks
    vb.customize ["modifyvm", :id, "--ioapic",    "on"]
    vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    vb.customize ["modifyvm", :id, "--natdnsproxy1",        "on"]
    vb.customize ["modifyvm", :id, "--largepages", "on"]
    vb.customize ["modifyvm", :id, "--paravirtprovider", "kvm"]
  end

  # -- Timeouts --
  config.vm.boot_timeout      = 600
  config.ssh.connect_timeout  = 60

  # -- Synced folder --
  config.vm.synced_folder "%%WORKSPACE%%", "/home/vagrant/workspace",
    type: "virtualbox", create: true

  # ================================================================
  # Provisioning  (split into stages for clarity and cacheability)
  # ================================================================

  # --- Stage 1: System prep ---
  config.vm.provision "shell", name: "base-packages", inline: <<-'SHELL'
    set -euo pipefail
    echo ">>> Updating system & installing base packages"
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends \
      curl git jq tar unzip bash-completion apt-transport-https ca-certificates \
      gnupg lsb-release htop tmux vim tree make gcc libssl-dev \
      2>&1 | tail -5
    echo "  + Base packages installed"
  SHELL

  # --- Stage 2: Java 21 ---
  config.vm.provision "shell", name: "java", inline: <<-'SHELL'
    set -euo pipefail
    echo ">>> Installing Java 21 (OpenJDK)"
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get install -y --no-install-recommends openjdk-21-jdk-headless 2>&1 | tail -3
    echo "  + Java: $(java -version 2>&1 | head -1)"
  SHELL

  # --- Stage 3: Node.js LTS ---
  config.vm.provision "shell", name: "nodejs", inline: <<-'SHELL'
    set -euo pipefail
    echo ">>> Installing Node.js LTS"
    export DEBIAN_FRONTEND=noninteractive
    curl -fsSL https://deb.nodesource.com/setup_%%NODE_VERSION%%.x | sudo bash - 2>&1 | tail -3
    sudo apt-get install -y nodejs 2>&1 | tail -3
    echo "  + Node $(node -v)  npm $(npm -v)"
  SHELL

  # --- Stage 4: Docker ---
  config.vm.provision "shell", name: "docker", inline: <<-'SHELL'
    set -euo pipefail
    echo ">>> Installing Docker CE"
    export DEBIAN_FRONTEND=noninteractive
    if ! command -v docker &>/dev/null; then
      sudo install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      sudo chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
      sudo apt-get update -qq
      sudo apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
        2>&1 | tail -3
    fi
    sudo systemctl enable --now docker
    sudo usermod -aG docker vagrant

    # Expose Docker daemon on TCP for host access (private network only)
    sudo mkdir -p /etc/systemd/system/docker.service.d
    cat <<'OVERRIDE' | sudo tee /etc/systemd/system/docker.service.d/override.conf > /dev/null
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H fd:// -H tcp://0.0.0.0:2375 --containerd=/run/containerd/containerd.sock
OVERRIDE
    sudo systemctl daemon-reload
    sudo systemctl restart docker
    echo "  + Docker: $(docker --version)"
    echo "  + Docker TCP listener enabled on port 2375"
  SHELL

  # --- Stage 5: k3s ---
  config.vm.provision "shell", name: "k3s", inline: <<-'SHELL'
    set -euo pipefail
    echo ">>> Installing k3s (lightweight Kubernetes)"
    export INSTALL_K3S_EXEC="--write-kubeconfig-mode 644 --disable traefik --tls-san %%PRIVATE_IP%% --node-external-ip %%PRIVATE_IP%% --flannel-iface eth1"
    K3S_VER='%%K3S_VERSION%%'
    if [ -n "$K3S_VER" ]; then export INSTALL_K3S_VERSION="$K3S_VER"; fi
    curl -sfL https://get.k3s.io | sh -

    echo ">>> Waiting for k3s kubeconfig..."
    for i in $(seq 1 45); do
      [ -f /etc/rancher/k3s/k3s.yaml ] && break
      sleep 2
    done
    [ -f /etc/rancher/k3s/k3s.yaml ] || { echo "ERROR: k3s kubeconfig not found after 90s" >&2; exit 1; }

    echo ">>> Waiting for k3s node to be Ready..."
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    for i in $(seq 1 60); do
      kubectl get nodes 2>/dev/null | grep -q ' Ready' && break
      sleep 2
    done
    echo "  + k3s: $(k3s --version | head -1)"
  SHELL

  # --- Stage 6: Helm ---
  config.vm.provision "shell", name: "helm", inline: <<-'SHELL'
    set -euo pipefail
    echo ">>> Installing Helm"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    echo "  + $(helm version --short)"
  SHELL

  # --- Stage 7: Extra CLI tools ---
  config.vm.provision "shell", name: "cli-tools", inline: <<-'SHELL'
    set -euo pipefail

    # Helper: authenticated GitHub API calls (avoids 60-req/hr rate limit)
    gh_api() {
      local url="$1"
      local args=(-s)
      if [ -n "${GITHUB_TOKEN:-}" ]; then
        args+=(-H "Authorization: token $GITHUB_TOKEN")
      fi
      curl "${args[@]}" "$url"
    }

    # Helper: SHA256 checksum verification
    verify_checksum() {
      local file="$1" checksums_url="$2" filename="$3"
      if [ -z "$checksums_url" ]; then return 0; fi
      local expected
      curl -sL -o /tmp/checksums.txt "$checksums_url"
      expected=$(grep "$filename" /tmp/checksums.txt 2>/dev/null | awk '{print $1}' | head -1)
      rm -f /tmp/checksums.txt
      if [ -z "$expected" ]; then
        echo "  ! Checksum not found for $filename, skipping verification"
        return 0
      fi
      local actual
      actual=$(sha256sum "$file" | awk '{print $1}')
      if [ "$actual" != "$expected" ]; then
        echo "  X Checksum FAILED for $filename" >&2
        echo "    Expected: $expected" >&2
        echo "    Actual:   $actual" >&2
        return 1
      fi
      echo "  + Checksum verified for $filename"
      return 0
    }

    # Helper: extract a URL from GitHub release JSON (grep-safe under pipefail)
    extract_url() {
      local json="$1" pattern="$2"
      echo "$json" | grep "$pattern" | head -1 | cut -d '"' -f 4 || true
    }

    echo ">>> Installing k9s"
    K9S_REL=$(gh_api https://api.github.com/repos/derailed/k9s/releases/latest)
    K9S_URL=$(extract_url "$K9S_REL" "browser_download_url.*Linux_amd64.tar.gz")
    K9S_CHECKSUMS=$(extract_url "$K9S_REL" "browser_download_url.*checksums.sha256")
    if [ -z "$K9S_URL" ]; then echo "  X Failed to get k9s download URL (GitHub API rate limit?)" >&2; exit 1; fi
    curl -sL -o /tmp/k9s.tar.gz "$K9S_URL"
    verify_checksum /tmp/k9s.tar.gz "$K9S_CHECKSUMS" "$(basename "$K9S_URL")"
    tar -xzf /tmp/k9s.tar.gz -C /tmp k9s
    sudo mv /tmp/k9s /usr/local/bin/
    rm -f /tmp/k9s.tar.gz

    echo ">>> Installing kubectx & kubens"
    KUBECTX_REL=$(gh_api https://api.github.com/repos/ahmetb/kubectx/releases/latest)
    KUBECTX_CHECKSUMS=$(extract_url "$KUBECTX_REL" "browser_download_url.*checksums.txt")
    for TOOL in kubectx kubens; do
      URL=$(extract_url "$KUBECTX_REL" "browser_download_url.*${TOOL}_.*_linux_x86_64.tar.gz")
      if [ -z "$URL" ]; then echo "  X Failed to get $TOOL download URL (GitHub API rate limit?)" >&2; exit 1; fi
      curl -sL -o "/tmp/${TOOL}.tar.gz" "$URL"
      verify_checksum "/tmp/${TOOL}.tar.gz" "$KUBECTX_CHECKSUMS" "$(basename "$URL")"
      tar -xzf "/tmp/${TOOL}.tar.gz" -C /tmp "$TOOL"
      sudo mv "/tmp/$TOOL" /usr/local/bin/
      rm -f "/tmp/${TOOL}.tar.gz"
    done

    echo ">>> Installing yq"
    YQ_REL=$(gh_api https://api.github.com/repos/mikefarah/yq/releases/latest)
    YQ_URL=$(extract_url "$YQ_REL" 'browser_download_url.*yq_linux_amd64"')
    if [ -z "$YQ_URL" ]; then echo "  X Failed to get yq download URL (GitHub API rate limit?)" >&2; exit 1; fi
    sudo curl -sL -o /usr/local/bin/yq "$YQ_URL"
    sudo chmod +x /usr/local/bin/yq
    echo "  + yq installed (checksum skipped — non-standard checksums format)"

    echo ">>> Installing lazydocker"
    LD_REL=$(gh_api https://api.github.com/repos/jesseduffield/lazydocker/releases/latest)
    LD_URL=$(extract_url "$LD_REL" "browser_download_url.*Linux_x86_64.tar.gz")
    LD_CHECKSUMS=$(extract_url "$LD_REL" "browser_download_url.*checksums.txt")
    if [ -z "$LD_URL" ]; then echo "  X Failed to get lazydocker download URL (GitHub API rate limit?)" >&2; exit 1; fi
    curl -sL -o /tmp/lazydocker.tar.gz "$LD_URL"
    verify_checksum /tmp/lazydocker.tar.gz "$LD_CHECKSUMS" "$(basename "$LD_URL")"
    tar -xzf /tmp/lazydocker.tar.gz -C /tmp lazydocker
    sudo mv /tmp/lazydocker /usr/local/bin/
    rm -f /tmp/lazydocker.tar.gz

    echo "  + CLI tools installed: k9s, kubectx, kubens, yq, lazydocker"
  SHELL

  # --- Stage 8: User environment ---
  config.vm.provision "shell", name: "env-setup", inline: <<-'SHELL'
    set -euo pipefail
    echo ">>> Configuring vagrant user environment"

    # kubeconfig for vagrant user
    mkdir -p /home/vagrant/.kube
    sudo cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
    sudo chown -R vagrant:vagrant /home/vagrant/.kube

    # Idempotent .bashrc additions (only append if sentinel comment is absent)
    if ! grep -q '# == Dev VM environment ==' /home/vagrant/.bashrc 2>/dev/null; then
      cat >> /home/vagrant/.bashrc << 'BASHRC_BLOCK'

# == Dev VM environment ==
export KUBECONFIG=/home/vagrant/.kube/config
export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java))))
export PATH=$JAVA_HOME/bin:$PATH

# Aliases
alias k='kubectl'
alias kgp='kubectl get pods -A'
alias kgs='kubectl get svc -A'
alias kgn='kubectl get nodes'
alias d='docker'
alias dps='docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias ll='ls -lah --color=auto'

# Kubectl completion
source <(kubectl completion bash)
complete -o default -F __start_kubectl k

# Helm completion
source <(helm completion bash)
BASHRC_BLOCK
    fi

    # Inject tokens only if non-empty (idempotent: skip if already present)
    GH_TOKEN='%%GH_TOKEN%%'
    DH_TOKEN='%%DH_TOKEN%%'
    if [ -n "$GH_TOKEN" ] && ! grep -q 'GITHUB_TOKEN' /home/vagrant/.bashrc 2>/dev/null; then
      echo "export GITHUB_TOKEN='$GH_TOKEN'" >> /home/vagrant/.bashrc
    fi
    if [ -n "$DH_TOKEN" ] && ! grep -q 'DOCKERHUB_TOKEN' /home/vagrant/.bashrc 2>/dev/null; then
      echo "export DOCKERHUB_TOKEN='$DH_TOKEN'" >> /home/vagrant/.bashrc
    fi

    chown vagrant:vagrant /home/vagrant/.bashrc

    # Inject host SSH public keys (idempotent)
    SSH_KEYS='%%SSH_PUB_KEYS%%'
    if [ -n "$SSH_KEYS" ]; then
      echo "$SSH_KEYS" | while IFS= read -r key; do
        [ -z "$key" ] && continue
        if ! grep -qF "$key" /home/vagrant/.ssh/authorized_keys 2>/dev/null; then
          echo "$key" >> /home/vagrant/.ssh/authorized_keys
        fi
      done
      chown vagrant:vagrant /home/vagrant/.ssh/authorized_keys
      chmod 600 /home/vagrant/.ssh/authorized_keys
      echo "  + SSH public keys injected"
    fi

    # Docker login (if credentials provided)
    DH_USER='%%DH_USER%%'
    if [ -n "$DH_USER" ] && [ -n "$DH_TOKEN" ]; then
      echo "$DH_TOKEN" | sudo -u vagrant docker login -u "$DH_USER" --password-stdin 2>&1 | tail -1
      echo "  + Docker Hub login configured for $DH_USER"
    fi

    echo "  + Environment configured"
  SHELL

  # --- Stage 9: Smoke tests ---
  config.vm.provision "shell", name: "verify", inline: <<-'SHELL'
    set -euo pipefail
    echo ""
    echo "======================================================"
    echo "           Dev VM - Installation Summary"
    echo "======================================================"
    printf "  %-12s %s\n" "Docker:"  "$(docker --version 2>/dev/null || echo 'NOT FOUND')"
    printf "  %-12s %s\n" "k3s:"     "$(k3s --version 2>/dev/null | head -1 || echo 'NOT FOUND')"
    printf "  %-12s %s\n" "kubectl:" "$(kubectl version --client 2>/dev/null | head -1 || echo 'NOT FOUND')"
    printf "  %-12s %s\n" "Helm:"    "$(helm version --short 2>/dev/null || echo 'NOT FOUND')"
    printf "  %-12s %s\n" "Java:"    "$(java -version 2>&1 | head -1 || echo 'NOT FOUND')"
    printf "  %-12s %s\n" "Node:"    "$(node -v 2>/dev/null || echo 'NOT FOUND')"
    printf "  %-12s %s\n" "k9s:"     "$(k9s version --short 2>/dev/null || echo 'installed')"
    printf "  %-12s %s\n" "yq:"      "$(yq --version 2>/dev/null || echo 'NOT FOUND')"
    echo "------------------------------------------------------"
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    echo "  Cluster nodes:"
    kubectl get nodes -o wide 2>/dev/null | sed 's/^/    /'
    echo "======================================================"
  SHELL
end
'@

# Build port-forward Ruby lines from YAML config
$portForwardLines = ($yamlConfig.ports | ForEach-Object {
    $desc = if ($_.description) { "   # $($_.description)" } else { '' }
    "  config.vm.network `"forwarded_port`", guest: $($_.guest), host: $($_.host), auto_correct: true$desc"
}) -join "`n"

# Replace placeholders with actual values
$Vagrantfile = $VagrantfileTemplate
$Vagrantfile = $Vagrantfile.Replace('%%VM_NAME%%',       $VMName)
$Vagrantfile = $Vagrantfile.Replace('%%CPUS%%',          "$CPUs")
$Vagrantfile = $Vagrantfile.Replace('%%MEMORY%%',        "$Memory")
$Vagrantfile = $Vagrantfile.Replace('%%DISK_GB%%',       "$DiskGB")
$Vagrantfile = $Vagrantfile.Replace('%%PRIVATE_IP%%',    $PrivateIP)
$Vagrantfile = $Vagrantfile.Replace('%%PORT_FORWARDS%%', $portForwardLines)
$Vagrantfile = $Vagrantfile.Replace('%%GH_TOKEN%%',      $ghEscaped)
$Vagrantfile = $Vagrantfile.Replace('%%DH_TOKEN%%',      $dhEscaped)
$Vagrantfile = $Vagrantfile.Replace('%%DH_USER%%',       $dhUserEscaped)
$Vagrantfile = $Vagrantfile.Replace('%%NODE_VERSION%%',  $nodeVersionValue)
$Vagrantfile = $Vagrantfile.Replace('%%K3S_VERSION%%',   $k3sVersionValue)
# Workspace path for Vagrantfile (forward slashes for Ruby/Vagrant)
$workspaceForVagrant = $workspace -replace '\\', '/'
$Vagrantfile = $Vagrantfile.Replace('%%WORKSPACE%%',     $workspaceForVagrant)
$Vagrantfile = $Vagrantfile.Replace('%%SSH_PUB_KEYS%%',  $sshPubKeys)

# Ensure vagrant directory exists
if (-not (Test-Path $VagrantDir)) {
    New-Item -ItemType Directory -Path $VagrantDir -Force | Out-Null
}

$VagrantfilePath = Join-Path $VagrantDir 'Vagrantfile'

# Only write if content has changed (avoids unnecessary vagrant up cycles)
$vagrantfileChanged = $true
if (Test-Path $VagrantfilePath) {
    $existing  = (Get-Content $VagrantfilePath -Raw) -replace "`r`n", "`n"
    $generated = $Vagrantfile -replace "`r`n", "`n"
    if ($existing.TrimEnd() -eq $generated.TrimEnd()) {
        Write-Ok 'Vagrantfile is up to date (no changes detected)'
        $vagrantfileChanged = $false
    } else {
        Set-Content -Path $VagrantfilePath -Value $Vagrantfile -Force
        Write-Ok "Vagrantfile updated: $VagrantfilePath"
    }
} else {
    Set-Content -Path $VagrantfilePath -Value $Vagrantfile -Force
    Write-Ok "Vagrantfile written to $VagrantfilePath"
}

# ─── DryRun exit ────────────────────────────────────────────
if ($DryRun) {
    Write-Ok 'DryRun mode: Vagrantfile generated. Skipping vagrant up.'
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
    exit 0
}

# ─────────────────────────────────────────────────────────────
# 7. Bring up the VM
# ─────────────────────────────────────────────────────────────
Write-Step 'Starting VM (vagrant up) - this will take several minutes...'

# Temporarily relax error handling — vagrant writes progress and warnings to
# stderr, which PowerShell's StrictMode treats as terminating errors.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
vagrant up 2>&1 | ForEach-Object { Write-Host $_ }
$vagrantExitCode = $LASTEXITCODE
$ErrorActionPreference = $prevEAP

if ($vagrantExitCode -ne 0) {
    Write-Err "vagrant up failed (exit $vagrantExitCode). Check logs above."
    Write-Warn "Full log: $LogFile"

    # Offer retry — useful when the VM booted but provisioning timed out
    if (-not $SkipConfirm) {
        $retry = Read-Host '  Retry provisioning? (y/N)'
        if ($retry -match '^[Yy]') {
            Write-Step 'Retrying provisioning (vagrant provision)...'
            $ErrorActionPreference = 'Continue'
            vagrant provision 2>&1 | ForEach-Object { Write-Host $_ }
            $vagrantExitCode = $LASTEXITCODE
            $ErrorActionPreference = $prevEAP

            if ($vagrantExitCode -ne 0) {
                Write-Err "vagrant provision also failed (exit $vagrantExitCode)."
                Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
                exit $vagrantExitCode
            }
            Write-Ok 'Provisioning retry succeeded!'
            Write-Step 'Running post-retry repair checks'
            Invoke-Repair -Quiet | Out-Null
        } else {
            Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
            exit $vagrantExitCode
        }
    } else {
        Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
        exit $vagrantExitCode
    }
}

# ─────────────────────────────────────────────────────────────
# 8. Copy kubeconfig to host and rewrite the server address
# ─────────────────────────────────────────────────────────────
Write-Step 'Setting up host-side kubeconfig'

$kubeconfigDir  = Join-Path $homeDir '.kube'
$kubeconfigDest = Join-Path $kubeconfigDir "config-$VMName"

if (-not (Test-Path $kubeconfigDir)) {
    New-Item -ItemType Directory -Path $kubeconfigDir -Force | Out-Null
}

# Pull the kubeconfig from the VM and rewrite the server address
vagrant ssh -c "sudo cat /etc/rancher/k3s/k3s.yaml" 2>$null |
    ForEach-Object { $_ -replace 'server: https://127\.0\.0\.1:6443', "server: https://${PrivateIP}:6443" } |
    Set-Content -Path $kubeconfigDest -Force

if (Test-Path $kubeconfigDest) {
    Write-Ok "Kubeconfig saved to $kubeconfigDest"
    Write-Host ''
    Write-Host '  To use from your host:' -ForegroundColor Cyan
    Write-Host "    `$env:KUBECONFIG = `"$kubeconfigDest`"" -ForegroundColor White
    Write-Host "    kubectl get nodes" -ForegroundColor White
    Write-Host ''

    # If kubectl is on the host, do a quick connectivity test
    if (Get-Command kubectl -ErrorAction SilentlyContinue) {
        $prevKC = $env:KUBECONFIG
        $env:KUBECONFIG = $kubeconfigDest
        try {
            $nodes = kubectl get nodes --no-headers 2>$null
            if ($nodes) {
                Write-Ok 'Host -> k8s cluster connectivity verified!'
                Write-Host "    $nodes" -ForegroundColor Green
            } else {
                Write-Warn 'Could not reach cluster from host yet (may need a moment to stabilize).'
            }
        } catch {
            Write-Warn "kubectl test failed: $_"
        }
        $env:KUBECONFIG = $prevKC
    } else {
        Write-Warn 'kubectl not found on host. Install it to manage the cluster:'
        if ($IsWin) {
            Write-Host '    winget install --id Kubernetes.kubectl' -ForegroundColor White
        } else {
            Write-Host '    brew install kubectl' -ForegroundColor White
        }
    }
} else {
    Write-Warn 'Could not extract kubeconfig from VM. SSH in and copy manually.'
}

# ─────────────────────────────────────────────────────────────
# 8b. Post-setup health verification and repair
# ─────────────────────────────────────────────────────────────
Write-Step 'Running post-setup health verification'
$repairOk = Invoke-Repair -Quiet
if (-not $repairOk) {
    Write-Warn 'Some issues could not be auto-repaired. The VM may need manual attention.'
    Write-Warn 'You can re-run: .\scripts\setup-dev-vm.ps1 -Action Repair'
}

# ─────────────────────────────────────────────────────────────
# 9. Create baseline snapshot
# ─────────────────────────────────────────────────────────────
Write-Step 'Creating baseline snapshot'
$prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
vagrant snapshot save fresh-install 2>&1 | ForEach-Object { Write-Host "  $_" }
$snapshotExitCode = $LASTEXITCODE
$ErrorActionPreference = $prevEAP

if ($snapshotExitCode -eq 0) {
    Write-Ok "Snapshot 'fresh-install' saved. Restore with: vagrant snapshot restore fresh-install"
} else {
    Write-Warn 'Snapshot failed (non-critical). You can create one manually later.'
}

# ─────────────────────────────────────────────────────────────
# Done!
# ─────────────────────────────────────────────────────────────
$elapsed = (Get-Date) - $ScriptStart
Stop-Transcript -ErrorAction SilentlyContinue | Out-Null

Write-Host ''
Write-Host '======================================================' -ForegroundColor Green
Write-Host "  Dev VM '$VMName' is ready!  ($( '{0:mm\:ss}' -f $elapsed ) elapsed)" -ForegroundColor Green
Write-Host '======================================================' -ForegroundColor Green
Write-Host ''
Write-Host "  SSH into the VM:        vagrant ssh  (or: ssh -i ~/.ssh/id_ed25519 vagrant@$PrivateIP)" -ForegroundColor Cyan
Write-Host "  Workspace (shared):     $workspace" -ForegroundColor Cyan
Write-Host "  Vagrant directory:      $VagrantDir" -ForegroundColor Cyan
Write-Host "  VM private IP:          $PrivateIP" -ForegroundColor Cyan
Write-Host "  k8s API from host:      https://${PrivateIP}:6443" -ForegroundColor Cyan
Write-Host "  Docker from host:       DOCKER_HOST=tcp://${PrivateIP}:2375" -ForegroundColor Cyan
Write-Host "  Kubeconfig (host):      $kubeconfigDest" -ForegroundColor Cyan
Write-Host "  Snapshot:               fresh-install (vagrant snapshot restore fresh-install)" -ForegroundColor Cyan
Write-Host "  Setup log:              $LogFile" -ForegroundColor Cyan
Write-Host ''
Write-Host '  Use from your host terminal:' -ForegroundColor Cyan
Write-Host "    `$env:KUBECONFIG = `"$kubeconfigDest`"" -ForegroundColor White
Write-Host "    `$env:DOCKER_HOST = `"tcp://${PrivateIP}:2375`"" -ForegroundColor White
Write-Host '    kubectl get nodes' -ForegroundColor White
Write-Host '    helm install <name> <chart>' -ForegroundColor White
Write-Host '    docker ps' -ForegroundColor White
Write-Host ''
Write-Host '  Quick commands inside the VM:' -ForegroundColor Cyan
Write-Host '    k get pods -A        (kubectl alias)' -ForegroundColor White
Write-Host '    k9s                  (terminal k8s UI)' -ForegroundColor White
Write-Host '    lazydocker           (terminal Docker UI)' -ForegroundColor White
Write-Host ''
Write-Host '  Management:' -ForegroundColor Cyan
Write-Host '    .\scripts\setup-dev-vm.ps1 -Action Health     (health check)' -ForegroundColor White
Write-Host '    .\scripts\setup-dev-vm.ps1 -Action Update     (update software)' -ForegroundColor White
Write-Host '    .\scripts\setup-dev-vm.ps1 -Action Provision   (re-provision)' -ForegroundColor White
Write-Host '    .\scripts\setup-dev-vm.ps1 -Action Cleanup     (destroy VM)' -ForegroundColor White
Write-Host ''
