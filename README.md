# Proxmox Automated Deployment Platform (Del 4)

Komplet automatiseringsløsning til udrulning af standardiserede Linux-servere (KVM Virtuelle Maskiner og LXC Containers) i Proxmox VE ved hjælp af **Cloud-Init**, **Bash-automatisering** og valgfri **Semaphore UI Self-Service Portal**.

Projektet er udviklet som en del af **Infrastrukturprojekt – Del 4: Automatiseret deployment** (H5 Datatekniker).

---

## 📁 Repository Struktur

```text
proxmox-autodeploy/
├── create_template_vm.sh       # Henter Ubuntu 25/26 cloud-image og bygger KVM VM-template (qm)
├── create_template_ct.sh       # Henter officiel Ubuntu LXC template via pveam
├── deploy.sh                   # Universelt deployment-script til både VM og CT med validering
├── snippets/
│   └── customer-webserver.yaml # Cloud-Init snippet: installerer Nginx og genererer dynamisk status-side
├── semaphore/
│   ├── docker-compose.yml      # Starter Semaphore UI web-portal som Docker container
│   └── README.md               # Guide til opsætning af Semaphore som Bash Runner
└── docs/
    ├── opgavebesvarelse_del4.md        # Komplet besvarelse af alle opgavens 9 krav
    └── laerer_spoergsmaal_og_svar.md  # Tjekliste til eksamination ("Hvor ændrer man XX?")
```

---

## 🚀 Hurtig Start-Vejledning

### Trin 1: Klargør Proxmox Værten
Klon dette repository ind på din Proxmox VE vært (eller kopiér filerne):
```bash
git clone https://github.com/jsmikkelsen/proxmox-autodeploy.git /root/proxmox-autodeploy
cd /root/proxmox-autodeploy
chmod +x *.sh
```

Aktivér Proxmox snippets storage, hvis det ikke allerede er gjort:
```bash
pvesm set local --content snippets,iso,vztmpl,backup
mkdir -p /var/lib/vz/snippets
cp snippets/customer-webserver.yaml /var/lib/vz/snippets/
```

---

### Trin 2: Opret Standard VM-Template (Ubuntu 26.04 / 25.10)

Kør scriptet for at oprette templaten med ID `9000`:
```bash
# Opret Ubuntu 26.04 LTS template (standard):
./create_template_vm.sh resolute local-lvm 9000

# (Valgfrit) Opret Ubuntu 25.10 template:
./create_template_vm.sh questing local-lvm 9001
```

---

### Trin 3: Deploy Kundeserverne

Scriptet `deploy.sh` kan afvikles på to måder:

#### Metode A: Interaktiv Menu (Anbefalet)
Kør blot scriptet uden parametre:
```bash
./deploy.sh
```
Du guides gennem en interaktiv menu, hvor du vælger:
* Type: **1) KVM VM** eller **2) LXC Container**
* Kunde: **Alfa**, **Bravo**, **Charlie** eller **Delta**
* Scriptet foreslår automatisk korrekt Bridge, Gateway, Resource Pool og IP-adresse!

#### Metode B: Direkte CLI-kommandoer (Opgavekrav)
```bash
# Kunde Alfa (VLAN 10, vmbr10):
./deploy.sh 111 alfa-web01 192.168.10.10/24 192.168.10.1 vmbr10 pool-alfa "Kunde Alfa"

# Kunde Bravo (VLAN 20, vmbr20):
./deploy.sh 121 bravo-web01 192.168.20.10/24 192.168.20.1 vmbr20 pool-bravo "Kunde Bravo"

# Kunde Charlie (VLAN 30, vmbr30):
./deploy.sh 131 charlie-web01 192.168.30.10/24 192.168.30.1 vmbr30 pool-charlie "Kunde Charlie"

# Kunde Delta (VLAN 40, vmbr40):
./deploy.sh 141 delta-web01 192.168.40.10/24 192.168.40.1 vmbr40 pool-delta "Kunde Delta"
```

---

### Trin 4: Udrulning af LXC Container (CT)
Vil du oprette en container i stedet for en virtuel maskine, tilføjer du blot `ct` foran:
```bash
./deploy.sh ct 211 alfa-ct01 192.168.10.20/24 192.168.10.1 vmbr10 pool-alfa "Kunde Alfa"
```

---

## 🌐 Web-Portal med Semaphore UI (Bonus / Self-Service)

Hvis du ønsker en grafisk web-portal, hvor helpdesk eller kolleger kan udrulle servere via en webformular i stedet for at logge ind via SSH, startes Semaphore UI:

```bash
cd semaphore
docker compose up -d
```
Åbn `http://<PROXMOX_IP>:3000` (Login: `admin` / `AdminSecretPassword123!`).  
Se den detaljerede vejledning i [`semaphore/README.md`](semaphore/README.md).

---

## 📚 Detaljeret Dokumentation

* **[Opgavebesvarelse Del 4](docs/opgavebesvarelse_del4.md):** Komplet teknisk gennemgang af alle opgavens krav 1 til 9.
* **[Lærerens Tjekliste](docs/laerer_spoergsmaal_og_svar.md):** Hurtig reference til *"Hvor ændrer man XX i scriptet?"* til eksaminationen.
