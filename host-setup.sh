#!/usr/bin/env bash
# Proxmox host detection and configuration for PCIe passthrough (IOMMU + VFIO)
#
# Usage: host-setup.sh [--check] [--yes] [--bind ADDR[,ADDR...]] [--revert] [--help]
#   --check   Report host status only; make no changes (exit 0 ready, 3 not ready)
#   --yes     Do not prompt; apply changes unattended (does not reboot)
#   --bind    Bind the given PCI addresses (plus related GPU audio functions) to vfio-pci
#   --revert  Restore files from the latest backups made by this script

set -Eeuo pipefail

GRUB_FILE="${GRUB_FILE:-/etc/default/grub}"
CMDLINE_FILE="${CMDLINE_FILE:-/etc/kernel/cmdline}"
MODULES_FILE="${MODULES_FILE:-/etc/modules}"
VFIO_CONF="${VFIO_CONF:-/etc/modprobe.d/vfio.conf}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/proxmox-vm-builder}"
PROC_CPUINFO="${PROC_CPUINFO:-/proc/cpuinfo}"
PROC_CMDLINE="${PROC_CMDLINE:-/proc/cmdline}"
SYS_ROOT="${SYS_ROOT:-/sys}"
VFIO_MODULES=(vfio vfio_iommu_type1 vfio_pci)
MIN_PVE_MAJOR=7

CHECK_ONLY=0
ASSUME_YES=0
REVERT=0
BIND_LIST=""
CPU_PARAM=""
BOOTLOADER=""
PROBLEMS=0
declare -A MGMT_DEVICES=()

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; PROBLEMS=$((PROBLEMS + 1)); }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

confirm() {
    ((ASSUME_YES)) && return 0
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

detect_proxmox() {
    command -v pveversion >/dev/null 2>&1 || die "Proxmox VE not detected (pveversion missing)."
    local version major
    version=$(pveversion)
    info "Detected $version"
    major=$(sed -nE 's#^pve-manager/([0-9]+)\..*#\1#p' <<<"$version")
    if [[ -z "$major" ]]; then
        warn "Could not parse the Proxmox version."
    elif ((major < MIN_PVE_MAJOR)); then
        warn "Proxmox VE $major is older than the supported minimum ($MIN_PVE_MAJOR)."
    fi
}

ensure_pciutils() {
    command -v lspci >/dev/null 2>&1 && return 0
    if ((CHECK_ONLY)); then
        warn "pciutils (lspci) is not installed."
        return 1
    fi
    info "Installing pciutils..."
    apt-get install -y pciutils >/dev/null || die "Failed to install pciutils."
}

detect_cpu() {
    if grep -qi 'GenuineIntel' "$PROC_CPUINFO"; then
        CPU_PARAM="intel_iommu=on"
        info "CPU vendor: Intel"
    elif grep -qi 'AuthenticAMD' "$PROC_CPUINFO"; then
        CPU_PARAM="amd_iommu=on"
        info "CPU vendor: AMD"
    else
        die "Unsupported CPU vendor."
    fi
}

detect_bootloader() {
    if command -v proxmox-boot-tool >/dev/null 2>&1 \
        && proxmox-boot-tool status 2>&1 | grep -qi 'systemd-boot'; then
        BOOTLOADER="systemd-boot"
    elif [[ -f "$GRUB_FILE" ]]; then
        BOOTLOADER="grub"
    else
        die "Could not determine boot loader."
    fi
    info "Boot loader: $BOOTLOADER"
}

iommu_active() { compgen -G "$SYS_ROOT/kernel/iommu_groups/*" >/dev/null; }
cmdline_has() { grep -qw -- "$1" "$PROC_CMDLINE"; }
vfio_loaded() { lsmod 2>/dev/null | grep -q '^vfio_pci'; }

report_status() {
    if iommu_active; then
        info "IOMMU groups present: $(find "$SYS_ROOT/kernel/iommu_groups" -mindepth 1 -maxdepth 1 | wc -l)"
    else
        warn "No IOMMU groups found (IOMMU disabled in firmware or kernel)."
    fi
    local p
    for p in "$CPU_PARAM" iommu=pt; do
        if cmdline_has "$p"; then info "Kernel cmdline has $p"; else warn "Kernel cmdline missing $p"; fi
    done
    local m
    for m in "${VFIO_MODULES[@]}"; do
        if grep -qx "$m" "$MODULES_FILE" 2>/dev/null; then
            info "$m listed in $MODULES_FILE"
        else
            warn "$m not listed in $MODULES_FILE"
        fi
    done
}

# ---- device checks -------------------------------------------------------

pci_path() { printf '%s/bus/pci/devices/%s' "$SYS_ROOT" "$1"; }

iommu_group_of() {
    local link
    link=$(readlink "$(pci_path "$1")/iommu_group" 2>/dev/null) || return 1
    printf '%s\n' "${link##*/}"
}

driver_of() {
    lspci -nnk -s "$1" 2>/dev/null | sed -nE 's/^[[:space:]]*Kernel driver in use: (.*)/\1/p'
}

ids_of() {
    lspci -nn -s "$1" | grep -oE '\[[0-9a-f]{4}:[0-9a-f]{4}\]' | tail -n1 | tr -d '[]'
}

# Populate MGMT_DEVICES with PCI addresses of NICs behind the default route.
find_management_devices() {
    command -v ip >/dev/null 2>&1 || return 0
    local dev port addr
    dev=$(ip -o route show default 2>/dev/null | sed -nE 's/.* dev ([^ ]+).*/\1/p' | head -n1) || true
    [[ -n "$dev" ]] || return 0
    local -a ifaces=("$dev")
    for port in "$SYS_ROOT/class/net/$dev/brif/"*; do
        if [[ -e "$port" ]]; then ifaces+=("${port##*/}"); fi
    done
    for port in "${ifaces[@]}"; do
        addr=$(readlink -f "$SYS_ROOT/class/net/$port/device" 2>/dev/null || true)
        [[ -n "$addr" ]] && MGMT_DEVICES["${addr##*/}"]="$port"
    done
    return 0
}

is_management() { [[ -n "${MGMT_DEVICES[$1]:-}" ]]; }

check_devices() {
    command -v lspci >/dev/null 2>&1 || return 0
    find_management_devices
    local line addr desc driver group kind flags
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        addr="${line%% *}"
        desc="${line#"$addr "}"
        case "${desc,,}" in
            *vga*|*3d\ controller*|*display\ controller*) kind=GPU ;;
            *network\ controller*|*wireless*|*wi-fi*) kind=Wi-Fi ;;
            *ethernet\ controller*) kind=NIC ;;
            *) continue ;;
        esac
        driver=$(driver_of "$addr"); group=$(iommu_group_of "$addr" || echo none)
        flags=""
        is_management "$addr" && flags+=" [MANAGEMENT NETWORK: ${MGMT_DEVICES[$addr]}]"
        [[ "$(cat "$(pci_path "$addr")/boot_vga" 2>/dev/null)" == 1 ]] && flags+=" [HOST CONSOLE]"
        info "$kind $addr group=$group driver=${driver:-none}$flags :: $desc"
        if [[ -n "$flags" ]]; then warn "$addr carries host connectivity/console; do not pass it through."; fi
        case "$driver" in
            nvidia|nouveau|amdgpu|radeon|i915)
                info "  $addr uses host driver '$driver'; vfio-pci must claim it before that driver loads (bind by ID with --bind)." ;;
        esac
        if [[ "$kind" == GPU ]]; then check_gpu_firmware "$addr"; fi
    done < <(lspci -D 2>/dev/null)
    return 0
}

check_gpu_firmware() {
    local addr="$1" res start above=0 details
    while read -r start _; do
        if [[ "$start" =~ ^0x[0-9a-fA-F]+$ ]] && ((start > 0xffffffff)); then above=1; fi
    done < "$(pci_path "$addr")/resource" 2>/dev/null || true
    if ((above)); then
        info "  $addr has BARs above 4G (Above-4G decoding appears enabled)."
    else
        warn "$addr has no BAR above 4G; enable 'Above 4G Decoding' in the BIOS."
    fi
    if res=$(lspci -vv -s "$addr" 2>/dev/null) && grep -qi 'Resizable BAR' <<<"$res"; then
        details=$(grep -i 'Resizable BAR' <<<"$res" | head -n1 | sed 's/^[[:space:]]*//')
        info "  $addr: $details (confirm 'Resizable BAR' is enabled in the BIOS if desired)."
    fi
}

# ---- backups and revert --------------------------------------------------

backup_name() { local n="${1//\//_}"; printf '%s/%s' "$BACKUP_DIR" "${n#_}"; }

backup_file() {
    local file="$1" base stamp
    mkdir -p "$BACKUP_DIR"
    base=$(backup_name "$file")
    stamp=$(date +%Y%m%d-%H%M%S-%N)
    if [[ -e "$file" ]]; then
        cp -a "$file" "$base.$stamp.bak"
    else
        : > "$base.$stamp.absent"
    fi
}

latest_backup() { ls -1 "$(backup_name "$1")".*.bak "$(backup_name "$1")".*.absent 2>/dev/null | sort | tail -n1; }

revert_all() {
    local file backup restored=0
    for file in "$GRUB_FILE" "$CMDLINE_FILE" "$MODULES_FILE" "$VFIO_CONF"; do
        backup=$(latest_backup "$file" || true)
        [[ -n "$backup" ]] || continue
        if [[ "$backup" == *.absent ]]; then rm -f "$file"; else cp -a "$backup" "$file"; fi
        info "Restored $file from $backup"
        restored=1
        rm -f "$backup"
    done
    ((restored)) || { info "No backups found in $BACKUP_DIR."; return 0; }
    refresh_boot
    update-initramfs -u -k all
    info "Revert complete. Reboot to apply."
}

refresh_boot() {
    if [[ "$BOOTLOADER" == grub ]]; then update-grub; else proxmox-boot-tool refresh; fi
}

# ---- configuration -------------------------------------------------------

add_param() {
    local file="$1" param="$2"
    if [[ "$file" == "$GRUB_FILE" ]]; then
        grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$file" | grep -qw -- "$param" && return 0
        sed -Ei "/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/([\"'])\$/ $param\1/" "$file"
    else
        grep -qw -- "$param" "$file" && return 0
        sed -Ei "1 s/\$/ $param/" "$file"
    fi
}

configure_cmdline() {
    local target p
    if [[ "$BOOTLOADER" == grub ]]; then
        target="$GRUB_FILE"
        grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=["'"'"']' "$target" \
            || { warn "GRUB_CMDLINE_LINUX_DEFAULT not found in $target; skipping."; return 1; }
    else
        target="$CMDLINE_FILE"
        [[ -f "$target" ]] || { warn "$target not found; skipping."; return 1; }
        if (( $(grep -c . "$target") != 1 )); then
            warn "$target does not contain exactly one line; skipping automatic edit."
            return 1
        fi
    fi
    backup_file "$target"
    for p in "$CPU_PARAM" iommu=pt; do add_param "$target" "$p"; done
    refresh_boot
}

configure_modules() {
    local m changed=0
    for m in "${VFIO_MODULES[@]}"; do
        grep -qx "$m" "$MODULES_FILE" 2>/dev/null && continue
        ((changed)) || backup_file "$MODULES_FILE"
        changed=1
        echo "$m" >> "$MODULES_FILE"
    done
    ((changed == 0)) || update-initramfs -u -k all
}

# Echo "ADDR" plus other functions in the same slot that are GPU audio functions.
expand_with_related() {
    local addr="$1" slot other
    printf '%s\n' "$addr"
    slot="${addr%.*}"
    lspci -nn -s "$slot." 2>/dev/null | while IFS= read -r other; do
        [[ "${other%% *}" == "$addr" || "${other%% *}" == "${addr#0000:}" ]] && continue
        [[ "$other" == *"Audio device"* ]] && printf '%s\n' "${slot%%:*}:${other%% *}"
    done
}

normalize_addr() { [[ "$1" =~ ^[[:xdigit:]]{4}: ]] && printf '%s\n' "${1,,}" || printf '0000:%s\n' "${1,,}"; }

bind_devices() {
    local -a addrs=() ids=() all=()
    local a b id
    IFS=',' read -r -a addrs <<<"$1"
    for a in "${addrs[@]}"; do
        a=$(normalize_addr "$a")
        [[ "$a" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]] || { warn "Invalid PCI address '$a'."; return 1; }
        lspci -s "$a" 2>/dev/null | grep -q . || { warn "Device $a not found."; return 1; }
        if is_management "$a"; then
            warn "Refusing to bind $a: it carries the management network (${MGMT_DEVICES[$a]})."
            return 1
        fi
        while IFS= read -r b; do all+=("$(normalize_addr "$b")"); done < <(expand_with_related "$a")
    done
    for a in "${all[@]}"; do
        if is_management "$a"; then warn "Refusing to bind $a (management network)."; return 1; fi
        id=$(ids_of "$a")
        [[ -n "$id" ]] || continue
        [[ " ${ids[*]} " == *" $id "* ]] || ids+=("$id")
    done
    ((${#ids[@]})) || { warn "No device IDs resolved."; return 1; }
    local joined
    joined=$(IFS=,; echo "${ids[*]}")
    info "Binding to vfio-pci: ${all[*]} (ids=$joined). Note: this rule binds every device with these IDs."
    backup_file "$VFIO_CONF"
    mkdir -p "$(dirname "$VFIO_CONF")"
    printf 'options vfio-pci ids=%s\n' "$joined" > "$VFIO_CONF"
    update-initramfs -u -k all
}

pick_devices_interactively() {
    command -v whiptail >/dev/null 2>&1 || return 0
    local -a opts=()
    local line addr
    while IFS= read -r line; do
        addr="${line%% *}"
        is_management "$addr" && continue
        opts+=("$addr" "${line#"$addr "}" OFF)
    done < <(lspci -D | grep -Ei 'vga|3d controller|display controller|network controller|wireless|wi-fi')
    ((${#opts[@]})) || return 0
    local sel
    sel=$(whiptail --title "VFIO binding" --checklist "Select devices to reserve for VMs (Esc to skip):" \
        20 90 8 "${opts[@]}" 3>&1 1>&2 2>&3) || return 0
    sel=$(tr -d '"' <<<"$sel" | tr ' ' ',')
    if [[ -n "$sel" ]]; then BIND_LIST="$sel"; fi
    return 0
}

host_ready() {
    iommu_active && cmdline_has "$CPU_PARAM" && cmdline_has iommu=pt && vfio_loaded
}

parse_args() {
    while (($#)); do
        case "$1" in
            --check) CHECK_ONLY=1 ;;
            --yes|-y) ASSUME_YES=1 ;;
            --revert) REVERT=1 ;;
            --bind) shift; [[ $# -gt 0 ]] || die "--bind requires an argument."; BIND_LIST="$1" ;;
            --help|-h) usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done
}

main() {
    parse_args "$@"
    if ((CHECK_ONLY && REVERT)); then die "--check and --revert cannot be combined."; fi
    if ((!CHECK_ONLY)) && [[ $EUID -ne 0 ]]; then die "Run as root on the Proxmox host (or use --check)."; fi

    detect_proxmox
    ensure_pciutils || true
    detect_cpu
    detect_bootloader

    if ((REVERT)); then
        confirm "Restore the latest backups of boot/VFIO files?" || { info "No changes made."; exit 0; }
        revert_all
        exit 0
    fi

    report_status
    check_devices

    if ((CHECK_ONLY)); then
        if host_ready && ((PROBLEMS == 0)); then info "Host is ready for PCIe passthrough."; exit 0; fi
        info "Host is not fully ready ($PROBLEMS issue(s) reported)."
        exit 3
    fi

    local changed=0
    if ! host_ready; then
        warn "This edits boot settings and VFIO modules, then requires a reboot. Keep console access available."
        if confirm "Apply host configuration now?"; then
            configure_cmdline || true
            configure_modules
            changed=1
        else
            info "No host configuration changes made."
        fi
    else
        info "IOMMU and VFIO are already configured."
    fi

    if [[ -z "$BIND_LIST" ]] && ((!ASSUME_YES)); then pick_devices_interactively; fi
    if [[ -n "$BIND_LIST" ]]; then
        if confirm "Bind $BIND_LIST to vfio-pci?" && bind_devices "$BIND_LIST"; then changed=1; fi
    fi

    if ((changed)); then
        info "Configuration complete. A reboot is required."
        if ((!ASSUME_YES)) && confirm "Reboot now?"; then reboot; fi
    fi
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
