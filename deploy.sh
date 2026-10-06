#!/usr/bin/env bash
# ==============================================================================
# SCRIPT: deploy.sh
# PROJEKT: Infrastrukturprojekt Del 4 - Automatiseret Deployment
# FORFATTER: Jacob Mikkelsen
# BESKRIVELSE: Universelt deployment- og state-styringsscript til Proxmox VE.
#              - Understøtter KVM VM (qm) og LXC Containers (pct).
#              - Proxmox SDN (Software-Defined Networking) integreret.
#              - Deklarativ State Management via deployments.csv.
#              - Automatisk genopbygning (reconciliation loop) af slettede VM'er.
#              - Valgfri Resource Pool og dynamiske serverroller.
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# 0. KONFIGURATION & STANDARDVÆRDIER
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${STATE_FILE:-$SCRIPT_DIR/deployments.csv}"

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
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[ADVARSEL]${NC} $*"; }
error() { echo -e "${RED}[FEJL]${NC} $*" >&2; exit 1; }

usage() {
    cat <<EOF
${BOLD}Brug:${NC} $0 [KOMMANDO] eller $0 [vm|ct] <ID> <HOSTNAME> <IP/CIDR> <GATEWAY> <BRIDGE/VNET> [POOL] [KUNDE] [ROLLE]

${BOLD}Kommandoer til State Management & Selvreparation:${NC}
  sync / apply     - Synkroniser tilstand: Tjekker deployments.csv og genopbygger manglende/slettede VM'er
  status / list    - Viser overblik over registrerede servere og deres aktuelle driftstilstand
  menu             - Starter den interaktive udrulningsmenu

${BOLD}Rollemuligheder [ROLLE]:${NC}
  web     - Nginx webserver med dynamisk statusportal (standard)
  docker  - Docker CE container-platform
  base    - Standard minimal og hærdet Linux-server

${BOLD}Eksempler:${NC}
  # 1. Kør synkronisering (genopbyg slettede servere automatisk):
  $0 sync

  # 2. Vis overblik over server-status i Proxmox:
  $0 status

  # 3. Udrul en specifik server manuelt og tilføj til state:
  $0 111 alfa-web01 192.168.10.10/24 192.168.10.1 alfa Pool_KundeA "Kunde Alfa" web

  # 4. Udrul uden resource pool (angiv '-' eller 'none'):
  $0 301 netic-srv01 192.168.100.155/24 192.168.100.1 vmbr0 - "Netic" web
EOF
    exit 1
}

# ------------------------------------------------------------------------------
# 1. FUNKTIONER TIL STATE MANAGEMENT & RECONCILIATION
# ------------------------------------------------------------------------------

# Gem eller opdater en server i deployments.csv
save_state() {
    local p_id="$1" p_host="$2" p_ip="$3" p_gw="$4" p_bridge="$5" p_pool="$6" p_cust="$7" p_role="$8" p_type="$9"
    mkdir -p "$(dirname "$STATE_FILE")"
    if [ ! -f "$STATE_FILE" ]; then
        echo "# Proxmox Automated Deployment Platform - Desired State Registry" > "$STATE_FILE"
        echo "# Format: ID,HOSTNAME,IP_CIDR,GATEWAY,BRIDGE,POOL,CUST_NAME,ROLE,TARGET_TYPE" >> "$STATE_FILE"
    fi
    # Fjern tidligere linje for samme ID for at undgå duplikater
    local temp_file
    temp_file="$(mktemp)"
    grep -v "^${p_id}," "$STATE_FILE" > "$temp_file" 2>/dev/null || true
    echo "${p_id},${p_host},${p_ip},${p_gw},${p_bridge},${p_pool},${p_cust},${p_role},${p_type}" >> "$temp_file"
    mv "$temp_file" "$STATE_FILE"
    ok "Server $p_id ($p_host) er registreret i state-filen: $STATE_FILE"
}

# Viser en oversigt over alle registrerede servere og deres tilstand i Proxmox
show_state() {
    echo -e "${CYAN}========================================================================================${NC}"
    echo -e "${CYAN}       PROXMOX DESIRED STATE OVERBLIK (deployments.csv)                                 ${NC}"
    echo -e "${CYAN}========================================================================================${NC}"
    if [ ! -f "$STATE_FILE" ]; then
        warn "Ingen state-fil fundet på $STATE_FILE."
        return 0
    fi

    printf "%-5s %-4s %-16s %-19s %-10s %-14s %-18s\n" "ID" "TYPE" "HOSTNAME" "IP-ADRESSE" "NET/VNET" "KUNDE" "STATUS I PROXMOX"
    echo "----------------------------------------------------------------------------------------"

    while IFS=',' read -r s_id s_host s_ip s_gw s_bridge s_pool s_cust s_role s_type || [ -n "$s_id" ]; do
        [[ "$s_id" =~ ^[[:space:]]*# ]] && continue
        [ -z "$s_id" ] && continue

        s_id="$(echo "$s_id" | xargs)"
        s_host="$(echo "$s_host" | xargs)"
        s_ip="$(echo "$s_ip" | xargs)"
        s_bridge="$(echo "$s_bridge" | xargs)"
        s_cust="$(echo "$s_cust" | xargs)"
        s_type="${s_type:-vm}"

        local status_str="${RED}MANGLER (SLETTET)${NC}"
        if [ "$s_type" = "vm" ]; then
            if qm status "$s_id" &>/dev/null; then
                local raw_status
                raw_status="$(qm status "$s_id" | awk '{print $2}')"
                if [ "$raw_status" = "running" ]; then
                    status_str="${GREEN}RUNNING (I drift)${NC}"
                else
                    status_str="${YELLOW}STOPPED (Lukket)${NC}"
                fi
            fi
        else
            if pct status "$s_id" &>/dev/null; then
                local raw_status
                raw_status="$(pct status "$s_id" | awk '{print $2}')"
                if [ "$raw_status" = "running" ]; then
                    status_str="${GREEN}RUNNING (I drift)${NC}"
                else
                    status_str="${YELLOW}STOPPED (Lukket)${NC}"
                fi
            fi
        fi

        local s_type_upper
        s_type_upper="$(echo "$s_type" | tr '[:lower:]' '[:upper:]')"
        printf "%-5s %-4s %-16s %-19s %-10s %-14s %b\n" "$s_id" "$s_type_upper" "$s_host" "$s_ip" "$s_bridge" "$s_cust" "$status_str"
    done < "$STATE_FILE"
    echo -e "${CYAN}========================================================================================${NC}"
    echo "Kør './deploy.sh sync' for automatisk at genopbygge manglende/slettede maskiner."
    echo ""
}

# Synkroniserer Proxmox' virkelige tilstand med state-filen (Reconciliation Loop)
reconcile_state() {
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${CYAN}  STARTER PROXMOX STATE RECONCILIATION (SELVRAPARATION)                  ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    if [ ! -f "$STATE_FILE" ]; then
        error "State-filen $STATE_FILE blev ikke fundet! Opret en server først eller tilføj deployments.csv."
    fi

    info "Indlæser ønsket tilstand (Desired State) fra $STATE_FILE..."
    local total=0
    local running=0
    local restored=0

    while IFS=',' read -r s_id s_host s_ip s_gw s_bridge s_pool s_cust s_role s_type || [ -n "$s_id" ]; do
        [[ "$s_id" =~ ^[[:space:]]*# ]] && continue
        [ -z "$s_id" ] && continue

        s_id="$(echo "$s_id" | xargs)"
        s_host="$(echo "$s_host" | xargs)"
        s_ip="$(echo "$s_ip" | xargs)"
        s_gw="$(echo "$s_gw" | xargs)"
        s_bridge="$(echo "$s_bridge" | xargs)"
        s_pool="$(echo "$s_pool" | xargs)"
        s_cust="$(echo "$s_cust" | xargs)"
        s_role="$(echo "${s_role:-web}" | xargs)"
        s_type="$(echo "${s_type:-vm}" | xargs)"

        local s_type_upper
        s_type_upper="$(echo "$s_type" | tr '[:lower:]' '[:upper:]')"

        total=$((total + 1))
        echo ""
        info "Undersøger $s_type_upper ID $s_id ($s_host)..."

        local exists=false
        local is_running=false

        if [ "$s_type" = "vm" ]; then
            if qm status "$s_id" &>/dev/null; then
                exists=true
                [ "$(qm status "$s_id" | awk '{print $2}')" = "running" ] && is_running=true
            fi
        else
            if pct status "$s_id" &>/dev/null; then
                exists=true
                [ "$(pct status "$s_id" | awk '{print $2}')" = "running" ] && is_running=true
            fi
        fi

        if [ "$exists" = true ]; then
            if [ "$is_running" = true ]; then
                ok "$s_type_upper $s_id ($s_host) kører i forvejen og matcher ønsket tilstand."
                running=$((running + 1))
            else
                warn "$s_type_upper $s_id ($s_host) eksisterer, men er stoppet. Starter instansen..."
                if [ "$s_type" = "vm" ]; then qm start "$s_id"; else pct start "$s_id"; fi
                running=$((running + 1))
            fi
        else
            warn "AFVIGELSE DETEKTERET! $s_type_upper $s_id ($s_host) MANGLER I PROXMOX (slettet)."
            info "Genskaber og udruller $s_host automatisk fra state-definitionen..."
            deploy_instance "$s_type" "$s_id" "$s_host" "$s_ip" "$s_gw" "$s_bridge" "$s_pool" "$s_cust" "$s_role" "$DEFAULT_VM_TEMPLATE" false
            restored=$((restored + 1))
            running=$((running + 1))
        fi
    done < "$STATE_FILE"

    echo ""
    echo -e "${GREEN}========================================================================${NC}"
    echo -e "${GREEN}  RECONCILIATION AFSLUTTET SUCCESFULDT                                  ${NC}"
    echo -e "${GREEN}========================================================================${NC}"
    echo "  Servere kontrolleret: $total"
    echo "  Kørende servere:      $running"
    echo "  Genopbyggede servere: $restored"
    echo -e "${GREEN}========================================================================${NC}"
}

# ------------------------------------------------------------------------------
# 2. KERNEFUNKTION: DEPLOY INSTANCE (VM ELLER CONTAINER)
# ------------------------------------------------------------------------------
deploy_instance() {
    local TARGET_TYPE="$1"
    local ID="$2"
    local HOSTNAME="$3"
    local IP_CIDR="$4"
    local GATEWAY="$5"
    local BRIDGE="$6"
    local POOL="$7"
    local CUST_NAME="$8"
    local ROLE="$9"
    local TEMPLATE_ID="${10:-$DEFAULT_VM_TEMPLATE}"
    local UPDATE_STATE="${11:-true}"

    # Normaliser POOL
    if [ "$POOL" = "-" ] || [ "$POOL" = "none" ] || [ "$POOL" = "null" ]; then
        POOL=""
    fi

    # Normaliser rolle
    local ROLE_DISPLAY BASE_SNIPPET
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

    # --------------------------------------------------------------------------
    # VALIDERINGS- OG SIKKERHEDSKONTROL (OPGAVE PUNKT 6)
    # --------------------------------------------------------------------------
    info "Validerer parametre for $HOSTNAME (ID: $ID)..."

    # ID er et heltal
    if ! [[ "$ID" =~ ^[0-9]+$ ]]; then
        error "ID '$ID' er ugyldigt. Det skal være et positivt heltal."
    fi

    # Template tjek hvis VM
    if [ "$TARGET_TYPE" = "vm" ]; then
        if ! qm status "$TEMPLATE_ID" &>/dev/null; then
            error "Template med ID $TEMPLATE_ID blev ikke fundet i Proxmox! Kør ./create_template_vm.sh først."
        fi
        if ! qm config "$TEMPLATE_ID" | grep -q "template: 1"; then
            error "ID $TEMPLATE_ID er ikke konfigureret som skrivebeskyttet template!"
        fi
    fi

    # Netværk/VNet tjek
    if ! ip link show "$BRIDGE" &>/dev/null; then
        if [ -f "/etc/pve/sdn/vnets.cfg" ] && grep -qw "$BRIDGE" /etc/pve/sdn/vnets.cfg 2>/dev/null; then
            info "SDN VNet '$BRIDGE' er defineret, men ikke aktiv i kernen. Forsøger at genindlæse SDN (pvesdn reload)..."
            pvesdn reload || true
            sleep 1
        fi
        if ! ip link show "$BRIDGE" &>/dev/null; then
            error "Netværk '$BRIDGE' findes ikke som aktiv bridge/VNet på Proxmox værten! Klik 'Apply' under SDN eller kør 'pvesdn reload'."
        fi
    fi

    # IP CIDR format
    if ! [[ "$IP_CIDR" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        error "IP-adresse '$IP_CIDR' er ikke et gyldigt CIDR-format (f.eks. 192.168.10.10/24)."
    fi

    # Gateway format
    if ! [[ "$GATEWAY" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        error "Default Gateway '$GATEWAY' er ugyldig."
    fi

    # Resource Pool hvis angivet
    if [ -n "$POOL" ]; then
        if ! pvesh get /pools | grep -qw "$POOL"; then
            info "Resource Pool '$POOL' findes ikke. Opretter pool automatisk..."
            pvesh create /pools -poolid "$POOL"
        fi
    fi

    # SSH public key
    if [ ! -f "$SSH_PUBKEY_FILE" ]; then
        warn "Fandt ingen SSH-nøgle i $SSH_PUBKEY_FILE. Genererer ny nøgle..."
        mkdir -p "$HOME/.ssh"
        ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_rsa"
    fi

    # --------------------------------------------------------------------------
    # UDRULNING: KVM VM
    # --------------------------------------------------------------------------
    if [ "$TARGET_TYPE" = "vm" ]; then
        info "Kloner template $TEMPLATE_ID -> VM $ID ($HOSTNAME)..."
        local CLONE_CMD=(qm clone "$TEMPLATE_ID" "$ID" --name "$HOSTNAME" --full 1)
        if [ -n "$POOL" ]; then
            CLONE_CMD+=(--pool "$POOL")
        fi

        if ! "${CLONE_CMD[@]}"; then
            error "Kunne ikke klone template $TEMPLATE_ID til VM $ID! Kontroller storage."
        fi

        info "Tilknytter netkort til SDN VNet/Bridge '$BRIDGE'..."
        qm set "$ID" --net0 "virtio,bridge=$BRIDGE"

        info "Klargør Cloud-Init user-data for rolle '$ROLE_DISPLAY'..."
        mkdir -p "$SNIPPETS_DIR"
        local VM_SNIPPET_FILE="$SNIPPETS_DIR/vm-${ID}-userdata.yaml"
        if [ -f "$BASE_SNIPPET" ]; then
            sed "s|__CUSTOMER_NAME__|$CUST_NAME|g" "$BASE_SNIPPET" > "$VM_SNIPPET_FILE"
            qm set "$ID" --cicustom "user=${STORAGE_SNIPPET}:snippets/vm-${ID}-userdata.yaml"
        fi

        info "Konfigurerer Cloud-Init netværk og bruger..."
        qm set "$ID" \
            --ciuser "$DEFAULT_USER" \
            --sshkeys "$SSH_PUBKEY_FILE" \
            --ipconfig0 "ip=$IP_CIDR,gw=$GATEWAY" \
            --nameserver "$DNS_SERVER"

        info "Starter VM $ID..."
        qm start "$ID"

    # --------------------------------------------------------------------------
    # UDRULNING: LXC CONTAINER
    # --------------------------------------------------------------------------
    elif [ "$TARGET_TYPE" = "ct" ]; then
        info "Søger efter Ubuntu LXC template..."
        local LXC_TAR
        LXC_TAR=$(pvesm list "$STORAGE_SNIPPET" | grep "ubuntu.*tar" | awk '{print $1}' | tail -n 1 || true)
        if [ -z "$LXC_TAR" ]; then
            pveam update
            local LATEST_APPLIANCE
            LATEST_APPLIANCE=$(pveam available --section system | grep "ubuntu-" | tail -n 1 | awk '{print $2}')
            pveam download "$STORAGE_SNIPPET" "$LATEST_APPLIANCE"
            LXC_TAR="${STORAGE_SNIPPET}:vztmpl/${LATEST_APPLIANCE}"
        fi

        info "Opretter LXC Container $ID ($HOSTNAME)..."
        local PCT_CMD=(pct create "$ID" "$LXC_TAR" \
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
            error "Kunne ikke oprette container $ID!"
        fi

        sleep 5
        pct exec "$ID" -- bash -c "apt-get update -qq"
        case "$ROLE" in
            web)
                pct exec "$ID" -- bash -c "apt-get install -y -qq nginx curl"
                local IP_RAW="${IP_CIDR%/*}"
                pct exec "$ID" -- bash -c "cat <<HTML > /var/www/html/index.html
<!DOCTYPE html><html><body style='background:#0f172a;color:#fff;font-family:sans-serif;text-align:center;padding:3rem;'>
<h1>Kundeserver i Drift (LXC)</h1>
<p>Kunde: $CUST_NAME | Host: $HOSTNAME | IP: $IP_RAW | Net: $BRIDGE</p>
</body></html>
HTML"
                pct exec "$ID" -- systemctl restart nginx
                ;;
            docker)
                pct exec "$ID" -- bash -c "apt-get install -y -qq docker.io curl"
                pct exec "$ID" -- bash -c "systemctl enable --now docker"
                ;;
            base)
                pct exec "$ID" -- bash -c "apt-get install -y -qq curl htop net-tools ufw"
                ;;
        esac
    fi

    # Gem i state-filen hvis aktiveret
    if [ "$UPDATE_STATE" = true ]; then
        save_state "$ID" "$HOSTNAME" "$IP_CIDR" "$GATEWAY" "$BRIDGE" "$POOL" "$CUST_NAME" "$ROLE" "$TARGET_TYPE"
    fi

    # Afsluttende opsummering
    local IP_ONLY="${IP_CIDR%/*}"
    local TARGET_TYPE_UPPER
    TARGET_TYPE_UPPER="$(echo "$TARGET_TYPE" | tr '[:lower:]' '[:upper:]')"
    echo ""
    echo -e "${GREEN}========================================================================${NC}"
    echo -e "${GREEN}  DEPLOYMENT GENNEMFØRT SUCCESFULDT!                                    ${NC}"
    echo -e "${GREEN}========================================================================${NC}"
    echo "  Type:           $TARGET_TYPE_UPPER"
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
}

# ------------------------------------------------------------------------------
# 3. HOVEDLOGIK & PARSNING AF ARGUMENTER
# ------------------------------------------------------------------------------

# Hvis brugeren angiver en kommando som første argument
if [ "$#" -eq 1 ]; then
    case "$1" in
        sync|apply|reconcile)
            reconcile_state
            exit 0
            ;;
        status|list|state)
            show_state
            exit 0
            ;;
        help|--help|-h)
            usage
            ;;
    esac
fi

# Hvis scriptet køres uden argumenter -> Hovedmenu
if [ "$#" -eq 0 ]; then
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${CYAN}       PROXMOX SDN AUTOMATISERET DEPLOYMENT PLATFORM                    ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    echo ""
    echo "Vælg handling:"
    echo -e "  1) ${BOLD}Synkroniser tilstand (Reconcile)${NC} [Genopbyg manglende/slettede VM'er]"
    echo "  2) Udrul en ny kundeserver (Guidet menu)"
    echo "  3) Vis status for registrerede servere (State oversigt)"
    echo "  4) Afslut"
    read -rp "Valg [1-4, standard 1]: " MAIN_CHOICE

    case "${MAIN_CHOICE:-1}" in
        1)
            reconcile_state
            exit 0
            ;;
        3)
            show_state
            exit 0
            ;;
        4)
            echo "Afslutter."
            exit 0
            ;;
        2)
            # Fortsæt til udrulningsmenuen nedenfor
            ;;
        *)
            reconcile_state
            exit 0
            ;;
    esac

    # Guidet menu til ny server
    echo ""
    echo "Trin 1: Vælg virtualiseringstype:"
    echo "  1) KVM Virtuel Maskine (VM via qm + Cloud-Init) [Standard]"
    echo "  2) LXC Linux Container (CT via pct)"
    read -rp "Valg [1-2, standard 1]: " TYPE_CHOICE
    [ "${TYPE_CHOICE:-1}" = "2" ] && TARGET_TYPE="ct" || TARGET_TYPE="vm"

    echo ""
    echo "Trin 2: Vælg serverrolle:"
    echo "  1) Webserver (Nginx med dynamisk statusportal) [Standard]"
    echo "  2) Docker-server (Docker CE + container runtime)"
    echo "  3) Standard Linux-server (Minimal, hærdet base-server)"
    read -rp "Valg [1-3, standard 1]: " ROLE_CHOICE
    case "${ROLE_CHOICE:-1}" in
        2) ROLE="docker" ;;
        3) ROLE="base" ;;
        *) ROLE="web" ;;
    esac

    case "$ROLE" in
        docker) ROLE_PREFIX="dock" ;;
        base)   ROLE_PREFIX="srv" ;;
        *)      ROLE_PREFIX="web" ;;
    esac

    echo ""
    echo "Trin 3: Vælg kunde (Proxmox SDN Zone 'kundenet'):"
    echo "  1) Kunde Alfa    (SDN VNet: alfa,    VLAN 10, 192.168.10.0/24)"
    echo "  2) Kunde Bravo   (SDN VNet: bravo,   VLAN 20, 192.168.20.0/24)"
    echo "  3) Kunde Charlie (SDN VNet: charlie, VLAN 30, 192.168.30.0/24)"
    echo "  4) Kunde Delta   (SDN VNet: delta,   VLAN 40, 192.168.40.0/24)"
    echo "  5) Anden / Brugerdefineret"
    read -rp "Valg [1-5]: " CUST_CHOICE

    case "$CUST_CHOICE" in
        1)
            CUST_NAME="Kunde Alfa"; BRIDGE="alfa"; GATEWAY="192.168.10.1"
            POOL="Pool_KundeA"; DEFAULT_IP="192.168.10.10/24"; SUGGESTED_ID="111"
            SUGGESTED_HOST="alfa-${ROLE_PREFIX}01"
            ;;
        2)
            CUST_NAME="Kunde Bravo"; BRIDGE="bravo"; GATEWAY="192.168.20.1"
            POOL="Pool_KundeB"; DEFAULT_IP="192.168.20.10/24"; SUGGESTED_ID="121"
            SUGGESTED_HOST="bravo-${ROLE_PREFIX}01"
            ;;
        3)
            CUST_NAME="Kunde Charlie"; BRIDGE="charlie"; GATEWAY="192.168.30.1"
            POOL="Pool_KundeC"; DEFAULT_IP="192.168.30.10/24"; SUGGESTED_ID="131"
            SUGGESTED_HOST="charlie-${ROLE_PREFIX}01"
            ;;
        4)
            CUST_NAME="Kunde Delta"; BRIDGE="delta"; GATEWAY="192.168.40.1"
            POOL="Pool_KundeD"; DEFAULT_IP="192.168.40.10/24"; SUGGESTED_ID="141"
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
    echo "Trin 4: Bekræft parametre:"
    read -rp "Indtast ID [$SUGGESTED_ID]: " ID
    ID="${ID:-$SUGGESTED_ID}"

    read -rp "Indtast Hostname [$SUGGESTED_HOST]: " HOSTNAME
    HOSTNAME="${HOSTNAME:-$SUGGESTED_HOST}"

    read -rp "Indtast IP/CIDR [$DEFAULT_IP]: " IP_CIDR
    IP_CIDR="${IP_CIDR:-$DEFAULT_IP}"

    deploy_instance "$TARGET_TYPE" "$ID" "$HOSTNAME" "$IP_CIDR" "$GATEWAY" "$BRIDGE" "${POOL:-}" "$CUST_NAME" "$ROLE" "$DEFAULT_VM_TEMPLATE" true
    exit 0

else
    # CLI DIREKTE DEPLOYMENT
    if [ "$1" = "vm" ] || [ "$1" = "ct" ]; then
        TARGET_TYPE="$1"
        shift
    else
        TARGET_TYPE="vm"
    fi

    if [ "$#" -lt 5 ]; then
        warn "Utilstrækkeligt antal argumenter ($# givet, mindst 5 krævet)."
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

    deploy_instance "$TARGET_TYPE" "$ID" "$HOSTNAME" "$IP_CIDR" "$GATEWAY" "$BRIDGE" "$POOL" "$CUST_NAME" "$ROLE" "$TEMPLATE_ID" true
fi
