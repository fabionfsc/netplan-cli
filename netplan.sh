#!/usr/bin/env bash
set -euo pipefail

# ------------- CLI PARSER (IPv4-only) -------------
IFACE=""
IPV4_CIDR=""
GW4=""
DNS4=""
NETPLAN_FILE_ARG=""
DRY_RUN=0
VALIDATE_ONLY=0
SHOW_ALL_IFACES=0

usage() {
  cat <<EOF
Usage: sudo $0 [options]

Interactive mode: run with no options.

Non-interactive options:
  --iface IFACE           Interface name (e.g. ens3, enp0s3, bond0, ens3.120)
  --ip CIDR               IPv4 CIDR (e.g. 192.168.10.5/24)
  --gw IPV4               Default IPv4 gateway
  --dns LIST              DNS IPv4 comma-separated (e.g. 1.1.1.1,8.8.8.8)

General:
  --file PATH             Netplan YAML to write (default: auto-detect or /etc/netplan/01-netcfg.yaml)
  --dry-run               Print YAML to stdout only; do not write/apply
  --validate-only         Generate and validate netplan without applying
  --show-all-ifaces       Show every interface (no filtering)
  -h, --help              This help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iface) IFACE="$2"; shift 2;;
    --ip) IPV4_CIDR="$2"; shift 2;;
    --gw) GW4="$2"; shift 2;;
    --dns) DNS4="$2"; shift 2;;
    --file) NETPLAN_FILE_ARG="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --validate-only) VALIDATE_ONLY=1; shift;;
    --show-all-ifaces) SHOW_ALL_IFACES=1; shift;;
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

list_netplan_files() {
  shopt -s nullglob
  local files=(/etc/netplan/*.yaml /etc/netplan/*.yml)
  shopt -u nullglob
  echo "${files[@]:-}"
}

pick_netplan_file() {
  local files=("$@")
  if [[ -n "$NETPLAN_FILE_ARG" ]]; then
    echo "$NETPLAN_FILE_ARG"
    return
  fi
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "/etc/netplan/01-netcfg.yaml"
    return
  fi
  if [[ ${#files[@]} -eq 1 ]]; then
    echo "${files[0]}"
    return
  fi
  echo "Multiple Netplan YAML files found:"
  local i=1
  for f in "${files[@]}"; do
    echo "  [$i] $f"
    ((i++))
  done
  local choice
  while true; do
    read -r -p "Choice [1-${#files[@]}] (default 1): " choice
    [[ -z "$choice" ]] && choice=1
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#files[@]} )); then
      echo "${files[choice-1]}"
      return
    fi
    echo "Invalid choice."
  done
}

list_ifaces() {
  local cmd="ip -o link show | awk -F': ' '{print \$2}'"
  if (( SHOW_ALL_IFACES==0 )); then
    # filtra lo, docker, veth, cni, flannel, wg, tailscale, vm/virt bridges, tun/tap, zerotier
    bash -c "$cmd" | grep -Ev '^(lo|docker|veth|cni|flannel|wg|tailscale|vmnet|vnet|virbr|br-[0-9a-f]{12}|tun|tap|zt[a-z0-9]+)$' || true
  else
    bash -c "$cmd" || true
  fi
}

pick_iface() {
  if [[ -n "$IFACE" ]]; then
    echo "$IFACE"
    return
  fi
  mapfile -t ifaces < <(list_ifaces)
  if [[ ${#ifaces[@]} -eq 0 ]]; then
    echo "No usable interfaces found." >&2
    exit 1
  fi
  if [[ ${#ifaces[@]} -eq 1 ]]; then
    echo "${ifaces[0]}"
    return
  fi
  echo "Detected interfaces:"
  local i=1
  for itf in "${ifaces[@]}"; do
    echo "  [$i] $itf"
    ((i++))
  done
  local choice
  while true; do
    read -r -p "Select interface [1-${#ifaces[@]}] (default 1): " choice
    [[ -z "$choice" ]] && choice=1
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#ifaces[@]} )); then
      echo "${ifaces[choice-1]}"
      return
    fi
    echo "Invalid choice."
  done
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
int2ip() { local int="$1"; printf "%d.%d.%d.%d" $(( (int>>24)&255 )) $(( (int>>16)&255 )) $(( (int>>8)&255 )) $(( int&255 )); }
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

confirm() { local prompt="$1" ans; read -r -p "$prompt [y/N]: " ans; [[ "$ans" == "y" || "$ans" == "Y" ]]; }

show_iface_status() {
  local iface="$1"
  if command -v ifconfig >/dev/null 2>&1; then
    ifconfig "$iface" | sed -n '1,12p'
  else
    ip -4 -brief address show dev "$iface"
  fi
}

apply_netplan() {
  netplan generate
  if (( VALIDATE_ONLY==1 )); then
    echo "Validation: 'netplan generate' succeeded."
    return
  fi
  netplan apply
}

# ------------- CORE -------------
main() {
  need_root

  # Resolve netplan file
  mapfile -t files < <(list_netplan_files)
  NETPLAN_FILE="$(pick_netplan_file "${files[@]}")"

  # Resolve iface
  IFACE="$(pick_iface)"

  # Interactive or args-fed values
  local ip4 ip4p gw4 dns_ary
  if [[ -z "$IPV4_CIDR" ]]; then
    # Interactive IPv4
    while true; do
      read -r -p "Define IPv4/prefix (e.g. 192.168.100.10/24): " in
      if read -r ip4 ip4p < <(parse_ipv4_cidr "$in" 2>/dev/null); then
        break
      fi
    done
    while true; do
      read -r -p "Define default IPv4 gateway: " gw
      if validate_gw4_in_subnet "$ip4" "$ip4p" "$gw"; then gw4="$gw"; break; fi
    done
    while true; do
      read -r -p "Primary DNS: " d1
      if is_ipv4 "$d1"; then
        dns_ary=("$d1")
        read -r -p "Secondary DNS (optional, Enter to skip): " d2
        [[ -n "$d2" ]] && is_ipv4 "$d2" && dns_ary+=("$d2")
        break
      else
        echo "Invalid DNS."
      fi
    done
  else
    # Non-interactive
    read -r ip4 ip4p < <(parse_ipv4_cidr "$IPV4_CIDR")
    [[ -n "$GW4" ]] && validate_gw4_in_subnet "$ip4" "$ip4p" "$GW4"
    gw4="$GW4"
    if [[ -n "$DNS4" ]]; then
      IFS=',' read -r -a dns_ary <<<"$DNS4"
      # validate DNS entries
      for d in "${dns_ary[@]}"; do
        is_ipv4 "$d" || { echo "Invalid DNS entry: $d" >&2; exit 1; }
      done
    else
      echo "At least one DNS must be provided via --dns in non-interactive mode."
      exit 1
    fi
  fi

  # Build YAML
  local DNS_BLOCK="      nameservers:
        addresses: [$(printf "%s," "${dns_ary[@]}" | sed 's/,$//')]"
  local ADDR_BLOCK="      addresses:
        - $ip4/$ip4p"
  local GW4_LINE="      gateway4: $gw4"

  YAML_CONTENT=$(cat <<EOF
network:
  version: 2
  ethernets:
    $IFACE:
      dhcp4: no
$ADDR_BLOCK
$GW4_LINE
$DNS_BLOCK
EOF
)

  # Preview
  echo
  echo "============= CONFIGURATION PREVIEW ============="
  echo "Netplan file: ${NETPLAN_FILE}"
  echo "Interface   : ${IFACE}"
  echo "IPv4        : ${ip4}/${ip4p}"
  echo "GW IPv4     : ${gw4}"
  echo "DNS         : $(printf "%s " "${dns_ary[@]}")"
  echo "================================================="
  echo

  if (( DRY_RUN==1 )); then
    echo "$YAML_CONTENT"
    echo
    echo "Dry-run: YAML printed above. No changes written or applied."
    exit 0
  fi

  # Confirm only if interactive (no args used)
  if [[ -z "$IPV4_CIDR$GW4$DNS4$IFACE$NETPLAN_FILE_ARG" ]]; then
    confirm "Apply these settings?" || { echo "Aborted."; exit 1; }
  fi

  mkdir -p /etc/netplan
  if [[ -f "$NETPLAN_FILE" ]]; then
    cp -a "$NETPLAN_FILE" "${NETPLAN_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
  fi
  printf "%s\n" "$YAML_CONTENT" > "$NETPLAN_FILE"

  # Validate/apply
  if (( VALIDATE_ONLY==1 )); then
    netplan generate
    echo "Validation: 'netplan generate' succeeded. Configuration not applied."
  else
    apply_netplan
  fi

  echo
  echo "Interface status for $IFACE:"
  show_iface_status "$IFACE"
  echo
  echo "Route to 1.1.1.1:"
  ip route get 1.1.1.1 || true

  echo
  echo "Done: interface $IFACE configured. YAML saved at: $NETPLAN_FILE"
}

main "$@"