# Projektopgave – Del 4: Automatiseret Deployment

**Udarbejdet af:** Jacob Mikkelsen  
**Dato:** 2. oktober 2026  
**Uddannelse & Fag:** Datatekniker med speciale i infrastruktur (H5)  
**Platform:** Proxmox Virtual Environment (PVE) 8.x / KVM / LXC  
**Git Repository:** `https://github.com/jsmikkelsen/proxmox-deploy.git`  

---

## 1. Design af deployment-løsningen

Formålet med denne del af projektet er at overgå fra tidskrævende, manuelle installationer af Linux-servere til en standardiseret, fuldautomatiseret udrulningsproces baseret på **Templates**, **Cloud-Init** og **Bash Scripting**.

### 1.1 Teknologivalg & Begrundelse
* **Linux Cloud Image:** **Ubuntu 26.04 LTS (Resolute Raccoon)** / **Ubuntu 24.04 LTS (Noble Numbat)** officielle cloud-images fra Canonical.  
  *Begrundelse:* Cloud-images er specifikt minimeret og optimeret til virtualisering. De booter på få sekunder, indeholder ikke overflødige desktop-pakker og leveres med `cloud-init` og `qemu-guest-agent` forberedt.
* **Template vs. Cloud-Init adskillelse:**
  * **I Templaten (Standardserver):** Virtuel hardware, CPU-type (`host`), SCSI-controller (`virtio-scsi-pci`), netkort (`virtio`), seriel konsol (`serial0`), QEMU Guest Agent og Cloud-Init drev (`ide2`).
  * **I Cloud-Init (Den enkelte VM):** Hostname, IP-adresse, subnet maske, default gateway, DNS-server, lokale brugere, SSH-public keys og serverroller (Nginx, Docker).
* **Tildeling af IP-adresser:** Statisk tildeling styret centralt via scriptet med Proxmox `--ipconfig0`. Dette sikrer deterministisk IP-styring i henhold til virksomhedens IP-plan uden afhængighed af DHCP-leases i servernetværkene.
* **Brugere og SSH-adgang:** Root-adgang over password deaktiveres. Der oprettes en dedikeret administratorkonto (`sysadmin`) med administratorernes SSH public keys indsprøjtet direkte via Cloud-Init.
* **Placering på korrekt Bridge/VLAN:** Serverens netkort bindes direkte til kundens dedikerede Linux Bridge (`vmbr10`, `vmbr20`, `vmbr30`, `vmbr40`). Dette opretholder den fysiske og logiske L2-isolation etableret i Del 2.
* **Placering i Resource Pool:** Hver VM placeres i kundens respektive pool (`pool-alfa`, `pool-bravo`, `pool-charlie`, `pool-delta`), hvilket sikrer rollebaseret adgangskontrol (RBAC) og ressourceoverblik.

---

## 2. Standard Linux Template

### 2.1 Egenskaber ved Standard-Templaten
Templaten er skabt med scriptet `create_template_vm.sh` og har ID `9000`. Den er 100% neutral og anonymiseret.

| Komponent | Værdi / Konfiguration | Formål |
| :--- | :--- | :--- |
| **VM-ID** | `9000` | Reserveret ID til gylden skabelon |
| **OS Type** | Linux 2.6+ / 5.x / 6.x (`l26`) | Optimerer KVM-kernen |
| **CPU / RAM** | 2 vCPU (`host`), 2048 MB RAM | Ensartet standard ydelse |
| **Disk Controller** | VirtIO SCSI (`virtio-scsi-pci`) | Højeste I/O hastighed og TRIM/Discard support |
| **Systemdisk** | `scsi0` (+10G udvidelse) | Importeret fra Ubuntu cloud image |
| **Netkort** | VirtIO (`virtio`) på `vmbr0` | Paravirtualiseret netværk |
| **Cloud-Init drev** | `ide2` (`local-lvm:cloudinit`) | Transportbånd til metadata, network-config og user-data |
| **Konsol** | `serial0` (socket) + `vga serial0` | Muliggør visning af xterm.js konsol og tidlige boot-fejl |
| **Guest Agent** | `agent: 1` | Synkronisering af IP og graceful shutdown |

> **Vigtigt designprincip:** Templaten indeholder **INGEN** IP-adresse, **INTET** kundespecifikt hostname og **INGEN** forudindstillede brugere eller SSH-nøgler.

---

## 3. Cloud-Init Konfiguration

Under opstart af en klonet VM indlæser Cloud-Init sine moduler i fire faser:
1. `cloud-init-local`: Finder CD-ROM drevet (`ide2`) med ISO9660-filsystemet indeholdende metadata og netværkskonfiguration.
2. `cloud-init`: Tildeler hostname og sætter statisk IP og default gateway på netkortet.
3. `cloud-config`: Opretter den lokale bruger `sysadmin` og lægger SSH-nøglen i `~/.ssh/authorized_keys`.
4. `cloud-final`: Udfører pakkeopdateringer, installerer software-roller og afvikler tilpassede scripts (`runcmd`).

---

## 4. Automatiseret Installation af Serverrolle (Webserver)

Kravet om automatisk installation af en webserver er implementeret via Proxmox Cloud-Init User-Data Snippets:
* **Sti på Proxmox vært:** `/var/lib/vz/snippets/customer-webserver.yaml`
* **Aktivering:** `qm set <VMID> --cicustom "user=local:snippets/vm-<VMID>-userdata.yaml"`

### Dynamisk Status-Webside
Når serveren booter første gang, afvikles følgende scriptblok automatisk via `runcmd`:
```bash
runcmd:
  - |
    #!/bin/bash
    set -e
    HOSTNAME_VAL=$(hostname)
    IP_VAL=$(hostname -I | awk '{print $1}')
    sed -i "s|__HOSTNAME__|${HOSTNAME_VAL}|g" /var/www/html/index.html
    sed -i "s|__IP_ADDRESS__|${IP_VAL}|g" /var/www/html/index.html
    systemctl restart nginx
    systemctl enable --now qemu-guest-agent
```
Websiden viser i et moderne, responsivt layout:
1. **Kundenavn** (indsat under deployment via `sed` i kildeskabelonen)
2. **Serverens faktiske Hostname**
3. **Serverens aktuelle IP-adresse**
4. **Serverrolle** (Nginx Webserver)

---

## 5 & 6. Deployment Script & Fejlhåndtering (`deploy.sh`)

Scriptet `deploy.sh` samler hele processen og understøtter både direkte argumenter i CLI og en interaktiv menu.

### Fejlhåndtering og validering (Punkt 6):
Før scriptet foretager ændringer i Proxmox, udføres følgende kontroller:
1. **Syntakskontrol:** Tjekker om de nødvendige argumenter er angivet, eller viser en hjælpetekst.
2. **Heltalstjek på ID:** Verificerer med regex, at det angivne ID er et positivt heltal.
3. **Duplikat-tjek:** Afviser deployment hvis VM-ID eller Container-ID allerede eksisterer (`qm status` / `pct status`).
4. **Template-validering:** Bekræfter at kilde-templaten eksisterer og reelt er konfigureret med `template: 1`.
5. **Netværksvalidering:** Tjekker med `ip link show` at den angivne Linux Bridge (fx `vmbr10`) fysisk findes på Proxmox serveren.
6. **IP/CIDR formatkontrol:** Regex-tjekker at IP-adressen indeholder subnet-maske (fx `192.168.10.10/24`).
7. **Gateway validering:** Regex-tjekker at gateway er en gyldig IPv4-adresse.
8. **Resource Pool:** Opretter automatisk poolen via `pvesh`, hvis den endnu ikke findes på hypervisoren.
9. **Klonings-fejlkontrol:** Fanger eventuelle fejl under `qm clone` (f.eks. ved fyldt storage) og afbryder med en forklarende fejlbesked.

---

## 7. Udrulning af de 4 Kundemiljøer

Udrulningen af de fire kundemaskiner blev gennemført med følgende kommandoer:

```bash
# Kunde Alfa (VLAN 10, vmbr10)
./deploy.sh 111 alfa-web01 192.168.10.10/24 192.168.10.1 vmbr10 pool-alfa "Kunde Alfa"

# Kunde Bravo (VLAN 20, vmbr20)
./deploy.sh 121 bravo-web01 192.168.20.10/24 192.168.20.1 vmbr20 pool-bravo "Kunde Bravo"

# Kunde Charlie (VLAN 30, vmbr30)
./deploy.sh 131 charlie-web01 192.168.30.10/24 192.168.30.1 vmbr30 pool-charlie "Kunde Charlie"

# Kunde Delta (VLAN 40, vmbr40)
./deploy.sh 141 delta-web01 192.168.40.10/24 192.168.40.1 vmbr40 pool-delta "Kunde Delta"
```

### Verifikationstabel:

| Kunde | VM-ID | Hostname | IP-Adresse | Bridge | Resource Pool | Web HTTP Status |
| :--- | :---: | :--- | :--- | :---: | :--- | :---: |
| **Alfa** | 111 | `alfa-web01` | `192.168.10.10` | `vmbr10` | `pool-alfa` | HTTP 200 OK |
| **Bravo**| 121 | `bravo-web01`| `192.168.20.10` | `vmbr20` | `pool-bravo`| HTTP 200 OK |
| **Charlie**| 131 | `charlie-web01` | `192.168.30.10` | `vmbr30` | `pool-charlie` | HTTP 200 OK |
| **Delta**| 141 | `delta-web01` | `192.168.40.10` | `vmbr40` | `pool-delta` | HTTP 200 OK |

---

## 8. Test af Reproducerbarhed (Redeployment)

For at dokumentere, at udrulningen er 100% reproducerbar uden manuelle indgreb, blev serveren **`alfa-web01` (VMID: 111)** destrueret og redeployed:

1. **Stop og sletning af VM:**
   ```bash
   qm stop 111
   qm destroy 111 --purge
   ```
2. **Genudrulning via script:**
   ```bash
   ./deploy.sh 111 alfa-web01 192.168.10.10/24 192.168.10.1 vmbr10 pool-alfa "Kunde Alfa"
   ```
3. **Verifikation efter 35 sekunder:**
   * **Netværksping:** `ping -c 3 192.168.10.10` ➔ 0% packet loss.
   * **SSH-adgang:** `ssh sysadmin@192.168.10.10` ➔ Forbindelse etableret med nøgle uden password.
   * **Webserver:** `curl -s http://192.168.10.10/ | grep -E "Kunde|alfa-web01|192.168.10.10"` ➔ Korrekte data fundet i HTML.
   * **Isolation:** Bekræftet at VM'en er låst til `vmbr10` og ikke kan nå andre kunders netværk uden om firewall/gateway.

---

## 9. Bonus: Generisk og Interaktivt Deployment

For at gøre deployment-processen endnu mere brugervenlig og mindske risikoen for menneskelige tastefejl, er `deploy.sh` udstyret med en interaktiv guide.

Hvis scriptet kaldes uden parametre (`./deploy.sh`), præsenteres administratoren for en trin-for-trin menu:
1. **Virtualiseringstype:** KVM VM eller LXC Container.
2. **Serverrolle:** Webserver, Docker-server eller Standard Linux.
3. **Kunde:** Valg mellem Kunde Alfa, Bravo, Charlie, Delta eller Brugerdefineret.

Scriptet slår derefter automatisk de tilhørende infrastrukturværdier op:
* Korrekt Resource Pool (`pool-alfa`, `pool-bravo`, etc.)
* Korrekt Bridge (`vmbr10`, `vmbr20`, etc.)
* Korrekt Gateway (`192.168.10.1`, etc.)
* Forslag til næste ledige IP-adresse og standardiseret hostname (fx `alfa-web01`, `bravo-dock01`).

Administratoren behøver dermed ikke at huske detaljerne om netværk og pools udenad.

---

## 10. Ekstra Bonus: Flere Serverroller

Løsningen er udvidet med understøttelse af tre forskellige serverroller, som kan vælges enten interaktivt eller via CLI-argumentet `[ROLLE]`:

1. **`web` (Webserver - standard):**
   * Installerer `nginx`, `curl`, `qemu-guest-agent`.
   * Genererer den dynamiske HTML-statusside i `/var/www/html/index.html`.
2. **`docker` (Docker Container Platform):**
   * Installerer `docker.io`, `curl`, `qemu-guest-agent`.
   * Starter Docker-dæmonen og klargør velkomstbanner i `/etc/update-motd.d/99-docker-info`.
   * Starter en testcontainer for at bekræfte runtime funktionalitet.
3. **`base` (Standard Hærdet Linux Server):**
   * Installerer `curl`, `htop`, `net-tools`, `ufw`, `qemu-guest-agent`.
   * Konfigurerer SSH motd-banner og aktiverer lokal firewall.

Eksempel på udrulning af en Docker-server til Kunde Alfa:
```bash
./deploy.sh 112 alfa-dock01 192.168.10.11/24 192.168.10.1 vmbr10 pool-alfa "Kunde Alfa" docker
```

---

## 11. Konklusion

Med etableringen af Cloud-Init templaten og det samlede deployment-script er udrulningstiden for nye kundemaskiner reduceret fra 20-30 minutter (manuel ISO-installation) til **under 40 sekunder**.

Menneskelige konfigurationsfejl er elimineret, multitenancy-sikkerheden håndhæves automatisk via pools og bridges, og udrulningsprocessen er fuldt reproducerbar, modulær og forberedt til fremtidig orkestrering.
