#!/usr/bin/env -S bash -euo pipefail

# Netplan CLI (non-interactive)
# -------------------------------------------------------------
# Purpose:
#   Generate and apply Netplan YAML for a single interface.
#   This tool is STRICTLY non-interactive. Running with no args prints help.
#
# Key features:
#   - IPv4 static OR DHCPv4 (mutually exclusive)
#   - Proper default route via "routes: to: default" (avoids legacy gateway4)
#   - VLAN-aware output (ens3.120 becomes a netplan vlans: block)
#   - DHCPv4 with optional DNS override
#   - Dry-run and validate-only modes
#
# Line endings:
#   Keep this file with LF line endings. In Git, enforce with .gitattributes:
#     *.sh text eol=lf
#
# Usage examples:
#   Static IPv4 on plain NIC:
#     sudo ./netplan.sh --static4 --iface ens3 --ip 10.120.80.10/27 --gw 10.120.80.1 --dns 1.1.1.1,8.8.8.8
#   Static IPv4 on VLAN:
#     sudo ./netplan.sh --static4 --iface ens3.120 --ip 10.120.80.10/27 --gw 10.120.80.1 --dns 1.1.1.1
#   DHCPv4 with DNS override:
#     sudo ./netplan.sh --dhcp4 --iface ens3 --dns 9.9.9.9,1.1.1.1
#   Just print YAML (no write/apply):
#     sudo ./netplan.sh --dhcp4 --iface ens3 --dry-run
#   Only validate the generated file:
#     sudo ./netplan.sh --static4 --iface ens3 --ip 192.168.0.10/24 --gw 192.168.0.1 --dns 1.1.1.1 --validate-only
#   List detected real interfaces (whitelist) and exit:
#     ./netplan.sh --list-ifaces
# -------------------------------------------------------------

# ------------- CLI STATE -------------
IFACE=""
IPV4_CIDR=""
GW4=""
DNS4=""
NETPLAN_FILE_ARG=""
DRY_RUN=0
VALIDATE_ONLY=0
DHCP4=0
STATIC4=0
LIST_IFACES_ONLY=0

# ------------- USAGE -------------
usage() {
  cat <<EOF
Usage: sudo $0 [MODE] [options]

Modes (pick exactly one):
  --dhcp4                  Enable DHCPv4 on the interface
  --static4                Enable static IPv4 mode (requires --ip, --gw, --dns)

Required:
  --iface IFACE            Interface name (e.g. ens3, enp0s3, bond0, ens3.120)

Static IPv4 options:
  --ip CIDR                IPv4/prefix (e.g. 192.168.10.5/24)
  --gw IPV4                Default IPv4 gateway
  --dns LIST               DNS IPv4 comma-separated (e.g. 1.1.1.1,8.8.8.8)

General options:
  --file PATH              Netplan YAML to write (default: auto-detect or /etc/netplan/01-netcfg.yaml)
  --dry-run                Print YAML to stdout only; do not write/apply
  --validate-only          Generate and validate netplan without applying
  --list-ifaces            Print detected real interfaces and exit
  -h, --help               This help

Notes:
  - --dhcp4 and --static4 are mutually exclusive.
  - In static mode, all of --ip, --gw, and --dns are required.
EOF
}

# Print help if no args at all
[[ $# -eq 0 ]] && { usage; exit 1; }

# Support positional mode for ergonomics: `dhcp4` or `static4` as first arg
case "${1:-}" in
  dhcp4) DHCP4=1; shift ;;
  static4) STATIC4=1; shift ;;
esac

# ------------- ARG PARSER -------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iface) IFACE="$2"; shift 2;;
    --ip) IPV4_CIDR="$2"; shift 2;;
    --gw) GW4="$2"; shift 2;;
    --dns) DNS4="$2"; shift 2;;
    --dhcp4) DHCP4=1; shift;;
    --static4) STATIC4=1; shift;;
    --file) NETPLAN_FILE_ARG="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --validate-only) VALIDATE_ONLY=1; shift;;
    --list-ifaces) LIST_IFACES_ONLY=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
done

# ------------- UTIL -------------
need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
  fi
}

is_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<<"$ip"
  for n in $a $b $c $d; do
    (( n>=0 && n<=255 )) || return 1
  done
  return 0
}

ip2int() { local a b c d; IFS='.' read -r a b c d <<<"$1"; echo $(( (a<<24) + (b<<16) + (c<<8) + d )); }
prefix2mask_int() { local p="$1"; echo $(( (p==0)?0: (0xFFFFFFFF << (32-p)) & 0xFFFFFFFF )); }

parse_ipv4_cidr() {
  local input="$1"
  [[ "$input" =~ ^([^/]+)/([0-9]{1,2})$ ]] || { echo "Invalid input. Use IP/prefix, e.g. 192.168.100.10/24" >&2; return 1; }
  local ip="${BASH_REMATCH[1]}" prefix="${BASH_REMATCH[2]}"
  is_ipv4 "$ip" || { echo "Invalid IPv4." >&2; return 1; }
  (( prefix>=1 && prefix<=32 )) || { echo "Invalid prefix (1..32)." >&2; return 1; }
  local ip_i mask_i net_i bcast_i
  ip_i="$(ip2int "$ip")"
  mask_i="$(prefix2mask_int "$prefix")"
  net_i=$(( ip_i & mask_i ))
  bcast_i=$(( net_i | (~mask_i & 0xFFFFFFFF) ))
  if (( ip_i==net_i || ip_i==bcast_i )); then
    echo "Host IPv4 cannot be network or broadcast for /$prefix." >&2
    return 1
  fi
  echo "$ip" "$prefix"
}

validate_gw4_in_subnet() {
  local ip="$1" prefix="$2" gw="$3"
  is_ipv4 "$gw" || { echo "Invalid IPv4 gateway." >&2; return 1; }
  local ip_i gw_i mask_i net_i bcast_i
  ip_i="$(ip2int "$ip")"; gw_i="$(ip2int "$gw")"; mask_i="$(prefix2mask_int "$prefix")"
  net_i=$(( ip_i & mask_i )); bcast_i=$(( net_i | (~mask_i & 0xFFFFFFFF) ))
  (( (gw_i & mask_i) == net_i )) || { echo "Gateway $gw is not in the same subnet as $ip/$prefix." >&2; return 1; }
  (( gw_i!=net_i && gw_i!=bcast_i && gw_i!=ip_i )) || { echo "Gateway cannot be network/broadcast/host IP." >&2; return 1; }
}

list_real_ifaces() {
  # Whitelist common NICs; allow VLAN suffix .ID; drop @peer suffix.
  mapfile -t all_ifaces < <(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | sort -u || true)
  local -a filtered=()
  local name base
  for name in "${all_ifaces[@]}"; do
    base="${name%%.*}"
    if [[ "$base" =~ ^(eth[0-9]+|en[a-z0-9-]*|ens[0-9]+|eno[0-9]+|enp[0-9s]+f?[0-9]*|enx[0-9a-f]+|bond[0-9]+|wl[a-z0-9]+|wlan[0-9]+)$ ]]; then
      filtered+=("$name")
    fi
  done
  if (( ${#filtered[@]} == 0 )); then
    # Fallback: blacklist container/tunnel noise
    mapfile -t filtered < <(printf "%s
" "${all_ifaces[@]}" |
      grep -Ev '^(lo|docker.*|veth.*|cni.*|flannel.*|wg.*|tailscale.*|vmnet.*|vnet.*|virbr.*|br-[0-9a-f]{12}|tun.*|tap.*|zt[a-z0-9]+.*)$' || true)
  fi
  printf "%s
" "${filtered[@]}"
}

apply_netplan() {
  netplan generate
  if (( VALIDATE_ONLY==1 )); then
    echo "Validation: 'netplan generate' succeeded."
    return
  fi
  netplan apply
}

build_dns_block() {
  local -a dns=("$@")
  [[ ${#dns[@]} -gt 0 ]] || return 0
  printf "      nameservers:
        addresses: [%s]
" "$(printf "%s," "${dns[@]}" | sed 's/,$//')"
}

is_vlan_iface() { [[ "$1" == *.* ]]; }
vlan_base() { echo "${1%%.*}"; }
vlan_id()   { echo "${1##*.}"; }

# ------------- MAIN -------------
main() {
  # Quick exits
  if (( LIST_IFACES_ONLY==1 )); then
    list_real_ifaces
    exit 0
  fi

  # Validate mode and required args
  if (( DHCP4==1 && STATIC4==1 )); then
    echo "Choose exactly one mode: --dhcp4 OR --static4." >&2; usage; exit 1
  fi
  if (( DHCP4==0 && STATIC4==0 )); then
    echo "Missing mode. Use --dhcp4 or --static4." >&2; usage; exit 1
  fi
  if [[ -z "$IFACE" ]]; then
    echo "Missing --iface." >&2; usage; exit 1
  fi

  if (( DHCP4==1 )); then
    # DHCP mode
    if [[ -n "$IPV4_CIDR$GW4" ]]; then
      echo "Options conflict: --dhcp4 cannot be used with --ip/--gw." >&2
      exit 1
    fi
    local -a dns_ary=()
    if [[ -n "$DNS4" ]]; then
      IFS=',' read -r -a dns_ary <<<"$DNS4"
      for d in "${dns_ary[@]}"; do is_ipv4 "$d" || { echo "Invalid DNS entry: $d" >&2; exit 1; }; done
    fi
    generate_and_apply "dhcp" "$IFACE" "" "" "${dns_ary[@]:-}"
    exit 0
  fi

  # Static mode requires --ip, --gw, --dns
  if [[ -z "$IPV4_CIDR" || -z "$GW4" || -z "$DNS4" ]]; then
    echo "Static mode requires --ip, --gw, and --dns." >&2
    usage; exit 1
  fi

  read -r ip4 ip4p < <(parse_ipv4_cidr "$IPV4_CIDR")
  validate_gw4_in_subnet "$ip4" "$ip4p" "$GW4"
  IFS=',' read -r -a dns_ary <<<"$DNS4"
  for d in "${dns_ary[@]}"; do is_ipv4 "$d" || { echo "Invalid DNS entry: $d" >&2; exit 1; }; done

  generate_and_apply "static" "$IFACE" "$ip4/$ip4p" "$GW4" "${dns_ary[@]}"
}

# ------------- GENERATOR -------------
generate_and_apply() {
  local mode="$1" iface="$2" ip_with_prefix="${3:-}" gw4="${4:-}"
  shift 4 || true
  local -a dns_ary=("$@")

  # Resolve netplan file automatically if not provided
  local NETPLAN_FILE="$NETPLAN_FILE_ARG"
  if [[ -z "$NETPLAN_FILE" ]]; then
    shopt -s nullglob
    local files=(/etc/netplan/*.yaml /etc/netplan/*.yml)
    shopt -u nullglob
    if (( ${#files[@]} >= 1 )); then
      NETPLAN_FILE="${files[0]}"
    else
      NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
    fi
  fi

  local YAML_CONTENT=""
  if is_vlan_iface "$iface"; then
    local base id
    base="$(vlan_base "$iface")"
    id="$(vlan_id "$iface")"
    if [[ "$mode" == "dhcp" ]]; then
      local DNS_BLOCK_DHCP=""
      if [[ ${#dns_ary[@]} -gt 0 ]]; then DNS_BLOCK_DHCP="$(build_dns_block "${dns_ary[@]}")"; fi
      YAML_CONTENT=$(cat <<EOF
network:
  version: 2
  ethernets:
    ${base}: {}
  vlans:
    ${iface}:
      id: ${id}
      link: ${base}
      dhcp4: yes
$( [[ -n "$DNS_BLOCK_DHCP" ]] && printf "%s
" "$DNS_BLOCK_DHCP" )
EOF
)
    else
      local DNS_BLOCK="$(build_dns_block "${dns_ary[@]}")"
      YAML_CONTENT=$(cat <<EOF
network:
  version: 2
  ethernets:
    ${base}: {}
  vlans:
    ${iface}:
      id: ${id}
      link: ${base}
      dhcp4: no
      addresses:
        - ${ip_with_prefix}
      routes:
        - to: default
          via: ${gw4}
$DNS_BLOCK
EOF
)
    fi
  else
    if [[ "$mode" == "dhcp" ]]; then
      local DNS_BLOCK_DHCP=""
      if [[ ${#dns_ary[@]} -gt 0 ]]; then DNS_BLOCK_DHCP="$(build_dns_block "${dns_ary[@]}")"; fi
      YAML_CONTENT=$(cat <<EOF
network:
  version: 2
  ethernets:
    ${iface}:
      dhcp4: yes
$( [[ -n "$DNS_BLOCK_DHCP" ]] && printf "%s
" "$DNS_BLOCK_DHCP" )
EOF
)
    else
      local DNS_BLOCK="$(build_dns_block "${dns_ary[@]}")"
      YAML_CONTENT=$(cat <<EOF
network:
  version: 2
  ethernets:
    ${iface}:
      dhcp4: no
      addresses:
        - ${ip_with_prefix}
      routes:
        - to: default
          via: ${gw4}
$DNS_BLOCK
EOF
)
    fi
  fi

  # Preview
  echo "============= CONFIGURATION PREVIEW ============="
  echo "Netplan file: ${NETPLAN_FILE}"
  echo "Interface   : ${iface}"
  if [[ "$mode" == "dhcp" ]]; then
    echo "Mode        : DHCPv4"
    if [[ ${#dns_ary[@]} -gt 0 ]]; then
      echo "DNS (override): ${dns_ary[*]}"
    else
      echo "DNS         : from DHCP lease"
    fi
  else
    echo "IPv4        : ${ip_with_prefix}"
    echo "GW IPv4     : ${gw4}"
    echo "DNS         : ${dns_ary[*]}"
  fi
  echo "================================================="

  if (( DRY_RUN==1 )); then
    echo
    echo "$YAML_CONTENT"
    echo
    echo "Dry-run: YAML printed above. No changes written or applied."
    return
  fi

  need_root
  mkdir -p /etc/netplan
  if [[ -f "$NETPLAN_FILE" ]]; then
    cp -a "$NETPLAN_FILE" "${NETPLAN_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
  fi
  printf "%s
" "$YAML_CONTENT" > "$NETPLAN_FILE"

  if (( VALIDATE_ONLY==1 )); then
    netplan generate
    echo "Validation: 'netplan generate' succeeded. Configuration not applied."
  else
    apply_netplan
  fi

  echo
  echo "Interface status for $iface:"
  if command -v ifconfig >/dev/null 2>&1; then
    ifconfig "$iface" | sed -n '1,12p'
  else
    ip -4 -brief address show dev "$iface"
  fi
  echo
  echo "Done: interface $iface configured. YAML saved at: $NETPLAN_FILE"
}

main "$@"
