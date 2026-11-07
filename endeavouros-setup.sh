#!/usr/bin/env bash
# EndeavourOS KDE - LEAN installer v57 (photo/video, Google, Ollama, iPhone diagnostics): vibe coding, Steam, Ledger/DeFi, PDF/OCR
# No automatic removal of personal data, drivers or desktop components.
# AUR builds are untrusted; check PKGBUILD independently before execution.
# Office: LibreOffice only. Installazioni automatiche; rimozioni con conferma.
set -Eeuo pipefail
IFS=$'\n\t'

if [[ $EUID -eq 0 ]]; then echo 'Esegui come utente normale, non con sudo.'; exit 1; fi
command -v pacman >/dev/null || { echo 'Richiesto Arch/EndeavourOS con pacman.'; exit 1; }


# Rilevamento hardware senza installare driver e senza interrogare Internet.
# /sys/bus/pci/devices è disponibile anche prima di installare pciutils.
HW_PROFILE=unknown
HAS_INTEL_GPU=0
HAS_NVIDIA_GPU=0
HAS_AMD_GPU=0
HW_MODEL=unknown
detect_hardware(){
 local dev vendor class
 HAS_INTEL_GPU=0; HAS_NVIDIA_GPU=0; HAS_AMD_GPU=0
 for dev in /sys/bus/pci/devices/*; do
   [[ -r "$dev/vendor" && -r "$dev/class" ]] || continue
   vendor=$(<"$dev/vendor"); class=$(<"$dev/class")
   case "$class" in 0x03*) ;; *) continue;; esac
   case "$vendor" in
     0x8086) HAS_INTEL_GPU=1;;
     0x10de) HAS_NVIDIA_GPU=1;;
     0x1002) HAS_AMD_GPU=1;;
   esac
 done
 if [[ -r /sys/class/dmi/id/product_name ]]; then
   HW_MODEL=$(< /sys/class/dmi/id/product_name)
 fi
 if (( HAS_NVIDIA_GPU && HAS_INTEL_GPU )); then HW_PROFILE=intel-nvidia
 elif (( HAS_NVIDIA_GPU )); then HW_PROFILE=nvidia
 elif (( HAS_INTEL_GPU )); then HW_PROFILE=intel
 elif (( HAS_AMD_GPU )); then HW_PROFILE=amd
 else HW_PROFILE=unknown
 fi
 printf 'Hardware: %s | GPU Intel=%s NVIDIA=%s AMD=%s | profilo=%s\n' \
   "$HW_MODEL" "$HAS_INTEL_GPU" "$HAS_NVIDIA_GPU" "$HAS_AMD_GPU" "$HW_PROFILE"
}
detect_hardware

LOG="$HOME/installer-endeavouros-lean-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
# Report strutturato: salvato anche in caso di interruzione o errore.
REPORT="${LOG%.log}-riepilogo.txt"
RUN_STARTED=$(date '+%Y-%m-%d %H:%M:%S')
RUN_FINISHED=0
RUN_MODE="Menu interattivo"
declare -a REPORT_OK=() REPORT_FAIL=() REPORT_SKIP=() REPORT_WARN=()
declare -A REQUESTED_PACKAGES=()
report_ok(){ REPORT_OK+=("$*"); }
report_fail(){ REPORT_FAIL+=("$*"); }
report_skip(){ REPORT_SKIP+=("$*"); }
report_warn(){ REPORT_WARN+=("$*"); }
report_section(){
 local heading="$1"; shift
 printf '\n%s (%s)\n' "$heading" "$#"
 if (($#)); then printf '%s\n' "$@" | awk '!seen[$0]++ {print "  - " $0}'; else echo '  Nessuno'; fi
}
lean_vm_final_report(){
 echo
 echo 'STATO VIRTUALIZZAZIONE / HDTRACKS — VERIFICA FINALE'
 local item cmd
 for item in qemu-desktop libvirt virt-manager virt-install edk2-ovmf swtpm dnsmasq spice-gtk usbredir; do
   if pacman -Qq "$item" >/dev/null 2>&1; then printf '  [OK] %s\n' "$item";
   else printf '  [MANCA] %s\n' "$item"; fi
 done
 if [[ -e /dev/kvm ]]; then echo '  [OK] /dev/kvm presente'; else echo '  [MANCA] /dev/kvm: verificare VT-x/AMD-V nel BIOS/UEFI'; fi
 if command -v virt-manager >/dev/null 2>&1; then echo '  [OK] Virt-Manager disponibile'; else echo '  [MANCA] Virt-Manager'; fi
 if systemctl is-active --quiet libvirtd.service || systemctl is-active --quiet virtqemud.socket; then
   echo '  [OK] Servizio/socket libvirt attivo'
 else echo '  [DA FARE] Avviare libvirt (libvirtd oppure virtqemud)'; fi
 if id -nG "$USER" | grep -qw libvirt; then echo '  [OK] Gruppo libvirt attivo nella sessione'
 elif id -nG "$USER" | grep -qw libvirt || getent group libvirt | grep -qE "[:,]${USER}(,|$)"; then
   echo '  [DA FARE] Logout/login per attivare il gruppo libvirt'
 else echo '  [DA FARE] Autorizzazione utente libvirt da verificare'; fi
 if command -v virsh >/dev/null 2>&1; then
   if virsh -c qemu:///system list --all 2>/dev/null | grep -q 'HDtracks-Windows11'; then
     echo '  [OK] VM HDtracks-Windows11 definita in libvirt'
   else echo '  [DA FARE] VM HDtracks-Windows11 non ancora creata'; fi
 else echo '  [DA FARE] VM non verificabile: virsh assente'; fi
 if [[ -d "$HOME/Downloads" ]] && find "$HOME/Downloads" -maxdepth 1 -type f \( -iname '*win11*.iso' -o -iname '*windows*11*.iso' \) -print -quit 2>/dev/null | grep -q .; then
   echo '  [DA VERIFICARE] ISO Windows 11 individuata in Download; controllare origine/checksum'
 else echo '  [DA FARE] Scaricare ISO Windows 11 ufficiale dal sito Microsoft'; fi
 echo '  [DA VERIFICARE] Installazione Windows 11, licenza, driver VirtIO/SPICE e HDtracks dentro la VM'
 echo '  [DA VERIFICARE] USB redirection / microSD e cartella di trasferimento FLAC'
 echo '  [INFO] Windows 11 ISO gratuita, licenza non inclusa; macOS non installabile qui'
}
report_final(){
 local status="$1" pkg
 ((RUN_FINISHED)) && return 0
 RUN_FINISHED=1
 {
   echo '============================================================'
   echo ' REPORT FINALE — ENDEAVOUROS LEAN v57'
   echo '============================================================'
   echo "Modalità: $RUN_MODE"
   echo "Inizio: $RUN_STARTED"
   echo "Fine:   $(date '+%Y-%m-%d %H:%M:%S')"
   echo "Codice di uscita: $status"
   if ((status != 0)); then echo 'ESITO: INTERROTTO / ERRORE';
   elif ((${#REPORT_FAIL[@]})); then echo 'ESITO: COMPLETATO CON ERRORI';
   elif ((${#REPORT_SKIP[@]})); then echo 'ESITO: COMPLETATO CON ELEMENTI DA VERIFICARE';
   else echo 'ESITO: COMPLETATO (nessun errore registrato)'; fi
   report_section 'OPERAZIONI RIUSCITE' "${REPORT_OK[@]}"
   report_section 'ERRORI / OPERAZIONI NON RIUSCITE' "${REPORT_FAIL[@]}"
   report_section 'NON ESEGUITO / DA COMPLETARE MANUALMENTE' "${REPORT_SKIP[@]}"
   report_section 'AVVISI' "${REPORT_WARN[@]}"
   echo
   echo 'VERIFICA PACCHETTI RICHIESTI DURANTE LA SESSIONE'
   if ((${#REQUESTED_PACKAGES[@]})); then
     for pkg in "${!REQUESTED_PACKAGES[@]}"; do
       if pacman -Qq "$pkg" >/dev/null 2>&1; then
         printf '  [PRESENTE] %s\n' "$pkg"
       else
         printf '  [MANCANTE] %s\n' "$pkg"
       fi
     done | sort
   else echo '  Nessun pacchetto tracciato'; fi
   echo
   lean_vm_final_report
   lean_github_report
   lean_syncthing_report
   lean_appflowy_report
   lean_workspace_final_report
   echo "Log dettagliato: $LOG"
   echo "Report salvato: $REPORT"
   echo 'Nota: il controllo pacchetti non garantisce il corretto avvio delle applicazioni.'
   echo '============================================================'
 } | tee "$REPORT"
}
on_error(){ local rc=$?; report_fail "Errore non gestito (riga $1, codice $rc)"; return 0; }
on_exit(){ local rc=$?; trap - EXIT; report_final "$rc"; kill "${SUDO_KEEPALIVE_PID:-}" 2>/dev/null || true; }
trap 'on_error "$LINENO"' ERR
trap on_exit EXIT

# Una richiesta password sudo all'avvio; rinnovo ticket finche lo script e' attivo.
sudo -v || exit 1
( while true; do sudo -n -v 2>/dev/null || exit; sleep 45; done ) &
SUDO_KEEPALIVE_PID=$!


say(){ printf '\n\033[1;36m%s\033[0m\n' "$*"; }
warn(){ printf '\nATTENZIONE: %s\n' "$*"; }
# Conferme standard: Invio = Si. Operazioni distruttive/pubblicazione: default No.
ask(){ local answer; read -r -p "$1 [S/n] " answer || return 1; [[ -z "$answer" || "$answer" =~ ^[sSyY]$ ]]; }
ask_explicit(){ local answer; read -r -p "$1 [s/N] " answer || return 1; [[ "$answer" =~ ^[sSyY]$ ]]; }
has_repo(){ pacman -Si "$1" >/dev/null 2>&1; }
has_pkg(){ pacman -Qq "$1" >/dev/null 2>&1; }
need_yay(){ command -v yay >/dev/null || { warn 'yay non disponibile: pacchetti AUR saltati.'; return 1; }; }
install_repo(){ local pkg
 for pkg in "$@"; do
  REQUESTED_PACKAGES["$pkg"]=1
  if has_pkg "$pkg"; then
    echo "[OK] $pkg già installato"; report_ok "Pacchetto già presente: $pkg"
  elif has_repo "$pkg"; then
    echo "[PACMAN] $pkg"
    if sudo -n pacman -S --needed --noconfirm "$pkg" && has_pkg "$pkg"; then
      report_ok "Installato con pacman: $pkg"
    else
      report_fail "Installazione pacman fallita o non verificata: $pkg"
    fi
  else
    warn "$pkg non presente nei repository configurati; saltato"
    report_skip "Pacchetto non disponibile nei repository: $pkg"
  fi
 done
}
install_fallback(){ local candidate="$1" aur="${2:-$1}"
 if has_pkg "$candidate" || has_pkg "$aur"; then
   report_ok "Già presente: $candidate/$aur"; return 0
 fi
 if has_repo "$candidate"; then install_repo "$candidate"; return 0; fi
 if ! command -v yay >/dev/null; then
   report_skip "AUR non disponibile (yay assente): $aur"; return 0
 fi
 if yay -Si "$aur" >/dev/null 2>&1; then
   warn "AUR: $aur. --noconfirm non sostituisce la verifica del PKGBUILD."
   if yay -S --needed --noconfirm "$aur" && has_pkg "$aur"; then
     report_ok "Installato con yay: $aur"
   else
     report_fail "Installazione AUR fallita: $aur"
   fi
 else
   report_skip "Pacchetto non trovato (pacman/yay): $candidate / $aur"
 fi
}

updated=0
update_system(){
 say 'Aggiornamento completo Arch (no partial upgrades)'
 warn 'Un aggiornamento Arch puo aggiornare anche i pacchetti NVIDIA gia installati. Non li riconfiguro, ma pacman puo aggiornarli.'
 sudo -n pacman -Syu --noconfirm
 updated=1
}

migration(){
 say 'Inventario installazioni esterne (rimozione duplicati con conferma)'
 if command -v flatpak >/dev/null; then
   flatpak list --app --columns=application,name,installation 2>/dev/null || true
 else echo 'Flatpak non installato'; fi
 if command -v snap >/dev/null; then snap list 2>/dev/null || true; else echo 'Snap non installato'; fi
 if command -v npm >/dev/null; then npm list -g --depth=0 2>/dev/null || true; fi
 echo 'Possibili AppImage (sola lettura):'
 find "$HOME/Applications" "$HOME/Downloads" -maxdepth 2 -type f \( -iname '*.AppImage' -o -iname '*.appimage' \) -print 2>/dev/null || true
 echo
 warn 'Rimuovi solo app duplicate dopo aver provato le sostituzioni pacman/yay. Nessuna cancellazione automatica di profili o dati.'
 if command -v flatpak >/dev/null; then
   local app target
   for app in com.bitwarden.desktop com.valvesoftware.Steam org.mozilla.firefox com.calibre_ebook.calibre org.libreoffice.LibreOffice; do
     if flatpak info "$app" >/dev/null 2>&1; then
       echo "Trovata versione Flatpak: $app"
       case "$app" in
         com.bitwarden.desktop) target=bitwarden;;
         com.valvesoftware.Steam) target=steam;;
         org.mozilla.firefox) target=firefox;;
         com.calibre_ebook.calibre) target=calibre;;
         org.libreoffice.LibreOffice) target=libreoffice-fresh;;
       esac
       if ! has_pkg "$target"; then warn "Alternativa $target non ancora installata: mantengo Flatpak $app"; continue; fi
       if ask_explicit "Disinstallare SOLO l'app Flatpak $app (dati mantenuti)?"; then flatpak uninstall --noninteractive "$app"; fi
     fi
   done
 fi
 warn 'Snap, npm globale, AppImage e altre Flatpak: solo inventario, senza rimozione automatica per evitare perdita di dati o rimozioni errate.'
}

steam_setup(){
 say 'Steam / DualShock 4 / Gaming'
 if [[ $updated -ne 1 ]]; then warn 'Prima esegui la sezione 1: aggiornamento completo; Steam non installato.'; return; fi
 if ! grep -Eq '^\[multilib\]' /etc/pacman.conf; then
   warn 'Repository [multilib] non abilitato. Non modifico automaticamente pacman.conf.'
   echo 'Abilita [multilib] manualmente, esegui sudo pacman -Syu e riprova.'
   return
 fi
 detect_hardware
 local gpu_pkgs=(lib32-mesa lib32-vulkan-icd-loader vulkan-icd-loader steam steam-devices bluez bluez-utils)
 if (( HAS_NVIDIA_GPU )); then
   if has_pkg nvidia-utils; then
     local installed_version lib32_version
     installed_version=$(pacman -Q nvidia-utils | awk '{print $2}')
     lib32_version=$(pacman -Si lib32-nvidia-utils | awk '/^Version/{print $3;exit}')
     if [[ -n "$lib32_version" && "$installed_version" == "$lib32_version" ]]; then
       gpu_pkgs+=(lib32-nvidia-utils)
     else
       warn 'Versioni NVIDIA non allineate: lib32-nvidia-utils escluso; non modifico driver.'
       report_warn 'NVIDIA: controllare versioni driver e lib32-nvidia-utils'
     fi
   else
     warn 'GPU NVIDIA rilevata ma nvidia-utils assente: non installo driver automaticamente.'
     report_warn 'NVIDIA: driver da verificare manualmente'
   fi
   if has_pkg nvidia-utils; then gpu_pkgs+=(nvidia-prime); fi
 elif (( HAS_INTEL_GPU )); then
   gpu_pkgs+=(vulkan-intel lib32-vulkan-intel)
   echo 'Intel integrata: installazione stack Mesa/Vulkan Intel; niente pacchetti NVIDIA.'
 elif (( HAS_AMD_GPU )); then
   gpu_pkgs+=(vulkan-radeon lib32-vulkan-radeon)
   echo 'AMD: installazione stack Mesa/Vulkan Radeon; niente pacchetti NVIDIA.'
 else
   warn 'GPU non identificata: installazione stack grafico specifico sospesa.'
 fi
 install_repo "${gpu_pkgs[@]}"
 if command -v systemctl >/dev/null; then
   if ! systemctl is-enabled bluetooth.service >/dev/null 2>&1; then
     if ask 'Abilitare e avviare Bluetooth per DualShock 4 wireless?'; then sudo -n systemctl enable --now bluetooth.service; fi
   fi
 fi
 echo
 echo 'DualShock 4: USB oppure Bluetooth (tieni premuti SHARE + PS finche lampeggia; associa da Impostazioni KDE > Bluetooth).'
 echo 'Steam > Impostazioni > Controller: abilita Steam Input per controller PlayStation dove necessario.'
 echo 'Steam > Impostazioni > Compatibilita: abilita Proton per i giochi Windows.'
 if (( HAS_NVIDIA_GPU )); then echo 'Per usare NVIDIA in Steam: prime-run %command% (se disponibile).'; fi
 echo 'Proton GE e MangoHud sono OPZIONALI: installali solo se servono, non come dipendenze obbligatorie.'
 install_repo mangohud lib32-mangohud gamemode lib32-gamemode
 install_fallback protonup-qt
}

remove_onlyoffice(){
 say 'Rimozione opzionale ONLYOFFICE (solo dopo verifica LibreOffice)'
 if ! has_pkg libreoffice-fresh && ! has_pkg libreoffice-still; then
   warn 'LibreOffice non risulta installato: mantengo ONLYOFFICE per non lasciarti senza suite Office.'
   return
 fi
 local pkg
 for pkg in onlyoffice-bin onlyoffice-desktopeditors onlyoffice-desktopeditors-bin onlyoffice; do
   if has_pkg "$pkg"; then
     if ask_explicit "Rimuovere $pkg con pacman -R (senza cancellare i dati personali)?"; then
       sudo -n pacman -R --noconfirm "$pkg"
     fi
   fi
 done
 if command -v flatpak >/dev/null && flatpak info org.onlyoffice.desktopeditors >/dev/null 2>&1; then
   if ask_explicit 'Rimuovere ONLYOFFICE Flatpak (senza --delete-data)?'; then
     flatpak uninstall --noninteractive org.onlyoffice.desktopeditors
   fi
 fi
 if command -v snap >/dev/null && snap list onlyoffice-desktopeditors >/dev/null 2>&1; then
   warn 'ONLYOFFICE Snap rilevato.'
   if ask_explicit 'Rimuovere ONLYOFFICE Snap (senza opzioni di eliminazione dati)?'; then
     sudo -n snap remove onlyoffice-desktopeditors
   fi
 fi
 echo 'Configurazioni e documenti personali non vengono eliminati dallo script.'
}
# LibreOffice: GTK3 risolve lo scaling misto eDP-1 100% / DP-1 145%.
# Crea override dei launcher solo per LibreOffice, senza alterare KDE o Qt globali.
lean_libreoffice_gtk3(){
 say 'LibreOffice: backend GTK3 per configurazione multi-monitor KDE Wayland'
 local old="$HOME/.config/environment.d/90-libreoffice-kf6.conf"
 if [[ -f "$old" ]] && [[ "$(cat "$old")" == 'SAL_USE_VCLPLUGIN=kf6' || "$(cat "$old")" == 'SAL_USE_VCLPLUGIN=kf6\n' ]]; then
   rm -- "$old"
   echo '[OK] Rimossa impostazione kf6 creata dalle versioni precedenti.'
 elif [[ -e "$old" ]]; then
   warn "Non modifico configurazione personalizzata: $old"
 fi
 local appdir="$HOME/.local/share/applications" source target name
 mkdir -p "$appdir"
 local count=0 skipped=0
 for source in /usr/share/applications/libreoffice-*.desktop; do
   [[ -f "$source" ]] || continue
   name="${source##*/}"
   target="$appdir/$name"
   if [[ -e "$target" ]]; then
     if grep -q '^Exec=env SAL_USE_VCLPLUGIN=gtk3 GDK_SCALE=1 ' "$target"; then
       echo "[OK] $name già configurato"
     else
       warn "Override esistente non modificato: $target"
       skipped=$((skipped+1))
     fi
     continue
   fi
   # Copia le voci Exec (incluse le Desktop Actions) preservando gli argomenti originali.
   sed -E 's|^Exec=|Exec=env SAL_USE_VCLPLUGIN=gtk3 GDK_SCALE=1 |' "$source" > "$target"
   count=$((count+1))
 done
 if (( count > 0 )); then
   echo "[OK] Creati $count launcher LibreOffice GTK3 in $appdir"
 fi
 if (( skipped > 0 )); then
   report_warn "LibreOffice: $skipped launcher utente preesistenti da verificare"
 fi
 if (( count == 0 && skipped == 0 )); then
   warn 'Nessun nuovo launcher trovato: verificare i file .desktop di LibreOffice.'
 fi
 echo 'Chiudi LibreOffice e riaprilo dal menu KDE; se necessario, esci e rientra nella sessione.'
 echo 'Test manuale: SAL_USE_VCLPLUGIN=gtk3 GDK_SCALE=1 libreoffice --draw'
}
lean_office_fonts(){
 say 'Font compatibilità Microsoft Office / LibreOffice (font liberi e sostituti metrici)'
 install_repo fontconfig ttf-liberation ttf-carlito ttf-caladea noto-fonts noto-fonts-emoji
 if command -v fc-cache >/dev/null 2>&1; then fc-cache -f "$HOME/.local/share/fonts" 2>/dev/null || true; fi
 echo 'Liberation Sans/Serif/Mono sostituiscono Arial/Times New Roman/Courier New; Carlito sostituisce Calibri; Caladea sostituisce Cambria.'
 echo 'I font Microsoft originali (Arial, Calibri, Aptos, ecc.) NON vengono scaricati senza licenza/fonte autorizzata.'
 report_ok 'Font metricamente compatibili con Microsoft Office richiesti; verifica pacchetti nel report'
}
# AppFlowy: alternativa open-source a Notion. AUR solo con consenso esplicito.
lean_appflowy(){
 say 'AppFlowy: installazione desktop nativa (pacman -> AUR, con consenso)'
 if [[ $(uname -m) != x86_64 ]]; then
   report_skip 'AppFlowy: architettura non x86_64; installazione saltata'
   return 0
 fi
 local pkg='' candidate found=0 f bin=''
 if has_pkg appflowy-bin || has_pkg appflowy; then
   report_ok 'AppFlowy: pacchetto già installato'
 else
   for candidate in appflowy-bin appflowy; do
     if has_repo "$candidate"; then
       install_repo "$candidate"
       break
     fi
   done
   if ! has_pkg appflowy-bin && ! has_pkg appflowy; then
     if ! command -v yay >/dev/null 2>&1; then
       warn 'AppFlowy richiede normalmente AUR; yay non è installato.'
       if has_repo yay && ask 'Installare yay dai repository configurati per poter installare AppFlowy?'; then
         install_repo yay
       fi
     fi
     if command -v yay >/dev/null 2>&1; then
       for candidate in appflowy-bin appflowy; do
         if yay -Si "$candidate" >/dev/null 2>&1; then pkg="$candidate"; break; fi
       done
       if [[ -n "$pkg" ]]; then
         echo "AppFlowy: trovato $pkg su AUR (PKGBUILD di terze parti)."
         if ask "Vuoi esaminare e installare $pkg tramite yay?"; then
           if yay -S --needed "$pkg" && has_pkg "$pkg"; then
             report_ok "AppFlowy: installato tramite AUR ($pkg)"
           else
             report_fail "AppFlowy: installazione AUR fallita ($pkg); consultare il log $LOG"
           fi
         else
           report_skip 'AppFlowy: installazione AUR non autorizzata'
         fi
       else
         report_fail 'AppFlowy: nessun pacchetto appflowy-bin/appflowy trovato in AUR; verificare connessione, yay e nomi pacchetti'
       fi
     else
       report_fail 'AppFlowy: yay assente; installare yay in modo verificato e riprovare con opzione 53'
     fi
   fi
 fi
 if has_pkg appflowy-bin || has_pkg appflowy; then
   for f in /usr/share/applications/*appflowy*.desktop /usr/share/applications/*AppFlowy*.desktop "$HOME"/.local/share/applications/*appflowy*.desktop "$HOME"/.local/share/applications/*AppFlowy*.desktop; do
     [[ -f "$f" ]] && { found=1; break; }
   done
   for bin in /usr/bin/appflowy /usr/bin/app_flowy /opt/AppFlowy/AppFlowy; do
     [[ -x "$bin" ]] && break
   done
   if (( !found )) && [[ -x "$bin" ]]; then
     mkdir -p "$HOME/.local/share/applications"
     cat > "$HOME/.local/share/applications/lean-appflowy.desktop" <<EOFAPPFLOWY
[Desktop Entry]
Type=Application
Name=AppFlowy
Comment=Workspace open source per note, progetti e database
Exec=$bin
Icon=appflowy
Terminal=false
Categories=Office;Utility;
EOFAPPFLOWY
     report_ok 'AppFlowy: collegamento KDE di fallback creato'
   fi
   if (( !found )) && [[ ! -x "$bin" ]]; then
     report_warn 'AppFlowy: pacchetto installato ma launcher/eseguibile non individuato; controllare pacman -Ql appflowy-bin'
   else
     report_ok 'AppFlowy: launcher o eseguibile individuato'
   fi
   if command -v kbuildsycoca6 >/dev/null 2>&1; then
     kbuildsycoca6 --noincremental >/dev/null 2>&1 || report_warn 'AppFlowy: cache KDE non aggiornata'
   fi
 else
   report_fail 'AppFlowy: non risulta installato; vedere messaggi sopra e log'
 fi
}
lean_appflowy_report(){
 echo
 echo 'APPFLOWY — WORKSPACE / NOTE'
 if has_pkg appflowy-bin || has_pkg appflowy; then
   echo '  [OK] Pacchetto AppFlowy installato'
 else
   echo '  [DA FARE] AppFlowy non installato: voce 53 (pacman, poi AUR con consenso)'
 fi
 echo '  [INFO] Nessun dato AppFlowy esistente viene eliminato'
}

# Inventario browser in sola lettura: deve precedere ogni installazione nel percorso B.
# La selezione degli shortcut avviene di nuovo al momento della loro creazione:
# se un browser viene installato/rimosso nel frattempo, i launcher non restano obsoleti.
lean_browser_audit(){
 say 'AUDIT BROWSER PRE-INSTALLAZIONE (sola lettura)'
 local candidate path selected='' 
 for candidate in chromium chromium-browser firefox brave brave-browser; do
   path=$(command -v "$candidate" 2>/dev/null || true)
   if [[ -n "$path" && -x "$path" ]]; then
     printf '  [PRESENTE] %-17s %s\n' "$candidate" "$path"
   else
     printf '  [ASSENTE]  %s\n' "$candidate"
   fi
 done
 selected=$(lean_shortcut_browser || true)
 if [[ -n "$selected" ]]; then
   printf '  [SCELTO] Shortcut KDE: %s (rilevato ora)\n' "$selected"
   report_ok "Browser shortcut rilevato prima delle installazioni: $selected"
 else
   warn 'Chromium e Firefox assenti: nessuno shortcut web verrà creato finché non sarà disponibile un browser.'
   report_warn 'Browser shortcut: Chromium/Firefox assenti al preflight'
 fi
 echo '  [INFO] Brave non viene usato per gli shortcut LEAN, anche se installato.'
}
# Ripulisce esclusivamente i launcher web creati da LEAN o riconoscibili
# come suoi vecchi collegamenti. Non tocca il menu KDE di sistema né le app native.
lean_clean_web_shortcuts(){
 say 'KDE: rimozione shortcut LEAN precedenti e duplicati web riconosciuti'
 local appdir="$HOME/.local/share/applications" file base count=0
 [[ -d "$appdir" ]] || return 0
 local -a candidates=(
   "$appdir"/ai-*-ai.desktop "$appdir"/lean-google-*.desktop
   "$appdir"/google-*.desktop "$appdir"/famiglia-*.desktop
   "$appdir"/lean-tuta-mail.desktop "$appdir"/endeavouros-lean-ferdium.desktop
 )
 for file in "${candidates[@]}"; do
   [[ -f "$file" && ! -L "$file" ]] || continue
   base=${file##*/}
   if grep -q '^X-EndeavourOS-LEAN-Managed=true$' "$file" ||
      { [[ "$base" == ai-*-ai.desktop || "$base" == lean-google-*.desktop ||
            "$base" == famiglia-*.desktop || "$base" == google-*.desktop ||
            "$base" == lean-tuta-mail.desktop || "$base" == endeavouros-lean-ferdium.desktop ]] &&
        grep -Eq '^Exec=.*(chatgpt\\.com|claude\\.ai|gemini\\.google\\.com|perplexity\\.ai|grok\\.com|docs\\.google\\.com|drive\\.google\\.com|calendar\\.google\\.com|tasks\\.google\\.com|mail\\.google\\.com|keep\\.google\\.com|app\\.tuta\\.com|ferdium)' "$file"; }; then
      rm -- "$file" || { report_warn "Impossibile rimuovere $file"; continue; }
      count=$((count+1))
   fi
 done
 report_ok "Shortcut LEAN precedenti rimossi: $count"
}
lean_rebuild_web_shortcuts(){
 say 'KDE: audit browser -> pulizia LEAN -> shortcut unici -> cache menu'
 lean_browser_audit
 if ! lean_shortcut_browser >/dev/null 2>&1; then
   report_warn 'Chromium/Firefox assenti: non cancello shortcut prima di poterli ricreare'
   return 0
 fi
 lean_clean_web_shortcuts
 ai_desktop
 lean_google_office
 google_workspace
 lean_tuta_desktop
 # Ferdium usa il launcher nativo del pacchetto: mai un secondo .desktop.
 if command -v kbuildsycoca6 >/dev/null 2>&1; then
   kbuildsycoca6 --noincremental >/dev/null 2>&1 || report_warn 'Cache KDE non aggiornata'
 elif command -v kbuildsycoca5 >/dev/null 2>&1; then
   kbuildsycoca5 --noincremental >/dev/null 2>&1 || true
 fi
 report_ok "Shortcut KDE ricreati con $(lean_shortcut_browser)"
}

# Browser per launcher KDE: Chromium, poi Firefox. Non usare Brave, anche se installato.
# Safari non esiste nativamente su EndeavourOS/Linux.
lean_shortcut_browser(){
 local candidate
 for candidate in chromium chromium-browser firefox; do
   if command -v "$candidate" >/dev/null 2>&1; then
     printf '%s' "$candidate"; return 0
   fi
 done
 return 1
}
lean_shortcut_exec(){
 local browser="$1" url="$2"
 case "$browser" in
   chromium|chromium-browser) printf '%s --new-window %s' "$browser" "$url" ;;
   firefox) printf 'firefox --new-window %s' "$url" ;;
   *) return 1 ;;
 esac
}

lean_tuta_desktop(){
 say 'Tuta Mail: priorità al client desktop nativo, Firefox solo come fallback'
 # Pacchetto AUR di terze parti: non installare senza revisione PKGBUILD.
 if has_pkg tutanota-desktop || has_pkg tuta-desktop; then
   report_ok 'Tuta desktop già installato'
 elif has_repo tutanota-desktop; then
   install_repo tutanota-desktop
 elif has_repo tuta-desktop; then
   install_repo tuta-desktop
 else
   if command -v yay >/dev/null 2>&1 && ask 'Tuta desktop non presente nei repository: vuoi esaminare e installare tutanota-desktop da AUR?'; then
     echo 'Prima di procedere, verifica attentamente PKGBUILD e provenienza del pacchetto.'
     yay -S --needed tutanota-desktop || report_warn 'Tuta AUR: installazione non riuscita; disponibile fallback Firefox'
   else
     report_skip 'Tuta desktop: pacchetto repo assente; disponibile fallback Firefox'
   fi
 fi

 local desktop="$HOME/.local/share/applications/lean-tuta-mail.desktop"
 local native_exec='' native_icon='internet-mail' pkg entry desktop_id candidate
 mkdir -p "${desktop%/*}"
 # Preferire il launcher .desktop fornito dal pacchetto, che conosce l'eseguibile corretto.
 # Evitare il launcher LEAN stesso per non creare un ciclo gtk-launch.
 for pkg in tutanota-desktop tuta-desktop; do
   if has_pkg "$pkg"; then
     while IFS= read -r entry; do
       [[ "$entry" == /usr/share/applications/*.desktop ]] || continue
       [[ -f "$entry" ]] || continue
       desktop_id="${entry##*/}"; desktop_id="${desktop_id%.desktop}"
       [[ "$desktop_id" == lean-tuta-mail ]] && continue
       if command -v gtk-launch >/dev/null 2>&1; then
         native_exec="gtk-launch $desktop_id"
         candidate=$(sed -n 's/^Icon=//p' "$entry" | head -n 1)
         [[ -n "$candidate" ]] && native_icon="$candidate"
         break
       fi
     done < <(pacman -Qlq "$pkg" 2>/dev/null || true)
   fi
   [[ -n "$native_exec" ]] && break
 done
 # Se manca gtk-launch o il pacchetto non fornisce un .desktop, verificare il binario.
 if [[ -z "$native_exec" ]]; then
   for candidate in tutanota-desktop tuta-desktop; do
     if command -v "$candidate" >/dev/null 2>&1; then
       native_exec="$candidate"
       break
     fi
   done
 fi
 if [[ -z "$native_exec" ]]; then
   local shortcut_browser
   shortcut_browser=$(lean_shortcut_browser || true)
   if [[ -z "$shortcut_browser" ]]; then
     report_warn 'Tuta: client nativo e browser assenti; launcher non creato'
     return 0
   fi
   native_exec=$(lean_shortcut_exec "$shortcut_browser" 'https://app.tuta.com/')
   report_warn "Tuta: client nativo assente; launcher via $shortcut_browser"
 else
   report_ok "Tuta: launcher KDE nativo ($native_exec)"
 fi

 # Aggiornare il vecchio launcher LEAN Firefox, ma non sovrascrivere launcher personalizzati.
 if [[ -e "$desktop" ]] && ! grep -q '^X-EndeavourOS-LEAN-Managed=true$' "$desktop" && ! grep -Eq '^Exec=(brave|brave-browser|chromium|chromium-browser|firefox) (--app=|--new-window )https://app.tuta.com/?$' "$desktop"; then
   report_skip "Tuta: launcher personalizzato conservato ($desktop)"
 else
   cat > "$desktop" <<EOFTUTA
[Desktop Entry]
Type=Application
Name=Tuta Mail
Comment=Posta privata Tuta
Exec=$native_exec
Icon=$native_icon
Terminal=false
Categories=Network;Email;
X-EndeavourOS-LEAN-Managed=true
EOFTUTA
   report_ok 'Launcher Tuta Mail aggiornato nel menu KDE'
 fi
 if command -v kbuildsycoca6 >/dev/null 2>&1; then
   kbuildsycoca6 --noincremental >/dev/null 2>&1 || report_warn 'Tuta: cache KDE non aggiornata'
 fi
}

lean_google_office(){
 say 'Google Docs / Sheets / Slides / Drive: browser installato (Chromium > Firefox (Brave escluso))'
 local browser
 browser=$(lean_shortcut_browser || true)
 if [[ -z "$browser" ]]; then report_warn 'Google Workspace: nessun browser disponibile'; return 0; fi
 local dir="$HOME/.local/share/applications" key title url icon cmd
 mkdir -p "$dir"
 while IFS='|' read -r key title url icon; do
  local desktop="$dir/lean-google-${key}.desktop"
  if [[ -e "$desktop" ]] && ! grep -q '^X-EndeavourOS-LEAN-Managed=true$' "$desktop" && ! grep -Eq '^Exec=(brave|brave-browser|chromium|chromium-browser|firefox) (--app=|--new-window )' "$desktop"; then
    report_skip "Google $title: launcher personalizzato conservato"; continue
  fi
  cmd=$(lean_shortcut_exec "$browser" "$url")
  cat > "$desktop" <<EOFGO
[Desktop Entry]
Type=Application
Name=Google $title
Comment=Google Workspace online ($browser)
Exec=$cmd
Icon=$icon
Terminal=false
Categories=Office;Network;
X-EndeavourOS-LEAN-Managed=true
EOFGO
  report_ok "Google $title: launcher KDE creato"
 done <<'GOOGLEOFFICE'
docs|Docs|https://docs.google.com/document/|x-office-document
sheets|Sheets|https://docs.google.com/spreadsheets/|x-office-spreadsheet
slides|Slides|https://docs.google.com/presentation/|x-office-presentation
drive|Drive|https://drive.google.com/|$HOME/.local/share/icons/endeavouros-lean/drive.svg
GOOGLEOFFICE
 echo 'Google Docs Offline: estensione ufficiale Google Docs Offline destinata ai browser Chromium supportati, NON Firefox.'
 echo 'Firefox: Docs/Sheets/Slides funzionano online. Per lavoro offline utilizzare LibreOffice e sincronizzare manualmente al ritorno online.'
 echo 'Non installo estensioni Firefox che promettono offline Docs senza supporto ufficiale.'
 report_skip 'Google Docs/Sheets/Slides offline in Firefox: non supportato ufficialmente; usare LibreOffice offline'
 if command -v kbuildsycoca6 >/dev/null 2>&1; then kbuildsycoca6 --noincremental >/dev/null 2>&1 || true; fi
}
lean_postinstall_review(){
 say 'Audit post-installazione: pacchetti, dipendenze, cache (nessuna rimozione forzata)'
 detect_hardware
 if command -v pacman >/dev/null; then
  pacman -Dk || report_warn 'Pacman: problemi di dipendenze rilevati'
  echo 'Pacchetti orfani (verificare prima di rimuovere):'
  pacman -Qdtq 2>/dev/null || true
 fi
 if command -v paccache >/dev/null; then
  echo 'Cache pacman: pulizia conservativa tramite funzione esistente';
 else report_skip 'paccache assente: installare pacman-contrib se necessario'; fi
 report_ok "Audit hardware post-installazione: $HW_MODEL ($HW_PROFILE)"
}
lean_workspace_final_report(){
 echo
 echo 'STATO OFFICE / PRIVACY / GOOGLE WORKSPACE'
 local pkg
 for pkg in firefox firefox-ublock-origin libreoffice-fresh ttf-liberation ttf-carlito ttf-caladea proton-vpn-gtk-app; do
  if has_pkg "$pkg"; then echo "  [OK] $pkg"; else echo "  [DA VERIFICARE] $pkg"; fi
 done
 for pkg in lean-google-docs lean-google-sheets lean-google-slides lean-tuta-mail; do
  if [[ -f "$HOME/.local/share/applications/$pkg.desktop" ]]; then echo "  [OK] Launcher $pkg"; else echo "  [MANCA] Launcher $pkg"; fi
 done
 echo '  [INFO] Google Docs Offline non supportato ufficialmente su Firefox.'
 echo '  [INFO] Font Microsoft proprietari non installati; disponibili sostituti compatibili.'
 echo '  [DA FARE] Login Tuta e Proton VPN; controllare VPN senza interrompere la rete.'
}
base_apps(){
 say 'Ebook / LibreOffice / Password manager'
 install_repo calibre libreoffice-fresh libreoffice-fresh-it bitwarden
 lean_office_fonts
 remove_onlyoffice
 lean_libreoffice_gtk3
}
fix_claude_path(){
 say 'Claude Code: verifica conflitti npm / pacman'
 local native='/usr/bin/claude' stale="$HOME/.local/npm/node_modules/.bin/claude"
 if ! has_pkg claude-code || [[ ! -x "$native" ]]; then
   warn 'Claude Code pacman non presente o binario mancante: non rimuovo nulla.'
   return 0
 fi
 if ! "$native" --version; then
   warn 'Il binario pacman non funziona: non rimuovo la versione npm; verifica manualmente.'
   return 0
 fi
 if [[ -L "$stale" ]]; then
   echo "Collegamento npm trovato: $stale -> $(readlink "$stale")"
   # Cancella soltanto un symlink sotto il prefisso npm utente, mai una directory o un binario reale.
   rm -- "$stale"
   echo '[OK] Rimosso collegamento npm in conflitto; pacchetto pacman intatto.'
 elif [[ -e "$stale" ]]; then
   warn "Percorso npm presente ma non e un symlink: $stale. Non rimuovo automaticamente."
 else
   echo '[OK] Nessun symlink npm in conflitto.'
 fi
 hash -r || true
 echo 'Binario pacman:'
 "$native" --version
 echo 'Percorsi disponibili:'
 type -a claude || true
}

# Codex CLI: prima pacman, poi yay, infine pacchetto npm ufficiale.
# Installazione nel prefisso utente, mai npm globale di sistema.
install_codex_cli(){
 if command -v codex >/dev/null 2>&1 && codex --version >/dev/null 2>&1; then
   report_ok "Codex CLI già funzionante: $(codex --version)"
   return 0
 fi
 if has_pkg codex; then
   if command -v codex >/dev/null 2>&1 && codex --version >/dev/null 2>&1; then
     report_ok 'Codex CLI già presente tramite pacman'
     return 0
   fi
 fi
 if has_repo codex; then
   install_repo codex
   if command -v codex >/dev/null 2>&1 && codex --version >/dev/null 2>&1; then return 0; fi
 fi
 if command -v yay >/dev/null 2>&1 && yay -Si codex >/dev/null 2>&1; then
   if yay -S --needed --noconfirm codex && command -v codex >/dev/null 2>&1 && codex --version >/dev/null 2>&1; then
     report_ok 'Codex CLI installato con yay'
     return 0
   fi
 fi
 if ! command -v npm >/dev/null 2>&1; then
   report_fail 'Codex CLI: npm non disponibile per installazione ufficiale'
   return 0
 fi
 local prefix="$HOME/.local/npm" bin="$HOME/.local/bin" installed
 mkdir -p "$prefix" "$bin"
 echo '[CODEX] Installazione ufficiale npm nel profilo utente: @openai/codex'
 if npm install --prefix "$prefix" --no-audit --no-fund @openai/codex; then
   installed="$prefix/node_modules/.bin/codex"
   if [[ -x "$installed" ]]; then
     if [[ ! -e "$bin/codex" && ! -L "$bin/codex" ]]; then
       ln -s "$installed" "$bin/codex"
     elif [[ -L "$bin/codex" && "$(readlink "$bin/codex")" == "$installed" ]]; then
       :
     else
       report_warn "Codex installato, ma $bin/codex esiste già: non lo sovrascrivo"
     fi
     if "$installed" --version; then
       report_ok 'Codex CLI installato e verificato tramite npm ufficiale (utente)'
       echo 'Per nuovi terminali, assicurati che ~/.local/bin sia nel PATH.'
       echo 'Per autenticarti: codex login (oppure avvia codex e segui le istruzioni).'
       return 0
     fi
   fi
 fi
 report_fail 'Codex CLI: installazione ufficiale npm non riuscita o binario non funzionante'
 return 0
}
ai_tools(){
 say 'AI CLI e sviluppo (pacman -> yay)'
 install_repo git github-cli python python-pipx nodejs npm base-devel
 install_fallback visual-studio-code-bin visual-studio-code-bin
 echo 'VS Code: installa le estensioni ufficiali Anthropic Claude Code e OpenAI Codex dal marketplace interno.'
 install_codex_cli
 install_fallback claude-code claude-code
 fix_claude_path
 install_fallback gemini-cli gemini-cli
 echo 'Non installo npm -g, curl|bash o installer terzi. Login/API key da configurare separatamente.'
}
lean_ai_icons(){
 local dir="$HOME/.local/share/icons/endeavouros-lean"
 mkdir -p "$dir"
 # Icone SVG locali: sempre disponibili, senza download o dipendenze aggiuntive.
 cat > "$dir/chatgpt.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#0d8b78"/><g fill="none" stroke="#fff" stroke-width="3.8" stroke-linejoin="round" stroke-linecap="round"><path d="M31 10c-9-3-18 4-17 13-8 6-7 18 2 22 1 10 12 15 20 10 9 3 18-4 17-13 8-6 7-18-2-22-1-10-12-15-20-10Z"/><path d="m19 22 13-7 12 7v15L31 49 18 42V28l14-8M19 42l13-8 13 8M32 15v15l-14 9M44 22 31 30l14 8"/></g></svg>
SVG
 cat > "$dir/claude.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#f3e8dc"/><g stroke="#bd6e4c" stroke-width="5" stroke-linecap="round"><path d="M32 9v46M9 32h46M16 16l32 32M48 16 16 48M13 24l38 16M24 13l16 38M51 24 13 40M40 13 24 51"/></g><circle cx="32" cy="32" r="5" fill="#bd6e4c"/></svg>
SVG
 cat > "$dir/gemini.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#1c78eb"/><stop offset=".55" stop-color="#8b5cf6"/><stop offset="1" stop-color="#e06db5"/></linearGradient></defs><rect width="64" height="64" rx="14" fill="#fff"/><path d="M32 7c3 15 10 22 25 25-15 3-22 10-25 25-3-15-10-22-25-25C22 29 29 22 32 7Z" fill="url(#g)"/></svg>
SVG
 cat > "$dir/perplexity.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#102c34"/><g fill="none" stroke="#48c7c4" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"><path d="M17 19h30v28H17zM17 19l15-10 15 10M17 19l15 17 15-17M32 9v46M17 47l15-11 15 11M10 29h7m30 0h7"/></g></svg>
SVG
 cat > "$dir/grok.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#141414"/><g fill="none" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"><path d="M46 15 18 43M18 20h20v20H18z"/><path d="M38 40 49 51"/></g></svg>
SVG
 echo "[OK] Icone AI create in $dir"
}

lean_firefox_replace_brave(){
 say 'Browser predefinito LEAN: Firefox; disinstallazione Brave solo se sicura'
 install_repo firefox firefox-i18n-it firefox-ublock-origin
 if ! command -v firefox >/dev/null 2>&1; then
   warn 'Firefox non disponibile: Brave viene mantenuto per sicurezza.'
   report_warn 'Browser: Firefox assente; Brave mantenuto'
   return 0
 fi
 if command -v xdg-settings >/dev/null 2>&1; then
   xdg-settings set default-web-browser firefox.desktop 2>/dev/null || warn 'Browser predefinito: configurazione manuale necessaria'
 fi
 if command -v kwriteconfig6 >/dev/null 2>&1; then
   : # Non forzare impostazioni globali Plasma oltre allo standard xdg.
 fi
 local pkg req
 for pkg in brave-bin brave brave-browser brave-beta-bin brave-nightly-bin; do
   if ! pacman -Qq "$pkg" >/dev/null 2>&1; then continue; fi
   req=$(LC_ALL=C pacman -Qi "$pkg" 2>/dev/null | sed -n '/^Required By *:/s/^[^:]*: *//p')
   if [[ -z "$req" ]]; then
     warn "Impossibile verificare le dipendenze inverse di $pkg: mantengo il pacchetto."
     report_warn "Brave $pkg: dipendenze non verificabili"
   elif [[ "$req" != 'None' ]]; then
     warn "Brave $pkg richiesto da: $req; non disinstallo."
     report_skip "Brave $pkg: necessario per altri pacchetti ($req)"
   else
     say "Brave $pkg non è richiesto da altri pacchetti: rimozione senza -Rns (nessuna pulizia ricorsiva)."
     if sudo -n pacman -R --noconfirm "$pkg"; then
       report_ok "Brave $pkg rimosso; profili personali conservati"
     else
       warn "Rimozione $pkg non riuscita: nessuna forzatura."
       report_warn "Brave $pkg: rimozione non riuscita"
     fi
   fi
 done
 if command -v flatpak >/dev/null 2>&1 && flatpak info com.brave.Browser >/dev/null 2>&1; then
   warn 'Brave Flatpak presente: non lo rimuovo automaticamente (richiede gestione separata).'
   report_warn 'Brave Flatpak: rimozione manuale eventuale'
 fi
 report_ok 'Firefox: browser scelto per i launcher LEAN'
}

ai_desktop(){
 say 'AI desktop: browser disponibile (Chromium > Firefox (Brave escluso))'
 local exe
 exe=$(lean_shortcut_browser || true)
 if [[ -z "$exe" ]]; then warn 'Nessun browser disponibile: launcher AI non creati.'; return 0; fi
 lean_ai_icons
 local appdir="$HOME/.local/share/applications"
 local icondir="$HOME/.local/share/icons/endeavouros-lean"
 mkdir -p "$appdir"
 local key title url file cmd
 while IFS='|' read -r key title url; do
   [[ -n "$key" ]] || continue
   file="$appdir/ai-${key}-ai.desktop"
   # Protegge launcher personalizzati; aggiorna solo quelli precedentemente creati dallo script.
   if [[ -f "$file" ]] && ! grep -q '^X-EndeavourOS-LEAN-Managed=true$' "$file" && ! grep -Eq -- "^Exec=(brave|brave-browser|chromium|chromium-browser|firefox) (\-\-app=|\-\-new-window )$url$" "$file"; then
     warn "Launcher personalizzato: $file (non modificato)"
     continue
   fi
   cmd=$(lean_shortcut_exec "$exe" "$url")
   cat > "$file" <<EOF
[Desktop Entry]
Type=Application
Name=$title
Exec=$cmd
Icon=$icondir/$key.svg
Terminal=false
Categories=Development;Network;
StartupNotify=true
X-EndeavourOS-LEAN-Managed=true
EOF
   echo "[OK] $title con icona -> $file"
 done <<'AI_APPS'
chatgpt|ChatGPT|https://chatgpt.com
claude|Claude|https://claude.ai
gemini|Gemini|https://gemini.google.com
perplexity|Perplexity|https://www.perplexity.ai
grok|Grok|https://grok.com
AI_APPS
 if command -v kbuildsycoca6 >/dev/null 2>&1; then kbuildsycoca6 >/dev/null 2>&1 || true; fi
}

lean_social_ferdium(){
 say 'Social media e messaggistica: Ferdium (KDE)'
 # Ferdium riunisce i servizi; nessuna credenziale viene richiesta dallo script.
 if has_pkg ferdium || has_pkg ferdium-bin || command -v ferdium >/dev/null 2>&1; then
   report_ok 'Ferdium: già installato'
 elif has_repo ferdium; then
   install_repo ferdium
 else
   # AUR solo se disponibile; il normale helper LEAN informa sulla verifica PKGBUILD.
   install_fallback ferdium-bin ferdium-bin
 fi
 if ! command -v ferdium >/dev/null 2>&1; then
   warn 'Ferdium non disponibile: nessun collegamento creato.'
   report_skip 'Ferdium: installazione non verificata; configurazione servizi rinviata'
   return 0
 fi
 # Ferdium installa già il proprio launcher .desktop: non generarne un secondo.
 # Rimuovere soltanto il duplicato creato da vecchie versioni LEAN.
 local legacy="$HOME/.local/share/applications/endeavouros-lean-ferdium.desktop"
 if [[ -f "$legacy" && ! -L "$legacy" ]] &&
    grep -Eq '^Exec=ferdium([[:space:]]|$)' "$legacy"; then
   rm -- "$legacy"
 fi
 echo 'Apri Ferdium dal menu KDE, quindi aggiungi i servizi desiderati (es. WhatsApp, Telegram, Discord).'
 echo 'L''accesso ai servizi avviene dentro Ferdium; lo script non memorizza credenziali.'
 report_skip 'Ferdium: aggiunta account social da completare manualmente'
}

dropbox_kde(){
 say 'Dropbox in KDE Plasma / Dolphin'
 install_fallback dropbox dropbox
 if ! has_pkg dropbox; then
   warn 'Dropbox non installato: integrazione Dolphin sospesa.'
   report_skip 'Dropbox KDE: installare il client Dropbox e riprovare'
   return 0
 fi
 # Integrazione nativa con Dolphin, se disponibile nei repository configurati.
 # Non sostituire il plugin Dropbox con pacchetti Dolphin generici.
 if has_pkg dolphin-dropbox; then
   report_ok 'Dropbox Dolphin: integrazione già installata'
 elif has_repo dolphin-dropbox; then
   install_repo dolphin-dropbox
 elif command -v yay >/dev/null && yay -Si dolphin-dropbox >/dev/null 2>&1; then
   echo 'Plugin Dolphin Dropbox disponibile in AUR.'
   if ask 'Installare il plugin Dolphin Dropbox da AUR? (verifica il PKGBUILD)'; then
     if yay -S --needed dolphin-dropbox && has_pkg dolphin-dropbox; then
       report_ok 'Installato plugin Dolphin Dropbox'
     else
       report_fail 'Installazione plugin Dolphin Dropbox non riuscita'
     fi
   else
     report_skip 'Plugin Dolphin Dropbox non installato su scelta utente'
   fi
 else
   warn 'Plugin dolphin-dropbox non disponibile nei repository configurati.'
   report_skip 'Dolphin Dropbox: plugin non disponibile; client Dropbox comunque utilizzabile'
 fi
 echo 'Avvia Dropbox dal menu KDE, accedi al tuo account e attendi la sincronizzazione.'
 echo 'Apri ~/Dropbox in Dolphin; se il plugin è installato, riavvia Dolphin per i menu contestuali.'
 echo 'Non vengono create cartelle Dropbox manualmente, né vengono richieste credenziali.'
 report_skip 'Dropbox: accesso account e sincronizzazione iniziale da completare manualmente'
}
cloud(){ say 'Cloud integrato KDE'; install_repo kio-gdrive kaccounts-integration kaccounts-providers; echo 'Google Drive: Dolphin > Rete > Google Drive, oppure gdrive:/';
 dropbox_kde
 install_fallback megasync megasync
 install_fallback pcloud-drive pcloud-drive
}
iphone(){ say 'iPhone 16 Pro / KDE'; install_repo kdeconnect libimobiledevice usbmuxd libplist libusbmuxd gphoto2 usbutils; install_fallback ifuse ifuse; echo 'USB: sblocca iPhone e conferma Autorizza. KDE Connect usa rete LAN/Wi-Fi, non USB diretto.'; }
lean_firefox_privacy_harden(){
 say 'Firefox privacy LEAN: protezioni avanzate, uBlock Origin e impostazioni reversibili'
 install_repo firefox firefox-i18n-it firefox-ublock-origin
 if ! command -v firefox >/dev/null 2>&1; then
   report_warn 'Firefox privacy: Firefox non disponibile'; return 0
 fi
 if ! command -v python3 >/dev/null 2>&1; then
   report_warn 'Firefox privacy: Python3 mancante, configurazione policy rinviata'; return 0
 fi
 local dir='/etc/firefox/policies' target='/etc/firefox/policies/policies.json'
 local tmp; tmp=$(mktemp) || return 0
 # Merge conservativo: mantiene policy preesistenti; nessun profilo personale modificato.
 if ! python3 - "$target" "$tmp" <<'PYPRIV'
import json, os, sys
source, target = sys.argv[1:]
obj = {"policies": {}}
if os.path.exists(source):
    try:
        with open(source, encoding="utf-8") as f: obj = json.load(f)
        if not isinstance(obj, dict) or not isinstance(obj.get('policies', {}), dict):
            raise ValueError('invalid policies')
    except Exception as exc:
        print('Existing Firefox policies invalid; refusing overwrite:', exc)
        sys.exit(2)
pol = obj.setdefault('policies', {})
# ExtensionSettings: normal_installed installs but allows disabling/removal.
# Do not force-install many redundant anti-tracker extensions: increases attack surface.
ext = pol.setdefault('ExtensionSettings', {})
if not isinstance(ext, dict): sys.exit('Existing ExtensionSettings invalid')
ext.setdefault('uBlock0@raymondhill.net', {
    'installation_mode': 'normal_installed',
    'install_url': 'https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi'
})
# Set default prefs rather than lock; existing user choices stay editable.
prefs = pol.setdefault('Preferences', {})
if not isinstance(prefs, dict): sys.exit('Existing Preferences invalid')
values = {
 'browser.contentblocking.category': 'strict',
 'privacy.globalprivacycontrol.enabled': True,
 'dom.security.https_only_mode': True,
 'network.cookie.cookieBehavior': 5,
 'privacy.query_stripping.enabled': True,
 'privacy.query_stripping.enabled.pbmode': True,
 'media.peerconnection.ice.default_address_only': True,
 'browser.send_pings': False,
 'beacon.enabled': False,
 'datareporting.healthreport.uploadEnabled': False,
 'toolkit.telemetry.enabled': False,
 'browser.newtabpage.activity-stream.feeds.telemetry': False,
 'browser.newtabpage.activity-stream.telemetry': False,
 'browser.urlbar.suggest.quicksuggest.sponsored': False,
}
for key, value in values.items():
    prefs.setdefault(key, {'Value': value, 'Status': 'default'})
with open(target, 'w', encoding='utf-8') as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
    f.write('\n')
PYPRIV
 then
   rm -f "$tmp"; report_warn 'Firefox privacy: impossibile creare policy; file originale preservato'; return 0
 fi
 if [[ -e "$target" ]] && cmp -s "$tmp" "$target"; then
   rm -f "$tmp"; report_ok 'Firefox privacy: policy già aggiornate'; return 0
 fi
 if [[ -e "$target" ]]; then
   local backup="${target}.lean-backup-$(date +%Y%m%d-%H%M%S)"
   if ! sudo -n cp -p "$target" "$backup"; then
     rm -f "$tmp"; report_warn 'Firefox privacy: backup policy fallito; nessuna modifica'; return 0
   fi
   report_ok "Firefox privacy: backup precedente $backup"
 fi
 if sudo -n install -d -m 0755 "$dir" && sudo -n install -m 0644 "$tmp" "$target"; then
   report_ok 'Firefox privacy: Strict ETP, HTTPS-only, GPC, anti-tracking URL, uBlock Origin predisposti'
   report_warn 'Firefox privacy: riavviare Firefox; controllare about:policies e about:addons; siti incompatibili possibili'
 else
   report_warn 'Firefox privacy: scrittura policy non riuscita'
 fi
 rm -f "$tmp"
}
privacy(){ lean_firefox_privacy_harden; }


ledger_setup(){
 say 'Ledger Nano X — Ledger Wallet (ex Ledger Live)'
 echo 'Cerco il client Ledger Wallet/Live per Linux: prima pacman, poi AUR.'
 echo 'Non installo il pacchetto "ledger": e un software di contabilita, NON il wallet hardware.'
 local pkg=''
 for candidate in ledger-live-bin ledger-live; do
   if has_repo "$candidate"; then pkg="$candidate"; install_repo "$candidate"; break; fi
 done
 if [[ -z "$pkg" ]]; then
   if need_yay; then
     for candidate in ledger-live-bin ledger-live; do
       if yay -Si "$candidate" >/dev/null 2>&1; then
         pkg="$candidate"
         echo "[AUR] $pkg — verifica sempre la provenienza del PKGBUILD per un wallet crypto."
         yay -S --needed --noconfirm "$pkg"
         break
       fi
     done
   fi
 fi
 if [[ -z "$pkg" ]]; then
   warn 'Client Ledger non trovato nei repository/AUR: nessun download automatico da siti non verificati.'
   echo 'Download ufficiale Linux: https://shop.ledger.com/pages/ledger-wallet-download'
 fi
 # Le regole udev permettono accesso USB al dispositivo senza root.
 # Non scrivere regole custom generiche, potenzialmente insicure.
 local rule=''
 for candidate in ledger-udev ledger-udev-rules; do
   if has_repo "$candidate"; then rule="$candidate"; install_repo "$candidate"; break; fi
 done
 if [[ -z "$rule" ]] && need_yay; then
   for candidate in ledger-udev ledger-udev-rules; do
     if yay -Si "$candidate" >/dev/null 2>&1; then
       rule="$candidate"; yay -S --needed --noconfirm "$candidate"; break
     fi
   done
 fi
 if [[ -z "$rule" ]]; then
   warn 'Regole udev Ledger dedicate non trovate: non creo permessi USB globali o regole improvvisate.'
 else
   sudo -n udevadm control --reload-rules
   sudo -n udevadm trigger --subsystem-match=usb || true
 fi
 echo 'Nano X: collega con cavo USB dati, sblocca il dispositivo e apri Ledger Wallet.'
 echo 'Bluetooth Nano X: su Linux desktop preferisci USB; il supporto Bluetooth non e garantito.'
 echo 'Mai digitare le 24 parole di recupero sul computer, in un sito o in una finestra di app.'
 echo 'Controlla indirizzi e transazioni sul display fisico del Nano X.'
}

proton_vpn_setup(){
 say 'Proton VPN — GUI desktop + CLI (repository Arch extra)'
 if ! pacman -Qq networkmanager >/dev/null 2>&1; then
   warn 'NetworkManager non risulta installato: Proton VPN richiede NetworkManager. Non modifico la rete automaticamente.'
   return
 fi
 if ! systemctl is-active --quiet NetworkManager.service; then
   warn 'NetworkManager non risulta attivo: installazione sospesa per non alterare la connessione esistente.'
   return
 fi
 install_repo proton-vpn-gtk-app proton-vpn-cli
 echo 'Proton VPN richiede un keyring: gnome-keyring e supportato; KWallet potrebbe funzionare ma non e ufficialmente supportato.'
 echo 'Non cambio gestore credenziali, DNS, routing, kill switch o servizi di rete.'
 echo 'Avvia Proton VPN dal menu KDE ed effettua login. CLI disponibile se installata.'
 echo 'Split tunneling GUI: richiede systemd-resolved, che NON abilito automaticamente.'
}

firefox_macos_theme(){
 say 'Firefox macOS-like — Cupertino (Mozilla Add-ons)'
 install_repo firefox
 echo 'Tema scelto: Cupertino, open source, aspetto macOS, modalita chiara e scura.'
 echo 'La conferma di installazione del tema deve essere data in Firefox: non modifico profili, prefs.js o policy del browser.'
 echo 'Pagina ufficiale: https://addons.mozilla.org/en-US/firefox/addon/cupertino-theme/'
 if command -v firefox >/dev/null 2>&1; then
   firefox 'https://addons.mozilla.org/en-US/firefox/addon/cupertino-theme/' >/dev/null 2>&1 &
 elif command -v xdg-open >/dev/null 2>&1; then
   xdg-open 'https://addons.mozilla.org/en-US/firefox/addon/cupertino-theme/' >/dev/null 2>&1 &
 fi
 echo 'Premi "Installa tema" nella pagina Mozilla, poi conferma in Firefox.'
}

maintenance_audit(){
 say 'Audit LEAN: pacchetti, orfani, cache e installazioni esterne (sola lettura)'
 echo 'Pacchetti espliciti:'; pacman -Qqe | wc -l
 echo 'Pacchetti totali:'; pacman -Qq | wc -l
 echo 'Orfani (dipendenze non richieste):'; pacman -Qdt || true
 echo 'Pacchetti esterni ai repository sincronizzati (inclusi AUR):'; pacman -Qm || true
 echo 'Integrita dipendenze pacman:'; sudo -n pacman -Dk || true
 echo 'Dimensione cache pacman:'; du -sh /var/cache/pacman/pkg 2>/dev/null || true
 echo 'Flatpak (solo rilevamento):'; if command -v flatpak >/dev/null; then flatpak list --app --columns=application 2>/dev/null || true; else echo 'assente'; fi
 echo 'Snap (solo rilevamento):'; if command -v snap >/dev/null; then snap list 2>/dev/null || true; else echo 'assente'; fi
 echo 'Directory grandi in home (primi 10 elementi):'; du -sh "$HOME"/{Downloads,.cache,Sviluppo} 2>/dev/null || true
 echo 'ATTENZIONE: pacman -Qm NON indica pacchetti inutili; include i pacchetti AUR desiderati.'
 echo 'ATTENZIONE: non esiste un modo affidabile per riconoscere software in disuso senza revisione manuale.'
}

clean_orphans(){
 say 'Pulizia prudente delle dipendenze orfane'
 local orphans=() safe=() protected=() pkg
 mapfile -t orphans < <(pacman -Qdtq 2>/dev/null || true)
 if (( ${#orphans[@]} == 0 )); then echo 'Nessun pacchetto orfano.'; return 0; fi
 for pkg in "${orphans[@]}"; do
   # Questi pacchetti possono essere necessari per kernel, driver e hardware anche senza dipendenze formali.
   if [[ "$pkg" =~ ^(linux.*|.*-headers|dkms|.*firmware.*|nvidia.*|lib32-nvidia.*|openrazer.*|.*-dkms|bluez.*|usbmuxd|libimobiledevice|steam-devices)$ ]]; then
     protected+=("$pkg")
   else
     safe+=("$pkg")
   fi
 done
 if (( ${#protected[@]} )); then
   warn 'Candidati protetti (NON rimossi automaticamente):'
   printf '  %s\n' "${protected[@]}"
 fi
 if (( ${#safe[@]} == 0 )); then echo 'Nessun candidato sicuro da proporre.'; return 0; fi
 echo 'Candidati da esaminare:'
 for pkg in "${safe[@]}"; do
   pacman -Qi "$pkg" | grep -E '^(Name|Description|Install Reason|Required By|Optional For)' || true
   echo
 done
 warn 'Pacman non puo sapere se usi un programma direttamente o fuori dal gestore pacchetti.'
 if ! sudo -n pacman -Dk; then warn 'Integrita dipendenze non valida: pulizia annullata.'; return 1; fi
 echo 'Controllo transazione: pacman mostrera eventuali dipendenze aggiuntive prima di chiedere conferma.'
 if ask_explicit 'Rimuovere SOLO i candidati elencati? pacman verifichera le dipendenze'; then
   sudo -n pacman -Rns "${safe[@]}"
 else echo 'Rimozione annullata.'; fi
}

clean_package_cache(){
 say 'Cache pacman: conserviamo le ultime 2 versioni per consentire rollback'
 if ! command -v paccache >/dev/null; then
   echo 'paccache non presente. pacman-contrib e disponibile tramite pacman.'
   if ask 'Installare pacman-contrib per gestire la cache?'; then install_repo pacman-contrib; else return 0; fi
 fi
 echo 'Dimensione attuale:'; du -sh /var/cache/pacman/pkg 2>/dev/null || true
 if ask_explicit 'Rimuovere le vecchie versioni mantenendo le ultime 2 per pacchetto?'; then
   sudo -n paccache -r -k 2
 fi
 echo 'Dimensione dopo la pulizia:'; du -sh /var/cache/pacman/pkg 2>/dev/null || true
}

maintenance(){
 maintenance_audit
 clean_orphans
 clean_package_cache
 echo 'Non elimino automaticamente Flatpak, Snap, pacchetti AUR, cache personali, log, dati Docker o modelli Ollama.'
 echo 'Se pacman -Dk segnala problemi, interrompi la pulizia e verifica manualmente.'
}


macos_opensource_fonts(){
 say 'Font macOS-like: solo font open source, senza font Apple'
 # Inter: estetica moderna simile al font di sistema Apple; JetBrains Mono per codice.
 # Noto Sans e Liberation garantiscono fallback e compatibilita documentale.
 local sans='' mono=''
 if has_repo inter-font; then install_repo inter-font
 elif has_repo ttf-inter; then install_repo ttf-inter
 else warn 'Inter non trovato nei repository ufficiali: non forzo pacchetti AUR non verificati.'; fi
 install_repo noto-fonts ttf-liberation ttf-jetbrains-mono fontconfig
 if ! command -v fc-list >/dev/null; then warn 'fontconfig non disponibile; salto configurazione.'; return 0; fi
 if fc-list -f '%{family}\n' | grep -Eiq '(^|[, ])Inter([, ]|$)'; then sans='Inter'
 elif fc-list -f '%{family}\n' | grep -Eiq 'Noto Sans'; then sans='Noto Sans'
 else warn 'Nessun font sans previsto rilevato; lascio invariato KDE.'; return 0; fi
 if fc-list -f '%{family}\n' | grep -Eiq 'JetBrains Mono'; then mono='JetBrains Mono'
 else mono='monospace'; fi
 echo "Font proposti: interfaccia $sans (10 pt), codice $mono (10 pt)."
 if ! command -v kwriteconfig6 >/dev/null; then
   warn 'kwriteconfig6 non disponibile: font installati ma impostazioni KDE invariate.'; return 0
 fi
 local config="$HOME/.config/kdeglobals" backup
 mkdir -p "$HOME/.config"
 if [[ -f "$config" ]]; then
   backup="$config.lean-backup-$(date +%Y%m%d-%H%M%S)"
   cp -p -- "$config" "$backup"
   echo "Backup configurazione KDE: $backup"
 fi
 # Cambiamo solo le chiavi dei font utente, non tema, compositor, display o driver.
 kwriteconfig6 --file kdeglobals --group General --key font "$sans,10,-1,5,50,0,0,0,0,0"
 kwriteconfig6 --file kdeglobals --group General --key menuFont "$sans,10,-1,5,50,0,0,0,0,0"
 kwriteconfig6 --file kdeglobals --group General --key toolBarFont "$sans,10,-1,5,50,0,0,0,0,0"
 kwriteconfig6 --file kdeglobals --group General --key smallestReadableFont "$sans,9,-1,5,50,0,0,0,0,0"
 kwriteconfig6 --file kdeglobals --group General --key fixed "$mono,10,-1,5,50,0,0,0,0,0"
 echo 'Font KDE aggiornati; alcune applicazioni richiedono chiusura e riapertura o nuova sessione.'
 echo 'Font LibreOffice e Firefox sono gestiti anche dalle rispettive impostazioni applicative.'
}


macos_window_buttons(){
 say 'Pulsanti finestra a sinistra in stile macOS (KWin / Plasma 6)'
 if ! command -v kwriteconfig6 >/dev/null 2>&1; then
   warn 'kwriteconfig6 non trovato: nessuna modifica alle decorazioni.'; return 0
 fi
 if [[ -z "${XDG_CURRENT_DESKTOP:-}" || "${XDG_CURRENT_DESKTOP,,}" != *kde* ]]; then
   warn 'Sessione KDE non rilevata: non cambio i pulsanti finestra.'; return 0
 fi
 local config="$HOME/.config/kwinrc" backup
 mkdir -p "$HOME/.config"
 if [[ -f "$config" ]]; then
   backup="$config.lean-backup-$(date +%Y%m%d-%H%M%S)"
   cp -p -- "$config" "$backup"
   echo "Backup KWin: $backup"
 fi
 # Codici KWin: X=chiudi, I=minimizza, A=massimizza.
 # Disposizione macOS: chiudi, minimizza, massimizza a sinistra.
 kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key ButtonsOnLeft 'XIA'
 kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key ButtonsOnRight ''
 echo 'Pulsanti KWin impostati a sinistra (XIA).'
 echo 'Per applicare: chiudi e riapri le finestre; se necessario esci e rientra nella sessione KDE.'
 echo 'Non riavvio KWin o Plasma per evitare interruzioni della sessione Wayland.'
 echo 'Rollback: Impostazioni di sistema > Colori e temi > Decorazioni finestre > Pulsanti della barra del titolo.'
}

macos_desktop_look(){
 macos_opensource_fonts
 macos_window_buttons
}


docker_setup(){
 say 'Docker Engine + Compose + GitHub CLI'
 install_repo docker docker-compose docker-buildx github-cli git
 if ! has_pkg docker; then warn 'Docker non installato: servizio non modificato.'; return; fi
 # Installare Docker non significa avviare automaticamente un demone privilegiato.
 echo 'Docker installato; il servizio si attiva nella sezione Ollama/Open WebUI quando richiesto.'
 echo 'Per abilitarlo successivamente: sudo systemctl enable --now docker.service'
 echo 'Per evitare sudo su docker: aggiunta al gruppo docker opzionale, MA equivale a privilegi root.'
 echo 'Alternativa sicura: sudo docker ... (nessuna modifica gruppi).'
 echo 'GitHub: gh auth login (autenticazione manuale).'
}

defi_setup(){
 say 'DeFi: wallet browser e sicurezza Ledger Nano X'
 install_repo firefox firefox-ublock-origin
 echo 'Nessuna estensione wallet viene installata automaticamente: richiede verifica publisher e autorizzazioni browser.'
 echo 'MetaMask ufficiale: https://metamask.io/download/'
 echo 'Rabby ufficiale: https://rabby.io/'
 echo 'Ledger: collega Nano X tramite USB e verifica ogni firma sul display hardware.'
 echo 'Usa un profilo browser separato per DeFi; evita di inserire seed phrase su PC o browser.'
 echo 'Non abilito accesso automatico a wallet, dApp o trading.'
}

pdf_ocr_setup(){
 say 'PDF avanzati / scansioni / OCR (pacman)'
 install_repo okular pdfarranger poppler ghostscript sane simple-scan tesseract tesseract-data-eng tesseract-data-ita ocrmypdf
 echo 'OCR PDF ricercabile: ocrmypdf -l ita+eng input.pdf output_ocr.pdf'
 echo 'Scanner: apri Document Scanner (simple-scan); compatibilita hardware da verificare.'
 echo 'OCRmyPDF non deve sovrascrivere l’originale: usa file di output distinto.'
}
# Inventario non distruttivo: verifiche PRIMA delle nuove installazioni.
preflight(){
 say 'PRECHECK: sistema, repository, storage, servizi, rete, dispositivi'
 echo "Host: $(hostname) | Kernel: $(uname -r)"
 echo 'Spazio libero HOME:'; df -h "$HOME" | tail -1
 echo 'Filesystem /:'; findmnt -no FSTYPE,SOURCE,OPTIONS / || true
 echo 'Repository e pacchetti richiesti (sola lettura):'
 for p in digikam darktable kdenlive ollama ollama-cuda kdeconnect libimobiledevice usbmuxd kio-gdrive restic; do
   if has_pkg "$p"; then echo "[INSTALLATO] $p"; elif has_repo "$p"; then echo "[PACMAN] $p"; else echo "[NON DISPONIBILE] $p"; fi
 done
 echo 'Pacchetti chiave:'
 pacman -Q nvidia-utils nvidia-open openrazer-driver-dkms steam claude-code docker ollama ollama-cuda kdeconnect libimobiledevice 2>/dev/null || true
 echo 'GPU:'; lspci -nn | grep -Ei 'vga|3d|display' || true
 echo 'Driver NVIDIA (sola lettura):'; command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader || true
 echo 'NetworkManager / Firewall:'
 systemctl is-active NetworkManager.service 2>/dev/null || true
 for svc in firewalld.service ufw.service docker.service ollama.service bluetooth.service; do printf '%s: ' "$svc"; systemctl is-active "$svc" 2>/dev/null || true; done
 echo 'KDE Connect:'; command -v kdeconnect-cli >/dev/null && kdeconnect-cli --list-devices || true
 echo 'USB iPhone (solo se collegato):'; command -v lsusb >/dev/null && lsusb | grep -Ei 'apple|iphone|ipad' || true
 echo 'Flatpak/Snap presenti (nessuna rimozione):'
 command -v flatpak >/dev/null && flatpak list --app --columns=application 2>/dev/null || true
 command -v snap >/dev/null && snap list 2>/dev/null || true
 echo 'Pacchetti orfani:'; pacman -Qdtq 2>/dev/null || true
 echo 'Nota: lo script non può sapere se un software esterno è ancora utilizzato: ogni rimozione richiede conferma.'
}

photo_video(){
 say 'Fotografia iPhone: digiKam + darktable / montaggio Kdenlive'
 install_repo digikam darktable kdenlive perl-image-exiftool libheif libraw ffmpeg
 echo 'ProRAW/DNG: verifica un file campione. digiKam cataloga, darktable sviluppa RAW; conserva gli originali.'
 echo 'Importazione iPhone: gphoto2/digiKam; in caso di limiti iOS usa esportazione via Foto/Files o KDE Connect Wi-Fi.'
 echo 'Kdenlive: nessuna modifica automatica all’accelerazione NVIDIA o ai profili video.'
}

# Icone SVG locali, indipendenti da download e da Flatpak/Snap.
lean_google_icons(){
 local dir="$HOME/.local/share/icons/endeavouros-lean"
 mkdir -p "$dir"
 cat > "$dir/gmail.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect x="6" y="11" width="52" height="42" rx="8" fill="#fff"/><path d="M8 19 32 37 56 19" fill="none" stroke="#ea4335" stroke-width="9" stroke-linecap="round" stroke-linejoin="round"/><path d="M8 22v27" stroke="#4285f4" stroke-width="9"/><path d="M56 22v27" stroke="#34a853" stroke-width="9"/></svg>
SVG
 cat > "$dir/keep.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect x="8" y="5" width="48" height="54" rx="10" fill="#fbbc04"/><path d="M25 22a10 10 0 1 1 14 9c-3 2-4 4-4 7h-6c0-3-1-5-4-7a10 10 0 0 1 0-9" fill="#fff"/><rect x="28" y="41" width="8" height="4" rx="2" fill="#fff"/></svg>
SVG
 cat > "$dir/calendar.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect x="7" y="9" width="50" height="47" rx="7" fill="#4285f4"/><rect x="12" y="22" width="40" height="29" rx="2" fill="#fff"/><path d="M20 6v12M44 6v12" stroke="#34a853" stroke-width="6" stroke-linecap="round"/><text x="32" y="44" font-size="21" text-anchor="middle" font-family="sans-serif" font-weight="bold" fill="#4285f4">31</text></svg>
SVG
 cat > "$dir/tasks.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect x="5" y="5" width="54" height="54" rx="13" fill="#4285f4"/><path d="m16 20 6 6 9-11M16 40l6 6 9-11" fill="none" stroke="#fff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><path d="M38 24h12M38 44h12" stroke="#fff" stroke-width="4" stroke-linecap="round"/></svg>
SVG
 cat > "$dir/drive.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><path d="M24 8h15l20 35H44z" fill="#ffba00"/><path d="M24 8h15L19 44H4z" fill="#0f9d58"/><path d="M19 44h40l-8 13H11z" fill="#4285f4"/></svg>
SVG
 echo "[OK] Icone Google create in $dir"
}

google_workspace(){
 say 'Google Workspace: Gmail, Keep, Calendar e Tasks — un launcher per servizio'
 local browser appdir="$HOME/.local/share/applications" icondir="$HOME/.local/share/icons/endeavouros-lean"
 browser=$(lean_shortcut_browser || true)
 [[ -n "$browser" ]] || { report_warn 'Google Workspace: browser non disponibile'; return 0; }
 lean_google_icons
 mkdir -p "$appdir"
 local key name url cmd
 while IFS='|' read -r key name url; do
   cmd=$(lean_shortcut_exec "$browser" "$url")
   cat > "$appdir/google-${key}.desktop" <<EOFGOOGLE
[Desktop Entry]
Type=Application
Name=$name
Exec=$cmd
Icon=$icondir/$key.svg
Terminal=false
Categories=Network;
StartupNotify=true
X-EndeavourOS-LEAN-Managed=true
EOFGOOGLE
 done <<'GOOGLE_LINKS'
keep|Google Keep|https://keep.google.com/
gmail|Gmail|https://mail.google.com/
calendar|Google Calendar|https://calendar.google.com/
tasks|Google Tasks|https://tasks.google.com/
GOOGLE_LINKS
}


configure_ollama_service(){
 say 'Configurazione iniziale Ollama: localhost, memoria e concorrenza conservative'
 local dir='/etc/systemd/system/ollama.service.d' file="$dir/10-endeavouros-lean.conf"
 if [[ -e "$file" ]]; then
   warn "Configurazione già presente: $file. Non la sovrascrivo."
 else
   sudo -n install -d -m 755 "$dir"
   local tmp
   tmp="$(mktemp)"
   cat > "$tmp" <<'OVERRIDE'
[Service]
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_CONTEXT_LENGTH=4096"
Environment="OLLAMA_KEEP_ALIVE=5m"
OVERRIDE
   sudo -n install -m 644 "$tmp" "$file"
   rm -f "$tmp"
   echo "Creato $file (override dedicato, reversibile)."
 fi
 sudo -n systemctl daemon-reload
 sudo -n systemctl enable --now ollama.service
 if systemctl is-active --quiet ollama.service; then
   echo '[OK] Ollama attivo e abilitato al boot.'
 else
   warn 'Ollama non attivo; ultimi log:'
   journalctl -u ollama.service -n 20 --no-pager || true
   return 1
 fi
 if command -v curl >/dev/null; then
   curl -fsS --max-time 5 http://127.0.0.1:11434/api/version || warn 'API locale non ancora pronta.'
 fi
 echo
 echo 'API accessibile solo da localhost. Nessun modello scaricato automaticamente.'
 echo 'Test consigliato: ollama run qwen2.5-coder:1.5b (download esplicito).'
 echo 'Per rollback: sudo rm /etc/systemd/system/ollama.service.d/10-endeavouros-lean.conf && sudo systemctl daemon-reload && sudo systemctl restart ollama'
}

prepare_openwebui(){
 say 'Open WebUI: interfaccia grafica locale opzionale con Docker Compose'
 if ! has_pkg docker || ! has_pkg docker-compose; then
   warn 'Docker/Compose assenti; GUI non configurata.'; return 0
 fi
 local dir="$HOME/.config/endeavouros-lean/open-webui" file
 mkdir -p "$dir"
 file="$dir/compose.yaml"
 if [[ -e "$file" ]]; then
   echo "[OK] Configurazione già esistente: $file (non sovrascritta)."
 else
   cat > "$file" <<'COMPOSE'
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    restart: unless-stopped
    network_mode: host
    environment:
      OLLAMA_BASE_URL: http://127.0.0.1:11434
      WEBUI_HOST: 127.0.0.1
      WEBUI_PORT: '3000'
    volumes:
      - open-webui-data:/app/backend/data
volumes:
  open-webui-data:
COMPOSE
   echo "Creato $file (network host per raggiungere Ollama su localhost)."
 fi
 echo 'Open WebUI è un progetto terzo. La prima esecuzione scarica una immagine container e crea dati locali.'
 echo 'Verifica le immagini e le impostazioni di rete prima di avviare.'
 if ask 'Avviare Open WebUI ora (immagine esterna e Docker abilitato al boot)?'; then
   sudo -n systemctl enable --now docker.service
   if ! systemctl is-active --quiet docker.service; then warn 'Docker non avviato'; return 1; fi
   ( cd "$dir" && sudo -n docker compose up -d )
   echo 'Interfaccia prevista: http://127.0.0.1:3000'
   echo 'Verifica ascolto locale: sudo ss -ltnp | grep -E ":(3000|11434) "'
   echo 'Se 3000 è esposta su 0.0.0.0 o IP LAN, ferma subito il container e controlla WEBUI_HOST.'
 else
   echo "Docker non attivato per Open WebUI. Avvio manuale: cd '$dir' && sudo docker compose up -d"
 fi
}

ollama_local(){
 say 'LLM locali: Ollama + CUDA NVIDIA + servizio locale + GUI opzionale'
 if [[ $updated -ne 1 ]]; then warn 'Esegui prima aggiornamento completo (opzione 1). Ollama sospeso per evitare aggiornamenti parziali.'; return 0; fi
 install_repo ollama
 if ! has_pkg ollama; then warn 'Ollama non installato.'; return 0; fi
 detect_hardware
 if (( HAS_NVIDIA_GPU )) && has_pkg nvidia-utils && command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; then
   if has_repo ollama-cuda; then install_repo ollama-cuda; else warn 'ollama-cuda non disponibile: controlla supporto GPU.'; fi
 else warn 'GPU NVIDIA non rilevata: possibile uso CPU.'; fi
 configure_ollama_service
 prepare_openwebui
 echo 'Ollama: un modello alla volta, contesto iniziale 4096, API solo su 127.0.0.1.'
 echo 'Per coding locale, scarica esplicitamente un modello piccolo con: ollama pull qwen2.5-coder:1.5b'
 if (( HAS_NVIDIA_GPU )); then echo 'Verifica GPU: watch -n 1 nvidia-smi'; else echo 'Ollama: CPU; nessun driver CUDA/NVIDIA installato.'; fi
 echo 'Non esporre la porta 11434 e non inserire segreti API nei prompt locali non necessari.'
 echo 'Nessun modello scaricato automaticamente. Non esporre API Ollama su LAN o Internet.'
}

iphone_diagnostics(){
 say 'iPhone: diagnostica USB e KDE Connect separata (senza modifiche al firewall)'
 echo 'USB: collega iPhone sbloccato, premi Autorizza sul telefono. Usa un cavo dati USB-C.'
 if command -v lsusb >/dev/null; then lsusb | grep -Ei 'apple|iphone|ipad' || echo 'iPhone non rilevato da lsusb'; else echo 'Installa usbutils per lsusb'; fi
 echo 'usbmuxd (socket activation/udev):'; systemctl status usbmuxd.service --no-pager -l 2>/dev/null | head -18 || true
 if command -v idevice_id >/dev/null; then idevice_id -l || true; fi
 if command -v idevicepair >/dev/null; then idevicepair validate || true; fi
 echo 'Non eseguo idevicepair pair automaticamente: richiede conferma Trust sul telefono.'
 echo 'KDE Connect usa LAN, NON cavo USB diretto. iPhone e Razer sulla stessa rete, non rete ospiti.'
 if command -v kdeconnect-cli >/dev/null; then kdeconnect-cli --list-devices || true; fi
 echo 'Porte locali KDE Connect (diagnostica):'; if command -v ss >/dev/null; then ss -lntup 2>/dev/null | grep -E '171[4-9]|17[2-5][0-9]|176[0-4]' || true; fi
 echo 'iPhone: stessa LAN (non Wi-Fi ospiti), app KDE Connect aperta, permesso Rete locale abilitato.'
 echo 'Controlla firewall TCP/UDP 1714-1764 SOLO sulla LAN; lo script NON apre porte.'
 echo 'Su iOS notifiche di altre app e background continuo non sono disponibili.'
}

security_audit(){
 say 'Sicurezza / backup / salute hardware: inventario e installazione conservativa'
 local fs
 fs=$(findmnt -no FSTYPE / 2>/dev/null || echo unknown)
 echo "Filesystem root: $fs"
 if [[ $fs == btrfs ]]; then
   echo 'Btrfs rilevato: installo GUI btrfs-assistant e snapper, senza configurare snapshot/rollback.'
   install_repo btrfs-assistant snapper
 else
   echo 'Filesystem non Btrfs: non installo strumenti snapshot Btrfs.'
   echo 'Backup portabile: restic; richiede destinazione e password scelte da te.'
 fi
 install_repo restic smartmontools nvtop inxi lm_sensors
 echo 'Firewall attivo:'
 for svc in firewalld.service ufw.service; do systemctl is-active "$svc" 2>/dev/null || true; done
 echo 'Non installo/abilito un secondo firewall e non cambio regole di rete.'
 echo 'SMART: nessun test distruttivo, nessuna modifica dischi o bootloader.'
 echo 'Non creo snapshot, non tocco bootloader e non eseguo backup senza destinazione confermata.'
}


# Ambiente multiprogetto: non sovrascrive file esistenti e non pubblica repository.
write_if_absent(){
  local dest="$1"; mkdir -p "$(dirname "$dest")"
  if [[ -e "$dest" ]]; then echo "[CONSERVATO] $dest"; return 0; fi
  cat > "$dest"
  echo "[CREATO] $dest"
}
create_development_workspace(){
 say 'Predisposizione workspace generico: NESSUN progetto creato'
 local root="$HOME/Sviluppo" templates="$HOME/.config/endeavouros-lean/templates"
 mkdir -p "$root" "$templates"
 chmod 700 "$root" "$templates" 2>/dev/null || true
 write_if_absent "$root/README.md" <<'EOF'
# Sviluppo — workspace multiprogetto
Crea qui un repository indipendente per ogni progetto QUANDO lo deciderai.
Nessuna cartella trading-platform, ai-agents o altri progetti viene creata dall'installer.
Modelli riutilizzabili: ~/.config/endeavouros-lean/templates
Usa repository GitHub privati per impostazione predefinita.
EOF
 write_if_absent "$templates/.gitignore" <<'EOF'
.env
.env.*
!.env.example
.venv/
node_modules/
__pycache__/
.pytest_cache/
.ruff_cache/
*.pyc
*.sqlite3
*.db
*.pem
*.key
*.seed
*.wallet
*.log
.DS_Store
EOF
 write_if_absent "$templates/.env.example" <<'EOF'
# MODELLO: copiare in .env soltanto dentro un futuro progetto.
# Non inserire chiavi API o seed phrase qui.
APP_ENV=development
TRADING_MODE=paper
ENABLE_LIVE_TRADING=false
DATABASE_URL=
REDIS_URL=
EOF
 write_if_absent "$templates/CLAUDE.md" <<'EOF'
# Istruzioni per agenti di coding (modello)
- Prima analizza, poi presenta un piano di modifica.
- Puoi eseguire test e lint locali senza interagire con servizi di produzione.
- Richiedi approvazione esplicita prima di comandi distruttivi, deploy, push, migrazioni DB, modifiche di sicurezza o segreti.
- Non eseguire trading live, non inviare ordini e non connettere wallet/exchange senza autorizzazione specifica.
- Non leggere, stampare, copiare o caricare segreti e seed phrase.
- I test di trading devono usare dati sintetici o storici e modalità paper.
- Non disabilitare i controlli di approvazione degli strumenti.
EOF
 write_if_absent "$templates/pyproject.toml" <<'EOF'
[project]
name = "replace-me"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = []
[dependency-groups]
dev = ["pytest", "ruff"]
[tool.pytest.ini_options]
testpaths = ["tests"]
EOF
 write_if_absent "$templates/compose.yaml" <<'EOF'
# MODELLO NON AVVIATO: utilizzare in un progetto futuro con credenziali proprie.
# Solo porte locali, senza esposizione sulla LAN.
services:
  postgres:
    image: postgres:17-alpine
    environment:
      POSTGRES_USER: ${POSTGRES_USER:?Set POSTGRES_USER in .env}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD in .env}
      POSTGRES_DB: ${POSTGRES_DB:?Set POSTGRES_DB in .env}
    ports: ["127.0.0.1:5432:5432"]
    volumes: ["pgdata:/var/lib/postgresql/data"]
  redis:
    image: redis:7-alpine
    command: ["sh", "-c", "exec redis-server --requirepass "$$REDIS_PASSWORD""]
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD:?Set REDIS_PASSWORD in .env}
    ports: ["127.0.0.1:6379:6379"]
volumes:
  pgdata:
EOF
 write_if_absent "$templates/ci-python.yml" <<'EOF'
# Copiare in .github/workflows/ci.yml nel repository futuro.
name: Python CI
on: [push, pull_request]
permissions:
  contents: read
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: astral-sh/setup-uv@v6
      - run: uv sync --dev
      - run: uv run pytest -q
      - run: uv run ruff check .
EOF
 write_if_absent "$templates/vscode-settings.json" <<'EOF'
{
  "editor.formatOnSave": true,
  "files.trimTrailingWhitespace": true,
  "files.insertFinalNewline": true,
  "python.defaultInterpreterPath": "${workspaceFolder}/.venv/bin/python",
  "python.analysis.autoImportCompletions": true,
  "git.confirmSync": true,
  "terminal.integrated.defaultProfile.linux": "bash"
}
EOF
 write_if_absent "$templates/README.md" <<'EOF'
# Modelli per futuri progetti
Quando decidi il nome di un progetto, crea una cartella in ~/Sviluppo e inizializza Git.
Copia soltanto i modelli che servono, rinomina pyproject.toml e personalizza i workflow.
Le configurazioni Claude e VS Code sono suggerimenti per singoli progetti, NON permessi globali.
GitHub: `gh auth login`, poi `gh repo create NOME --private` solo su richiesta.
Python: `uv sync --dev`; Node: `npm install` nel progetto, mai npm globale per gli agenti.
Docker Compose richiede segreti .env e non viene avviato automaticamente.
Backup restic: configura repository e password fuori dallo script; nessun backup parte da solo.
EOF
 echo "[OK] Workspace vuoto: $root"
 echo "[OK] Template generici: $templates"
 echo 'Nessun progetto, repository, database, container o cartella trading creati.'
}

development_environment(){
 say 'Ambiente vibe coding: uv, VS Code, GitHub e template sicuro'
 install_repo git github-cli python python-pipx nodejs npm docker docker-compose docker-buildx
 install_fallback uv uv
 install_fallback visual-studio-code-bin visual-studio-code-bin
 install_fallback claude-code claude-code
 fix_claude_path
 install_codex_cli
 install_fallback gemini-cli gemini-cli
 create_development_workspace
 echo 'Per VS Code: apri ~/Sviluppo con code ~/Sviluppo (nessun progetto creato).' 
 echo 'Per GitHub: gh auth login; crea repository PRIVATO manualmente.'
 echo 'Docker non viene abilitato implicitamente: opzione E per attivazione esplicita.'
}

enable_development_services(){
 say 'Servizi sviluppo: Docker (privilegiato) e Ollama (locale)'
 if has_pkg ollama; then
   if systemctl list-unit-files ollama.service --no-legend 2>/dev/null | grep -q '^ollama.service'; then
     sudo -n systemctl enable --now ollama.service
     systemctl is-active ollama.service || true
   fi
 else echo 'Ollama non installato: usa opzione O dopo aggiornamento.'; fi
 if has_pkg docker; then
   warn 'Docker daemon equivale a servizio con privilegi elevati. Non aggiungo utente al gruppo docker.'
   if ask 'Abilitare Docker all’avvio e avviarlo ora?'; then
     sudo -n systemctl enable --now docker.service
     systemctl is-active docker.service || true
   else echo 'Docker lasciato invariato.'; fi
 else echo 'Docker non installato: usa opzione X.'; fi
 echo 'PostgreSQL e Redis NON partono senza .env e scelta esplicita.'
}


# v10: diagnostica hardware, manutenzione SSD, profili energetici e Ledger/Rabby.
# Nessun intervento sui driver, sul bootloader o sul sistema grafico.
lean_hardware_audit(){
 say 'LEAN v10 — inventario CPU, GPU, SSD, batteria e spazio'
 echo '--- GPU ---'
 command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=name,memory.total,temperature.gpu --format=csv,noheader || true
 echo '--- Sensori ---'
 command -v sensors >/dev/null && sensors || true
 echo '--- Dischi e mount ---'
 lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL || true
 df -hT / "$HOME" || true
 echo '--- SSD/NVMe ---'
 if command -v smartctl >/dev/null; then
   while IFS= read -r disk; do
     echo "Dispositivo: $disk"
     sudo -n smartctl -H "$disk" 2>&1 || true
   done < <(lsblk -dnpo NAME,TYPE | awk '$2=="disk"{print $1}')
 fi
 echo '--- Batteria ---'
 for bat in /sys/class/power_supply/BAT*; do
   [[ -d "$bat" ]] || continue
   echo "Batteria: $bat"
   for f in status capacity charge_full charge_full_design energy_full energy_full_design; do
     [[ -r "$bat/$f" ]] && printf '%s: %s\n' "$f" "$(cat "$bat/$f")"
   done
 done
 echo '--- TRIM ---'
 systemctl is-enabled fstrim.timer 2>/dev/null || true
 systemctl is-active fstrim.timer 2>/dev/null || true
 echo '--- Profili energetici ---'
 for unit in power-profiles-daemon.service tuned.service tlp.service auto-cpufreq.service; do
   printf '%s: ' "$unit"
   systemctl is-active "$unit" 2>/dev/null || true
 done
 echo '--- Cache pacman ---'
 du -sh /var/cache/pacman/pkg 2>/dev/null || true
}

lean_monitoring_install(){
 say 'LEAN v10 — monitoraggio hardware con pacman'
 install_repo btop nvtop lm_sensors smartmontools nvme-cli pacman-contrib usbutils
 lean_hardware_audit
 echo 'Comandi: btop, nvtop, sensors, sudo smartctl -a /dev/nvme0'
 echo 'Non lancio sensors-detect automaticamente e non carico moduli kernel.'
}

lean_ssd_maintenance(){
 say 'LEAN v10 — manutenzione SSD e cache conservativa'
 install_repo pacman-contrib
 echo 'Controllo supporto TRIM per il filesystem root:'
 findmnt -no SOURCE,FSTYPE,OPTIONS / || true
 lsblk -D || true
 if systemctl list-unit-files fstrim.timer --no-legend 2>/dev/null | grep -q '^fstrim.timer'; then
   if systemctl is-enabled --quiet fstrim.timer; then
     echo '[OK] fstrim.timer gia abilitato.'
   else
     echo 'fstrim.timer non attivo: non abilito senza valutare filesystem, SSD e cifratura.'
   fi
 fi
 if command -v paccache >/dev/null; then
   echo 'Cache prima:'
   du -sh /var/cache/pacman/pkg 2>/dev/null || true
   echo 'Pulizia automatica cache: mantengo le ultime DUE versioni, nessuna rimozione pacchetti installati.'
   sudo -n paccache -r -k 2 || true
   echo 'Cache dopo:'
   du -sh /var/cache/pacman/pkg 2>/dev/null || true
 fi
 echo 'Pacchetti orfani: elenco e rimozione solo previa conferma nella funzione C.'
 pacman -Qdt || true
}

lean_power_audit(){
 say 'LEAN v10 — profili energetici: controllo senza modifiche'
 local active=0 unit
 for unit in power-profiles-daemon.service tuned.service tlp.service auto-cpufreq.service; do
   if systemctl is-active --quiet "$unit"; then
     echo "[ATTIVO] $unit"
     ((active+=1))
   else
     echo "[NON ATTIVO] $unit"
   fi
 done
 if ((active>1)); then
   warn 'Più gestori energetici attivi: possibile conflitto. Nessuna disabilitazione automatica.'
 elif ((active==0)); then
   echo 'Nessun gestore energetico riconosciuto attivo. Non ne installo uno senza verificare la configurazione.'
 else
   echo 'Un solo gestore riconosciuto attivo: lo mantengo.'
 fi
 command -v powerprofilesctl >/dev/null && powerprofilesctl get || true
 echo 'Nessun intervento su CPU, governor, GPU, driver o servizi energetici.'
}

lean_ledger_usb_audit(){
 say 'LEAN v10 — Ledger Nano X USB e regole udev'
 install_repo usbutils
 echo 'USB Ledger (vendor 2c97):'
 if lsusb -d 2c97: 2>/dev/null | grep -q .; then
   lsusb -d 2c97: || true
 else
   echo 'Non rilevato. Collega il Nano X con cavo dati, sbloccalo e riprova.'
 fi
 echo 'Regole udev esistenti per Ledger:'
 local found=0 f
 for f in /etc/udev/rules.d/*.rules /usr/lib/udev/rules.d/*.rules; do
   [[ -f "$f" ]] || continue
   if grep -Eiq '2c97|ledger|20-hw1' "$f"; then
     echo "$f"
     found=1
   fi
 done
 if ((found==0)); then
   echo 'Regole Ledger non trovate.'
   echo 'Provenienza ufficiale: https://github.com/LedgerHQ/udev-rules'
   echo 'Per sicurezza non scarico/eseguo script remoti con sudo e non imposto MODE=0666.'
   echo 'L opzione L tenta pacchetti udev dedicati tramite pacman/yay.'
 else
   echo 'Regole presenti: verifica l accesso dal client Ledger con Nano X collegato.'
 fi
 echo 'Nessuna modifica automatica a udev, permessi globali o gruppi.'
}

lean_rabby_guide(){
 say 'LEAN v10 — Rabby Wallet per Ledger Nano X'
 echo 'Rabby: verifica sul sito ufficiale la disponibilità e compatibilità dell’estensione per Firefox; non usare estensioni non ufficiali.'
 echo 'Sito ufficiale: https://rabby.io/'
 echo 'Il link Chrome Web Store non è installabile direttamente su Firefox.'
 echo 'Se Firefox non è supportato da Rabby, usa un browser Chromium separato SOLO se lo scegli consapevolmente; LEAN non lo installa.'
 echo 'In Rabby scegli connessione hardware wallet Ledger: NON importare mai la seed phrase del Nano X.'
 echo 'Verifica indirizzi, reti, approvazioni e importi sul display del dispositivo.'
 echo 'Non installo estensioni automaticamente e non apro siti simili a rabby.io.'
}

lean_v10_all(){
 lean_monitoring_install
 lean_ssd_maintenance
 lean_power_audit
 lean_ledger_usb_audit
 lean_rabby_guide
}


# v12: produttivita, contabilità, video, API/database, workflow foto iPhone e famiglia.
# Nessun progetto/repository creato. Le app web non contengono credenziali.
lean_productivity_audit(){
 say 'LEAN v12 — verifica applicazioni e workflow (sola lettura)'
 local pkg
 for pkg in homebank obs-studio handbrake dbeaver bruno pandoc libimobiledevice usbmuxd gphoto2 digikam darktable restic; do
   if has_pkg "$pkg"; then echo "[PRESENTE] $pkg"; else echo "[MANCANTE/DA VERIFICARE] $pkg"; fi
 done
 echo 'iPhone USB:'
 command -v idevice_id >/dev/null && idevice_id -l || true
 echo 'Cartella Sviluppo (nessun progetto):'
 [[ -d "$HOME/Sviluppo" ]] && echo 'Presente' || echo 'Assente'
}

lean_productivity_install(){
 say 'LEAN v14 — Solo HomeBank, video, database, API e documenti'
 # HomeBank è l'unica applicazione di contabilità da installare.
 # GnuCash, se già presente, viene proposto per la rimozione SOLO dopo
 # aver verificato HomeBank e con conferma esplicita.
 install_repo homebank
 if has_pkg gnucash; then
   warn 'GnuCash presente: non verrà utilizzato né reinstallato.'
   if has_pkg homebank; then
     if ask_explicit 'Vuoi disinstallare GnuCash? I tuoi file personali non saranno cancellati'; then
       sudo -n pacman -Rns gnucash
     else
       echo 'GnuCash mantenuto, nessuna rimozione.'
     fi
   else
     warn 'HomeBank non risulta installato: mantengo GnuCash per sicurezza.'
   fi
 fi
 install_repo obs-studio handbrake pandoc
 install_fallback dbeaver dbeaver
 install_fallback bruno bruno-bin
 echo 'OBS e HandBrake: nessun cambiamento a driver NVIDIA, encoder o Wayland.'
 echo 'DBeaver/Bruno: nessuna connessione database/API configurata e nessuna credenziale creata.'
}

lean_iphone_photo_workflow(){
 say 'LEAN v12 — importazione foto iPhone e backup non distruttivo'
 install_repo libimobiledevice usbmuxd gphoto2 libgphoto2 libheif libraw perl-image-exiftool
 local cfg="$HOME/.config/endeavouros-lean"
 mkdir -p "$cfg"
 cat > "$cfg/iphone-photo-workflow.txt" <<'GUIDE'
WORKFLOW FOTO IPHONE — EndeavourOS KDE
1. Collega iPhone sbloccato via USB con cavo dati; conferma "Autorizza" sul telefono.
2. Verifica: idevice_id -l ; idevicepair validate ; gphoto2 --auto-detect
3. Se supportato, importa tramite digiKam/gPhoto2 in una cartella scelta da te.
   L'accesso USB alle foto dipende da versione iOS, permessi e supporto PTP.
4. Alternativa: esporta originali da Foto/File dell'iPhone o via cloud,
   conservando HEIC, MOV e DNG/ProRAW senza conversione preventiva.
5. Organizza gli originali per data; evita importazioni duplicate con verifica manuale.
6. Verifica che i file siano leggibili, poi esegui backup cifrato con restic
   su destinazione scelta manualmente. Non cancellare originali dall'iPhone
   finché non hai verificato almeno una copia di backup indipendente.
7. digiKam: catalogazione; darktable: sviluppo DNG; Kdenlive: video.
NOTA: nessun trasferimento, sincronizzazione, pairing o backup automatico.
GUIDE
 echo "Guida creata: $cfg/iphone-photo-workflow.txt"
 iphone_diagnostics
}

lean_family_setup(){
 say 'Calendari e attività: guida, senza creare shortcut duplicati'
 local cfg="$HOME/.config/endeavouros-lean"
 mkdir -p "$cfg"
 cat > "$cfg/gestione-famiglia.txt" <<'GUIDE'
GESTIONE FAMIGLIA — PROPOSTA, NESSUNA CONFIGURAZIONE ACCOUNT
- Crea manualmente un calendario condiviso per appuntamenti, scuola e attività.
- Usa Google Tasks per promemoria e scadenze; verifica quali liste puoi condividere.
- Conserva documenti sensibili in una cartella cloud con permessi limitati,
  backup cifrato e autenticazione a due fattori.
- Non mettere dati personali delle figlie in repository Git o prompt AI.
- Non vengono creati calendari, cartelle cloud, account o condivisioni.
GUIDE
 echo "Guida creata: $cfg/gestione-famiglia.txt"
}

lean_v12_all(){
 lean_productivity_audit
 lean_productivity_install
 lean_iphone_photo_workflow
 lean_family_setup
}

# v18 — accesso KDE, audit LUKS e stampante HP Color Laser 150mw/150nw.
# Non esegue cryptsetup, partizionamenti, cambi PAM, firewall o driver grafici.
lean_kde_lock(){
 say 'Protezione accesso KDE — blocco schermo (senza cambiare password o PAM)'
 if [[ "${XDG_CURRENT_DESKTOP:-}" != *KDE* ]] && ! command -v kwriteconfig6 >/dev/null 2>&1; then
   report_skip 'Blocco KDE: sessione Plasma o kwriteconfig6 non rilevati'; return 0
 fi
 local cfg="$HOME/.config/kscreenlockerrc" backup
 mkdir -p "$HOME/.config"
 if [[ -f "$cfg" ]]; then
   backup="${cfg}.lean-backup-$(date +%Y%m%d-%H%M%S)"
   cp -p -- "$cfg" "$backup"
   report_ok "Backup impostazioni blocco KDE: $backup"
 fi
 if ! command -v kwriteconfig6 >/dev/null 2>&1; then
   report_skip 'kwriteconfig6 assente: configura manualmente Impostazioni di sistema > Sicurezza e privacy > Blocco schermo'; return 0
 fi
 # Impostazioni supportate da KScreenLocker su Plasma 6; nessuna modifica al login manager.
 kwriteconfig6 --file kscreenlockerrc --group Daemon --key Autolock true
 kwriteconfig6 --file kscreenlockerrc --group Daemon --key Timeout 5
 kwriteconfig6 --file kscreenlockerrc --group Daemon --key LockOnResume true
 report_ok 'KDE: blocco automatico dopo 5 minuti e blocco al risveglio configurati'
 echo 'Per rendere effettive le modifiche, esci e rientra nella sessione KDE se necessario.'
 echo 'La password di accesso esistente rimane invariata.'
}
lean_luks_audit(){
 say 'Audit cifratura disco LUKS — SOLO LETTURA'
 install_repo cryptsetup
 echo 'Dispositivi e filesystem:'
 lsblk -o NAME,TYPE,FSTYPE,SIZE,MOUNTPOINTS || true
 echo 'Radice del filesystem:'
 findmnt -no SOURCE,FSTYPE / || true
 echo 'Mapping device-mapper di tipo crypt:'
 local crypts
 crypts="$(lsblk -nr -o NAME,TYPE | awk '$2=="crypt"{print $1}')"
 if [[ -n "$crypts" ]]; then
   printf '%s\n' "$crypts"
   report_ok 'Rilevati mapping cifrati (verificare che includano i dati da proteggere)'
 else
   report_warn 'Nessun mapping crypt rilevato; non equivale a prova definitiva di disco non cifrato'
 fi
 echo 'Audit non invasivo: nessuna cifratura, conversione, modifica partizioni o bootloader.'
 local guide="$HOME/.config/endeavouros-lean/audit-cifratura-luks.txt"
 mkdir -p "$(dirname "$guide")"
 cat > "$guide" <<'LUKS_GUIDE'
CIFRATURA LUKS — PIANO SICURO (NESSUNA OPERAZIONE AUTOMATICA)
1. Verifica lo stato attuale con lsblk -f e findmnt /.
2. Prepara un backup completo, cifrato, verificato e ripristinabile su supporto esterno.
3. Conserva chiavi di recupero fuori dal laptop.
4. Se il sistema non è cifrato, pianifica una reinstallazione con LUKS o una migrazione
   assistita separata, valutando layout disco, EFI, swap, snapshot e recupero.
5. Non eseguire cryptsetup luksFormat o luksConvert sul disco in uso.
6. Verifica il ripristino del backup prima di ogni operazione distruttiva.
LUKS_GUIDE
 report_skip "Conversione LUKS non eseguita per sicurezza; guida: $guide"
}
lean_hp_printer_audit(){
 say 'HP Color Laser 150mw/150nw — rilevamento e diagnostica'
 echo 'Stampanti USB HP (vendor 03f0):'
 if command -v lsusb >/dev/null 2>&1; then lsusb -d 03f0: || true; else echo 'lsusb non presente'; fi
 echo 'Code CUPS:'
 if command -v lpstat >/dev/null 2>&1; then lpstat -p -d 2>&1 || true; else echo 'lpstat non presente'; fi
 echo 'Dispositivi USB / rete rilevati da CUPS:'
 if command -v lpinfo >/dev/null 2>&1; then
   sudo -n lpinfo -v 2>&1 | grep -Ei 'usb|ipp|dnssd|socket|hp:' | head -40 || true
 fi
 echo 'Stampanti IPP di rete (se ippfind disponibile):'
 if command -v ippfind >/dev/null 2>&1; then timeout 8 ippfind 2>/dev/null | head -20 || true; fi
 echo 'Il modello 150mw/150nw può richiedere un driver specifico; NON presumo compatibilità HPLIP o driverless IPP.'
}
lean_hp_printer_setup(){
 say 'HP Color Laser 150mw/150nw — configurazione CUPS prudente'
 install_repo cups cups-filters cups-pdf usbutils avahi system-config-printer
 if ! command -v system-config-printer >/dev/null 2>&1; then
   report_fail 'system-config-printer mancante: interfaccia grafica stampanti non disponibile'
 else
   report_ok 'system-config-printer presente: configurazione grafica disponibile'
 fi
 if ! command -v cupsd >/dev/null 2>&1; then
   report_fail 'CUPS non installato correttamente'; return 0
 fi
 if sudo -n systemctl enable --now cups.service; then
   report_ok 'CUPS abilitato e avviato'
 else
   report_fail 'Impossibile avviare cups.service'
 fi
 lean_hp_printer_audit
 local guide="$HOME/.config/endeavouros-lean/stampante-hp-color-laser-150.txt"
 mkdir -p "$(dirname "$guide")"
 cat > "$guide" <<'HP_GUIDE'
HP COLOR LASER 150mw / 150nw — CONFIGURAZIONE
1. Verifica l'esatto modello sull'etichetta della stampante.
2. Collega la stampante via USB oppure alla stessa rete Wi-Fi del laptop.
3. Apri system-config-printer, http://localhost:631 oppure Impostazioni di sistema KDE > Stampanti.
   Il messaggio relativo a PackageKit non richiede l'installazione di PackageKit: usa pacman.
4. Seleziona la stampante rilevata. Controlla il driver proposto e stampa una pagina test.
5. Questi modelli NON vanno dati per scontati come compatibili con HPLIP o IPP Everywhere.
   Se non compare un driver compatibile, recupera il driver Linux esatto dal supporto HP
   per il modello specifico, verifica provenienza e compatibilità prima di installarlo.
6. Se il modello è 150mw, prova il rilevamento USB e rete; non dare per scontato che HPLIP funzioni.
7. Nessuna regola firewall, driver non verificato o pacchetto AUR viene installato automaticamente.
HP_GUIDE
 echo "Guida stampante: $guide"
 if command -v lpstat >/dev/null 2>&1 && lpstat -p 2>/dev/null | grep -q '^printer '; then
   if ask 'Vuoi stampare una pagina di prova sulla stampante PREDEFINITA già configurata?'; then
     if lpstat -d 2>/dev/null | grep -q 'system default destination:'; then
       local tmp
       tmp="$(mktemp --suffix=.txt)"
       printf 'EndeavourOS LEAN v23 — stampa di prova\nData: %s\n' "$(date)" > "$tmp"
       if lp "$tmp"; then report_ok 'Pagina di prova inviata alla stampante predefinita';
       else report_fail 'Invio stampa di prova fallito'; fi
       rm -f "$tmp"
     else
       report_skip 'Nessuna stampante predefinita; stampa test non eseguita'
     fi
   else report_skip 'Stampa di prova non richiesta'; fi
 else
   report_skip 'Stampante non configurata in CUPS: completare selezione driver/coda e stampa di prova manualmente'
 fi
}
lean_v18_all(){
 lean_kde_lock
 lean_luks_audit
 lean_hp_printer_setup
}

# Percorso guidato unico: verifica -> audit -> aggiornamento -> installazione -> manutenzione.
# La pulizia orfani rimane soggetta a conferma e non elimina dati personali.
# Ogni fase registra l'esito e non blocca l'intero percorso B.
# Alcune funzioni interne possono gestire autonomamente errori: i pacchetti
# vengono quindi verificati anche a fine sessione.
run_step(){
 local fn="$1" rc
 echo "[FASE] $fn"
 if "$fn"; then
   report_ok "Fase completata: $fn"
 else
   rc=$?
   report_fail "Fase non completata: $fn (codice $rc)"
 fi
 return 0
}


# Virtualizzazione opzionale: QEMU/KVM + Virt-Manager, niente VirtualBox o driver host.
lean_vm_specs(){
 local memkb threads avail
 memkb=$(awk '/MemTotal:/{print $2}' /proc/meminfo)
 threads=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
 VM_HOST_RAM_MIB=$((memkb/1024))
 VM_THREADS=$threads
 if ((VM_HOST_RAM_MIB < 7000)); then VM_RAM_MIB=4096
 elif ((VM_HOST_RAM_MIB < 12000)); then VM_RAM_MIB=4096
 elif ((VM_HOST_RAM_MIB < 24000)); then VM_RAM_MIB=6144
 else VM_RAM_MIB=8192; fi
 if ((VM_HOST_RAM_MIB < 6000)); then
   VM_RAM_MIB=0
 fi
 if ((threads >= 8)); then VM_CPUS=4; else VM_CPUS=2; fi
 if ((VM_CPUS >= threads)); then VM_CPUS=$((threads-1)); fi
 ((VM_CPUS >= 1)) || VM_CPUS=1
 if ((VM_HOST_RAM_MIB >= 12000)); then VM_DISK_GB=100; else VM_DISK_GB=80; fi
 printf 'Host: %s | RAM %s MiB | thread %s | VM suggerita: RAM %s MiB, vCPU %s, disco %s GiB (qcow2 dinamico)\n' \
  "$HW_MODEL" "$VM_HOST_RAM_MIB" "$threads" "$VM_RAM_MIB" "$VM_CPUS" "$VM_DISK_GB"
}
lean_vm_kde_launcher(){
 say 'Verifica collegamento KDE di Virt-Manager'
 local appdir="$HOME/.local/share/applications"
 local desk="$appdir/endeavouros-lean-virt-manager.desktop"
 local existing_icon="virt-manager"
 if ! command -v virt-manager >/dev/null 2>&1; then
   report_warn 'Menu KDE VM: virt-manager non installato; collegamento non creato'
   return 1
 fi
 mkdir -p "$appdir"
 # Se l'icona ufficiale non è installata, usa quella di sistema, senza file mancanti.
 if [[ ! -e /usr/share/icons/hicolor/scalable/apps/virt-manager.svg ]] && \
    ! find /usr/share/icons/hicolor -iname '*virt-manager*' -print -quit 2>/dev/null | grep -q .; then
   existing_icon='computer'
 fi
 # Non sovrascrivere collegamenti personalizzati: ripara solo quello gestito da LEAN.
 if [[ -e "$desk" ]] && ! grep -q '^X-EndeavourOS-LEAN-Managed=true$' "$desk" && ! grep -q '^Comment=Gestisci Windows e Linux con QEMU/KVM$' "$desk"; then
   report_skip 'Launcher KDE VM esistente non marcato LEAN: preservato'
 else
   cat > "$desk" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Macchine virtuali (Virt-Manager)
GenericName=Gestore macchine virtuali
Comment=Gestisci macchine virtuali Windows e Linux con QEMU/KVM
Exec=virt-manager
TryExec=virt-manager
Icon=$existing_icon
Terminal=false
Categories=System;Emulator;
StartupNotify=true
X-EndeavourOS-LEAN-Managed=true
EOF
   report_ok 'Collegamento KDE Virt-Manager creato o riparato'
 fi
 if command -v desktop-file-validate >/dev/null 2>&1; then
   desktop-file-validate "$desk" 2>&1 || report_warn 'Launcher KDE VM: verifica desktop-file-validate'
 fi
 if command -v kbuildsycoca6 >/dev/null 2>&1; then
   if kbuildsycoca6 --noincremental >/dev/null 2>&1; then
     report_ok 'Cache menu KDE ricostruita (kbuildsycoca6)'
   else
     report_warn 'Cache menu KDE: ricostruzione non riuscita; ripetere dopo accesso KDE'
   fi
 else
   report_warn 'kbuildsycoca6 assente: collegamento creato, cache non aggiornata'
 fi
 if [[ -f "$desk" ]] && grep -q '^Exec=virt-manager$' "$desk"; then
   report_ok 'Menu KDE: Macchine virtuali (Virt-Manager) pronto'
 else
   report_warn 'Menu KDE: collegamento VM da verificare'
 fi
}

lean_vm_install(){
 say 'Virtualizzazione KDE: QEMU/KVM + Virt-Manager (installazione predefinita)'
 detect_hardware
 lean_vm_specs
 if [[ ! -e /dev/kvm ]]; then
   warn '/dev/kvm assente: controlla Intel VT-x nel BIOS/UEFI. Non modifico il firmware.'
   report_warn 'VM: accelerazione KVM non disponibile'
 fi
 # Solo pacchetti ufficiali, nessun modulo proprietario e nessun cambio kernel.
 install_repo qemu-desktop libvirt virt-manager virt-install virt-viewer edk2-ovmf swtpm dnsmasq spice-gtk usbredir virtiofsd
 if ! command -v virt-manager >/dev/null 2>&1; then
   report_fail 'Virt-Manager non disponibile dopo installazione'; return 1
 fi
 if systemctl list-unit-files libvirtd.service --no-legend 2>/dev/null | grep -q '^libvirtd.service'; then
   if true; then # v40: servizio VM incluso di default
     if sudo systemctl enable --now libvirtd.service; then report_ok 'libvirtd attivato'; else report_fail 'libvirtd non attivato'; fi
   fi
 elif systemctl list-unit-files virtqemud.socket --no-legend 2>/dev/null | grep -q '^virtqemud.socket'; then
   if true; then # v40: socket VM incluso di default
     if sudo systemctl enable --now virtqemud.socket; then report_ok 'virtqemud.socket attivato'; else report_fail 'virtqemud.socket non attivato'; fi
   fi
 fi
 if ! id -nG "$USER" | grep -qw libvirt; then
   if true; then # v40: accesso libvirt predisposto di default; nuovo login richiesto
     if sudo usermod -aG libvirt "$USER"; then report_ok 'Gruppo libvirt aggiunto: nuovo login necessario'; else report_fail 'Gruppo libvirt: modifica fallita'; fi
   fi
 fi
 # Ripara il launcher KDE anche se Virt-Manager era già installato.
 lean_vm_kde_launcher
 report_ok 'Stack VM QEMU/KVM predisposto'
}
lean_vm_open_url(){
 local url="$1"
 if command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 &
 else echo "Apri nel browser: $url"; fi
}
lean_vm_wizard(){
 say 'Creazione macchina virtuale guidata: Windows 11 / Linux / macOS'
 detect_hardware
 lean_vm_specs
 if ((VM_RAM_MIB == 0)); then
   warn 'RAM insufficiente per una VM Windows 11 consigliabile; nessuna VM creata.'
   report_skip 'VM: RAM host insufficiente'; return 0
 fi
 if [[ ! -e /dev/kvm ]]; then
   warn 'KVM non disponibile: verifica VT-x/AMD-V nel BIOS, poi riprova.'
   report_skip 'VM: KVM assente'; return 0
 fi
 if ! command -v virt-install >/dev/null 2>&1; then
   echo 'Virt-Manager non installato.'
   if ask 'Installare QEMU/KVM e Virt-Manager ora?'; then lean_vm_install || return 1; else return 0; fi
 fi
 echo ' 1) Windows 11 x64 — HDtracks Download Manager (consigliato)'
 echo ' 2) Linux — scegli ISO ufficiale'
 echo ' 3) macOS — informazioni su compatibilità/licenza (nessuna installazione su PC non Apple)'
 echo ' 0) Annulla'
 local choice osid name iso defaultiso
 read -r -p 'Sistema operativo [1]: ' choice || return 0
 choice=${choice:-1}
 case "$choice" in
  1)
   osid=win11; name=HDtracks-Windows11
   echo 'Aprirò la pagina Microsoft per scaricare manualmente la ISO ufficiale Windows 11 x64.'
   echo 'Microsoft genera URL temporanei: lo script non inventa link diretti e non aggira i controlli.'
   echo 'Driver guest ufficiali: https://github.com/virtio-win/virtio-win-pkg-scripts/blob/master/README.md'
   echo 'SPICE guest tools: https://www.spice-space.org/download.html'
   echo 'Il download ISO è gratuito, ma la licenza di utilizzo Windows NON è gratuita.'
   lean_vm_open_url 'https://www.microsoft.com/it-it/software-download/windows11'
   echo 'Sezione: Scarica immagine disco Windows 11 (ISO) per dispositivi x64.'
   ;;
  2)
   osid=linux; name=Linux-VM
   echo 'Aprirò la pagina ufficiale Debian con immagini ISO aggiornate.'
   lean_vm_open_url 'https://www.debian.org/distrib/'
   echo 'Scarica una ISO amd64 dal sito ufficiale Debian, oppure indica una ISO Linux già presente.'
   ;;
  3)
   echo 'macOS: le condizioni Apple limitano la virtualizzazione a hardware Apple compatibile.'
   echo 'Su Razer e ThinkPad non scarico né installo macOS, e non aggiro controlli di licenza.'
   report_skip 'VM macOS: non disponibile su hardware non Apple'; return 0;;
  0) return 0;;
  *) warn 'Scelta non valida'; return 0;;
 esac
 echo 'Quando il download è terminato, indica il percorso completo della ISO.'
 read -r -p 'Percorso ISO (Invio per rimandare): ' iso || return 0
 [[ -n "$iso" ]] || { report_skip 'VM: ISO da scaricare; creazione rimandata'; return 0; }
 iso="${iso/#\~/$HOME}"
 if [[ ! -f "$iso" || "$iso" != *.iso && "$iso" != *.ISO ]]; then
   warn 'ISO non trovata oppure estensione non .iso; nessuna VM creata.'
   report_skip 'VM: ISO mancante/non riconosciuta'; return 0
 fi
 if ! command -v file >/dev/null 2>&1 || ! file -b "$iso" | grep -Eqi 'ISO 9660|UDF|boot sector|filesystem data'; then
   warn 'Immagine non riconosciuta come ISO; verifica provenienza e checksum.'
   report_skip 'VM: formato ISO non verificato'; return 0
 fi
 echo 'Verifica checksum SHA256 pubblicato dal produttore prima di procedere.'
 if ! ask_explicit 'Hai verificato provenienza ufficiale e checksum della ISO?'; then
   report_skip 'VM: checksum ISO non verificato'; return 0
 fi
 local free_kib vmroot iso_dst diskpath vmname os_variant
 vmroot='/var/lib/libvirt/images'
 free_kib=$(df -Pk "$HOME" | awk 'NR==2{print $4}')
 if ((free_kib < 35*1024*1024)); then
   warn 'Meno di 35 GiB liberi: creazione VM annullata.'
   report_skip 'VM: spazio disco insufficiente'; return 0
 fi
 if ! command -v virsh >/dev/null 2>&1 || ! sudo -n virsh -c qemu:///system list --all >/dev/null 2>&1; then
   warn 'Connessione libvirt system non disponibile. Verifica servizio/socket e autorizzazioni.'
   report_skip 'VM: libvirt system non accessibile'; return 0
 fi
 if [[ "$osid" == win11 ]]; then
   if ! command -v swtpm >/dev/null 2>&1; then
     warn 'swtpm assente: TPM 2.0 necessario per Windows 11.'; report_skip 'VM: swtpm assente'; return 0
   fi
   os_variant=win11
 else
   os_variant=debian12
 fi
 vmname="$name"
 diskpath="$vmroot/$vmname.qcow2"
 iso_dst="$vmroot/$vmname-install.iso"
 if sudo -n virsh -c qemu:///system dominfo "$vmname" >/dev/null 2>&1 || sudo -n test -e "$diskpath" || sudo -n test -e "$iso_dst"; then
   warn 'VM o file preesistenti: non sovrascrivo nulla.'
   report_skip 'VM: nome già utilizzato, controllare Virt-Manager'; return 0
 fi
 echo "VM: $vmname | $VM_RAM_MIB MiB | $VM_CPUS vCPU | ${VM_DISK_GB}GiB qcow2"
 echo 'Verranno copiati ISO e disco nel pool libvirt di sistema (richiede spazio aggiuntivo).'
 echo 'Windows 11: UEFI, TPM 2.0, controller SATA e rete e1000 per evitare driver durante setup.'
 echo 'Display SPICE; USB redirection disponibile in Virt-Manager; driver guest da completare in Windows.'
 if ! ask_explicit 'Creare e avviare la VM con queste impostazioni?'; then
   report_skip 'VM: creazione annullata'; return 0
 fi
 sudo -n install -m 0644 "$iso" "$iso_dst" || { report_fail 'VM: copia ISO non riuscita'; return 0; }
 if ! sudo -n qemu-img create -f qcow2 "$diskpath" "${VM_DISK_GB}G"; then
   report_fail 'VM: creazione disco fallita'; return 0
 fi
 sudo -n chmod 0644 "$iso_dst"
 sudo -n chmod 0600 "$diskpath"
 local args=(--connect qemu:///system --name "$vmname" --memory "$VM_RAM_MIB" --vcpus "$VM_CPUS"
   --virt-type kvm --machine q35 --cpu host-passthrough --os-variant "$os_variant"
   --disk "path=$diskpath,format=qcow2,bus=sata"
   --cdrom "$iso_dst" --network network=default,model=e1000e
   --graphics spice,listen=none --video virtio
   --controller usb,model=qemu-xhci --boot uefi --noautoconsole)
 if [[ "$osid" == win11 ]]; then
   args+=(--tpm backend.type=emulator,backend.version=2.0,model=tpm-crb --features smm=on)
 fi
 # Non forzare --check all=off e non alterare sicurezza del filesystem.
 if sudo -n virt-install "${args[@]}"; then
   report_ok "VM $vmname definita e avviata in libvirt"
   echo 'Apri Virt-Manager, seleziona la VM e completa la procedura guidata del sistema operativo.'
   echo 'Se Windows segnala requisiti Secure Boot, abilita firmware UEFI Secure Boot in Virt-Manager prima di riprovare.'
   echo 'Driver guest VirtIO: https://github.com/virtio-win/virtio-win-pkg-scripts'
   echo 'SPICE tools: https://www.spice-space.org/download.html'
   echo 'Per USB: VM > Redirect USB device; scollega/smonta prima la periferica dall host.'
   echo 'Per FLAC: preferisci scaricare in una cartella Windows e trasferire a Linux via rete o cartella condivisa.'
   report_skip "VM $vmname: installazione guest, driver SPICE/VirtIO, USB e HDtracks da completare"
   command -v virt-manager >/dev/null 2>&1 && (virt-manager >/dev/null 2>&1 &)
 else
   report_fail "VM $vmname: virt-install non riuscito; controlla log e file in $vmroot"
 fi

}

# Syncthing: sincronizzazione peer-to-peer, senza duplicare daemon o cartelle.
lean_syncthing(){
 say 'Syncthing — sincronizzazione ThinkPad / Razer con GUI locale'
 detect_hardware
 install_repo syncthing
 if ! command -v syncthing >/dev/null 2>&1; then
   report_fail 'Syncthing: eseguibile assente dopo installazione'; return 1
 fi
 # Il servizio utente evita di eseguire il daemon come root.
 if systemctl --user list-unit-files syncthing.service --no-legend 2>/dev/null | grep -q '^syncthing.service'; then
   if systemctl --user enable --now syncthing.service; then
     report_ok 'Syncthing: servizio utente attivo e abilitato al login'
   else
     report_warn 'Syncthing: impossibile avviare servizio utente; verificare sessione systemd --user'
   fi
 else
   report_warn 'Syncthing: unità systemd utente non trovata'
 fi
 local dir="$HOME/.local/share/applications" desk="$HOME/.local/share/applications/lean-syncthing.desktop"
 mkdir -p "$dir"
 if [[ -f "$desk" ]] && ! grep -q '^X-EndeavourOS-LEAN=true$' "$desk"; then
   report_warn 'Syncthing: launcher personalizzato preservato'
 else
   cat > "$desk" <<'EOF_SYNCTHING_DESKTOP'
[Desktop Entry]
Type=Application
Name=Syncthing - Sincronizzazione
Comment=Gestione sincronizzazione tra computer (GUI locale)
Exec=xdg-open http://127.0.0.1:8384/
Icon=folder-sync
Terminal=false
Categories=Network;FileTransfer;
X-EndeavourOS-LEAN=true
EOF_SYNCTHING_DESKTOP
   report_ok 'Syncthing: launcher KDE creato con icona folder-sync'
 fi
 if command -v kbuildsycoca6 >/dev/null 2>&1; then
   kbuildsycoca6 --noincremental >/dev/null 2>&1 || report_warn 'Syncthing: cache KDE non aggiornata'
 fi
 echo 'GUI: http://127.0.0.1:8384/ (solo computer locale).'
 echo 'Per collegare ThinkPad e Razer: su entrambi apri GUI > Azioni > Mostra ID; aggiungi reciprocamente i dispositivi e condividi SOLO le cartelle scelte.'
 echo 'Non condivido automaticamente HOME, profili Firefox, password, cartelle VM, Docker o dati AppFlowy.'
 echo 'iPhone (Möbius Sync): apri l’app, aggiungi il Device ID del computer e autorizza la cartella scelta nella GUI Syncthing.'
 echo 'Nota iOS: Möbius Sync non può sincronizzare continuamente in background; apri l’app per sincronizzazioni affidabili.'
 report_skip 'Syncthing: abbinamento ID e selezione cartelle sui due computer da completare nella GUI'
}
lean_syncthing_report(){
 echo
 echo 'STATO SYNCTHING / SINCRONIZZAZIONE'
 if has_pkg syncthing; then echo '  [OK] Pacchetto syncthing'; else echo '  [MANCA] Pacchetto syncthing'; fi
 if systemctl --user is-active --quiet syncthing.service; then echo '  [OK] Servizio utente attivo'; else echo '  [DA FARE] Servizio utente non attivo'; fi
 if systemctl --user is-enabled --quiet syncthing.service; then echo '  [OK] Avvio automatico al login'; else echo '  [DA FARE] Abilitare servizio utente'; fi
 if [[ -f "$HOME/.local/share/applications/lean-syncthing.desktop" ]]; then echo '  [OK] Launcher KDE'; else echo '  [MANCA] Launcher KDE'; fi
 echo '  [DA FARE] Abbinare reciprocamente ThinkPad e Razer tramite Device ID e scegliere cartelle'
 echo '  [DA FARE] Collegare iPhone tramite Möbius Sync (Device ID, autorizzazione cartelle)'
 echo '  [INFO] iOS limita la sincronizzazione in background: aprire Möbius Sync per sincronizzare' 
 echo '  [INFO] GUI locale: http://127.0.0.1:8384/ — non esporre porta 8384 a Internet'
}
lean_safe_cleanup(){
 say 'Manutenzione conservativa: dipendenze, orfani e cache'
 local orphans=() pkg protected=() removable=() rc=0
 if ! pacman -Dk; then
   report_warn 'Dipendenze pacman non integre: rimozione orfani e cache saltata'; return 1
 fi
 mapfile -t orphans < <(pacman -Qdtq 2>/dev/null || true)
 for pkg in "${orphans[@]}"; do
   # Non rimuovere mai automaticamente pacchetti espliciti, kernel, driver, firmware o componenti VM.
   if [[ "$pkg" =~ ^(linux.*|.*-headers|dkms|.*firmware.*|nvidia.*|lib32-nvidia.*|openrazer.*|.*-dkms|bluez.*|usbmuxd|libimobiledevice|steam-devices|qemu.*|libvirt.*|virt-.*|edk2.*|swtpm.*|syncthing.*)$ ]]; then
     protected+=("$pkg")
   else
     removable+=("$pkg")
   fi
 done
 if ((${#protected[@]})); then printf 'Protetti (non rimossi): %s\n' "${protected[*]}"; fi
 if ((${#removable[@]})); then
   echo 'Candidati orfani (pacman non rileva gli usi manuali o esterni):'
   printf '  %s\n' "${removable[@]}"
   if ask_explicit 'Esaminati i candidati: autorizzi la rimozione con controllo dipendenze pacman?'; then
     sudo -n pacman -Rns -- "${removable[@]}" || { rc=1; report_warn 'Rimozione orfani fallita/annullata'; }
   else
     report_skip 'Orfani non rimossi: conferma non concessa'
   fi
 else
   report_ok 'Nessun orfano non protetto da proporre'
 fi
 if command -v paccache >/dev/null 2>&1; then
   # Non cancellare l'intera cache: preserva 2 versioni per eventuale rollback.
   if sudo -n paccache -r -k 2; then report_ok 'Cache pacman ridotta conservando 2 versioni';
   else report_warn 'Pulizia cache pacman non riuscita'; rc=1; fi
 else
   report_skip 'paccache non disponibile: pacman-contrib mancante'
 fi
 echo 'Non elimino cache personali, dati Syncthing, AppFlowy, VM, Docker, Firefox o pacchetti AUR espliciti.'
 echo 'Pacchetti installati:'; pacman -Qq 2>/dev/null | wc -l
 echo 'Orfani residui:'; (pacman -Qdtq 2>/dev/null || true) | wc -l
 echo 'Cache pacman residua:'; du -sh /var/cache/pacman/pkg 2>/dev/null || true
 return "$rc"
}
# GitHub: creazione opzionale, privata per default, mai senza consenso.
# L'autenticazione avviene tramite GitHub CLI; non memorizzare token nello script.
LEAN_REPO_NAME="endeavouros-lean"
lean_github_repo(){
 say 'GitHub: repository per script e documentazione LEAN'
 local owner visibility repo source_dir workdir script_src readme_src guide_src server_src existing
 if ! command -v git >/dev/null 2>&1 || ! command -v gh >/dev/null 2>&1; then
   echo 'Bootstrap minimo: installo git e github-cli prima del repository.'
   install_repo git github-cli
 fi
 if ! command -v gh >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
   report_skip 'GitHub: git/gh mancanti; repository rimandato'; return 0
 fi
 if ! gh auth status >/dev/null 2>&1; then
   echo 'Autenticazione GitHub richiesta nel browser (non inserire token nello script).'
   if ! gh auth login --hostname github.com --git-protocol https --web; then
     report_skip 'GitHub: login non completato; repository rimandato'; return 0
   fi
 fi
 owner=$(gh api user --jq .login 2>/dev/null || true)
 if [[ -z "$owner" ]]; then report_warn 'GitHub: impossibile leggere account autenticato'; return 0; fi
 echo "Account GitHub: $owner"
 echo "Repository proposto: $owner/$LEAN_REPO_NAME"
 echo 'Privato consigliato durante i test; puoi renderlo pubblico in seguito.'
 if ! ask 'Vuoi creare/verificare il repository GitHub adesso?'; then
   report_skip 'GitHub: creazione non autorizzata'; return 0
 fi
 visibility='--private'
 if ask_explicit 'Vuoi renderlo PUBBLICO fin da subito (codice leggibile da chiunque)?'; then visibility='--public'; fi
 repo="$owner/$LEAN_REPO_NAME"
 if gh repo view "$repo" >/dev/null 2>&1; then
   echo "Repository già esistente: $repo (nessuna modifica alla visibilità)"
 else
   if ! gh repo create "$repo" "$visibility" --description 'Installer EndeavourOS KDE LEAN: ThinkPad e Razer' --clone=false; then
     report_warn 'GitHub: creazione repository non riuscita'; return 0
   fi
   report_ok "Repository GitHub creato: $repo"
 fi
 echo "Repository: https://github.com/$repo"
 source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
 script_src="$source_dir/$(basename -- "${BASH_SOURCE[0]}")"
 readme_src="$source_dir/README.md"
 if [[ ! -f "$readme_src" ]]; then
   report_skip 'GitHub: README non trovato accanto allo script; upload iniziale rimandato'
   return 0
 fi
 guide_src="$source_dir/hdtracks-vm-fiio-m3k.md"
 if [[ ! -f "$guide_src" ]]; then
   report_skip 'GitHub: guida HDtracks non trovata accanto allo script; upload rimandato'
   return 0
 fi
 server_src="$source_dir/proxmox-homelab.md"
 if [[ ! -f "$server_src" ]]; then
   report_skip 'GitHub: guida server Proxmox non trovata accanto allo script; upload rimandato'
   return 0
 fi
 if ! ask 'Vuoi sincronizzare SOLO i 4 file del progetto (script, README, guida HDtracks, guida Proxmox), senza dati personali?'; then
   report_skip 'GitHub: caricamento iniziale non autorizzato'; return 0
 fi
 # Percorso del clone Git scelto dall'utente (Invio accetta ~/Projects).
 local default_workdir="$HOME/Projects/$LEAN_REPO_NAME" requested_dir
 printf '\nCartella per il repository locale GitHub (predefinita: %s)\n' "$default_workdir"
 read -r -p 'Percorso [Invio = predefinito]: ' requested_dir
 requested_dir="${requested_dir:-$default_workdir}"
 case "$requested_dir" in
   '~') requested_dir="$HOME" ;;
   '~/'*) requested_dir="$HOME/${requested_dir#\~/}" ;;
 esac
 if [[ "$requested_dir" != /* || "$requested_dir" == / || "$requested_dir" == "$HOME" ]]; then
   echo 'ERRORE: scegli una sottocartella con percorso assoluto (es. ~/Projects/endeavouros-lean).'
   report_fail 'GitHub: percorso locale non valido'; return 1
 fi
 workdir="${requested_dir%/}"
 echo "Repository locale: $workdir"
 mkdir -p -- "$(dirname -- "$workdir")"
 if [[ -e "$workdir" && ! -d "$workdir/.git" ]]; then
   report_warn "GitHub: $workdir esiste e non è un repository Git; non modifico la cartella"; return 0
 fi
 if [[ ! -d "$workdir/.git" ]]; then
   if ! gh repo clone "$repo" "$workdir"; then
     report_warn 'GitHub: clone non riuscito'; return 0
   fi
 fi
 existing=$(git -C "$workdir" remote get-url origin 2>/dev/null || true)
 if [[ "$existing" != *"github.com/$repo"* && "$existing" != *"github.com:$repo"* ]]; then
   report_warn 'GitHub: origin non corrisponde al repository atteso; nessun upload'; return 0
 fi
 if [[ -n "$(git -C "$workdir" status --porcelain)" ]]; then
   report_warn 'GitHub: modifiche locali presenti, nessuna sovrascrittura'; return 0
 fi
 if ! git -C "$workdir" pull --ff-only 2>/dev/null; then
   echo 'Repository vuoto o branch senza upstream: continuo senza forzare.'
 fi
 cp -- "$script_src" "$workdir/endeavouros-setup.sh"
 cp -- "$readme_src" "$workdir/README.md"
 cp -- "$guide_src" "$workdir/hdtracks-vm-fiio-m3k.md"
 cp -- "$server_src" "$workdir/proxmox-homelab.md"
 # Rinomina i vecchi file versionati senza toccare altri contenuti del repository.
 for legacy in endeavourOS_customization.sh HDtracks_Windows11_VM_FiiO_M3K.md 04_Proxmox_Home_Server_Fastweb.md; do
   if git -C "$workdir" ls-files --error-unmatch -- "$legacy" >/dev/null 2>&1; then
     git -C "$workdir" rm -- "$legacy" || { report_warn "GitHub: impossibile rinominare $legacy"; return 0; }
   fi
 done
 git -C "$workdir" add -- endeavouros-setup.sh README.md hdtracks-vm-fiio-m3k.md proxmox-homelab.md
 if git -C "$workdir" diff --cached --quiet; then
   report_ok 'GitHub: file già sincronizzati'
   return 0
 fi
 if ! git -C "$workdir" -c user.name="$owner" -c user.email="$owner@users.noreply.github.com" commit -m 'docs: sync LEAN installer and four project files'; then
   report_warn 'GitHub: commit fallito; controllare identità Git'; return 0
 fi
 if git -C "$workdir" push -u origin HEAD; then
   report_ok "GitHub: tutti e quattro i file del progetto sincronizzati in $repo"
 else
   report_warn 'GitHub: push non riuscito; commit locale conservato'
 fi
}
lean_github_report(){
 echo
 echo 'GITHUB — STATO REPOSITORY'
 if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
   echo '  [OK] GitHub CLI autenticata'
   local owner
   owner=$(gh api user --jq .login 2>/dev/null || true)
   if [[ -n "$owner" ]] && gh repo view "$owner/$LEAN_REPO_NAME" >/dev/null 2>&1; then
     echo "  [OK] Repository: https://github.com/$owner/$LEAN_REPO_NAME"
   else echo '  [DA FARE] Repository non verificato'; fi
 else echo '  [DA FARE] gh auth login / installazione github-cli'; fi
 echo '  [INFO] Sincronizzazione dei quattro file del progetto tramite commit/push'
 echo '  [INFO] Non continua in background'
}
lean_guided(){
 detect_hardware
 if [[ "$HW_PROFILE" == unknown ]]; then
   warn 'GPU non identificata: percorso automatico interrotto per sicurezza. Esegui audit hardware.'
   report_fail 'Preflight: hardware grafico sconosciuto; installazione automatica annullata'
   return 1
 fi
 RUN_MODE="B — percorso guidato completo"
 say 'PERCORSO GUIDATO LEAN: hardware -> app -> garbage -> GitHub -> aggiornamento -> installazione -> pulizia'
 echo 'FASE 1/6 — Inventario e preflight (sola lettura)'
 run_step preflight
 run_step lean_browser_audit
 # La pulizia/ricreazione avviene prima delle installazioni; si ripete a fine percorso.
 run_step lean_rebuild_web_shortcuts
 detect_hardware
 echo 'FASE 2/6 — Audit pacchetti, servizi, hardware, alimentazione e Ledger (sola lettura)'
 run_step maintenance_audit
 run_step lean_hardware_audit
 run_step lean_power_audit
 run_step lean_productivity_audit
 echo 'Controllo garbage pre-installazione (sola lettura, nessuna rimozione):'
 run_step maintenance_audit
 echo 'Ledger USB: verifica preliminare senza installare pacchetti.'
 if command -v lsusb >/dev/null; then lsusb -d 2c97: || true; else echo 'usbutils non installato: verra installato in seguito.'; fi
 echo 'FASE 3/6 — GitHub (con consenso; bootstrap git/gh se assenti)'
 run_step lean_github_repo
 echo 'FASE 4/6 — Aggiornamento completo del sistema (necessario su Arch)'
 run_step update_system
 echo 'FASE 5/6 — Installazioni per categoria (sistema -> sviluppo -> AI -> sync -> comunicazione -> produttività -> media)'
 echo '  [1/8] SISTEMA, HARDWARE, SICUREZZA E VIRTUALIZZAZIONE'
 run_step base_apps
 run_step lean_vm_install
 run_step lean_gpu_mode
 run_step lean_gpu_shortcuts
 run_step lean_firefox_replace_brave
 run_step lean_firefox_privacy_harden
 run_step security_audit
 run_step privacy
 run_step lean_monitoring_install
 run_step lean_power_audit
 run_step lean_kde_lock
 run_step lean_luks_audit
 run_step lean_hp_printer_setup
 echo '  [2/8] SVILUPPO E INFRASTRUTTURA'
 run_step development_environment
 run_step docker_setup
 run_step enable_development_services
 echo '  [3/8] INTELLIGENZA ARTIFICIALE'
 run_step ai_tools
 run_step ollama_local
 run_step ai_desktop
 echo '  [4/8] SINCRONIZZAZIONE, CLOUD E DISPOSITIVI'
 run_step lean_syncthing
 run_step cloud
 run_step iphone
 run_step iphone_diagnostics
 run_step lean_iphone_photo_workflow
 echo '  [5/8] COMUNICAZIONE, MAIL E VPN'
 run_step lean_tuta_desktop
 run_step lean_social_ferdium
 run_step proton_vpn_setup
 echo '  [6/8] OFFICE, GOOGLE E PRODUTTIVITÀ'
 run_step lean_office_fonts
 run_step google_workspace
 run_step lean_google_office
 run_step lean_appflowy
 run_step lean_productivity_install
 run_step lean_family_setup
 echo '  [7/8] MEDIA, GIOCHI, FINANZA E PERIFERICHE'
 run_step photo_video
 run_step steam_setup
 run_step ledger_setup
 run_step lean_ledger_usb_audit
 run_step lean_rabby_guide
 run_step defi_setup
 run_step pdf_ocr_setup
 echo '  [8/8] ASPETTO KDE E CONTROLLO DI COMPLETAMENTO'
 run_step macos_desktop_look
 echo 'FASE 6/6 — Controllo finale e pulizia conservativa'
 run_step maintenance_audit
 run_step lean_safe_cleanup
 run_step lean_hardware_audit
 run_step lean_rebuild_web_shortcuts
 run_step lean_postinstall_review
 echo 'Fasi completate. Il report finale verrà mostrato alla chiusura del menu.'
}
lean_gpu_shortcuts(){
 say 'Shortcut KDE: preferenza GPU Intel / NVIDIA / Hybrid'
 detect_hardware
 if (( ! HAS_NVIDIA_GPU )); then
   echo 'NVIDIA assente: nessuna scelta GPU richiesta; solo Intel se rilevata.'
 fi
 local bindir="$HOME/.local/bin" appdir="$HOME/.local/share/applications" icondir="$HOME/.local/share/icons/hicolor/scalable/apps"
 mkdir -p "$bindir" "$appdir" "$icondir" "$HOME/.config/endeavouros-lean"
 local helper="$bindir/lean-gpu-select"
 if [[ -e "$helper" ]] && ! grep -Eq '^# LEAN GPU SELECT v(32|33|34)$' "$helper"; then
   warn "Helper personalizzato esistente: $helper. Non sovrascrivo."; report_warn 'Shortcut GPU: helper personalizzato non modificato'; return 0
 fi
 cat > "$helper" <<'GPU_SELECT'
#!/usr/bin/env bash
# LEAN GPU SELECT v34
set -euo pipefail
case "${1:-}" in
 intel|nvidia|hybrid) mode="$1";;
 *) printf 'Uso: lean-gpu-select {intel|nvidia|hybrid}\n' >&2; exit 2;;
esac
if [[ "$mode" == nvidia ]] && { [[ ! -e /sys/bus/pci/devices ]] || ! grep -lqi '0x10de' /sys/bus/pci/devices/*/vendor 2>/dev/null || ! command -v prime-run >/dev/null 2>&1; }; then
  message='prime-run non trovato: preferenza NVIDIA non cambiata.'
  command -v kdialog >/dev/null 2>&1 && kdialog --error "$message" || printf '%s\n' "$message" >&2
  exit 1
fi
confdir="$HOME/.config/endeavouros-lean"
mkdir -p "$confdir"
printf '%s\n' "$mode" > "$confdir/gpu-mode"
case "$mode" in
 intel) label='Intel (preferenza per le applicazioni LEAN)' ;;
 nvidia) label='NVIDIA (applicazioni LEAN tramite PRIME)' ;;
 hybrid) label='Hybrid (applicazioni LEAN in avvio normale)' ;;
esac
message="Preferenza GPU: $label. Il desktop KDE e le applicazioni già aperte NON cambiano GPU. Usa lean-gpu-run per le nuove applicazioni."
if command -v notify-send >/dev/null 2>&1; then notify-send 'EndeavourOS LEAN · GPU' "$message"; else printf '%s\n' "$message"; fi
GPU_SELECT
 chmod 755 "$helper"
 local mode title color glyph iconfile desktop
 for mode in intel nvidia hybrid; do
   if (( ! HAS_NVIDIA_GPU )) && { [[ "$mode" != intel ]] || (( ! HAS_INTEL_GPU )); }; then
     desktop="$appdir/endeavouros-gpu-$mode.desktop"
     if [[ -f "$desktop" ]] && grep -Eq '^# LEAN GPU SHORTCUT v(32|33|34)$' "$desktop"; then rm -f "$desktop"; fi
     report_skip "GPU $mode: shortcut non creato (NVIDIA assente)"
     continue
   fi
   case "$mode" in
    intel) title='GPU · Intel'; color='#2676b8'; glyph='I';;
    nvidia) title='GPU · NVIDIA'; color='#3f8b34'; glyph='N';;
    hybrid) title='GPU · Hybrid'; color='#7359ad'; glyph='H';;
   esac
   iconfile="$icondir/endeavouros-gpu-$mode.svg"
   if [[ -e "$iconfile" ]] && ! grep -q 'viewBox="0 0 64 64"' "$iconfile"; then
     warn "Icona esistente non gestita dallo script: $iconfile (preservata)"
   else
     cat > "$iconfile" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
 <rect x="5" y="5" width="54" height="54" rx="14" fill="$color"/>
 <rect x="15" y="15" width="34" height="34" rx="7" fill="none" stroke="#fff" stroke-width="3"/>
 <text x="32" y="40" text-anchor="middle" font-family="sans-serif" font-weight="bold" font-size="24" fill="#fff">$glyph</text>
</svg>
SVG
   fi
   desktop="$appdir/endeavouros-gpu-$mode.desktop"
   if [[ -e "$desktop" ]] && ! grep -Eq '^# LEAN GPU SHORTCUT v(32|33|34)$' "$desktop"; then
     warn "Collegamento personalizzato esistente: $desktop (preservato)"
     report_warn "GPU: collegamento $mode non modificato"
     continue
   fi
   cat > "$desktop" <<EOF
[Desktop Entry]
# LEAN GPU SHORTCUT v34
Type=Application
Name=$title
Comment=Imposta la preferenza per le applicazioni avviate con lean-gpu-run; non cambia la GPU del desktop
Exec=$helper $mode
Icon=$iconfile
Terminal=false
Categories=Settings;System;
StartupNotify=false
EOF
   report_ok "Shortcut GPU $mode creato con icona SVG"
 done
 if command -v gtk-update-icon-cache >/dev/null 2>&1; then gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true; fi
 if command -v kbuildsycoca6 >/dev/null 2>&1; then kbuildsycoca6 --noincremental >/dev/null 2>&1 || true; fi
 echo 'Se le icone non compaiono subito, chiudi e riapri il menu KDE oppure esci e rientra nella sessione.'
 echo 'Nel menu KDE: GPU · Intel, GPU · NVIDIA, GPU · Hybrid.'
 echo 'Questi shortcut salvano solo la preferenza per lean-gpu-run; NON commutano il desktop.'
 report_skip 'GPU: per-app via lean-gpu-run; non modifica sessione KDE, driver o MUX'
}
lean_gpu_mode(){
 say 'GPU: Intel / NVIDIA / Hybrid (PRIME, senza modifiche ai driver)'
 detect_hardware
 if (( ! HAS_NVIDIA_GPU )); then
   # Nessuna scelta interattiva sui portatili senza NVIDIA.
   # Non creare launcher PRIME né chiedere Intel/NVIDIA/Hybrid.
   local confdir="$HOME/.config/endeavouros-lean" conf
   conf="$confdir/gpu-mode"
   if (( HAS_INTEL_GPU )); then
     mkdir -p "$confdir"
     printf '%s\n' intel > "$conf"
     echo '[OK] GPU Intel rilevata: profilo Intel impostato automaticamente, nessuna domanda.'
     report_ok 'GPU Intel: selezione automatica (NVIDIA assente)'
   elif (( HAS_AMD_GPU )); then
     mkdir -p "$confdir"
     printf '%s\n' hybrid > "$conf"
     echo '[OK] GPU AMD rilevata: avvio standard senza PRIME NVIDIA; nessuna domanda.'
     report_ok 'GPU AMD: avvio standard (NVIDIA assente)'
   else
     warn 'Nessuna GPU riconosciuta: configurazione GPU saltata.'
     report_skip 'GPU: hardware sconosciuto'
   fi
   return 0
 fi
 echo 'Rilevamento GPU (sola lettura):'
 if command -v lspci >/dev/null 2>&1; then lspci | grep -Ei 'VGA compatible controller|3D controller|Display controller' || true; else echo 'lspci non disponibile'; fi
 if command -v nvidia-smi >/dev/null 2>&1; then nvidia-smi --query-gpu=name,driver_version --format=csv,noheader || true; fi
 echo 'Sessione:' "${XDG_SESSION_TYPE:-non disponibile}"
 cat <<'GPU_MENU'
 1) Intel integrata — preferenza per app compatibili (non spegne la NVIDIA)
 2) NVIDIA RTX (solo se rilevata) — avvio di singole applicazioni su NVIDIA con PRIME
 3) Hybrid (consigliata) — desktop invariato, NVIDIA su richiesta
 0) Annulla
GPU_MENU
 local choice confdir conf target tmp
 read -r -p 'Modalità GPU [3]: ' choice || return 0
 if (( HAS_NVIDIA_GPU )); then choice=${choice:-3}; else choice=${choice:-1}; fi
 case "$choice" in
  1) target=intel;;
  2) if (( ! HAS_NVIDIA_GPU )); then warn 'NVIDIA assente: selezione annullata'; return 0; fi; target=nvidia;;
  3) if (( HAS_NVIDIA_GPU )); then target=hybrid; else target=intel; fi;;
  0) report_skip 'Selezione GPU annullata'; return 0;;
  *) warn 'Selezione non valida'; return 0;;
 esac
 confdir="$HOME/.config/endeavouros-lean"
 conf="$confdir/gpu-mode"
 mkdir -p "$confdir" "$HOME/.local/bin"
 if [[ -e "$conf" ]] && [[ ! -f "$conf" ]]; then warn 'Percorso configurazione GPU non è un file regolare'; return 0; fi
 # Modalità per-app; nessun cambio globale del display manager o del driver.
 printf '%s\n' "$target" > "$conf"
 local launcher="$HOME/.local/bin/lean-gpu-run"
 if [[ -e "$launcher" ]] && ! grep -q '^# LEAN GPU RUN v29$' "$launcher"; then
   warn "Launcher $launcher preesistente e personalizzato: non lo sovrascrivo."
   report_warn 'GPU: configurazione salvata ma launcher personalizzato non modificato'
   return 0
 fi
 cat > "$launcher" <<'GPU_RUN'
#!/usr/bin/env bash
# LEAN GPU RUN v29
set -euo pipefail
modefile="$HOME/.config/endeavouros-lean/gpu-mode"
mode=$(cat "$modefile" 2>/dev/null || printf hybrid)
if (($# == 0)); then printf 'Uso: lean-gpu-run applicazione [argomenti]\n' >&2; exit 2; fi
case "$mode" in
 intel)
   # Preferenza Mesa: su alcuni sistemi/app la selezione effettiva dipende dal driver.
   exec env DRI_PRIME=0 __NV_PRIME_RENDER_OFFLOAD=0 "$@";;
 nvidia)
   if command -v prime-run >/dev/null 2>&1; then exec prime-run "$@"; fi
   printf 'prime-run assente: non posso garantire NVIDIA. Nessuna modifica eseguita.\n' >&2
   exit 1;;
 hybrid)
   # L'avvio standard non forza NVIDIA; usare lean-gpu-nvidia per PRIME.
   exec "$@";;
 *) printf 'Modalità GPU non valida: %s\n' "$mode" >&2; exit 1;;
esac
GPU_RUN
 chmod 755 "$launcher"
 local nvlauncher="$HOME/.local/bin/lean-gpu-nvidia"
 if [[ ! -e "$nvlauncher" ]]; then
 cat > "$nvlauncher" <<'GPU_NVIDIA'
#!/usr/bin/env bash
set -euo pipefail
if (($# == 0)); then echo 'Uso: lean-gpu-nvidia applicazione [argomenti]' >&2; exit 2; fi
if ! command -v prime-run >/dev/null 2>&1; then echo 'prime-run non disponibile; installare nvidia-prime dopo verifica dei driver.' >&2; exit 1; fi
exec prime-run "$@"
GPU_NVIDIA
 chmod 755 "$nvlauncher"
 fi
 echo "[OK] Preferenza salvata: $target"
 echo 'Per applicazione: ~/.local/bin/lean-gpu-run nome-app'
 echo 'Per forzare NVIDIA su un singolo programma: ~/.local/bin/lean-gpu-nvidia nome-app'
 if (( HAS_NVIDIA_GPU )); then echo 'Steam (gioco specifico): prime-run %command%'; fi
 echo 'Nota: il desktop KDE resta sulla configurazione GPU attuale.'
 echo 'Nota: Intel non disattiva fisicamente la RTX; NVIDIA non forza tutto Plasma sulla RTX.'
 if [[ "$target" == nvidia ]] && ! command -v prime-run >/dev/null 2>&1; then
   warn 'prime-run assente: modalità NVIDIA selezionata ma launcher non operativo finché non sarà disponibile.'
   report_warn 'GPU NVIDIA: manca prime-run'
 fi
 report_ok "GPU: preferenza applicazioni impostata su $target"
}
cat <<'INFO'

EndeavourOS KDE — installer LEAN v49 (percorso guidato predefinito + workspace vuoto)
- pacman > yay; installer ufficiale solo come scelta manuale quando necessario
- nessuna nuova Flatpak/Snap
- non tocca NVIDIA kernel/driver, OpenRazer, Plasma o Wayland
- installazioni automatiche; conferma solo per disinstallazioni e pulizia orfani/cache
- SOLO LibreOffice; ONLYOFFICE rimosso solo su conferma dopo verifica
- Ledger Nano X: wallet Linux via pacman/AUR se disponibile, regole USB dedicate
- Proton VPN: GUI + CLI da pacman, senza alterare configurazione di rete
- Claude Code: controlla il binario pacman prima di rimuovere un eventuale symlink npm in conflitto
- Firefox Cupertino: tema ufficialmente distribuito tramite Mozilla Add-ons; conferma nel browser
- VS Code + Claude Code + Codex, Docker Compose + GitHub, DeFi, PDF/OCR
- font KDE open source stile macOS e pulsanti finestra a sinistra, con backup di kdeglobals/kwinrc
- HomeBank (contabilita semplice), OBS, HandBrake, DBeaver, Bruno, Pandoc, guida foto iPhone e famiglia
- CUPS HP Color Laser 150mw/150nw, blocco KDE e audit LUKS (nessuna cifratura automatica)
- digiKam + darktable, Kdenlive, Google Keep/Gmail/Calendar/Tasks, Ollama con servizio locale e Open WebUI opzionale, diagnostica iPhone, audit backup
INFO
while true; do
 cat <<'MENU'

 B) PREDEFINITO — hardware > software > garbage > GitHub > installazione > pulizia (INVIO)
  0) Esci
  1) Inventario e preflight (sola lettura)
  2) Aggiornamento completo pacman -Syu
  3) Inventario/migrazione vecchie installazioni
  4) Calibre + LibreOffice + Bitwarden
  5) Steam + DualShock 4 + gaming
  6) AI CLI / sviluppo
  7) AI desktop (Chromium o Firefox, mai Brave)
  8) Cloud (Google Drive KDE, Dropbox, MEGA, pCloud)
  9) iPhone + KDE Connect
 10) Firefox + uBlock Origin
 11) Ripara conflitto Claude Code npm/pacman
 12) Tema Firefox macOS-like Cupertino
 13) Ledger Wallet / Nano X (USB + udev)
 14) Proton VPN (GUI + CLI)
 15) Docker + Compose + GitHub
 16) Wallet DeFi browser (guida)
 17) PDF avanzati, scansioni, OCR
 18) Fotografia RAW/ProRAW + Kdenlive
 19) Google Keep/Gmail/Calendar/Tasks
 20) Ollama locale + Open WebUI opzionale
 21) Diagnostica iPhone USB / KDE Connect LAN
 22) Audit sicurezza, backup, hardware
 23) Workspace vuoto + template generici
 24) Attiva servizi sviluppo (Docker/Ollama)
 25) Manutenzione LEAN: audit, orfani e cache
 26) Aspetto macOS: font e pulsanti finestre
 27) Monitoraggio hardware: installazione + audit
 28) SSD/cache: TRIM e pulizia conservativa
 29) Profili energetici: sola verifica
 30) Ledger USB: diagnostica e regole
 31) Rabby Wallet: guida ufficiale
 32) Tutte le nuove funzioni LEAN v10
 33) Produttività: HomeBank, video, API, famiglia
 34) Stampante HP + blocco KDE + audit LUKS
 35) Ripara icone shortcut Google e famiglia
 36) Stampante HP Color Laser 150mw: CUPS + test
 37) LibreOffice multi-monitor: backend GTK3
 38) Solo audit manutenzione (nessuna modifica)
 39) Tutte le sezioni (stesso percorso ordinato di B)
 40) Dropbox: integrazione KDE / Dolphin
 41) GPU: Intel / NVIDIA / Hybrid (selettore sicuro)
 42) Social media / messaggistica: Ferdium
 43) Crea shortcut KDE GPU Intel / NVIDIA / Hybrid
 44) Rileva hardware e profilo GPU (sola lettura)
 45) Virtualizzazione: QEMU/KVM, Virt-Manager, SPICE e USB (anche in B e 39)
 46) VM guidata: crea e avvia Windows 11 / Linux (macOS solo info)
 47) Ripara collegamento Virt-Manager nel menu KDE (senza reinstallare)
 48) Firefox: configura privacy avanzata (senza reinstallare tutto)
 49) Font compatibilità Microsoft / LibreOffice
 50) Google Docs, Sheets, Slides, Drive (Firefox)
 51) Tuta Mail (desktop se disponibile, altrimenti web)
 52) Audit hardware e pulizia conservativa
 53) AppFlowy: note, database e progetti (alternativa a Notion)
 54) Syncthing: installa, avvia e crea collegamento KDE
 55) Audit e pulizia sicura: dipendenze, orfani e cache
 56) GitHub: crea/verifica repository e sincronizza 4 file (script + 3 guide)
 57) OpenAI Codex CLI: installa/verifica (senza reinstallare la suite)
 58) Audit browser, elimina shortcut web LEAN precedenti e ricreali (Chromium > Firefox)
 Nota: il rilevamento hardware avviene automaticamente prima di ogni operazione
MENU
 read -r -p 'Scelta [B]: ' choice || break
 choice=${choice:-B}
 detect_hardware
 if [[ "$choice" != 0 ]]; then lean_browser_audit; fi
 if [[ "$HW_PROFILE" == unknown && "$choice" != 44 && "$choice" != 0 && "$choice" != 1 && "$choice" != 38 && "$choice" != 56 && "$choice" != 57 ]]; then
   warn 'Hardware grafico non identificato: per sicurezza disponibili solo audit (1, 38, 44) o uscita (0).'
   report_warn 'Azione bloccata: GPU sconosciuta'
   continue
 fi
 case "$choice" in
  [Bb]) lean_guided; break;;
  1) preflight;;
  2) update_system;;
  3) migration;;
  4) base_apps;;
  5) steam_setup;;
  6) ai_tools;;
  7) lean_firefox_replace_brave; lean_firefox_privacy_harden; ai_desktop;;
  8) cloud;;
  9) iphone;;
  10) privacy;;
  11) fix_claude_path;;
  12) firefox_macos_theme;;
  13) ledger_setup;;
  14) proton_vpn_setup;;
  15) docker_setup;;
  16) defi_setup;;
  17) pdf_ocr_setup;;
  18) photo_video;;
  19) google_workspace; lean_google_office;;
  20) ollama_local;;
  21) iphone_diagnostics;;
  22) security_audit;;
  23) development_environment;;
  24) enable_development_services;;
  25) maintenance;;
  26) macos_desktop_look;;
  27) lean_monitoring_install;;
  28) lean_ssd_maintenance;;
  29) lean_power_audit;;
  30) lean_ledger_usb_audit;;
  31) lean_rabby_guide;;
  32) lean_v10_all;;
  33) lean_v12_all;;
  34) lean_v18_all;;
  35) google_workspace; lean_family_setup;;
  36) lean_hp_printer_setup;;
  37) lean_libreoffice_gtk3;;
  38) maintenance_audit;;
  39) lean_guided;;
  40) dropbox_kde;;
  41) lean_gpu_mode;;
  42) lean_social_ferdium;;
  43) lean_gpu_shortcuts;;
  44) detect_hardware;;
  45) lean_vm_install;;
  46) lean_vm_wizard;;
  47) lean_vm_kde_launcher;;
  48) lean_firefox_privacy_harden;;
  49) lean_office_fonts;;
  50) lean_google_office;;
  51) lean_tuta_desktop;;
  52) lean_postinstall_review;;
  53) lean_appflowy;;
  54) lean_syncthing;;
  55) maintenance_audit; lean_safe_cleanup;;
  56) lean_github_repo;;
  57) install_repo nodejs npm; install_codex_cli;;
  58) lean_rebuild_web_shortcuts;;
  0) break;;
  *) echo 'Scelta non valida';;
 esac
done
echo "Log: $LOG"
echo "Il report finale verrà stampato e salvato in: $REPORT"
