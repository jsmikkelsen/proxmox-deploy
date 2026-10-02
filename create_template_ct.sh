#!/usr/bin/env bash
# ==============================================================================
# SCRIPT: create_template_ct.sh
# FORMÅL: Henter og klargør Ubuntu LXC Container Template i Proxmox
# ANVENDELSE: ./create_template_ct.sh [STORAGE]
# ==============================================================================
set -euo pipefail

STORAGE="${1:-local}"

echo "=========================================================================="
echo "  HENTER UBUNTU LXC CONTAINER APPLIANCE TEMPLATE                          "
echo "=========================================================================="
echo "  Template Storage: $STORAGE"
echo "=========================================================================="

echo "=== [1/2] Opdaterer Proxmox Appliance liste (pveam update) ==="
pveam update

echo "=== [2/2] Søger efter seneste officielle Ubuntu standard template ==="
# Find nyeste tilgængelige Ubuntu template (f.eks. ubuntu-24.04-standard eller nyere)
TEMPLATE_NAME=$(pveam available --section system | grep "ubuntu-" | tail -n 1 | awk '{print $2}')

if [ -z "$TEMPLATE_NAME" ]; then
    echo "Fejl: Fandt ingen officiel Ubuntu template på pveam listen."
    exit 1
fi

echo "Henter template: $TEMPLATE_NAME til storage: $STORAGE..."
pveam download "$STORAGE" "$TEMPLATE_NAME"

echo ""
echo "=========================================================================="
echo "  LXC TEMPLATE KLARGJORT SUCCESFULDT!                                     "
echo "=========================================================================="
echo "  Template fil: $TEMPLATE_NAME"
echo "  Status:       Klar til oprettelse af containere med deploy.sh"
echo "=========================================================================="
