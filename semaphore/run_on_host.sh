#!/usr/bin/env bash
# ==============================================================================
# SCRIPT: run_on_host.sh
# FORMÅL: Tillader Semaphore UI (hvis det kører i en Docker-container) at
#         afvikle deploy.sh direkte på Proxmox-hosten (vmh01) via SSH.
# ==============================================================================
set -euo pipefail

# Docker bridge standard gateway til hosten er typisk 172.17.0.1
TARGET_HOST="${PROXMOX_HOST:-172.17.0.1}"

# Afvikl deploy.sh på Proxmox værten med alle givne argumenter
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$TARGET_HOST" "/root/proxmox-deploy/deploy.sh $*"
