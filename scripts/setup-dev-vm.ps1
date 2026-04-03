# ============================================================
# Dev VM Setup Script  (v4 – cross-platform Windows & macOS)
# Requires: Windows 10/11 or macOS, admin rights recommended
# macOS: brew install --cask powershell && pwsh ./setup-dev-vm.ps1
# ============================================================
#Requires -Version 5.1

<#
.SYNOPSIS
    Provisions an Ubuntu 24.04 LTS dev VM with Docker, k3s, Helm, Java 21, Maven, Node.js, and CLI tools.

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
if (-not $homeDir) {
    Write-Host '  X Cannot determine home directory ($env:USERPROFILE / $env:HOME is empty).' -ForegroundColor Red
    exit 1
}

# Tell vagrant where to find the Vagrantfile
$env:VAGRANT_CWD = $VagrantDir

# ─── YAML support ───────────────────────────────────────────
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Host '  ! Installing powershell-yaml module...' -ForegroundColor Yellow
    try {
        if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
        }
        Install-Module -Name powershell-yaml -Force -Scope CurrentUser -AllowClobber
    } catch {
        Write-Host "  X Failed to install powershell-yaml module: $_" -ForegroundColor Red
        Write-Host '    Check internet connectivity or install manually: Install-Module powershell-yaml' -ForegroundColor Yellow
        exit 1
    }
}
Import-Module powershell-yaml -ErrorAction Stop

# ─── Utilities ──────────────────────────────────────────────
function Write-Step  { param([string]$Msg) Write-Host "`n>>> [$([DateTime]::Now.ToString('HH:mm:ss'))] $Msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "  + $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "  ! $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "  X $Msg" -ForegroundColor Red }

# Dump host diagnostics — call this on failures to capture context in the log
function Write-Diagnostics {
    param([string]$Context = 'general failure')
    Write-Host ''
    Write-Host '  ╔══════════════════════════════════════════════════╗' -ForegroundColor Red
    Write-Host '  ║            DIAGNOSTIC INFORMATION               ║' -ForegroundColor Red
    Write-Host '  ╚══════════════════════════════════════════════════╝' -ForegroundColor Red
    Write-Host "  Context:    $Context" -ForegroundColor Red
    Write-Host "  Timestamp:  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
    Write-Host "  Platform:   $(if ($IsWin) { 'Windows' } else { 'macOS' })" -ForegroundColor DarkGray
    Write-Host "  PS Version: $($PSVersionTable.PSVersion)" -ForegroundColor DarkGray
    $adminStatus = if (Get-Variable isAdmin -Scope Script -ValueOnly -ErrorAction SilentlyContinue) { 'Yes' } else { 'No/Unknown' }
    Write-Host "  Admin:      $adminStatus" -ForegroundColor DarkGray
    Write-Host "  PATH:" -ForegroundColor DarkGray
    ($env:PATH -split $(if ($IsWin) { ';' } else { ':' })) | ForEach-Object {
        if ($_) { Write-Host "    $_" -ForegroundColor DarkGray }
    }
    Write-Host "  Key commands:" -ForegroundColor DarkGray
    foreach ($cmd in 'VBoxManage', 'vagrant', 'winget', 'brew', 'kubectl', 'helm', 'java', 'mvn', 'docker') {
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($found) {
            Write-Host "    $cmd => $($found.Source)" -ForegroundColor DarkGray
        } else {
            Write-Host "    $cmd => NOT FOUND" -ForegroundColor DarkGray
        }
    }
    if (Get-Command VBoxManage -ErrorAction SilentlyContinue) {
        Write-Host "  VirtualBox version: $(VBoxManage --version 2>$null)" -ForegroundColor DarkGray
        Write-Host "  VirtualBox VMs:" -ForegroundColor DarkGray
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        VBoxManage list vms 2>$null | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Write-Host "  Host-only interfaces:" -ForegroundColor DarkGray
        VBoxManage list hostonlyifs 2>$null | Select-String -Pattern 'Name:|IPAddress:' |
            ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        VBoxManage list hostonlynets 2>$null | Select-String -Pattern 'Name:|LowerIP:|UpperIP:' |
            ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        $ErrorActionPreference = $prevEAP
    }
    if ($IsWin) {
        Write-Host "  Disk space (C:):" -ForegroundColor DarkGray
        $drive = Get-PSDrive C -ErrorAction SilentlyContinue
        if ($drive) {
            $freeGB = [math]::Round($drive.Free / 1GB, 1)
            $usedGB = [math]::Round($drive.Used / 1GB, 1)
            Write-Host "    Free: ${freeGB}GB  Used: ${usedGB}GB" -ForegroundColor DarkGray
        }
    }
    Write-Host ''
}

# Write file as UTF-8 without BOM (Windows PowerShell 5.1 Set-Content -Encoding utf8 adds a BOM)
function Set-Utf8NoBom {
    param([string]$Path, [string[]]$Content)
    $text = $Content -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($Path, $text, [System.Text.UTF8Encoding]::new($false))
}

function Refresh-Path {
    if ($IsWin) {
        $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'User') + ';' +
                    [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
        # Ensure the WinGet Links directory is on PATH (winget installs shims here)
        $wingetLinks = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
        if ((Test-Path $wingetLinks) -and $env:PATH -notlike "*$wingetLinks*") {
            $env:PATH += ";$wingetLinks"
        }
    } else {
        # macOS: use path_helper and ensure Homebrew paths are included
        $pathHelper = & /usr/libexec/path_helper -s 2>$null
        if ($pathHelper) {
            $pathLine = $pathHelper | Where-Object { $_ -match '^PATH=' } | Select-Object -First 1
            if ($pathLine) {
                $newPath = ($pathLine -replace 'PATH="(.*?)";.*', '$1')
                if ($newPath) { $env:PATH = $newPath }
            }
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
        if (-not $SkipConfirm) { Read-Host 'Press Enter to exit' }; exit 1
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
    try {
        $config = Get-Content $defaultsFile -Raw | ConvertFrom-Yaml
    } catch {
        Write-Err "Failed to parse defaults.yaml: $_"
        exit 1
    }
    if ($null -eq $config) {
        Write-Err "defaults.yaml is empty or invalid: $defaultsFile"
        exit 1
    }
    # Normalize PSCustomObject to hashtable if needed
    if ($config -isnot [hashtable]) {
        $ht = @{}; $config.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }; $config = $ht
    }

    # Merge env.yaml overrides (optional)
    if (Test-Path $envFile) {
        Write-Ok 'Loading overrides from env.yaml'
        $envConfig = try { Get-Content $envFile -Raw | ConvertFrom-Yaml } catch { $null }
        if ($null -eq $envConfig) { $envConfig = @{} }
        if ($envConfig -isnot [hashtable]) {
            $ht = @{}; $envConfig.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }; $envConfig = $ht
        }

        # Deep merge vm section (scalar overrides)
        if ($envConfig.ContainsKey('vm') -and $null -ne $envConfig.vm) {
            foreach ($key in $envConfig.vm.Keys) {
                $config.vm[$key] = $envConfig.vm[$key]
            }
        }

        # Replace ports list entirely if specified
        if ($envConfig.ContainsKey('ports') -and $null -ne $envConfig.ports) {
            $config['ports'] = $envConfig.ports
        }

        # Deep merge credentials section (scalar overrides)
        if ($envConfig.ContainsKey('credentials') -and $null -ne $envConfig.credentials) {
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
               ForEach-Object { ($_ -split ',')[3] } |
               Select-Object -First 1
    $ErrorActionPreference = $prevEAP

    if (-not $vmState -or $vmState -eq 'not_created') {
        Write-Err "VM does not exist (state: $vmState). Run Setup first."
        return $false
    }

    if ($vmState -eq 'saved' -or $vmState -eq 'suspended') {
        Write-Warn "VM is suspended. Resuming..."
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $resumeOutput = vagrant resume 2>&1
        $resumeExit = $LASTEXITCODE
        $resumeOutput | ForEach-Object { Write-Host "    $_" }
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
        $upOutput = vagrant up --no-provision 2>&1
        $upExit = $LASTEXITCODE
        $upOutput | ForEach-Object { Write-Host "    $_" }
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
        $upOutput = vagrant up --no-provision 2>&1
        $ErrorActionPreference = $prevEAP
        $upOutput | ForEach-Object { Write-Host "    $_" }
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
        $kubeconfigContent = vagrant ssh -c 'sudo cat /etc/rancher/k3s/k3s.yaml' 2>$null |
            ForEach-Object { $_ -replace 'server: https://127\.0\.0\.1:6443', "server: https://${repairIP}:6443" }
        if ($kubeconfigContent) { Set-Utf8NoBom -Path $kubeconfigDest -Content $kubeconfigContent }
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
for tool in docker k3s kubectl helm java node npm k9s yq lazydocker kubectx kubens stern gh terraform python3 psql mysql redis-cli yarn pnpm kcat mc; do
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
                    $k9sOutput = vagrant ssh -c @'
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
'@ 2>$null
                    $k9sResult = ($k9sOutput | Out-String)
                    if ($k9sResult -match 'REINSTALLED') { Write-Ok 'k9s reinstalled.' }
                    elseif ($k9sResult -match 'FAILED') { Write-Err 'Failed to get k9s download URL.'; $allHealthy = $false }
                }
                'yq' {
                    Write-Warn "Reinstalling $tool..."
                    $yqOutput = vagrant ssh -c @'
URL=$(curl -s https://api.github.com/repos/mikefarah/yq/releases/latest | grep 'browser_download_url.*yq_linux_amd64"' | head -1 | cut -d'"' -f4)
if [ -n "$URL" ]; then
    sudo curl -sL -o /usr/local/bin/yq "$URL"
    sudo chmod +x /usr/local/bin/yq
    echo "REINSTALLED"
else
    echo "FAILED"
fi
'@ 2>$null
                    $yqResult = ($yqOutput | Out-String)
                    if ($yqResult -match 'REINSTALLED') { Write-Ok 'yq reinstalled.' }
                    elseif ($yqResult -match 'FAILED') { Write-Err 'Failed to get yq download URL.'; $allHealthy = $false }
                }
                'lazydocker' {
                    Write-Warn "Reinstalling $tool..."
                    $ldOutput = vagrant ssh -c @'
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
'@ 2>$null
                    $ldResult = ($ldOutput | Out-String)
                    if ($ldResult -match 'REINSTALLED') { Write-Ok 'lazydocker reinstalled.' }
                    elseif ($ldResult -match 'FAILED') { Write-Err 'Failed to get lazydocker download URL.'; $allHealthy = $false }
                }
                { $_ -in 'kubectx', 'kubens' } {
                    Write-Warn "Reinstalling $_..."
                    $toolName = $_
                    $ktxOutput = vagrant ssh -c "URL=`$(curl -s https://api.github.com/repos/ahmetb/kubectx/releases/latest | grep `"browser_download_url.*${toolName}_.*_linux_x86_64.tar.gz`" | head -1 | cut -d'`"' -f4); if [ -n `"`$URL`" ]; then curl -sL -o /tmp/${toolName}.tar.gz `"`$URL`"; tar -xzf /tmp/${toolName}.tar.gz -C /tmp ${toolName}; sudo mv /tmp/${toolName} /usr/local/bin/; rm -f /tmp/${toolName}.tar.gz; echo REINSTALLED; else echo FAILED; fi" 2>$null
                    $ktxResult = ($ktxOutput | Out-String)
                    if ($ktxResult -match 'REINSTALLED') { Write-Ok "$toolName reinstalled." }
                    elseif ($ktxResult -match 'FAILED') { Write-Err "Failed to get $toolName download URL."; $allHealthy = $false }
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
                ForEach-Object { ($_ -split ',')[3] } |
                Select-Object -First 1
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
printf "  %-14s %s\n" "Maven:"       "$(mvn --version 2>&1 | head -1 || echo 'NOT FOUND')"
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

    # Load config so we use the correct VM name and IP
    $yamlConfig = Read-YamlConfig -ScriptDir $VagrantDir
    if (-not $VMName)    { $VMName    = $yamlConfig.vm.name }
    if (-not $VMName)    { $VMName    = 'dev-vm' }
    if (-not $PrivateIP) { $PrivateIP = $yamlConfig.vm.private_ip }
    if (-not $PrivateIP) { $PrivateIP = '192.168.56.10' }

    # Check VM is running
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $vmStatus = vagrant status --machine-readable 2>$null |
                Select-String -Pattern ',state,' |
                ForEach-Object { ($_ -split ',')[3] } |
                Select-Object -First 1
    $ErrorActionPreference = $prevEAP

    if ($vmStatus -ne 'running') {
        Write-Err "VM is not running (state: $vmStatus). Start it first: vagrant up"
        exit 1
    }

    # System packages
    Write-Step 'Updating system packages (apt)'
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $aptOutput = vagrant ssh -c 'sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y 2>&1 | tail -5' 2>$null
    $aptExit = $LASTEXITCODE
    $aptOutput | ForEach-Object { Write-Host "  $_" }
    if ($aptExit -ne 0) { Write-Warn "apt-get upgrade may have failed (exit $aptExit)." }
    else { Write-Ok 'System packages updated.' }

    # k3s update
    Write-Step 'Checking k3s update'
    $k3sOutput = vagrant ssh -c @'
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
'@ 2>$null
    $k3sExit = $LASTEXITCODE
    $k3sOutput | ForEach-Object { Write-Host $_ }
    if ($k3sExit -ne 0) { Write-Warn "k3s update may have failed (exit $k3sExit)." }

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
    $nodeOutput = vagrant ssh -c @'
echo "  Node: $(node -v)  npm: $(npm -v)"
sudo npm install -g npm@latest 2>&1 | tail -2
echo "  + npm updated to $(npm -v)"
'@ 2>$null
    $nodeExit = $LASTEXITCODE
    $nodeOutput | ForEach-Object { Write-Host $_ }
    if ($nodeExit -ne 0) { Write-Warn "npm update may have failed (exit $nodeExit)." }
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
    $kubeconfigContent = vagrant ssh -c 'sudo cat /etc/rancher/k3s/k3s.yaml' 2>$null |
        ForEach-Object { $_ -replace 'server: https://127\.0\.0\.1:6443', "server: https://${PrivateIP}:6443" }
    $ErrorActionPreference = $prevEAP
    if ($kubeconfigContent) {
        Set-Utf8NoBom -Path $kubeconfigDest -Content $kubeconfigContent
        Write-Ok "Kubeconfig refreshed: $kubeconfigDest"
    } else {
        Write-Warn 'Could not extract kubeconfig from VM.'
    }

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
    $provOutput = vagrant provision 2>&1
    $provExitCode = $LASTEXITCODE
    $provOutput | ForEach-Object { Write-Host $_ }
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
if (-not (Test-Path $VagrantDir)) { New-Item -ItemType Directory -Path $VagrantDir -Force | Out-Null }
try { Start-Transcript -Path $LogFile -Append | Out-Null } catch {
    Write-Warn "Could not start transcript: $_"
}

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

# ─── Log host environment at start ──────────────────────────
Write-Step 'Host environment'
Write-Host "  Date:         $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
Write-Host "  Platform:     $(if ($IsWin) { "Windows $([Environment]::OSVersion.Version)" } else { "macOS $(sw_vers -productVersion 2>$null)" })" -ForegroundColor DarkGray
Write-Host "  PowerShell:   $($PSVersionTable.PSVersion)" -ForegroundColor DarkGray
Write-Host "  Admin:        $isAdmin" -ForegroundColor DarkGray
Write-Host "  Repo root:    $RepoRoot" -ForegroundColor DarkGray
Write-Host "  Log file:     $LogFile" -ForegroundColor DarkGray
$prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
if (Get-Command VBoxManage -ErrorAction SilentlyContinue) {
    Write-Host "  VirtualBox:   $(VBoxManage --version 2>$null)" -ForegroundColor DarkGray
}
if (Get-Command vagrant -ErrorAction SilentlyContinue) {
    Write-Host "  Vagrant:      $((vagrant --version 2>$null) -replace 'Vagrant ','')" -ForegroundColor DarkGray
}
if ($IsWin) {
    $drive = Get-PSDrive C -ErrorAction SilentlyContinue
    if ($drive) {
        Write-Host "  Disk free:    $([math]::Round($drive.Free / 1GB, 1))GB (C:)" -ForegroundColor DarkGray
    }
}
$ErrorActionPreference = $prevEAP

# ─── Winget check (Windows only) ────────────────────────────
if ($IsWin -and -not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Warn 'winget (Windows Package Manager) not found. Attempting to install...'
    try {
        $progressPref = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        $installerUrl  = 'https://aka.ms/getwinget'
        $installerPath = Join-Path $env:TEMP 'Microsoft.DesktopAppInstaller.msixbundle'
        Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
        Add-AppxPackage -Path $installerPath -ErrorAction Stop
        Remove-Item $installerPath -ErrorAction SilentlyContinue
        $ProgressPreference = $progressPref
        Refresh-Path
    } catch {
        Write-Err 'Failed to install winget automatically.'
        Write-Err 'Please install it manually:'
        Write-Err '  1. Open the Microsoft Store'
        Write-Err '  2. Search for "App Installer" and install/update it'
        Write-Err '  3. Re-run this script'
        try { Stop-Transcript | Out-Null } catch {}
        exit 1
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Err 'winget still not available after install attempt.'
        Write-Err 'Install manually from the Microsoft Store ("App Installer") and re-run.'
        try { Stop-Transcript | Out-Null } catch {}
        exit 1
    }
    Write-Ok 'winget installed successfully.'
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

# Validate IP format and octet ranges
$ipValid = $PrivateIP -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$'
if ($ipValid) {
    $octets = $PrivateIP -split '\.' | ForEach-Object { [int]$_ }
    $ipValid = @($octets | Where-Object { $_ -gt 255 }).Count -eq 0
}
if (-not $ipValid) {
    Write-Err "Invalid IP address: $PrivateIP"
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

# Credentials: CLI params > env.yaml > interactive prompt
$credentialsEnteredInteractively = $false
$creds = if ($yamlConfig.ContainsKey('credentials') -and $null -ne $yamlConfig.credentials) { $yamlConfig.credentials } else { @{} }
if ($creds -isnot [hashtable]) {
    $ht = @{}; $creds.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }; $creds = $ht
}

if (-not $PSBoundParameters.ContainsKey('GitHubToken')) {
    if ($creds.ContainsKey('github_token') -and $creds.github_token) {
        $GitHubToken = $creds.github_token
        Write-Ok 'GitHub token loaded from env.yaml'
    } elseif (-not $SkipConfirm) {
        $GitHubToken = Read-Secret 'GitHub token     (optional, Enter to skip)'
        if ($GitHubToken) { $credentialsEnteredInteractively = $true }
    }
}
if (-not $PSBoundParameters.ContainsKey('DockerHubUser')) {
    if ($creds.ContainsKey('dockerhub_user') -and $creds.dockerhub_user) {
        $DockerHubUser = $creds.dockerhub_user
        Write-Ok "Docker Hub user loaded from env.yaml ($DockerHubUser)"
    } elseif (-not $SkipConfirm) {
        $DockerHubUser = (Read-Host '  Docker Hub user  (optional, Enter to skip)').Trim()
        if ($DockerHubUser) { $credentialsEnteredInteractively = $true }
    }
}
if (-not $PSBoundParameters.ContainsKey('DockerHubToken')) {
    if ($creds.ContainsKey('dockerhub_token') -and $creds.dockerhub_token) {
        $DockerHubToken = $creds.dockerhub_token
        Write-Ok 'Docker Hub token loaded from env.yaml'
    } elseif (-not $SkipConfirm) {
        $DockerHubToken = Read-Secret 'Docker Hub token (optional, Enter to skip)'
        if ($DockerHubToken) { $credentialsEnteredInteractively = $true }
    }
}

Write-Ok "VM=$VMName  CPUs=$CPUs  RAM=${Memory}MB  Disk=${DiskGB}GB  IP=$PrivateIP"
$portsDisplay = if ($yamlConfig.ContainsKey('ports') -and $yamlConfig.ports) {
    ($yamlConfig.ports | ForEach-Object { "$($_.guest):$($_.host)" }) -join ', '
} else { '(none)' }
Write-Ok "Ports: $portsDisplay"
Write-Ok "GitHub token: $(if ($GitHubToken) { '(provided)' } else { '(none)' })"
Write-Ok "Docker Hub: $(if ($DockerHubUser) { "$DockerHubUser (provided)" } else { '(none)' })"

# ─── Confirmation ────────────────────────────────────────────
if (-not $SkipConfirm) {
    Write-Host ''
    $confirm = Read-Host '  Proceed with this configuration? (Y/n)'
    if ($confirm -and $confirm -notmatch '^[Yy]') {
        Write-Warn 'Aborted by user.'
        try { Stop-Transcript | Out-Null } catch {}
        exit 0
    }
}

# ─── Save credentials to env.yaml ─────────────────────────────
if ($credentialsEnteredInteractively -and -not $SkipConfirm) {
    $saveCreds = Read-Host '  Save credentials to vagrant/env.yaml for next time? (y/N)'
    if ($saveCreds -match '^[Yy]') {
        $envFile = Join-Path $VagrantDir 'env.yaml'
        if (Test-Path $envFile) {
            $envYaml = try { Get-Content $envFile -Raw | ConvertFrom-Yaml } catch { $null }
            if ($null -eq $envYaml) { $envYaml = [ordered]@{} }
        } else {
            $envYaml = [ordered]@{}
        }
        if ($envYaml -isnot [hashtable] -and $envYaml -isnot [System.Collections.Specialized.OrderedDictionary]) {
            $ht = [ordered]@{}; $envYaml.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }; $envYaml = $ht
        }

        if (-not $envYaml.Contains('credentials')) {
            $envYaml['credentials'] = [ordered]@{}
        }
        if ($GitHubToken)    { $envYaml.credentials['github_token']    = $GitHubToken }
        if ($DockerHubUser)  { $envYaml.credentials['dockerhub_user']  = $DockerHubUser }
        if ($DockerHubToken) { $envYaml.credentials['dockerhub_token'] = $DockerHubToken }

        Set-Utf8NoBom -Path $envFile -Content ($envYaml | ConvertTo-Yaml)
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
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $vboxOutput = winget install --id Oracle.VirtualBox --source winget `
            --accept-package-agreements --accept-source-agreements 2>&1
        $vboxExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP
        $vboxOutput | ForEach-Object { Write-Host "    $_" }
        if ($vboxExit -ne 0) {
            Write-Err "winget install VirtualBox returned exit code $vboxExit"
            Write-Diagnostics -Context 'VirtualBox install failed'
        }
        Refresh-Path; Add-VBoxToPath

        if (-not (Get-Command VBoxManage -ErrorAction SilentlyContinue)) {
            Write-Err 'VirtualBox install failed. Install manually from https://www.virtualbox.org/wiki/Downloads and re-run.'
            Write-Diagnostics -Context 'VBoxManage not found after install'
            if (-not $SkipConfirm) { Read-Host 'Press Enter to exit' }; exit 1
        }
        Write-Ok "VirtualBox installed: $(VBoxManage --version 2>$null)"
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
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        brew install --cask virtualbox 2>&1 | ForEach-Object { Write-Host "    $_" }
        $ErrorActionPreference = $prevEAP
        Refresh-Path

        if (-not (Get-Command VBoxManage -ErrorAction SilentlyContinue)) {
            Write-Err 'VirtualBox install failed. Install manually from https://www.virtualbox.org/wiki/Downloads and re-run.'
            Write-Warn 'macOS may require you to allow the kernel extension in System Settings > Privacy & Security.'
            if (-not $SkipConfirm) { Read-Host 'Press Enter to exit' }; exit 1
        }
    }

    if (-not (Get-Command VBoxManage -ErrorAction SilentlyContinue)) { Install-VirtualBox }
}
Assert-Command 'VBoxManage' 'Install VirtualBox manually and re-run.'
Write-Ok "VirtualBox $(VBoxManage --version)"

# Ensure a host-only network exists for the chosen IP range
Write-Step 'Ensuring VirtualBox host-only network for private IP'
$subnet = ($PrivateIP -replace '\.\d+$', '')

# VirtualBox 7+ on macOS uses hostonlynets instead of hostonlyifs
$prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$hostNet = VBoxManage list hostonlyifs 2>$null |
           Select-String -Pattern "IPAddress:\s+$subnet\."
if (-not $hostNet) {
    # Also check host-only networks (VirtualBox 7+ / macOS) — match on LowerIP/UpperIP which contain the subnet
    $hostNet = VBoxManage list hostonlynets 2>$null |
               Select-String -Pattern "(LowerIP|UpperIP):\s+$subnet\."
}
if (-not $hostNet) {
    Write-Warn 'Creating host-only network adapter...'
    if ($IsMac) { Write-Warn 'macOS may prompt you to allow the VirtualBox kernel extension in System Settings > Privacy & Security.' }
    # Try modern hostonlynets first, fall back to legacy hostonlyifs
    $netName = "DevVM-$subnet"
    $existingNet = VBoxManage list hostonlynets 2>$null | Select-String -Pattern "Name:\s+$netName"
    if (-not $existingNet) {
        VBoxManage hostonlynet add --name $netName --netmask 255.255.255.0 --lower-ip "${subnet}.1" --upper-ip "${subnet}.254" 2>$null
    }
    if ($LASTEXITCODE -ne 0) {
        VBoxManage hostonlyif create 2>$null
    }
}
$ErrorActionPreference = $prevEAP

# ─────────────────────────────────────────────────────────────
# 3. Install Vagrant (if missing)
# ─────────────────────────────────────────────────────────────
Write-Step 'Checking Vagrant'

if (-not (Get-Command vagrant -ErrorAction SilentlyContinue)) {
    if ($IsWin) {
        Write-Warn 'Vagrant not found - installing via winget...'
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $vagrantInstOutput = winget install --id HashiCorp.Vagrant --source winget `
            --accept-package-agreements --accept-source-agreements 2>&1
        $vagrantInstExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP
        $vagrantInstOutput | ForEach-Object { Write-Host "    $_" }
        if ($vagrantInstExit -ne 0) { Write-Warn "winget install Vagrant returned exit code $vagrantInstExit" }
    } else {
        Write-Warn 'Vagrant not found - installing via Homebrew...'
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        brew install --cask vagrant 2>&1 | ForEach-Object { Write-Host "    $_" }
        $ErrorActionPreference = $prevEAP
    }
    Refresh-Path
}
Assert-Command 'vagrant' 'Reboot may be required after Vagrant install.'
$prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
Write-Ok "$(vagrant --version 2>$null)"
$ErrorActionPreference = $prevEAP

Write-Step 'Checking Vagrant plugins'
Write-Ok 'No required Vagrant plugins (using native disk API)'

# ─────────────────────────────────────────────────────────────
# 3b. Install Helm on host (if missing)
# ─────────────────────────────────────────────────────────────
Write-Step 'Checking Helm (host)'
if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
    if ($IsWin) {
        Write-Warn 'Helm not found - installing via winget...'
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $helmInstOutput = winget install --id Helm.Helm --source winget `
            --accept-package-agreements --accept-source-agreements 2>&1
        $helmInstExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP
        $helmInstOutput | ForEach-Object { Write-Host "    $_" }
        if ($helmInstExit -ne 0) { Write-Warn "winget install Helm returned exit code $helmInstExit" }
    } else {
        Write-Warn 'Helm not found - installing via Homebrew...'
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        brew install helm 2>&1 | ForEach-Object { Write-Host "    $_" }
        $ErrorActionPreference = $prevEAP
    }
    Refresh-Path
}
if (Get-Command helm -ErrorAction SilentlyContinue) {
    Write-Ok "Helm $(helm version --short 2>$null)"
} else {
    Write-Warn 'Helm not found after install. Install manually and re-run.'
}

# ─────────────────────────────────────────────────────────────
# 3c. Install kubectl on host (if missing)
# ─────────────────────────────────────────────────────────────
Write-Step 'Checking kubectl (host)'
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    if ($IsWin) {
        Write-Warn 'kubectl not found - installing via winget...'
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $kubectlInstOutput = winget install --id Kubernetes.kubectl --source winget `
            --accept-package-agreements --accept-source-agreements 2>&1
        $kubectlInstExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP
        $kubectlInstOutput | ForEach-Object { Write-Host "    $_" }
        if ($kubectlInstExit -ne 0) { Write-Warn "winget install kubectl returned exit code $kubectlInstExit" }
    } else {
        Write-Warn 'kubectl not found - installing via Homebrew...'
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        brew install kubectl 2>&1 | ForEach-Object { Write-Host "    $_" }
        $ErrorActionPreference = $prevEAP
    }
    Refresh-Path
}
if (Get-Command kubectl -ErrorAction SilentlyContinue) {
    Write-Ok "kubectl $(kubectl version --client 2>$null | Select-Object -First 1)"
} else {
    Write-Warn 'kubectl not found after install attempt.'
    if ($IsWin) {
        Write-Warn 'Install manually: winget install Kubernetes.kubectl'
    } else {
        Write-Warn 'Install manually: brew install kubectl'
    }
}

# ─────────────────────────────────────────────────────────────
# 3d. Install Docker CLI on host (if missing)
# ─────────────────────────────────────────────────────────────
Write-Step 'Checking Docker CLI (host)'
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    if ($IsWin) {
        Write-Warn 'Docker CLI not found - installing via winget...'
        # Install just the CLI (not Docker Desktop)
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $dockerInstOutput = winget install --id Docker.DockerCLI --source winget `
            --accept-package-agreements --accept-source-agreements 2>&1
        $dockerInstExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP
        $dockerInstOutput | ForEach-Object { Write-Host "    $_" }
        if ($dockerInstExit -ne 0) {
            # Fallback: try the Docker CE CLI package
            Write-Warn "Docker.DockerCLI install returned exit code $dockerInstExit, trying Docker.DockerCli..."
            $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            $dockerInstOutput2 = winget install --id Docker.DockerCli --source winget `
                --accept-package-agreements --accept-source-agreements 2>&1
            $ErrorActionPreference = $prevEAP
            $dockerInstOutput2 | ForEach-Object { Write-Host "    $_" }
        }
    } else {
        Write-Warn 'Docker CLI not found - installing via Homebrew...'
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        brew install docker 2>&1 | ForEach-Object { Write-Host "    $_" }
        $ErrorActionPreference = $prevEAP
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
# 3e. Install k9s on host (if missing)
# ─────────────────────────────────────────────────────────────
Write-Step 'Checking k9s (host)'
if (-not (Get-Command k9s -ErrorAction SilentlyContinue)) {
    if ($IsWin) {
        Write-Warn 'k9s not found - installing via winget...'
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $k9sInstOutput = winget install --id Derailed.k9s --source winget `
            --accept-package-agreements --accept-source-agreements 2>&1
        $k9sInstExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP
        $k9sInstOutput | ForEach-Object { Write-Host "    $_" }
        if ($k9sInstExit -ne 0) { Write-Warn "winget install k9s returned exit code $k9sInstExit" }
    } else {
        Write-Warn 'k9s not found - installing via Homebrew...'
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        brew install derailed/k9s/k9s 2>&1 | ForEach-Object { Write-Host "    $_" }
        $ErrorActionPreference = $prevEAP
    }
    Refresh-Path
}
if (Get-Command k9s -ErrorAction SilentlyContinue) {
    Write-Ok "k9s installed"
} else {
    Write-Warn 'k9s not found after install attempt.'
    if ($IsWin) {
        Write-Warn 'Install manually: winget install Derailed.k9s'
    } else {
        Write-Warn 'Install manually: brew install derailed/k9s/k9s'
    }
}

# ─────────────────────────────────────────────────────────────
# 3f. Install Temurin JDK 21 on host (if missing)
# ─────────────────────────────────────────────────────────────
Write-Step 'Checking Temurin JDK 21 (host)'
$hasTemurin21 = $false

if ($IsWin) {
    $javaCmd = Get-Command java -ErrorAction SilentlyContinue
    if ($javaCmd) {
        $javaVerOutput = try { & java -version 2>&1 | Out-String } catch { '' }
        if ($javaVerOutput -match '21\.' -and $javaVerOutput -match 'Temurin') {
            $hasTemurin21 = $true
        }
    }
} else {
    # macOS: Temurin cask installs to /Library/Java/JavaVirtualMachines/ but does NOT add java to PATH.
    # Search for any temurin-21 JDK variant instead of hardcoding the exact directory name.
    $temurinHome = $null
    $jvmDir = '/Library/Java/JavaVirtualMachines'
    if (Test-Path $jvmDir) {
        $temurinDir = Get-ChildItem $jvmDir -Directory -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -match 'temurin.*21' } |
                      Select-Object -First 1
        if ($temurinDir) {
            $candidate = Join-Path $temurinDir.FullName 'Contents/Home'
            if (Test-Path "$candidate/bin/java") { $temurinHome = $candidate }
        }
    }
    if ($temurinHome) { $hasTemurin21 = $true }
}

if (-not $hasTemurin21) {
    if ($IsWin) {
        Write-Warn 'Temurin JDK 21 not found - installing via winget...'
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $javaInstOutput = winget install --id EclipseAdoptium.Temurin.21.JDK --source winget `
            --accept-package-agreements --accept-source-agreements 2>&1
        $javaInstExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP
        $javaInstOutput | ForEach-Object { Write-Host "    $_" }
        if ($javaInstExit -ne 0) { Write-Warn "winget install Temurin JDK returned exit code $javaInstExit" }
    } else {
        Write-Warn 'Temurin JDK 21 not found - installing via Homebrew...'
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        brew tap adoptium/openjdk 2>&1 | ForEach-Object { Write-Host "    $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-Warn 'brew tap adoptium/openjdk failed — trying install anyway...'
        }
        brew install --cask temurin@21 2>&1 | ForEach-Object { Write-Host "    $_" }
        $ErrorActionPreference = $prevEAP
    }
    Refresh-Path
}

# Set JAVA_HOME on the host
if ($IsWin) {
    if (Get-Command java -ErrorAction SilentlyContinue) {
        $javaVer = try { & java -version 2>&1 | Select-Object -First 1 } catch { $null }
        Write-Ok "Java: $javaVer"
        # Resolve JAVA_HOME from the java.exe path (e.g. C:\Program Files\Eclipse Adoptium\jdk-21...\bin\java.exe -> parent\parent)
        $javaExe = (Get-Command java).Source
        $javaHome = Split-Path (Split-Path $javaExe -Parent) -Parent
        $env:JAVA_HOME = $javaHome
        # Persist JAVA_HOME for future sessions
        $currentJH = [System.Environment]::GetEnvironmentVariable('JAVA_HOME', 'User')
        if ($currentJH -ne $javaHome) {
            [System.Environment]::SetEnvironmentVariable('JAVA_HOME', $javaHome, 'User')
            Write-Ok "JAVA_HOME set to $javaHome (User environment)"
        } else {
            Write-Ok "JAVA_HOME already set: $javaHome"
        }
    } else {
        Write-Warn 'Java not found after install attempt.'
        Write-Warn 'Install manually: winget install EclipseAdoptium.Temurin.21.JDK'
    }
} else {
    # macOS: discover the Temurin install path (may vary by version/formula)
    if (-not $temurinHome) {
        $jvmDir = '/Library/Java/JavaVirtualMachines'
        if (Test-Path $jvmDir) {
            $temurinDir = Get-ChildItem $jvmDir -Directory -ErrorAction SilentlyContinue |
                          Where-Object { $_.Name -match 'temurin.*21' } |
                          Select-Object -First 1
            if ($temurinDir) {
                $candidate = Join-Path $temurinDir.FullName 'Contents/Home'
                if (Test-Path "$candidate/bin/java") { $temurinHome = $candidate }
            }
        }
    }
    if ($temurinHome -and (Test-Path "$temurinHome/bin/java")) {
        $env:JAVA_HOME = $temurinHome
        $env:PATH = "${temurinHome}/bin:$env:PATH"
        $javaVer = & "$temurinHome/bin/java" -version 2>&1 | Select-Object -First 1
        Write-Ok "Java: $javaVer"
        Write-Ok "JAVA_HOME set to $temurinHome (current session)"
    } else {
        Write-Warn 'Java not found after install attempt.'
        Write-Warn 'Install manually: brew install --cask temurin@21'
    }
}

# ─────────────────────────────────────────────────────────────
# 3g. Install Maven on host (if missing)
# ─────────────────────────────────────────────────────────────
Write-Step 'Checking Maven (host)'
if (-not (Get-Command mvn -ErrorAction SilentlyContinue)) {
    if ($IsWin) {
        Write-Warn 'Maven not found - installing via winget...'
        $mvnInstOutput = winget install --id Apache.Maven --source winget `
            --accept-package-agreements --accept-source-agreements 2>&1
        $mvnInstExit = $LASTEXITCODE
        $mvnInstOutput | ForEach-Object { Write-Host "    $_" }
        if ($mvnInstExit -ne 0) { Write-Warn "winget install Maven returned exit code $mvnInstExit" }
    } else {
        # Install Maven directly from Apache to avoid Homebrew pulling in openjdk (conflicts with Temurin)
        $mvnVersion = '3.9.9'
        $mvnTar = "apache-maven-${mvnVersion}-bin.tar.gz"
        $mvnUrl = "https://dlcdn.apache.org/maven/maven-3/${mvnVersion}/binaries/${mvnTar}"
        $mvnInstallDir = '/opt/maven'
        Write-Warn "Installing Maven $mvnVersion from Apache..."
        & /usr/bin/curl -fsSL -o "/tmp/$mvnTar" $mvnUrl
        & sudo mkdir -p $mvnInstallDir
        & sudo tar -xzf "/tmp/$mvnTar" -C $mvnInstallDir --strip-components=1
        Remove-Item -Force "/tmp/$mvnTar" -ErrorAction SilentlyContinue
        # Add mvn to PATH for current session
        $env:PATH = "${mvnInstallDir}/bin:$env:PATH"
    }
    Refresh-Path
}

# Set MAVEN_HOME / M2_HOME on the host
if (Get-Command mvn -ErrorAction SilentlyContinue) {
    Write-Ok "Maven $(mvn --version 2>$null | Select-Object -First 1)"

    if ($IsWin) {
        # Resolve MAVEN_HOME from mvn.cmd path (e.g. ...\apache-maven-x.y.z\bin\mvn.cmd -> parent\parent)
        $mvnExe = (Get-Command mvn).Source
        $mavenHome = Split-Path (Split-Path $mvnExe -Parent) -Parent
        $env:MAVEN_HOME = $mavenHome
        $env:M2_HOME = $mavenHome
        # Persist for future sessions
        $currentMH = [System.Environment]::GetEnvironmentVariable('MAVEN_HOME', 'User')
        if ($currentMH -ne $mavenHome) {
            [System.Environment]::SetEnvironmentVariable('MAVEN_HOME', $mavenHome, 'User')
            [System.Environment]::SetEnvironmentVariable('M2_HOME', $mavenHome, 'User')
            Write-Ok "MAVEN_HOME set to $mavenHome (User environment)"
        } else {
            Write-Ok "MAVEN_HOME already set: $mavenHome"
        }
    } else {
        # macOS: resolve from mvn binary (BSD readlink lacks -f, use python3 to resolve symlinks)
        $mvnExe = & python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" (Get-Command mvn).Source 2>/dev/null
        if (-not $mvnExe) { $mvnExe = (Get-Command mvn).Source }
        $mavenHome = Split-Path (Split-Path $mvnExe -Parent) -Parent
        $env:MAVEN_HOME = $mavenHome
        $env:M2_HOME = $mavenHome
        Write-Ok "MAVEN_HOME set to $mavenHome (current session)"
    }
} else {
    Write-Warn 'Maven not found after install attempt.'
    if ($IsWin) {
        Write-Warn 'Install manually: winget install Apache.Maven'
    } else {
        Write-Warn 'Install manually: Download from https://maven.apache.org/download.cgi'
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

# Resolve Node.js version placeholder — NodeSource requires a numeric major version
$nodeVersionValue = if ($NodeVersion -and $NodeVersion -ne 'lts') { $NodeVersion } else { '22' }

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
  config.vm.disk :disk, size: "%%DISK_GB%%GB", primary: true

  # -- Network --
  # Private network so the host can reach the k8s API directly.
  config.vm.network "private_network", ip: "%%PRIVATE_IP%%"

  # Port forwards (configured via defaults.yaml / env.yaml)
%%PORT_FORWARDS%%

  # -- Provider --
  config.vm.provider "virtualbox" do |vb|
    vb.name   = "%%VM_NAME%%"
    vb.gui    = false
    vb.memory = %%MEMORY%%
    vb.cpus   = %%CPUS%%

    # Performance tweaks
    vb.customize ["modifyvm", :id, "--ioapic", "on"]

    # VirtualBox 7.1+ removed --natdnshostresolver1/--natdnsproxy1
    vbox_version = `VBoxManage --version`.strip.split("r")[0] rescue "0"
    if Gem::Version.new(vbox_version) >= Gem::Version.new("7.1")
      vb.customize ["modifyvm", :id, "--nat-localhostreachable1", "on"]
    else
      vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
      vb.customize ["modifyvm", :id, "--natdnsproxy1",        "on"]
    end

    # Platform-specific tuning (largepages and KVM paravirt are Linux/Windows-only)
    if RUBY_PLATFORM =~ /darwin/
      vb.customize ["modifyvm", :id, "--paravirtprovider", "default"]
    else
      vb.customize ["modifyvm", :id, "--largepages", "on"]
      vb.customize ["modifyvm", :id, "--paravirtprovider", "kvm"]
    end
  end

  # -- Timeouts --
  config.vm.boot_timeout      = 900
  config.ssh.connect_timeout  = 120

  # -- Synced folder --
  config.vm.synced_folder "%%WORKSPACE%%", "/home/vagrant/workspace",
    type: "virtualbox", create: true

  # ================================================================
  # Provisioning  (split into stages for clarity and cacheability)
  # ================================================================

  # --- Stage 1: System prep ---
  config.vm.provision "shell", name: "base-packages", inline: <<-'SHELL'
    set -euo pipefail
    trap 'echo "ERROR: base-packages stage failed at line $LINENO (exit $?)" >&2; echo "  System: $(uname -a)"; df -h / 2>/dev/null; exit 1' ERR
    echo ">>> Updating system & installing base packages"
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends \
      curl git jq tar unzip bash-completion apt-transport-https ca-certificates \
      gnupg lsb-release htop tmux vim tree make gcc libssl-dev \
      postgresql-client mysql-client redis-tools \
      python3 python3-pip python3-venv \
      netcat-openbsd dnsutils iputils-ping telnet \
      zip p7zip-full wget net-tools
    echo "  + Base packages installed (including database clients, Python3, network tools)"
  SHELL

  # --- Stage 2: Java 21 ---
  config.vm.provision "shell", name: "java", inline: <<-'SHELL'
    set -euo pipefail
    trap 'echo "ERROR: java stage failed at line $LINENO (exit $?)" >&2; exit 1' ERR
    echo ">>> Installing Java 21 (OpenJDK)"
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get install -y --no-install-recommends openjdk-21-jdk-headless
    java -version 2>&1 || { echo "ERROR: java not found after install" >&2; exit 1; }
    echo "  + Java: $(java -version 2>&1 | head -1)"
  SHELL

  # --- Stage 2b: Maven ---
  config.vm.provision "shell", name: "maven", inline: <<-'SHELL'
    set -euo pipefail
    trap 'echo "ERROR: maven stage failed at line $LINENO (exit $?)" >&2; exit 1' ERR
    echo ">>> Installing Maven"
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get install -y --no-install-recommends maven
    mvn --version 2>&1 || { echo "ERROR: mvn not found after install" >&2; exit 1; }
    echo "  + Maven: $(mvn --version 2>&1 | head -1)"
  SHELL

  # --- Stage 3: Node.js LTS ---
  config.vm.provision "shell", name: "nodejs", inline: <<-'SHELL'
    set -euo pipefail
    trap 'echo "ERROR: nodejs stage failed at line $LINENO (exit $?)" >&2; exit 1' ERR
    echo ">>> Installing Node.js LTS"
    export DEBIAN_FRONTEND=noninteractive
    curl -fsSL https://deb.nodesource.com/setup_%%NODE_VERSION%%.x | sudo bash -
    sudo apt-get install -y nodejs
    echo "  + Node $(node -v)  npm $(npm -v)"
  SHELL

  # --- Stage 4: Docker ---
  config.vm.provision "shell", name: "docker", inline: <<-'SHELL'
    set -euo pipefail
    trap 'echo "ERROR: docker stage failed at line $LINENO (exit $?)" >&2; echo "  Docker status: $(systemctl is-active docker 2>/dev/null || echo unknown)"; exit 1' ERR
    echo ">>> Installing Docker CE"
    export DEBIAN_FRONTEND=noninteractive
    if ! command -v docker &>/dev/null; then
      sudo install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
      sudo chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
      sudo apt-get update -qq
      sudo apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
    sudo systemctl enable --now docker
    sudo usermod -aG docker vagrant

    # Expose Docker daemon on TCP for host access (private network only)
    sudo mkdir -p /etc/systemd/system/docker.service.d
    cat <<'OVERRIDE' | sudo tee /etc/systemd/system/docker.service.d/override.conf > /dev/null
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H fd:// -H tcp://%%PRIVATE_IP%%:2375 --containerd=/run/containerd/containerd.sock
OVERRIDE
    sudo systemctl daemon-reload
    sudo systemctl restart docker
    echo "  + Docker: $(docker --version)"
    echo "  + Docker TCP listener enabled on port 2375"
  SHELL

  # --- Stage 5: k3s ---
  config.vm.provision "shell", name: "k3s", inline: <<-'SHELL'
    set -euo pipefail
    trap 'echo "ERROR: k3s stage failed at line $LINENO (exit $?)" >&2; echo "  k3s service: $(systemctl is-active k3s 2>/dev/null || echo unknown)"; journalctl -u k3s --no-pager -n 20 2>/dev/null || true; exit 1' ERR
    echo ">>> Installing k3s (lightweight Kubernetes)"
    export INSTALL_K3S_EXEC="--write-kubeconfig-mode 644 --disable traefik --tls-san %%PRIVATE_IP%% --node-external-ip %%PRIVATE_IP%% --flannel-iface eth1"
    K3S_VER='%%K3S_VERSION%%'
    if [ -n "$K3S_VER" ]; then export INSTALL_K3S_VERSION="$K3S_VER"; fi
    echo "  k3s install flags: $INSTALL_K3S_EXEC"
    echo "  k3s version pin:   ${INSTALL_K3S_VERSION:-latest}"
    curl -sfL https://get.k3s.io | sh -

    echo ">>> Waiting for k3s kubeconfig..."
    for i in $(seq 1 45); do
      [ -f /etc/rancher/k3s/k3s.yaml ] && break
      sleep 2
    done
    if [ ! -f /etc/rancher/k3s/k3s.yaml ]; then
      echo "ERROR: k3s kubeconfig not found after 90s" >&2
      echo "  k3s service status:" >&2
      systemctl status k3s --no-pager 2>&1 | head -20 || true
      echo "  k3s journal (last 30 lines):" >&2
      journalctl -u k3s --no-pager -n 30 2>/dev/null || true
      exit 1
    fi

    echo ">>> Waiting for k3s node to be Ready..."
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    for i in $(seq 1 60); do
      kubectl get nodes 2>/dev/null | grep -q ' Ready' && break
      sleep 2
    done
    if ! kubectl get nodes 2>/dev/null | grep -q ' Ready'; then
      echo "ERROR: k3s node not Ready after 120s" >&2
      echo "  Node status:" >&2
      kubectl get nodes -o wide 2>&1 || true
      echo "  k3s journal (last 30 lines):" >&2
      journalctl -u k3s --no-pager -n 30 2>/dev/null || true
      echo "  System pods:" >&2
      kubectl get pods -A 2>&1 || true
      exit 1
    fi
    echo "  + k3s: $(k3s --version | head -1)"
  SHELL

  # --- Stage 6: Helm ---
  config.vm.provision "shell", name: "helm", inline: <<-'SHELL'
    set -euo pipefail
    trap 'echo "ERROR: helm stage failed at line $LINENO (exit $?)" >&2; exit 1' ERR
    echo ">>> Installing Helm"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    helm version --short || { echo "ERROR: helm not found after install" >&2; exit 1; }
    echo "  + $(helm version --short)"
  SHELL

  # --- Stage 7: Extra CLI tools ---
  config.vm.provision "shell", name: "cli-tools", env: { "GITHUB_TOKEN" => "%%GH_TOKEN%%" }, inline: <<-'SHELL'
    set -euo pipefail
    trap 'echo "ERROR: cli-tools stage failed at line $LINENO (exit $?)" >&2; echo "  GitHub API rate limit remaining:"; curl -s https://api.github.com/rate_limit 2>/dev/null | grep -A2 rate || true; exit 1' ERR
    echo "  GitHub token: $(if [ -n "${GITHUB_TOKEN:-}" ]; then echo "provided (authenticated API)"; else echo "NOT SET (60 req/hr limit)"; fi)"

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
      local tmpcheck
      tmpcheck=$(mktemp)
      if ! curl -sL --fail -o "$tmpcheck" "$checksums_url"; then
        echo "  ! Checksum file download failed for $filename, skipping verification"
        rm -f "$tmpcheck"
        return 0
      fi
      expected=$(grep "$filename" "$tmpcheck" 2>/dev/null | awk '{print $1}' | head -1)
      rm -f "$tmpcheck"
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

    echo ">>> Installing stern (Kubernetes log viewer)"
    STERN_REL=$(gh_api https://api.github.com/repos/stern/stern/releases/latest)
    STERN_URL=$(extract_url "$STERN_REL" "browser_download_url.*linux_amd64.tar.gz")
    STERN_CHECKSUMS=$(extract_url "$STERN_REL" "browser_download_url.*checksums.txt")
    if [ -z "$STERN_URL" ]; then echo "  ! Failed to get stern download URL, skipping" >&2; else
      curl -sL -o /tmp/stern.tar.gz "$STERN_URL"
      verify_checksum /tmp/stern.tar.gz "$STERN_CHECKSUMS" "$(basename "$STERN_URL")" || true
      tar -xzf /tmp/stern.tar.gz -C /tmp stern
      sudo mv /tmp/stern /usr/local/bin/
      rm -f /tmp/stern.tar.gz
      echo "  + stern installed"
    fi

    echo ">>> Installing GitHub CLI (gh)"
    if ! command -v gh &>/dev/null; then
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
      sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
      sudo apt-get update -qq
      sudo apt-get install -y gh
      echo "  + gh: $(gh --version | head -1)"
    fi

    echo ">>> Installing Terraform"
    if ! command -v terraform &>/dev/null; then
      wget -qO- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null
      echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
      sudo apt-get update -qq
      sudo apt-get install -y terraform
      echo "  + Terraform: $(terraform version | head -1)"
    fi

    echo "  + Additional tools installed: stern, gh, terraform"
  SHELL

  # --- Stage 7b: Additional development tools ---
  config.vm.provision "shell", name: "additional-dev-tools", inline: <<-'SHELL'
    set -euo pipefail
    trap 'echo "ERROR: additional-dev-tools stage failed at line $LINENO (exit $?)" >&2; exit 1' ERR
    echo ">>> Installing additional development utilities"

    echo ">>> Installing yarn (alternative Node.js package manager)"
    if ! command -v yarn &>/dev/null; then
      sudo npm install -g yarn
      echo "  + Yarn: $(yarn --version)"
    fi

    echo ">>> Installing pnpm (fast Node.js package manager)"
    if ! command -v pnpm &>/dev/null; then
      sudo npm install -g pnpm
      echo "  + pnpm: $(pnpm --version)"
    fi

    echo "  + Development tools configuration complete"
  SHELL

  # --- Stage 7c: Moctra-specific tools ---
  config.vm.provision "shell", name: "moctra-tools", env: { "GITHUB_TOKEN" => "%%GH_TOKEN%%" }, inline: <<-'SHELL'
    set -euo pipefail
    trap 'echo "ERROR: moctra-tools stage failed at line $LINENO (exit $?)" >&2; exit 1' ERR
    echo ">>> Installing Moctra-specific development tools"

    # Helper: authenticated GitHub API calls
    gh_api() {
      local url="$1"
      local args=(-s)
      if [ -n "${GITHUB_TOKEN:-}" ]; then
        args+=(-H "Authorization: token $GITHUB_TOKEN")
      fi
      curl "${args[@]}" "$url"
    }

    echo ">>> Installing Apache Kafka CLI tools"
    if ! command -v kafka-topics.sh &>/dev/null; then
      KAFKA_VERSION="3.7.0"
      KAFKA_SCALA_VERSION="2.13"
      curl -sL -o /tmp/kafka.tgz "https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/kafka_${KAFKA_SCALA_VERSION}-${KAFKA_VERSION}.tgz"
      sudo tar -xzf /tmp/kafka.tgz -C /opt/
      sudo ln -sf "/opt/kafka_${KAFKA_SCALA_VERSION}-${KAFKA_VERSION}" /opt/kafka
      # Add kafka bin to PATH for all users
      echo 'export PATH=/opt/kafka/bin:$PATH' | sudo tee /etc/profile.d/kafka.sh > /dev/null
      rm -f /tmp/kafka.tgz
      echo "  + Kafka CLI: ${KAFKA_VERSION}"
    fi

    echo ">>> Installing MinIO Client (mc)"
    if ! command -v mc &>/dev/null; then
      curl -sL -o /tmp/mc https://dl.min.io/client/mc/release/linux-amd64/mc
      sudo install -m 755 /tmp/mc /usr/local/bin/mc
      rm -f /tmp/mc
      echo "  + MinIO Client: $(mc --version | head -1)"
    fi

    echo ">>> Installing kcat (Kafka CLI tool, formerly kafkacat)"
    if ! command -v kcat &>/dev/null; then
      sudo apt-get install -y --no-install-recommends kcat
      echo "  + kcat: $(kcat -V 2>&1 | head -1)"
    fi

    echo ">>> Installing dive (Docker image layer explorer)"
    if ! command -v dive &>/dev/null; then
      DIVE_REL=$(gh_api https://api.github.com/repos/wagoodman/dive/releases/latest)
      DIVE_VERSION=$(echo "$DIVE_REL" | grep '"tag_name"' | cut -d'"' -f4 | sed 's/^v//')
      if [ -n "$DIVE_VERSION" ]; then
        curl -sL -o /tmp/dive.deb "https://github.com/wagoodman/dive/releases/download/v${DIVE_VERSION}/dive_${DIVE_VERSION}_linux_amd64.deb"
        sudo dpkg -i /tmp/dive.deb
        rm -f /tmp/dive.deb
        echo "  + dive: $(dive --version 2>&1 | head -1)"
      else
        echo "  ! Failed to get dive version (GitHub API rate limit?)"
      fi
    fi

    echo ">>> Installing ctop (container metrics viewer)"
    if ! command -v ctop &>/dev/null; then
      CTOP_REL=$(gh_api https://api.github.com/repos/bcicen/ctop/releases/latest)
      CTOP_URL=$(echo "$CTOP_REL" | grep "browser_download_url.*linux-amd64" | head -1 | cut -d'"' -f4)
      if [ -n "$CTOP_URL" ]; then
        sudo curl -sL -o /usr/local/bin/ctop "$CTOP_URL"
        sudo chmod +x /usr/local/bin/ctop
        echo "  + ctop: $(ctop -v 2>&1)"
      else
        echo "  ! Failed to get ctop download URL (GitHub API rate limit?)"
      fi
    fi

    echo "  + Moctra-specific tools installed: kafka-cli, mc, kcat, dive, ctop"
  SHELL

  # --- Stage 8: User environment ---
  config.vm.provision "shell", name: "env-setup", inline: <<-'SHELL'
    set -euo pipefail
    trap 'echo "ERROR: env-setup stage failed at line $LINENO (exit $?)" >&2; exit 1' ERR
    echo ">>> Configuring vagrant user environment"

    # kubeconfig for vagrant user
    mkdir -p /home/vagrant/.kube
    if [ -f /etc/rancher/k3s/k3s.yaml ]; then
      sudo cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
      sudo chown -R vagrant:vagrant /home/vagrant/.kube
    else
      echo "  ! k3s kubeconfig not found, skipping .kube/config setup" >&2
    fi

    # Idempotent .bashrc additions (only append if sentinel comment is absent)
    if ! grep -q '# == Dev VM environment ==' /home/vagrant/.bashrc 2>/dev/null; then
      cat >> /home/vagrant/.bashrc << 'BASHRC_BLOCK'

# == Dev VM environment ==
export KUBECONFIG=/home/vagrant/.kube/config
if command -v java &>/dev/null; then export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java)))); fi
export MAVEN_HOME=/usr/share/maven
export M2_HOME=$MAVEN_HOME
export PATH=$JAVA_HOME/bin:$MAVEN_HOME/bin:$PATH

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
      printf 'export GITHUB_TOKEN=%q\n' "$GH_TOKEN" >> /home/vagrant/.bashrc
    fi
    if [ -n "$DH_TOKEN" ] && ! grep -q 'DOCKERHUB_TOKEN' /home/vagrant/.bashrc 2>/dev/null; then
      printf 'export DOCKERHUB_TOKEN=%q\n' "$DH_TOKEN" >> /home/vagrant/.bashrc
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
      echo "$DH_TOKEN" | sudo -u vagrant docker login -u "$DH_USER" --password-stdin 2>&1
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
    printf "  %-15s %s\n" "Docker:"     "$(docker --version 2>/dev/null || echo 'NOT FOUND')"
    printf "  %-15s %s\n" "k3s:"        "$(k3s --version 2>/dev/null | head -1 || echo 'NOT FOUND')"
    printf "  %-15s %s\n" "kubectl:"    "$(kubectl version --client 2>/dev/null | head -1 || echo 'NOT FOUND')"
    printf "  %-15s %s\n" "Helm:"       "$(helm version --short 2>/dev/null || echo 'NOT FOUND')"
    printf "  %-15s %s\n" "Java:"       "$(java -version 2>&1 | head -1 || echo 'NOT FOUND')"
    printf "  %-15s %s\n" "Maven:"      "$(mvn --version 2>&1 | head -1 || echo 'NOT FOUND')"
    printf "  %-15s %s\n" "Node:"       "$(node -v 2>/dev/null || echo 'NOT FOUND')"
    printf "  %-15s %s\n" "Yarn:"       "$(yarn --version 2>/dev/null || echo 'NOT FOUND')"
    printf "  %-15s %s\n" "pnpm:"       "$(pnpm --version 2>/dev/null || echo 'NOT FOUND')"
    printf "  %-15s %s\n" "k9s:"        "$(k9s version --short 2>/dev/null || echo 'installed')"
    printf "  %-15s %s\n" "yq:"         "$(yq --version 2>/dev/null || echo 'NOT FOUND')"
    printf "  %-15s %s\n" "PostgreSQL:" "$(psql --version 2>/dev/null || echo 'NOT FOUND')"
    printf "  %-15s %s\n" "Redis:"      "$(redis-cli --version 2>/dev/null || echo 'NOT FOUND')"
    printf "  %-15s %s\n" "Kafka CLI:"  "$([[ -f /opt/kafka/bin/kafka-topics.sh ]] && echo '3.7.0' || echo 'NOT FOUND')"
    printf "  %-15s %s\n" "MinIO mc:"   "$(mc --version 2>/dev/null | head -1 || echo 'NOT FOUND')"
    printf "  %-15s %s\n" "kcat:"       "$(kcat -V 2>&1 | head -1 || echo 'NOT FOUND')"
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
$sshPubKeysEscaped = if ($sshPubKeys) { $sshPubKeys -replace "'", "'\\''" } else { '' }
$Vagrantfile = $Vagrantfile.Replace('%%SSH_PUB_KEYS%%',  $sshPubKeysEscaped)

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
        Set-Utf8NoBom -Path $VagrantfilePath -Content $Vagrantfile
        Write-Ok "Vagrantfile updated: $VagrantfilePath"
    }
} else {
    Set-Utf8NoBom -Path $VagrantfilePath -Content $Vagrantfile
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

# Remove stale VirtualBox VM registration if one exists with the same name.
# This can happen after a VirtualBox reinstall or aborted cleanup.
if ($IsWin) { Add-VBoxToPath }
if (Get-Command VBoxManage -ErrorAction SilentlyContinue) {
    $prevEAPStale = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $staleVM = VBoxManage showvminfo $VMName --machinereadable 2>$null
    $staleVMExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEAPStale
    if ($staleVMExit -eq 0) {
        $vmUUIDMatch = $staleVM | Select-String -Pattern '^UUID="([^"]+)"'
        $vmUUID = if ($vmUUIDMatch) { $vmUUIDMatch.Matches[0].Groups[1].Value } else { '' }
        $vmStateMatch = $staleVM | Select-String -Pattern '^VMState="([^"]+)"'
        $vmState = if ($vmStateMatch) { $vmStateMatch.Matches[0].Groups[1].Value } else { 'unknown' }
        # Only remove if Vagrant doesn't manage this specific VM (UUID mismatch or no id file)
        $vagrantIdFile = Join-Path $VagrantDir ".vagrant\machines\default\virtualbox\id"
        $vagrantUUID = if (Test-Path $vagrantIdFile) { (Get-Content $vagrantIdFile -Raw).Trim() } else { '' }
        if ($vagrantUUID -ne $vmUUID) {
            Write-Warn "Found stale VirtualBox VM '$VMName' (state: $vmState) not managed by Vagrant. Removing..."
            $prevEAPStale = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            if ($vmState -eq 'running') {
                VBoxManage controlvm $VMName poweroff 2>$null | Out-Null
                Start-Sleep -Seconds 2
            }
            VBoxManage unregistervm $VMName --delete 2>$null | Out-Null
            $unregExit = $LASTEXITCODE
            $ErrorActionPreference = $prevEAPStale
            if ($unregExit -eq 0) {
                Write-Ok "Removed stale VM '$VMName'."
            } else {
                Write-Err "Failed to remove stale VM '$VMName'. Remove it manually: VBoxManage unregistervm $VMName --delete"
                Write-Diagnostics -Context "stale VM removal failed"
                exit 1
            }
        }
    }
}

# Temporarily relax error handling — vagrant writes progress and warnings to
# stderr, which PowerShell's StrictMode treats as terminating errors.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'

# Retry vagrant up on boot timeout — first boot on Windows can be slow due to
# disk resize, SSH key setup, and VirtualBox/Hyper-V compatibility delays.
$maxAttempts = 3
$vagrantExitCode = 1
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    if ($attempt -gt 1) {
        Write-Warn "Retrying vagrant up (attempt $attempt of $maxAttempts)..."
        # VM may already be running — use --no-provision to just wait for SSH
        $vagrantOutput = vagrant up --no-provision 2>&1
    } else {
        $vagrantOutput = vagrant up 2>&1
    }
    $vagrantExitCode = $LASTEXITCODE
    $vagrantOutput | ForEach-Object { Write-Host $_ }

    if ($vagrantExitCode -eq 0) { break }

    $isBootTimeout = ($vagrantOutput | Out-String) -match 'Timed out while waiting for the machine to boot'
    if (-not $isBootTimeout -or $attempt -eq $maxAttempts) { break }

    Write-Warn 'Boot timeout detected — VM may still be starting. Waiting 30 seconds before retry...'
    Start-Sleep -Seconds 30
}

# If first vagrant up timed out but a retry connected without provisioning, run provisioning now
if ($vagrantExitCode -eq 0 -and $attempt -gt 1) {
    Write-Step 'Running provisioning (skipped during retry)...'
    $provOutput = vagrant provision 2>&1
    $provExitCode = $LASTEXITCODE
    $provOutput | ForEach-Object { Write-Host $_ }
    if ($provExitCode -ne 0) {
        $vagrantExitCode = $provExitCode
    }
}

$ErrorActionPreference = $prevEAP

if ($vagrantExitCode -ne 0) {
    Write-Err "vagrant up failed (exit $vagrantExitCode). Check logs above."
    Write-Warn "Full log: $LogFile"
    Write-Diagnostics -Context "vagrant up failed (exit $vagrantExitCode)"

    # Dump VM-side logs if SSH is reachable
    $prevEAP2 = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    Write-Host '  Attempting to retrieve VM-side diagnostics...' -ForegroundColor DarkGray
    $vmDiag = vagrant ssh -c @'
echo "=== VM DIAGNOSTICS ==="
echo "Hostname: $(hostname)"
echo "Uptime: $(uptime)"
echo "Disk:"
df -h / 2>/dev/null
echo "Memory:"
free -h 2>/dev/null
echo "Failed services:"
systemctl --failed 2>/dev/null || true
echo "Docker status: $(systemctl is-active docker 2>/dev/null || echo 'not installed')"
echo "k3s status: $(systemctl is-active k3s 2>/dev/null || echo 'not installed')"
echo "Last 15 lines of syslog:"
tail -15 /var/log/syslog 2>/dev/null || journalctl -n 15 --no-pager 2>/dev/null || echo "(unavailable)"
echo "=== END DIAGNOSTICS ==="
'@ 2>$null
    if ($vmDiag) { $vmDiag | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
    else { Write-Warn 'Could not SSH into VM for diagnostics.' }
    $ErrorActionPreference = $prevEAP2

    # Offer retry — useful when the VM booted but provisioning timed out
    if (-not $SkipConfirm) {
        $retry = Read-Host '  Retry provisioning? (y/N)'
        if ($retry -match '^[Yy]') {
            Write-Step 'Retrying provisioning (vagrant provision)...'
            $ErrorActionPreference = 'Continue'
            $provisionOutput = vagrant provision 2>&1
            $vagrantExitCode = $LASTEXITCODE
            $provisionOutput | ForEach-Object { Write-Host $_ }
            $ErrorActionPreference = $prevEAP

            if ($vagrantExitCode -ne 0) {
                Write-Err "vagrant provision also failed (exit $vagrantExitCode)."
                Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
                exit $vagrantExitCode
            }
            Write-Ok 'Provisioning retry succeeded!'
            Write-Step 'Running post-retry repair checks'
            $retryRepairOk = Invoke-Repair -Quiet
            if (-not $retryRepairOk) { Write-Warn 'Post-retry repair found issues.' }
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
$prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$kubeconfigContent = vagrant ssh -c "sudo cat /etc/rancher/k3s/k3s.yaml" 2>$null |
    ForEach-Object { $_ -replace 'server: https://127\.0\.0\.1:6443', "server: https://${PrivateIP}:6443" }
$kubeconfigRaw = ($kubeconfigContent | Out-String)
if ($kubeconfigRaw -match 'apiVersion:') {
    Set-Utf8NoBom -Path $kubeconfigDest -Content $kubeconfigContent
} else {
    Write-Warn 'Kubeconfig content from VM does not look valid (missing apiVersion). Skipping.'
}
$ErrorActionPreference = $prevEAP

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
        Write-Warn 'kubectl not found on host. Connectivity test skipped.'
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
if ($repairOk) {
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    vagrant snapshot save fresh-install 2>&1 | ForEach-Object { Write-Host "  $_" }
    $snapshotExitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP

    if ($snapshotExitCode -eq 0) {
        Write-Ok "Snapshot 'fresh-install' saved. Restore with: vagrant snapshot restore fresh-install"
    } else {
        Write-Warn 'Snapshot failed (non-critical). You can create one manually later.'
    }
} else {
    Write-Warn 'Skipping snapshot due to unresolved health issues.'
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
Write-Host '  Host environment variables set:' -ForegroundColor Cyan
if ($env:JAVA_HOME) {
    Write-Host "    JAVA_HOME  = $env:JAVA_HOME" -ForegroundColor White
}
if ($env:MAVEN_HOME) {
    Write-Host "    MAVEN_HOME = $env:MAVEN_HOME" -ForegroundColor White
}
Write-Host ''
Write-Host '  Use from your host terminal:' -ForegroundColor Cyan
Write-Host "    `$env:KUBECONFIG = `"$kubeconfigDest`"" -ForegroundColor White
Write-Host "    `$env:DOCKER_HOST = `"tcp://${PrivateIP}:2375`"" -ForegroundColor White
Write-Host '    kubectl get nodes' -ForegroundColor White
Write-Host '    helm install <name> <chart>' -ForegroundColor White
Write-Host '    docker ps' -ForegroundColor White
Write-Host '    mvn --version' -ForegroundColor White
Write-Host '    java -version' -ForegroundColor White
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
