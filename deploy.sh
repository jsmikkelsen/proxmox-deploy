#!/usr/bin/env bash
# ==============================================================================
# SCRIPT: deploy.sh
# PROJEKT: Infrastrukturprojekt Del 4 - Automatiseret Deployment
# FORFATTER: Jacob Mikkelsen
# BESKRIVELSE: Universelt deployment-script til Proxmox VE.
#              Understøtter både KVM Virtuelle Maskiner (qm) og
#              LXC Containere (pct) med fuldautomatisk Cloud-Init/Nginx.
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# 0. KONFIGURATION & STANDARDVÆRDIER
# ------------------------------------------------------------------------------
STORAGE_VM="local-lvm"          # Storage pool til VM diske
STORAGE_CT="local-lvm"          # Storage pool til CT rootfs
STORAGE_SNIPPET="local"         # Proxmox storage med 'snippets' aktiveret
SNIPPETS_DIR="/var/lib/vz/snippets"
BASE_SNIPPET="$SNIPPETS_DIR/customer-webserver.yaml"
SSH_PUBKEY_FILE="$HOME/.ssh/id_rsa.pub"
DEFAULT_USER="sysadmin"
DNS_SERVER="1.1.1.1"
DEFAULT_VM_TEMPLATE=9000

# Farvekoder til terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[ADVARSEL]${NC} $*"; }
error() { echo -e "${RED}[FEJL]${NC} $*" >&2; exit 1; }

usage() {
    cat <<EOF
Brug: $0 [vm|ct] <ID> <HOSTNAME> <IP/CIDR> <GATEWAY> <BRIDGE> <POOL> [KUNDENAVN] [TEMPLATE_ID]

Eksempler:
  # 1. Standard VM deployment (Opgaveformat - default VM):
  $0 111 alfa-web01 192.168.10.10/24 192.168.10.1 vmbr10 pool-alfa "Kunde Alfa"

  # 2. Eksplicit LXC Container deployment:
  $0 ct 221 bravo-web01 192.168.20.10/24 192.168.20.1 vmbr20 pool-bravo "Kunde Bravo"

  # 3. Interaktiv menu (anbefalet for nem udrulning):
  $0
EOF
    exit 1
}

# ------------------------------------------------------------------------------
# 1. PARSNING AF ARGUMENTER (INTERAKTIV ELLER CLI)
# ------------------------------------------------------------------------------
if [ "$#" -eq 0 ]; then
    # INTERAKTIV MENU
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${CYAN}          PROXMOX AUTOMATISERET DEPLOYMENT PLATFORM                     ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    echo ""
    echo "Vælg type:"
    echo "  1) KVM Virtuel Maskine (VM via qm + Cloud-Init) [Standard]"
    echo "  2) LXC Linux Container (CT via pct)"
    read -rp "Valg [1-2, standard 1]: " TYPE_CHOICE
    if [ "${TYPE_CHOICE:-1}" = "2" ]; then
        TARGET_TYPE="ct"
    else
        TARGET_TYPE="vm"
    fi

    echo ""
    echo "Vælg kunde:"
    echo "  1) Kunde Alfa    (VLAN 10, vmbr10, 192.168.10.0/24)"
    echo "  2) Kunde Bravo   (VLAN 20, vmbr20, 192.168.20.0/24)"
    echo "  3) Kunde Charlie (VLAN 30, vmbr30, 192.168.30.0/24)"
    echo "  4) Kunde Delta   (VLAN 40, vmbr40, 192.168.40.0/24)"
    echo "  5) Anden / Brugerdefineret"
    read -rp "Valg [1-5]: " CUST_CHOICE

    case "$CUST_CHOICE" in
        1)
            CUST_NAME="Kunde Alfa"
            BRIDGE="vmbr10"
            GATEWAY="192.168.10.1"
            POOL="pool-alfa"
            DEFAULT_IP="192.168.10.10/24"
            SUGGESTED_ID="111"
            SUGGESTED_HOST="alfa-web01"
            ;;
        2)
            CUST_NAME="Kunde Bravo"
            BRIDGE="vmbr20"
            GATEWAY="192.168.20.1"
            POOL="pool-bravo"
            DEFAULT_IP="192.168.20.10/24"
            SUGGESTED_ID="121"
            SUGGESTED_HOST="bravo-web01"
            ;;
        3)
            CUST_NAME="Kunde Charlie"
            BRIDGE="vmbr30"
            GATEWAY="192.168.30.1"
            POOL="pool-charlie"
            DEFAULT_IP="192.168.30.10/24"
            SUGGESTED_ID="131"
            SUGGESTED_HOST="charlie-web01"
            ;;
        4)
            CUST_NAME="Kunde Delta"
            BRIDGE="vmbr40"
            GATEWAY="192.168.40.1"
            POOL="pool-delta"
            DEFAULT_IP="192.168.40.10/24"
            SUGGESTED_ID="141"
            SUGGESTED_HOST="delta-web01"
            ;;
        *)
            read -rp "Indtast kundenavn: " CUST_NAME
            read -rp "Indtast bridge (fx vmbr10): " BRIDGE
            read -rp "Indtast gateway (fx 192.168.10.1): " GATEWAY
            read -rp "Indtast resource pool (fx pool-custom): " POOL
            DEFAULT_IP="192.168.10.50/24"
            SUGGESTED_ID="301"
            SUGGESTED_HOST="custom-web01"
            ;;
    esac

    read -rp "Indtast ID [$SUGGESTED_ID]: " ID
    ID="${ID:-$SUGGESTED_ID}"

    read -rp "Indtast Hostname [$SUGGESTED_HOST]: " HOSTNAME
    HOSTNAME="${HOSTNAME:-$SUGGESTED_HOST}"

    read -rp "Indtast IP/CIDR [$DEFAULT_IP]: " IP_CIDR
    IP_CIDR="${IP_CIDR:-$DEFAULT_IP}"

    TEMPLATE_ID="$DEFAULT_VM_TEMPLATE"

else
    # CLI ARGUMENT MODE
    # Tjek om første argument er 'vm' eller 'ct', eller om det er et tal (VM-ID)
    if [ "$1" = "vm" ] || [ "$1" = "ct" ]; then
        TARGET_TYPE="$1"
        shift
    else
        TARGET_TYPE="vm"
    fi

    if [ "$#" -lt 6 ]; then
        usage
    fi

    ID="$1"
    HOSTNAME="$2"
    IP_CIDR="$3"
    GATEWAY="$4"
    BRIDGE="$5"
    POOL="$6"
    CUST_NAME="${7:-Ukendt Kunde}"
    TEMPLATE_ID="${8:-$DEFAULT_VM_TEMPLATE}"
fi

# ------------------------------------------------------------------------------
# 2. VALIDERINGS- OG SIKKERHEDSKONTROL (OPGAVE PUNKT 6)
# ------------------------------------------------------------------------------
info "Starter validering af input og miljø..."

# 2.1 Er ID et gyldigt heltal?
if ! [[ "$ID" =~ ^[0-9]+$ ]]; then
    error "ID '$ID' er ikke et gyldigt heltal."
fi

# 2.2 Findes ID allerede på Proxmox klyngen?
if [ "$TARGET_TYPE" = "vm" ]; then
    if qm status "$ID" &>/dev/null; then
        error "VM-ID $ID er allerede i brug i Proxmox!"
    fi
else
    if pct status "$ID" &>/dev/null; then
        error "Container-ID $ID er allerede i brug i Proxmox!"
    fi
fi

# 2.3 Hvis VM, tjek om Template findes og er en gyldig template
if [ "$TARGET_TYPE" = "vm" ]; then
    if ! qm status "$TEMPLATE_ID" &>/dev/null; then
        error "Template med ID $TEMPLATE_ID blev ikke fundet i Proxmox!"
    fi
    if ! qm config "$TEMPLATE_ID" | grep -q "template: 1"; then
        error "ID $TEMPLATE_ID findes, men er ikke konfigureret som template!"
    fi
fi

# 2.4 Tjek om Linux Bridge findes på Proxmox serveren
if ! ip link show "$BRIDGE" &>/dev/null; then
    error "Linux Bridge '$BRIDGE' findes ikke på Proxmox! Kontroller /etc/network/interfaces."
fi

# 2.5 Tjek om IP/CIDR overholder gyldigt format
if ! [[ "$IP_CIDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
    error "IP-adresse '$IP_CIDR' er ikke formateret korrekt (skal være fx 192.168.10.10/24)."
fi

# 2.6 Tjek eller opret Resource Pool
if ! pvesh get /pools | grep -qw "$POOL"; then
    info "Resource Pool '$POOL' findes ikke. Opretter pool..."
    pvesh create /pools -poolid "$POOL"
fi

# 2.7 Tjek for SSH public key
if [ ! -f "$SSH_PUBKEY_FILE" ]; then
    warn "Fandt ingen SSH-nøgle i $SSH_PUBKEY_FILE. Genererer en ny ed25519 nøgle..."
    mkdir -p "$HOME/.ssh"
    ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_rsa"
fi

ok "Input og miljø valideret uden fejl."

# ------------------------------------------------------------------------------
# 3. UDRULNING: KVM VIRTUAL MACHINE (VM)
# ------------------------------------------------------------------------------
if [ "$TARGET_TYPE" = "vm" ]; then
    info "Trin [1/5]: Kloner template $TEMPLATE_ID -> VM $ID ($HOSTNAME)..."
    qm clone "$TEMPLATE_ID" "$ID" \
        --name "$HOSTNAME" \
        --pool "$POOL" \
        --full 1

    info "Trin [2/5]: Forbinder netkort til bridge '$BRIDGE'..."
    qm set "$ID" --net0 "virtio,bridge=$BRIDGE"

    info "Trin [3/5]: Klargør klientspecifik Cloud-Init user-data snippet..."
    mkdir -p "$SNIPPETS_DIR"
    VM_SNIPPET_FILE="$SNIPPETS_DIR/vm-${ID}-userdata.yaml"
    
    if [ -f "$BASE_SNIPPET" ]; then
        sed "s/__CUSTOMER_NAME__/$CUST_NAME/g" "$BASE_SNIPPET" > "$VM_SNIPPET_FILE"
        qm set "$ID" --cicustom "user=${STORAGE_SNIPPET}:snippets/vm-${ID}-userdata.yaml"
        ok "Tilknyttede Cloud-Init snippet med kundenavn: $CUST_NAME"
    else
        warn "Grundskabelon $BASE_SNIPPET mangler. Udruller uden Nginx snippet."
    fi

    info "Trin [4/5]: Konfigurerer Cloud-Init IP, bruger og SSH-adgang..."
    qm set "$ID" \
        --ciuser "$DEFAULT_USER" \
        --sshkeys "$SSH_PUBKEY_FILE" \
        --ipconfig0 "ip=$IP_CIDR,gw=$GATEWAY" \
        --nameserver "$DNS_SERVER"

    info "Trin [5/5]: Starter VM $ID..."
    qm start "$ID"

# ------------------------------------------------------------------------------
# 4. UDRULNING: LXC CONTAINER (CT)
# ------------------------------------------------------------------------------
elif [ "$TARGET_TYPE" = "ct" ]; then
    info "Trin [1/4]: Søger efter tilgængelig Ubuntu LXC template i $STORAGE_SNIPPET..."
    LXC_TAR=$(pvesm list "$STORAGE_SNIPPET" | grep "ubuntu.*tar" | awk '{print $1}' | tail -n 1 || true)
    
    if [ -z "$LXC_TAR" ]; then
        info "Ingen lokal Ubuntu LXC template fundet. Henter nyeste template..."
        pveam update
        LATEST_APPLIANCE=$(pveam available --section system | grep "ubuntu-" | tail -n 1 | awk '{print $2}')
        pveam download "$STORAGE_SNIPPET" "$LATEST_APPLIANCE"
        LXC_TAR="${STORAGE_SNIPPET}:vztmpl/${LATEST_APPLIANCE}"
    fi
    info "Anvender LXC template: $LXC_TAR"

    info "Trin [2/4]: Opretter LXC Container $ID ($HOSTNAME)..."
    pct create "$ID" "$LXC_TAR" \
        --hostname "$HOSTNAME" \
        --pool "$POOL" \
        --cores 2 \
        --memory 1024 \
        --swap 512 \
        --rootfs "${STORAGE_CT}:8" \
        --net0 "name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,gw=$GATEWAY" \
        --nameserver "$DNS_SERVER" \
        --ssh-public-keys "$SSH_PUBKEY_FILE" \
        --features nesting=1 \
        --ostype ubuntu \
        --start 1

    info "Trin [3/4]: Venter på container opstart..."
    sleep 5

    info "Trin [4/4]: Installerer og konfigurerer Nginx webserver i containeren..."
    pct exec "$ID" -- bash -c "apt-get update -qq && apt-get install -y -qq nginx curl"
    IP_RAW="${IP_CIDR%/*}"
    pct exec "$ID" -- bash -c "cat <<HTML > /var/www/html/index.html
<!DOCTYPE html>
<html lang='da'>
<head>
    <meta charset='UTF-8'>
    <title>Kundeserver Status (LXC Container)</title>
    <style>
        body { font-family: -apple-system, sans-serif; background: #0f172a; color: #f8fafc; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; }
        .card { background: #1e293b; padding: 2.5rem; border-radius: 12px; border: 1px solid #334155; text-align: center; max-width: 500px; width: 90%; }
        h1 { color: #38bdf8; font-size: 1.8rem; margin-top: 0; }
        .badge { display: inline-block; padding: 0.35rem 1rem; background: #059669; color: #fff; border-radius: 9999px; font-size: 0.85rem; font-weight: 600; margin-bottom: 1.5rem; text-transform: uppercase; }
        .grid { background: #0f172a; padding: 1.25rem; border-radius: 8px; border: 1px solid #334155; text-align: left; }
        .row { margin-bottom: 0.75rem; }
        .row:last-child { margin-bottom: 0; }
        .label { color: #94a3b8; font-size: 0.75rem; text-transform: uppercase; }
        .value { font-family: monospace; font-size: 1.15rem; color: #4ade80; font-weight: 600; }
    </style>
</head>
<body>
    <div class='card'>
        <span class='badge'>Proxmox LXC Container</span>
        <h1>Kundeserver i Drift</h1>
        <div class='grid'>
            <div class='row'><div class='label'>Kunde</div><div class='value'>$CUST_NAME</div></div>
            <div class='row'><div class='label'>Hostname</div><div class='value'>$HOSTNAME</div></div>
            <div class='row'><div class='label'>IP-Adresse</div><div class='value'>$IP_RAW</div></div>
        </div>
    </div>
</body>
</html>
HTML"
    pct exec "$ID" -- systemctl restart nginx
fi

# ------------------------------------------------------------------------------
# 5. OPSUMMERING
# ------------------------------------------------------------------------------
IP_ONLY="${IP_CIDR%/*}"
echo ""
echo -e "${GREEN}========================================================================${NC}"
echo -e "${GREEN}  DEPLOYMENT GENNEMFØRT SUCCESFULDT!                                    ${NC}"
echo -e "${GREEN}========================================================================${NC}"
echo "  Type:           ${TARGET_TYPE^^}"
echo "  ID:             $ID"
echo "  Hostname:       $HOSTNAME"
echo "  Kunde:          $CUST_NAME"
echo "  Resource Pool:  $POOL"
echo "  Linux Bridge:   $BRIDGE"
echo "  IP-Adresse:     $IP_ONLY"
echo "  Default Gateway:$GATEWAY"
echo "  SSH Bruger:     $DEFAULT_USER"
echo ""
echo "  Webserver URL:  http://$IP_ONLY/"
echo "  SSH Kommando:   ssh $DEFAULT_USER@$IP_ONLY"
echo -e "${GREEN}========================================================================${NC}"
if [ "$TARGET_TYPE" = "vm" ]; then
    echo "  Bemærk: KVM VM'ens Cloud-Init bruger ca. 30-45 sekunder på første boot."
fi
