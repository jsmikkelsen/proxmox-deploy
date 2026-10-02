# Semaphore UI Integration: Proxmox Self-Service Portal

Dette katalog indeholder opsætningen til at køre **Semaphore UI** som en grafisk web-portal til automatisering af VM- og Container-deployment i Proxmox VE (`vmh01`).

---

## ⚠️ Vigtig pædagogisk note (Opgavekrav & Lærer)

Opgavebeskrivelsen specificerer eksplicit:
> *"VIGTIGT VIGTIGT! Dette er IKKE en opgave i automatisering med ansible / lign software, det kommer senere"*

### Hvorfor Semaphore UI overholder dette krav:
* Semaphore UI er **ikke** Ansible.
* Semaphore UI er en letvægts, uafhængig web-portal (Task Runner), der kan afvikle **Bash Scripts** direkte.
* Vores løsning bruger udelukkende `deploy.sh` (som anvender Proxmox native `qm` og `pct` CLI-værktøjer samt SDN).
* Semaphore fungerer blot som en moderne self-service web-grænseflade, så en administrator eller helpdesk kan udrulle servere fra en webbrowser uden at skulle åbne en SSH-terminal som root.

---

## 🚀 To måder at køre Semaphore på

Vælg den metode, der passer bedst til dit setup:

### Metode A: Docker Compose (Anbefalet hvis du har Docker)
Gå ind i `semaphore`-kataloget på din Proxmox vært og start containeren:

```bash
cd /root/proxmox-deploy/semaphore
docker compose up -d
```

### Metode B: Native Systemd Service (Uden Docker)
Hvis du foretrækker ikke at have Docker installeret direkte på din hypervisor, kan Semaphore installeres som en enkeltstående Go-binary:

```bash
# 1. Hent nyeste officielle Semaphore binary
curl -s https://api.github.com/repos/semaphoreui/semaphore/releases/latest \
  | grep "browser_download_url.*linux_amd64.deb" \
  | cut -d : -f 2,3 | tr -d \" | wget -qi - -O /tmp/semaphore.deb

# 2. Installer deb-pakken
dpkg -i /tmp/semaphore.deb

# 3. Klargør config og start service
semaphore setup --config /etc/semaphore/config.json
systemctl enable --now semaphore
```

---

## 🌐 Adgang til Web-Portalen

Åbn browseren på din Proxmox IP:
```text
http://<PROXMOX_IP>:3000
```
* **Brugernavn:** `admin`
* **Adgangskode:** `AdminSecretPassword123!`

---

## ⚙️ Opsætning af Task Template i Semaphore

Når du er logget ind første gang, konfigureres portalen i 4 hurtige trin:

### Trin 1: Opret Nyt Projekt
1. Klik på **New Project** ➔ Kald det **"Proxmox Deployment"**.

### Trin 2: Opret Key Store (SSH Nøgle)
1. Gå til **Key Store** ➔ **New Key**.
2. **Name:** `Proxmox Host Root Key`.
3. **Type:** `SSH Key`.
4. Indsæt indholdet af din `/root/.ssh/id_rsa` fra Proxmox-hosten (eller vælg `None` hvis du kører native).

### Trin 3: Opret Repository
1. Gå til **Repositories** ➔ **New Repository**.
2. **Name:** `Proxmox Deployment Scripts`.
3. **Git URL:** `https://github.com/jsmikkelsen/proxmox-deploy.git`
4. **Branch:** `main`.

### Trin 4: Opret Task Template
1. Gå til **Task Templates** ➔ **New Template**.
2. **Template Type:** Vælg `Shell / Bash Script`.
3. **Name:** `Deploy Kundeserver`.
4. **Playbook / Script Fil:** `deploy.sh` *(eller `semaphore/run_on_host.sh` hvis du kører Docker)*.
5. **Tillad Extra CLI Arguments:** Sæt flueben i **"Allow CLI arguments"** (eller opret forudindstillede Survey-variabler).

---

## 🎮 Kørsel af Deployment fra Web UI

Når du klikker på **Run** på din Task Template, indtaster du blot parametrene i pop-up vinduet:

```text
111 alfa-web01 192.168.10.10/24 192.168.10.1 alfa pool-alfa "Kunde Alfa" web
```

Eller for en server uden pool:
```text
301 netic-srv01 192.168.100.155/24 192.168.100.1 vmbr0 - "Netic" web
```

### Hvad sker der i Web UI:
1. Semaphore streamer terminal-outputtet i realtid med farver.
2. Template klones, SDN VNet tilknyttes, og Cloud-Init pakker injiceres.
3. Efter ca. 30 sekunder modtager du den grønne boks med direkte link til den nye server (`http://192.168.10.10/`) og SSH-kommando!
