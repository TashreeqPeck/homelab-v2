The following are the tools used to develop this server and their versions at the time of development.

## Environment
| Tool Name | Tool Version |
| - | - |
| wsl | 20.0.14.0 |
| wsl kernel | 5.15.133.1-1 |
| windows | 10.0.26200.8524 |
| wsl distro | Debian 13 (trixie) |
| debian full version | 13.5 |

## Core WSL Tooling
| Tool Name | Tool Version |
| - | - |
| proxmox-auto-install-assistant | proxmox-installer-common v9.2.5 |

## Bootstrap-Installed Packages
These packages are installed by [90-bootstrap-scripts/bootstrap/install-dependencies.sh](90-bootstrap-scripts/bootstrap/install-dependencies.sh).

| Package | Version Available During Development |
| - | - |
| xorriso | 1.5.6 |
| dnsmasq | 2.91 |
| ipxe package | 1.21.1+git20250501.dad20602+dfsg-1 |
| zstd | 1.5.7 |
| cpio | 2.15 |
| pv | 1.9.31 |
| python3 | 3.13.5 |

## Proxmox VE
The image deployed was version 9.2-1

## Notes
- Target platform is Debian WSL only.
- Version-sensitive behavior should be validated primarily against Debian 13 (trixie).
- The ipxe package is installed and used for artifacts; a standalone ipxe command is not present in PATH in this environment.