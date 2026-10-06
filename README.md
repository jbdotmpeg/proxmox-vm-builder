# Proxmox Universal VM & Passthrough Builder (`proxmox-vm-builder`)

A modular Python orchestrator for Proxmox VE designed to quickly spin up custom virtual machines (such as **Bazzite OS**, generic Linux distributions, or Windows nodes) with advanced hardware topologies including **q35 architecture**, **UEFI (OVMF) firmware**, and dynamic **PCIe GPU/Wi-Fi passthrough**.

## Features
* **Multi-OS Profile Support:** Tailored configuration paths for Bazzite, Linux, and Windows VMs.
* **Dynamic Passthrough Selection:** Automatically parses host `lspci` outputs to let you choose and inject GPU or Wi-Fi hardware controller addresses directly into the VM configuration (`hostpciX`).
* **Whiptail TUI Dashboard:** Simple text-based user interface designed specifically for Proxmox administrative shells.
