#!/usr/bin/env bash
# Bazzite OS VM Deployer with Automatic PCIe Passthrough Discovery

set -Eeuo pipefail

readonly DEFAULT_CORES=4
readonly DEFAULT_MEMORY=8192
readonly DEFAULT_DISK=64
readonly DEFAULT_VMID=135
readonly DEFAULT_VM_NAME="bazzite-gaming-vm"
readonly DEFAULT_ISO="local:iso/bazzite-deck-stable-live-amd64.iso"

VM_CREATED=0
VMID=""

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    readonly RED=$'\033[0;31m' YELLOW=$'\033[1;33m' GREEN=$'\033[0;32m'
    readonly BLUE=$'\033[0;34m' NC=$'\033[0m'
else
    readonly RED="" YELLOW="" GREEN="" BLUE="" NC=""
fi

log() {
    local level="$1" color="$2"
    shift 2
    printf '%s[%s] [%s]%s %s\n' "$color" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$NC" "$*" >&2
}

log_info() { log INFO "$BLUE" "$@"; }
log_warn() { log WARN "$YELLOW" "$@"; }
log_error() { log ERROR "$RED" "$@"; }
log_success() { log SUCCESS "$GREEN" "$@"; }

on_error() {
    local status="$1" line="$2"
    log_error "Command failed at line $line (exit status $status)."
    if (( VM_CREATED )); then
        log_warn "VM $VMID may be partially configured. Review it with 'qm config $VMID'; remove it with 'qm destroy $VMID' if needed."
    fi
    exit "$status"
}
trap 'on_error "$?" "$LINENO"' ERR

check_dependencies() {
    local cmd
    local missing=()
    for cmd in whiptail qm lspci date; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if ((${#missing[@]})); then
        log_error "Required tools not found: ${missing[*]}"
        log_error "Install the missing tools and run this script again."
        return 1
    fi
    return 0
}

show_message() {
    whiptail --msgbox "$1" 8 "${2:-60}" || true
}

validate_numeric() {
    local value="$1" min="$2" max="$3" description="$4"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        log_error "$description must be a whole number."
        return 1
    fi

    local number=$((10#$value))
    if ((number < min || number > max)); then
        log_error "$description must be between $min and $max."
        return 1
    fi
    printf '%s\n' "$number"
}

prompt_numeric() {
    local description="$1" default="$2" min="$3" max="$4"
    local value validated
    while true; do
        if ! value=$(whiptail --inputbox "$description ($min-$max):" 10 60 "$default" 3>&1 1>&2 2>&3); then
            return 1
        fi
        if validated=$(validate_numeric "$value" "$min" "$max" "$description"); then
            printf '%s\n' "$validated"
            return 0
        fi
        show_message "$description must be a whole number between $min and $max."
    done
}

prompt_required() {
    local description="$1" default="$2"
    local value
    while true; do
        if ! value=$(whiptail --inputbox "$description" 10 60 "$default" 3>&1 1>&2 2>&3); then
            return 1
        fi
        if [[ -n "$value" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
        show_message "$description cannot be empty." 50
    done
}

detect_pcie_devices() {
    local filter="$1" output line address description
    if ! output=$(lspci -nn 2>&1); then
        log_error "Unable to detect PCIe devices: $output"
        return 1
    fi

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if [[ "${line,,}" =~ $filter ]]; then
            address="${line%% *}"
            description="${line#"$address"}"
            description="${description# }"
            printf '%s\n%s\n' "$address" "$description"
        fi
    done <<< "$output"
}

validate_pcie_address() {
    local address="$1" device_info
    if [[ ! "$address" =~ ^([[:xdigit:]]{4}:)?[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]]; then
        log_error "Invalid PCIe address '$address' (expected 09:00.0 or 0000:09:00.0)."
        return 1
    fi
    if ! device_info=$(lspci -s "$address" 2>/dev/null) || [[ -z "$device_info" ]]; then
        log_error "PCIe device '$address' was not found by lspci."
        return 1
    fi
    return 0
}

select_device() {
    local device_type="$1" filter="$2" example="$3"
    local device_data selected address
    local -a options=()

    if ! device_data=$(detect_pcie_devices "$filter"); then
        return 2
    fi
    if [[ -n "$device_data" ]]; then
        mapfile -t options <<< "$device_data"
    fi

    while true; do
        if ((${#options[@]})); then
            if ! selected=$(whiptail --title "$device_type Selection" \
                --menu "Select a $device_type to pass through, or choose Skip:" \
                15 80 6 "${options[@]}" "SKIP" "Do not pass through $device_type" \
                3>&1 1>&2 2>&3); then
                log_info "$device_type selection cancelled; skipping passthrough."
                return 1
            fi
            if [[ "$selected" == "SKIP" ]]; then
                log_info "Skipping $device_type passthrough."
                return 1
            fi
            address="$selected"
        else
            log_warn "No $device_type devices were detected."
            if ! whiptail --yesno "No $device_type was detected. Enter a PCIe address manually?" 10 60; then
                log_info "Skipping $device_type passthrough."
                return 1
            fi
            if ! address=$(whiptail --inputbox "Enter the $device_type PCIe address (for example, $example):" \
                10 60 "$example" 3>&1 1>&2 2>&3); then
                log_info "Manual $device_type selection cancelled; skipping passthrough."
                return 1
            fi
        fi

        if validate_pcie_address "$address"; then
            printf '%s\n' "$address"
            return 0
        fi
        show_message "Invalid or unavailable PCIe address. Select a detected device or enter an existing address." 70
        if ((${#options[@]} == 0)); then
            continue
        fi
    done
}

normalize_pcie_address() {
    local address="$1"
    if [[ "$address" =~ ^[[:xdigit:]]{4}: ]]; then
        printf '%s\n' "${address,,}"
    else
        printf '0000:%s\n' "${address,,}"
    fi
}

iommu_group_for() {
    local address="$1" group_dir normalized
    normalized=$(normalize_pcie_address "$address")
    for group_dir in /sys/kernel/iommu_groups/*/devices; do
        if [[ -e "$group_dir/$normalized" ]]; then
            printf '%s\n' "${group_dir%/devices}"
            return 0
        fi
    done
    return 1
}

confirm_passthrough_warnings() {
    local gpu="$1" wifi="$2" group group_id member normalized_member address
    local message
    local -a selected=() group_members=() unselected=()
    local -A seen_groups=()

    [[ -n "$gpu" ]] && selected+=("$gpu")
    [[ -n "$wifi" ]] && selected+=("$wifi")
    ((${#selected[@]})) || return 0

    for address in "${selected[@]}"; do
        if ! group=$(iommu_group_for "$address"); then
            log_warn "No IOMMU group found for $address; passthrough may not work."
            if ! whiptail --yesno "No IOMMU group was found for $address. Passthrough may fail. Continue anyway?" 10 70; then
                return 1
            fi
            continue
        fi

        group_id="${group##*/}"
        [[ -n "${seen_groups[$group_id]:-}" ]] && continue
        seen_groups[$group_id]=1
        group_members=()
        unselected=()
        for member in "$group"/devices/*; do
            [[ -e "$member" ]] || continue
            group_members+=("${member##*/}")
        done
        for member in "${group_members[@]}"; do
            normalized_member=$(normalize_pcie_address "$member")
            local included=0 selected_address
            for selected_address in "${selected[@]}"; do
                if [[ "$normalized_member" == "$(normalize_pcie_address "$selected_address")" ]]; then
                    included=1
                    break
                fi
            done
            ((included)) || unselected+=("$member")
        done

        if ((${#unselected[@]})); then
            message="IOMMU group $group_id also contains unselected device(s): ${unselected[*]}. The group may not be safely isolated for passthrough. Continue?"
            log_warn "$message"
            if ! whiptail --yesno "$message" 12 75; then
                return 1
            fi
        fi
    done

    if [[ -n "$gpu" && -n "$wifi" ]]; then
        local gpu_group wifi_group
        gpu_group=$(iommu_group_for "$gpu" || true)
        wifi_group=$(iommu_group_for "$wifi" || true)
        if [[ -n "$gpu_group" && "$gpu_group" == "$wifi_group" ]]; then
            message="The selected GPU and Wi-Fi device share IOMMU group ${gpu_group##*/}. Continue with both devices in the same group?"
            log_warn "$message"
            if ! whiptail --yesno "$message" 10 75; then
                return 1
            fi
        fi
    fi
    return 0
}

run_qm() {
    if "$@"; then
        return 0
    fi
    log_error "Failed command: $*"
    if ((VM_CREATED)); then
        log_warn "VM $VMID may be partially configured. Review it with 'qm config $VMID'; remove it with 'qm destroy $VMID' if needed."
    fi
    return 1
}

create_vm() {
    local vm_name="$1" cores="$2" memory="$3" disk_size="$4"
    local gpu="$5" wifi="$6" iso_path="$7"

    log_info "Creating VM $VMID ($vm_name): $cores cores, ${memory} MB RAM, ${disk_size} GB disk."
    if qm create "$VMID" --name "$vm_name" \
        --machine q35 --bios ovmf --ostype l26 --cpu host \
        --cores "$cores" --sockets 1 --memory "$memory" --agent 1; then
        VM_CREATED=1
    else
        log_error "Failed to create VM $VMID."
        return 1
    fi

    run_qm qm set "$VMID" --efidisk0 local-lvm:1,format=raw,pre-enrolled-keys=1
    run_qm qm set "$VMID" --scsihw virtio-scsi-pci
    run_qm qm set "$VMID" --scsi0 "local-lvm:${disk_size},discard=on,ssd=1"
    run_qm qm set "$VMID" --net0 virtio,bridge=vmbr0,firewall=1

    if [[ -n "$iso_path" ]]; then
        run_qm qm set "$VMID" --ide2 "${iso_path},media=cdrom"
        run_qm qm set "$VMID" --boot 'order=ide2;scsi0'
    else
        run_qm qm set "$VMID" --boot order=scsi0
    fi

    if [[ -n "$gpu" ]]; then
        log_info "Attaching GPU passthrough: $gpu"
        run_qm qm set "$VMID" --hostpci0 "${gpu},pcie=1,x-vga=1"
    fi
    if [[ -n "$wifi" ]]; then
        log_info "Attaching Wi-Fi passthrough: $wifi"
        run_qm qm set "$VMID" --hostpci1 "${wifi},pcie=1"
    fi

    log_success "Successfully created Bazzite VM ID $VMID."
    log_info "Start the VM with: qm start $VMID"
}

main() {
    check_dependencies
    log_info "=== Bazzite OS VM Builder ==="

    local vm_name cores memory disk_size gpu="" wifi="" iso_path="" status
    if ! VMID=$(prompt_numeric "VM ID" "$DEFAULT_VMID" 100 999999999); then
        log_info "VM ID entry cancelled; no VM was created."
        return 0
    fi
    if ! vm_name=$(prompt_required "VM name" "$DEFAULT_VM_NAME"); then
        log_info "VM name entry cancelled; no VM was created."
        return 0
    fi
    if ! cores=$(prompt_numeric "CPU cores" "$DEFAULT_CORES" 1 128); then
        log_info "CPU configuration cancelled; no VM was created."
        return 0
    fi
    if ! memory=$(prompt_numeric "Memory (MB)" "$DEFAULT_MEMORY" 512 1048576); then
        log_info "Memory configuration cancelled; no VM was created."
        return 0
    fi
    if ! disk_size=$(prompt_numeric "Disk size (GB)" "$DEFAULT_DISK" 10 10000); then
        log_info "Disk configuration cancelled; no VM was created."
        return 0
    fi

    if gpu=$(select_device "GPU" 'vga|3d|display' "09:00.0"); then
        :
    else
        status=$?
        ((status == 1)) || return "$status"
    fi
    if wifi=$(select_device "Wi-Fi" 'network|wireless|wi-fi' "0a:00.0"); then
        :
    else
        status=$?
        ((status == 1)) || return "$status"
    fi

    if [[ -n "$gpu" && -n "$wifi" && "$(normalize_pcie_address "$gpu")" == "$(normalize_pcie_address "$wifi")" ]]; then
        log_error "GPU and Wi-Fi cannot use the same PCIe address."
        return 1
    fi
    if ! confirm_passthrough_warnings "$gpu" "$wifi"; then
        log_info "Passthrough validation declined; no VM was created."
        return 0
    fi

    if iso_path=$(whiptail --inputbox "ISO storage path (leave blank to boot from disk):" \
        10 80 "$DEFAULT_ISO" 3>&1 1>&2 2>&3); then
        :
    else
        log_info "ISO selection cancelled; VM will boot from disk."
        iso_path=""
    fi

    local summary
    printf -v summary 'VM ID: %s\nName: %s\nCPU cores: %s\nMemory: %s MB\nDisk: %s GB\nGPU passthrough: %s\nWi-Fi passthrough: %s\nISO: %s' \
        "$VMID" "$vm_name" "$cores" "$memory" "$disk_size" "${gpu:-none}" "${wifi:-none}" "${iso_path:-none}"
    log_info "=== Configuration Summary ==="
    log_info "VM ID: $VMID | Name: $vm_name | CPU: $cores cores | Memory: ${memory} MB | Disk: ${disk_size} GB"
    log_info "GPU: ${gpu:-none} | Wi-Fi: ${wifi:-none} | ISO: ${iso_path:-none}"
    if ! whiptail --yesno "$(printf 'Create this Bazzite VM with the following configuration?\n\n%s' "$summary")" 18 75; then
        log_info "VM creation cancelled."
        return 0
    fi

    create_vm "$vm_name" "$cores" "$memory" "$disk_size" "$gpu" "$wifi" "$iso_path"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
