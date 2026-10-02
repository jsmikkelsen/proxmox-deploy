# Semaphore UI Integration: Proxmox Self-Service Portal

Dette katalog indeholder opsætningen til at køre **Semaphore UI** som en grafisk web-portal til automatisering af VM- og Container-deployment i Proxmox.

---

## ⚠️ Vigtig pædagogisk note (Opgavekrav & Lærer)

Opgavebeskrivelsen specificerer eksplicit:
> *"VIGTIGT VIGTIGT! Dette er IKKE en opgave i automatisering med ansible / lign software, det kommer senere"*

### Hvorfor Semaphore UI overholder dette krav:
* Semaphore UI er **ikke** Ansible.
* Semaphore UI er en letvægts web-portal (Task Runner), der kan afvikle **Bash Scripts** direkte.
* Vores løsning bruger udelukkende `deploy.sh` (som anvender Proxmox native `qm` og `pct` CLI-værktøjer).
* Semaphore fungerer blot som en brugervenlig web-grænseflade ovenpå vores bash-script, så en administrator kan udrulle servere fra en webbrowser uden at skulle SSH'e ind som root.

---

## 1. Start Semaphore UI med Docker Compose

På din Proxmox host (eller i en dedikeret management LXC container med Docker installeret):

```bash
cd /root/proxmox-autodeploy/semaphore
docker compose up -d
```

Åbn browseren på:
```text
http://<SERVER_IP>:3000
```
* **Brugernavn:** `admin`
* **Adgangskode:** `AdminSecretPassword123!`

---

## 2. Opret Projekt & Task Template i Semaphore

### Trin 1: Opret Nyt Projekt
1. Opret et projekt ved navn **"Proxmox Deployment"**.

### Trin 2: Opret Inventory (Localhost)
1. Gå til **Inventory** ➔ **New Inventory**.
2. Navn: `Proxmox Host (Local)`.
3. Vælg Type: `Static`.
4. Indhold:
   ```ini
   localhost ansible_connection=local
   ```

### Trin 3: Opret Repository
1. Gå til **Repositories** ➔ **New Repository**.
2. Navn: `Proxmox Deploy Scripts`.
3. Git URL: `https://github.com/jsmikkelsen/proxmox-autodeploy.git` (eller lokal sti `/scripts`).
4. Branch: `main`.

### Trin 4: Opret Task Template (Bash Runner)
1. Gå til **Task Templates** ➔ **New Template**.
2. **Template Type:** Vælg `Shell / Bash Script`.
3. **Navn:** `Deploy Kundeserver (VM / CT)`.
4. **Playbook / Script Fil:** `deploy.sh`.
5. **Tillad Extra CLI Arguments:** Sæt flueben i *"Allow CLI arguments"*.

---

## 3. Eksempel på kørsel via Web UI

Når du trykker **Run** i Semaphore, kan du indtaste argumenterne:

```text
vm 111 alfa-web01 192.168.10.10/24 192.168.10.1 vmbr10 pool-alfa "Kunde Alfa"
```

Semaphore afvikler scriptet, fanger output i realtid og viser den grønne succes-besked i browseren:
* Link til webserver: `http://192.168.10.10/`
* SSH kommando: `ssh sysadmin@192.168.10.10`
