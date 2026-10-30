# Windows SSH Server Setup Kit

Portable, idempotent installer that automates the full SSH server setup on Windows 10/11.
Designed to be "just install it and run" on other devices.

## Contents

| File | Purpose |
|------|---------|
| `Install-SSHD.ps1` | Main PowerShell installer script |
| `Setup-SSHD.cmd` | Double-click launcher (admin required) |
| `Uninstall-SSHD.cmd` | Double-click uninstall launcher |
| `README.md` | This file |

## Quick Start

### On a new device:

1. **Run as Administrator**: Double-click `Setup-SSHD.cmd` or right-click and select "Run as administrator"

2. **Or via PowerShell** (if you prefer custom options):
   ```powershell
   PowerShell -ExecutionPolicy Bypass -File Install-SSHD.ps1 [options]
   ```

3. **Default behavior** (with `-NoFullAdmin`):
   - Installs OpenSSH (via pinned MSI, then winget, then capability)
   - Installs Git for Windows and sets `DefaultShell` to `C:\Program Files\Git\bin\bash.exe`
   - Configures `sshd_config` with `PubkeyAuthentication yes`, `PasswordAuthentication yes`, `PermitRootLogin prohibit-password`
   - Inserts directives **before** the `Match Group administrators` block
   - Sets up LAN-scoped and Tailscale inbound firewall rules
   - Optionally blocks outbound SSH to tailnet
   - Creates `ensure-sshd.ps1` self-heal script and `OpenSSH sshd ensure-start` SYSTEM scheduled task
   - Sets up authorized keys target at `__PROGRAMDATA__/ssh/administrators_authorized_keys`

## Installation Options

| Option | Description |
|--------|-------------|
| `-DryRun` | Show what would be done without making changes |
| `-Uninstall` | Remove the SSH server setup (reverse all changes) |
| `-GenerateKey` | Generate new SSH host keys |
| `-PublicKey <path>` | Extract/public key handling (deprecated, use `-PublicKeyPath` instead) |
| `-PublicKeyPath <path>` | Path to save/write the public key |
| `-DisablePasswordAuth` | **Disable** password authentication (recommended: key-only auth) |
| `-SkipGit` | Skip Git for Windows installation (use existing PowerShell shell) |
| `-SkipTailscale` | Skip Tailscale firewall rule creation |
| `-TailscaleAuthKey <path|string>` | Import a Tailscale auth key into the administrators_authorized_keys file |
| `-AllowOutboundSSH` | Allow outbound TCP/22 connections to tailnet peers (blocked by default) |
| `-NoFullAdmin` | **Do not** set full admin over SSH (sets up key auth + restricted privileges only) |
| `-SkipFirewall` | Skip firewall rule creation (use existing network configuration) |
| `-Force` | Skip confirmation prompts and override existing configurations |
| `-PauseOnExit` | Keep console open after completion (default) |

## Security Notes

- **Password auth vs Key auth**: By default, password authentication is **enabled** (`-DisablePasswordAuth` to disable). The prior setup accepted the tradeoff of password + full admin for convenience. For better security, use `-DisablePasswordAuth` which requires SSH keys.
- **Full admin access**: By default, the setup provides restricted admin access via the `Match Group administrators` block in `sshd_config`. Use `-NoFullAdmin` to disable the administrators group match block and run with minimal privileges.
- **Outbound SSH blocked**: Outbound TCP/22 to tailnet (`100.64.0.0/10`) is blocked by default to prevent accidental connections to other tailnet peers. Use `-AllowOutboundSSH` to permit.
- **Firewall scope**: Inbound rules are scoped to:
  - LAN CIDR (auto-detected via default route, typically `10.120.0.0/20` or similar)
  - Tailscale network (`100.64.0.0/10` and `fd7a:115c:a1e0::/48`)
- **Self-healing**: A SYSTEM scheduled task runs `ensure-sshd.ps1` at boot and every 5 minutes to repair and restart the sshd service.
- **Default shell**: Git Bash is set as the default SSH shell. PowerShell is used as fallback if Git is not available.

## Connection Commands

### Connect with SSH client:

```powershell
# Using Git Bash:
ssh -i ~/.ssh/id_ed25519 Admin@desktop-45jskiv.tail12e076.ts.net

# Or using PowerShell:
ssh -i C:\Users\Admin\.ssh\id_ed25519 Admin@desktop-45jskiv.tail12e076.ts.net
```

### Find the SSH host key fingerprint:

```powershell
cd C:\ProgramData\ssh
ssh-keygen -lf ssh_host_rsa_key.pub
ssh-keygen -lf ssh_host_ed25519_key.pub
```

### Transfer your personal key for admin access:

```powershell
:: Copy your public key to the admin authorized keys target:
copy C:\Users\Admin\.ssh\id_ed25519.pub "C:\ProgramData\ssh\administrators_authorized_keys"

:: Or via PowerShell:
Add-Content -Path "C:\ProgramData\ssh\administrators_authorized_keys" -Value "$(Get-Content C:\Users\Admin\.ssh\id_ed25519.pub)"

:: Then reload sshd:
Restart-Service sshd
```

## Troubleshooting

### sshd won't start

1. Check the event log: `Get-EventLog -LogName Application -Source SSHD`
2. Check the heal log: `Get-Content C:\ProgramData\ssh\ensure-sshd.log -Tail 20`
3. Verify config: `Test-SSHDConfig -Path C:\ProgramData\ssh\sshd_config`

### Key authentication not working

1. Verify the key is in `C:\ProgramData\ssh\administrators_authorized_keys`
2. Ensure `LocalAccountTokenFilterPolicy=1` is set (already present on this OS)
3. Verify `PubkeyAuthentication yes` is in sshd_config
4. Check that the Admin account is not locked out

### Firewall rules not appearing

1. Verify inbound rules: `Get-NetFirewallRule -DisplayName 'OpenSSH*'`
2. Check that the LAN CIDR is correct (run `ipconfig` and check the default gateway)
3. Ensure PowerShell is run as Administrator

### Reboot required

The `OpenSSH.Server` capability may show `InstallPending` with a `RebootPending` flag. Reboot the machine after initial setup.

## Generated Files

The installer creates/updates these files on the target machine:

- `C:\ProgramData\ssh\sshd_config` - OpenSSH server configuration
- `C:\ProgramData\ssh\ensure-sshd.ps1` - Self-heal/heartbeat script
- `C:\ProgramData\ssh\ensure-sshd.log` - Heartbeat log (last 200 lines kept)
- `C:\ProgramData\ssh\administrators_authorized_keys` - Admin authorized keys target
- `HKLM:\SOFTWARE\OpenSSH\DefaultShell` - Default SSH shell registry key
- Scheduled task: `OpenSSH sshd ensure-start` (SYSTEM account, at boot + every 5 min)
- Firewall rules for LAN and Tailscale scoped SSH access

## Packaging

The complete kit can be ZIP'd and delivered to other devices. The Desktop folder contains all required files:

```
C:\Users\Admin\Desktop\Windows-SSH-Setup-Kit\
├── Install-SSHD.ps1
├── Setup-SSHD.cmd
├── Uninstall-SSHD.cmd
└── README.md
```