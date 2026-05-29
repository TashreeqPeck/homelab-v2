# Getting Started
Bootstrap in this repository runs a Windows-native TinyPXE workflow for PXE-installing Proxmox VE.

## Configure the metal
1. Ensure that the device you want to install proxmox ve has network boot as the first option
2. Turn off secure boot
3. Connect the target to the network you are serving PXE on

**Note**: The installer disk target is controlled by filters in [answer.toml](answer.toml). Review `disk-setup` carefully before unattended installs.

## Configure bootstrap machine (Windows)
1. Install and set up wsl.
```
wsl --install -d Debian
```
2. Edit your wsl file (located at `%USERPROFILE%/.wslconfig`) and ensure it has the following:
```
[wsl2]
networkingMode=mirrored
```
3. Restart WSL after changing `.wslconfig`:
```
wsl --shutdown
```
4. Install bootstrap dependencies from PowerShell with [00-install-dependencies.ps1](00-install-dependencies.ps1). This installs Linux dependencies in WSL and the 1Password CLI on Windows if needed.
```
./00-bootstrap/00-install-dependencies.ps1
```

## Configure secrets
Secret management is done using 1Password. This project assumes that you add all the secrets for this project into the "Homelab" vault. Ensure that the names in 1Password matches the names specified by the project.

**Ensure you are signed in to the 1Password CLI. See the [docs](https://www.1password.dev/cli/get-started#windows-2).**

**Note**: To use different names from 1Password change the corresponding secret references.

|Name|Use|
|-|-|
|Proxmox root| The password for the proxmox root user|


## Bootstrap PXE install with Windows
1. Verify the Proxmox ISO exists inside [99-image](../99-image).
2. Create or edit `00-bootstrap/answer.toml`.
3. Start the Windows/TinyPXE workflow from PowerShell:
```
./00-bootstrap/01-start-pxe-server.ps1
```
4. Stop the workflow by stopping and closing TinyPXE when finished.
