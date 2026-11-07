> Versione v60 — scelta della cartella locale GitHub, predefinita `~/Projects/endeavouros-lean`.

# EndeavourOS LEAN v53 — Guida operativa

**Script:** `endeavouros-setup.sh`  
**Destinatari:** ThinkPad T480s e Razer Blade 15 con EndeavourOS / Arch Linux, KDE Plasma.  
**Obiettivo:** controllare il computer, aggiornare il sistema, installare una suite di applicazioni e produrre un report, evitando modifiche non necessarie ai driver grafici e ai dati personali.

> **Importante:** questa guida descrive le funzioni previste dal codice v53, non certifica che tutte le installazioni riescano su ciascun computer. I pacchetti AUR, i servizi, le dipendenze e i download dipendono dallo stato effettivo del sistema e dalla rete. La sintassi valida non equivale a un collaudo completo.

## 1. Avvio rapido

1. Scarica lo script e salvalo nella cartella **Download** (`~/Downloads`).
2. Apri **Konsole** come utente normale (non eseguire lo script con `sudo`).
3. Esegui:

   ```bash
   cd ~/Downloads
   bash -n endeavouros-setup.sh
   bash endeavouros-setup.sh
   ```

4. Per l'installazione completa premi **Invio**: la scelta predefinita è **`B`**. Per un primo controllo senza installare pacchetti, scegli **`1`**.
5. Leggi le richieste di conferma. Non chiudere Konsole mentre `pacman` o `yay` sta lavorando.
6. Al termine, consulta il **report** e il **log** nella tua home.

**Se hai già installato la maggior parte della suite:** puoi eseguire soltanto la sezione desiderata, per esempio `54` per Syncthing, `45` per Virt-Manager o `55` per audit/pulizia. Non occorre ripetere `B` per ogni piccola modifica.

## GitHub: repository e sincronizzazione (v52)

**Perché privato?** È una precauzione durante i test: lo script installa e configura servizi, e un repository privato evita di distribuire pubblicamente codice non ancora collaudato. **Non è obbligatorio**: puoi scegliere **pubblico** durante la procedura; un repository pubblico può essere utile per condivisione, audit e contributi. La visibilità non influisce sulla capacità di sincronizzare ThinkPad e Razer.

Nel percorso `B` la sequenza è: **rilevamento hardware → inventario software → audit orfani/cache (senza eliminare nulla) → repository GitHub (con conferma) → aggiornamento e installazione → pulizia conservativa (con conferma) → report**.

- Lo script installa **`git` e `github-cli`** se mancanti, come unico bootstrap preliminare necessario per creare il repository.
- Se necessario, apre l'autenticazione `gh auth login` tramite browser. Non inserire password o token nel file `.sh`.
- Chiede **se creare** `ACCOUNT/endeavouros-lean` e se renderlo **pubblico** oppure mantenerlo **privato** (predefinito). Non cambia la visibilità di un repository già esistente.
- Chiede separatamente se caricare **solo** `endeavouros-setup.sh`, `README.md`, `hdtracks-vm-fiio-m3k.md` e `proxmox-homelab.md`, copiati dalla cartella in cui si trova lo script. Metti quindi le tre guide Markdown accanto allo script.
- Clona il repository in `~/Sviluppo/endeavouros-lean`, evitando sovrascritture se esistono modifiche locali non salvate. Registra commit e prova il push.
- L'operazione è **su richiesta**: non pubblica log, configurazioni locali, credenziali, dati personali, profili browser, file Syncthing o VM.
- Non è una sincronizzazione continua: i file sul repository si aggiornano tramite **commit/push**; gli altri computer li ricevono con **`git pull`**. L'installer non esegue aggiornamenti automatici remoti senza conferma.

Per eseguire solo questa procedura scegli **`56`** dal menu. Per ricevere gli aggiornamenti su un altro computer, dopo aver effettuato il clone:

```bash
cd ~/Sviluppo/endeavouros-lean
git pull --ff-only
bash -n install.sh
bash install.sh
```

**Nota:** `B` può effettuare molte installazioni. Prima di eseguirlo, esamina lo script e conserva un backup. L'autenticazione GitHub e le conferme richiedono interazione; in caso di errore il report indica ciò che manca.

## 2. Che cosa rileva prima di installare

| Controllo | Come viene usato |
|---|---|
| Sistema operativo | Richiede `pacman` (Arch/EndeavourOS); rifiuta l'avvio come root. |
| Modello computer | Legge il modello DMI, quando disponibile. |
| GPU Intel / NVIDIA / AMD | Legge i dispositivi PCI da `/sys`; seleziona il profilo grafico. |
| Hardware non riconosciuto | Blocca le operazioni di installazione e consente solo alcune opzioni di audit. |
| Pacchetti già installati | Verifica i pacchetti prima delle installazioni tramite funzioni di supporto. |
| Dipendenze pacman | Controlla la consistenza con `pacman -Dk` nella manutenzione conservativa. |
| Virtualizzazione | Verifica `/dev/kvm`, strumenti QEMU/libvirt, servizio e gruppo utente. |
| Servizi e collegamenti | Controlla, fra gli altri, Syncthing e i collegamenti KDE. |
| Disco, cache, orfani | Controlla pacchetti orfani e spazio disponibile, con pulizia conservativa. |

**Differenze hardware:** sul ThinkPad con sola GPU Intel non dovrebbero essere installati componenti NVIDIA; sul Razer Intel+NVIDIA sono previste funzioni PRIME per singole applicazioni. La scelta GPU **non** cambia fisicamente GPU, MUX o configurazione del desktop. Le impostazioni delle VM dipendono dalla RAM e dal profilo rilevati.

## 3. Che cosa fa la scelta `B` (predefinita)

1. **Preflight:** controlli iniziali e inventario.
2. **Audit:** stato pacchetti, hardware, servizi, alimentazione e periferiche.
3. **GitHub:** crea/verifica il repository solo dopo conferma; può caricare script e le tre guide Markdown.
4. **Aggiornamento:** esegue un aggiornamento completo `pacman -Syu`.
5. **Installazione ordinata:** sistema e virtualizzazione → sviluppo e infrastruttura → AI → sincronizzazione e cloud → comunicazione e VPN → Office e produttività → media e finanza → KDE. La voce `39` richiama lo stesso percorso di `B`, per evitare differenze tra installazioni complete.
6. **Verifica finale:** riesamina il sistema e propone una pulizia conservativa.

Lo script preferisce **repository ufficiali (`pacman`)**, poi **AUR (`yay`)** dove previsto; non aggiunge nuove installazioni Flatpak/Snap. Alcuni programmi potrebbero richiedere conferme, installazioni manuali o account esterni.

**Nota pratica:** `B` è un percorso ampio, non una modalità minimale: installa anche componenti che potresti non utilizzare. Prima di avviarlo assicurati di avere un backup e spazio libero sufficiente. Sul ThinkPad da 8 GB, non avviare contemporaneamente Windows VM, Ollama e numerosi container.

## 4. Applicazioni e strumenti previsti

| Area | Applicazioni / funzioni |
|---|---|
| Browser e privacy | Firefox predefinito, uBlock Origin, protezioni antitracciamento, launcher web; rimozione Brave soltanto se sicura e prevista. |
| Office | LibreOffice (italiano), Calibre, font Liberation/Carlito/Caladea per compatibilità Microsoft, correzione GTK3 per LibreOffice multi-monitor. |
| Google Workspace | Collegamenti Firefox per Docs, Sheets, Slides, Drive, Gmail, Calendar, Keep e Tasks. |
| Note e organizzazione | **AppFlowy** (AUR se necessario), alternativa a Notion. |
| Posta e VPN | Tuta Mail (launcher KDE nativo quando disponibile; Firefox soltanto come fallback), Proton VPN. |
| Password e sicurezza | Bitwarden, Ledger Nano X (diagnostica USB), guida Rabby Wallet. |
| AI online | Collegamenti KDE per ChatGPT, Claude, Gemini, Perplexity e Grok. |
| AI locale | Ollama; Open WebUI opzionale; CUDA soltanto se hardware NVIDIA e driver compatibili. |
| Sviluppo | VS Code, Git/GitHub CLI, Python, Node/npm, Claude Code, Codex, Docker/Compose, template e strumenti API/database. |
| Virtualizzazione | QEMU/KVM, libvirt, Virt-Manager, Virt-Install, OVMF, swtpm, SPICE, USB redirection. |
| Windows per HDtracks | Procedura guidata per creare VM Windows 11 con ISO ufficiale fornita dall'utente. |
| Cloud e file | Google Drive KDE, Dropbox/Dolphin, MEGA, pCloud. |
| Sincronizzazione | **Syncthing** con interfaccia web locale, compatibile con Möbius Sync su iPhone. |
| Foto e video | digiKam, darktable, Kdenlive, OBS, HandBrake, gestione foto iPhone. |
| PDF | Strumenti PDF, scansione e OCR. |
| Gaming | Steam, DualShock 4, GameMode, MangoHud, componenti Vulkan secondo hardware. |
| Produttività | HomeBank, Ferdium, strumenti di monitoraggio hardware e stampante HP Color Laser 150nw/150mw. |
| KDE | Collegamenti con icone, preferenze estetiche e blocco schermo. |

La tabella riassume i **componenti previsti**, non garantisce che ogni pacchetto sia disponibile oggi o installato correttamente: controlla il report.

## 5. Menu numerico completo

La voce `B` è separata dalle opzioni numeriche. Le opzioni sono ordinate in modo crescente.

| Voce | Funzione | Voce | Funzione |
|---:|---|---:|---|
| 0 | Esci | 1 | Inventario e preflight |
| 2 | Aggiornamento pacman | 3 | Migrazione installazioni precedenti |
| 4 | Calibre, LibreOffice, Bitwarden | 5 | Steam e gaming |
| 6 | AI CLI e sviluppo | 7 | Launcher AI Firefox |
| 8 | Cloud | 9 | iPhone e KDE Connect |
| 10 | Firefox e uBlock Origin | 11 | Ripara Claude Code |
| 12 | Tema Firefox | 13 | Ledger Nano X |
| 14 | Proton VPN | 15 | Docker, Compose e GitHub |
| 16 | Guida DeFi | 17 | PDF e OCR |
| 18 | Foto e video | 19 | Google Workspace |
| 20 | Ollama e Open WebUI | 21 | Diagnostica iPhone |
| 22 | Sicurezza, backup e hardware | 23 | Workspace e template |
| 24 | Servizi sviluppo | 25 | Manutenzione LEAN |
| 26 | Aspetto macOS-like | 27 | Monitoraggio hardware |
| 28 | SSD e TRIM | 29 | Audit energia |
| 30 | Diagnostica Ledger USB | 31 | Guida Rabby |
| 32 | Funzioni aggregate LEAN v10 | 33 | Produttività e API |
| 34 | Stampante e KDE | 35 | Ripara icone Google |
| 36 | Stampante HP | 37 | LibreOffice GTK3 multi-monitor |
| 38 | Solo audit manutenzione | 39 | Tutte le sezioni (legacy) |
| 40 | Dropbox e Dolphin | 41 | Preferenze GPU |
| 42 | Ferdium | 43 | Shortcut GPU |
| 44 | Rilevamento GPU | 45 | Installa QEMU/KVM e Virt-Manager |
| 46 | Crea VM Windows/Linux | 47 | Ripara menu KDE Virt-Manager |
| 48 | Privacy Firefox | 49 | Font Office |
| 50 | Google Docs/Sheets/Slides | 51 | Tuta Mail |
| 52 | Audit e manutenzione | 53 | AppFlowy |
| 54 | Syncthing | 55 | Dipendenze, orfani e cache |

## 6. Windows 11, Virt-Manager e HDtracks

- `B` e `45` **installano l'infrastruttura** QEMU/KVM e Virt-Manager; **non** installano automaticamente Windows.
- `46` apre una procedura guidata: scegli Windows 11 oppure Linux, scarica l'ISO dalla pagina ufficiale e indica il file locale.
- La creazione della VM richiede KVM attivo, spazio libero, libvirt funzionante e conferma dell'origine dell'ISO.
- **Windows 11:** download ISO gratuito; licenza Windows non inclusa. macOS non viene installato su ThinkPad/Razer.
- Dopo l'installazione di Windows, completa i **driver guest VirtIO/SPICE**, l'installazione di HDtracks Download Manager e le prove USB/microSD.
- Per accedere alle periferiche USB usa la console SPICE di Virt-Manager; alcune microSD integrate potrebbero non apparire come dispositivi USB reindirizzabili. In quel caso usa una chiavetta/lettore USB compatibile oppure una cartella condivisa.
- Per lanciare Virt-Manager: cerca **Macchine virtuali** nel menu KDE, oppure esegui `virt-manager`. Se il collegamento manca, scegli `47`.

**Attenzione allo spazio:** il codice della procedura guidata verifica lo spazio libero nella home, mentre il disco della VM viene creato nel pool libvirt (`/var/lib/libvirt/images`), che può essere su una partizione diversa. **Controlla lo spazio libero effettivo del pool prima di confermare**: un'installazione precedente era fallita per spazio insufficiente.

## 7. Syncthing: ThinkPad, Razer e iPhone

1. Esegui `54` su **entrambi** i computer, oppure usa `B`.
2. Cerca **Syncthing - Sincronizzazione** nel menu KDE, oppure apri `http://127.0.0.1:8384/` su ciascun computer.
3. In **Azioni → Mostra ID**, copia il Device ID di ciascun computer e aggiungilo all'altro.
4. Crea una cartella dedicata (es. `~/Sync/Documenti`) e condividi **solo** quella.
5. Apri **Möbius Sync** su iPhone, aggiungi il Device ID del computer e approva l'associazione.
6. Verifica la sincronizzazione con un file di prova; solo dopo aggiungi documenti importanti.

Non sincronizzare automaticamente l'intera home, i profili browser, i database di app in uso, le cartelle VM o i segreti. Su iPhone l'esecuzione in background è limitata: apri Möbius Sync per sincronizzazioni affidabili. **Non esporre la GUI Syncthing sulla porta 8384 a Internet.**

## 8. Firefox e Google Docs offline

Firefox viene utilizzato per Google Docs, Sheets e Slides **online**. L'offline nativo di Google Docs è legato all'estensione Google Docs Offline e ai browser Chromium supportati: **non considerarlo garantito su Firefox**. Per lavorare senza rete, usa LibreOffice e salva/esporta in formati compatibili. La privacy avanzata riduce il tracciamento, ma non garantisce anonimato né impedisce il riconoscimento quando accedi a un account.

## 9. Manutenzione: che cosa può rimuovere

L'opzione `55` esegue audit dipendenze e pulizia conservativa: identifica i pacchetti orfani, **chiede conferma** prima di eventuali rimozioni, protegge categorie sensibili (kernel, driver, firmware, VM, Syncthing) e può ridurre la cache pacman conservando versioni recenti. Non elimina automaticamente dati personali, cartelle VM o workspace. **Un pacchetto classificato come orfano non è necessariamente inutile**: leggi sempre la lista prima di confermare.

Per un controllo non distruttivo, usa `38` o `1`. Evita di eseguire altri comandi `pacman` o `yay` in parallelo allo script. Se il download resta su **Retrieving packages**, controlla rete/mirror e i processi prima di interrompere; non cancellare il lock pacman mentre è attivo.

## 10. Report finale e diagnostica

Lo script crea nella home due file con timestamp:

```text
~/installer-endeavouros-lean-AAAAMMGG-HHMMSS.log
~/installer-endeavouros-lean-AAAAMMGG-HHMMSS-riepilogo.txt
```

Il report distingue operazioni riuscite, errori, elementi saltati, avvisi e pacchetti richiesti ma mancanti. Include controlli dedicati a **virtualizzazione/HDtracks** e **Syncthing**, oltre ad altri audit post-installazione.

Per trovare l'ultimo report:

```bash
ls -lt ~/installer-endeavouros-lean-*-riepilogo.txt | head
```

Per consultarlo:

```bash
less "$(ls -t ~/installer-endeavouros-lean-*-riepilogo.txt | head -n 1)"
```

Se un'app manca dal menu KDE, prima verifica se è realmente installata (`pacman -Q nome-pacchetto`); poi aggiorna la cache KDE con `kbuildsycoca6 --noincremental`. Il menu KDE può richiedere logout/login dopo modifiche ai gruppi utente.

## 11. Controlli consigliati dopo l'installazione

```bash
# Programmi principali
command -v firefox virt-manager syncthing libreoffice

# Stato Syncthing
systemctl --user status syncthing.service

# Accelerazione virtualizzazione
ls -l /dev/kvm

# Pacchetti e dipendenze
pacman -Dk

# Spazio per le VM
df -h /var/lib/libvirt/images
```

Per gli errori, conserva le ultime righe del log e il report. **Non inviare pubblicamente log contenenti credenziali, percorsi privati o ID dei dispositivi Syncthing senza oscurarli.**

---

**Versione documentata:** v57. **Fonte:** lettura del file Bash `endeavouros-setup.sh`. Le funzionalità sono soggette a verifica pratica su ciascuna macchina.

## Modifiche v49

- Aggiunta opzione **56 — GitHub: crea/verifica repository e sincronizza script + README**.
- Menu numerico da 0 a 56 in ordine crescente; `B` rimane predefinito.
- Report GitHub, oltre ai controlli VM, Syncthing e applicazioni.
- Nessuna creazione del repository senza conferma esplicita.

## Ordine di installazione (v52)

| Fase | Categoria | Componenti principali |
|---|---|---|
| 1 | Sistema, hardware e sicurezza | Base, Virt-Manager/QEMU, GPU, Firefox e privacy, monitoraggio, stampante |
| 2 | Development | VS Code, Git, CLI, Python, Docker e servizi di sviluppo |
| 3 | AI | Claude, Codex, Gemini, Ollama e collegamenti AI |
| 4 | Sincronizzazione e cloud | Syncthing/Möbius, Dropbox/Drive, iPhone |
| 5 | Comunicazione e rete | Tuta, Ferdium, Proton VPN |
| 6 | Office e produttività | LibreOffice/font, Google Workspace, AppFlowy, HomeBank |
| 7 | Media, gaming e finanza | Foto/video, Steam, Ledger, DeFi, PDF/OCR |
| 8 | Aspetto e verifica | KDE e audit finale, pulizia conservativa con conferma |

**Browser:** Firefox resta predefinito per privacy e uso generale. Chromium non viene installato obbligatoriamente: può essere aggiunto separatamente per Google Docs Offline e siti che richiedono un browser Chromium compatibile. Nessun browser rende anonimi quando si accede ai propri account.

**Nota sulle dipendenze:** Git e GitHub CLI possono essere installati nella fase preliminare di bootstrap GitHub, prima della categoria Development. Questo è intenzionale. La categoria non modifica le dipendenze interne dei pacchetti gestite da pacman.


## File distribuiti insieme (v52)

Mantieni questi **quattro file nella stessa cartella** prima di eseguire il percorso `B` o l'opzione `56`:

1. `endeavouros-setup.sh` — installer completo (stesso nome nel repository GitHub).
2. `README.md` — questa guida: inventario applicazioni, prerequisiti, menu e sequenza di installazione.
3. `hdtracks-vm-fiio-m3k.md` — guida pratica per Windows 11 in QEMU/KVM, HDtracks Downloader e trasferimento audio su FiiO M3K.
4. `proxmox-homelab.md` — server domestico Proxmox, self-hosting, AI e trading 24/7.

Per creare una VM scegli **46** dopo aver predisposto Virt-Manager con **45** o con il percorso completo **B**. L'installazione Windows e dei driver guest non è automatica: la guida HDtracks spiega ogni passaggio. La VM richiede spazio libero reale sul disco e un'ISO ufficiale; Windows 11 può richiedere una licenza valida.

Il repository GitHub non viene creato né aggiornato senza autenticazione e conferma. L'opzione `56` copia esclusivamente i quattro file sopra, non i log né i dati personali. Il file locale mantiene il nome `endeavouros-setup.sh`; nel repository lo script mantiene il nome `endeavouros-setup.sh`.

**Attenzione:** il controllo `bash -n` verifica solo la sintassi. Il funzionamento dell'installer su hardware reale, le policy Firefox, il firmware Secure Boot della VM e i pacchetti AUR devono essere verificati in esecuzione.


## Server domestico Proxmox per AI e trading 24/7 (v52)

La quarta guida copre una piattaforma dedicata e separata dai laptop. Per AI e trading continuativi scegliere preferibilmente **64 GB RAM espandibili a 96/128 GB, CPU Ryzen 7/9 con 8+ core, NVMe 2 TB per VM e dati attivi, secondo SSD per separare carichi e almeno una porta 2.5GbE**. Una GPU discreta o un nodo AI separato sono necessari per modelli locali grandi: non assumere che un mini PC senza GPU offra inferenza rapida. Dimensionare l'UPS per server + router + storage e verificare lo spegnimento NUT. Il trading deve iniziare in paper trading, con limiti di rischio, kill switch, gestione dei segreti e monitoraggio. Proxmox rimane sull'host; Docker e applicazioni nelle VM.

Per pubblicare tutte le guide: metti **tutti e quattro** i file nella stessa cartella e scegli `56` oppure `B`. Il repository GitHub viene creato/aggiornato soltanto dopo autenticazione e consenso. La sincronizzazione non è in tempo reale: il push avviene quando esegui la funzione.


## Tuta Mail — launcher nativo (v52)

La funzione `lean_tuta_desktop` (opzione `51`, inclusa in `B`) installa/verifica il pacchetto desktop Tuta, preferendo i repository ufficiali e richiedendo consenso per AUR. Il launcher `lean-tuta-mail.desktop` usa **il client nativo** tramite il file `.desktop` del pacchetto o il relativo eseguibile. **Firefox è usato solo se il client non è rilevabile**.

La procedura aggiorna anche il precedente collegamento LEAN che apriva sempre Firefox. Non sovrascrive eventuali collegamenti personalizzati. Aggiorna la cache KDE, quando disponibile. Controllare il risultato avviando «Tuta Mail» dal menu applicazioni; se il client nativo non è installato, verificare il log e l'eventuale consenso AUR.

I nomi `README.md`, `endeavouros-setup.sh`, `hdtracks-vm-fiio-m3k.md` e `proxmox-homelab.md` restano invariati.

## OpenAI Codex CLI (v53)

OpenAI Codex CLI è previsto nell'installazione completa **B**, nella categoria **AI / sviluppo** (opzione **6**), nell'ambiente di sviluppo (opzione **23**) e ora nell'opzione dedicata **57**, per installarlo senza reinstallare il resto della suite.

Lo script controlla prima se `codex --version` funziona, quindi prova il pacchetto disponibile tramite `pacman`, poi `yay` (AUR), e infine il pacchetto ufficiale `@openai/codex` con `npm` nel profilo utente (`~/.local/npm`), senza `sudo npm -g`. Le fonti pacman/AUR sono verificate a runtime: non si presume che esistano. Il comando di verifica è:

```bash
codex --version
codex login
```

L'autenticazione va completata dall'utente; **non** si inseriscono credenziali o chiavi API nello script. L'uso di Codex può richiedere un piano o crediti abilitati. Il comando `codex` installato nel profilo utente può richiedere `~/.local/bin` nel `PATH` per i nuovi terminali.


## v54 — Installazione AppFlowy

L’opzione `53` e il percorso completo `B` verificano prima i pacchetti installati e i repository pacman, poi cercano `appflowy-bin` o `appflowy` in AUR con `yay`. Se `yay` manca, lo script segnala il problema e può installarlo da pacman **solo se disponibile**, con conferma. L’installazione AUR richiede sempre conferma e verifica del PKGBUILD. Al termine vengono controllati pacchetto e launcher KDE. In caso di errore consultare il log dell’installer. Nessun dato AppFlowy viene cancellato.


## v55 — Launcher browser KDE e compatibilità

I collegamenti web creati da LEAN (AI, Google Workspace, Tuta quando il client nativo non è disponibile e servizi famiglia) selezionano a runtime **Brave se installato**, altrimenti **Chromium**, altrimenti **Firefox**. Non richiedono né avviano Brave se assente. **Safari non è disponibile come browser nativo su EndeavourOS/Linux**. La scelta del browser per i collegamenti è distinta dal browser predefinito del sistema, che rimane Firefox secondo la configurazione LEAN. I launcher gestiti da LEAN vengono aggiornati; quelli personalizzati sono preservati dove previsto.


## v56 — Correzione browser degli shortcut KDE

Gli shortcut LEAN usano **Chromium** se installato, altrimenti **Firefox**. Brave non viene più selezionato, anche quando è presente nel PATH. Il client desktop Tuta rimane prioritario. Rieseguire le funzioni di creazione shortcut per aggiornare i file `.desktop` precedenti. I launcher personalizzati non riconosciuti come LEAN sono conservati.

**Riparazione immediata:** eseguire `bash endeavouros-setup.sh` e scegliere `58` per ricreare gli shortcut web AI, Google Workspace, famiglia e Tuta. Il browser preferito è Chromium, altrimenti Firefox; Brave non è mai scelto. L’operazione non disinstalla Brave.


## v57 — Inventario browser prima delle installazioni e shortcut coerenti

Lo script esegue un **audit in sola lettura dei browser già installati** (Chromium, Firefox e Brave) prima di procedere con il percorso completo `B` e all'apertura di ciascuna voce del menu. Riporta percorso eseguibile e browser scelto. Gli shortcut web sono creati **solo dopo aver verificato di nuovo il browser disponibile**, preferendo Chromium e poi Firefox; Brave non è usato per i collegamenti LEAN, anche quando installato. Se nessuno dei due è disponibile, non crea collegamenti non funzionanti e segnala il problema. Al termine di `B`, ricontrolla i browser e ripara i collegamenti LEAN. La voce `58` esegue audit e riparazione senza reinstallare applicazioni. Gli shortcut personalizzati non gestiti restano protetti.


## v57 — Ricostruzione shortcut KDE prima delle installazioni

Il percorso completo `B` esegue prima l’inventario hardware/software e l’audit browser, quindi ricostruisce gli shortcut web **prima** di installare altri pacchetti; al termine ripete la ricostruzione per recepire eventuali browser installati nel frattempo. L’opzione `58` permette di ripetere la sola procedura.

Ordine: rilevamento di Chromium/Firefox (Brave escluso) → identificazione dei launcher web LEAN preesistenti in `~/.local/share/applications` → eliminazione mirata → rigenerazione con il browser effettivamente presente → aggiornamento cache KDE. Se nessun browser compatibile è presente, non elimina i launcher esistenti.

**Sicurezza:** non cancella tutte le voci del menu KDE, i launcher di sistema, le applicazioni native o i collegamenti personali non riconosciuti. L’eventuale icona già fissata nel pannello KDE potrebbe dover essere rimossa e aggiunta nuovamente.


## Conferme interattive (v58)

Lo script richiede la password `sudo` una volta all’avvio e rinnova la sessione durante l’esecuzione. Per le normali conferme di installazione e configurazione usa `[S/n]`: **Invio equivale a sì**. Le operazioni di rimozione pacchetti, la pubblicazione del repository GitHub e la creazione di VM richiedono invece un sì esplicito (`[s/N]`) per evitare modifiche indesiderate. L’autenticazione GitHub (`gh auth login`) e le eventuali verifiche di sicurezza di AUR, Windows o servizi esterni non possono essere sostituite dalla password di sistema.

## Posizione dei file GitHub (v60)

Durante l'opzione **56** o il percorso **B**, lo script chiede dove salvare il clone locale. Il percorso predefinito è `~/Projects/endeavouros-lean`; basta premere Invio. Puoi inserire `~/Projects/Linux/endeavouros-lean` o un altro percorso assoluto. La cartella sorgente da cui avvii lo script, che deve contenere i quattro file, può essere diversa dalla cartella del clone. Se la destinazione contiene già un clone Git valido, viene riutilizzato; se contiene file non Git, non viene sovrascritta. Il repository remoto mantiene il nome `endeavouros-lean`.

## v61 — menu KDE senza duplicati

Ad ogni ricostruzione (`B` o opzione `58`) lo script verifica Chromium/Firefox, rimuove **soltanto** i launcher gestiti da LEAN e quelli legacy riconosciuti, e ricrea un unico collegamento per servizio. Nomi puliti: ChatGPT, Claude, Gemini, Perplexity, Grok, Google Docs, Google Sheets, Google Slides, Google Drive, Google Calendar, Google Tasks, Gmail, Google Keep. Niente prefisso «Famiglia -». Docs/Sheets/Slides/Drive compaiono soltanto nella categoria **Office**; Gmail/Calendar/Tasks/Keep soltanto in **Internet**. Ferdium usa il launcher nativo, senza un duplicato LEAN. Le icone usano risorse SVG locali o icone del tema KDE. Gli shortcut personali e i launcher di sistema non vengono cancellati. I preferiti già fissati nel pannello Plasma possono richiedere rimozione e nuova aggiunta.


## v62 — Tuta Desktop e protezione del menu KDE

L'installazione di Tuta è integrata nella procedura completa `B` e nell'opzione `51`. Lo script controlla `tutanota-desktop-bin`, `tutanota-desktop` e `tuta-desktop`, installa tramite `yay` il pacchetto AUR disponibile se necessario, verifica il pacchetto e il launcher nativo, senza generare uno shortcut web o un doppione. Il vecchio `lean-tuta-mail.desktop` viene spostato in un backup soltanto se marcato come gestito da LEAN. Se l'installazione fallisce, viene riportato un errore esplicito.

**Misura di sicurezza temporanea:** dopo i problemi riscontrati con il menu KDE, la ricostruzione automatica degli shortcut è disabilitata nel percorso `B`; l'opzione `58` resta separata e non va usata finché non viene validata su un laptop. La presenza di un file `.desktop` non garantisce il funzionamento effettivo dell'applicazione: verificarne l'avvio manualmente.


## v63 — AppFlowy e KDE

L'opzione 53 tenta `yay -S --needed appflowy-bin` dopo conferma `[S/n]`, senza bloccare l'installazione con un pre-controllo `yay -Si`. In caso di errore controllare il log. L'opzione 58 esegue backup dei soli launcher marcati LEAN e ricrea gli shortcut web una volta, con Chromium o Firefox, senza Brave. La procedura B ricostruisce gli shortcut una sola volta alla fine. Ferdium e Tuta restano nativi. Docs, Sheets, Slides e Drive sono soltanto in Office; AI e servizi di comunicazione soltanto in Internet. Gli shortcut personali e nativi non vengono cancellati.


## Riparazione 2026-11-07

- Opzione **51**: Tuta nativo via AUR, tentativo reale `yay -S --needed tutanota-desktop-bin` e fallback `tutanota-desktop`, verifica pacchetto e launcher. Nessun collegamento web Tuta.
- Opzione **53**: AppFlowy tramite `yay -S --needed appflowy-bin`, dopo conferma; segnala eventuali errori.
- Opzione **58**: ricrea ChatGPT, Claude, Gemini, Perplexity, Grok, Gmail, Calendar, Keep, Tasks, Google Docs, Sheets, Slides, Drive; Chromium preferito, Firefox fallback, mai Brave. Prima archivia soltanto launcher marcati LEAN.
- Il menu non blocca più le opzioni se il rilevamento GPU restituisce `unknown`.
- Nessun file `.desktop` personale viene sovrascritto dalla funzione Google Workspace.
- Consiglio: testare prima 51, 53, 58 separatamente. Non eseguire `B` prima di averli verificati.
- Questa build è stata verificata staticamente, **non** installata su un laptop reale.


## Consolidamento 2026-11-07
- Opzione 58 non archivia e non elimina più alcun launcher. Aggiorna in loco 13 file gestiti, valida con desktop-file-validate e aggiorna la cache KDE.
- Opzione 0 evita la stampa del report finale e termina il menu.
- AppFlowy e Tuta: opzioni 53 e 51, se già installati non vengono reinstallati.
- Attenzione: il resto dell'installer completo (inclusa B) NON è stato testato sul computer reale. Per adesso usare soltanto opzioni mirate.
- Prima prova consigliata: 58, poi 0.
