#!/usr/bin/env bash
# EndeavourOS / Arch KDE - LEAN hardware-agnostic 2026-11-08
# Menu a 8 categorie (max 6 voci ciascuna) + percorso guidato B.
# Nessun modello di laptop presupposto: GPU Intel/NVIDIA/AMD (anche ibride) rilevate a ogni operazione.
# No automatic removal of personal data, drivers or desktop components.
# AUR builds are untrusted; check PKGBUILD independently before execution.
# Office: LibreOffice only. Installazioni automatiche; rimozioni con conferma.
set -Eeuo pipefail
IFS=$'\n\t'

if [[ $EUID -eq 0 ]]; then echo 'Esegui come utente normale, non con sudo.'; exit 1; fi
command -v pacman >/dev/null || { echo 'Richiesta una distribuzione basata su Arch (EndeavourOS, Arch, CachyOS, Manjaro, Garuda...) con pacman.'; exit 1; }
LEAN_DISTRO=$( . /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-Arch-based}" )


# Rilevamento hardware senza installare driver e senza interrogare Internet.
# /sys/bus/pci/devices è disponibile anche prima di installare pciutils.
HW_PROFILE=unknown
HAS_INTEL_GPU=0
HAS_NVIDIA_GPU=0
HAS_AMD_GPU=0
HAS_DGPU=0
HAS_IGPU=0
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
 # GPU dedicata: NVIDIA (qualsiasi iGPU) oppure AMD affiancata a Intel. GPU integrata: Intel, oppure AMD accanto a NVIDIA.
 HAS_DGPU=0; HAS_IGPU=0
 if (( HAS_NVIDIA_GPU )) || (( HAS_AMD_GPU && HAS_INTEL_GPU )); then HAS_DGPU=1; fi
 if (( HAS_INTEL_GPU )) || (( HAS_AMD_GPU && HAS_NVIDIA_GPU )); then HAS_IGPU=1; fi
 if (( HAS_NVIDIA_GPU && (HAS_INTEL_GPU || HAS_AMD_GPU) )); then HW_PROFILE=hybrid-nvidia
 elif (( HAS_NVIDIA_GPU )); then HW_PROFILE=nvidia
 elif (( HAS_AMD_GPU && HAS_INTEL_GPU )); then HW_PROFILE=hybrid-amd
 elif (( HAS_INTEL_GPU )); then HW_PROFILE=intel
 elif (( HAS_AMD_GPU )); then HW_PROFILE=amd
 else HW_PROFILE=unknown
 fi
 printf 'Hardware: %s | GPU Intel=%s NVIDIA=%s AMD=%s | profilo=%s\n' \
   "$HW_MODEL" "$HAS_INTEL_GPU" "$HAS_NVIDIA_GPU" "$HAS_AMD_GPU" "$HW_PROFILE"
}
detect_hardware

# Log e report in una cartella dedicata (mai nella radice della HOME).
# Sovrascrivibile con LEAN_LOG_DIR=/percorso prima di avviare lo script.
LEAN_LOG_DIR="${LEAN_LOG_DIR:-$HOME/EndeavourOS-LEAN/log}"
if ! mkdir -p -- "$LEAN_LOG_DIR" || [[ ! -w "$LEAN_LOG_DIR" ]]; then
  echo "Impossibile creare o scrivere la cartella log: $LEAN_LOG_DIR"; exit 1
fi
chmod 700 -- "$LEAN_LOG_DIR" 2>/dev/null || true
LOG="$LEAN_LOG_DIR/installer-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
echo "Cartella log e report: $LEAN_LOG_DIR"
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
   echo ' REPORT FINALE — ENDEAVOUROS LEAN repaired'
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
on_exit(){ local rc=$?; trap - EXIT; if [[ "${LEAN_QUICK_EXIT:-0}" != 1 ]]; then report_final "$rc"; fi; kill "${SUDO_KEEPALIVE_PID:-}" 2>/dev/null || true; }
trap 'on_error "$LINENO"' ERR
trap on_exit EXIT

# Sudo viene richiesto solo quando una funzione modifica il sistema.
# Nessun keepalive o password per il menu, audit, preflight e uscita rapida.


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
 say 'Aggiornamento completo Arch: conferma esplicita'
 warn 'pacman -Syu può aggiornare kernel, driver grafici, firmware e desktop; nessun pacchetto viene bloccato artificialmente.'
 if ! ask_explicit 'Autorizzi ORA pacman -Syu (inclusi eventuali driver/kernel)?'; then
   report_skip 'Aggiornamento non autorizzato: nessuna modifica'; return 2
 fi
 if ! sudo -n pacman -Syu --noconfirm; then
   report_fail 'Aggiornamento pacman -Syu fallito'; return 1
 fi
 updated=1
 report_ok 'Aggiornamento pacman -Syu completato'
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
 if [[ $updated -ne 1 ]]; then warn 'Per installare o aggiornare Steam esegui prima Sistema e manutenzione > Aggiornamento completo nella stessa sessione. Nessuna modifica.'; report_skip 'Steam: aggiornamento completo non autorizzato nella sessione'; return 0; fi
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
 fi
 # Stack Mesa/Vulkan per OGNI GPU rilevata (valido anche per configurazioni ibride Intel+AMD o AMD+NVIDIA).
 if (( HAS_INTEL_GPU )); then gpu_pkgs+=(vulkan-intel lib32-vulkan-intel); echo 'Intel: stack Mesa/Vulkan Intel.'; fi
 if (( HAS_AMD_GPU )); then gpu_pkgs+=(vulkan-radeon lib32-vulkan-radeon); echo 'AMD: stack Mesa/Vulkan Radeon.'; fi
 if (( ! HAS_INTEL_GPU && ! HAS_AMD_GPU && ! HAS_NVIDIA_GPU )); then
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
 if (( HAS_AMD_GPU && HAS_INTEL_GPU )); then echo 'Per usare la GPU AMD dedicata in Steam: DRI_PRIME=1 %command%.'; fi
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
# LibreOffice: GTK3 risolve lo scaling misto su configurazioni multi-monitor con DPI diversi.
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
 say 'AppFlowy: verifica e installazione desktop nativa AUR'
 if has_pkg appflowy-bin || has_pkg appflowy; then
   report_ok 'AppFlowy: già installato'
 else
   if ! command -v yay >/dev/null 2>&1; then
     report_fail 'AppFlowy: yay non disponibile; installare yay e riprovare'
     return 1
   fi
   if ask 'Installare AppFlowy tramite yay (appflowy-bin)?'; then
     if ! yay -S --needed appflowy-bin; then
       report_fail "AppFlowy: installazione AUR fallita; controllare log $LOG"
       return 1
     fi
   else
     report_skip 'AppFlowy: installazione rifiutata'; return 0
   fi
 fi
 if ! has_pkg appflowy-bin && ! has_pkg appflowy; then
   report_fail 'AppFlowy: pacchetto assente dopo installazione'; return 1
 fi
 local desktop found=0
 for desktop in /usr/share/applications/*[Aa]pp[Ff]lowy*.desktop "$HOME"/.local/share/applications/*[Aa]pp[Ff]lowy*.desktop; do
   [[ -f "$desktop" ]] && { found=1; break; }
 done
 if (( found )); then report_ok "AppFlowy: launcher nativo presente ($desktop)"
 else report_warn 'AppFlowy: pacchetto presente, launcher nativo non individuato'; fi
 if command -v kbuildsycoca6 >/dev/null 2>&1; then kbuildsycoca6 --noincremental >/dev/null 2>&1 || true; fi
}

lean_appflowy_report(){
 echo
 echo 'APPFLOWY — WORKSPACE / NOTE'
 if has_pkg appflowy-bin || has_pkg appflowy; then
   echo '  [OK] Pacchetto AppFlowy installato'
 else
   echo '  [DA FARE] AppFlowy non installato: Ufficio e produttività > AppFlowy (AUR con consenso)'
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
 # Disabilitata: la vecchia routine archiviava tutti i launcher LEAN a ogni passaggio.
 # I generatori aggiornano in loco soltanto i rispettivi file gestiti.
 report_ok 'Launcher LEAN conservati: nessuna pulizia automatica'
}

# KMenuEdit puo' includere/escludere esplicitamente vecchi launcher.
# Non alterare mai automaticamente il menu personalizzato: avvisa e mostra
# la diagnostica, cosi' le categorie restano sotto controllo dell'utente.
lean_kde_menu_diagnostic(){
 local menu="$HOME/.config/menus/applications-kmenuedit.menu"
 [[ -f "$menu" ]] || return 0
 if grep -Eqi '(<Filename>(ai-gemini-ai|Gemini|lean-google-drive)\.desktop</Filename>)' "$menu"; then
   warn 'Menu KDE personalizzato: possibili regole Include/Exclude su Gemini/Drive.'
   echo "  [INFO] Non modifico $menu"
   echo '  [INFO] Se il menu nasconde un launcher, controlla con: grep -ni -C 4 -i gemini ~/.config/menus/applications-kmenuedit.menu'
   report_warn 'KMenuEdit: verificare eventuali regole personalizzate di esclusione/inclusione'
 fi
}

lean_verify_web_shortcuts(){
 local dir="$HOME/.local/share/applications" f n=0 failures=0
 local -a expected=(
  ai-chatgpt-ai ai-claude-ai ai-gemini-ai ai-grok-ai ai-perplexity-ai ai-ollama-ai
  ai-copilot-ai ai-manus-ai ai-mistral-ai
  google-calendar google-gmail google-keep google-tasks
  lean-google-docs lean-google-drive lean-google-sheets lean-google-slides
 )
 for f in "${expected[@]}"; do
   if [[ ! -f "$dir/$f.desktop" ]]; then
     if [[ "$f" == ai-gemini-ai && -f "$dir/Gemini.desktop" ]]; then
       echo '[INFO] Gemini personalizzato presente: Gemini.desktop'
       n=$((n+1))
       continue
     fi
     echo "[ERRORE] Manca $f.desktop"; failures=$((failures+1)); continue
   fi
   if command -v desktop-file-validate >/dev/null 2>&1; then
     if ! desktop-file-validate "$dir/$f.desktop"; then failures=$((failures+1)); fi
   fi
   n=$((n+1))
 done
 printf 'Shortcut verificati: %d/17; errori: %d\n' "$n" "$failures"
 if (( failures > 0 || n != 17 )); then report_fail 'Verifica shortcut KDE non superata'; return 1; fi
 report_ok '17 shortcut KDE verificati: 9 LLM, 4 Google Internet e 4 Office'
}

# Migrazione opzionale dei vecchi launcher Gemini web (mai eliminati).
# Il nome del file puo' essere arbitrario; la URL identifica il collegamento web.
lean_gemini_legacy_migration(){
 local appdir="$HOME/.local/share/applications" file basename backup_dir moved=0
 local managed="$appdir/ai-gemini-ai.desktop"
 backup_dir="$HOME/.local/share/endeavouros-lean/backups/gemini-$(date +%Y%m%d-%H%M%S)"
 while IFS= read -r -d '' file; do
   [[ "$file" == "$managed" ]] && continue
   # Non toccare Gemini CLI, altri programmi o launcher senza URL web di Gemini.
   if ! grep -Eq '^(Exec|URL)=.*(https?://)?gemini\.google\.com([/ ?]|$)' "$file"; then continue; fi
   basename=${file##*/}
   echo "[DUPLICATO] $file"
   grep -E '^(Name|Exec|Categories)=' "$file" || true
   if ask_explicit "Archiviare questo vecchio launcher Gemini (backup, non cancellazione)?"; then
     mkdir -p "$backup_dir"
     if [[ -e "$backup_dir/$basename" ]]; then
       warn "Backup già presente: $backup_dir/$basename; nessuna modifica"
       continue
     fi
     mv -- "$file" "$backup_dir/$basename"
     echo "[BACKUP] $backup_dir/$basename"
     moved=$((moved+1))
   else
     warn "Conservato: $file; Gemini potrebbe ancora comparire in Internet"
   fi
 done < <(find "$appdir" -maxdepth 1 -type f -name '*.desktop' -print0 2>/dev/null)
 if (( moved > 0 )); then
   report_ok "Gemini: $moved vecchi launcher web archiviati in $backup_dir"
 else
   echo '[INFO] Nessun vecchio launcher Gemini spostato.'
 fi
 # Menu KMenuEdit: mai modificato automaticamente.
 if [[ -f "$HOME/.config/menus/applications-kmenuedit.menu" ]]; then
   echo '[INFO] Menu KMenuEdit personalizzato presente: potrebbe mantenere una voce Gemini in Internet.'
 fi
}

lean_rebuild_web_shortcuts(){
 say 'KDE: aggiornamento non distruttivo dei 17 collegamenti web'
 lean_browser_audit
 if ! lean_shortcut_browser >/dev/null 2>&1; then
   report_fail 'Chromium/Firefox assenti: shortcut non aggiornati'
   return 1
 fi
 # Nessuna archiviazione/rimozione dei launcher esistenti.
 ai_desktop
 lean_google_office
 google_workspace
 lean_verify_web_shortcuts || return 1
 lean_gemini_menu_audit
 echo "[PRESERVATO] Nessuna migrazione/archiviazione dei launcher Gemini"
 lean_kde_menu_diagnostic
 # Non cancellare o rinominare launcher preesistenti: segnala i potenziali duplicati.
 local old
 for old in "$HOME"/.local/share/applications/lean-web-{chatgpt,claude,gemini,perplexity,grok,copilot,manus,mistral,ollama}.desktop; do
   if [[ -f "$old" ]]; then
     warn "Possibile duplicato storico conservato: $old (verificare manualmente con KMenuEdit)"
   fi
 done
 if command -v kbuildsycoca6 >/dev/null 2>&1; then
   kbuildsycoca6 --noincremental || report_warn 'Cache KDE non aggiornata'
 fi
 report_ok "Shortcut KDE aggiornati con $(lean_shortcut_browser)"
}

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
 say 'Tuta Desktop: installazione AUR e verifica launcher nativo'
 local pkg='' candidate entry desktop_id='' legacy="$HOME/.local/share/applications/lean-tuta-mail.desktop"
 for candidate in tutanota-desktop-bin tutanota-desktop tuta-desktop; do
   if has_pkg "$candidate"; then pkg="$candidate"; break; fi
 done
 if [[ -z "$pkg" ]]; then
   if ! command -v yay >/dev/null 2>&1; then
     report_fail 'Tuta: yay non disponibile'; return 1
   fi
   # L'installazione viene effettivamente tentata: yay -Si non e' affidabile
   # come prerequisito quando i metadati AUR non sono in cache.
   for candidate in tutanota-desktop-bin tutanota-desktop; do
     echo "Tentativo AUR: $candidate"
     if yay -S --needed "$candidate" && has_pkg "$candidate"; then
       pkg="$candidate"; break
     fi
     warn "Tuta: tentativo $candidate non riuscito"
   done
   if [[ -z "$pkg" ]]; then
     report_fail 'Tuta: installazione AUR non riuscita; consultare il log'; return 1
   fi
 fi
 while IFS= read -r entry; do
   [[ "$entry" == /usr/share/applications/*.desktop && -f "$entry" ]] || continue
   desktop_id="${entry##*/}"
   break
 done < <(pacman -Qlq "$pkg" 2>/dev/null || true)
 if [[ -z "$desktop_id" ]]; then
   report_warn "Tuta: $pkg installato ma launcher non rilevato tramite pacman -Ql"
 else
   report_ok "Tuta desktop nativo: $pkg ($desktop_id)"
 fi
 if [[ -f "$legacy" && ! -L "$legacy" ]] && grep -qx 'X-EndeavourOS-LEAN-Managed=true' "$legacy"; then
   local backup_dir="$HOME/.local/share/endeavouros-lean/launcher-backups"
   mkdir -p "$backup_dir" || return 1
   mv -- "$legacy" "$backup_dir/lean-tuta-mail-$(date +%Y%m%d%H%M%S)-$$.desktop" || return 1
 fi
 command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
}

lean_google_office(){
 lean_google_icons
 say 'Google Docs / Sheets / Slides / Drive: browser installato (Chromium > Firefox (Brave escluso))'
 local browser
 browser=$(lean_shortcut_browser || true)
 if [[ -z "$browser" ]]; then report_warn 'Google Workspace: nessun browser disponibile'; return 0; fi
 local dir="$HOME/.local/share/applications" key title url icon cmd
 mkdir -p "$dir"
 while IFS='|' read -r key title url icon; do
  local desktop="$dir/lean-google-${key}.desktop"
  if [[ -e "$desktop" ]] && ! grep -q '^X-EndeavourOS-LEAN-Managed=true$' "$desktop"; then
    report_skip "Google $title: launcher personalizzato conservato"; continue
  fi
  cmd=$(lean_shortcut_exec "$browser" "$url")
  if [[ "$key" == drive ]]; then icon="$HOME/.local/share/icons/endeavouros-lean/drive.svg"; fi
  cat > "$desktop" <<EOFGO
[Desktop Entry]
Type=Application
Name=Google $title
Comment=Google Workspace online ($browser)
Exec=$cmd
Icon=$icon
Terminal=false
Categories=Office;
X-EndeavourOS-LEAN-Managed=true
EOFGO
  report_ok "Google $title: launcher KDE creato"
 done <<'GOOGLEOFFICE'
docs|Docs|https://docs.google.com/document/|x-office-document
sheets|Sheets|https://docs.google.com/spreadsheets/|x-office-spreadsheet
slides|Slides|https://docs.google.com/presentation/|x-office-presentation
drive|Drive|https://drive.google.com/|folder-remote
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
  echo 'Cache pacman: nessuna pulizia eseguita; usa Sistema e manutenzione > Manutenzione per pulizia con conferma';
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
lean_gemini_cli(){
 say 'Google Gemini CLI: installazione o verifica pacman/yay'
 if command -v gemini >/dev/null 2>&1; then
   echo "[OK] Gemini CLI già presente: $(command -v gemini)"
   gemini --version || report_warn 'Gemini CLI presente ma versione non verificabile'
   report_ok 'Gemini CLI già installato'
   return 0
 fi
 if ! has_pkg gemini-cli && ! has_repo gemini-cli && ! command -v yay >/dev/null 2>&1; then
   report_warn 'Gemini CLI non disponibile: pacman/yay assenti o pacchetto non trovato'
   return 0
 fi
 echo 'Gemini CLI è un client distinto dal collegamento web Gemini.'
 echo 'L’installazione può richiedere download e compilazione da AUR.'
 if ! ask_explicit 'Installare Gemini CLI ora?'; then
   report_skip 'Gemini CLI: installazione non autorizzata'
   return 0
 fi
 install_fallback gemini-cli gemini-cli
 if command -v gemini >/dev/null 2>&1; then
   gemini --version || true
   report_ok 'Gemini CLI disponibile; autenticazione da completare al primo avvio'
   echo 'Avvio: gemini'
 else
   report_warn 'Gemini CLI non disponibile dopo tentativo: verificare repository/AUR'
 fi
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
 cat > "$dir/ollama.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#242424"/><path d="M14 46V25c0-10 8-17 18-17s18 7 18 17v21" fill="none" stroke="#fff" stroke-width="5" stroke-linecap="round"/><circle cx="25" cy="29" r="3" fill="#fff"/><circle cx="39" cy="29" r="3" fill="#fff"/><path d="M26 39q6 5 12 0" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round"/></svg>
SVG
 cat > "$dir/perplexity.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#102c34"/><g fill="none" stroke="#48c7c4" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"><path d="M17 19h30v28H17zM17 19l15-10 15 10M17 19l15 17 15-17M32 9v46M17 47l15-11 15 11M10 29h7m30 0h7"/></g></svg>
SVG
 cat > "$dir/copilot.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><defs><linearGradient id="c" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#12a5f4"/><stop offset=".55" stop-color="#6656df"/><stop offset="1" stop-color="#f29c54"/></linearGradient></defs><rect width="64" height="64" rx="14" fill="#111827"/><path d="M13 38c0-14 10-25 23-25 10 0 18 7 18 16 0 11-9 21-21 21H18c-4 0-6-5-5-12Zm11-1c5 3 10 3 15 0" fill="none" stroke="url(#c)" stroke-width="9" stroke-linecap="round"/></svg>
SVG
 cat > "$dir/manus.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#101828"/><path d="M13 47V17l19 22 19-22v30" fill="none" stroke="#fff" stroke-width="7" stroke-linejoin="round" stroke-linecap="round"/><circle cx="32" cy="17" r="4" fill="#8fd5ff"/></svg>
SVG
 cat > "$dir/mistral.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#fff8ef"/><path fill="#f15a24" d="M10 15h12v8h7v8h6v-8h7v-8h12v34H42V37h-7v7h-6v-7h-7v12H10z"/></svg>
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
     if ask_explicit "Rimuovere davvero $pkg? Profili e dati resteranno sul disco" && sudo -n pacman -R --noconfirm "$pkg"; then
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

lean_llm_kde_submenu(){
 # La struttura creata manualmente in KMenuEdit ha precedenza.
 if [[ -f "$HOME/.config/menus/applications-kmenuedit.menu" ]]; then
   echo '[PRESERVATO] Menu KMenuEdit attivo: nessun sottomenu LLM aggiuntivo generato.'
   return 0
 fi
 # Menu KDE separato, senza modificare applications-kmenuedit.menu.
 local menu_dir="$HOME/.config/menus/applications-merged"
 local directory_dir="$HOME/.local/share/desktop-directories"
 mkdir -p "$menu_dir" "$directory_dir"
 local menu="$menu_dir/endeavouros-lean-llm.menu"
 local dirfile="$directory_dir/endeavouros-lean-llm.directory"
 # Non sovrascrivere file con lo stesso nome se non gestiti da LEAN.
 if [[ -f "$menu" ]] && ! grep -q 'EndeavourOS-LEAN-Managed' "$menu"; then
   warn "Menu personalizzato non gestito: $menu"; return 1
 fi
 if [[ -f "$dirfile" ]] && ! grep -q '^X-EndeavourOS-LEAN-Managed=true$' "$dirfile"; then
   warn "Directory KDE personalizzata non gestita: $dirfile"; return 1
 fi
 cat > "$dirfile" <<'DIRECTORY'
[Desktop Entry]
Type=Directory
Name=Intelligenza Artificiale
Comment=LLM cloud e locali
Icon=applications-science
X-EndeavourOS-LEAN-Managed=true
DIRECTORY
 cat > "$menu" <<'MENUXML'
<!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN" "http://www.freedesktop.org/standards/menu-spec/menu-1.0.dtd">
<!-- EndeavourOS-LEAN-Managed: KDE AI submenu -->
<Menu>
 <Name>Applications</Name>
 <Menu>
  <Name>EndeavourOS-LEAN-LLM</Name>
  <Directory>endeavouros-lean-llm.directory</Directory>
  <Include><Category>X-EndeavourOS-LEAN-LLM</Category></Include>
  <Layout><Merge type="menus"/><Merge type="files"/></Layout>
 </Menu>
</Menu>
MENUXML
 if command -v kbuildsycoca6 >/dev/null 2>&1; then kbuildsycoca6 --noincremental >/dev/null 2>&1 || true; fi
 echo '[OK] Sottomenu KDE: Intelligenza Artificiale (9 LLM, cloud + Open WebUI)'
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
   # Gemini e' stato personalizzato in KMenuEdit: non sovrascriverlo MAI.
   # Questo vale anche per file creati in passato da LEAN.
   if [[ "$key" == gemini && ( -f "$file" || -f "$appdir/Gemini.desktop" ) ]]; then
     echo "[PRESERVATO] Gemini esistente e menu KMenuEdit: $file"
     continue
   fi
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
Categories=X-EndeavourOS-LEAN-LLM;
StartupNotify=true
X-EndeavourOS-LEAN-Managed=true
EOF
   echo "[OK] $title con icona -> $file"
 done <<'AI_APPS'
chatgpt|ChatGPT|https://chatgpt.com
claude|Claude|https://claude.ai
gemini|Gemini|https://gemini.google.com
ollama|Ollama (Open WebUI)|http://127.0.0.1:8080
perplexity|Perplexity|https://www.perplexity.ai
copilot|Microsoft Copilot|https://copilot.microsoft.com
manus|Manus AI|https://manus.im
mistral|Mistral Le Chat|https://chat.mistral.ai
grok|Grok|https://grok.com
AI_APPS
 lean_llm_kde_submenu || warn "Sottomenu LLM non creato"
 lean_gemini_menu_audit
 if command -v kbuildsycoca6 >/dev/null 2>&1; then kbuildsycoca6 --noincremental >/dev/null 2>&1 || true; fi
}


# Gemini puo' apparire in un'altra categoria se esiste un vecchio launcher
# indipendente. Non cancellare o alterare collegamenti non gestiti da LEAN.
lean_gemini_menu_audit(){
 local appdir="$HOME/.local/share/applications" file managed="$appdir/ai-gemini-ai.desktop"
 if [[ ! -f "$managed" ]]; then
   report_warn 'Gemini: launcher LEAN non presente; eventuale launcher KMenuEdit preservato'
   return 0
 fi
 echo '[INFO] Gemini: categoria e posizione definite dall’utente in KMenuEdit; nessuna riscrittura.'
 grep -E '^(Name|Exec|Categories|NoDisplay|Hidden)=' "$managed" || true
 # La categoria Network e' legittima per un launcher spostato tramite KMenuEdit.
 # Non segnalarla come errore e non imporre ArtificialIntelligence (non standard).
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
iphone(){ say 'Smartphone / KDE Connect (iPhone via libimobiledevice, Android via KDE Connect/MTP)'; install_repo kdeconnect libimobiledevice usbmuxd libplist libusbmuxd gphoto2 usbutils; install_fallback ifuse ifuse; echo 'USB iPhone: sblocca il telefono e conferma Autorizza. KDE Connect usa rete LAN/Wi-Fi, non USB diretto, su iOS e Android.'; }
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
         if ask_explicit "Autorizzi installazione AUR di $pkg dopo verifica PKGBUILD?"; then yay -S --needed "$pkg"; fi
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
 echo 'Directory grandi in home (primi 10 elementi):'; du -sh "$HOME"/{Downloads,.cache,Projects} 2>/dev/null || true
 echo 'ATTENZIONE: pacman -Qm NON indica pacchetti inutili; include i pacchetti AUR desiderati.'
 echo 'ATTENZIONE: non esiste un modo affidabile per riconoscere software in disuso senza revisione manuale.'
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
 pacman -Q nvidia-utils nvidia-open mesa vulkan-intel vulkan-radeon steam claude-code docker ollama ollama-cuda ollama-rocm kdeconnect libimobiledevice 2>/dev/null || true
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
   local file="$appdir/google-${key}.desktop"
   if [[ -e "$file" ]] && ! grep -qx 'X-EndeavourOS-LEAN-Managed=true' "$file"; then
     report_skip "Google $name: launcher personale conservato ($file)"
     continue
   fi
   cat > "$file" <<EOFGOOGLE
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
 local dir file
 dir='/etc/systemd/system/ollama.service.d'
 file="${dir}/10-endeavouros-lean.conf"
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
 say 'Open WebUI: verifica installazione esistente (porta 8080)'
 local url='http://127.0.0.1:8080' dir="$HOME/.config/endeavouros-lean/open-webui" file
 # Non avviare una seconda istanza: l'utente ha gia Open WebUI in Docker Compose.
 if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 5 "$url/" -o /dev/null; then
   echo "[OK] Open WebUI gia raggiungibile: $url (nessuna modifica a container o volumi)"
   report_ok 'Open WebUI esistente sulla porta 8080 conservato'
   return 0
 fi
 if ! has_pkg docker || ! command -v docker >/dev/null 2>&1; then
   warn 'Docker non disponibile: GUI non configurata.'; return 0
 fi
 mkdir -p "$dir"
 file="$dir/compose.yaml"
 if [[ -e "$file" ]]; then
   echo "[OK] Configurazione gia esistente: $file (non sovrascritta)."
   echo '[INFO] Verificare eventuali vecchie porte 3000 nel compose prima di avviarlo.'
 else
   cat > "$file" <<'COMPOSE'
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main-slim
    restart: unless-stopped
    network_mode: host
    environment:
      OLLAMA_BASE_URL: http://127.0.0.1:11434
      HOST: 127.0.0.1
      PORT: '8080'
    volumes:
      - open-webui-data:/app/backend/data
volumes:
  open-webui-data:
COMPOSE
   echo "[OK] File Compose preparato: $file (non avviato)."
 fi
 echo "GUI prevista: $url"
 echo '[SICUREZZA] Avvio manuale soltanto dopo verifica dei container e dei volumi esistenti.'
 echo "  cd '$dir' && sudo docker compose config"
 echo '  sudo docker ps -a --filter name=open-webui'
 echo '[INFO] LEAN non crea/avvia automaticamente un container duplicato.'
}

lean_tangram(){
 say 'Tangram: aggregatore web LLM separato da Ferdium (senza API)'
 if has_pkg tangram; then
   report_ok 'Tangram gia installato: nessuna reinstallazione'
 elif ! ask_explicit 'Installare Tangram dai repository ufficiali Arch (pacman)?'; then
   report_skip 'Tangram: installazione non autorizzata'; return 0
 else
   # Aggiornamento completo per evitare installazioni parziali su Arch.
   if ! sudo -v || ! sudo pacman -Syu --needed tangram || ! has_pkg tangram; then
     report_fail 'Installazione Tangram non riuscita o interrotta'; return 1
   fi
   report_ok 'Tangram installato con pacman (aggiornamento completo)'
 fi
 echo 'Apri Tangram dal menu KDE e aggiungi queste applicazioni web:'
 echo '  ChatGPT: https://chatgpt.com'
 echo '  Claude:  https://claude.ai'
 echo '  Gemini:  https://gemini.google.com'
 echo '  Ollama:  http://127.0.0.1:8080'
 echo '  Copilot: https://copilot.microsoft.com'
 echo '  Perplexity: https://www.perplexity.ai'
 echo '  Manus: https://manus.im'
 echo '  Mistral: https://chat.mistral.ai'
 echo '  Grok:    https://grok.com'
 echo 'Ferdium resta dedicato alle chat social; nessuna chiave API richiesta.'
}

lean_missing_cloud_llms(){
 say 'LLM cloud: Copilot, Manus, Mistral Le Chat e Grok'
 local exe appdir icondir key title url file cmd
 exe=$(lean_shortcut_browser || true)
 if [[ -z "$exe" ]]; then warn 'Firefox/Chromium non disponibile: nessun launcher creato'; return 1; fi
 appdir="$HOME/.local/share/applications"
 icondir="$HOME/.local/share/icons/endeavouros-lean"
 mkdir -p "$appdir"
 lean_ai_icons
 while IFS='|' read -r key title url; do
   file="$appdir/ai-${key}-ai.desktop"
   if [[ -f "$file" ]] && ! grep -q '^X-EndeavourOS-LEAN-Managed=true$' "$file"; then
     warn "Launcher preesistente non gestito, preservato: $file"
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
Categories=X-EndeavourOS-LEAN-LLM;
StartupNotify=true
X-EndeavourOS-LEAN-Managed=true
EOF
   echo "[OK] $title: $file"
 done <<'CLOUD_APPS'
copilot|Microsoft Copilot|https://copilot.microsoft.com
manus|Manus AI|https://manus.im
mistral|Mistral Le Chat|https://chat.mistral.ai
grok|Grok|https://grok.com
CLOUD_APPS
 lean_llm_kde_submenu || warn "Sottomenu LLM non creato"
 if command -v kbuildsycoca6 >/dev/null 2>&1; then kbuildsycoca6 --noincremental || true; fi
 echo 'I quattro servizi cloud sono link web: non richiedono modelli Ollama né API.'
 echo 'Tangram: aggiungi manualmente Copilot, Manus, Mistral e Grok; non altero il profilo o le sessioni.'
}

lean_ollama_models(){
 say 'LLM locali: inventario e download opzionale dei modelli mancanti'
 if ! command -v ollama >/dev/null 2>&1; then
   warn 'Ollama non installato: utilizzare prima Intelligenza artificiale > Ollama locale.'; return 1
 fi
 if ! curl -fsS --max-time 4 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
   warn 'Servizio Ollama non raggiungibile su 127.0.0.1:11434. Verifica: systemctl status ollama'; return 1
 fi
 echo 'Modelli gia presenti:'
 ollama list || return 1
 local ram_mib; ram_mib=$(( $(awk '/MemTotal:/{print $2}' /proc/meminfo) / 1024 ))
 echo "Profilo conservativo per questo PC: RAM ${ram_mib} MiB, GPU dedicata=${HAS_DGPU} (profilo $HW_PROFILE)."
 if command -v nvidia-smi >/dev/null 2>&1; then nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || true; fi
 echo 'I modelli grandi possono esaurire VRAM/RAM o rallentare il sistema: i 4 proposti restano sotto i 4B parametri.'
 local model free_kb
 free_kb=$(df -Pk "$HOME" | awk 'NR==2 {print $4}')
 if [[ ! "$free_kb" =~ ^[0-9]+$ ]] || (( free_kb < 6291456 )); then
   warn 'Meno di 6 GiB liberi (o spazio non determinabile): nessun download automatico.'; return 1
 fi
 # Nessun pull non richiesto; evitare download duplicati.
 for model in 'qwen3:4b' 'qwen2.5-coder:1.5b' 'llama3.2:3b' 'gemma3:4b'; do
   if ollama list | awk 'NR>1 {print $1}' | grep -Fxq "$model"; then
     echo "[PRESENTE] $model"; continue
   fi
   echo "[MANCANTE] $model"
   if ask_explicit "Scaricare $model da Ollama (download di diversi GB, possibile uso CPU)?"; then
     if ollama pull "$model"; then
       report_ok "Modello Ollama scaricato: $model"
     else
       report_fail "Download modello non riuscito: $model"
     fi
   else
     report_skip "Modello non scaricato: $model"
   fi
 done
 echo 'Verifica finale: ollama list'
 ollama list
 echo 'Test manuale: ollama run qwen3:4b'
 echo 'In Open WebUI (http://127.0.0.1:8080) aggiorna la lista modelli.'
 echo 'Non sono stati modificati container, password, database o configurazioni NVIDIA.'
}

ollama_local(){
 say 'LLM locali: Ollama + CUDA NVIDIA + servizio locale + GUI opzionale'
 # Una nuova invocazione dello script azzera updated. Se Ollama e gia installato,
 # la voce Ollama locale puo configurare il servizio senza installare pacchetti o aggiornare il sistema.
 # Per installare nuovi pacchetti, invece, e necessario un -Syu autorizzato nella sessione.
 if ! has_pkg ollama; then
   if [[ $updated -ne 1 ]]; then
     warn 'Ollama assente: esegui prima Sistema e manutenzione > Aggiornamento completo, poi questa voce nella stessa sessione.'
     report_skip 'Ollama non installato; nessun aggiornamento parziale eseguito'
     return 0
   fi
   install_repo ollama
 fi
 if ! has_pkg ollama; then warn 'Ollama non installato.'; return 0; fi
 detect_hardware
 if (( HAS_NVIDIA_GPU )) && has_pkg nvidia-utils && command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; then
   if has_pkg ollama-cuda; then
     echo '[OK] ollama-cuda gia installato: nessuna modifica ai driver NVIDIA.'
   elif [[ $updated -eq 1 ]]; then
     if has_repo ollama-cuda; then install_repo ollama-cuda; else warn 'ollama-cuda non disponibile: controlla supporto GPU.'; fi
   else
     warn 'ollama-cuda assente: non installo pacchetti senza aggiornamento completo autorizzato; configurazione Ollama esistente consentita.'
   fi
 elif (( HAS_AMD_GPU )) && has_repo ollama-rocm; then
   if has_pkg ollama-rocm; then echo '[OK] ollama-rocm gia installato: nessuna modifica ai driver AMD.'
   elif [[ $updated -eq 1 ]] && ask_explicit 'GPU AMD rilevata: installare ollama-rocm? (ROCm supporta solo alcune GPU; in caso contrario Ollama usa la CPU)'; then install_repo ollama-rocm
   else warn 'ollama-rocm non installato: Ollama usera la CPU finche non sara autorizzato dopo un aggiornamento completo.'; fi
 else warn 'GPU dedicata NVIDIA/AMD supportata non rilevata: possibile uso CPU.'; fi
 configure_ollama_service
 prepare_openwebui
 echo 'Ollama: un modello alla volta, contesto iniziale 4096, API solo su 127.0.0.1.'
 echo 'Per coding locale, scarica esplicitamente un modello piccolo con: ollama pull qwen2.5-coder:1.5b'
 if (( HAS_NVIDIA_GPU )); then echo 'Verifica GPU: watch -n 1 nvidia-smi'
 elif has_pkg ollama-rocm; then echo 'Verifica GPU AMD: rocm-smi oppure journalctl -u ollama'
 else echo 'Ollama: CPU; nessun driver CUDA/ROCm installato.'; fi
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
 echo 'KDE Connect usa LAN, NON cavo USB diretto. Telefono e computer sulla stessa rete, non rete ospiti.'
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
 say 'Cartella Projects e template generici: NESSUN progetto creato'
 # ~/Projects: creata solo se assente; se esiste non viene toccata (nessun file aggiunto o sovrascritto).
 local root="${LEAN_PROJECTS_DIR:-$HOME/Projects}" templates="$HOME/.config/endeavouros-lean/templates"
 if [[ -d "$root" ]]; then
   echo "[CONSERVATO] $root (esistente, nessuna modifica)"
 elif [[ -e "$root" ]]; then
   warn "$root esiste ma non è una cartella: nessuna modifica."
   report_warn "Projects: percorso $root occupato da un file"
 else
   mkdir -p -- "$root" && chmod 700 -- "$root" 2>/dev/null || true
   echo "[CREATO] $root"
   report_ok "Cartella progetti creata: $root"
 fi
 mkdir -p -- "$templates"
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
Quando decidi il nome di un progetto, crea una cartella in ~/Projects e inizializza Git.
Copia soltanto i modelli che servono, rinomina pyproject.toml e personalizza i workflow.
Le configurazioni Claude e VS Code sono suggerimenti per singoli progetti, NON permessi globali.
GitHub: `gh auth login`, poi `gh repo create NOME --private` solo su richiesta.
Python: `uv sync --dev`; Node: `npm install` nel progetto, mai npm globale per gli agenti.
Docker Compose richiede segreti .env e non viene avviato automaticamente.
Backup restic: configura repository e password fuori dallo script; nessun backup parte da solo.
EOF
 echo "[OK] Cartella progetti: $root"
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
 echo 'Per VS Code: apri ~/Projects con code ~/Projects (nessun progetto creato).'
 echo 'Per GitHub: gh auth login; crea repository PRIVATO manualmente.'
 echo 'Docker non viene abilitato implicitamente: Sviluppo > Attiva servizi per attivazione esplicita.'
}

enable_development_services(){
 say 'Servizi sviluppo: Docker (privilegiato) e Ollama (locale)'
 if has_pkg ollama; then
   if systemctl list-unit-files ollama.service --no-legend 2>/dev/null | grep -q '^ollama.service'; then
     sudo -n systemctl enable --now ollama.service
     systemctl is-active ollama.service || true
   fi
 else echo 'Ollama non installato: usa Intelligenza artificiale > Ollama locale dopo aggiornamento.'; fi
 if has_pkg docker; then
   warn 'Docker daemon equivale a servizio con privilegi elevati. Non aggiungo utente al gruppo docker.'
   if ask 'Abilitare Docker all’avvio e avviarlo ora?'; then
     sudo -n systemctl enable --now docker.service
     systemctl is-active docker.service || true
   else echo 'Docker lasciato invariato.'; fi
 else echo 'Docker non installato: usa Sviluppo > Docker.'; fi
 echo 'PostgreSQL e Redis NON partono senza .env e scelta esplicita.'
}


# v10: diagnostica hardware, manutenzione SSD, profili energetici e Ledger/Rabby.
# Nessun intervento sui driver, sul bootloader o sul sistema grafico.
lean_hardware_audit(){
 say 'LEAN v10 — inventario CPU, GPU, SSD, batteria e spazio'
 echo '--- GPU ---'
 command -v lspci >/dev/null && lspci | grep -Ei 'vga|3d|display' || true
 command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=name,memory.total,temperature.gpu --format=csv,noheader || true
 command -v rocm-smi >/dev/null && rocm-smi --showtemp --showmeminfo vram 2>/dev/null | head -20 || true
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
   echo 'Pulizia cache opzionale: mantiene le ultime DUE versioni.'
   if ask_explicit 'Autorizzi la pulizia della cache pacman?'; then
     sudo -n paccache -r -k 2 || report_warn 'Pulizia cache non riuscita'
   else report_skip 'Cache pacman conservata'; fi
   echo 'Cache dopo:'
   du -sh /var/cache/pacman/pkg 2>/dev/null || true
 fi
 echo 'Pacchetti orfani: elenco e rimozione solo previa conferma (Sistema e manutenzione > Manutenzione).'
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
   echo 'La voce Ledger del menu Sicurezza tenta pacchetti udev dedicati tramite pacman/yay.'
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
 echo 'Cartella Projects (nessun progetto creato dallo script):'
 [[ -d "${LEAN_PROJECTS_DIR:-$HOME/Projects}" ]] && echo 'Presente' || echo 'Assente'
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


# Accesso KDE, audit LUKS e stampante generica (CUPS, USB o rete).
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
lean_printer_audit(){
 say 'Stampante — rilevamento e diagnostica (USB e rete, qualsiasi marca)'
 echo 'Stampanti USB (riconosciute dal nome del produttore):'
 if command -v lsusb >/dev/null 2>&1; then lsusb | grep -Ei 'print|hewlett|hp,|brother|canon|epson|samsung|lexmark|kyocera|xerox|ricoh|oki' || echo 'Nessuna stampante USB riconosciuta dal nome; se collegata, controlla lsusb manualmente.'; else echo 'lsusb non presente'; fi
 echo 'Code CUPS:'
 if command -v lpstat >/dev/null 2>&1; then lpstat -p -d 2>&1 || true; else echo 'lpstat non presente'; fi
 echo 'Dispositivi USB / rete rilevati da CUPS:'
 if command -v lpinfo >/dev/null 2>&1; then
   sudo -n lpinfo -v 2>&1 | grep -Ei 'usb|ipp|dnssd|socket|hp:' | head -40 || true
 fi
 echo 'Stampanti IPP di rete (se ippfind disponibile):'
 if command -v ippfind >/dev/null 2>&1; then timeout 8 ippfind 2>/dev/null | head -20 || true; fi
 echo 'Alcuni modelli (es. laser entry-level) richiedono un driver specifico del produttore; NON presumo compatibilità HPLIP, Gutenprint o driverless IPP.'
}
lean_printer_setup(){
 say 'Stampante — configurazione CUPS prudente (USB o rete)'
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
 lean_printer_audit
 local guide="$HOME/.config/endeavouros-lean/stampante.txt"
 mkdir -p "$(dirname "$guide")"
 cat > "$guide" <<'HP_GUIDE'
STAMPANTE — CONFIGURAZIONE (qualsiasi marca/modello)
1. Verifica l'esatto modello sull'etichetta della stampante.
2. Collega la stampante via USB oppure alla stessa rete Wi-Fi del computer.
3. Apri system-config-printer, http://localhost:631 oppure Impostazioni di sistema KDE > Stampanti.
   Il messaggio relativo a PackageKit non richiede l'installazione di PackageKit: usa pacman.
4. Seleziona la stampante rilevata. Controlla il driver proposto e stampa una pagina test.
5. Stampanti recenti di rete: prova prima IPP Everywhere (driverless). HP: valuta hplip; altre marche: gutenprint
   o il driver Linux ufficiale del produttore, verificandone provenienza e compatibilità prima di installarlo.
6. Nessuna regola firewall, driver non verificato o pacchetto AUR viene installato automaticamente.
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
   warn '/dev/kvm assente: controlla Intel VT-x o AMD-V (SVM) nel BIOS/UEFI. Non modifico il firmware.'
   report_warn 'VM: accelerazione KVM non disponibile'
 fi
 # Solo pacchetti ufficiali, nessun modulo proprietario e nessun cambio kernel.
 install_repo qemu-desktop libvirt virt-manager virt-install virt-viewer edk2-ovmf swtpm dnsmasq spice-gtk usbredir virtiofsd
 if ! command -v virt-manager >/dev/null 2>&1; then
   report_fail 'Virt-Manager non disponibile dopo installazione'; return 1
 fi
 if systemctl list-unit-files libvirtd.service --no-legend 2>/dev/null | grep -q '^libvirtd.service'; then
   if ! systemctl is-active --quiet libvirtd.service && ! systemctl is-active --quiet virtqemud.socket && ask_explicit "Attivare libvirtd per le VM?"; then
     if sudo systemctl enable --now libvirtd.service; then report_ok 'libvirtd attivato'; else report_fail 'libvirtd non attivato'; fi
   fi
 elif systemctl list-unit-files virtqemud.socket --no-legend 2>/dev/null | grep -q '^virtqemud.socket'; then
   if ! systemctl is-active --quiet libvirtd.service && ! systemctl is-active --quiet virtqemud.socket && ask_explicit "Attivare virtqemud.socket per le VM?"; then
     if sudo systemctl enable --now virtqemud.socket; then report_ok 'virtqemud.socket attivato'; else report_fail 'virtqemud.socket non attivato'; fi
   fi
 fi
 if ! id -nG "$USER" | grep -qw libvirt; then
   if ask_explicit "Aggiungere utente al gruppo libvirt? (logout/login necessario)"; then
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
   echo 'Su hardware non Apple non scarico né installo macOS, e non aggiro controlli di licenza.'
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
 say 'Syncthing — sincronizzazione peer-to-peer tra i tuoi computer con GUI locale'
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
 echo 'Per collegare due computer: su entrambi apri GUI > Azioni > Mostra ID; aggiungi reciprocamente i dispositivi e condividi SOLO le cartelle scelte.'
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
 echo '  [DA FARE] Abbinare reciprocamente i computer tramite Device ID e scegliere cartelle'
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
   if ask_explicit 'Pulire cache pacman conservando 2 versioni?'; then
    if sudo -n paccache -r -k 2; then report_ok 'Cache pacman ridotta conservando 2 versioni';
    else report_warn 'Pulizia cache pacman non riuscita'; rc=1; fi
   else report_skip 'Cache pacman conservata'; fi
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
   if ! gh repo create "$repo" "$visibility" --description 'Installer EndeavourOS/Arch KDE LEAN (hardware-agnostic)' --clone=false; then
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
lean_base_apps_no_removal(){
 say 'Applicazioni base senza rimozioni'
 install_repo calibre libreoffice-fresh libreoffice-fresh-it bitwarden
 lean_office_fonts
 lean_libreoffice_gtk3
}
lean_dual_hardware_profile(){
 detect_hardware
 local memkb threads
 memkb=$(awk '/MemTotal:/{print $2}' /proc/meminfo)
 threads=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 2)
 LEAN_RAM_MIB=$((memkb/1024))
 LEAN_THREADS=$threads
 LEAN_MACHINE_PROFILE="$HW_PROFILE"
 printf 'Profilo macchina: %s | modello: %s | RAM: %s MiB | thread: %s\n' \
  "$LEAN_MACHINE_PROFILE" "$HW_MODEL" "$LEAN_RAM_MIB" "$LEAN_THREADS"
 lean_vm_specs
 if (( LEAN_RAM_MIB < 12000 )); then
   echo '[INFO] RAM contenuta: Ollama/Open WebUI e avvio automatico di servizi pesanti esclusi dal percorso B.'
 fi
 if (( ! HAS_NVIDIA_GPU )); then echo '[INFO] Nessun pacchetto NVIDIA richiesto dal percorso B.'; fi
}
lean_preflight_full(){
 say 'VERIFICA PRIMA DEL PERCORSO B — NESSUNA MODIFICA'
 local free_kib free_gib=0
 echo "Utente: $USER | HOME: $HOME | Shell: $BASH_VERSION"
 echo "Desktop: ${XDG_CURRENT_DESKTOP:-non rilevato} | sessione: ${XDG_SESSION_TYPE:-non rilevata}"
 if command -v pacman >/dev/null 2>&1; then echo '[OK] pacman disponibile'; else report_fail 'pacman mancante'; return 1; fi
 if command -v firefox >/dev/null 2>&1 || command -v chromium >/dev/null 2>&1; then
   echo '[OK] Browser supportato per i launcher KDE'
 else warn 'Firefox/Chromium assenti: B dovra installarne uno prima dei launcher'; fi
 if command -v kbuildsycoca6 >/dev/null 2>&1; then echo '[OK] KDE Plasma 6 cache disponibile';
 else warn 'kbuildsycoca6 assente: menu KDE da verificare manualmente'; fi
 if command -v df >/dev/null 2>&1; then
   free_kib=$(df -Pk "$HOME" | awk 'NR==2 {print $4}')
   free_gib=$((free_kib/1024/1024))
   echo "Spazio libero HOME: ${free_gib} GiB"
   if ((free_gib < 15)); then warn 'Meno di 15 GiB liberi: installazione B potenzialmente insufficiente'; fi
 fi
 if command -v pacman >/dev/null 2>&1; then
   echo 'Pacchetti core installati:'
   local pkg
   for pkg in firefox tangram ollama docker virt-manager; do
     if pacman -Qq "$pkg" >/dev/null 2>&1; then echo "  [OK] $pkg"; else echo "  [NON INSTALLATO] $pkg"; fi
   done
 fi
 echo '[INFO] B puo aggiornare pacchetti, installare applicazioni e abilitare servizi.'
 echo '[INFO] B non e una simulazione: usa prima un backup o snapshot verificato.'
 echo '[INFO] Non tocca il menu KMenuEdit personalizzato, le sessioni Tangram o i dati Open WebUI.'
 report_ok 'Audit preliminare B completato (sola lettura)'
}

# Kali-inspired prompt for Bash in Konsole; no shell changes, themes, or root access.
lean_kali_terminal(){
  local rc="$HOME/.bashrc" marker='# BEGIN ENDEAVOUROS LEAN KALI PROMPT' backup
  if [[ ! -f "$rc" ]]; then
    if ! ask_explicit 'File ~/.bashrc assente: crearne uno per il prompt Kali-like?'; then return 0; fi
    touch "$rc"
  fi
  if grep -Fq "$marker" "$rc"; then
    echo '[OK] Prompt Kali-like LEAN già configurato: nessuna duplicazione.'
    return 0
  fi
  echo 'Anteprima: ┌──(utente㉿computer)-[~/cartella]'
  echo '           └─$ comando'
  echo 'Solo Bash interattivo: colori blu/verde, due righe, nessun cambio shell.'
  if ! ask_explicit 'Attivare prompt Kali-like in Konsole per i nuovi terminali?'; then
    report_skip 'Prompt Kali-like non autorizzato'; return 0
  fi
  backup="$HOME/.bashrc.lean-backup-$(date +%Y%m%d-%H%M%S)"
  cp -a "$rc" "$backup" || return 1
  cat >> "$rc" <<'KALI_PROMPT'

# BEGIN ENDEAVOUROS LEAN KALI PROMPT
# Only interactive Bash; \[ \] keeps readline cursor positioning correct.
if [[ $- == *i* && -n ${BASH_VERSION:-} ]]; then
  if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then
    PS1='\[\e[1;34m\]┌──(\[\e[1;32m\]\u㉿\h\[\e[1;34m\])-[\[\e[1;37m\]\w\[\e[1;34m\]]\n└─\[\e[1;32m\]\\$\[\e[0m\] '
  else
    PS1='┌──(\u@\h)-[\w]\n└─\\$ '
  fi
fi
# END ENDEAVOUROS LEAN KALI PROMPT
KALI_PROMPT
  echo "[OK] Prompt configurato. Backup: $backup"
  echo 'Apri una nuova scheda Konsole per verificarlo. Ripristino: copia il backup sopra ~/.bashrc.'
  report_ok 'Prompt Bash Kali-like configurato senza modificare Konsole/KDE'
}

# Optional Konsole profile: separate from the user's default profile and KDE menu.
lean_kali_transparency(){
  local profile_dir="$HOME/.local/share/konsole" profile="$HOME/.local/share/konsole/LEAN-Kali-Transparent.profile"
  local scheme="$HOME/.local/share/konsole/LEAN-Kali-Transparent.colorscheme" backup stamp
  if ! command -v konsole >/dev/null 2>&1; then
    report_warn 'Konsole non installato: impossibile creare il profilo trasparente'
    return 1
  fi
  echo 'Profilo separato LEAN Kali Transparent: sfondo scuro, opacità 85% (15% trasparenza).'
  echo 'Non cambia il profilo predefinito, KMenuEdit, i launcher o le impostazioni globali KDE.'
  echo 'La trasparenza richiede il compositore KDE attivo; la sfocatura dipende dalle impostazioni Plasma.'
  if ! ask_explicit 'Creare/aggiornare il profilo Konsole trasparente?'; then
    report_skip 'Profilo Konsole trasparente non autorizzato'; return 0
  fi
  mkdir -p "$profile_dir" || return 1
  stamp=$(date +%Y%m%d-%H%M%S)
  for backup in "$profile" "$scheme"; do
    if [[ -e "$backup" ]]; then
      cp -a -- "$backup" "${backup}.lean-backup-${stamp}" || return 1
    fi
  done
  cat > "$scheme" <<'KALI_SCHEME'
[General]
Description=LEAN Kali Transparent
Opacity=0.85

[Background]
Color=16,23,34

[Foreground]
Color=222,231,241

[Color0]
Color=16,23,34
[Color0Intense]
Color=76,88,105
[Color1]
Color=226,92,100
[Color1Intense]
Color=255,120,129
[Color2]
Color=91,214,160
[Color2Intense]
Color=133,237,189
[Color3]
Color=229,193,107
[Color3Intense]
Color=247,214,139
[Color4]
Color=125,181,255
[Color4Intense]
Color=161,205,255
[Color5]
Color=191,144,246
[Color5Intense]
Color=214,183,255
[Color6]
Color=94,202,221
[Color6Intense]
Color=136,227,242
[Color7]
Color=210,219,231
[Color7Intense]
Color=245,248,252
KALI_SCHEME
  cat > "$profile" <<'KALI_PROFILE'
[General]
Name=LEAN Kali Transparent
Parent=FALLBACK/

[Appearance]
ColorScheme=LEAN-Kali-Transparent
KALI_PROFILE
  echo '[OK] Profilo Konsole LEAN Kali Transparent creato.'
  echo 'Per provarlo: konsole --profile "LEAN Kali Transparent"'
  echo 'Per impostarlo come predefinito: Konsole > Impostazioni > Gestisci profili (scelta manuale).'
  echo 'Per tornare indietro: usa il tuo precedente profilo; i file esistenti non sono modificati.'
  report_ok 'Profilo Konsole trasparente separato creato'
}

lean_guided(){
 RUN_MODE='B — profilo hardware adattivo, conferme esplicite'
 say 'LEAN — installazione guidata sicura (profilo adattivo al PC rilevato)'
 lean_dual_hardware_profile
 echo 'FASE 1 — controlli di sola lettura'
 preflight || { report_fail 'Preflight fallito: B interrotto'; return 1; }
 maintenance_audit || { report_fail 'Audit pacman fallito: B interrotto'; return 1; }
 if ! ask_explicit 'Avviare installazione dei pacchetti mancanti per questo PC? (nessuna rimozione automatica)'; then
   report_skip 'B interrotto: installazione non autorizzata'; return 0
 fi
 echo 'FASE 2 — aggiornamento completo (con conferma separata)'
 if ! update_system; then
   report_warn 'Aggiornamento non completato/autorizzato: installazioni sospese per evitare aggiornamenti parziali'
   return 1
 fi
 echo 'FASE 3 — applicazioni e strumenti di base'
 echo '[SICUREZZA] Nessuna pulizia, rimozione, cambio GPU/display manager o pubblicazione GitHub nel percorso B.'
 local fn fails_before
 local -a phases=(
   lean_base_apps_no_removal lean_vm_install ai_tools docker_setup
   lean_tuta_desktop lean_social_ferdium lean_appflowy
   lean_office_fonts cloud iphone pdf_ocr_setup photo_video
   lean_productivity_install lean_rebuild_web_shortcuts
 )
 for fn in "${phases[@]}"; do
   fails_before=${#REPORT_FAIL[@]}
   if ! "$fn"; then
     report_fail "B interrotto alla fase $fn; verificare log prima di riprendere"
     return 1
   fi
   if (( ${#REPORT_FAIL[@]} > fails_before )); then
     report_fail "B interrotto: errori registrati durante $fn"
     return 1
   fi
 done
 if (( LEAN_RAM_MIB >= 12000 )); then
   if ask_explicit 'Installare/configurare Ollama locale e servizi AI su questo PC?'; then
     ollama_local || { report_fail 'Ollama: fase fallita'; return 1; }
   else report_skip 'Ollama escluso dal percorso B'; fi
 else
   report_skip 'Ollama/Open WebUI esclusi dal B per RAM inferiore a 12 GiB'
 fi
 if ask_explicit 'Personalizzare anche il prompt Bash di Konsole in stile Kali Linux?'; then
   lean_kali_terminal || report_warn 'Personalizzazione terminale non completata'
 fi
 if ask_explicit 'Creare anche il profilo Konsole Kali con sfondo trasparente?'; then
   lean_kali_transparency || report_warn 'Profilo Konsole trasparente non completato'
 fi
 echo 'FASE 4 — verifica finale (sola lettura)'
 lean_postinstall_review || report_warn 'Audit finale con avvisi'
 echo 'NON eseguiti automaticamente: rimozioni Brave/ONLYOFFICE, pulizia orfani/cache, GitHub push, cambio GPU, tema KDE, cambio display manager.'
 echo 'Menu: GitHub in Sviluppo; pulizia in Sistema e manutenzione; preferenze GPU in Grafica, gaming e virtualizzazione.'
}

lean_gpu_shortcuts(){
 say 'Shortcut KDE: preferenza GPU integrata / dedicata / Hybrid'
 detect_hardware
 if (( ! HAS_DGPU )); then
   echo 'GPU dedicata assente: nessuna scelta GPU richiesta; eventuali shortcut LEAN obsoleti vengono rimossi.'
 fi
 local bindir="$HOME/.local/bin" appdir="$HOME/.local/share/applications" icondir="$HOME/.local/share/icons/hicolor/scalable/apps"
 mkdir -p "$bindir" "$appdir" "$icondir" "$HOME/.config/endeavouros-lean"
 local helper="$bindir/lean-gpu-select"
 if [[ -e "$helper" ]] && ! grep -Eq '^# LEAN GPU SELECT v(32|33|34|35)$' "$helper"; then
   warn "Helper personalizzato esistente: $helper. Non sovrascrivo."; report_warn 'Shortcut GPU: helper personalizzato non modificato'; return 0
 fi
 cat > "$helper" <<'GPU_SELECT'
#!/usr/bin/env bash
# LEAN GPU SELECT v35
set -euo pipefail
case "${1:-}" in
 intel|nvidia|amd|hybrid) mode="$1";;
 *) printf 'Uso: lean-gpu-select {intel|nvidia|amd|hybrid}\n' >&2; exit 2;;
esac
if [[ "$mode" == amd ]] && ! grep -lqi '0x1002' /sys/bus/pci/devices/*/vendor 2>/dev/null; then
  message='GPU AMD non rilevata: preferenza non cambiata.'
  command -v kdialog >/dev/null 2>&1 && kdialog --error "$message" || printf '%s\n' "$message" >&2
  exit 1
fi
if [[ "$mode" == nvidia ]] && { [[ ! -e /sys/bus/pci/devices ]] || ! grep -lqi '0x10de' /sys/bus/pci/devices/*/vendor 2>/dev/null || ! command -v prime-run >/dev/null 2>&1; }; then
  message='prime-run non trovato: preferenza NVIDIA non cambiata.'
  command -v kdialog >/dev/null 2>&1 && kdialog --error "$message" || printf '%s\n' "$message" >&2
  exit 1
fi
confdir="$HOME/.config/endeavouros-lean"
mkdir -p "$confdir"
printf '%s\n' "$mode" > "$confdir/gpu-mode"
case "$mode" in
 intel) label='GPU integrata (preferenza per le applicazioni LEAN)' ;;
 nvidia) label='NVIDIA (applicazioni LEAN tramite PRIME)' ;;
 amd) label='AMD dedicata (applicazioni LEAN con DRI_PRIME=1)' ;;
 hybrid) label='Hybrid (applicazioni LEAN in avvio normale)' ;;
esac
message="Preferenza GPU: $label. Il desktop KDE e le applicazioni già aperte NON cambiano GPU. Usa lean-gpu-run per le nuove applicazioni."
if command -v notify-send >/dev/null 2>&1; then notify-send 'EndeavourOS LEAN · GPU' "$message"; else printf '%s\n' "$message"; fi
GPU_SELECT
 chmod 755 "$helper"
 local mode title color glyph iconfile desktop
 local wanted
 for mode in intel nvidia amd hybrid; do
   # Crea solo gli shortcut sensati per l'hardware rilevato; rimuove quelli LEAN non piu' pertinenti.
   wanted=0
   case "$mode" in
    intel)  if (( HAS_DGPU && HAS_IGPU )); then wanted=1; fi;;
    nvidia) if (( HAS_NVIDIA_GPU )); then wanted=1; fi;;
    amd)    if (( HAS_AMD_GPU && HAS_INTEL_GPU && ! HAS_NVIDIA_GPU )); then wanted=1; fi;;
    hybrid) if (( HAS_DGPU )); then wanted=1; fi;;
   esac
   if (( ! wanted )); then
     desktop="$appdir/endeavouros-gpu-$mode.desktop"
     if [[ -f "$desktop" ]] && grep -Eq '^# LEAN GPU SHORTCUT v(32|33|34|35)$' "$desktop"; then rm -f "$desktop"; fi
     report_skip "GPU $mode: shortcut non necessario per questo hardware"
     continue
   fi
   case "$mode" in
    intel) title='GPU · Integrata'; color='#2676b8'; glyph='I';;
    nvidia) title='GPU · NVIDIA'; color='#3f8b34'; glyph='N';;
    amd) title='GPU · AMD dedicata'; color='#b4321e'; glyph='A';;
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
   if [[ -e "$desktop" ]] && ! grep -Eq '^# LEAN GPU SHORTCUT v(32|33|34|35)$' "$desktop"; then
     warn "Collegamento personalizzato esistente: $desktop (preservato)"
     report_warn "GPU: collegamento $mode non modificato"
     continue
   fi
   cat > "$desktop" <<EOF
[Desktop Entry]
# LEAN GPU SHORTCUT v35
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
 echo 'Nel menu KDE: GPU · Integrata, GPU · NVIDIA / GPU · AMD dedicata, GPU · Hybrid (solo quelli pertinenti).'
 echo 'Questi shortcut salvano solo la preferenza per lean-gpu-run; NON commutano il desktop.'
 report_skip 'GPU: per-app via lean-gpu-run; non modifica sessione KDE, driver o MUX'
}
lean_gpu_mode(){
 say 'GPU: integrata / dedicata / Hybrid (PRIME o DRI_PRIME, senza modifiche ai driver)'
 detect_hardware
 if (( ! HAS_DGPU )); then
   # Nessuna scelta interattiva sui PC con una sola GPU.
   # Non creare launcher PRIME né chiedere integrata/dedicata/Hybrid.
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
 1) GPU integrata — preferenza per le app LEAN (non spegne la GPU dedicata)
 2) GPU dedicata — NVIDIA tramite PRIME (prime-run) oppure AMD tramite DRI_PRIME=1
 3) Hybrid (consigliata) — desktop invariato, GPU dedicata su richiesta
 0) Annulla
GPU_MENU
 local choice confdir conf target tmp
 read -r -p 'Modalità GPU [3]: ' choice || return 0
 choice=${choice:-3}
 case "$choice" in
  1) target=intel;;
  2) if (( HAS_NVIDIA_GPU )); then target=nvidia; elif (( HAS_AMD_GPU )); then target=amd; else warn 'GPU dedicata assente: selezione annullata'; return 0; fi;;
  3) target=hybrid;;
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
 if [[ -e "$launcher" ]] && ! grep -Eq '^# LEAN GPU RUN v(29|30)$' "$launcher"; then
   warn "Launcher $launcher preesistente e personalizzato: non lo sovrascrivo."
   report_warn 'GPU: configurazione salvata ma launcher personalizzato non modificato'
   return 0
 fi
 cat > "$launcher" <<'GPU_RUN'
#!/usr/bin/env bash
# LEAN GPU RUN v30
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
 amd)
   # GPU AMD dedicata tramite Mesa PRIME offload (nessun driver proprietario richiesto).
   exec env DRI_PRIME=1 "$@";;
 hybrid)
   # L'avvio standard non forza la GPU dedicata; usare lean-gpu-nvidia (PRIME) o DRI_PRIME=1.
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
 if (( HAS_NVIDIA_GPU )); then echo 'Per forzare NVIDIA su un singolo programma: ~/.local/bin/lean-gpu-nvidia nome-app'; fi
 if (( HAS_NVIDIA_GPU )); then echo 'Steam (gioco specifico): prime-run %command%'; fi
 echo 'Nota: il desktop KDE resta sulla configurazione GPU attuale.'
 echo 'Nota: la preferenza integrata non spegne fisicamente la GPU dedicata; la preferenza dedicata non sposta tutto Plasma su di essa.'
 if [[ "$target" == amd ]]; then echo 'AMD: DRI_PRIME=1 seleziona la GPU dedicata tramite Mesa; verifica con glxinfo -B o vulkaninfo --summary.'; fi
 if [[ "$target" == nvidia ]] && ! command -v prime-run >/dev/null 2>&1; then
   warn 'prime-run assente: modalità NVIDIA selezionata ma launcher non operativo finché non sarà disponibile.'
   report_warn 'GPU NVIDIA: manca prime-run'
 fi
 report_ok "GPU: preferenza applicazioni impostata su $target"
}
cat <<INFO

EndeavourOS / Arch KDE — installer LEAN (hardware-agnostic)
Distribuzione: ${LEAN_DISTRO:-Arch-based} | Modello: $HW_MODEL | profilo GPU: $HW_PROFILE
- pacman > yay; nessuna nuova Flatpak/Snap; nessun driver, kernel, bootloader o display manager modificato
- GPU Intel / NVIDIA / AMD (anche ibride) rilevate prima di ogni operazione: nessun modello di PC presupposto
- installazioni automatiche; rimozioni, aggiornamenti e pubblicazioni sempre con conferma esplicita
- 8 categorie con al massimo 6 voci ciascuna; B = percorso guidato completo (verifica → aggiornamento → installazione → audit)
INFO

# ---------------------------------------------------------------------------
# MENU A CATEGORIE
# Ogni voce: 'etichetta|sudo|funzione [funzione ...]'
#   sudo=1 -> autenticazione richiesta prima dell'esecuzione (modifica il sistema)
#   sudo=0 -> sola lettura o modifiche limitate alla HOME dell'utente
# Le funzioni elencate vengono eseguite in sequenza tramite run_step: un errore
# viene registrato nel report senza interrompere il menu.
# ---------------------------------------------------------------------------
declare -A MENU_TITLE=(
 [1]='Sistema e manutenzione'
 [2]='Ufficio e produttività'
 [3]='Browser, web e comunicazione'
 [4]='Intelligenza artificiale'
 [5]='Sviluppo'
 [6]='Multimedia, cloud e dispositivi mobili'
 [7]='Grafica, gaming e virtualizzazione'
 [8]='Sicurezza, privacy e crypto'
)
declare -a MENU_1=(
 'Inventario completo: sistema, hardware, pacchetti, controllo pre-B (sola lettura)|0|preflight lean_hardware_audit maintenance_audit lean_preflight_full'
 'Aggiornamento completo pacman -Syu (conferma esplicita)|1|update_system'
 'Inventario e migrazione installazioni esterne: Flatpak, Snap, AppImage, npm|1|migration'
 'Manutenzione: dipendenze, orfani protetti, cache pacman, SSD/TRIM (con conferma)|1|maintenance_audit lean_safe_cleanup lean_ssd_maintenance'
 'Monitoraggio hardware (btop, nvtop, sensori, SMART) + audit profili energetici|1|lean_monitoring_install lean_power_audit'
 'Aspetto desktop: font stile macOS, pulsanti finestra a sinistra, prompt Bash e profilo Konsole stile Kali (ognuno con conferma e backup)|1|macos_desktop_look lean_kali_terminal lean_kali_transparency'
)
declare -a MENU_2=(
 'Suite base: LibreOffice (+ GTK3 multi-monitor), Calibre, Bitwarden, font compatibili MS|1|base_apps'
 'PDF avanzati, scanner e OCR (Okular, PDF Arranger, OCRmyPDF, Tesseract)|1|pdf_ocr_setup'
 'Produttività: HomeBank, OBS, HandBrake, DBeaver, Bruno, Pandoc (+ verifica)|1|lean_productivity_audit lean_productivity_install'
 'Note, database e progetti: AppFlowy (alternativa a Notion, AUR con consenso)|1|lean_appflowy'
 'Stampante: CUPS, rilevamento USB/rete, guida e pagina di prova|1|lean_printer_setup'
)
declare -a MENU_3=(
 'Firefox: installazione, uBlock Origin e privacy avanzata (policy reversibili)|1|lean_firefox_privacy_harden'
 'Firefox browser predefinito e rimozione Brave (solo se sicura e confermata)|1|lean_firefox_replace_brave'
 'Tema Firefox stile macOS: Cupertino (conferma nel browser)|1|firefox_macos_theme'
 'Launcher Google: Gmail, Keep, Calendar, Tasks, Docs, Sheets, Slides, Drive + guida famiglia|0|google_workspace lean_google_office lean_family_setup'
 'Email e messaggistica: Tuta Desktop (AUR) e Ferdium|1|lean_tuta_desktop lean_social_ferdium'
 'Ricostruisci e verifica tutti i 17 collegamenti web KDE (LLM, Google, Office)|0|lean_rebuild_web_shortcuts'
)
declare -a MENU_4=(
 'AI CLI e sviluppo: VS Code, Claude Code (con fix PATH npm/pacman), Codex CLI, Gemini CLI|1|ai_tools'
 'Launcher LLM web (ChatGPT, Claude, Gemini, Perplexity, Copilot, Manus, Mistral, Grok, Open WebUI) + sottomenu KDE|0|ai_desktop'
 'Tangram: aggregatore web LLM separato da Ferdium (senza API)|1|lean_tangram'
 'Ollama locale: servizio su localhost, accelerazione CUDA/ROCm se disponibile, Open WebUI opzionale|1|ollama_local'
 'Ollama: inventario e download dei soli modelli locali mancanti (con conferma)|0|lean_ollama_models'
)
declare -a MENU_5=(
 'Docker Engine + Compose + GitHub CLI (servizio non avviato)|1|docker_setup'
 'Ambiente di sviluppo completo: uv, VS Code, AI CLI, workspace vuoto e template sicuri|1|development_environment'
 'Attiva servizi di sviluppo: Docker e Ollama (con conferma)|1|enable_development_services'
 'GitHub: crea/verifica repository del progetto e sincronizza i file (privato per default)|1|lean_github_repo'
)
declare -a MENU_6=(
 'Cloud in KDE/Dolphin: Google Drive (kio-gdrive), Dropbox, MEGA, pCloud|1|cloud'
 'Syncthing: installazione, servizio utente e launcher KDE|1|lean_syncthing'
 'Smartphone: KDE Connect + supporto USB iPhone (libimobiledevice, ifuse)|1|iphone'
 'Diagnostica smartphone: USB e KDE Connect in LAN (sola lettura)|0|iphone_diagnostics'
 'Workflow foto da smartphone: strumenti di importazione + guida non distruttiva|1|lean_iphone_photo_workflow'
 'Fotografia RAW/ProRAW e video: digiKam, darktable, Kdenlive|1|photo_video'
)
declare -a MENU_7=(
 'Steam, controller e gaming: stack Vulkan per ogni GPU rilevata, MangoHud, GameMode|1|steam_setup'
 'GPU: preferenza per-app integrata / dedicata (NVIDIA PRIME o AMD DRI_PRIME) / Hybrid + shortcut KDE|0|lean_gpu_mode lean_gpu_shortcuts'
 'Virtualizzazione: QEMU/KVM, Virt-Manager, SPICE, USB redirection (+ launcher KDE)|1|lean_vm_install'
 'VM guidata: crea e avvia Windows 11 / Linux (macOS solo informazioni)|1|lean_vm_wizard'
 'Ripara solo il collegamento Virt-Manager nel menu KDE (senza reinstallare)|0|lean_vm_kde_launcher'
)
declare -a MENU_8=(
 'Audit sicurezza, backup e salute dischi: restic, SMART, Btrfs/snapper se presente|1|security_audit'
 'Blocco schermo KDE + audit cifratura LUKS (nessuna cifratura automatica)|1|lean_kde_lock lean_luks_audit'
 'Proton VPN: GUI + CLI dai repository (senza alterare la rete)|1|proton_vpn_setup'
 'Ledger Nano: client wallet, regole udev dedicate e diagnostica USB|1|ledger_setup lean_ledger_usb_audit'
 'Wallet DeFi browser: guida MetaMask/Rabby e sicurezza Ledger (nessuna estensione installata)|1|defi_setup lean_rabby_guide'
)

# Esegue una voce di menu: rilevamento hardware, sudo solo se necessario, audit browser, funzioni in sequenza.
lean_run_entry(){
 local entry="$1" label sudo_needed fnlist fn
 IFS='|' read -r label sudo_needed fnlist <<< "$entry"
 detect_hardware
 if [[ "$sudo_needed" == 1 ]] && ! sudo -v; then
   echo '[ERRORE] Autenticazione sudo non riuscita: voce non eseguita'; return 0
 fi
 lean_browser_audit
 if [[ "$HW_PROFILE" == unknown ]]; then
   echo '[INFO] GPU non riconosciuta: procedo senza forzare driver; il menu resta disponibile.'
 fi
 say "▶ $label"
 local -a fns=()
 IFS=' ' read -r -a fns <<< "$fnlist"
 for fn in "${fns[@]}"; do run_step "$fn"; done
}

# Sottomenu di una categoria: elenco numerato generato dai dati, 0 per tornare indietro.
lean_category_menu(){
 local cat="$1" choice i label
 local -n items="MENU_$cat"
 while true; do
   printf '\n %s) %s\n' "$cat" "${MENU_TITLE[$cat]}"
   for i in "${!items[@]}"; do
     IFS='|' read -r label _ <<< "${items[$i]}"
     printf '  %d) %s\n' "$((i+1))" "$label"
   done
   echo '  0) Indietro'
   read -r -p 'Scelta [0]: ' choice || return 0
   choice=${choice:-0}
   [[ "$choice" == 0 ]] && return 0
   if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#items[@]} )); then
     lean_run_entry "${items[$((choice-1))]}"
   else
     echo 'Scelta non valida'
   fi
 done
}

while true; do
 echo
 echo ' B) PERCORSO GUIDATO SICURO — profilo hardware adattivo; aggiornamenti/installazioni con conferma (INVIO)'
 for cat in 1 2 3 4 5 6 7 8; do
   printf '  %s) %s\n' "$cat" "${MENU_TITLE[$cat]}"
 done
 echo '  0) Esci'
 echo ' Nota: il rilevamento hardware avviene automaticamente prima di ogni operazione'
 read -r -p 'Scelta [B]: ' choice || break
 choice=${choice:-B}
 case "$choice" in
  [Bb])
   detect_hardware
   if ! sudo -v; then echo '[ERRORE] Autenticazione sudo non riuscita'; continue; fi
   lean_browser_audit
   lean_guided; break;;
  [1-8]) lean_category_menu "$choice";;
  0) LEAN_QUICK_EXIT=1; break;;
  *) echo 'Scelta non valida';;
 esac
done
echo "Log: $LOG"
echo "Cartella log/report: $LEAN_LOG_DIR"
if [[ "${LEAN_QUICK_EXIT:-0}" != 1 ]]; then echo "Il report finale verrà stampato e salvato in: $REPORT"; fi
