#!/usr/bin/env bash
# ==============================================================================
# SCRIPT: create_template_vm.sh
# FORMÅL: Henter Ubuntu 25/26 Cloud Image og bygger en generisk Proxmox VM-template
# ANVENDELSE: ./create_template_vm.sh [RELEASE] [STORAGE] [TEMPLATE_ID]
# EKSEMPEL:   ./create_template_vm.sh resolute local-lvm 9000
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# 1. KONFIGURATION & STANDARDVÆRDIER
# ------------------------------------------------------------------------------
# Vælg mellem:
#   - 'resolute' = Ubuntu 26.04 LTS
#   - 'questing' = Ubuntu 25.10
#   - 'noble'    = Ubuntu 24.04 LTS
RELEASE="${1:-resolute}"
STORAGE="${2:-local-lvm}"
TEMPLATE_ID="${3:-9000}"
TEMPLATE_NAME="ubuntu-${RELEASE}-cloudinit-template"

IMAGE_URL="https://cloud-images.ubuntu.com/${RELEASE}/current/${RELEASE}-server-cloudimg-amd64.img"
IMAGE_FILE="/tmp/${RELEASE}-server-cloudimg-amd64.img"

echo "=========================================================================="
echo "  OPRETTER CLOUD-INIT VM TEMPLATE FOR UBUNTU (${RELEASE^^})               "
echo "=========================================================================="
echo "  Template ID:   $TEMPLATE_ID"
echo "  Template Navn: $TEMPLATE_NAME"
echo "  Storage Pool:  $STORAGE"
echo "  Billede URL:   $IMAGE_URL"
echo "=========================================================================="

# ------------------------------------------------------------------------------
# 2. DOWNLOAD CLOUD IMAGE
# ------------------------------------------------------------------------------
echo "=== [1/6] Downloader Ubuntu Cloud Image ($RELEASE) ==="
if [ ! -f "$IMAGE_FILE" ]; then
    echo "Henter image fra $IMAGE_URL..."
    wget -q --show-progress "$IMAGE_URL" -O "$IMAGE_FILE"
else
    echo "Cloud image findes allerede i $IMAGE_FILE (genbruger fil)."
fi

# ------------------------------------------------------------------------------
# 3. KONTROLLER OG OPRET BASIS VM
# ------------------------------------------------------------------------------
echo "=== [2/6] Opretter basis KVM VM ($TEMPLATE_ID) ==="
if qm status "$TEMPLATE_ID" &>/dev/null; then
    echo "Advarsel: VM/Template med ID $TEMPLATE_ID findes allerede."
    read -rp "Vil du overskrive/slette eksisterende template? [y/N]: " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        qm destroy "$TEMPLATE_ID" --purge
    else
        echo "Afbryder oprettelse."
        exit 0
    fi
fi

# Opretter VM med VirtIO optimeringer
qm create "$TEMPLATE_ID" \
    --name "$TEMPLATE_NAME" \
    --memory 2048 \
    --cores 2 \
    --cpu host \
    --net0 virtio,bridge=vmbr0 \
    --scsihw virtio-scsi-pci \
    --ostype l26

# ------------------------------------------------------------------------------
# 4. IMPORTER DISK TIL STORAGE
# ------------------------------------------------------------------------------
echo "=== [3/6] Importerer disk til storage: $STORAGE ==="
qm importdisk "$TEMPLATE_ID" "$IMAGE_FILE" "$STORAGE"

# Find det nøjagtige navn på den importerede disk og tilknyt den til scsi0
DISK_NAME=$(pvesm list "$STORAGE" | grep "vm-$TEMPLATE_ID-disk" | awk '{print $1}' | head -n 1)
if [ -z "$DISK_NAME" ]; then
    DISK_NAME="$STORAGE:vm-$TEMPLATE_ID-disk-0"
fi
echo "Tilknytter disk: $DISK_NAME"
qm set "$TEMPLATE_ID" --scsi0 "$DISK_NAME,discard=on,ssd=1"

# ------------------------------------------------------------------------------
# 5. OPRET CLOUD-INIT DREV, BOOT ORDER & SERIEL KONSOL
# ------------------------------------------------------------------------------
echo "=== [4/6] Opretter Cloud-Init drev og xterm.js seriel konsol ==="
qm set "$TEMPLATE_ID" --ide2 "$STORAGE:cloudinit"
qm set "$TEMPLATE_ID" --boot order=scsi0 --bootdisk scsi0
qm set "$TEMPLATE_ID" --serial0 socket --vga serial0

# ------------------------------------------------------------------------------
# 6. AKTIVER GUEST AGENT OG UDVID DISK
# ------------------------------------------------------------------------------
echo "=== [5/6] Aktiverer QEMU Guest Agent og udvider basisdisk ==="
qm set "$TEMPLATE_ID" --agent enabled=1
qm disk resize "$TEMPLATE_ID" scsi0 +10G

# ------------------------------------------------------------------------------
# 7. KONVERTER TIL TEMPLATE
# ------------------------------------------------------------------------------
echo "=== [6/6] Konverterer VM til skrivebeskyttet template ==="
qm template "$TEMPLATE_ID"

echo ""
echo "=========================================================================="
echo "  TEMPLATE OPRETTET SUCCESFULDT!                                          "
echo "=========================================================================="
echo "  Template ID:   $TEMPLATE_ID"
echo "  Navn:          $TEMPLATE_NAME"
echo "  Status:        Klar til kloning med deploy.sh"
echo "=========================================================================="
