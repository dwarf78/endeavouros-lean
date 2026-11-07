# 04 — Home Server Proxmox VE + Fastweb (ThinkPad, Razer, iPhone)

Versione: 2026-11-05 · Documento operativo, **non** installer unattended. Da aggiungere al repository `dwarf78/endeavouros-lean` come quarto file.

> **Prima di iniziare:** installare Proxmox VE **cancella i dischi selezionati** del mini PC. Fare backup e identificare con certezza il disco. Non installare Proxmox sui laptop. Nessuna password, chiave VPN, token GitHub o configurazione privata deve essere caricata su GitHub.

## 1. Acquisti (Amazon Italia)

**Scelta economica verificata come inserzione Amazon.it:** Beelink MINI-S13 Pro Intel N150, 16 GB RAM, SSD 500 GB, rete dichiarata dual 2.5GbE, prezzo indicativo **€379** (fonte Trovaprezzi, rilevazione novembre 2026). [Ricerca Amazon.it Beelink MINI-S13 Pro](https://www.amazon.it/s?k=Beelink+MINI+S13+Pro+N150+16GB+500GB). Controllare sulla scheda della **specifica variante** le due porte Ethernet, la possibilità di espandere RAM e SSD e la garanzia. Il prezzo e la disponibilità non sono garantiti.

**Scelta consigliata per il progetto completo:** preferire un mini PC x86-64 con **32 GB RAM (espandibile a 64 GB), 1 TB NVMe, CPU Ryzen 5/7 a 6–8 core o Intel equivalente, almeno 1 Ethernet cablata**; ideale seconda porta 2.5 GbE e secondo alloggiamento SSD. [Ricerca Amazon.it mini PC Ryzen 32GB 1TB dual LAN](https://www.amazon.it/s?k=mini+pc+ryzen+32gb+1tb+dual+lan). **Non è stata verificata una specifica offerta Amazon** per questa fascia: confrontare venditore e SKU prima dell'acquisto. Per Immich + Nextcloud + Syncthing + VM e backup, 16 GB/N150 è una configurazione ridotta e non la scelta ottimale.

**UPS:** Eaton **5E Gen2 900 USB IEC (5E900UI)**, 900 VA, collegamento USB di monitoraggio e uscite IEC C13, prezzo indicativo **€90–100** (non vincolante). [Ricerca Amazon.it Eaton 5E900UI](https://www.amazon.it/s?k=Eaton+5E900UI). Controllare se servono cavi IEC C14→C13 per mini PC/router o scegliere versione con prese DIN italiane. Il collegamento **USB dati** è indispensabile per spegnimento automatico con NUT. Autonomia reale dipende dal carico e dalla batteria: fare test pratico, non promettere minuti precisi.

**Storage:** SSD/NAS o disco USB dedicato per backup, separato dal disco delle VM; per libreria fotografica importante prevedere almeno un secondo backup offline o esterno. SSD di sistema e backup non sono intercambiabili.

## 2. Architettura consigliata

```text
Internet — Fastweb Nexxt — Ethernet — Mini PC Proxmox VE (host, solo LAN)
                                |
                                +-- VM Debian 13 / Ubuntu LTS: Docker Compose
                                |     +-- Immich (foto/video iPhone)
                                |     +-- Nextcloud (file, calendario, contatti)
                                |     +-- Syncthing (cartelle ThinkPad/Razer/Möbius iPhone)
                                |     +-- Uptime Kuma (monitoraggio)
                                |     +-- Vaultwarden (OPZIONALE, con backup e TLS)
                                |
                                +-- VM/LXC separata: Tailscale oppure WireGuard (accesso remoto)
                                +-- Proxmox Backup Server su disco/host separato (opzionale)
UPS USB dati —> Proxmox host (NUT) —> shutdown ordinato guest/host
```

**«Neocloud»** è ambiguo: in questa guida interpreto la richiesta come **Nextcloud**, il cloud personale open source. Se intendi un prodotto diverso chiamato NeoCloud, identificare progetto e URL prima di installarlo.

**Scelta VM anziché LXC per Docker/Immich:** la documentazione Immich raccomanda una VM Linux completa per ambienti virtualizzati e non raccomanda Docker dentro LXC come percorso standard. Proxmox resta hypervisor: **non installare Docker direttamente sull'host**.

## 3. Dimensionamento iniziale

| Profilo | Proxmox host | VM applicazioni | Storage |
|---|---|---|---|
| N150 / 16 GB | Riserva 3–4 GB | 8–10 GB, 2–4 vCPU; evitare ML Immich pesante | 500 GB SSD per avvio/test; foto su storage dedicato |
| Ryzen / 32 GB | Riserva 4–6 GB | 16–20 GB, 4–6 vCPU | 1 TB NVMe + disco dati/backup separato |

Immich richiede **almeno 6 GB RAM**, preferibilmente 8 GB, e almeno 2 core; non assegnare tutta la RAM al guest. Il disco DB PostgreSQL Immich deve essere locale e con filesystem Linux, non NTFS/exFAT e non share di rete.

## 4. Installazione Proxmox VE (fase manuale distruttiva)

1. Sul ThinkPad/Razer aprire **https://www.proxmox.com/en/downloads** e scaricare ISO Proxmox VE ufficiale; verificare checksum secondo istruzioni del sito.
2. Preparare chiavetta USB avviabile con strumento affidabile (ad es. KDE ISO Image Writer). **La chiavetta sarà cancellata.**
3. Collegare mini PC a router Nexxt con Ethernet, tastiera e monitor temporanei; in BIOS/UEFI abilitare Intel VT-x/AMD-V, boot USB, e *Restore on AC Power Loss* se disponibile. Aggiornamenti BIOS solo secondo vendor.
4. Avviare installer USB, selezionare **solo** disco di sistema destinato a Proxmox, verificare seriale e capacità, confermare cancellazione. Per singolo SSD e 16–32 GB RAM, filesystem ext4/LVM è una scelta semplice; ZFS solo dopo valutazione RAM/dischi e backup.
5. Impostare hostname es. `pve-home.lan`, IP **statico o prenotazione DHCP** nella LAN (esempio documentale `192.168.1.50`, da sostituire dopo aver verificato la subnet Nexxt), gateway e DNS corretti. **Non usare l'IP di esempio senza verifica.**
6. Dal browser Firefox su laptop aprire `https://IP_SERVER:8006`. Certificato iniziale self-signed: verificare IP/identità prima di accettare eccezione locale.
7. Aggiornare host dalla GUI con repository appropriati per installazione senza abbonamento, seguendo la documentazione Proxmox per la **versione installata**. Non incollare repository di versioni precedenti.
8. Creare storage separato per backup, configurare notifiche email, account amministrativo con MFA; evitare uso quotidiano dell'utente root.

## 5. VM Debian per self-hosting

In Proxmox GUI: caricare ISO Debian 13 netinst (oppure Ubuntu Server LTS supportato), creare VM con CPU type `host` se compatibile, VirtIO SCSI, VirtIO network, QEMU guest agent; installare sistema, `openssh-server`, `qemu-guest-agent`, Docker Engine e plugin Compose **seguendo i repository ufficiali Docker per quella distribuzione**. Abilitare aggiornamenti di sicurezza e firewall. Creare utente non-root con sudo; accesso SSH solo con chiave dove possibile.

Schema cartelle proposto sulla VM:

```text
/srv/compose/immich/      # compose ufficiale + .env non in git
/srv/compose/nextcloud/   # compose/versione pinning da documentazione ufficiale
/srv/compose/syncthing/   # compose + volumi
/srv/compose/uptime-kuma/
/srv/data/photos/         # media Immich, backup separato
/srv/data/nextcloud/      # dati Nextcloud
/srv/data/syncthing/      # cartelle scelte
/srv/backups/             # destinazione temporanea, poi copia esterna
```

**Ordine installazione:** Docker/Compose → storage/permessi → Syncthing → Immich → Nextcloud → Uptime Kuma → accesso remoto VPN → backup/UPS → eventuali app opzionali. Non pubblicare i pannelli amministrativi su Internet.

### Immich

Seguire **https://docs.immich.app/install/docker-compose/** e **https://docs.immich.app/overview/quick-start/**. Usare i file compose e `.env` **della stessa release** e non inventare un compose minimale che salta database o Redis. Impostare `UPLOAD_LOCATION` sul volume dati e `DB_DATA_LOCATION` su SSD Linux locale; impostare timezone, password forte e backup PostgreSQL + foto. Configurare app Immich su iPhone per backup foto; **Immich non sostituisce il backup indipendente**.

### Nextcloud (non «neocloud» senza conferma)

Usare installazione documentata e versionata (Nextcloud AIO se prerequisiti compatibili, oppure stack Docker ufficialmente supportato). Prima della messa in servizio definire dominio/HTTPS o accesso solo VPN, DB PostgreSQL/MariaDB, Redis, cron, limiti upload, backup DB+data+config. App Nextcloud su iPhone e accesso via Firefox/Dolphin WebDAV dai laptop.

### Syncthing

Syncthing sul server in container con volume persistente per configurazione e dati; GUI **solo LAN/VPN**, non esporre porta 8384 su Internet. Abbinare Device ID del server con ThinkPad, Razer e Möbius Sync su iPhone; approvare cartelle esplicitamente. **Non sincronizzare** `~/.ssh`, profili browser, database vivi, dischi VM o directory Immich/Nextcloud gestite dalle applicazioni. Per documenti usare una cartella dedicata come `~/Sync/Documenti`. Su iOS la sincronizzazione in background è limitata: aprire Möbius Sync per completare i trasferimenti.

### Altre applicazioni utili

- **Uptime Kuma:** monitoraggio HTTP e disponibilità dei servizi, notifiche.
- **Tailscale** o **WireGuard:** accesso remoto senza aprire pubblicamente Proxmox; Tailscale spesso funziona anche dietro CGNAT, previa verifica connettività.
- **Gitea/Forgejo** (opzionale): repository Git locali; **GitHub resta repository primario** per `endeavouros-lean`, evitando conflitti di sincronizzazione bidirezionale.
- **Jellyfin** (opzionale): media server, attenzione allo spazio e transcoding.
- **Paperless-ngx** (opzionale): archivio documenti con OCR; valutare risorse.
- **Home Assistant** (opzionale): meglio VM dedicata se prevista automazione domestica.
- **Pi-hole/AdGuard Home** (opzionale): DNS di rete, **non** cambiare DNS/DHCP del Nexxt prima di aver verificato rollback per smart working e PS5.
- **Proxmox Backup Server:** ideale su macchina/disco separato; uno snapshot non è un backup.

## 6. Fastweb Nexxt, accesso sicuro e LAN

1. Collegare mini PC via Ethernet; configurare DHCP reservation sul Nexxt **solo se disponibile** oppure IP statico coerente con rete e fuori dal pool DHCP.
2. Verificare subnet/gateway sul laptop: `ip route` e `ip -br addr`; evitare conflitti IP.
3. Non attivare port forwarding per Proxmox `8006`, Syncthing GUI `8384`, SSH `22`, Nextcloud o Immich come prima scelta.
4. Installare Tailscale sul server/VM e sui laptop/iPhone, autenticare ogni dispositivo, abilitare MFA e ACL; usare VPN per accesso remoto. Fastweb potrebbe usare CGNAT, quindi non presumere IP pubblico.
5. Usare DNS locale solo dopo test; non sostituire DHCP del Nexxt senza piano di rollback. PS5 e smart working devono continuare a usare la configurazione esistente se il server è spento.
6. Disabilitare UPnP per servizi del server dove possibile; mantenere firewall host e guest, aggiornamenti e backup.

## 7. UPS: spegnimento ordinato

Collegare USB **dati** dell'UPS al mini PC. Sul nodo Proxmox usare `lsusb` e `upsc -l` per diagnostica dopo installazione **NUT** dai repository Debian/Proxmox appropriati. Verificare il driver effettivamente compatibile con il modello Eaton, senza inventare nome USB driver. Configurare NUT in modalità standalone e una soglia di batteria per shutdown ordinato dei guest e host; testare prima con alimentazione di rete presente, poi test controllato con carico reale. Router Nexxt sullo stesso UPS se si vuole mantenere LAN durante breve blackout; verificare potenza totale e cavi.

## 8. Backup e disaster recovery

- **Regola 3-2-1:** tre copie dei dati, due supporti, una copia esterna/offline.
- Backup Proxmox schedulato per VM (vzdump/PBS), più backup applicativi coerenti: DB Immich e Nextcloud + file + config.
- Snapshot prima di aggiornamenti rischiosi, **non** sostituisce backup.
- Cifrare backup esterni e custodire separatamente recovery key; testare restore di almeno una VM e di alcune foto/file.
- UPS non sostituisce backup, RAID non sostituisce backup, Syncthing non sostituisce backup (propaga cancellazioni).

## 9. Integrazione con `endeavouros-setup.sh`

**Non eseguire lo script EndeavourOS sul nodo Proxmox.** I laptop continuano a usare `pacman/yay`; il server Proxmox/Debian usa `apt` e installazioni guest Docker Compose. Il quarto documento è una guida server autonoma.

| Client | Server | Uso |
|---|---|---|
| ThinkPad T480s / Razer | Syncthing | cartelle autorizzate, non backup di VM |
| Firefox | Nextcloud | file, calendario, contatti |
| Firefox | Proxmox | GUI amministrazione solo LAN/VPN |
| digiKam / darktable | Immich | archivio foto centralizzato, workflow editing locale |
| iPhone + Möbius | Syncthing | sincronizzazione manuale/periodica |
| iPhone + Immich | Immich | upload foto/video |
| GitHub CLI | GitHub | repo `endeavouros-lean` principale; server eventuale runner solo isolato e con token minimo |

## 10. Checklist finale

- [ ] Acquisto mini PC con RAM, porte e upgrade verificati sulla **specifica** scheda Amazon
- [ ] UPS USB dati + cavi appropriati; batteria verificata
- [ ] Backup di tutti i dischi da cancellare
- [ ] Proxmox installato e aggiornato, IP LAN stabile, MFA attiva
- [ ] Nessuna GUI amministrativa esposta pubblicamente
- [ ] VM Debian con Docker Compose, QEMU guest agent e aggiornamenti
- [ ] Syncthing con ThinkPad, Razer e Möbius associati
- [ ] Immich con iPhone e backup database/foto
- [ ] Nextcloud configurato con HTTPS/VPN e backup
- [ ] NUT/UPS testato con shutdown ordinato
- [ ] Backup esterno e prova di ripristino
- [ ] Verifica navigazione, smart working e PS5 anche con server spento

## 11. Fonti ufficiali

- Proxmox installazione: https://proxmox.com/en/products/proxmox-virtual-environment/get-started
- Proxmox requisiti: https://proxmox.com/en/products/proxmox-virtual-environment/requirements
- Immich requisiti: https://docs.immich.app/install/requirements/
- Immich quick start: https://docs.immich.app/overview/quick-start/
- Nextcloud requisiti: https://docs.nextcloud.com/server/stable/admin_manual/installation/system_requirements.html
- Syncthing: https://docs.syncthing.net/
- NUT: https://networkupstools.org/
- Tailscale: https://tailscale.com/kb/

**Stato:** guida progettuale e procedura guidata, non un'installazione Proxmox già eseguita. I prezzi Amazon, varianti hardware, driver UPS, LAN Nexxt e servizi vanno verificati sul posto prima dell'installazione.


## 10. Espansione: AI, trading algoritmico 24/7 e progetti futuri

### Hardware raccomandato per questo obiettivo

Il Beelink N150/16 GB citato all'inizio è **solo un'opzione economica di test**, non la scelta per un host multi-progetto 24/7. Come target iniziale raccomando **Ryzen 7/9 8+ core, 64 GB RAM (espandibile almeno a 96 GB se possibile), NVMe 2 TB e secondo SSD, Ethernet 2.5GbE, dissipazione adeguata a carico continuo**. Verificare con attenzione SKU, slot RAM/SSD, rumorosità e assistenza prima dell'acquisto; non presumere che ogni mini PC supporti 96 GB. Per inferenza AI locale seria prevedere una GPU con VRAM adeguata, eGPU solo dopo verifica delle porte e della compatibilità, oppure un secondo nodo GPU dedicato. Non confondere le prestazioni CPU per container con le prestazioni GPU per LLM.

### Separazione delle macchine virtuali

| VM | Ruolo | Risorse indicative iniziali |
|---|---|---|
| `svc-cloud` | Syncthing, Nextcloud, Immich, Uptime Kuma | 6 vCPU, 16–24 GB RAM, volumi dati dedicati |
| `svc-trading` | ricerca, feed, broker API, paper/live trading | 4 vCPU, 8–12 GB RAM, SSD persistente |
| `svc-ai` | agenti, code, API e modelli CPU leggeri | 4 vCPU, 12–16 GB RAM, adattare al modello |
| `svc-dev` (opzionale) | Forgejo, CI runner, esperimenti | 2 vCPU, 4–8 GB RAM |

Sono **quote iniziali orientative**, non RAM da riservare tutta contemporaneamente: verificare consumo reale, lasciare 6–8 GB al nodo Proxmox e spazio per cache e backup. Evitare overcommit di memoria senza monitoraggio. Usare una VM separata per il trading, non mescolare chiavi API dei broker con servizi pubblici o laboratori AI.

### Trading affidabile 24/7

Partire con **paper trading** e passare al live solo dopo backtest senza look-ahead, forward test, audit degli ordini e verifica dei vincoli del broker. Inserire limiti di esposizione, limite perdita giornaliera, blocco ordini duplicati, gestione disconnessioni e **kill switch** manuale/automatico. Chiavi API con privilegi minimi, nessun prelievo, credenziali fuori da Git e backup cifrati. NTP, watchdog, healthcheck, metriche e notifiche sono obbligatori per uso unattended; UPS e riavvio automatico non garantiscono esecuzione senza interruzioni. Separare database PostgreSQL/Redis e backup con restore testato.

### Compatibilità con laptop LEAN

I laptop restano ambienti di sviluppo tramite SSH e VS Code Remote-SSH; GitHub resta la fonte del codice versionato, Syncthing per cartelle personali selezionate e Nextcloud per documenti condivisi. Tailscale/WireGuard protegge accesso remoto, senza esporre Proxmox, Docker socket, database, API broker o dashboard trading su Internet. La VM trading non va sincronizzata come directory live tramite Syncthing.

### Acquisto e continuità

Verificare alimentatore e consumo misurato del mini PC, NAS/dischi e Fastweb Nexxt prima di scegliere UPS: il 900 VA proposto può essere adeguato a un mini PC a basso consumo ma va dimensionato per il carico complessivo e l'autonomia desiderata. Per un nodo con GPU discreta può servire un UPS più capiente. Prediligere modello con USB HID/NUT verificabile, batteria sostituibile e prese compatibili.
