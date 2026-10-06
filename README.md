# Proxmox Universal VM & Passthrough Builder (`proxmox-vm-builder`)

A modular Python orchestrator for Proxmox VE designed to quickly spin up custom virtual machines (such as **Bazzite OS**, generic Linux distributions, or Windows nodes) with advanced hardware topologies including **q35 architecture**, **UEFI (OVMF) firmware**, and dynamic **PCIe GPU/Wi-Fi passthrough**.

## Features
* **Multi-OS Profile Support:** Tailored configuration paths for Bazzite, Linux, and Windows VMs.
* **Dynamic Passthrough Selection:** Automatically parses host `lspci` outputs to let you choose and inject GPU or Wi-Fi hardware controller addresses directly into the VM configuration (`hostpciX`).
* **Whiptail TUI Dashboard:** Simple text-based user interface designed specifically for Proxmox administrative shells.

## Proxmox host setup for PCIe passthrough

The VM builder configures the guest only. It does not change host boot settings, bind devices to VFIO, or reboot Proxmox. Complete and verify the host setup first. Keep console or out-of-band access available: binding a GPU or Wi-Fi adapter can disconnect services that depend on that device.

1. **Enable IOMMU in firmware.** Enable Intel VT-d or AMD-Vi/IOMMU in the server BIOS/UEFI.

2. **Enable IOMMU in the Proxmox kernel command line.** Preserve existing options and add the matching parameters:

   - **GRUB:** Add `intel_iommu=on iommu=pt` for Intel, or `amd_iommu=on iommu=pt` for AMD, to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`; then run `update-grub`.
   - **systemd-boot:** Add the matching parameters to the existing single line in `/etc/kernel/cmdline`; then run `proxmox-boot-tool refresh`.

   Reboot Proxmox after changing the kernel command line.

3. **Check the devices and their IOMMU groups.** Use `lspci -nnk` to identify the exact GPU and Wi-Fi PCIe functions and their vendor/device IDs. After reboot, verify that IOMMU groups exist:

   ```bash
   dmesg | grep -Ei 'DMAR|IOMMU|AMD-Vi'
   find /sys/kernel/iommu_groups -type l -print
   ```

   All devices in a selected IOMMU group must be safe to assign together. Do not pass through a group containing host devices you still need. Avoid ACS override patches as a substitute for proper isolation in production.

4. **Bind only the intended devices to VFIO when needed.** Current Proxmox kernels often load VFIO on demand; if needed, ensure `vfio`, `vfio_iommu_type1`, and `vfio_pci` are loaded during boot (for example, list them in `/etc/modules`). To bind particular PCI IDs early, create `/etc/modprobe.d/vfio.conf` with the IDs reported by `lspci -nnk`, for example:

   ```text
   options vfio-pci ids=vvvv:dddd,vvvv:dddd
   ```

   Include every required function of a GPU, such as its audio function, when applicable. An ID rule can bind every device with that ID, not just one PCI address. Avoid broadly blacklisting GPU or network drivers; this can remove the host console or network interface. Rebuild the initramfs after VFIO configuration changes:

   ```bash
   update-initramfs -u -k all
   ```

   Reboot, then use `lspci -nnk -s <PCI-address>` to confirm the intended device is using `vfio-pci`.

5. **Keep host networking available.** A PCIe Wi-Fi adapter assigned to the VM is no longer available to Proxmox. Do not pass through the adapter carrying the host's management connection; use a separate wired or out-of-band management path.

Once the host is ready, run the Bazzite VM builder and select the verified PCIe devices. The script checks IOMMU-group membership and warns about missing groups or unselected group members, but it cannot make unsafe groups isolated.
