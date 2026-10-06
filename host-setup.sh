#!/usr/bin/env bash
# Proxmox host detection and configuration for PCIe passthrough (IOMMU + VFIO)

set -Eeuo pipefail

readonly GRUB_FILE="/etc/default/grub"
readonly CMDLINE_FILE="/etc/kernel/cmdline"
readonly MODULES_FILE="/etc/modules"
readonly VFIO_MODULES=(vfio vfio_iommu_type1 vfio_pci)

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

confirm() {
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

detect_proxmox() {
    [[ $EUID -eq 0 ]] || die "Run as root on the Proxmox host."
    command -v pveversion >/dev/null 2>&1 || die "Proxmox VE not detected (pveversion missing)."
    info "Detected $(pveversion)"
}

detect_cpu() {
    if grep -qi 'GenuineIntel' /proc/cpuinfo; then
        CPU_PARAM="intel_iommu=on"
        info "CPU vendor: Intel"
    elif grep -qi 'AuthenticAMD' /proc/cpuinfo; then
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

iommu_active() {
    compgen -G '/sys/kernel/iommu_groups/*' >/dev/null
}

cmdline_has() {
    grep -qw -- "$1" /proc/cmdline
}

report_status() {
    if iommu_active; then
        info "IOMMU groups present: $(find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 | wc -l)"
    else
        warn "No IOMMU groups found (IOMMU disabled in firmware or kernel)."
    fi
    cmdline_has "$CPU_PARAM" && info "Kernel cmdline has $CPU_PARAM" || warn "Kernel cmdline missing $CPU_PARAM"
    cmdline_has "iommu=pt" && info "Kernel cmdline has iommu=pt" || warn "Kernel cmdline missing iommu=pt"
    local m
    for m in "${VFIO_MODULES[@]}"; do
        if grep -qx "$m" "$MODULES_FILE" 2>/dev/null; then
            info "$m listed in $MODULES_FILE"
        else
            warn "$m not listed in $MODULES_FILE"
        fi
    done
}

add_param() {
    # add_param <file> <sed-address-regex> <param> : appends param inside the quoted/single-line value
    local file="$1" param="$2" pattern="$3"
    grep -qw -- "$param" <(grep -E "$pattern" "$file") && return 0
    cp -a "$file" "$file.bak.$(date +%s)"
    if [[ "$file" == "$GRUB_FILE" ]]; then
        sed -Ei "/$pattern/ s/\"\$/ $param\"/" "$file"
    else
        sed -Ei "1 s/\$/ $param/" "$file"
    fi
}

configure_cmdline() {
    local p
    for p in "$CPU_PARAM" "iommu=pt"; do
        if [[ "$BOOTLOADER" == grub ]]; then
            grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT="' "$GRUB_FILE" || die "GRUB_CMDLINE_LINUX_DEFAULT not found in $GRUB_FILE."
            add_param "$GRUB_FILE" "$p" '^GRUB_CMDLINE_LINUX_DEFAULT='
        else
            [[ -f "$CMDLINE_FILE" ]] || die "$CMDLINE_FILE not found."
            add_param "$CMDLINE_FILE" "$p" '.'
        fi
    done
    if [[ "$BOOTLOADER" == grub ]]; then update-grub; else proxmox-boot-tool refresh; fi
}

configure_modules() {
    local m
    for m in "${VFIO_MODULES[@]}"; do
        grep -qx "$m" "$MODULES_FILE" 2>/dev/null || echo "$m" >> "$MODULES_FILE"
    done
    update-initramfs -u -k all
}

main() {
    detect_proxmox
    detect_cpu
    detect_bootloader
    report_status

    if iommu_active && cmdline_has "$CPU_PARAM" && cmdline_has "iommu=pt" \
        && lsmod | grep -q '^vfio_pci'; then
        info "Host is already configured for PCIe passthrough."
        exit 0
    fi

    warn "This edits boot settings and VFIO modules, then requires a reboot. Keep console access available."
    confirm "Apply host configuration now?" || { info "No changes made."; exit 0; }

    configure_cmdline
    configure_modules
    info "Configuration complete. Bind specific devices to vfio-pci manually if needed (see README)."
    if confirm "Reboot now?"; then reboot; fi
}

main "$@"
