# Proxmox Automated Deployment Platform (Del 4)

Komplet automatiseringsløsning til udrulning af standardiserede Linux-servere (KVM Virtuelle Maskiner og LXC Containers) i Proxmox VE ved hjælp af **Cloud-Init**, **Bash-automatisering** og valgfri **Semaphore UI Self-Service Portal**.

Projektet er udviklet som en del af **Infrastrukturprojekt – Del 4: Automatiseret deployment** (H5 Datatekniker).

> **VIGTIGT:** Løsningen er baseret på **100% native Proxmox CLI-værktøjer (`qm`, `pct`, `pvesm`), Cloud-Init og Bash**. Der anvendes **IKKE** Ansible eller lignende orkestreringssoftware, i overensstemmelse med opgavekravene.

---

## 📁 Repository Struktur

```text
proxmox-deploy/
├── create_template_vm.sh       # Henter Ubuntu cloud-image og bygger KVM VM-template (qm)
├── create_template_ct.sh       # Henter officiel Ubuntu LXC template via pveam
├── deploy.sh                   # Universelt deployment-script til både VM og CT med validering
├── snippets/
│   ├── customer-webserver.yaml # Cloud-Init: Webserver-rolle (Nginx + dynamisk HTML portal)
│   ├── docker-server.yaml      # Cloud-Init: Docker-rolle (Docker CE + container runtime)
│   └── standard-server.yaml    # Cloud-Init: Standard Linux-rolle (Minimal, hærdet base)
├── semaphore/
│   ├── docker-compose.yml      # Starter Semaphore UI web-portal som Docker container
│   └── README.md               # Guide til opsætning af Semaphore som Bash Runner
└── docs/
    ├── opgavebesvarelse_del4.md        # Komplet besvarelse af alle opgavens krav 1 til 9 + bonusser
    └── laerer_spoergsmaal_og_svar.md  # Eksamens-tjekliste ("Hvor ændrer man XX i scriptet?")
```

---

## 🚀 Hurtig Start-Vejledning

### Trin 1: Klargør Proxmox Værten
Klon dette repository ind på din Proxmox VE vært:
```bash
git clone https://github.com/jsmikkelsen/proxmox-deploy.git /root/proxmox-deploy
cd /root/proxmox-deploy
chmod +x *.sh
```

Aktivér Proxmox snippets storage og kopiér Cloud-Init skabelonerne:
```bash
pvesm set local --content snippets,iso,vztmpl,backup
mkdir -p /var/lib/vz/snippets
cp snippets/*.yaml /var/lib/vz/snippets/
```

---

### Trin 2: Opret Standard VM-Template

Kør scriptet for at oprette den gyldne skabelon med ID `9000`:
```bash
# Opret Ubuntu 26.04 LTS template (standard):
./create_template_vm.sh resolute local-lvm 9000

# (Alternativt) Opret Ubuntu 24.04 LTS template:
./create_template_vm.sh noble local-lvm 9000
```

---

### Trin 3: Deploy Kundeserverne

Scriptet `deploy.sh` kan afvikles på to måder:

#### Metode A: Interaktiv Menu (Bonus)
Kør blot scriptet uden parametre for at få en guidet menu:
```bash
./deploy.sh
```
Du vælger blot:
1. Virtualisering: **VM** eller **Container**
2. Serverrolle: **Webserver**, **Docker-server** eller **Standard Linux**
3. Kunde: **Alfa**, **Bravo**, **Charlie** eller **Delta**
*Scriptet udfylder og foreslår automatisk Bridge, Gateway, Resource Pool, IP og Hostname!*

#### Metode B: Direkte CLI-kommandoer (Opgavekrav)
Format: `./deploy.sh [vm|ct] <ID> <HOSTNAME> <IP/CIDR> <GATEWAY> <SDN_VNET> <POOL> [KUNDE] [ROLLE]`

```bash
# Kunde Alfa (SDN VNet 'alfa', VLAN 10, Nginx webserver):
./deploy.sh 111 alfa-web01 192.168.10.10/24 192.168.10.1 alfa pool-alfa "Kunde Alfa"

# Kunde Bravo (SDN VNet 'bravo', VLAN 20, Nginx webserver):
./deploy.sh 121 bravo-web01 192.168.20.10/24 192.168.20.1 bravo pool-bravo "Kunde Bravo"

# Kunde Charlie (SDN VNet 'charlie', VLAN 30, Nginx webserver):
./deploy.sh 131 charlie-web01 192.168.30.10/24 192.168.30.1 charlie pool-charlie "Kunde Charlie"

# Kunde Delta (SDN VNet 'delta', VLAN 40, Nginx webserver):
./deploy.sh 141 delta-web01 192.168.40.10/24 192.168.40.1 delta pool-delta "Kunde Delta"
```

#### Udrulning med andre Serverroller (Ekstra Bonus)
```bash
# Deploy en Docker-server til Kunde Alfa:
./deploy.sh 112 alfa-dock01 192.168.10.11/24 192.168.10.1 alfa pool-alfa "Kunde Alfa" docker

# Deploy en minimal standard base-server til Kunde Bravo:
./deploy.sh 122 bravo-srv01 192.168.20.11/24 192.168.20.1 bravo pool-bravo "Kunde Bravo" base
```

---

### Trin 4: Udrulning af LXC Container (CT)
Vil du oprette en container i stedet for en virtuel maskine, tilføjer du blot `ct` foran:
```bash
./deploy.sh ct 211 alfa-ct01 192.168.10.20/24 192.168.10.1 alfa pool-alfa "Kunde Alfa" web
```

---

### Trin 5: Test af Reproducerbarhed (Krav 8)
Slet maskinen og redeploy på under 40 sekunder:
```bash
# 1. Stop og slet
qm stop 111 && qm destroy 111 --purge

# 2. Redeploy med én kommando
./deploy.sh 111 alfa-web01 192.168.10.10/24 192.168.10.1 alfa pool-alfa "Kunde Alfa"
```
# 3. Verificér webserver
curl http://192.168.10.10/
```

---

## 🌐 Web-Portal med Semaphore UI (Bonus / Self-Service)

Hvis du ønsker en grafisk web-portal, hvor helpdesk eller kolleger kan udrulle servere via en webformular i stedet for at logge ind via SSH, startes Semaphore UI:

```bash
cd semaphore
docker compose up -d
```
Åbn `http://<PROXMOX_IP>:3000` (Login: `admin` / `AdminSecretPassword123!`).  
*(Bemærk: Semaphore er konfigureret til at køre rene Bash-scripts – ikke Ansible)*.  
Se den detaljerede vejledning i [`semaphore/README.md`](semaphore/README.md).

---

## 📚 Detaljeret Dokumentation

* **[Opgavebesvarelse Del 4](docs/opgavebesvarelse_del4.md):** Komplet teknisk gennemgang af opgavens krav 1 til 9 samt bonusser.
* **[Lærerens Tjekliste](docs/laerer_spoergsmaal_og_svar.md):** Udtømmende reference til *"Hvor ændrer man XX i scriptet?"* med 20 spørgsmål og svar til eksaminationen.
