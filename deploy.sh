#!/usr/bin/env bash
# ==============================================================================
# SCRIPT: deploy.sh
# PROJEKT: Infrastrukturprojekt Del 4 - Automatiseret Deployment
# FORFATTER: Jacob Mikkelsen
# BESKRIVELSE: Universelt deployment-script til Proxmox VE.
#              Understøtter både KVM Virtuelle Maskiner (qm) og
#              LXC Containere (pct) med Proxmox SDN (Software-Defined Networking),
#              Cloud-Init, dynamiske serverroller og validering.
#              Resource pool er valgfri.
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# 0. KONFIGURATION & STANDARDVÆRDIER
# ------------------------------------------------------------------------------
STORAGE_VM="local-lvm"          # Storage pool til VM diske
STORAGE_CT="local-lvm"          # Storage pool til CT rootfs
STORAGE_SNIPPET="local"         # Proxmox storage med 'snippets' aktiveret
SNIPPETS_DIR="/var/lib/vz/snippets"
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
Brug: $0 [vm|ct] <ID> <HOSTNAME> <IP/CIDR> <GATEWAY> <BRIDGE/VNET> [POOL] [KUNDENAVN] [ROLLE] [TEMPLATE_ID]

Bemærk: [POOL] er valgfri. Angiv '-' eller 'none' hvis serveren ikke skal placeres i en pool.

Rollemuligheder [ROLLE]:
  web     - Nginx webserver med dynamisk statusportal (standard)
  docker  - Docker CE container-platform
  base    - Standard minimal og hærdet Linux-server

Eksempler med Proxmox SDN (Software-Defined Networking):
  # 1. Kunde Alfa (SDN VNet 'alfa', VLAN 10 med pool):
  $0 111 alfa-web01 192.168.10.10/24 192.168.10.1 alfa pool-alfa "Kunde Alfa"

  # 2. Uden pool (angiv '-' eller 'none'):
  $0 301 test-srv01 192.168.100.155/24 192.168.100.1 vmbr0 - "Netic" web

  # 3. Kunde Bravo (SDN VNet 'bravo', VLAN 20 med Docker-rolle):
  $0 121 bravo-dock01 192.168.20.10/24 192.168.20.1 bravo pool-bravo "Kunde Bravo" docker

  # 4. Interaktiv menu (anbefalet for guidet udrulning):
  $0
EOF
    exit 1
}

# ------------------------------------------------------------------------------
# 1. PARSNING AF ARGUMENTER (INTERAKTIV ELLER CLI)
# ------------------------------------------------------------------------------
if [ "$#" -eq 0 ]; then
    # INTERAKTIV MENU (BONUS OPGAVE)
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${CYAN}       PROXMOX SDN AUTOMATISERET DEPLOYMENT PLATFORM                    ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    echo ""
    echo "Trin 1: Vælg virtualiseringstype:"
    echo "  1) KVM Virtuel Maskine (VM via qm + Cloud-Init) [Standard]"
    echo "  2) LXC Linux Container (CT via pct)"
    read -rp "Valg [1-2, standard 1]: " TYPE_CHOICE
    if [ "${TYPE_CHOICE:-1}" = "2" ]; then
        TARGET_TYPE="ct"
    else
        TARGET_TYPE="vm"
    fi

    echo ""
    echo "Trin 2: Vælg serverrolle (Ekstra Bonus):"
    echo "  1) Webserver (Nginx med dynamisk statusportal) [Standard]"
    echo "  2) Docker-server (Docker CE + container runtime)"
    echo "  3) Standard Linux-server (Minimal, hærdet base-server)"
    read -rp "Valg [1-3, standard 1]: " ROLE_CHOICE
    case "${ROLE_CHOICE:-1}" in
        2) ROLE="docker" ;;
        3) ROLE="base" ;;
        *) ROLE="web" ;;
    esac

    echo ""
    echo "Trin 3: Vælg kunde (Proxmox SDN Zone 'kundenet'):"
    echo "  1) Kunde Alfa    (SDN VNet: alfa,    VLAN 10, 192.168.10.0/24)"
    echo "  2) Kunde Bravo   (SDN VNet: bravo,   VLAN 20, 192.168.20.0/24)"
    echo "  3) Kunde Charlie (SDN VNet: charlie, VLAN 30, 192.168.30.0/24)"
    echo "  4) Kunde Delta   (SDN VNet: delta,   VLAN 40, 192.168.40.0/24)"
    echo "  5) Anden / Brugerdefineret"
    read -rp "Valg [1-5]: " CUST_CHOICE

    # Tilpas standard hostprefix baseret på rolle
    case "$ROLE" in
        docker) ROLE_PREFIX="dock" ;;
        base)   ROLE_PREFIX="srv" ;;
        *)      ROLE_PREFIX="web" ;;
    esac

    case "$CUST_CHOICE" in
        1)
            CUST_NAME="Kunde Alfa"
            BRIDGE="alfa"
            GATEWAY="192.168.10.1"
            POOL="pool-alfa"
            DEFAULT_IP="192.168.10.10/24"
            SUGGESTED_ID="111"
            SUGGESTED_HOST="alfa-${ROLE_PREFIX}01"
            ;;
        2)
            CUST_NAME="Kunde Bravo"
            BRIDGE="bravo"
            GATEWAY="192.168.20.1"
            POOL="pool-bravo"
            DEFAULT_IP="192.168.20.10/24"
            SUGGESTED_ID="121"
            SUGGESTED_HOST="bravo-${ROLE_PREFIX}01"
            ;;
        3)
            CUST_NAME="Kunde Charlie"
            BRIDGE="charlie"
            GATEWAY="192.168.30.1"
            POOL="pool-charlie"
            DEFAULT_IP="192.168.30.10/24"
            SUGGESTED_ID="131"
            SUGGESTED_HOST="charlie-${ROLE_PREFIX}01"
            ;;
        4)
            CUST_NAME="Kunde Delta"
            BRIDGE="delta"
            GATEWAY="192.168.40.1"
            POOL="pool-delta"
            DEFAULT_IP="192.168.40.10/24"
            SUGGESTED_ID="141"
            SUGGESTED_HOST="delta-${ROLE_PREFIX}01"
            ;;
        *)
            read -rp "Indtast kundenavn: " CUST_NAME
            read -rp "Indtast SDN VNet / Bridge (fx alfa): " BRIDGE
            read -rp "Indtast gateway (fx 192.168.10.1): " GATEWAY
            read -rp "Indtast resource pool (valgfrit - tryk Enter for ingen): " POOL
            DEFAULT_IP="192.168.10.50/24"
            SUGGESTED_ID="301"
            SUGGESTED_HOST="kunde-${ROLE_PREFIX}01"
            ;;
    esac

    echo ""
    echo "Trin 4: Bekræft specifikke parametre:"
    read -rp "Indtast ID [$SUGGESTED_ID]: " ID
    ID="${ID:-$SUGGESTED_ID}"

    read -rp "Indtast Hostname [$SUGGESTED_HOST]: " HOSTNAME
    HOSTNAME="${HOSTNAME:-$SUGGESTED_HOST}"

    read -rp "Indtast IP/CIDR [$DEFAULT_IP]: " IP_CIDR
    IP_CIDR="${IP_CIDR:-$DEFAULT_IP}"

    TEMPLATE_ID="$DEFAULT_VM_TEMPLATE"

else
    # CLI ARGUMENT MODE
    # Tjek om første argument er 'vm' eller 'ct', ellers antages 'vm' som default
    if [ "$1" = "vm" ] || [ "$1" = "ct" ]; then
        TARGET_TYPE="$1"
        shift
    else
        TARGET_TYPE="vm"
    fi

    # Validering: Mangler nødvendige argumenter? (mindst ID, Host, IP, Gateway, Bridge)
    if [ "$#" -lt 5 ]; then
        warn "Utilstrækkeligt antal argumenter angivet ($# givet, mindst 5 krævet)."
        usage
    fi

    ID="$1"
    HOSTNAME="$2"
    IP_CIDR="$3"
    GATEWAY="$4"
    BRIDGE="$5"
    POOL="${6:-}"
    CUST_NAME="${7:-${POOL:-$HOSTNAME}}"
    ROLE="${8:-web}"
    TEMPLATE_ID="${9:-$DEFAULT_VM_TEMPLATE}"
fi

# Normaliser POOL (hvis bruger har angivet '-' eller 'none', behandles det som ingen pool)
if [ "$POOL" = "-" ] || [ "$POOL" = "none" ] || [ "$POOL" = "null" ]; then
    POOL=""
fi

# Normaliser rolle
case "$ROLE" in
    docker|dock)
        ROLE="docker"
        ROLE_DISPLAY="Docker Server"
        BASE_SNIPPET="$SNIPPETS_DIR/docker-server.yaml"
        ;;
    base|standard|srv)
        ROLE="base"
        ROLE_DISPLAY="Standard Linux Server"
        BASE_SNIPPET="$SNIPPETS_DIR/standard-server.yaml"
        ;;
    *)
        ROLE="web"
        ROLE_DISPLAY="Nginx Webserver"
        BASE_SNIPPET="$SNIPPETS_DIR/customer-webserver.yaml"
        ;;
esac

# ------------------------------------------------------------------------------
# 2. VALIDERINGS- OG SIKKERHEDSKONTROL (OPGAVE PUNKT 6)
# ------------------------------------------------------------------------------
info "Starter validering af input og Proxmox miljø..."

# 2.1 Er ID angivet og et gyldigt heltal?
if [ -z "$ID" ] || ! [[ "$ID" =~ ^[0-9]+$ ]]; then
    error "ID '$ID' er ugyldigt. Det skal være et positivt heltal (f.eks. 111)."
fi

# 2.2 Findes VM-ID eller Container-ID allerede på Proxmox klyngen?
if [ "$TARGET_TYPE" = "vm" ]; then
    if qm status "$ID" &>/dev/null; then
        error "VM-ID $ID er allerede i brug i Proxmox! Vælg et andet ID eller slet den eksisterende VM."
    fi
else
    if pct status "$ID" &>/dev/null; then
        error "Container-ID $ID er allerede i brug i Proxmox! Vælg et andet ID eller slet den eksisterende container."
    fi
fi

# 2.3 Hvis VM, tjek om Template findes og er en gyldig template
if [ "$TARGET_TYPE" = "vm" ]; then
    if ! qm status "$TEMPLATE_ID" &>/dev/null; then
        error "Template med ID $TEMPLATE_ID blev ikke fundet i Proxmox! Kør venligst ./create_template_vm.sh først."
    fi
    if ! qm config "$TEMPLATE_ID" | grep -q "template: 1"; then
        error "ID $TEMPLATE_ID findes, men er ikke konfigureret som skrivebeskyttet template!"
    fi
fi

# 2.4 Tjek om Linux Bridge eller SDN VNet findes i operativsystemet
if ! ip link show "$BRIDGE" &>/dev/null; then
    # Undersøg om det er et SDN VNet der mangler 'pvesdn reload' (Apply)
    if [ -f "/etc/pve/sdn/vnets.cfg" ] && grep -qw "$BRIDGE" /etc/pve/sdn/vnets.cfg 2>/dev/null; then
        info "SDN VNet '$BRIDGE' er defineret, men ikke aktiv i kernen. Forsøger at genindlæse SDN (pvesdn reload)..."
        pvesdn reload || true
        sleep 1
    fi
    
    if ! ip link show "$BRIDGE" &>/dev/null; then
        error "Netværk '$BRIDGE' findes ikke som aktiv bridge/VNet på Proxmox værten! Hvis du bruger SDN, skal du klikke 'Apply' i Web GUI (under SDN) eller køre 'pvesdn reload' på værten."
    fi
fi

# 2.5 Er IP-adressen angivet og formateret korrekt som IPv4/CIDR?
if [ -z "$IP_CIDR" ]; then
    error "IP-adresse mangler. Angiv IP/CIDR (f.eks. 192.168.10.10/24)."
fi
if ! [[ "$IP_CIDR" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    error "IP-adresse '$IP_CIDR' er ikke et gyldigt CIDR-format (skal være fx 192.168.10.10/24)."
fi

# 2.6 Er Default Gateway en gyldig IPv4 adresse?
if [ -z "$GATEWAY" ] || ! [[ "$GATEWAY" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    error "Default Gateway '$GATEWAY' er ugyldig. Angiv en gyldig IPv4-adresse (f.eks. 192.168.10.1)."
fi

# 2.7 Tjek eller opret Resource Pool (hvis angivet)
if [ -n "$POOL" ]; then
    if ! pvesh get /pools | grep -qw "$POOL"; then
        info "Resource Pool '$POOL' findes ikke. Opretter pool automatisk..."
        pvesh create /pools -poolid "$POOL"
    fi
fi

# 2.8 Tjek for SSH public key
if [ ! -f "$SSH_PUBKEY_FILE" ]; then
    warn "Fandt ingen SSH-nøgle i $SSH_PUBKEY_FILE. Genererer automatisk en ny ed25519 nøgle..."
    mkdir -p "$HOME/.ssh"
    ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_rsa"
fi

ok "Input og miljø valideret uden fejl (SDN VNet '$BRIDGE' fundet)."

# ------------------------------------------------------------------------------
# 3. UDRULNING: KVM VIRTUAL MACHINE (VM)
# ------------------------------------------------------------------------------
if [ "$TARGET_TYPE" = "vm" ]; then
    info "Trin [1/5]: Kloner template $TEMPLATE_ID -> VM $ID ($HOSTNAME)..."
    
    CLONE_CMD=(qm clone "$TEMPLATE_ID" "$ID" --name "$HOSTNAME" --full 1)
    if [ -n "$POOL" ]; then
        CLONE_CMD+=(--pool "$POOL")
    fi

    if ! "${CLONE_CMD[@]}"; then
        error "Kunne ikke klone template $TEMPLATE_ID til VM $ID! Kontroller diskplads på storage."
    fi

    info "Trin [2/5]: Forbinder netkort til SDN VNet '$BRIDGE'..."
    qm set "$ID" --net0 "virtio,bridge=$BRIDGE"

    info "Trin [3/5]: Klargør Cloud-Init user-data snippet for rolle '$ROLE_DISPLAY'..."
    mkdir -p "$SNIPPETS_DIR"
    VM_SNIPPET_FILE="$SNIPPETS_DIR/vm-${ID}-userdata.yaml"
    
    if [ -f "$BASE_SNIPPET" ]; then
        sed "s|__CUSTOMER_NAME__|$CUST_NAME|g" "$BASE_SNIPPET" > "$VM_SNIPPET_FILE"
        qm set "$ID" --cicustom "user=${STORAGE_SNIPPET}:snippets/vm-${ID}-userdata.yaml"
        ok "Tilknyttede Cloud-Init snippet med kundenavn: $CUST_NAME og rolle: $ROLE_DISPLAY"
    else
        warn "Grundskabelon $BASE_SNIPPET mangler. Udruller uden tilpasset Cloud-Init user-data."
    fi

    info "Trin [4/5]: Konfigurerer Cloud-Init IP, gateway, DNS, bruger og SSH-nøgle..."
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
        info "Ingen lokal Ubuntu LXC template fundet. Henter nyeste template via pveam..."
        pveam update
        LATEST_APPLIANCE=$(pveam available --section system | grep "ubuntu-" | tail -n 1 | awk '{print $2}')
        pveam download "$STORAGE_SNIPPET" "$LATEST_APPLIANCE"
        LXC_TAR="${STORAGE_SNIPPET}:vztmpl/${LATEST_APPLIANCE}"
    fi
    info "Anvender LXC template: $LXC_TAR"

    info "Trin [2/4]: Opretter LXC Container $ID ($HOSTNAME)..."
    PCT_CMD=(pct create "$ID" "$LXC_TAR" \
        --hostname "$HOSTNAME" \
        --cores 2 \
        --memory 1024 \
        --swap 512 \
        --rootfs "${STORAGE_CT}:8" \
        --net0 "name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,gw=$GATEWAY" \
        --nameserver "$DNS_SERVER" \
        --ssh-public-keys "$SSH_PUBKEY_FILE" \
        --features nesting=1 \
        --ostype ubuntu \
        --start 1)
    if [ -n "$POOL" ]; then
        PCT_CMD+=(--pool "$POOL")
    fi

    if ! "${PCT_CMD[@]}"; then
        error "Kunne ikke oprette LXC container $ID! Kontroller storage og ressourcer."
    fi

    info "Trin [3/4]: Venter på container opstart..."
    sleep 5

    info "Trin [4/4]: Konfigurerer serverrolle '$ROLE_DISPLAY' i containeren..."
    pct exec "$ID" -- bash -c "apt-get update -qq"

    case "$ROLE" in
        web)
            pct exec "$ID" -- bash -c "apt-get install -y -qq nginx curl"
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
            <div class='row'><div class='label'>SDN VNet / Bridge</div><div class='value'>$BRIDGE</div></div>
            <div class='row'><div class='label'>Rolle</div><div class='value'>Nginx Webserver</div></div>
        </div>
    </div>
</body>
</html>
HTML"
            pct exec "$ID" -- systemctl restart nginx
            ;;
        docker)
            pct exec "$ID" -- bash -c "apt-get install -y -qq docker.io curl"
            pct exec "$ID" -- bash -c "systemctl enable --now docker"
            pct exec "$ID" -- bash -c "docker run -d --name status-web -p 80:80 nginxdemos/hello:plain-text 2>/dev/null || true"
            ;;
        base)
            pct exec "$ID" -- bash -c "apt-get install -y -qq curl htop net-tools ufw"
            ;;
    esac
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
echo "  Serverrolle:    $ROLE_DISPLAY"
echo "  Resource Pool:  ${POOL:-(ingen pool)}"
echo "  SDN VNet/Bridge:$BRIDGE"
echo "  IP-Adresse:     $IP_ONLY"
echo "  Default Gateway:$GATEWAY"
echo "  SSH Bruger:     $DEFAULT_USER"
echo ""
if [ "$ROLE" = "web" ]; then
    echo "  Webserver URL:  http://$IP_ONLY/"
elif [ "$ROLE" = "docker" ]; then
    echo "  Docker Status:  Docker kører (Test: http://$IP_ONLY/ eller 'docker ps')"
fi
echo "  SSH Kommando:   ssh $DEFAULT_USER@$IP_ONLY"
echo -e "${GREEN}========================================================================${NC}"
if [ "$TARGET_TYPE" = "vm" ]; then
    echo "  Bemærk: KVM VM'ens Cloud-Init bruger ca. 30-45 sekunder på første boot."
fi
