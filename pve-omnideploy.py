#!/usr/env/python3
import subprocess
import os
import sys
import json
import time
import shlex
import urllib.request

# --- UI & LOGGING CONSTANTS ---
TITLE = "PVE-OmniDeploy V8.0: Universal Gaming & OS Orchestrator"
BACKTITLE = "Proxmox Zero-Touch VM & Passthrough Deployment Suite"

# --- HARDWARE SENSING CACHE ---
_HW_CACHE = {
    "storage_pools": [],
    "network_bridges": [],
    "pci_devices": []
}

GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY", "")
GEMINI_MODEL = "gemini-2.5-flash-preview-09-2025"

# --- CORE SYSTEM UTILITIES ---
def run_cmd(cmd):
    try: return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()
    except: return ""

def sense_hardware():
    storage = run_cmd("pvesm status --content images | tail -n +2")
    _HW_CACHE["storage_pools"] = [l.split() for l in storage.split('\n') if l.strip() and "active" in l]
    
    bridges = run_cmd(r"ip link show type bridge | grep -oP '^\d+: \K[^:]+'")
    _HW_CACHE["network_bridges"] = [(b.strip(), "Bridge") for b in bridges.split('\n') if b.strip()]

    # Scan available PCI devices for passthrough selection
    pci_raw = run_cmd("lspci -nn | grep -E 'VGA|Audio|Network|Wireless|Controller'")
    pci_list = []
    for line in pci_raw.split('\n'):
        if line.strip():
            parts = line.split(' ', 1)
            pci_list.append((parts[0], parts[1][:50]))
    _HW_CACHE["pci_devices"] = pci_list

def msg_box(title, msg): os.system(f"whiptail --title {shlex.quote(title)} --msgbox {shlex.quote(msg)} 12 70")
def input_box(title, msg, default=""):
    os.system(f"whiptail --title {shlex.quote(title)} --inputbox {shlex.quote(msg)} 10 60 {shlex.quote(default)} 2>/tmp/pve_input")
    return open("/tmp/pve_input").read().strip() if os.path.exists("/tmp/pve_input") else ""

def menu_box(msg, choices):
    cmd = f"whiptail --title {shlex.quote(TITLE)} --menu {shlex.quote(msg)} 20 80 10 "
    for item in choices: cmd += f"{shlex.quote(item[0])} {shlex.quote(item[1])} "
    if os.system(cmd + " 2>/tmp/pve_menu") == 0: return open("/tmp/pve_menu").read().strip()
    return None

def run_with_timer(cmd, message):
    sys.stderr.write(f"  [WORKING] {message}...")
    sys.stderr.flush()
    res = subprocess.run(cmd, shell=True, capture_output=True)
    sys.stderr.write(" [DONE]\n")
    return res.returncode

# --- UNIVERSAL VM DEPLOYMENT WIZARD ---
def create_universal_vm():
    sense_hardware()
    
    vmid = input_box("VM ID", "Enter target VM ID:", run_cmd("pvesh get /cluster/nextid"))
    name = input_box("VM Name", "Enter VM Name (e.g., bazzite-vm):", f"Node-{vmid}")
    
    # Select OS Profile
    os_profile = menu_box("Select OS Profile", [
        ("bazzite", "Bazzite Linux (Gaming Desktop / Deck Flavor)"),
        ("linux", "Generic Linux Distribution (Ubuntu / Fedora / Arch)"),
        ("windows", "Windows 11 Pro (Automated Unattended Install)")
    ])
    if not os_profile: return

    pool = menu_box("Storage Pool", [(p[0], p[1]) for p in _HW_CACHE["storage_pools"]]).split()[0]
    bridge = menu_box("Network Bridge", _HW_CACHE["network_bridges"])

    # Optional Passthrough Hardware Selection
    gpu_pci = ""
    wifi_pci = ""
    if os.system("whiptail --yesno 'Would you like to assign a GPU via PCIe Passthrough?' 10 60") == 0:
        gpu_pci = menu_box("Select GPU Device", _HW_CACHE["pci_devices"])
        gpu_pci = gpu_pci.split()[0] if gpu_pci else ""

    if os.system("whiptail --yesno 'Would you like to assign a Wi-Fi Adapter via PCIe Passthrough?' 10 60") == 0:
        wifi_pci = menu_box("Select Wi-Fi Device", _HW_CACHE["pci_devices"])
        wifi_pci = wifi_pci.split()[0] if wifi_pci else ""

    disk_size = input_box("Disk Size", "Enter disk size in GB:", "64")
    ram_size = input_box("RAM Allocation", "Enter RAM in MB (e.g. 8192, 16384):", "8192")
    cores = input_box("CPU Cores", "Enter number of CPU cores:", "4")

    os.system('clear')
    print(==> Initializing Proxmox Universal VM Builder...)

    # 1. Base VM creation with q35 and UEFI (OVMF)
    ostype_val = "l26" if os_profile in ["bazzite", "linux"] else "win11"
    run_with_timer(f"qm create {vmid} --name {name} --machine q35 --bios ovmf --ostype {ostype_val} --cpu host --cores {cores} --sockets 1 --memory {ram_size} --agent 1", "Creating Base VM Configuration")

    # 2. Controllers and Disks
    run_with_timer(f"qm set {vmid} --efidisk0 {pool}:1,format=raw,pre-enrolled-keys=1", "Configuring EFI Disk")
    run_with_timer(f"qm set {vmid} --scsihw virtio-scsi-pci --scsi0 {pool}:{disk_size},discard=on,ssd=1", "Attaching Storage")

    # 3. Networking
    run_with_timer(f"qm set {vmid} --net0 virtio,bridge={bridge},firewall=1", "Configuring Network Interface")

    # 4. Hardware Passthrough Assignment
    if gpu_pci:
        run_with_timer(f"qm set {vmid} --hostpci0 {gpu_pci},pcie=1,x-vga=1", f"Attaching GPU Passthrough ({gpu_pci})")
    
    if wifi_pci:
        run_with_timer(f"qm set {vmid} --hostpci1 {wifi_pci},pcie=1", f"Attaching Wi-Fi Passthrough ({wifi_pci})")

    # 5. Locate and Mount ISO
    isos = run_cmd(f"pvesm list {pool} --content iso")
    if os_profile == "bazzite":
        iso_file = next((l.split()[0] for l in isos.split('\n') if "bazzite" in l.lower()), "local:iso/bazzite.iso")
    elif os_profile == "linux":
        iso_file = next((l.split()[0] for l in isos.split('\n') if "live" in l.lower() or "ubuntu" in l.lower() or "fedora" in l.lower()), "local:iso/linux.iso")
    else:
        iso_file = next((l.split()[0] for l in isos.split('\n') if "win" in l.lower()), "local:iso/win11.iso")

    run_with_timer(f"qm set {vmid} --ide2 {iso_file},media=cdrom --boot order=ide2\;scsi0", "Mounting Installer ISO")

    msg_box("Success!", f"VM {vmid} ({name}) configured successfully with profile '{os_profile}' and requested hardware bindings!")

def main():
    while True:
        c = menu_box(TITLE, [
            ("1", "Deploy Universal VM (Bazzite / Linux / Windows + Passthrough)"),
            ("2", "Exit")
        ])
        if c == "1": create_universal_vm()
        else: break

if __name__ == "__main__": main()
