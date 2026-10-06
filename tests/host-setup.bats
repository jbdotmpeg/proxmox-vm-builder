#!/usr/bin/env bats

setup() {
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin" "$T/sys/kernel/iommu_groups/1"
    export PATH="$T/bin:$PATH"
    export PROC_CPUINFO="$T/cpuinfo" PROC_CMDLINE="$T/cmdline" SYS_ROOT="$T/sys"
    export GRUB_FILE="$T/grub" CMDLINE_FILE="$T/kcmdline" MODULES_FILE="$T/modules"
    export VFIO_CONF="$T/vfio.conf" BACKUP_DIR="$T/backups"
    echo "vendor_id : GenuineIntel" > "$PROC_CPUINFO"
    echo "BOOT_IMAGE=/vmlinuz root=/dev/x intel_iommu=on iommu=pt" > "$PROC_CMDLINE"
    printf '#!/bin/sh\necho "pve-manager/8.2.2/abc (running kernel: 6.8)"\n' > "$T/bin/pveversion"
    printf '#!/bin/sh\nexit 0\n' > "$T/bin/lspci"
    printf '#!/bin/sh\nexit 0\n' > "$T/bin/update-grub"
    printf '#!/bin/sh\nexit 0\n' > "$T/bin/update-initramfs"
    printf '#!/bin/sh\nexit 1\n' > "$T/bin/proxmox-boot-tool"
    printf '#!/bin/sh\nexit 0\n' > "$T/bin/lsmod"
    chmod +x "$T"/bin/*
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"' > "$GRUB_FILE"
    : > "$MODULES_FILE"
    SCRIPT="$BATS_TEST_DIRNAME/../host-setup.sh"
}

@test "check reports not ready when VFIO modules are missing" {
    run "$SCRIPT" --check
    [ "$status" -eq 3 ] || { echo "$output"; false; }
    [[ "$output" == *"Detected pve-manager/8.2.2"* ]]
    [[ "$output" == *"CPU vendor: Intel"* ]]
}

@test "check fails without Proxmox" {
    rm "$T/bin/pveversion"
    run env PATH="$T/bin:/usr/bin:/bin" "$SCRIPT" --check
    [ "$status" -ne 0 ]
}

@test "--yes adds params and modules, backs up, and --revert restores" {
    [ "$EUID" -eq 0 ] || skip "requires root"
    run "$SCRIPT" --yes
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -q 'intel_iommu=on iommu=pt"' "$GRUB_FILE"
    grep -qx vfio_pci "$MODULES_FILE"
    run "$SCRIPT" --yes --revert
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -qx 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"' "$GRUB_FILE"
}

@test "multi-line /etc/kernel/cmdline is not edited" {
    [ "$EUID" -eq 0 ] || skip "requires root"
    printf '#!/bin/sh\necho "systemd-boot"\n' > "$T/bin/proxmox-boot-tool"
    printf 'a\nb\n' > "$CMDLINE_FILE"
    run "$SCRIPT" --yes
    [ "$(cat "$CMDLINE_FILE")" = "$(printf 'a\nb')" ]
}

@test "unknown option is rejected" {
    run "$SCRIPT" --bogus
    [ "$status" -ne 0 ]
}
