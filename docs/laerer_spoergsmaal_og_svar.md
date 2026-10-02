# Tjekliste til Lærerens Spørgsmål: "Hvor ændrer man XX i scriptet?"

Læreren har specifikt varslet:
> *"forvent at i bliver spurgt ind til dele af jeres scripts - forvent at jeg spørger ind til hvor man ændrer i scriptet for at XX sker."*  
> *"Dette er IKKE en opgave i automatisering med ansible / lign software, det kommer senere."*

Her er dine præcise svar, tekniske begrundelser og linjehenvisninger for både `deploy.sh`, `create_template_vm.sh`, Cloud-Init YAML-snippets og Proxmox SDN CLI.

---

### Spørgsmål 1: "Hvor ændrer man IP-adressen og Default Gateway for en VM?"
* **Svar:**  
  I `deploy.sh` modtages de som variablerne `$IP_CIDR` og `$GATEWAY`. Selve injektionen i Cloud-Init sker under kommandoen:
  ```bash
  qm set "$ID" --ipconfig0 "ip=$IP_CIDR,gw=$GATEWAY"
  ```
* **Hvis læreren spørger:** *"Hvad hvis serveren skal have DHCP i stedet for statisk IP?"*  
  **Svar:** Man ændrer det til:
  ```bash
  qm set "$ID" --ipconfig0 ip=dhcp
  ```

---

### Spørgsmål 2: "Hvor ændrer man, hvilket netværk / SDN VNet en VM forbindes til?"
* **Svar:**  
  I vores datacenter er netværket opbygget med **Proxmox SDN (Software-Defined Networking)** under zonen `kundenet` på noden `vmh01`.  
  Hver kunde har sit eget dedikerede SDN VNet:
  * **Kunde Alfa:** VNet `alfa` (Tag 10)
  * **Kunde Bravo:** VNet `bravo` (Tag 20)
  * **Kunde Charlie:** VNet `charlie` (Tag 30)
  * **Kunde Delta:** VNet `delta` (Tag 40)
  
  I Proxmox fungerer et SDN VNet som en virtuel bridge for VM'er og containere. I `deploy.sh` modtages det i variablen `$BRIDGE` (f.eks. `alfa`). Netkortet forbindes i linjen:
  ```bash
  qm set "$ID" --net0 "virtio,bridge=$BRIDGE"
  ```
  Fordi 802.1Q VLAN-tagget (f.eks. Tag 10) allerede er defineret centralt på VNet'et i SDN, behøver vi ikke hardcode `tag=10` på netkortet – Proxmox SDN håndterer trunking og isolering automatisk i kernen.

---

### Spørgsmål 3: "Hvad er Proxmox SDN, og hvorfor er det bedre end traditionelle Linux Bridges (`vmbr10`)?"
* **Svar:**  
  * **Traditionelle Bridges:** Kræver manuelle ændringer i `/etc/network/interfaces` på hver enkelt hypervisor-node efterfulgt af genstart af netværket (`ifreload -a`). Det er sårbart over for tastefejl og skalerer dårligt på tværs af et cluster.
  * **Proxmox SDN (Software-Defined Networking):** Centraliserer styringen af netværk via zoner (`zones`) og virtuelle netværk (`vnets`). Konfigurationen replikeres automatisk til alle noder i klyngen via Proxmox Cluster Filesystem (`/etc/pve/sdn/`), og ændringer kan rulles ud uden nedetid med et enkelt klik på **"Apply"** i Web GUI eller via kommandoen `pvesdn reload`.

---

### Spørgsmål 4: "Hvorfor står zonen 'kundenet' som status 'available' med en 'Apply' knap i Web GUI?"
* **Svar:**  
  I Proxmox SDN anvendes en to-trins commit-model for at forhindre utilsigtede netværksafbrydelser:
  1. **Definition:** Man opretter eller redigerer zoner og VNets i GUI/filer. Status markeres som `available` (afventer aktivering).
  2. **Deployment:** Når man klikker på den blå knap **"Apply"** (eller afvikler `pvesdn reload` fra terminalen), genererer Proxmox de underliggende Linux interfaces og ebtables/openvswitch regler i kernen.  
  *Vores deployment-script `deploy.sh` kontrollerer automatisk om VNet'et er aktivt, og kalder `pvesdn reload`, hvis ændringerne afventer aktivering!*

---

### Spørgsmål 5: "Hvor i scriptet ændrer du antallet af CPU-kerner eller tildelt RAM?"
* **Svar:**  
  * **I Templaten:** I `create_template_vm.sh` under `qm create`:
    ```bash
    --memory 2048 --cores 2 --cpu host
    ```
  * **Under deployment i `deploy.sh`:** Hvis en specifik server skal have mere RAM/CPU end standard-templaten, tilføjer man direkte efter kloningen:
    ```bash
    qm set "$ID" --cores 4 --memory 4096
    ```
  * **For LXC Containers:** I `deploy.sh` under `pct create`:
    ```bash
    --cores 2 --memory 1024 --swap 512
    ```

---

### Spørgsmål 6: "Hvor ændrer man disk-størrelsen på VM'en?"
* **Svar:**  
  * **I Templaten:** I `create_template_vm.sh` udvides basisdisken fra ca. 2.2 GB til 12 GB:
    ```bash
    qm disk resize "$TEMPLATE_ID" scsi0 +10G
    ```
  * **Under deployment i `deploy.sh`:** Hvis en serverrolle kræver ekstra diskplads:
    ```bash
    qm disk resize "$ID" scsi0 +20G
    ```
  * **Hvorfor behøver vi ikke partitionere manuelt inde i Linux?**  
    Fordi Ubuntu Cloud Images har Cloud-Init modulerne `growpart` og `resizefs` aktiveret som standard. Ved første boot detekterer kernen automatisk den udvidede disk og udvider ext4-filsystemet til 100% af disken uden nedetid.

---

### Spørgsmål 7: "Hvor ændrer man, hvilken Resource Pool VM'en lander i?"
* **Svar:**  
  I `deploy.sh` sker det direkte under kloningen via `--pool` parameteren:
  ```bash
  qm clone "$TEMPLATE_ID" "$ID" --name "$HOSTNAME" --pool "$POOL" --full 1
  ```
  Og for containers under:
  ```bash
  pct create "$ID" ... --pool "$POOL"
  ```

---

### Spørgsmål 8: "Hvor ændrer man administratorens brugernavn, adgangskode og SSH-nøgle?"
* **Svar:**  
  I `deploy.sh` under konfigurationssektionen i toppen:
  ```bash
  DEFAULT_USER="sysadmin"
  SSH_PUBKEY_FILE="$HOME/.ssh/id_rsa.pub"
  ```
  Selve Cloud-Init kommandoen, der overfører det til maskinens Cloud-Init ISO-drev, er:
  ```bash
  qm set "$ID" --ciuser "$DEFAULT_USER" --sshkeys "$SSH_PUBKEY_FILE"
  ```
  *(Bemærk: Password login er slået fra af hensyn til IT-sikkerhed; al godkendelse foregår kryptografisk via SSH public key).*

---

### Spørgsmål 9: "Hvor ændrer man DNS-serveren for de udrullede servere?"
* **Svar:**  
  I toppen af `deploy.sh` sættes variablen:
  ```bash
  DNS_SERVER="1.1.1.1"
  ```
  Og den injiceres i Cloud-Init med:
  ```bash
  qm set "$ID" --nameserver "$DNS_SERVER"
  ```

---

### Spørgsmål 10: "Hvordan vælges og skiftes serverrolle (Webserver, Docker, Standard Linux)?"
* **Svar:**  
  * **Interaktivt:** Menuen i `deploy.sh` spørger administratoren om serverrolle (1: Web, 2: Docker, 3: Base).
  * **Via CLI:** Sendes som 8. argument, fx:
    ```bash
    ./deploy.sh 112 alfa-dock01 192.168.10.11/24 192.168.10.1 alfa pool-alfa "Kunde Alfa" docker
    ```
  * **I koden:** Scriptet peger på den relevante fil i `snippets/`:
    * Webserver: `snippets/customer-webserver.yaml` (installerer Nginx og genererer HTML)
    * Docker: `snippets/docker-server.yaml` (installerer Docker CE og starter container)
    * Base: `snippets/standard-server.yaml` (minimal/hardened installation med htop, ufw, etc.)

---

### Spørgsmål 11: "Hvordan ved websiden, hvad serverens rigtige IP og hostname er, uden at det er hardcodet?"
* **Svar:**  
  Det sker i Cloud-Init user-data snippeten (`snippets/customer-webserver.yaml`) under `runcmd:` direktivet ved første boot:
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
  ```
  *Forklaring:* I de tidligere boot-faser har Cloud-Init sat hostname og netværk. Under `runcmd` spørger OS'et sig selv med `hostname` og `hostname -I`. Derefter erstatter `sed` pladsholderne i HTML-filen. Kundenavnet er erstattet forinden af `deploy.sh` under kloningen via `sed "s|__CUSTOMER_NAME__|$CUST_NAME|g"`.

---

### Spørgsmål 12: "Hvorfor har I brugt `--cicustom` og en YAML snippet i stedet for kun standard `qm set` parametre?"
* **Svar:**  
  Standard `qm set` parametre (`--ciuser`, `--ipconfig0`, `--nameserver`) kan udelukkende konfigurere basalt netværk og brugeradgang.  
  Med `--cicustom "user=local:snippets/..."` kan vi levere et fuldt Cloud-Init `#cloud-config` dokument, der understøtter:
  1. `packages:` (automatisk installation af software som Nginx og Docker)
  2. `write_files:` (automatisk oprettelse af konfigurationsfiler og HTML-sider)
  3. `runcmd:` (afvikling af opstartsscripts og dæmon-start)
  Dette opfylder opgavens krav om 100% automatiseret rolle-installation helt uden eksterne orkestreringsværktøjer.

---

### Spørgsmål 13: "Hvorfor bruger I IKKE Ansible eller Puppet her?"
* **Svar:**  
  1. **Opgavens pædagogiske mål:** Del 4 handler om at forstå og mestre virtualiseringsplatformens **native** mekanismer (Proxmox CLI, Cloud-Init drive, qemu-guest-agent og Bash).
  2. **Arkitektonisk forskel:** Cloud-Init er en **bootstrap-mekanisme**, der kører indefra maskinen fra sekundet den tænder (før netværk/SSH er aktivt). Ansible er et **post-provisioning værktøj**, der kræver en kørende maskine med fungerende IP, SSH og Python installeret. Cloud-Init klargør maskinen, så den overhovedet kan modtages af Ansible i senere projekter.

---

### Spørgsmål 14: "Hvorfor bruger I `qm clone --full 1` (Full Clone) i stedet for `--full 0` (Linked Clone)?"
* **Svar:**  
  * **Linked Clone (`--full 0`):** Opretter en tynd reference til templaten via Copy-on-Write snapshots. Det sparer plads og er hurtigt, men VM'en er låst til templaten. Hvis templaten slettes, går alle VM'er i stykker.
  * **Full Clone (`--full 1`):** Kopierer alle diskblokke, så den nye VM er 100% uafhængig af templaten. I et multi-tenant produktionsmiljø sikrer dette, at en opdatering eller sletning af en template aldrig kan kompromittere kundernes oppetid.

---

### Spørgsmål 15: "Hvorfor bruger I et Ubuntu Cloud Image i stedet for en standard Ubuntu ISO?"
* **Svar:**  
  * **Standard ISO:** Er designet til mennesker foran en skærm. Kræver en interaktiv installationsproces (eller avanceret autoinstall PXE), tager 15-20 minutter at installere, og fylder typisk 5-10 GB med unødvendige komponenter.
  * **Cloud Image (`.img`):** Er et præfabrikeret, råt diskimage optimeret af Canonical til virtualisering. Det fylder kun ca. 600 MB komprimeret, booter på 5-10 sekunder, og har QEMU Guest Agent og Cloud-Init modulerne præinstalleret.

---

### Spørgsmål 16: "Hvor i scriptet håndteres validering og fejl (Opgave punkt 6)?"
* **Svar:**  
  I `deploy.sh` under sektion 2 ("VALIDERINGS- OG SIKKERHEDSKONTROL"):
  1. **Argumenter:** Tjekker om `$# -lt 6` og viser venlig vejledning med `usage`.
  2. **Numerisk ID:** Regex-tjek `[[ "$ID" =~ ^[0-9]+$ ]]`.
  3. **Duplikat-tjek:** Kalder `qm status "$ID"` / `pct status "$ID"` for at forhindre overskrivelse af eksisterende servere.
  4. **Template-verifikation:** Kontrollerer at templaten eksisterer og har flaget `template: 1`.
  5. **Bridge/VNet-validering:** Tjekker med `ip link show "$BRIDGE"` at netværket findes. Hvis det findes i `/etc/pve/sdn/vnets.cfg` men mangler i kernen, kalder scriptet automatisk `pvesdn reload`.
  6. **IP/CIDR kontrol:** Regex-validerer IPv4-format med maske (fx `192.168.10.10/24`).
  7. **Kloning-fejl:** `if ! qm clone ...; then error ... fi` fanger manglende diskplads eller storage-fejl.

---

### Spørgsmål 17: "Hvad gør `set -euo pipefail` i toppen af scriptet?"
* **Svar:**  
  Det er "Bash Strict Mode":
  * `-e` (*errexit*): Scriptet standser straks, hvis en kommando returnerer en fejlkode (!= 0).
  * `-u` (*nounset*): Scriptet crasher med en fejl, hvis man forsøger at tilgå en variabel, der ikke er defineret.
  * `-o pipefail`: I pipelines som `cmd1 | cmd2` ignoreres det ikke, hvis `cmd1` fejler, selvom `cmd2` afslutter med 0.

---

### Spørgsmål 18: "Hvordan sikres netværks- og kundeisolation mellem de 4 kunder?"
* **Svar:**  
  Isolation opretholdes på tre niveauer:
  1. **Layer 2 (Data Link) via SDN:** Hver kunde er isoleret i sit eget SDN VNet (`alfa`, `bravo`, `charlie`, `delta`) med separate 802.1Q tags (10, 20, 30, 40) under zonen `kundenet`. Broadcasts og ARP-pakker kan ikke krydse mellem VNets.
  2. **Layer 3 (Network):** Hver kunde har sit eget IP-subnet (fx `192.168.10.0/24`, `192.168.20.0/24`). Al kommunikation mellem subnets skal passere virksomhedens firewall/router.
  3. **Management / Proxmox RBAC:** Hver VM placeres i en dedikeret Proxmox Resource Pool (`pool-alfa`, etc.), hvor adgangskontrol styrer, hvilke administratorer/brugere der må se og administrere maskinerne.

---

### Spørgsmål 19: "Hvad er QEMU Guest Agent (`qemu-guest-agent`), og hvordan aktiveres den?"
* **Svar:**  
  En dæmon der kører inde i det virtuelle operativsystem og taler med Proxmox hypervisoren via en VirtIO seriel kanal (`vport`).  
  * **Hvorfor er den nødvendig?**  
    1. Den rapporterer gæstens aktuelle IP-adresser direkte til Proxmox Web GUI.
    2. Den muliggør sikker og ren nedlukning (*graceful shutdown*) i stedet for hårdt ACPI-strømafbrydelse.
    3. Den fryser filsystemet (*fs-freeze*) under live Proxmox backups, så data ikke korrumperes.
  * **Hvordan aktiveres den?**  
    I `create_template_vm.sh`: `qm set "$TEMPLATE_ID" --agent enabled=1`  
    I gæsten: `systemctl enable --now qemu-guest-agent`.

---

### Spørgsmål 20: "Hvordan bevises det, at deployment er 100% reproducerbart (Opgave punkt 8)?"
* **Svar:**  
  1. Man noterer en kundeserves data (fx `alfa-web01`, ID 111, IP `192.168.10.10`, SDN VNet `alfa`).
  2. Man sletter serveren fuldstændigt:
     ```bash
     qm stop 111 && qm destroy 111 --purge
     ```
  3. Man genudruller med én enkelt script-kommando:
     ```bash
     ./deploy.sh 111 alfa-web01 192.168.10.10/24 192.168.10.1 alfa pool-alfa "Kunde Alfa"
     ```
  4. Efter 35 sekunder tilgår man `http://192.168.10.10/` og `ssh sysadmin@192.168.10.10`. Alt fungerer fejlfrit uden at administratoren har rørt ved maskinen.
