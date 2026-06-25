# bootstrap.ps1 — runs once at first logon (called by autounattend.xml).
# Installs the virtio guest tools + qemu-guest-agent, installs and configures
# Cloudbase-Init (so each clone gets a fresh identity + per-provision config),
# hardens RDP for Kasm, then leaves the VM ready for sysprep.
#
# It is copied onto the answer ISO next to autounattend.xml. Logs to
# C:\kasm-bootstrap.log. After it finishes, finalize with sysprep (see
# docs/WINDOWS-DESKTOP-POOL.md) — that's the only manual step.

$ErrorActionPreference = 'Stop'
Start-Transcript -Path 'C:\kasm-bootstrap.log' -Append | Out-Null
function Log($m) { Write-Host ("[bootstrap] {0}" -f $m) }

# --- locate the virtio-win ISO drive ----------------------------------------
$virtio = Get-Volume | Where-Object { $_.DriveType -eq 'CD-ROM' } |
  ForEach-Object { "$($_.DriveLetter):\" } |
  Where-Object { Test-Path (Join-Path $_ 'virtio-win-guest-tools.exe') } |
  Select-Object -First 1

if ($virtio) {
  Log "Installing virtio guest tools + qemu-guest-agent from $virtio"
  # /S = silent. Installs balloon, vioscsi, NetKVM, and the QEMU guest agent.
  Start-Process -Wait -FilePath (Join-Path $virtio 'virtio-win-guest-tools.exe') -ArgumentList '/S'
  # Belt and braces: install the standalone guest-agent MSI too if present.
  $qga = Join-Path $virtio 'guest-agent\qemu-ga-x86_64.msi'
  if (Test-Path $qga) { Start-Process -Wait msiexec.exe -ArgumentList "/i `"$qga`" /qn" }
  Set-Service -Name QEMU-GA -StartupType Automatic -ErrorAction SilentlyContinue
  Start-Service -Name QEMU-GA -ErrorAction SilentlyContinue
} else {
  Log "WARNING: virtio-win ISO not found — qemu-guest-agent NOT installed (Kasm needs it!)."
}

# --- enable Remote Desktop (Kasm brokers the desktop over RDP) ---------------
Log "Enabling Remote Desktop + NLA + firewall rule"
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 1
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'

# --- install Cloudbase-Init (Windows cloud-init) -----------------------------
# Lets each clone read the Proxmox cloud-init drive: unique hostname, injected
# admin password, and a sysprep-on-first-boot to regenerate the SID.
$cbDir = 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init'
if (-not (Test-Path $cbDir)) {
  Log "Downloading + installing Cloudbase-Init"
  $msi = "$env:TEMP\CloudbaseInitSetup.msi"
  try {
    Invoke-WebRequest -UseBasicParsing `
      -Uri 'https://github.com/cloudbase/cloudbase-init/releases/latest/download/CloudbaseInitSetup_Stable_x64.msi' `
      -OutFile $msi
    Start-Process -Wait msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart"
  } catch {
    Log "WARNING: Cloudbase-Init download failed ($_). Install it manually before sysprep."
  }
}

# Drop our Cloudbase-Init config + sysprep unattend if they shipped on the ISO.
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$confDst = Join-Path $cbDir 'conf'
foreach ($f in @('cloudbase-init.conf','cloudbase-init-unattend.conf','Unattend.xml')) {
  $s = Join-Path $src $f
  if ((Test-Path $s) -and (Test-Path $confDst)) { Copy-Item $s $confDst -Force; Log "Installed $f" }
}

# --- light cleanup -----------------------------------------------------------
Log "Disabling hibernation, clearing autologon flag"
powercfg /h off 2>$null
# AutoLogon LogonCount=1 already expired; make sure it's off.
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoAdminLogon -Value 0 -ErrorAction SilentlyContinue

Log "Bootstrap complete. VM is ready to sysprep (see docs/WINDOWS-DESKTOP-POOL.md)."
Stop-Transcript | Out-Null
