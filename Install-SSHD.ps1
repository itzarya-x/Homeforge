#Install-SSHD.ps1 - Portable SSH Server Setup for Windows
#Compatibility: PowerShell 5.1 (no custom function names that conflict)
#Usage: PowerShell -ExecutionPolicy Bypass -File Install-SSHD.ps1 [options]

[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $Uninstall,
    [switch] $GenerateKey,
    [string] $PublicKey,
    [string] $PublicKeyPath,
    [switch] $DisablePasswordAuth,
    [switch] $SkipGit,
    [switch] $SkipTailscale,
    [string] $TailscaleAuthKey,
    [switch] $AllowOutboundSSH,
    [switch] $NoFullAdmin,
    [switch] $SkipFirewall,
    [switch] $Force,
    [switch] $PauseOnExit
)

# ==============================================================================
#  SINGLE HERE-STRING: ensure-sshd.ps1 content (PS 5.1 compatible)
# ==============================================================================
$EnsureSshdContent = '
# Creates/repairs the sshd service and starts it. Safe to run repeatedly.
$ErrorActionPreference = "SilentlyContinue"
$exe = "C:\Windows\System32\OpenSSH\sshd.exe"
if (-not (Test-Path $exe)) { $exe = "C:\Program Files\OpenSSH\sshd.exe" }
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    New-Service -Name sshd -BinaryPathName $exe -DisplayName "OpenSSH SSH Server" -StartupType Automatic -Description "OpenSSH SSH Server" | Out-Null
    Start-Sleep -Seconds 2
}
Set-Service -Name sshd -StartupType Automatic
if ((Get-Service sshd).Status -ne "Running") {
    Start-Service -Name sshd
    Start-Sleep -Seconds 1
}
# Heartbeat (kept small: last 200 lines)
$line = "{0}  action={1}  status={2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), "started", (Get-Service sshd).Status
Add-Content -Path "C:\ProgramData\ssh\ensure-sshd.log" -Value $line
$c = @(Get-Content "C:\ProgramData\ssh\ensure-sshd.log" -ErrorAction SilentlyContinue)
if ($c.Count -gt 200) { $c | Select-Object -Last 200 | Set-Content "C:\ProgramData\ssh\ensure-sshd.log" }
'

# ==============================================================================
#  HELPER FUNCTIONS (output prefixes computed inline)
# ==============================================================================

function Get-PassDisplay {
    if ($DisablePasswordAuth) { 'no' } else { 'yes' }
}
function Get-AdminDisplay {
    if ($NoFullAdmin) { 'DISABLED (restricted)' } else { 'ENABLED (Match Group administrators)' }
}
function Get-ObDisplay {
    if ($AllowOutboundSSH) { 'ALLOWED' } else { 'BLOCKED' }
}

# ==============================================================================
#  OPTION VALIDATION
# ==============================================================================

function Validate-Opts {
    Write-Host "S: Validating setup options..."
    if (-not $DisablePasswordAuth -and -not $NoFullAdmin) {
        Write-Host "W: Password authentication will be ENABLED by default."
        Write-Host "W: For security, consider running with: -DisablePasswordAuth"
        $c = Read-Host "Continue with password auth enabled? (Y/n): "
        if ($c -ne '' -and $c[0].ToLower() -ne 'y') { Write-Host "Setup cancelled."; exit 1 }
    }
    if (-not $NoFullAdmin) {
        Write-Host "W: Full admin over SSH will be configured via 'Match Group administrators' block."
        Write-Host "W: For restricted access, consider: -NoFullAdmin"
        $c = Read-Host "Continue with full admin configured? (Y/n): "
        if ($c -ne '' -and $c[0].ToLower() -ne 'y') { $NoFullAdmin = $true; Write-Host "S: Full admin disabled per your request." }
    }
    if (-not $AllowOutboundSSH) {
        Write-Host "W: Outbound TCP/22 to tailnet (100.64.0.0/10) will be BLOCKED."
        Write-Host "W: Use -AllowOutboundSSH to permit if needed."
    }
}

# ==============================================================================
#  EXIT HANDLER
# ==============================================================================

function Handle-Exit {
    param([int]$EC = 0, [string]$Msg = "")
    if ($Msg) { Write-Host "E: $Msg" }
    if ($PauseOnExit) { Write-Host "S: Press Enter to exit setup."; $r = Read-Host; }
    exit $EC
}

# ==============================================================================
#  OPENSSH INSTALLATION
# ==============================================================================

function Install-OpenSSH {
    Write-Host "S: Checking OpenSSH availability..."
    $s1 = 'C:\Windows\System32\OpenSSH\sshd.exe'
    $s2 = 'C:\Program Files\OpenSSH\sshd.exe'
    if ((Test-Path $s1) -or (Test-Path $s2)) {
        Write-Host "L: OpenSSH already installed at $($s1 + " or " + $s2)"
        try { $svc = Get-Service sshd -ErrorAction Stop; Write-Host "L: Service status: $($svc.Status)" } catch { Write-Host "L: Existing sshd found but could not read status" }
        return
    }
    Write-Host "S: OpenSSH not found. Installing via pinned MSI (preferred)..."
    if ($DryRun) {
        Write-Host "L: [DRYNUM] Would download and install OpenSSH MSI from pinned URL"
        Write-Host "L: [DRYNUM] Would verify SHA256: ddec9c53864280759cf9f74791cefd387100e3946aa849a1c138a4ed1b96b7d9"
        return
    }
    $msiUrl = 'https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-Win64-v10.0.0.0.msi'
    $msiSha = 'ddec9c53864280759cf9f74791cefd387100e3946aa849a1c138a4ed1b96b7d9'
    $msiP = "$env:TEMP\OpenSSH-Win64.msi"
    Write-Host "L: Downloading OpenSSH MSI from pinned source..."
    try {
        $wc = New-Object Net.WebClient
        $wc.DownloadFile($msiUrl, $msiP)
        $compSha = (Get-FileHash -Path $msiP -Algorithm SHA256).Hash
        if ($compSha -ne $msiSha) {
            Write-E "SHA256 verification FAILED."
            Write-Host "W: Expected: $msiSha"
            Write-Host "W: Got: $compSha"
            $ws = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
            if ($ws) { & $ws install Microsoft.OpenSSH.Preview -scope Machine -silent --acceptPackageAgreements --acceptSourceAgreements 2>&1 | Out-Null }
            else { Handle-Exit 1 "No OpenSSH available and no winget source." }
        } else {
            Write-L "MSI downloaded and SHA256 verified successfully."
            & msiexec /i "$msiP" /qn /norest 2>&1 | Out-Null
        }
    } catch {
        Write-E "Failed to download MSI: $($_.Exception.Message)"
        Write-Host "S: Trying winget fallback..."
        $ws = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
        if ($ws) { & $ws install Microsoft.OpenSSH.Preview -scope Machine -silent --acceptPackageAgreements --acceptSourceAgreements 2>&1 | Out-Null }
        else { Handle-Exit 1 "CRITICAL: Cannot install OpenSSH. No MSI, no winget, no capability." }
    }
}

# ==============================================================================
#  GIT INSTALLATION
# ==============================================================================

function Install-GitFS {
    Write-Host "S: Checking Git for Windows (needed for Git Bash as default shell)..."
    $bp = 'C:\Program Files\Git\bin\bash.exe'
    if (Test-Path $bp) {
        Write-Host "L: Git for Windows already installed at $bp"
        return
    }
    if ($SkipGit) {
        Write-Host "W: Skipping Git installation per -SkipGit flag."
        Write-Host "W: DefaultShell will fall back to PowerShell."
        return
    }
    if ($DryRun) { Write-Host "L: [DRYNUM] Would install Git for Windows via winget"; return }
    Write-Host "S: Installing Git for Windows via winget..."
    $ws = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
    if (-not $ws) { Write-E "winget.exe not found. Cannot install Git for Windows."; Write-Host "W: DefaultShell will fall back to PowerShell."; return }
    try { & $ws install Git.Git -exact -scope Machine -silent --acceptPackageAgreements --acceptSourceAgreements 2>&1 | Out-Null; Start-Sleep -Seconds 5
    if (Test-Path $bp) { Write-Host "L: Git for Windows installed successfully at $bp" }
    else { Write-Host "W: Git install may have completed, but bash.exe not found. DefaultShell will fall back to PowerShell." }
    } catch { Write-E "Git installation failed: $($_.Exception.Message)"; Write-Host "W: DefaultShell will fall back to PowerShell." }
}

# ==============================================================================
#  DEFAULT SHELL CONFIGURATION
# ==============================================================================

function Config-DefaultShell {
    Write-Host "S: Configuring SSH default shell registry setting..."
    $regP = 'HKLM:\SOFTWARE\OpenSSH'
    $bashP = 'C:\Program Files\Git\bin\bash.exe'
    $psP = '$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $bashP)) {
        if (-not $SkipGit) {
            Write-Host "W: Git bash.exe not found at $bashP."
            Write-Host "W: Attempting to install Git for Windows..."
            Install-GitFS
        } else { Write-Host "W: Git installation skipped per -SkipGit flag." }
    }
    if (Test-Path $bashP) {
        try {
            New-Item -Path $regP -Force | Out-Null
            New-ItemProperty -Path $regP -Name DefaultShell -Value $bashP -PropertyType String -Force | Out-Null
            $av = (Get-ItemProperty -Path $regP -Name DefaultShell).DefaultShell
            Write-Host "L: DefaultShell set to: $av (Git Bash)"
        } catch {
            Write-E "Failed to set registry key at $regP"
            Write-Host "W: Attempting fallback to PowerShell..."
            try {
                New-ItemProperty -Path $regP -Name DefaultShell -Value $psP -PropertyType String -Force | Out-Null
                $av = (Get-ItemProperty -Path $regP -Name DefaultShell).DefaultShell
                Write-Host "L: DefaultShell set to (fallback): $av (PowerShell)"
            } catch { Write-E "Failed to set any DefaultShell registry value." }
        }
    } else {
        try {
            New-Item -Path $regP -Force | Out-Null
            New-ItemProperty -Path $regP -Name DefaultShell -Value $psP -PropertyType String -Force | Out-Null
            $av = (Get-ItemProperty -Path $regP -Name DefaultShell).DefaultShell
            Write-Host "L: DefaultShell set to (fallback): $av (PowerShell)"
        } catch { Write-E "Failed to set DefaultShell registry value." }
    }
}

# ==============================================================================
#  SSHD CONFIGURATION
# ==============================================================================

function Config-SshdConf {
    $cp = 'C:\ProgramData\ssh\sshd_config'
    Write-Host "S: Configuring sshd_server settings..."
    if ($DryRun) {
        Write-Host "L: [DRYNUM] Would configure $cp"
        Write-Host "L: [DRYNUM] Would set: PubkeyAuthentication yes"
        $paD = Get-PassDisplay
        Write-Host "L: [DRYNUM] Would set PasswordAuthentication: $paD"
        Write-Host "L: [DRYNUM] Would ensure PermitRootLogin prohibit-password"
        return
    }
    if (-not (Test-Path $cp)) {
        Write-E "sshd_config not found at $cp. Creating minimal default."
        $minC = "# OpenSSH server system-wide configuration file`n#"
        Set-Content -Path $cp -Value $minC -Encoding UTF8 -Force
    }
    $c = Get-Content -Path $cp -Raw
    $mp = $c.IndexOf("Match Group administrators")
    if ($mp -ge 0) {
        $bm = $c.Substring(0, $mp)
        $am = $c.Substring($mp)
        # PubkeyAuthentication yes globally
        $npb = $bm -replace '^\s*#\s*PubkeyAuthentication\s+yes\s*$', 'PubkeyAuthentication yes'
        $npb = $npb -replace '^\s*#\s*PubkeyAuthentication\s+no\s*$', 'PubkeyAuthentication yes'
        # PasswordAuthentication based on flag
        if ($DisablePasswordAuth) {
            $np = $npb -replace '^\s*#\s*PasswordAuthentication\s+yes\s*$', 'PasswordAuthentication no'
            $np = $np -replace '^\s*PasswordAuthentication\s+yes\s*$', 'PasswordAuthentication no'
            Write-Host "L: PasswordAuthentication set to: no (per -DisablePasswordAuth)"
        } else {
            $np = $npb -replace '^\s*#\s*PasswordAuthentication\s+no\s*$', 'PasswordAuthentication yes'
            $np = $np -replace '^\s*PasswordAuthentication\s+no\s*$', 'PasswordAuthentication yes'
            Write-Host "L: PasswordAuthentication set to: yes (default)"
        }
        # PermitRootLogin prohibit-password
        $nr = $np -replace '^\s*#\s*PermitRootLogin\s+prohibit-password\s*$', 'PermitRootLogin prohibit-password'
        $nr = $nr -replace '^\s*#\s*PermitRootLogin\s+no\s*$', 'PermitRootLogin prohibit-password'
        # AuthorizedKeysFile in Match block
        $na = $am
        if ($na -notmatch '__PROGRAMDATA__') {
            $na = $na -replace 'AuthorizedKeysFile\s+\.ssh/authorized_keys', 'AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys'
        }
        $fc = "$nr`n$na"
        try {
            Set-Content -Path $cp -Value $fc -Encoding UTF8 -Force
            Write-Host "L: sshd_config updated successfully"
        } catch {
            Write-E "Failed to write sshd_config"
            if (Test-Path "$cp.bak") { Copy-Item -Path "$cp.bak" -Destination $cp -Force }
        }
    } else {
        Write-E "Could not find 'Match Group administrators' block in sshd_config."
        Write-Host "W: The config may have a different structure. Please review $cp manually."
    }
}

# ==============================================================================
#  FIREWALL CONFIGURATION
# ==============================================================================

function Config-Firewall {
    Write-Host "S: Configuring Windows Firewall rules for SSH access..."
    function Get-LCidr {
        $rt = Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Where-Object { $_.NextHop -ne "0.0.0.0" } | Sort-Object -Property Metric | Select-Object -First 1
        if ($rt) { $ip = $rt.NextHop; $parts = $ip -split "."; if ($parts.Count -ge 3) { return "$($parts[0]).$($parts[1]).$($parts[2]).0/24" } }
        return "10.0.0.0/24"
    }
    $lcidr = Get-LCidr
    Write-Host "S: Detected LAN CIDR: $lcidr"
    if ($DryRun) {
        Write-Host "L: [DRYNUM] Would disable over-broad vendor SSH rules"
        Write-Host "L: [DRYNUM] Would create inbound rule: OpenSSH Server (Local subnet $lcidr)"
        Write-Host "L: [DRYNUM] Would create inbound rule: OpenSSH over Tailscale (100.64.0.0/10)"
        $obD = Get-ObDisplay
        Write-Host "L: [DRYNUM] Would $obD outbound SSH to tailnet (100.64.0.0/10)"
        return
    }
    # Disable over-broad vendor rules
    $rtd = @("OpenSSH SSH Server (sshd)", "OpenSSH SSH Server Preview (sshd)")
    foreach ($n in $rtd) {
        $r = Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue
        if ($r) { try { $r | Disable-NetFirewallRule } catch { Write-Host "W: Could not disable rule: $n" } }
    }
    # LAN-scoped inbound rule
    $lanRN = "OpenSSH Server (Local subnet $lcidr)"
    $elr = Get-NetFirewallRule -DisplayName $lanRN -ErrorAction SilentlyContinue
    if (-not $elr) {
        Write-Host "L: Creating inbound SSH rule for LAN: $lcidr"
        try {
            New-NetFirewallRule -DisplayName $lanRN -Direction Inbound -Protocol TCP -LocalPort 22 -RemoteAddress $lcidr -Action Allow -Enabled True -Profile Private | Out-NulL
            Write-Host "L: LAN SSH inbound rule created."
        } catch { Write-E "Failed to create LAN inbound SSH rule." }
    } else {
        Write-Host "L: LAN SSH inbound rule already exists: $lanRN"
        try { Set-NetFirewallRule -DisplayName $lanRN -RemoteAddress $lcidr -Enabled True } catch { Write-Host "W: Could not update LAN rule remote address." }
    }
    # Tailscale inbound rule
    $tsRN = "OpenSSH over Tailscale (100.64.0.0/10)"
    $etr = Get-NetFirewallRule -DisplayName $tsRN -ErrorAction SilentlyContinue
    if (-not $etr) {
        Write-Host "L: Creating inbound SSH rule for Tailscale network."
        try {
            New-NetFirewallRule -DisplayName $tsRN -Direction Inbound -Protocol TCP -LocalPort 22 -RemoteAddress 100.64.0.0/10,fd7a:115c:a1e0::/48 -Action Allow -Enabled True -Profile Any | Out-NulL
            Write-Host "L: Tailscale SSH inbound rule created."
        } catch { Write-E "Failed to create Tailscale inbound SSH rule." }
    } else {
        Write-Host "L: Tailscale SSH inbound rule already exists: $tsRN"
        try { Set-NetFirewallRule -DisplayName $tsRN -RemoteAddress 100.64.0.0/10,fd7a:115c:a1e0::/48 -Enabled True } catch { Write-Host "W: Could not update Tailscale rule." }
    }
    # Outbound SSH block or allow
    $brn = "Block outbound SSH to tailnet"
    $ebr = Get-NetFirewallRule -DisplayName $brn -ErrorAction SilentlyContinue
    if (-not $AllowOutboundSSH) {
        if (-not $ebr) {
            Write-Host "L: Creating outbound block rule for SSH to tailnet."
            try {
                New-NetFirewallRule -DisplayName $brn -Direction Outbound -Protocol TCP -RemotePort 22 -RemoteAddress 100.64.0.0/10 -Action Block -Enabled True -Profile Any | Out-NulL
                Write-Host "L: Outbound SSH block rule created."
            } catch { Write-E "Failed to create outbound SSH block rule." }
        } else {
            Write-Host "L: Outbound SSH block rule already exists."
            try { Set-NetFirewallRule -DisplayName $brn -RemoteAddress 100.64.0.0/10 -Enabled True } catch { Write-Host "W: Could not update outbound block rule." }
        }
    } else {
        Write-Host "L: Outbound SSH allowed (per -AllowOutboundSSH option)."
        $ebr | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
#  AUTHORIZED KEYS SETUP
# ==============================================================================

function Config-AuthorizedKeys {
    Write-Host "S: Configuring authorized keys for Admin access..."
    $pkp = "C:\ProgramData\ssh\administrators_authorized_keys"
    $usd = "C:\Users\Admin\.ssh"
    if ($DryRun) {
        Write-Host "L: [DRYNUM] Would set up authorized keys at $pkp"
        Write-Host "L: [DRYNUM] Would ensure .ssh directory exists at $usd"
        return
    }
    if (-not (Test-Path $pkp)) {
        try {
            New-Item -Path "$pkp" -ItemType File -Force | Out-Null
            Set-Content -Path $pkp -Value "" -Encoding UTF8
            Write-Host "L: Created empty authorized keys target: $pkp"
        } catch { Write-E "Could not create authorized keys file at $pkp" }
    } else { Write-Host "L: Existing authorized keys found at: $pkp" }
    if ($TailscaleAuthKey) {
        if (Test-Path $TailscaleAuthKey) {
            try { Copy-Item -Path $TailscaleAuthKey -Destination $pkp -Force; Write-Host "L: Tailscale auth key imported from: $TailscaleAuthKey" }
            catch { Write-E "Failed to copy Tailscale auth key: $($_.Exception.Message)" }
        } else {
            try { Set-Content -Path $pkp -Value $TailscaleAuthKey -Encoding UTF8; Write-Host "L: Tailscale auth key content written to: $pkp" }
            catch { Write-E "Failed to write Tailscale auth key content: $($_.Exception.Message)" }
        }
    }
    if (-not (Test-Path $usd)) {
        try { New-Item -Path $usd -ItemType Directory -Force | Out-Null; Write-Host "L: Created .ssh directory: $usd" }
        catch { Write-E "Could not create .ssh directory: $($_.Exception.Message)" }
    }
    Write-Host "S: Authorized keys configuration complete."
    Write-Host "L: Admin key target: $pkp"
    Write-Host "L: User key directory: $usd"
    Write-Host "W: IMPORTANT: Add your SSH public key to one of the above locations to enable key-based auth."
}

# ==============================================================================
#  SCHEDULED TASK SETUP
# ==============================================================================

function Config-Stask {
    Write-Host "S: Configuring SYSTEM scheduled task for SSH self-heal..."
    if ($DryRun) {
        Write-Host "L: [DRYNUM] Would register scheduled task: OpenSSH sshd ensure-start"
        Write-Host "L: [DRYNUM] Trigger: At boot + repeat every 5 minutes"
        return
    }
    try {
        $ac = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"C:\ProgramData\ssh\ensure-sshd.ps1`""
        $tgb = New-ScheduledTaskTrigger -AtStartup
        $tgr = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
        $tgb.Repetition = $tgr.Repetition
        $prn = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $ss = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName "OpenSSH sshd ensure-start" -Action $ac -Trigger @($tgb) -Principal $prn -Settings $ss -Force | Out-NulL
        Write-Host "L: Scheduled task registered: OpenSSH sshd ensure-start"
        Write-Host "L:  Trigger: At system boot + every 5 minutes"
        Write-Host "L:  Principal: LOCAL SYSTEM with highest privileges"
        $vf = Get-ScheduledTask -TaskName "OpenSSH sshd ensure-start" -ErrorAction SilentlyContinue
        if ($vf) { Write-Host "L: Verification: Scheduled task found and active." }
        else { Write-Host "W: Scheduled task may not have registered correctly. Check execution policy and permissions." }
    } catch {
        Write-E "Failed to register scheduled task: $($_.Exception.Message)"
        Write-Host "W: The ensure-sshd.ps1 script will still exist at C:\ProgramData\ssh\ensure-sshd.ps1"
        Write-Host "W: You can run it manually or create the task manually via Task Scheduler."
    }
}

# ==============================================================================
#  SSH KEY GENERATION
# ==============================================================================

function Gen-SshKeys {
    Write-Host "S: Generating SSH host keys if needed..."
    $sdir = "C:\ProgramData\ssh"
    $rka = Join-Path $sdir "ssh_host_rsa_key"
    $edka = Join-Path $sdir "ssh_host_ed25519_key"
    if ($DryRun) { Write-Host "L: [DRYNUM] Would generate SSH host keys if missing"; return }
    $ng = $false
    if (-not (Test-Path $rka)) { $ng = $true; Write-Host "L: RSA key missing." }
    if (-not (Test-Path $edka)) { $ng = $true; Write-Host "L: ED25519 key missing." }
    if ($ng) {
        try { & "C:\Program Files\OpenSSH\ssh-keygen.exe" -A 2>$null; Write-Host "L: SSH host keys generated in $sdir" }
        catch { Write-E "SSH key generation failed: $($_.Exception.Message)" }
    } else { Write-Host "L: All SSH host keys already exist. Skipping generation." }
}

# ==============================================================================
#  MAIN EXECUTION FLOW
# ==============================================================================

function Main {
    Write-Host "L: ========================================"
    Write-Host "L:   Install-SSHD.ps1 - SSH Server Setup"
    Write-Host "L: ========================================"
    Write-Host "L: "

    if (-not (Test-Admin)) {
        Write-E "This script requires administrative privileges."
        Write-Host "W: Please right-click 'Setup-SSHD.cmd' and select 'Run as administrator',"
        Write-Host "W: or run: PowerShell -ExecutionPolicy Bypass -File Install-SSHD.ps1 as Administrator"
        $r = Read-Host
        Handle-Exit 1 "Setup terminated: insufficient privileges."
    }

    Validate-Opts

    if ($Uninstall) {
        Write-Host "L: === Uninstall mode selected ==="
        Write-Host "S: Removing SSH server setup..."
        Unregister-ScheduledTask -TaskName "OpenSSH sshd ensure-start" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "C:\ProgramData\ssh\ensure-sshd.ps1" -Force -ErrorAction SilentlyContinue
        Uninstall-Service sshd -ErrorAction SilentlyContinue
        Get-NetFirewallRule -DisplayName "OpenSSH Server*","OpenSSH over Tailscale","Block outbound SSH to tailnet" | ForEach-Object { Remove-NetFirewallRule -DisplayName $_.DisplayName -ErrorAction SilentlyContinue }
        if (Test-Path "C:\ProgramData\ssh\sshd_config.bak") {
            Copy-Item -Path "C:\ProgramData\ssh\sshd_config.bak" -Destination "C:\ProgramData\ssh\sshd_config" -Force
        }
        Handle-Exit 0 "Uninstall complete."
    }

    Write-Host "L: --- Phase 1: OpenSSH Installation ---"
    Install-OpenSSH

    Write-Host "L: --- Phase 2: Git for Windows & DefaultShell ---"
    Install-GitFS
    Config-DefaultShell

    Write-Host "L: --- Phase 3: sshd_config Configuration ---"
    Config-SshdConf

    Write-Host "L: --- Phase 4: Firewall Configuration ---"
    Config-Firewall

    Write-Host "L: --- Phase 5: Self-Heal Initialization ---"
    if ($DryRun) {
        Write-Host "L: [DRYNUM] Would write self-heal script to C:\ProgramData\ssh\ensure-sshd.ps1"
    } else {
        try {
            Set-Content -Path "C:\ProgramData\ssh\ensure-sshd.ps1" -Value $EnsureSshdContent -Encoding ASCII -Force
            Write-Host "L: Self-heal script written to C:\ProgramData\ssh\ensure-sshd.ps1"
        } catch {
            Write-E "Failed to write self-heal script: $($_.Exception.Message)"
        }
    }

    Write-Host "L: --- Phase 6: Scheduled Task ---"
    Config-Stask

    Write-Host "L: --- Phase 7: SSH Keys ---"
    Gen-SshKeys

    Write-Host "L: --- Phase 8: Authorized Keys ---"
    Config-AuthorizedKeys

    Write-Host "L: --- Phase 9: Finalization ---"
    Write-Host "L: Restarting sshd service to apply changes..."
    try {
        Restart-Service sshd -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Host "L: sshd service restarted."
    } catch {
        Write-E "Could not restart sshd service automatically."
        Write-Host "W: The SYSTEM scheduled task (OpenSSH sshd ensure-start) will handle restarts at next boot + every 5 minutes."
    }

    Write-Host "L: "
    Write-Host "L: ========================================"
    Write-Host "L:   Setup Complete!"
    Write-Host "L: ========================================"
    Write-Host "L: "
    $ds = (Get-ItemProperty "HKLM:\SOFTWARE\OpenSSH" -ErrorAction SilentlyContinue).DefaultShell
    Write-Host "L: • OpenSSH SSH server (installed or verified)"
    Write-Host "L: • DefaultShell: $ds"
    Write-Host "L: • Firewall: LAN-scoped + Tailscale inbound rules"
    Write-Host "L: • Self-heal: SYSTEM task (boot + every 5 min)"
    Write-Host "L: • Authorized keys target: C:\ProgramData\ssh\administrators_authorized_keys"
    $paD = Get-PassDisplay
    Write-Host "L: • Password auth: $paD"
    $faD = Get-AdminDisplay
    Write-Host "L: • Full admin: $faD"
    $obD = Get-ObDisplay
    Write-Host "L: • Outbound SSH block: $obD"
    Write-Host "L: "
    Write-Host "L: NEXT STEPS:"
    Write-Host "L:   1. Add your SSH public key to:"
    Write-Host "L:      C:\ProgramData\ssh\administrators_authorized_keys"
    Write-Host "L:      Or: C:\Users\Admin\.ssh\authorized_keys (for user-level access)"
    Write-Host "L:   2. Find host key fingerprints:"
    Write-Host "L:     ssh-keygen -lf C:\ProgramData\ssh\ssh_host_rsa_key.pub"
    Write-Host "L:     ssh-keygen -lf C:\ProgramData\ssh\ssh_host_ed25519_key.pub"
    Write-Host "L:   3. Connect via SSH:"
    Write-Host "L:     ssh -i C:\\Users\\YOURKEY\\.ssh\\id_ed25519 Admin@<this-pc-IP-or-Tailscale-IP>"
    Write-Host "L:     ssh -i ~/.ssh/id_ed25519 Admin@desktop-45jskiv.tail12e076.ts.net (if Tailscale)"
    Write-Host "L: "
    if ($PauseOnExit) {
        Write-Host "S: Press Enter to exit setup."
        $r = Read-Host
    }
    Write-Host "L: Setup process finished."
    exit 0
}

Main