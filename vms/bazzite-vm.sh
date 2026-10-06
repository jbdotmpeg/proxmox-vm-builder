#!/usr/bin/env bash
# Bazzite OS VM Deployer with PCIe Passthrough Support

set -euo pipefail

echo "=== Bazzite OS VM Builder ==="

# Prompt for user choices or defaults matching community UX style
VMID=$(whiptail --inputbox "Enter VM ID for Bazzite:" 10 50 "135" 3>&1 1>&2 2>&3)
VM_NAME=$(whiptail --inputbox "Enter VM Name:" 10 50 "bazzite-gaming-vm" 3>&1 1>&2 2>&3)
GPU_PCI=$(whiptail --inputbox "Enter GPU PCIe Address (e.g., 0a:00.0):" 10 50 "" 3>&1 1>&2 2>&3)
WIFI_PCI=$(whiptail --inputbox "Enter Wi-Fi PCIe Address (e.g., 0b:00.0):" 10 50 "" 3>&1 1>&2 2>&3)

echo "Creating VM $VMID ($VM_NAME)..."

# 1. Create base VM configuration
qm create "$VMID" --name "$VM_NAME" \
    --machine q35 \
    --bios ovmf \
    --ostype l26 \
    --cpu host \
    --cores 4 \
    --sockets 1 \
    --memory 8192 \
    --agent 1

# 2. EFI and Storage
qm set "$VMID" --efidisk0 local-lvm:1,format=raw,pre-enrolled-keys=1
qm set "$VMID" --scsihw virtio-scsi-pci
qm set "$VMID" --scsi0 local-lvm:64,discard=on,ssd=1

# 3. Network and ISO
qm set "$VMID" --net0 virtio,bridge=vmbr0,firewall=1
qm set "$VMID" --ide2 local:iso/bazzite-deck-stable-live-amd64.iso,media=cdrom
qm set "$VMID" --boot order=ide2\;scsi0

# 4. Passthrough Handling
if [ -n "$GPU_PCI" ]; then
    echo "Attaching GPU passthrough: $GPU_PCI"
    qm set "$VMID" --hostpci0 "${GPU_PCI},pcie=1,x-vga=1"
fi

if [ -n "$WIFI_PCI" ]; then
    echo "Attaching Wi-Fi passthrough: $WIFI_PCI"
    qm set "$VMID" --hostpci1 "${WIFI_PCI},pcie=1"
fi

echo "Successfully created Bazzite VM ID $VMID!"
