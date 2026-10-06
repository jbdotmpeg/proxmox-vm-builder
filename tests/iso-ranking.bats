#!/usr/bin/env bats

@test "profile-matching ISOs are listed first" {
    source "$BATS_TEST_DIRNAME/../vms/generic-linux-vm.sh"
    run rank_isos <<< $'local:iso/win11.iso\n5000 MB\nlocal:iso/ubuntu.iso\n3000 MB'
    [ "${lines[0]}" = "local:iso/ubuntu.iso" ]
    [[ "${lines[1]}" == *recommended* ]]
    [ "${lines[2]}" = "local:iso/win11.iso" ]
}
