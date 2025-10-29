````markdown
# netplan-cli

A lightweight, IPv4-only CLI and interactive tool for configuring static network interfaces on Ubuntu Server using **Netplan**.

---

## Overview

`netplan-cli` provides a reliable and scriptable way to configure static IP addressing without manually editing YAML files under `/etc/netplan/`.  
It supports both interactive and automated (non-interactive) execution, performing full input validation and automatic YAML generation.

---

## Key Features

- IPv4-only configuration (CIDR notation, e.g. `192.168.100.10/24`)
- Gateway validation (must belong to the same subnet as the interface)
- DNS address validation (IPv4 format)
- Automatic interface detection, including VLANs and bonded interfaces
- Automatic backup of existing Netplan YAML files
- Non-interactive CLI parameters for automation and scripting
- `--dry-run` mode for YAML generation without changes
- `--validate-only` mode for syntax validation using `netplan generate`
- Pure Bash implementation — requires only `bash`, `iproute2`, and `netplan.io`

---

## Installation

```bash
git clone https://github.com/<your-username>/netplan-cli.git
cd netplan-cli
chmod +x netplan.sh
````

---

## Usage

### Interactive mode

Run the tool without parameters to enter guided configuration:

```bash
sudo ./netplan.sh
```

You will be prompted to define:

* Interface name
* IPv4 address (CIDR notation)
* Default gateway
* Primary and optional secondary DNS servers

All input is validated before being written to `/etc/netplan/`.

---

### Non-interactive mode

For automation or scripting, use command-line parameters:

```bash
sudo ./netplan.sh \
  --iface ens3 \
  --ip 192.168.100.10/24 \
  --gw 192.168.100.1 \
  --dns 1.1.1.1,8.8.8.8
```

---

### Dry-run

Generates and prints the resulting YAML without writing or applying changes:

```bash
sudo ./netplan.sh \
  --iface ens3 \
  --ip 192.168.100.10/24 \
  --gw 192.168.100.1 \
  --dns 1.1.1.1 \
  --dry-run
```

---

### Validate-only

Validates syntax and structure with `netplan generate`, without applying the configuration:

```bash
sudo ./netplan.sh \
  --iface ens3 \
  --ip 192.168.100.10/24 \
  --gw 192.168.100.1 \
  --dns 1.1.1.1 \
  --validate-only
```

---

### Display all interfaces

Show all detected network interfaces, including virtual and tunnel types:

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

## Requirements

* Ubuntu Server 18.04 or newer
* `bash`, `iproute2`, and `netplan.io` installed
* Root privileges (use `sudo`)

---

## License

Released under the MIT License.
