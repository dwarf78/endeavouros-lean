# EndeavourOS LEAN — installer post-installazione per KDE Plasma (Arch-based)

Script Bash interattivo, **hardware-agnostic**, per configurare un laptop/desktop con EndeavourOS o altra distribuzione basata su Arch (Arch, CachyOS, Manjaro, Garuda…) e KDE Plasma 6.

Filosofia **LEAN**: installa solo ciò che chiedi, non rimuove mai nulla senza conferma esplicita, non tocca driver, kernel, bootloader, display manager o il menu KMenuEdit personalizzato.

## Requisiti

- Distribuzione basata su Arch con `pacman`
- Utente normale con `sudo` (non eseguire come root)
- `yay` opzionale: senza, i pacchetti AUR vengono saltati con avviso
- KDE Plasma 6 consigliato; le funzioni KDE si disattivano da sole su altri desktop

## Avvio

```bash
git clone git@github.com:dwarf78/endeavouros-lean.git ~/Projects/endeavouros-lean
cd ~/Projects/endeavouros-lean
chmod +x endeavouros-setup.sh
./endeavouros-setup.sh
```

Variabili opzionali:

| Variabile | Default | Uso |
|-----------|---------|-----|
| `LEAN_LOG_DIR` | `~/EndeavourOS-LEAN/log` | cartella di log e report |
| `LEAN_PROJECTS_DIR` | `~/Projects` | cartella progetti (creata solo se assente) |

## Menu

Il menu è organizzato in **8 categorie con al massimo 6 voci** ciascuna, più il percorso guidato `B`.

| # | Categoria | Contenuto |
|---|-----------|-----------|
| B | **Percorso guidato sicuro** | verifica → aggiornamento → installazione applicazioni base → audit finale, con conferme separate |
| 1 | Sistema e manutenzione | inventario (sola lettura), `pacman -Syu`, migrazione Flatpak/Snap/AppImage, orfani/cache/TRIM, monitoraggio hardware, aspetto KDE e prompt Bash |
| 2 | Ufficio e produttività | LibreOffice + font compatibili MS, Calibre, Bitwarden, PDF/OCR, HomeBank, OBS, HandBrake, DBeaver, Bruno, AppFlowy, stampante CUPS |
| 3 | Browser, web e comunicazione | Firefox con privacy avanzata e uBlock Origin, rimozione Brave (con conferma), tema Cupertino, launcher Google, Tuta Mail, Ferdium, ricostruzione collegamenti web KDE |
| 4 | Intelligenza artificiale | Claude Code, Codex CLI, Gemini CLI, VS Code, launcher LLM web con sottomenu KDE, Tangram, Ollama (CUDA/ROCm), modelli locali |
| 5 | Sviluppo | Docker + Compose + GitHub CLI, ambiente completo (uv, template), attivazione servizi, repository GitHub |
| 6 | Multimedia, cloud e mobile | Google Drive/Dropbox/MEGA/pCloud in Dolphin, Syncthing, KDE Connect, diagnostica smartphone, workflow foto, digiKam/darktable/Kdenlive |
| 7 | Grafica, gaming e virtualizzazione | Steam con stack Vulkan per ogni GPU rilevata, selettore GPU per-app, QEMU/KVM + Virt-Manager, VM guidata |
| 8 | Sicurezza, privacy e crypto | audit backup/SMART/Btrfs, blocco schermo + audit LUKS, Proton VPN, Ledger Nano, guida wallet DeFi |

Ogni voce dichiara se richiede `sudo`: le operazioni di sola lettura e quelle limitate alla HOME non chiedono la password.

## Rilevamento hardware

A ogni operazione lo script legge `/sys/bus/pci/devices` e `/sys/class/dmi/id` (senza installare pacchetti né interrogare Internet) e ricava il profilo GPU:

| Profilo | Configurazione |
|---------|----------------|
| `intel`, `amd`, `nvidia` | singola GPU |
| `hybrid-nvidia` | iGPU Intel o AMD + NVIDIA dedicata (PRIME / `prime-run`) |
| `hybrid-amd` | iGPU Intel + AMD dedicata (`DRI_PRIME=1`) |

Nessun modello di laptop è presupposto: Steam, Ollama e il selettore GPU si adattano alle GPU effettivamente presenti.

### Selettore GPU per-app

`lean-gpu-run <app>` avvia un'applicazione sulla GPU preferita (integrata / dedicata / hybrid) senza cambiare la GPU del desktop. Preferenza salvata in `~/.config/endeavouros-lean/gpu-mode`, impostabile dal menu o dagli shortcut KDE `GPU · …`.

## Sicurezza e reversibilità

- Installazioni: `pacman` prima, `yay` solo come fallback; nessun `curl | bash`, nessun `npm -g` di sistema
- Rimozioni (Brave, ONLYOFFICE, GnuCash, orfani): sempre con conferma `[s/N]`
- Configurazioni KDE/Firefox/Ollama: backup con timestamp accanto al file originale, override in file dedicati e reversibili
- Launcher `.desktop`: aggiornati solo se marcati `X-EndeavourOS-LEAN-Managed=true`; quelli personalizzati sono preservati
- Nessuna credenziale, token, seed phrase o chiave API viene richiesta o salvata

## Log e report

Ogni esecuzione produce in `~/EndeavourOS-LEAN/log/`:

- `installer-AAAAMMGG-HHMMSS.log` — output completo
- `installer-AAAAMMGG-HHMMSS-riepilogo.txt` — report finale: operazioni riuscite, errori, elementi da completare a mano, avvisi, verifica pacchetti

## File del repository

| File | Descrizione |
|------|-------------|
| `endeavouros-setup.sh` | lo script |
| `README.md` | questa guida |

## Licenza

Uso personale. I pacchetti AUR sono non verificati: controlla sempre il `PKGBUILD` prima di installarli.
