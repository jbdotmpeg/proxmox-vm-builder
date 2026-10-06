#!/usr/bin/env bash
# Bazzite OS VM Deployer with Automatic PCIe Passthrough Discovery

set -euo pipefail

echo "=== Bazzite OS VM Builder ==="

VMID=$(whiptail --inputbox "Enter VM ID for Bazzite:" 10 50 "135" 3>&1 1>&2 2>&3)
VM_NAME=$(whiptail --inputbox "Enter VM Name:" 10 50 "bazzite-gaming-vm" 3>&1 1>&2 2>&3)

# Build GPU options dynamically
GPU_OPTIONS=()
while IFS= read -r line; do
    if [[ -n "$line" ]]; then
        addr=$(echo "$line" | awk '{print $1}')
        desc=$(echo "$line" | cut -d' ' -f2-)
        GPU_OPTIONS+=("$addr" "$desc" "OFF")
    fi
done < <(lspci -nn | grep -E -i "vga|3d|display")

if [ ${#GPU_OPTIONS[@]} -gt 0 ]; then
    GPU_PCI=$(whiptail --title "GPU Selection" --radiolist "Select GPU to pass through:" 15 80 6 "${GPU_OPTIONS[@]}" 3>&1 1>&2 2>&3)
else
    GPU_PCI=$(whiptail --inputbox "No GPUs auto-detected. Enter GPU PCIe Address manually (e.g., 09:00.0):" 10 50 "" 3>&1 1>&2 2>&3)
fi

# Build Wi-Fi options dynamically
WIFI_OPTIONS=()
while IFS= read -r line; do
    if [[ -n "$line" ]]; then
        addr=$(echo "$line" | awk '{print $1}')
        desc=$(echo "$line" | cut -d' ' -f2-)
        WIFI_OPTIONS+=("$addr" "$desc" "OFF")
    fi
done < <(lspci -nn | grep -E -i "network|wireless|wi-fi")

if [ ${#WIFI_OPTIONS[@]} -gt 0 ]; then
    WIFI_PCI=$(whiptail --title "Wi-Fi Selection" --radiolist "Select Wi-Fi adapter to pass through:" 15 80 6 "${WIFI_OPTIONS[@]}" 3>&1 1>&2 2>&3)
else
    WIFI_PCI=$(whiptail --inputbox "No Wi-Fi auto-detected. Enter Wi-Fi PCIe Address manually (e.g., 0a:00.0):" 10 50 "" 3>&1 1>&2 2>&3)
fi

echo "Creating VM $VMID ($VM_NAME)..."

qm create "$VMID" --name "$VM_NAME" \
    --machine q35 \
    --bios ovmf \
    --ostype l26 \
    --cpu host \
    --cores 4 \
    --sockets 1 \
    --memory 8192 \
    --agent 1

qm set "$VMID" --efidisk0 local-lvm:1,format=raw,pre-enrolled-keys=1
qm set "$VMID" --scsihw virtio-scsi-pci
qm set "$VMID" --scsi0 local-lvm:64,discard=on,ssd=1

qm set "$VMID" --net0 virtio,bridge=vmbr0,firewall=1
qm set "$VMID" --ide2 local:iso/bazzite-deck-stable-live-amd64.iso,media=cdrom
qm set "$VMID" --boot order=ide2\;scsi0

if [ -n "${GPU_PCI:-}" ]; then
    echo "Attaching GPU passthrough: $GPU_PCI"
    qm set "$VMID" --hostpci0 "${GPU_PCI},pcie=1,x-vga=1"
fi

if [ -n "${WIFI_PCI:-}" ]; then
    echo "Attaching Wi-Fi passthrough: $WIFI_PCI"
    qm set "$VMID" --hostpci1 "${WIFI_PCI},pcie=1"
fi

echo "Successfully created Bazzite VM ID $VMID!"
