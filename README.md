# netplan-cli

A minimal, IPv4-only CLI and interactive utility for configuring network interfaces on **Ubuntu Server** using **Netplan**.

This repository contains a single Bash script:

- **netplan.sh** – Provides both interactive and non-interactive modes to generate and apply Netplan YAML configurations with input validation and automatic backups.

---

## Description

- **netplan.sh**:
  - Configures static IPv4 addresses using CIDR notation (e.g. `192.168.100.10/24`).
  - **Supports enabling DHCPv4 mode (`--dhcp4`) with optional DNS override**
  - Validates gateway and DNS addresses.
  - Automatically detects available interfaces, including VLANs and bonded interfaces.
  - Creates a backup of any existing Netplan YAML file before writing.
  - Supports both interactive and automated (non-interactive) execution.
  - Provides `--dry-run` and `--validate-only` modes for safe testing.

---

## Features

- IPv4-only configuration with CIDR notation  
- **Static or DHCPv4 mode**
- Gateway validation (must be in same subnet)  
- DNS address validation (IPv4 format)  
- Automatic interface detection (physical, VLAN, bond, tunnel)  
- Interactive guided mode (static only)  
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

### 1. Interactive mode (static only)

```bash
sudo ./netplan.sh
```

Prompts for:

- Interface name  
- IPv4 address (CIDR notation)  
- Default gateway  
- Primary and secondary DNS servers  

All inputs are validated before the YAML file is written to `/etc/netplan/`.

---

### 2. Static IPv4 (non-interactive)

```bash
sudo ./netplan.sh \
  --iface ens3 \
  --ip 192.168.100.10/24 \
  --gw 192.168.100.1 \
  --dns 1.1.1.1,8.8.8.8
```

---

### 3. DHCPv4 mode

Enable DHCP:

```bash
sudo ./netplan.sh --iface ens3 --dhcp4
```

DHCP with DNS override:

```bash
sudo ./netplan.sh --iface ens3 --dhcp4 --dns 1.1.1.1,8.8.8.8
```

---

### 4. Dry-run

```bash
sudo ./netplan.sh --iface ens3 --dhcp4 --dry-run
```

---

### 5. Validate-only

```bash
sudo ./netplan.sh \
  --iface ens3 \
  --ip 192.168.100.10/24 \
  --gw 192.168.100.1 \
  --dns 1.1.1.1 \
  --validate-only
```

---

### 6. Show all interfaces

```bash
sudo ./netplan.sh --show-all-ifaces
```

---

## Example Output (static)

```
============= CONFIGURATION PREVIEW =============
Netplan file: /etc/netplan/50-cloud-init.yaml
Interface   : ens3
IPv4        : 192.168.100.10/24
Gateway     : 192.168.100.1
DNS         : 1.1.1.1, 8.8.8.8
=================================================
...
```

## Example Output (DHCP)

```
============= CONFIGURATION PREVIEW =============
Netplan file: /etc/netplan/01-netcfg.yaml
Interface   : ens3
Mode        : DHCPv4
DNS         : from DHCP lease
=================================================
...
```

---

## Disclaimer

This is an unofficial script and is not affiliated with or supported by Canonical Ltd.
