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

CHOICE=$(whiptail --title "Proxmox VM Builder" --menu "Select Deployment Profile" 16 64 5 \
    "1" "Deploy Bazzite Gaming VM (with GPU/Wi-Fi Passthrough)" \
    "2" "Deploy Generic Linux VM" \
    "3" "Deploy Automated Windows 11 VM" \
    "4" "Detect & Configure Proxmox Host (IOMMU/VFIO)" \
    "5" "Exit" 3>&1 1>&2 2>&3)

case $CHOICE in
    1)
        echo "Fetching Bazzite VM Deployment Script..."
        bash -c "$(wget -qLO - https://raw.githubusercontent.com/jbdotmpeg/proxmox-vm-builder/main/vms/bazzite-vm.sh)"
        ;;
    2)
        echo "Fetching Generic Linux VM Script..."
        bash -c "$(wget -qLO - https://raw.githubusercontent.com/jbdotmpeg/proxmox-vm-builder/main/vms/generic-linux-vm.sh)"
        ;;
    3)
        echo "Fetching Windows VM Script..."
        bash -c "$(wget -qLO - https://raw.githubusercontent.com/jbdotmpeg/proxmox-vm-builder/main/vms/windows-vm.sh)"
        ;;
    4)
        echo "Fetching Proxmox host setup script..."
        bash -c "$(wget -qLO - https://raw.githubusercontent.com/jbdotmpeg/proxmox-vm-builder/main/host-setup.sh)"
        ;;
    *)
        exit 0
        ;;
esac
