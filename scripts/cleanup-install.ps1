# ============================================================
# Dev VM Cleanup Script
# Destroys the VM and removes generated artifacts.
# Can be run standalone or via: setup-dev-vm.ps1 -Action Cleanup
# ============================================================
#Requires -Version 5.1

<#
.SYNOPSIS
    Tears down the dev VM and removes generated files.

.DESCRIPTION
    Performs a staged cleanup:
      1. Removes VM snapshots & destroys the Vagrant VM.
      2. Removes generated files (Vagrantfile, .vagrant/, log, env.yaml).
      3. Removes the workspace/ synced folder.
      4. Removes the host-side kubeconfig for this VM.
      5. Optionally uninstalls host tools (Vagrant, VirtualBox, kubectl, Helm, Docker CLI).

    Each destructive step asks for confirmation unless -SkipConfirm is set.

.PARAMETER VMName
    Name of the VM (used to locate the host kubeconfig file).
    Default: dev-vm

.PARAMETER SkipConfirm
    Skip all confirmation prompts (for scripted / CI use).

.EXAMPLE
    .\cleanup-install.ps1
    # Interactive cleanup with confirmations.

.EXAMPLE
    .\cleanup-install.ps1 -SkipConfirm
    # Destroy everything without prompts.

.EXAMPLE
    .\cleanup-install.ps1 -VMName myvm
    # Clean up a VM with a custom name.
#>

[CmdletBinding()]
param(
    [string]$VMName = 'dev-vm',
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

# ─── Utilities ──────────────────────────────────────────────
function Write-Step  { param([string]$Msg) Write-Host "`n>>> $Msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "  + $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "  ! $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "  X $Msg" -ForegroundColor Red }

function Confirm-Step {
    param([string]$Prompt)
    if ($SkipConfirm) { return $true }
    $answer = Read-Host "  $Prompt (y/N)"
    return ($answer -match '^[Yy]')
}

# Wrap winget/brew uninstall with consistent error handling
function Invoke-Uninstall {
    param([string]$Label, [scriptblock]$Command)
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        & $Command 2>&1 | ForEach-Object { Write-Host "    $_" }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($exitCode -eq 0) {
        Write-Ok "$Label uninstalled."
        return $true
    } elseif ($exitCode -eq 3010) {
        Write-Ok "$Label uninstalled (reboot required to complete)."
        return $true
    } else {
        Write-Err "$Label uninstall returned exit code $exitCode."
        return $false
    }
}

# ─── Banner ─────────────────────────────────────────────────
Write-Host ''
Write-Host '======================================================' -ForegroundColor Yellow
Write-Host '               Dev VM Cleanup                         ' -ForegroundColor Yellow
Write-Host '======================================================' -ForegroundColor Yellow
Write-Host ''
Write-Host '  This will destroy the VM and remove generated files.' -ForegroundColor Yellow
Write-Host ''

if (-not $SkipConfirm) {
    $go = Read-Host '  Are you sure you want to proceed? (y/N)'
    if ($go -notmatch '^[Yy]') {
        Write-Host '  Cleanup aborted.'
        exit 0
    }
}

$removedSomething = $false

# ─────────────────────────────────────────────────────────────
# 1. Remove VM snapshots & destroy the VM
# ─────────────────────────────────────────────────────────────
Write-Step 'Vagrant VM'

if (Test-Path (Join-Path $VagrantDir 'Vagrantfile')) {
    # Check if vagrant is available
    if (Get-Command vagrant -ErrorAction SilentlyContinue) {
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $status = vagrant status --machine-readable 2>$null |
                  Select-String -Pattern ',state,' |
                  ForEach-Object { ($_ -split ',')[3] }
        $ErrorActionPreference = $prevEAP

        if ($status -and $status -ne 'not_created') {
            # Remove snapshots first
            $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            $rawSnapshots = vagrant snapshot list 2>$null
            $snapshotExit = $LASTEXITCODE
            $ErrorActionPreference = $prevEAP

            if ($snapshotExit -eq 0 -and $rawSnapshots -and $rawSnapshots -notmatch 'No snapshots') {
                # Filter to non-empty trimmed lines (skip any vagrant output noise)
                $snapNames = @($rawSnapshots | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^==>|^$' })
                if ($snapNames.Count -gt 0) {
                    Write-Warn "Snapshots found:"
                    $snapNames | ForEach-Object { Write-Host "    $_" }
                    if (Confirm-Step 'Delete all VM snapshots?') {
                        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                        foreach ($snapName in $snapNames) {
                            vagrant snapshot delete $snapName 2>&1 | ForEach-Object { Write-Host "    $_" }
                        }
                        $ErrorActionPreference = $prevEAP
                        Write-Ok 'Snapshots deleted.'
                        $removedSomething = $true
                    } else {
                        Write-Warn 'Kept snapshots.'
                    }
                }
            }

            Write-Warn "VM state: $status"
            if (Confirm-Step 'Destroy the Vagrant VM?') {
                $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                vagrant destroy -f 2>&1 | ForEach-Object { Write-Host "    $_" }
                $destroyExit = $LASTEXITCODE
                $ErrorActionPreference = $prevEAP
                if ($destroyExit -eq 0) {
                    Write-Ok 'VM destroyed.'
                    $removedSomething = $true
                } else {
                    Write-Err "vagrant destroy failed (exit $destroyExit)."
                }
            } else {
                Write-Warn 'Skipped VM destruction.'
            }
        } else {
            Write-Ok 'No running VM found (state: not_created).'
        }
    } else {
        Write-Warn 'Vagrant is not installed. Cannot destroy VM — remove it manually via VirtualBox if needed.'
    }
} else {
    Write-Ok 'No Vagrantfile found. Nothing to destroy.'
}

# ─────────────────────────────────────────────────────────────
# 2. Remove generated files
# ─────────────────────────────────────────────────────────────
Write-Step 'Generated files'

# Check if env.yaml has credentials to warn the user
$envYamlPath = Join-Path $VagrantDir 'env.yaml'
$envYamlHasCreds = $false
if (Test-Path $envYamlPath) {
    $envContent = Get-Content $envYamlPath -Raw -ErrorAction SilentlyContinue
    if ($envContent -match 'credentials:') { $envYamlHasCreds = $true }
}

$filesToRemove = @(
    @{ Path = (Join-Path $VagrantDir 'Vagrantfile');      Label = 'Vagrantfile' }
    @{ Path = (Join-Path $VagrantDir '.vagrant');         Label = '.vagrant/ metadata' }
    @{ Path = (Join-Path $VagrantDir 'setup-dev-vm.log'); Label = 'Setup log' }
    @{ Path = $envYamlPath;                               Label = if ($envYamlHasCreds) { 'env.yaml (contains stored credentials!)' } else { 'env.yaml (user overrides)' } }
)

foreach ($item in $filesToRemove) {
    if (Test-Path $item.Path) {
        if (Confirm-Step "Remove $($item.Label)?") {
            Remove-Item $item.Path -Force -Recurse
            Write-Ok "Removed: $($item.Label)"
            $removedSomething = $true
        } else {
            Write-Warn "Kept: $($item.Label)"
        }
    }
}

# ─────────────────────────────────────────────────────────────
# 3. Remove workspace folder
# ─────────────────────────────────────────────────────────────
Write-Step 'Workspace folder'

$workspace = Join-Path $homeDir 'workspace'
if (Test-Path $workspace) {
    $itemCount = @(Get-ChildItem $workspace -Recurse -File -ErrorAction SilentlyContinue).Count
    Write-Warn "workspace/ contains $itemCount file(s)."
    if (Confirm-Step 'Remove the workspace/ folder and all its contents?') {
        Remove-Item $workspace -Recurse -Force
        Write-Ok 'Removed: workspace/'
        $removedSomething = $true
    } else {
        Write-Warn 'Kept: workspace/'
    }
} else {
    Write-Ok 'No workspace/ folder found.'
}

# ─────────────────────────────────────────────────────────────
# 4. Remove host-side kubeconfig
# ─────────────────────────────────────────────────────────────
Write-Step 'Host kubeconfig'

$kubeconfigDest = Join-Path (Join-Path $homeDir '.kube') "config-$VMName"
if (Test-Path $kubeconfigDest) {
    if (Confirm-Step "Remove host kubeconfig ($kubeconfigDest)?") {
        Remove-Item $kubeconfigDest -Force
        Write-Ok "Removed: $kubeconfigDest"
        Write-Warn 'If $env:KUBECONFIG points to this file, unset it or update your PowerShell profile.'
        $removedSomething = $true
    } else {
        Write-Warn "Kept: $kubeconfigDest"
    }
} else {
    Write-Ok "No host kubeconfig found for VM '$VMName'."
}

# ─────────────────────────────────────────────────────────────
# 5. Optionally uninstall host tools
# ─────────────────────────────────────────────────────────────
Write-Step 'Host tools (optional)'

if ($IsWin) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warn 'winget not found. Skipping tool uninstall checks.'
    } else {
        # Build a list of tools to check — ID, label
        $wingetTools = @(
            @{ Id = 'HashiCorp.Vagrant';   Label = 'Vagrant' }
            @{ Id = 'Oracle.VirtualBox';   Label = 'VirtualBox' }
            @{ Id = 'Kubernetes.kubectl';  Label = 'kubectl' }
            @{ Id = 'Helm.Helm';           Label = 'Helm' }
            @{ Id = 'Docker.DockerCLI';    Label = 'Docker CLI' }
            @{ Id = 'Derailed.k9s';        Label = 'k9s' }
        )

        foreach ($tool in $wingetTools) {
            $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            $installed = winget list --id $tool.Id --source winget 2>$null |
                         Select-String -Pattern ($tool.Id -replace '\.', '\.') -Quiet
            $ErrorActionPreference = $prevEAP
            if ($installed) {
                if (Confirm-Step "Uninstall $($tool.Label) via winget?") {
                    $result = Invoke-Uninstall -Label $tool.Label -Command ([scriptblock]::Create("winget uninstall --id $($tool.Id) --source winget"))
                    if ($result) { $removedSomething = $true }
                } else {
                    Write-Warn "Kept: $($tool.Label)"
                }
            } else {
                Write-Ok "$($tool.Label) not found via winget."
            }
        }
    }
} else {
    # macOS: use Homebrew
    if (-not (Get-Command brew -ErrorAction SilentlyContinue)) {
        Write-Warn 'Homebrew not found. Skipping tool uninstall checks.'
    } else {
        # Cask tools
        $brewCasks = @(
            @{ Name = 'vagrant';    Label = 'Vagrant' }
            @{ Name = 'virtualbox'; Label = 'VirtualBox' }
        )
        $installedCasks = brew list --cask 2>$null

        foreach ($cask in $brewCasks) {
            if ($installedCasks | Select-String -Pattern "^$($cask.Name)$" -Quiet) {
                if (Confirm-Step "Uninstall $($cask.Label) via Homebrew?") {
                    $result = Invoke-Uninstall -Label $cask.Label -Command ([scriptblock]::Create("brew uninstall --cask $($cask.Name)"))
                    if ($result) { $removedSomething = $true }
                } else {
                    Write-Warn "Kept: $($cask.Label)"
                }
            } else {
                Write-Ok "$($cask.Label) not found via Homebrew."
            }
        }

        # Formula tools
        $brewFormulae = @(
            @{ Name = 'kubectl';       Label = 'kubectl' }
            @{ Name = 'helm';          Label = 'Helm' }
            @{ Name = 'docker';        Label = 'Docker CLI' }
            @{ Name = 'k9s';           Label = 'k9s' }
        )
        $installedFormulae = brew list --formula 2>$null

        foreach ($formula in $brewFormulae) {
            if ($installedFormulae | Select-String -Pattern "^$($formula.Name)$" -Quiet) {
                if (Confirm-Step "Uninstall $($formula.Label) via Homebrew?") {
                    $result = Invoke-Uninstall -Label $formula.Label -Command ([scriptblock]::Create("brew uninstall $($formula.Name)"))
                    if ($result) { $removedSomething = $true }
                } else {
                    Write-Warn "Kept: $($formula.Label)"
                }
            } else {
                Write-Ok "$($formula.Label) not found via Homebrew."
            }
        }
    }
}

# ─────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────
Write-Host ''
if ($removedSomething) {
    Write-Host '======================================================' -ForegroundColor Green
    Write-Host '  Cleanup complete.' -ForegroundColor Green
    Write-Host '======================================================' -ForegroundColor Green
} else {
    Write-Host '  Nothing was removed.' -ForegroundColor Yellow
}
Write-Host ''
