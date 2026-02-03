# cleanup-dev-vm.ps1
# Fully automated cleanup of Fedora Dev VM setup

# -----------------------------
# Step 1: Confirm cleanup
# -----------------------------
Write-Host "WARNING: This will destroy the Fedora dev VM, remove synced folders, and optionally uninstall Windows tools."
$confirm = Read-Host "Are you sure you want to continue? Type 'yes' to proceed"
if ($confirm -ne "yes") {
    Write-Host "Cleanup aborted."
    exit
}

# -----------------------------
# Step 2: Destroy the Vagrant VM
# -----------------------------
if (Test-Path "Vagrantfile") {
    Write-Host "Destroying the VM..."
    vagrant destroy -f
} else {
    Write-Host "No Vagrantfile found. Skipping VM destruction."
}

# -----------------------------
# Step 3: Remove synced workspace folder
# -----------------------------
$workspaceFolder = Join-Path -Path (Get-Location) -ChildPath "workspace"
if (Test-Path $workspaceFolder) {
    Write-Host "Removing workspace folder..."
    Remove-Item -Recurse -Force $workspaceFolder
} else {
    Write-Host "No workspace folder found."
}

# -----------------------------
# Step 4: Remove env.yaml and Vagrantfile
# -----------------------------
if (Test-Path "env.yaml") {
    Remove-Item "env.yaml" -Force
    Write-Host "Removed env.yaml"
}
if (Test-Path "Vagrantfile") {
    Remove-Item "Vagrantfile" -Force
    Write-Host "Removed Vagrantfile"
}

# -----------------------------
# Step 5: Optional uninstall of Scoop packages
# -----------------------------
$uninstallTools = Read-Host "Do you want to uninstall Vagrant and VirtualBox installed via Scoop? (yes/no)"
if ($uninstallTools -eq "yes") {
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        # Uninstall Vagrant if installed
        if (scoop list | Select-String "^vagrant") {
            Write-Host "Uninstalling Vagrant..."
            scoop uninstall vagrant
        } else {
            Write-Host "Vagrant not installed via Scoop."
        }

        # Uninstall VirtualBox if installed
        if (scoop list | Select-String "^virtualbox") {
            Write-Host "Uninstalling VirtualBox..."
            scoop uninstall virtualbox
        } else {
            Write-Host "VirtualBox not installed via Scoop."
        }
    } else {
        Write-Host "Scoop not found, skipping tool uninstallation."
    }
}

Write-Host "`nCleanup complete. All VM artifacts and optionally host tools removed."
