# netplan-cli

A minimal, IPv4-only CLI and interactive utility for configuring static network interfaces on **Ubuntu Server** using **Netplan**.

This repository contains a single Bash script:

- **netplan.sh** – Provides both interactive and non-interactive modes to generate and apply Netplan YAML configurations with input validation and automatic backups.

---

## Description

- **netplan.sh**:
  - Configures static IPv4 addresses using CIDR notation (e.g. `192.168.100.10/24`).
  - Validates gateway and DNS addresses.
  - Automatically detects available interfaces, including VLANs and bonded interfaces.
  - Creates a backup of any existing Netplan YAML file before writing.
  - Supports both interactive and automated (non-interactive) execution.
  - Provides `--dry-run` and `--validate-only` modes for safe testing.

---

## Features

- IPv4-only configuration with CIDR notation  
- Gateway validation (must be in same subnet)  
- DNS address validation (IPv4 format)  
- Automatic interface detection (physical, VLAN, bond, tunnel)  
- Interactive guided mode  
- Non-interactive CLI mode for automation  
- `--dry-run` mode for YAML preview  
- `--validate-only` mode using `netplan generate`  
- Automatic YAML backup before modification  
- Pure Bash — no external dependencies beyond core system tools  

---

## Requirements

- Ubuntu Server 18.04 or newer  
- `bash`, `iproute2`, and `netplan.io` installed  
- Root privileges (`sudo`)  

---

## Setup

1. Clone this repository:

   ```bash
   git clone https://github.com/<your-username>/netplan-cli.git
   cd netplan-cli
   ```

2. Make the script executable:

   ```bash
   chmod +x netplan.sh
   ```

---

## Usage

### 1. Interactive mode

Run the script without parameters to enter guided configuration:

```bash
sudo ./netplan.sh
```

You will be prompted for:

- Interface name  
- IPv4 address (CIDR notation)  
- Default gateway  
- Primary and secondary DNS servers  

All inputs are validated before the YAML file is written to `/etc/netplan/`.

---

### 2. Non-interactive mode

Use parameters for automation or scripting:

```bash
sudo ./netplan.sh \
  --iface ens3 \
  --ip 192.168.100.10/24 \
  --gw 192.168.100.1 \
  --dns 1.1.1.1,8.8.8.8
```

---

### 3. Dry-run

Generates and prints the YAML file without writing or applying it:

```bash
sudo ./netplan.sh \
  --iface ens3 \
  --ip 192.168.100.10/24 \
  --gw 192.168.100.1 \
  --dns 1.1.1.1 \
  --dry-run
```

---

### 4. Validate-only

Validates syntax and structure using `netplan generate`, without applying the configuration:

```bash
sudo ./netplan.sh \
  --iface ens3 \
  --ip 192.168.100.10/24 \
  --gw 192.168.100.1 \
  --dns 1.1.1.1 \
  --validate-only
```

---

### 5. Show all interfaces

Displays all detected network interfaces, including virtual and tunnel types:

```bash
sudo ./netplan.sh --show-all-ifaces
```

---

## Example Output

```
============= CONFIGURATION PREVIEW =============
Netplan file: /etc/netplan/50-cloud-init.yaml
Interface   : ens3
IPv4        : 192.168.100.10/24
Gateway     : 192.168.100.1
DNS         : 1.1.1.1, 8.8.8.8
=================================================

Apply these settings? [y/N]: y

Interface status for ens3:
inet 192.168.100.10/24 brd 192.168.100.255 scope global ens3
Route to 1.1.1.1:
1.1.1.1 via 192.168.100.1 dev ens3 src 192.168.100.10

Done: interface ens3 configured with IP 192.168.100.10/24 and gateway 192.168.100.1.
YAML saved at: /etc/netplan/50-cloud-init.yaml (backup created if file existed).
```

---

## Disclaimer

This is an unofficial script and is not affiliated with or supported by Canonical Ltd.
