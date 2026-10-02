# Tjekliste til Lærerens Spørgsmål: "Hvor ændrer man XX i scriptet?"

Læreren har specifikt varslet:
> *"forvent at i bliver spurgt ind til dele af jeres scripts - forvent at jeg spørger ind til hvor man ændrer i scriptet for at XX sker."*

Her er dine præcise svar og linjerhenvisninger for både `deploy.sh`, `create_template_vm.sh` og Cloud-Init snippeten.

---

### Spørgsmål 1: "Hvor ændrer man IP-adressen og Default Gateway for en VM?"
* **Svar:**  
  I `deploy.sh` modtages de som variablerne `$IP_CIDR` og `$GATEWAY`. Selve injektionen i Cloud-Init sker i sektion 3 under kommandoen:
  ```bash
  qm set "$ID" --ipconfig0 "ip=$IP_CIDR,gw=$GATEWAY"
  ```
* **Hvis læreren spørger:** *"Hvad hvis serveren skal have DHCP i stedet for statisk IP?"*  
  **Svar:** Man ændrer det til:
  ```bash
  qm set "$ID" --ipconfig0 ip=dhcp
  ```

---

### Spørgsmål 2: "Hvor ændrer man, hvilken Linux Bridge / VLAN en VM forbindes til?"
* **Svar:**  
  I `deploy.sh` modtages det i variablen `$BRIDGE` (f.eks. `vmbr10`). Netkortet forbindes i linjen:
  ```bash
  qm set "$ID" --net0 "virtio,bridge=$BRIDGE"
  ```
* **Hvis læreren spørger:** *"Hvad hvis vi kørte med én fælles VLAN-aware bridge (vmbr0) med 802.1Q tags?"*  
  **Svar:** Så ville man tilføje `tag=<VLAN-ID>`:
  ```bash
  qm set "$ID" --net0 "virtio,bridge=vmbr0,tag=10"
  ```

---

### Spørgsmål 3: "Hvor i scriptet ændrer du antallet af CPU-kerner eller tildelt RAM?"
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

### Spørgsmål 4: "Hvor ændrer man, hvilken Resource Pool VM'en lander i?"
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

### Spørgsmål 5: "Hvordan ved websiden, hvad serverens rigtige IP og hostname er, uden at det er hardcodet?"
* **Svar:**  
  Det sker i Cloud-Init user-data snippeten (`snippets/customer-webserver.yaml`) under `runcmd` direktivet ved første boot:
  ```bash
  HOSTNAME_VAL=$(hostname)
  IP_VAL=$(hostname -I | awk '{print $1}')
  sed -i "s/__HOSTNAME__/${HOSTNAME_VAL}/g" /var/www/html/index.html
  sed -i "s/__IP_ADDRESS__/${IP_VAL}/g" /var/www/html/index.html
  ```
  Linux-kernen kender sit eget hostname og sin IP fra Cloud-Init netværksinterfacet. `sed` substituerer derefter pladsholderne i HTML-filen.

---

### Spørgsmål 6: "Hvor ændrer man administratorens brugernavn og SSH-nøgle?"
* **Svar:**  
  I `deploy.sh` under konfigurationssektionen i toppen:
  ```bash
  DEFAULT_USER="sysadmin"
  SSH_PUBKEY_FILE="$HOME/.ssh/id_rsa.pub"
  ```
  Og selve Cloud-Init kommandoen, der overfører det til maskinen, er:
  ```bash
  qm set "$ID" --ciuser "$DEFAULT_USER" --sshkeys "$SSH_PUBKEY_FILE"
  ```

---

### Spørgsmål 7: "Hvad gør `set -euo pipefail` i toppen af jeres scripts?"
* **Svar:**  
  Det er "Bash Strict Mode", der forhindrer usikre scripts:
  * `-e`: Scriptet standser øjeblikkeligt ved første fejl (exit code != 0), så det ikke fortsætter og ødelægger systemet halvt inde i processen.
  * `-u`: Scriptet standser, hvis en variabel ikke er defineret (beskytter mod utilsigtede handlinger på tomme strenge).
  * `-o pipefail`: Sikrer at en fejl i en pipeline (fx `cmd1 | cmd2`) opdages, selvom det sidste program i pipen afsluttede med 0.

---

### Spørgsmål 8: "Hvorfor bruger I `qm clone --full 1` (Full Clone) i stedet for `--full 0` (Linked Clone)?"
* **Svar:**  
  * **Linked Clone (`--full 0`):** Er hurtig og sparer plads via Copy-on-Write, men deler base-disken med templaten. Hvis templaten slettes eller flyttes, går alle maskiner ned.
  * **Full Clone (`--full 1`):** Opretter en 100% uafhængig kopi af diskblokkene. I et multi-tenant produktionsmiljø sikrer det, at kunderne har fuld isolation, og at templaten frit kan opdateres eller slettes senere uden at påvirke eksisterende servere.

---

### Spørgsmål 9: "Hvorfor har I brugt `--cicustom` og en YAML snippet i stedet for bare standard `qm set` parametre?"
* **Svar:**  
  Standard `qm set` parametre (`--ciuser`, `--ipconfig0` osv.) kan kun konfigurere basal netværk og brugeradgang.  
  Med `--cicustom "user=local:snippets/..."` kan vi overføre et fuldt Cloud-Init `#cloud-config` dokument, der giver os adgang til `packages:` (automatisk installation af Nginx), `write_files:` (automatisk oprettelse af websiden) og `runcmd:` (dynamisk kørsel af scripts ved boot). Det eliminerer behovet for eksterne værktøjer som Ansible.

---

### Spørgsmål 10: "Hvor vælger man Ubuntu version (26.04 vs 25.10)?"
* **Svar:**  
  I `create_template_vm.sh` kan man sende versionen som 1. argument:
  ```bash
  ./create_template_vm.sh resolute local-lvm 9000   # For Ubuntu 26.04 LTS
  ./create_template_vm.sh questing local-lvm 9001   # For Ubuntu 25.10
  ```
  Scriptet tilpasser automatisk download-URL'en (`https://cloud-images.ubuntu.com/${RELEASE}/...`) og templatenavnet.
