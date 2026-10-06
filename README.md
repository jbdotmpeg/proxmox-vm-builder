# Proxmox Universal VM & Passthrough Builder (`proxmox-vm-builder`)

A modular Python orchestrator for Proxmox VE designed to quickly spin up custom virtual machines (such as **Bazzite OS**, generic Linux distributions, or Windows nodes) with advanced hardware topologies including **q35 architecture**, **UEFI (OVMF) firmware**, and dynamic **PCIe GPU/Wi-Fi passthrough**.

## Features
* **Multi-OS Profile Support:** Tailored configuration paths for Bazzite, Linux, and Windows VMs.
* **Dynamic Passthrough Selection:** Automatically parses host `lspci` outputs to let you choose and inject GPU or Wi-Fi hardware controller addresses directly into the VM configuration (`hostpciX`).
* **Whiptail TUI Dashboard:** Simple text-based user interface designed specifically for Proxmox administrative shells.

## Proxmox host setup for PCIe passthrough

The VM builder configures the guest only. It does not change host boot settings, bind devices to VFIO, or reboot Proxmox. Complete and verify the host setup first. Keep console or out-of-band access available: binding a GPU or Wi-Fi adapter can disconnect services that depend on that device.

These host-side IOMMU/VFIO steps apply to passthrough for Windows and Linux guests alike. The current `vms/bazzite-vm.sh` profile specifically creates a Bazzite VM; another operating system needs its own VM configuration and in-guest device drivers, but can use the same host preparation.

**Automated option:** run `host-setup.sh` (or menu option 4 in `install.sh`) as root on the Proxmox host. It detects Proxmox, CPU vendor, boot loader, IOMMU state and VFIO modules, lists GPUs/Wi-Fi/NICs with their IOMMU group and driver (flagging the management NIC and host console GPU), checks for Above-4G BARs, and with confirmation applies the kernel parameters and VFIO modules. Firmware IOMMU (step 1) must still be enabled manually.

* `--check` reports only (exit 3 if not ready); `--yes` runs unattended (no reboot).
* `--bind 09:00.0,0a:00.0` writes `options vfio-pci ids=...` to `/etc/modprobe.d/vfio.conf`, including a GPU's audio function, and refuses to bind the management NIC. Without `--yes` it offers a device checklist.
* Every edited file is backed up under `/var/backups/proxmox-vm-builder`; `--revert` restores the latest backups. A multi-line `/etc/kernel/cmdline` is never auto-edited.

**Installer:** `install.sh` verifies each downloaded script against `SHA256SUMS` before running it. Pin a release with `PVMB_REF=<tag-or-commit> bash install.sh`. After changing a script run `./update-checksums.sh`. The VM scripts (`vms/bazzite-vm.sh`, `generic-linux-vm.sh`, `windows-vm.sh`) check host readiness first and list ISOs found on Proxmox storage for selection.

1. **Enable IOMMU in firmware.** Enable Intel VT-d or AMD-Vi/IOMMU in the server BIOS/UEFI.

2. **Enable IOMMU in the Proxmox kernel command line.** Preserve existing options and add the matching parameters:

   Run `proxmox-boot-tool status` to check whether Proxmox manages the systemd-boot entries; use the corresponding procedure below.

   - **GRUB:** Add `intel_iommu=on iommu=pt` for Intel, or `amd_iommu=on iommu=pt` for AMD, to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`; then run `update-grub`.
   - **systemd-boot:** Add the matching parameters to the existing single line in `/etc/kernel/cmdline`; then run `proxmox-boot-tool refresh`.

   Reboot Proxmox after changing the kernel command line.

3. **Check the devices and their IOMMU groups.** Before changing bindings, record the exact GPU and Wi-Fi PCIe addresses, vendor/device IDs, and current drivers:

   ```bash
   lspci -nnk
   ```

   After reboot, verify that IOMMU groups exist and inspect which devices share each group:

   ```bash
   cat /proc/cmdline
   dmesg | grep -Ei 'DMAR|IOMMU|AMD-Vi'
   find /sys/kernel/iommu_groups -type l -print
   ```

   All devices in a selected IOMMU group must be safe to assign together. Do not pass through a group containing host devices you still need. Avoid ACS override patches as a substitute for proper isolation in production.

4. **Bind only the intended devices to VFIO when needed.** Do this only if the host driver claims a device that needs to be reserved for the VM. Current Proxmox kernels often load VFIO on demand; if needed, ensure `vfio`, `vfio_iommu_type1`, and `vfio_pci` are loaded during boot (for example, list them in `/etc/modules`). To bind particular PCI IDs early, create `/etc/modprobe.d/vfio.conf` with the IDs reported by `lspci -nnk`, for example:

   ```text
   options vfio-pci ids=vvvv:dddd,vvvv:dddd
   ```

   Include every required function of a GPU, such as its audio function, when applicable. An ID rule can bind every device with that ID, not just one PCI address. Avoid broadly blacklisting GPU or network drivers; this can remove the host console or network interface. Rebuild the initramfs after VFIO configuration changes:

   ```bash
   update-initramfs -u -k all
   ```

   Reboot, then use `lspci -nnk -s <PCI-address>` to confirm the intended device is using `vfio-pci`.

   If a reboot leaves a required host device unavailable, use the local console, revert the VFIO ID/module changes, rebuild the initramfs, and reboot again.

5. **Keep host networking available.** A PCIe Wi-Fi adapter assigned to the VM is no longer available to Proxmox. Do not pass through the adapter carrying the host's management connection; use a separate wired or out-of-band management path.

The builder requires `whiptail`, `qm`, `lspci`, and `date` and prompts for VM resources, ISO, and optional passthrough devices. On Proxmox, `lspci` is provided by `pciutils`. Once the host is ready, run it from a Proxmox root shell and select the verified PCIe devices. The script checks IOMMU-group membership and warns about missing groups or unselected group members, but it cannot make unsafe groups isolated.

For version-specific details, see the [Proxmox PCI(e) passthrough wiki](https://pve.proxmox.com/wiki/PCI_Passthrough).

## Troubleshooting

* **NVIDIA "Code 43" in a Windows guest:** use `--cpu host`, a q35/OVMF VM with the GPU as `pcie=1,x-vga=1`, include the GPU's audio function, and install current drivers. Make sure Above-4G decoding is enabled.
* **GPU won't reset / VM hangs after a guest reboot:** some cards (notably older AMD) have reset bugs. Power-cycle the host, update the BIOS, or try a vendor-reset module; stop the VM fully rather than rebooting it.
* **Devices share an IOMMU group:** pass through every device in the group or move the card to another slot. ACS override is a last resort and weakens isolation.
* **Host console disappears:** the boot GPU was bound to `vfio-pci`. Use the local console and run `host-setup.sh --revert`.
