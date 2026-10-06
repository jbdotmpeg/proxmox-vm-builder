#!/usr/bin/env bash
# Regenerate SHA256SUMS for the scripts install.sh downloads.
cd "$(dirname "${BASH_SOURCE[0]}")" && sha256sum host-setup.sh vms/*.sh > SHA256SUMS
