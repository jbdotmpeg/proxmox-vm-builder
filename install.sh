#!/usr/bin/env bash
# Copyright (c) 2026 Jimmy Brock
# License: MIT
# Purpose: Proxmox Universal VM & Passthrough Deployment Suite

function header_info {
clear
cat <<"EOF"
██████╗ ██╗   ██╗███╗   ███╗███╗   ███╗
██╔══██╗██║   ██║████╗ ████║████╗ ████║
██████╔╝██║   ██║██╔████╔██║██╔████╔██║
██╔═══╝ ╚██╗ ██╔╝██║ ╚═╝ ██║██║ ╚═╝ ██║
██║      ╚████╔╝ ██║     ██║██║     ██║
╚═╝       ╚═══╝  ╚═╝     ╚═╝╚═╝     ╚═╝
  Proxmox Universal VM & Passthrough Builder
EOF
}

header_info

# Check if whiptail is available
if ! command -v whiptail &> /dev/null; then
    echo "Whiptail is required but not installed. Aborting."
    exit 1
fi

# Pin to a tag or commit with: PVMB_REF=v1.0.0 bash install.sh
REF="${PVMB_REF:-main}"
BASE_URL="https://raw.githubusercontent.com/jbdotmpeg/proxmox-vm-builder/${REF}"

# Download a script, verify it against SHA256SUMS for the same ref, then run it.
run_remote() {
    local path="$1" tmp sums expected actual
    shift
    tmp=$(mktemp) || return 1
    sums=$(mktemp) || { rm -f "$tmp"; return 1; }
    trap 'rm -f "$tmp" "$sums"' RETURN
    wget -qLO "$tmp" "$BASE_URL/$path" || { echo "Failed to download $path"; return 1; }
    wget -qLO "$sums" "$BASE_URL/SHA256SUMS" || { echo "Failed to download SHA256SUMS"; return 1; }
    expected=$(awk -v f="$path" '$2 == f {print $1}' "$sums")
    actual=$(sha256sum "$tmp" | awk '{print $1}')
    if [[ -z "$expected" || "$expected" != "$actual" ]]; then
        echo "Checksum verification failed for $path; aborting."
        return 1
    fi
    bash "$tmp" "$@"
}

if ! compgen -G '/sys/kernel/iommu_groups/*' >/dev/null; then
    if whiptail --yesno "IOMMU is not active on this host, so PCIe passthrough will not work.\nRun host detection/configuration now?" 10 70; then
        run_remote host-setup.sh
    fi
fi

CHOICE=$(whiptail --title "Proxmox VM Builder" --menu "Select Deployment Profile" 16 64 5 \
    "1" "Deploy Bazzite Gaming VM (with GPU/Wi-Fi Passthrough)" \
    "2" "Deploy Generic Linux VM" \
    "3" "Deploy Windows 11 VM" \
    "4" "Detect & Configure Proxmox Host (IOMMU/VFIO)" \
    "5" "Exit" 3>&1 1>&2 2>&3)

case $CHOICE in
    1) run_remote vms/bazzite-vm.sh ;;
    2) run_remote vms/generic-linux-vm.sh ;;
    3) run_remote vms/windows-vm.sh ;;
    4) run_remote host-setup.sh ;;
    *) exit 0 ;;
esac
