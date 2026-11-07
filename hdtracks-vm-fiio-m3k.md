# HDtracks su Windows 11 virtualizzato — EndeavourOS, ThinkPad/Razer e FiiO M3K

Guida passo passo per scaricare musica **acquistata legittimamente** con HDtracks Downloader in Windows 11, quindi copiarla su una scheda microSD utilizzabile nel lettore **FiiO M3K**. La procedura utilizza **QEMU/KVM + Virt-Manager** già previsti da `endeavouros-setup.sh`.

> **Importante:** l'ISO Windows 11 è scaricabile gratuitamente da Microsoft, ma l'utilizzo di Windows richiede il rispetto della licenza Microsoft. HDtracks può modificare modalità di download, formati e requisiti del client. Non installare Windows da ISO di terze parti. Non è possibile garantire che tutte le funzionalità USB funzionino su ogni periferica senza una prova sul computer.

## 1. Prima di iniziare

- Aggiorna EndeavourOS, fai un backup e collega il computer all'alimentazione.
- Conserva **almeno 35 GiB liberi** prima della creazione della VM, preferibilmente **100–120 GiB o più** se prevedi molti download audio. Il file qcow2 cresce man mano che viene usato: una capacità nominale di 80–100 GiB non è spazio già allocato, ma lo spazio necessario cresce con Windows e i file scaricati.
- Scarica `endeavouros-setup.sh`, `README.md` e questa guida nella stessa cartella `~/Downloads`.
- Usa un account HDtracks con acquisti disponibili e una microSD in buone condizioni. Fai un backup dei file già presenti sulla scheda.
- Per il **ThinkPad T480s (8 GB)** lo script propone **4 GiB RAM, 2 vCPU, 80 GiB** di disco virtuale; per il **Razer Blade 15 (16 GB)** **6 GiB RAM, 4 vCPU, 100 GiB**. Sono valori indicativi adattati alla RAM rilevata: non cambiare risorse se il computer è sotto carico.

## 2. Installare la virtualizzazione

Apri Konsole come **utente normale**:

```bash
cd ~/Downloads
bash -n endeavouros-setup.sh
bash endeavouros-setup.sh
```

Premi **Invio (`B`)** per l'installazione completa oppure **`45`** per installare solo QEMU/KVM, libvirt, Virt-Manager, firmware UEFI, TPM virtuale, SPICE e strumenti USB. Se i download pacman sembrano fermi, **non avviare un secondo pacman**: verifica prima rete e log. Il collegamento Virt-Manager viene aggiunto al menu KDE. Se manca, usa l'opzione **`47`** oppure cerca `virt-manager` nel launcher KDE.

Verifiche rapide:

```bash
command -v virt-manager
command -v virt-install
ls -l /dev/kvm
virsh -c qemu:///system list --all
```

Se `virsh` restituisce un errore di permessi, controlla il servizio libvirt e riavvia la sessione KDE dopo l'aggiunta al gruppo `libvirt`. Se `/dev/kvm` manca, verifica Intel VT-x nel firmware UEFI/BIOS.

## 3. Scaricare Windows 11 da Microsoft

1. Apri la pagina ufficiale: <https://www.microsoft.com/it-it/software-download/windows11>.
2. Cerca la sezione **ISO Windows 11 per dispositivi x64**, scegli la lingua e scarica il file ISO.
3. Non utilizzare siti che vendono ISO modificate o attivatori. Se Microsoft fornisce un checksum, confrontalo con `sha256sum nomefile.iso`.
4. Conserva l'ISO in `~/Downloads` fino alla creazione della VM.

## 4. Creare la VM da script

1. Avvia di nuovo lo script e scegli **`46 — VM guidata`**.
2. Seleziona **`1 — Windows 11`**.
3. Quando richiesto, incolla il percorso completo dell'ISO, per esempio `/home/tuo_utente/Downloads/Win11.iso`.
4. Conferma **solo se** spazio disponibile, configurazione proposta e provenienza dell'ISO sono corretti.
5. Lo script tenta di creare la VM **`HDtracks-Windows11`** con disco qcow2, firmware UEFI, TPM virtuale 2.0, display SPICE e USB xHCI. **Non sovrascrive** una VM esistente con lo stesso nome.
6. Apri **Virtual Machine Manager (Virt-Manager)** da KDE, seleziona `HDtracks-Windows11` e apri la console.

**Se la creazione fallisce:** controlla lo spazio effettivamente libero in `/var/lib/libvirt/images`, non soltanto quello della home. In alcune installazioni Windows 11 richiede anche **UEFI Secure Boot**: controlla la configurazione del firmware della VM in Virt-Manager **prima di reinstallare**. Non aggirare i controlli hardware o di licenza. Lo script prepara la VM ma non può garantire che Windows Setup termini automaticamente.

## 5. Installare Windows 11 nella VM

1. Segui la procedura Windows Setup nella console Virt-Manager.
2. Se richiesto, inserisci una licenza valida o scegli l'opzione prevista dal programma d'installazione per procedere senza chiave, se disponibile; l'attivazione resta necessaria secondo la licenza applicabile.
3. Seleziona il disco virtuale vuoto. **Non toccare le partizioni Linux fisiche**: Windows deve vedere soltanto il disco virtuale della VM.
4. Completa la configurazione iniziale, connetti la rete e avvia **Windows Update**.
5. Imposta una risoluzione confortevole nella VM. Se il display resta piccolo o il mouse non è fluido, passa al passo seguente.

## 6. Driver Windows: display, rete e periferiche

I driver del **computer host** rimangono in EndeavourOS: Windows virtualizzato vede **hardware virtuale**, non la RTX 2060 o la GPU Intel fisica. Non installare driver NVIDIA o Intel del laptop dentro Windows per cercare di migliorare la console SPICE.

1. In Windows apri la pagina ufficiale SPICE: <https://www.spice-space.org/download.html>.
2. Installa **SPICE Guest Tools** per Windows, se disponibili e compatibili con la versione di Windows in uso; riavvia Windows. Questo può migliorare puntatore, ridimensionamento del display e integrazione.
3. Per i driver VirtIO consulta il progetto ufficiale Fedora: <https://github.com/virtio-win/virtio-win-pkg-scripts> e la documentazione <https://docs.fedoraproject.org/en-US/quick-docs/creating-windows-virtual-machines-using-virtio-drivers/>. Scarica l'ISO/installer **solo dalle fonti ufficiali**. I driver VirtIO sono utili soprattutto se successivamente scegli controller disco/rete VirtIO.
4. La VM iniziale usa disco **SATA** e rete **e1000e** per ridurre la necessità di driver durante Windows Setup. **Non cambiare controller disco dopo l'installazione** senza preparare prima il driver Windows corretto: potresti rendere il sistema non avviabile.
5. In Virt-Manager controlla **View → Details** e la presenza di un display SPICE e di un controller USB 3 (xHCI). Per aggiungere canali di reindirizzamento USB, spegni la VM, aggiungi gli opportuni **USB Redirector** nelle impostazioni hardware e riavvia.

La disponibilità del ridimensionamento dinamico e del reindirizzamento USB dipende dalla versione dei driver guest e dalla configurazione della VM. Prova prima con una normale chiavetta USB senza dati importanti.

## 7. Installare e usare HDtracks Downloader

1. Apri Firefox o Edge **dentro Windows** e accedi al tuo account su <https://www.hdtracks.com/>.
2. Dal sito o dalla sezione degli acquisti cerca il link ufficiale al **Download Manager/Downloader** per Windows, se previsto per il tuo acquisto. Evita mirror di terze parti.
3. Scarica e installa il client seguendo le istruzioni ufficiali. Se HDtracks offre il download diretto via browser per il tuo acquisto, puoi utilizzare anche quello.
4. Accedi al tuo account, apri la libreria acquisti e seleziona gli album da scaricare.
5. Scegli un formato supportato dal tuo FiiO M3K (ad esempio **FLAC** per audio lossless) e una cartella di destinazione facilmente riconoscibile, per esempio `C:\Users\<utente>\Music\HDtracks`.
6. Al termine controlla che i brani siano completi, leggibili, con titoli e numerazione corretti. **Conserva una copia master** sul disco del computer o su un backup prima di trasferire alla microSD.

I file FLAC possono occupare molto spazio: evita di saturare il disco virtuale. È spesso più pratico trasferire periodicamente i download fuori dalla VM.

## 8. Trasferire i brani: metodo consigliato (Windows → Linux → microSD)

Questo metodo evita di far gestire contemporaneamente la stessa microSD a Windows virtuale e Linux.

**A. Porta i file da Windows a Linux.** Scegli uno dei seguenti metodi:

- **Cartella condivisa:** configura in Virt-Manager una condivisione tramite **virtiofs**, se supportata dal guest e dai relativi driver/servizi Windows. Richiede configurazione aggiuntiva: non è già pronta automaticamente nella VM iniziale.
- **Trasferimento via rete:** usa una cartella SMB/Samba temporanea con credenziali, limitata alla tua rete privata, oppure un servizio di trasferimento che controlli. Non esporre una condivisione senza password a Internet.
- **Chiavetta USB di passaggio:** collegala alla VM tramite SPICE USB redirection, copia i file da Windows, espellila **dentro Windows**, scollegala dalla VM e ricollegala all'host Linux. È il percorso più semplice quando la condivisione non è ancora configurata.

**B. Copia sulla microSD da EndeavourOS.**

1. Inserisci la microSD in un lettore collegato al ThinkPad/Razer, oppure collega il FiiO M3K in modalità memoria USB, se supportata dalla configurazione del lettore.
2. Apri **Dolphin**: individua la scheda nella barra laterale e aprila.
3. Crea una cartella `Music/HDtracks` e sottocartelle `Artista/Album`.
4. Copia i file **FLAC** (o altri formati supportati dal lettore) mantenendo i nomi e le copertine.
5. Aspetta il completamento della copia e usa **Espelli/Rimozione sicura** in Dolphin prima di scollegare la microSD o il FiiO.
6. Inserisci la scheda nel FiiO M3K e aggiorna la libreria musicale dalle impostazioni del lettore, se necessario.

**Formato della microSD:** verifica nel manuale del FiiO M3K capacità massima, file system supportati e aggiornamenti firmware. Non formattare una scheda con musica esistente senza backup; non presumere che ogni scheda exFAT/FAT32 o capacità sia supportata dal firmware in uso.

## 9. Alternativa: collegare microSD/USB direttamente alla VM

1. Con Windows avviato, inserisci una chiavetta USB o il lettore microSD nell'host.
2. In Virt-Manager apri la console Windows e cerca **Virtual Machine → Redirect USB Device** (la dicitura varia per versione).
3. Seleziona il dispositivo corretto; se non appare, controlla i canali USB Redirector e i permessi sull'host.
4. Windows dovrebbe rilevare il dispositivo. Copia i file e usa **Espelli** in Windows.
5. Disattiva il reindirizzamento prima di riaprire la stessa unità da Dolphin.

**Non montare o scrivere contemporaneamente la stessa partizione sia in Linux sia in Windows:** rischi di corrompere i file. Il pass-through USB non è garantito per ogni lettore, hub o dock.

## 10. Avvio quotidiano e manutenzione

- Apri il menu KDE → **Macchine virtuali (Virt-Manager)** → `HDtracks-Windows11` → **Start** → **Open**.
- Per spegnere, usa **Arresta il sistema** dentro Windows; evita **Force Off** salvo blocchi reali.
- Esegui Windows Update periodicamente e mantieni aggiornato il downloader HDtracks da fonti ufficiali.
- Prima di modificare driver o controller virtuali, esegui un backup del disco `.qcow2` **a VM spenta**. Gli snapshot richiedono una configurazione compatibile e non sostituiscono un backup.
- Usa `df -h /var/lib/libvirt/images` e Virt-Manager per controllare spazio e dimensioni; non cancellare a mano i file `.qcow2` di VM ancora definite.
- Il report dello script LEAN distingue componenti VM installati, VM definita e attività ancora manuali (Windows, driver, USB, HDtracks).

## 11. Risoluzione rapida dei problemi

| Problema | Verifica / soluzione |
|---|---|
| Virt-Manager non compare in KDE | Cerca `virt-manager`; nello script scegli `47` per riparare il launcher. |
| `Retrieving packages...` sembra fermo | Controlla rete, `ps` e `/var/log/pacman.log` da un'altra Konsole; non lanciare pacman in parallelo. |
| `/dev/kvm` assente | Controlla virtualizzazione Intel VT-x nel BIOS/UEFI. |
| Errore spazio disco | Controlla `df -h /var/lib/libvirt/images`; riduci dimensioni della VM **prima** della creazione o libera spazio in sicurezza. |
| Windows 11 rifiuta la VM | Verifica UEFI, TPM 2.0 e Secure Boot in Virt-Manager; non aggirare requisiti. |
| Mouse o risoluzione scadenti | Installa/aggiorna SPICE Guest Tools e verifica il tipo di display. |
| USB non appare in Windows | Controlla USB Redirector, permessi e che Linux non stia usando il dispositivo. |
| FiiO non mostra la musica | Verifica formato audio, struttura cartelle, file system, firmware e aggiornamento libreria. |
| Download HDtracks fallisce | Controlla accesso account, spazio disco Windows, connessione e istruzioni ufficiali HDtracks. |

## 12. Checklist finale

- [ ] Virt-Manager si apre dal menu KDE.
- [ ] VM `HDtracks-Windows11` avviabile con TPM e UEFI correttamente configurati.
- [ ] Windows 11 installato, aggiornato e utilizzato con licenza appropriata.
- [ ] Display/mouse funzionanti e driver guest necessari installati.
- [ ] HDtracks Downloader installato dal sito ufficiale; accesso agli acquisti riuscito.
- [ ] Primo album FLAC scaricato e verificato.
- [ ] Copia di backup conservata fuori dalla VM.
- [ ] Trasferimento riuscito su microSD con espulsione sicura.
- [ ] FiiO M3K riproduce correttamente i brani.
