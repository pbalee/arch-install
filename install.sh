#!/usr/bin/env bash
# =============================================================================
#  Arch Linux automata telepítő  –  BLUELIGHT INSTALLER   (pbalee, v3.9)
#
#  Indítás (Arch ISO-ról bootolva, működő hálózattal):
#
#     bash <(curl -fsSL https://raw.githubusercontent.com/pbalee/arch-install/main/install.sh)
# =============================================================================
set -uo pipefail

############################ BEÁLLÍTÁSOK – szabadon átírhatod ###################
GH_USER="pbalee"
GH_REPO="arch-install"
GH_BRANCH="main"
XFCE_PROFILE_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${GH_BRANCH}/xfce-backup.tar.gz"

DEFAULT_HOSTNAME="bluelight"
DEFAULT_USER="pbalee"
TIMEZONE="Europe/Budapest"
MAIN_LOCALE="hu_HU.UTF-8"
KEYMAP="hu"
CONSOLE_FONT="ter-122b"
AUDACIOUS_SKIN="Winamp3_Classified_v5.5.wsz"   # a repó "Winamp Skins/" mappájából (üres/hiányzó = az első .wsz)
SOLIDCRAFT_URL="https://github.com/bherbruck/solidcraft/releases/latest/download"
MIRROR_COUNTRIES="Hungary,Austria,Slovakia,Czechia,Germany,Romania"   # reflector tükrök

ESP_SIZE_GIB=1          # EFI/boot partíció mérete (új partíciózásnál)
DEFAULT_ROOT_GIB=75     # root alapméret, ha külön /home is lesz

# Extra meghajtók (opcionális, fstab-ba kerülnek, nofail-lel)
GAMES_UUID="9471a888-07ec-45ed-b516-eb6aa1513a64"   # ext4, /Games
DOWNLOAD_UUID="7460557760554152"                    # ntfs, /Download

LOG_FILE="/tmp/arch-install.log"
BACKTITLE="Arch Linux Telepítő  ::  BLUELIGHT SYSTEM"
#################################################################################

export LANG=C.UTF-8
RST=$'\e[0m'; RED=$'\e[1;31m'; GRN=$'\e[1;32m'; YEL=$'\e[1;33m'
BLU=$'\e[1;34m'; CYN=$'\e[1;36m'; WHT=$'\e[1;37m'

step() { printf '\n%s==>%s %s%s%s\n' "$BLU" "$RST" "$CYN" "$*" "$RST"; }
ok()   { printf '%s [OK]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s [!]%s %s\n' "$YEL" "$RST" "$*" >&2; }
die()  { printf '\n%s [HIBA]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }
must() { "$@" || die "Sikertelen parancs: $*  (napló: $LOG_FILE)"; }
# Parancs futtatása pty-n keresztül: marad a szín / ILoveCandy, közben naplózódik.
run_logged() { script -qefa -c "$(printf '%q ' "$@")" "$LOG_FILE"; }
cancel() { clear; printf '%sA telepítés megszakítva.%s\n' "$YEL" "$RST"; exit 1; }

# ---------------------------------------------------------------- dialog -----
d()    { dialog --backtitle "$BACKTITLE" --cr-wrap --no-collapse "$@" 3>&1 1>&2 2>&3; }
yn()   { d --title "$1" --yesno "$2" 0 0; }
ynn()  { d --title "$1" --defaultno --yesno "$2" 0 0; }
msg()  { d --title "$1" --msgbox "$2" 0 0; }
menu() { local t=$1 q=$2; shift 2; d --title "$t" --menu "$q" 0 0 0 "$@"; }
ask()  { d --title "$1" --inputbox "$2" 0 70 "${3:-}"; }

ask_int() {
  local v
  while true; do
    v=$(ask "$1" "$2" "$3") || return 1
    if [[ $v =~ ^[0-9]{1,6}$ ]] && (( 10#$v >= $4 && 10#$v <= $5 )); then v=$((10#$v)); printf '%s' "$v"; return 0; fi
    msg "Hibás érték" "Egész számot adj meg ($4 – $5 között)."
  done
}

ask_password() {
  local a b
  while true; do
    a=$(d --insecure --title "$1" --passwordbox "Jelszó:" 0 50) || return 1
    b=$(d --insecure --title "$1" --passwordbox "Jelszó újra:" 0 50) || return 1
    if [[ -z $a ]]; then msg "Hiba" "A jelszó nem lehet üres."; continue; fi
    if [[ $a != "$b" ]]; then msg "Hiba" "A két jelszó nem egyezik, próbáld újra."; continue; fi
    printf '%s' "$a"; return 0
  done
}

# ---------------------------------------------------------------- logó -------
banner() {
  clear
  printf '%s' "$CYN"
  cat <<'ART'
                .-'''''''''''-.
          .-''      .-----.      ''-.
       .'                             '.
.--.  /                                 \  .--.
/    \|           .---------.           |/    \
|  () |                                 | ()  |
|  () |                                 | ()  |
|  () |.------------.     .------------.| ()  |
|  () || _|-.  /\   |-----| _|-.  /\   || ()  |
|  () || |_  _/  \  |     | |_  _/  \  || ()  |
|  () ||   '-' /__\ |     |   '-' /__\ || ()  |
\    /|'------------'     '------------'|\    /
       \          '-._____.-'          /
          '-.                     .-'
             '-._______________.-'
ART
  printf '%s' "$RST"
  printf '%s       B L U E L I G H T   ::   A R C H   I N S T A L L E R%s\n' "$WHT" "$RST"
  printf '%s              [ Customized by pbalee ]%s\n\n' "$CYN" "$RST"
  printf '   Arch Linux Automata Telepítő  |  Blackice GRUB  |  UEFI\n\n'
}

# ------------------------------------------------------- pacman.conf --------
tune_pacman() {
  local f=$1
  sed -i 's/^#Color$/Color/' "$f"
  grep -q '^ILoveCandy' "$f" || sed -i '/^Color$/a ILoveCandy' "$f"
  sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' "$f"
  sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 9/' "$f"
  sed -i '/^#\[multilib\]$/,/^#Include/ s/^#//' "$f"
  if ! grep -q '^\[multilib\]' "$f"; then
    printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> "$f"
  fi
}

# ------------------------------------------------------- előkészítés --------
preflight() {
  [[ $EUID -eq 0 ]] || die "Rootként futtasd!"
  [[ -d /sys/firmware/efi ]] || die "A gép nem UEFI módban indult."
  command -v pacstrap >/dev/null || die "Ez a szkript az Arch Linux telepítő ISO-ról fut."

  step "Hálózat ellenőrzése"
  curl -fsS --max-time 10 -o /dev/null https://archlinux.org || die "Nincs internet."
  ok "Van internet."
  timedatectl set-ntp true 2>/dev/null || true

  step "Gyors tükörszerverek kiválasztása (reflector)"
  if command -v reflector >/dev/null; then
    if timeout 120 reflector --country "$MIRROR_COUNTRIES" --protocol https --age 24 --latest 15 --sort rate \
         --save /etc/pacman.d/mirrorlist.new >>"$LOG_FILE" 2>&1 && grep -q '^Server' /etc/pacman.d/mirrorlist.new; then
      mv /etc/pacman.d/mirrorlist.new /etc/pacman.d/mirrorlist
      ok "Tükörlista frissítve."
    else
      rm -f /etc/pacman.d/mirrorlist.new
      warn "A reflector nem sikerült, marad az alap tükörlista."
    fi
  fi

  step "Live rendszer pacman beállítása"
  tune_pacman /etc/pacman.conf
  must pacman -Sy --noconfirm
  must pacman -S --noconfirm --needed archlinux-keyring dialog gptfdisk terminus-font
  set_console
  ok "Kész."
}

set_console() {
  setfont "$CONSOLE_FONT" 2>/dev/null || setfont lat2-16 2>/dev/null || true
  loadkeys "$KEYMAP" 2>/dev/null || true
}

# ------------------------------------------------------- lemez-listák -------
live_disk_name() {
  local src
  src=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)
  [[ -n $src ]] && lsblk -no PKNAME "$src" 2>/dev/null | head -n1
  return 0
}

# Egy lsblk-oszlop lekérése eval nélkül (a címke/modell lehet bármi)
lsf() { lsblk -dnpo "$1" "$2" 2>/dev/null | head -n1 | sed 's/[[:space:]]*$//'; }

list_disks() {
  local live dev
  live=$(live_disk_name)
  while read -r dev; do
    [[ -n $live && ${dev##*/} == "$live" ]] && continue
    printf '%s\n%s\n' "$dev" "$(lsf SIZE "$dev")  $(lsf MODEL "$dev")"
  done < <(lsblk -dpnro NAME,TYPE | awk '$2=="disk" && $1 !~ /zram|\/loop|\/sr[0-9]/ {print $1}')
}

USED_PARTS=()
list_parts() {
  local live dev parent
  live=$(live_disk_name)
  while read -r dev; do
    parent=$(lsf PKNAME "$dev")
    [[ -n $live && ${parent##*/} == "$live" ]] && continue
    [[ " ${USED_PARTS[*]-} " == *" $dev "* ]] && continue
    printf '%s\n%s\n' "$dev" "$(lsf SIZE "$dev")  $(lsf FSTYPE "$dev")  $(lsf LABEL "$dev")"
  done < <(lsblk -pnro NAME,TYPE | awk '$2=="part"{print $1}')
}

pick_part() {
  local -a items
  mapfile -t items < <(list_parts)
  (( ${#items[@]} > 0 )) || { msg "Hiba" "Nem találtam szabad partíciót."; return 1; }
  menu "$1" "$2" "${items[@]}"
}

part_path() {
  if [[ $1 =~ [0-9]$ ]]; then printf '%sp%s' "$1" "$2"; else printf '%s%s' "$1" "$2"; fi
}

pick_fs() {
  menu "$1" "Melyik fájlrendszert használjuk?" \
    ext4  "Ext4  - megbízható, alapértelmezett" \
    btrfs "Btrfs - pillanatképek, tömörítés" \
    xfs   "XFS   - nagy fájlokhoz, gyors"
}

# ---------------------------------------------------------- kérdések --------
ask_basics() {
  while true; do
    HOSTNAME_=$(ask "Gépnév" "Add meg a gép nevét (hostname):" "$DEFAULT_HOSTNAME") || cancel
    [[ $HOSTNAME_ =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] && break
    msg "Hibás gépnév" "Csak betű, szám és kötőjel lehet benne."
  done
  while true; do
    USERNAME_=$(ask "Felhasználó" "Add meg a felhasználónevet (kisbetűkkel):" "$DEFAULT_USER") || cancel
    [[ $USERNAME_ =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
    msg "Hibás név" "Kisbetű, szám, _ és - lehet benne, betűvel kezdődjön."
  done
  ROOTPW=$(ask_password "ROOT jelszó") || cancel
  USERPW=$(ask_password "Jelszó a(z) $USERNAME_ felhasználónak") || cancel
}

ask_software() {
  DE=$(menu "Asztali környezet" "Milyen asztali környezetet szeretnél?" \
      xfce  "XFCE   - könnyű, gyors, Whisker menü (alapértelmezett)" \
      gnome "GNOME  - modern, letisztult" \
      kde   "KDE Plasma - testreszabható" \
      none  "Nincs  - csak konzolos rendszer") || cancel

  GPU=$(menu "Videókártya" "Milyen grafikus kártya van a gépben?" \
      other  "Egyéb / alap (nincs extra driver)" \
      nvidia "NVIDIA (nvidia-open, RTX 20xx / GTX 16xx és újabb)" \
      amd    "AMD (mesa + vulkan-radeon)" \
      intel  "Intel (mesa + vulkan-intel + media driver)") || cancel

  GRUBTHEME=$(menu "GRUB téma" "Melyik GRUB témát használjuk?" \
      blackice    "Blackice (a saját GitHub-repódból)" \
      hyperfluent "HyperFluent - Arch változat (Coopydood, GPL-3.0)" \
      none        "Nincs téma (alap GRUB)") || cancel

  DARKTHEME=none
  if [[ $DE == xfce ]]; then
    DARKTHEME=$(menu "Sötét téma" "Melyik sötét témát használjuk az XFCE-ben?\n(GTK + ablakkeret + Papirus-Dark ikonok + Qt-programok is)" \
        arc     "Arc-Dark      - klasszikus, kékesszürke (alapértelmezett)" \
        materia "Materia-dark  - Material Design, élénkebb kiemelés" \
        none    "Nincs         - alap (világos) téma") || cancel
  fi

  local on_xfce=off
  [[ $DE == xfce ]] && on_xfce=on
  EXTRAS=$(d --separate-output --title "Extra csomagok és szolgáltatások" \
      --checklist "Szóköz = kijelölés, Enter = tovább" 0 0 0 \
      office      "LibreOffice (magyar nyelvi csomagokkal)"           on \
      gaming      "Játék: Lutris, Wine, GameMode, MangoHud"           on \
      vbox        "VirtualBox (host + dkms)"                          on \
      aur         "AUR: yay + Google Chrome"                          on \
      rustdesk    "RustDesk távoli asztal (AUR) + szolgáltatás"       on \
      glava       "GLava hangvizualizáló + ksuperkey (AUR, XFCE)"     "$on_xfce" \
      screensaver "XScreenSaver GL Matrix, energiagazd. KI (XFCE)" "$on_xfce" \
      flatpak     "Flatpak + Flathub"                                 on \
      samba       "Samba fájlmegosztás (WORKGROUP)"                   on \
      media       "Média eszközök: yt-dlp, ffmpeg"                    on \
      freecad     "FreeCAD (3D CAD)"                                  on \
      solidcraft  "SolidCraft CAD (GitHub release AppImage)"         on \
      profile     "XFCE profil visszatöltése GitHubról"               "$on_xfce" \
      drives      "Extra meghajtók fstab-ba (/Games, /Download)"      off) || cancel
}
has() { grep -qx "$1" <<<"$EXTRAS"; }
need_aur() { has aur || has rustdesk || has glava; }

ask_disk() {
  MODE=$(menu "Lemezkezelés" "Hogyan állítsuk össze a partíciókat?" \
      new      "ÚJ partíciós tábla egy lemezen (TELJES törlés, mindent újra)" \
      keephome "A lemezen lévő /home MEGTARTÁSA, a többi (EFI, root, swap) újra" \
      existing "MEGLÉVŐ partíciók kézi kiválasztása (több lemez, saját elrendezés)") || cancel

  USE_HOME=0; USE_SWAP=0; FORMAT_HOME=1; FORMAT_ESP=1
  ROOT_FS=ext4; HOME_FS=ext4; SWAP_GIB=0; ROOT_GIB=0
  ESP_PART=""; ROOT_PART=""; HOME_PART=""; SWAP_PART=""; TARGET=""
  USED_PARTS=(); DEL_PARTS=(); HOME_UUID=""
  ESP_NUM=1; ROOT_NUM=2; SWAP_NUM=3

  case $MODE in
    new)      ask_disk_new ;;
    keephome) ask_disk_keephome ;;
    *)        ask_disk_existing ;;
  esac
}

ask_disk_new() {
  local -a dm
  mapfile -t dm < <(list_disks)
  (( ${#dm[@]} > 0 )) || die "Nem találtam telepíthető lemezt."
  TARGET=$(menu "Célmeghajtó" "Melyik lemezre telepítsünk?\n(A lemez TELJES tartalma törlődni fog!)" "${dm[@]}") || cancel
  DISK_GIB=$(( $(blockdev --getsize64 "$TARGET") / 1073741824 ))
  (( DISK_GIB >= 20 )) || die "A lemez túl kicsi ($DISK_GIB GiB), legalább 20 GiB kell."

  local ram_kb ram_gib swap_def
  ram_kb=$(awk '/^MemTotal/ {print $2}' /proc/meminfo)
  ram_gib=$(( (ram_kb + 1048575) / 1048576 ))
  swap_def=$(( (ram_gib + 1) / 2 ))
  (( swap_def < 1 )) && swap_def=1
  SWAP_GIB=$(ask_int "Swap" "Swap mérete GiB-ben. Ajánlott: ${swap_def} GiB.\n0 = NINCS swap." "$swap_def" 0 64) || cancel
  (( SWAP_GIB > 0 )) && USE_SWAP=1

  if yn "Külön /home" "Legyen külön /home partíció?"; then
    USE_HOME=1
    local root_def=$DEFAULT_ROOT_GIB root_max
    root_max=$(( DISK_GIB - ESP_SIZE_GIB - SWAP_GIB - 5 ))   # legalább 5 GiB maradjon a /home-nak
    (( root_def > root_max )) && root_def=$root_max
    (( DISK_GIB < 150 && root_def > DISK_GIB / 2 )) && root_def=$(( DISK_GIB / 2 ))
    (( root_def < 15 )) && root_def=15
    (( root_max >= 15 )) || die "Nincs elég hely külön /home-hoz ($DISK_GIB GiB lemez)."
    ROOT_GIB=$(ask_int "Root mérete" "A root (/) partíció mérete GiB-ben (15 - ${root_max}).\nA /home a maradék helyet kapja." "$root_def" 15 "$root_max") || cancel
    HOME_FS=$(pick_fs "/home fájlrendszere") || cancel
  fi
  ROOT_FS=$(pick_fs "Root (/) fájlrendszere") || cancel

  ESP_PART=$(part_path "$TARGET" 1)
  ROOT_PART=$(part_path "$TARGET" 2)
  local n=3
  (( USE_HOME )) && { HOME_PART=$(part_path "$TARGET" $n); n=$((n+1)); }
  (( USE_SWAP )) && SWAP_PART=$(part_path "$TARGET" $n)
  ESP_MOUNT=/boot
}

# A /home MARAD: a mellette lévő területet számoljuk át (tiszta aritmetika, külön tesztelhető)
#   bemenet: logikai szektorméret, home start/méret (512-es egységben), lemezméret bájtban
keephome_math() {
  local lss=$1 hs512=$2 hl512=$3 disk_bytes=$4
  local gib=$(( 1073741824 / lss )) align=$(( 1048576 / lss ))
  local h_start=$(( hs512 * 512 / lss )) h_len=$(( hl512 * 512 / lss ))
  local h_end=$(( h_start + h_len - 1 )) disk_ls=$(( disk_bytes / lss ))
  ESP_S=$align
  ESP_E=$(( ESP_S + ESP_SIZE_GIB * gib - 1 ))
  ROOT_S=$(( ESP_E + 1 ))
  ROOT_E=$(( h_start - 1 ))
  ROOT_GIB=$(( (ROOT_E - ROOT_S + 1) / gib ))
  TAIL_S=$(( (h_end + 1 + align - 1) / align * align ))
  TAIL_GIB=$(( (disk_ls - 34 - TAIL_S) / gib ))
  (( TAIL_GIB < 0 )) && TAIL_GIB=0
  GIB_SECT=$gib
  return 0
}

ask_disk_keephome() {
  local -a dm items=()
  mapfile -t dm < <(list_disks)
  (( ${#dm[@]} > 0 )) || die "Nem találtam lemezt."
  TARGET=$(menu "Célmeghajtó" "Melyik lemezen van a megtartandó /home partíció?\n\nA /home MARAD; a lemez TÖBBI partíciója (EFI, root, swap...)\nTÖRLŐDIK, és újra létrejön." "${dm[@]}") || cancel
  [[ $(lsblk -dno PTTYPE "$TARGET" 2>/dev/null) == gpt ]] || die "A $TARGET lemez nem GPT táblás, ez a mód csak GPT-vel működik."

  local dev
  while read -r dev; do
    items+=("$dev" "$(lsf SIZE "$dev")  $(lsf FSTYPE "$dev")  $(lsf LABEL "$dev")")
  done < <(lsblk -pnro NAME,TYPE "$TARGET" | awk '$2=="part"{print $1}')
  (( ${#items[@]} > 0 )) || die "A $TARGET lemezen nincs partíció."
  HOME_PART=$(menu "/home partíció" "Melyik partíció a megtartandó /home?" "${items[@]}") || cancel
  HOME_FS=$(blkid -s TYPE -o value "$HOME_PART" 2>/dev/null || true)
  case $HOME_FS in ext4|btrfs|xfs) ;; *) die "A $HOME_PART fájlrendszere ('${HOME_FS:-ismeretlen}') nem használható /home-nak (ext4/btrfs/xfs kell)." ;; esac
  HOME_UUID=$(blkid -s UUID -o value "$HOME_PART")
  USE_HOME=1; FORMAT_HOME=0; FORMAT_ESP=1

  local sys=/sys/class/block/${HOME_PART##*/} lss
  lss=$(blockdev --getss "$TARGET")
  keephome_math "$lss" "$(<"$sys/start")" "$(<"$sys/size")" "$(blockdev --getsize64 "$TARGET")"
  (( ROOT_GIB >= 15 )) || die "A /home előtt csak ${ROOT_GIB} GiB hely van (EFI + root), legalább 16 GiB kell.\nEnnél a /home-nál ez a mód nem használható."

  # Swap: a /home MÖGÖTTI szabad helyből
  local ram_kb ram_gib swap_def
  ram_kb=$(awk '/^MemTotal/ {print $2}' /proc/meminfo)
  ram_gib=$(( (ram_kb + 1048575) / 1048576 ))
  swap_def=$(( (ram_gib + 1) / 2 )); (( swap_def < 1 )) && swap_def=1
  (( swap_def > TAIL_GIB )) && swap_def=$TAIL_GIB
  if (( TAIL_GIB >= 1 )); then
    SWAP_GIB=$(ask_int "Swap" "A /home mögött ${TAIL_GIB} GiB szabad hely van.\nSwap mérete GiB-ben. Ajánlott: ${swap_def} GiB.\n0 = NINCS swap." "$swap_def" 0 "$TAIL_GIB") || cancel
  else
    msg "Swap" "A /home mögött nincs elég szabad hely, swap partíció nélkül telepítek."
    SWAP_GIB=0
  fi
  if (( SWAP_GIB > 0 )); then
    USE_SWAP=1
    SWAP_S=$TAIL_S
    SWAP_E=$(( SWAP_S + SWAP_GIB * GIB_SECT - 1 ))
  fi

  # Partíciószámok: a /home száma kimarad
  local hnum nums=() cand=1
  hnum=$(<"$sys/partition")
  while (( ${#nums[@]} < 3 )); do (( cand == hnum )) || nums+=("$cand"); cand=$((cand+1)); done
  ESP_NUM=${nums[0]}; ROOT_NUM=${nums[1]}; SWAP_NUM=${nums[2]}

  # Mi törlődik?
  local list=""
  while read -r dev; do
    [[ $dev == "$HOME_PART" ]] && continue
    DEL_PARTS+=("$dev")
    list+="  $dev   $(lsf SIZE "$dev")  $(lsf FSTYPE "$dev")  $(lsf LABEL "$dev")\n"
  done < <(lsblk -pnro NAME,TYPE "$TARGET" | awk '$2=="part"{print $1}')
  ynn "Törlendő partíciók" "A(z) $HOME_PART ($HOME_FS) /home MEGMARAD.\n\nEzek a partíciók TÖRLŐDNEK, majd újra létrejönnek:\n${list}\nA root ${ROOT_GIB} GiB lesz (a /home előtti teljes hely).\n\nBiztosan ezt akarod?" || cancel

  ROOT_FS=$(pick_fs "Root (/) fájlrendszere") || cancel
  ESP_PART=$(part_path "$TARGET" "$ESP_NUM")
  ROOT_PART=$(part_path "$TARGET" "$ROOT_NUM")
  (( USE_SWAP )) && SWAP_PART=$(part_path "$TARGET" "$SWAP_NUM")
  ESP_MOUNT=/boot
}

ask_disk_existing() {
  msg "Meglévő partíciók" "Válaszd ki a partíciókat. A meglévő /home adatait is itt döntheted el."
  ESP_PART=$(pick_part "EFI (boot) partíció" "Melyik az EFI System Partition (FAT32)?") || cancel
  USED_PARTS+=("$ESP_PART")
  local esp_fs; esp_fs=$(blkid -s TYPE -o value "$ESP_PART" 2>/dev/null || true)
  if [[ $esp_fs == vfat ]]; then
    ynn "EFI formázása" "Formázzam az EFI partíciót?\n\nNEM ajánlott, ha Windows is használja!" && FORMAT_ESP=1 || FORMAT_ESP=0
  else
    FORMAT_ESP=1
  fi

  ROOT_PART=$(pick_part "Root (/) partíció" "Melyik partícióra kerüljön a rendszer?") || cancel
  USED_PARTS+=("$ROOT_PART")
  ROOT_FS=$(pick_fs "Root (/) fájlrendszere") || cancel

  if yn "Külön /home" "Van külön /home partíció?"; then
    USE_HOME=1
    HOME_PART=$(pick_part "/home partíció" "Melyik partíció legyen a /home?") || cancel
    USED_PARTS+=("$HOME_PART")
    if ynn "/home formázása" "Formázzam a /home partíciót?\n\nIGEN = Minden adat törlődik tiszta lappal.\nNEM = A meglévő fájlok és beállítások MEGMARADNAK."; then
      FORMAT_HOME=1
      HOME_FS=$(pick_fs "/home fájlrendszere") || cancel
    else
      FORMAT_HOME=0
      HOME_FS=$(blkid -s TYPE -o value "$HOME_PART" 2>/dev/null || true)
      [[ -n $HOME_FS ]] || die "A $HOME_PART partíción nem ismerhető fel fájlrendszer."
    fi
  fi

  if yn "Swap" "Használjunk swap partíciót?"; then
    SWAP_PART=$(pick_part "Swap partíció" "Melyik partíció legyen a swap?") || cancel
    USED_PARTS+=("$SWAP_PART"); USE_SWAP=1
  fi

  local esp_mb; esp_mb=$(( $(blockdev --getsize64 "$ESP_PART") / 1048576 ))
  if (( FORMAT_ESP == 1 && esp_mb >= 500 )); then ESP_MOUNT=/boot; else ESP_MOUNT=/boot/efi; fi
}

confirm_all() {
  local s=""
  s+="Gépnév:         $HOSTNAME_\n"
  s+="Felhasználó:    $USERNAME_\n"
  s+="Asztali:        $DE     Videókártya: $GPU\n"
  s+="Extrák:         $(tr '\n' ' ' <<<"$EXTRAS")\n\n"
  case $MODE in
    new)      s+="LEMEZ:  $TARGET  --  a TELJES tartalma TÖRLŐDIK!\n" ;;
    keephome) s+="LEMEZ:  $TARGET  --  a /home MARAD, törlődik: ${DEL_PARTS[*]}\n" ;;
    *)        s+="LEMEZ:  meglévő partíciók használata\n" ;;
  esac
  s+="  EFI   $ESP_PART  ->  $ESP_MOUNT   $( ((FORMAT_ESP)) && echo '[FORMÁZÁS]' || echo '[megmarad]' )\n"
  s+="  root  $ROOT_PART  ($ROOT_FS)   [FORMÁZÁS]\n"
  if (( USE_HOME )); then
    s+="  home  $HOME_PART  ($HOME_FS)   $( ((FORMAT_HOME)) && echo '[FORMÁZÁS]' || echo '[ADATOK MEGMARADNAK]' )\n"
  else
    s+="  home  (nincs külön partíció)\n"
  fi
  if (( USE_SWAP )); then s+="  swap  $SWAP_PART\n"; else s+="  swap  (nincs)\n"; fi
  s+="\nElindítsuk a telepítést?"
  dialog --backtitle "$BACKTITLE" --cr-wrap --no-collapse --defaultno \
         --title "Összegzés" --yesno "$s" 0 0 || cancel
}

# ----------------------------------------------------- lemezműveletek -------
mkfs_any() {
  case $1 in
    ext4)  must mkfs.ext4 -q -F -L "$3" "$2" ;;
    btrfs) must mkfs.btrfs -q -f -L "$3" "$2" ;;
    xfs)   must mkfs.xfs -q -f -L "$3" "$2" ;;
  esac
}

prepare_disks() {
  step "Előző csatolások és swap leválasztása"
  swapoff -a 2>/dev/null || true
  umount -R /mnt 2>/dev/null || true

  if [[ $MODE == new ]]; then
    step "Particionálás: $TARGET"
    must wipefs -af "$TARGET"
    must sgdisk --zap-all "$TARGET"
    must sgdisk -n "1:0:+${ESP_SIZE_GIB}G" -t 1:ef00 -c 1:EFI "$TARGET"
    if (( USE_HOME )); then
      must sgdisk -n "2:0:+${ROOT_GIB}G" -t 2:8300 -c 2:root "$TARGET"
      if (( USE_SWAP )); then
        must sgdisk -n "3:0:-${SWAP_GIB}G" -t 3:8300 -c 3:home "$TARGET"
        must sgdisk -n "4:0:0" -t 4:8200 -c 4:swap "$TARGET"
      else
        must sgdisk -n "3:0:0" -t 3:8300 -c 3:home "$TARGET"
      fi
    else
      if (( USE_SWAP )); then
        must sgdisk -n "2:0:-${SWAP_GIB}G" -t 2:8300 -c 2:root "$TARGET"
        must sgdisk -n "3:0:0" -t 3:8200 -c 3:swap "$TARGET"
      else
        must sgdisk -n "2:0:0" -t 2:8300 -c 2:root "$TARGET"
      fi
    fi
    partprobe "$TARGET" 2>/dev/null || true
    udevadm settle
    sleep 2
  elif [[ $MODE == keephome ]]; then
    step "Partíciók újraépítése: $TARGET  (a /home érintetlen marad)"
    local dev num
    for dev in "${DEL_PARTS[@]}"; do
      num=$(<"/sys/class/block/${dev##*/}/partition")
      must sgdisk -d "$num" "$TARGET"
    done
    must sgdisk -n "${ESP_NUM}:${ESP_S}:${ESP_E}"   -t "${ESP_NUM}:ef00"  -c "${ESP_NUM}:EFI"  "$TARGET"
    must sgdisk -n "${ROOT_NUM}:${ROOT_S}:${ROOT_E}" -t "${ROOT_NUM}:8300" -c "${ROOT_NUM}:root" "$TARGET"
    (( USE_SWAP )) && must sgdisk -n "${SWAP_NUM}:${SWAP_S}:${SWAP_E}" -t "${SWAP_NUM}:8200" -c "${SWAP_NUM}:swap" "$TARGET"
    partprobe "$TARGET" 2>/dev/null || true
    udevadm settle
    sleep 2
    [[ $(blkid -s UUID -o value "$HOME_PART" 2>/dev/null) == "$HOME_UUID" ]] \
      || die "A /home partíció azonosítója megváltozott – leállok, hogy ne sérüljön az adat."
    for dev in "$ESP_PART" "$ROOT_PART" ${SWAP_PART:+"$SWAP_PART"}; do wipefs -af "$dev" >/dev/null 2>&1 || true; done
  fi

  step "Formázás"
  (( FORMAT_ESP )) && must mkfs.fat -F32 -n EFI "$ESP_PART"
  mkfs_any "$ROOT_FS" "$ROOT_PART" root
  if (( USE_HOME && FORMAT_HOME )); then mkfs_any "$HOME_FS" "$HOME_PART" home; fi
  if (( USE_SWAP )); then must mkswap -L swap "$SWAP_PART"; must swapon "$SWAP_PART"; fi

  step "Csatolás"
  must mount -o noatime "$ROOT_PART" /mnt
  must mkdir -p "/mnt$ESP_MOUNT"
  must mount "$ESP_PART" "/mnt$ESP_MOUNT"
  if (( USE_HOME )); then
    must mkdir -p /mnt/home
    must mount -o noatime "$HOME_PART" /mnt/home
  fi
  ok "Lemezek előkészítve."
}

# ----------------------------------------------------------- csomagok -------
build_package_list() {
  local ucode=""
  grep -q GenuineIntel /proc/cpuinfo && ucode=intel-ucode
  grep -q AuthenticAMD /proc/cpuinfo && ucode=amd-ucode

  PKGS=(base base-devel linux linux-firmware linux-headers $ucode terminus-font
        nano micro git sudo curl wget networkmanager
        grub efibootmgr os-prober dosfstools ntfs-3g exfatprogs e2fsprogs
        bash-completion man-db man-pages pacman-contrib reflector
        htop glances duf inxi lsb-release mc unzip unrar 7zip
        udisks2 gvfs gvfs-afc gvfs-gphoto2 gvfs-mtp gvfs-nfs gvfs-smb
        gnome-disk-utility bluez bluez-utils blueberry
        pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber gst-plugin-pipewire pavucontrol
        noto-fonts noto-fonts-emoji ttf-dejavu ttf-liberation
        firefox firefox-i18n-hu keepassxc qbittorrent audacious okular fastfetch accountsservice)

  [[ $ROOT_FS == btrfs || $HOME_FS == btrfs ]] && PKGS+=(btrfs-progs)
  [[ $ROOT_FS == xfs   || $HOME_FS == xfs   ]] && PKGS+=(xfsprogs)

  case $DE in
    xfce)  PKGS+=(xorg-server xfce4-session xfce4-settings xfce4-panel xfce4-appfinder xfce4-power-manager
                  xfce4-taskmanager xfce4-terminal xfce4-notifyd xfce4-screenshooter xfce4-pulseaudio-plugin
                  xfce4-whiskermenu-plugin xfconf xfdesktop xfwm4 thunar thunar-archive-plugin
                  thunar-media-tags-plugin thunar-volman file-roller mousepad ristretto galculator parole
                  lightdm lightdm-gtk-greeter numlockx network-manager-applet adwaita-icon-theme xdg-user-dirs
                  mugshot xorg-xrandr) ;;
    gnome) PKGS+=(xorg-server gnome gdm xdg-user-dirs) ;;
    kde)   PKGS+=(xorg-server plasma-meta sddm konsole dolphin kate ark xdg-user-dirs) ;;
    none)  PKGS+=(xdg-user-dirs) ;;
  esac

  case $GPU in
    nvidia) PKGS+=(nvidia-open nvidia-settings nvidia-utils lib32-nvidia-utils opencl-nvidia libva-nvidia-driver) ;;
    amd)    PKGS+=(mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon libva-mesa-driver) ;;
    intel)  PKGS+=(mesa lib32-mesa intel-media-driver vulkan-intel lib32-vulkan-intel) ;;
    other)  has gaming && PKGS+=(mesa lib32-mesa vulkan-swrast lib32-vulkan-swrast) ;;
  esac

  has office  && PKGS+=(libreoffice-fresh libreoffice-fresh-hu hunspell-hu mythes-hu aspell-hu)
  has gaming  && PKGS+=(steam lutris gamemode lib32-gamemode gamescope mangohud wine wine-gecko wine-mono
                        lib32-freetype2 lib32-gnutls lib32-libglvnd lib32-vulkan-icd-loader)
  has vbox    && PKGS+=(virtualbox virtualbox-host-dkms)
  has freecad && PKGS+=(freecad)
  has solidcraft && PKGS+=(fuse2 fuse3)
  has flatpak && PKGS+=(flatpak)
  has samba   && PKGS+=(samba)
  has media   && PKGS+=(yt-dlp ffmpeg)
  [[ $DE == xfce ]] && has screensaver && PKGS+=(xscreensaver)
  if [[ $DE == xfce ]]; then
    case $DARKTHEME in
      arc)     PKGS+=(arc-gtk-theme papirus-icon-theme kvantum kvantum-qt5) ;;
      materia) PKGS+=(materia-gtk-theme papirus-icon-theme kvantum kvantum-qt5 kvantum-theme-materia) ;;
    esac
  fi
}

filter_packages() {
  declare -A HAVE=()
  local p
  while read -r p; do HAVE["$p"]=1; done < <(pacman -Slq; pacman -Sgq)
  FINAL=(); SKIPPED=()
  for p in "${PKGS[@]}"; do
    if [[ -n ${HAVE[$p]:-} ]]; then FINAL+=("$p"); else SKIPPED+=("$p"); fi
  done
  if (( ${#SKIPPED[@]} )); then
    warn "Nem található csomagok (kihagyva): ${SKIPPED[*]}"
    printf 'KIHAGYOTT: %s\n' "${SKIPPED[*]}" >> "$LOG_FILE"
  fi
}

install_base() {
  step "Csomaglisták összeállítása és pacstrap"
  build_package_list
  filter_packages
  
  local n=0
  until run_logged pacstrap -K /mnt "${FINAL[@]}"; do
    n=$((n+1))
    (( n >= 3 )) && die "A pacstrap háromszor is hibázott (napló: $LOG_FILE)."
    warn "pacstrap hiba, újrapróbálom ($n/3)..."
    sleep 5
  done

  step "fstab generálás és extra lemezek"
  must genfstab -U /mnt > /mnt/etc/fstab
  if has drives; then
    must mkdir -p /mnt/Games /mnt/Download
    cat >> /mnt/etc/fstab <<EOF
UUID=${GAMES_UUID} /Games ext4 defaults,noatime,nofail,x-gvfs-show,x-gvfs-name=Games 0 2
UUID=${DOWNLOAD_UUID} /Download ntfs3 defaults,noatime,uid=1000,gid=1000,umask=022,nofail,x-gvfs-show,x-gvfs-name=Downloads 0 0
EOF
  fi

  tune_pacman /mnt/etc/pacman.conf
  sed -i "s/^#\?MAKEFLAGS=.*/MAKEFLAGS=\"-j$(nproc)\"/" /mnt/etc/makepkg.conf
}

# ---------------------------------------------------- chroot szkript --------
write_chroot_script() {
  local home_new=1
  (( USE_HOME && FORMAT_HOME == 0 )) && home_new=0
  {
    printf 'I_HOST=%q\n'  "$HOSTNAME_"
    printf 'I_USER=%q\n'  "$USERNAME_"
    printf 'I_DE=%q\n'    "$DE"
    printf 'I_GPU=%q\n'   "$GPU"
    printf 'I_EXTRAS=%q\n' "$EXTRAS"
    printf 'I_TZ=%q\n'    "$TIMEZONE"
    printf 'I_LOCALE=%q\n' "$MAIN_LOCALE"
    printf 'I_KEYMAP=%q\n' "$KEYMAP"
    printf 'I_FONT=%q\n'    "$CONSOLE_FONT"
    printf 'I_ESP=%q\n'   "$ESP_MOUNT"
    printf 'I_ESP_FORMATTED=%q\n' "$FORMAT_ESP"
    printf 'I_HOME_NEW=%q\n' "$home_new"
    printf 'I_XFCE_URL=%q\n' "$XFCE_PROFILE_URL"
    printf 'I_MIRRORS=%q\n' "$MIRROR_COUNTRIES"
    printf 'I_GRUBTHEME=%q\n' "$GRUBTHEME"
    printf 'I_DARK=%q\n' "$DARKTHEME"
    printf 'I_AUD_SKIN=%q\n' "$AUDACIOUS_SKIN"
    printf 'I_SC_URL=%q\n' "$SOLIDCRAFT_URL"
    printf 'I_GH_USER=%q\n' "$GH_USER"
    printf 'I_GH_REPO=%q\n' "$GH_REPO"
    printf 'I_GH_BRANCH=%q\n' "$GH_BRANCH"
  } > /mnt/root/install.env
  chmod 600 /mnt/root/install.env

  cat > /mnt/root/chroot-setup.sh <<'CHROOT'
#!/usr/bin/env bash
set -u
source /root/install.env
has() { grep -qx "$1" <<<"$I_EXTRAS"; }
need_aur() { has aur || has rustdesk || has glava; }
case ${I_DARK:-none} in
  arc)     GTK_THEME=Arc-Dark;      WM_THEME=Arc-Dark;      KV_THEME=KvArcDark ;;
  materia) GTK_THEME=Materia-dark;  WM_THEME=Materia-dark;  KV_THEME=MateriaDark ;;
  *)       GTK_THEME="";            WM_THEME="";            KV_THEME="" ;;
esac
ICON_THEME=Papirus-Dark
say()  { printf '\n\e[1;36m  -> %s\e[0m\n' "$*"; }
warn() { printf '\e[1;33m  [!] %s\e[0m\n' "$*"; }

ALIASES=$(cat <<'ALIASBLOCK'
# --- pbalee aliasok ---
alias cl='clear'
alias e='exit'
alias sr='sudo reboot'
alias in='sudo pacman -S '
alias rem='arch-clean'
alias u='arch-update'
alias ll='ls -lah --color=auto'
alias ls='ls --color=auto'
alias grep='grep --color=auto'
if command -v yay >/dev/null 2>&1; then alias y='yay -Syu'; else alias y='sudo pacman -Syu'; fi
ALIASBLOCK
)
add_aliases() { grep -q 'pbalee aliasok' "$1" 2>/dev/null || printf '\n%s\n' "$ALIASES" >> "$1"; }

# Új home: mindent a felhasználóra állítunk. Meglévő home: csak amit mi hoztunk létre.
fix_home_owner() {
  local h="/home/$I_USER" want f
  want=$(id -u "$I_USER")
  if [[ $I_HOME_NEW == 1 || $(stat -c %u "$h") != "$want" ]]; then
    chown -R "$I_USER:$I_USER" "$h"
  else
    for f in .bashrc .face .xscreensaver .config/autostart .config/glava .config/xfce4 .config/audacious .config/gtk-3.0 .config/gtk-4.0 .config/Kvantum .config/kdeglobals .local/bin .local/share/audacious; do
      [[ -e $h/$f ]] && chown -R "$I_USER:$I_USER" "$h/$f"
    done
  fi
}

dl_pic() {   # dl_pic <mappa> <fájlnév> – meglévőt nem írunk felül
  local f="$1/$2"
  [[ -s $f ]] && return 0
  if curl -fsSL -o "$f" "https://raw.githubusercontent.com/${I_GH_USER}/${I_GH_REPO}/${I_GH_BRANCH}/Pictures/$2"; then
    chown "$I_USER:$I_USER" "$f"
  else
    rm -f "$f"
  fi
}

phase1() {
  say "Idő, nyelv, billentyűzet, konzol betűtípus ($I_FONT), gépnév"
  ln -sf "/usr/share/zoneinfo/$I_TZ" /etc/localtime
  hwclock --systohc
  sed -i -e 's/^#\(hu_HU.UTF-8 UTF-8\)/\1/' -e 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
  locale-gen
  echo "LANG=$I_LOCALE" > /etc/locale.conf
  
  cat > /etc/vconsole.conf <<EOF
KEYMAP=$I_KEYMAP
FONT=$I_FONT
EOF

  say "initramfs újragenerálása (billentyűzetkiosztás, betűtípus)"
  mkinitcpio -P || warn "mkinitcpio figyelmeztetés."

  echo "$I_HOST" > /etc/hostname
  cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $I_HOST.localdomain $I_HOST
EOF

  mkdir -p /etc/X11/xorg.conf.d
  cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<EOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$I_KEYMAP"
EndSection
EOF

  if [[ $I_DE == xfce ]] && has screensaver; then
    cat > /etc/X11/xorg.conf.d/10-no-blanking.conf <<'EOF'
# Energiagazdálkodás KI: az X szerver ne sötétítse / kapcsolja ki a képernyőt
Section "ServerFlags"
    Option "BlankTime"   "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"     "0"
EndSection
EOF
  fi

  say "USB dirty bytes és udisks2 mount opciók"
  mkdir -p /etc/sysctl.d /etc/udisks2
  cat > /etc/sysctl.d/99-usb-dirty-bytes.conf <<'EOF'
vm.dirty_background_bytes = 16777216
vm.dirty_bytes = 50331648
EOF

  cat > /etc/udisks2/mount_options.conf <<'EOF'
[defaults]
vfat_defaults=uid=$UID,gid=$GID,shortname=mixed,utf8=1,showexec,flush
exfat_defaults=uid=$UID,gid=$GID,iocharset=utf8,errors=remount-ro
EOF

  # (A korábbi udev RUN+=udisksctl szabály kimaradt: rootként csatolta volna a
  #  pendrive-okat uid=0-val. A "flush" opció így is benne van az udisks2 beállításban.)

  say "Samba (WORKGROUP) konfigurálása"
  if has samba; then
    mkdir -p /etc/samba
    cat > /etc/samba/smb.conf <<'EOF'
[global]
   workgroup = WORKGROUP
   security = user
   map to guest = Bad User
EOF
  fi

  say "Takarítószkript és aliasok"
  cat > /usr/local/bin/arch-clean <<'ARCHCLEAN'
#!/usr/bin/env bash
echo "==> Csomag-gyorsítótár takarítása (2 verzió marad)"
sudo paccache -rk2
orphans=$(pacman -Qtdq 2>/dev/null || true)
if [[ -n $orphans ]]; then
  echo "==> Árva csomagok eltávolítása"
  sudo pacman -Rns --noconfirm $orphans
fi
echo "==> Journal takarítása (7 nap marad)"
sudo journalctl --vacuum-time=7d
echo "Takarítás kész!"
ARCHCLEAN
  chmod +x /usr/local/bin/arch-clean
  cat > /usr/local/bin/arch-update <<'ARCHUPD'
#!/usr/bin/env bash
echo "==> Pacman csomagok frissítése"
sudo pacman -Syu
if command -v flatpak >/dev/null 2>&1; then
  echo "==> Flatpak csomagok frissítése"
  flatpak update -y
fi
echo "Frissítés kész!"
ARCHUPD
  chmod +x /usr/local/bin/arch-update
  add_aliases /etc/skel/.bashrc
  add_aliases /root/.bashrc

  say "Felhasználó és sudo"
  echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
  chmod 440 /etc/sudoers.d/10-wheel
  local groups="" g
  for g in wheel storage power input video audio optical vboxusers uucp; do
    getent group "$g" >/dev/null && groups+="${groups:+,}$g"
  done
  # Meglévő /home esetén a régi tulajdonos UID/GID-jét használjuk, hogy a fájlok "sajátok" maradjanak
  local uid_opt=() ouid
  if [[ -d /home/$I_USER ]]; then
    ouid=$(stat -c %u "/home/$I_USER")
    if [[ $ouid =~ ^[0-9]+$ ]] && (( ouid >= 1000 )) && ! getent passwd "$ouid" >/dev/null && ! getent group "$ouid" >/dev/null; then
      groupadd -g "$ouid" "$I_USER" && uid_opt=(-u "$ouid" -g "$I_USER")
    fi
  fi
  useradd -m "${uid_opt[@]}" -G "$groups" -s /bin/bash "$I_USER" || warn "Useradd figyelmeztetés."
  cp -rn /etc/skel/. "/home/$I_USER/" 2>/dev/null
  add_aliases "/home/$I_USER/.bashrc"
  fix_home_owner

  say "Szolgáltatások engedélyezése"
  mkdir -p /etc/xdg/reflector
  cat > /etc/xdg/reflector/reflector.conf <<EOF
--save /etc/pacman.d/mirrorlist
--protocol https
--country $I_MIRRORS
--age 24
--latest 15
--sort rate
EOF
  systemctl enable NetworkManager bluetooth fstrim.timer paccache.timer systemd-timesyncd reflector.timer
  has samba && systemctl enable smb nmb
  
  case $I_DE in
    xfce)
      systemctl enable lightdm
      sed -i 's/^#\?greeter-session=.*/greeter-session=lightdm-gtk-greeter/' /etc/lightdm/lightdm.conf
      sed -i 's/^#\?display-setup-script=.*/display-setup-script=numlockx on/' /etc/lightdm/lightdm.conf
      # LightDM X11 kényszerítés (Wayland tiltása)
      if grep -q "^#\?user-session=" /etc/lightdm/lightdm.conf; then
        sed -i 's/^#\?user-session=.*/user-session=xfce/' /etc/lightdm/lightdm.conf
      else
        sed -i '/\[Seat:\*\]/a user-session=xfce' /etc/lightdm/lightdm.conf
      fi
      if [[ -n $GTK_THEME && -f /etc/lightdm/lightdm-gtk-greeter.conf ]]; then
        ini_set /etc/lightdm/lightdm-gtk-greeter.conf greeter theme-name "$GTK_THEME"
        ini_set /etc/lightdm/lightdm-gtk-greeter.conf greeter icon-theme-name "$ICON_THEME"
      fi
      if [[ -n $KV_THEME ]]; then
        # Qt-programok (KeePassXC, qBittorrent, Okular...) sötét témája: Kvantum stílus + GTK-s ikon/betű
        grep -q '^QT_STYLE_OVERRIDE=' /etc/environment 2>/dev/null || printf 'QT_STYLE_OVERRIDE=kvantum\nQT_QPA_PLATFORMTHEME=gtk3\n' >> /etc/environment
      fi
      ;;
    gnome) systemctl enable gdm ;;
    kde)   systemctl enable sddm ;;
  esac

  say "GRUB beállítások (os-prober, időtúllépés)"
  local grub_dir="/boot/grub"
  setvar() {
    if grep -q "^#\?$1=" /etc/default/grub; then sed -i "s|^#\?$1=.*|$1=$2|" /etc/default/grub
    else echo "$1=$2" >> /etc/default/grub; fi
  }
  setvar GRUB_DISABLE_OS_PROBER false
  setvar GRUB_TIMEOUT 5
  if [[ $I_GPU == nvidia ]] && ! grep -q 'nvidia-drm.modeset' /etc/default/grub; then
    sed -i 's|^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"|\1 nvidia-drm.modeset=1 nvidia-drm.fbdev=1"|' /etc/default/grub
  fi

  mkdir -p "$grub_dir/themes"
  grub_theme_on() {   # <téma-mappa neve>
    setvar GRUB_THEME "\"$grub_dir/themes/$1/theme.txt\""
    setvar GRUB_GFXMODE "\"1920x1080,auto\""
    setvar GRUB_GFXPAYLOAD_LINUX keep
    sed -i -E 's|^(GRUB_TERMINAL(_OUTPUT)?=.*console.*)|#\1|' /etc/default/grub
  }
  case $I_GRUBTHEME in
    blackice)
      say "Blackice GRUB téma telepítése GitHubról"
      if curl -fsSL -o /tmp/repo.tar.gz "https://github.com/${I_GH_USER}/${I_GH_REPO}/archive/refs/heads/${I_GH_BRANCH}.tar.gz" \
         && tar -xzf /tmp/repo.tar.gz -C /tmp; then
        local extracted_dir="/tmp/${I_GH_REPO}-${I_GH_BRANCH}"
        if [[ -f "$extracted_dir/blackice/theme.txt" ]]; then
          rm -rf "$grub_dir/themes/blackice"
          cp -r "$extracted_dir/blackice" "$grub_dir/themes/blackice"
          grub_theme_on blackice
        else
          warn "A repóban nincs blackice/theme.txt, téma nélkül folytatom."
        fi
      else
        warn "A GRUB téma letöltése nem sikerült, téma nélkül folytatom."
      fi
      rm -rf /tmp/repo.tar.gz "/tmp/${I_GH_REPO}-${I_GH_BRANCH}" 2>/dev/null || true
      ;;
    hyperfluent)
      say "HyperFluent GRUB téma (Arch változat) telepítése"
      rm -rf /tmp/hyperfluent
      if git clone --depth 1 https://github.com/Coopydood/HyperFluent-GRUB-Theme.git /tmp/hyperfluent \
         && [[ -f /tmp/hyperfluent/arch/theme.txt ]]; then
        rm -rf "$grub_dir/themes/hyperfluent"
        cp -r /tmp/hyperfluent/arch "$grub_dir/themes/hyperfluent"
        grub_theme_on hyperfluent
      else
        warn "A HyperFluent téma letöltése nem sikerült, téma nélkül folytatom."
      fi
      rm -rf /tmp/hyperfluent
      ;;
    *) say "GRUB téma nélkül" ;;
  esac

  say "GRUB telepítése (UEFI)"
  mkdir -p /run/udev
  [[ -d /udev-host ]] && mount --bind /udev-host /run/udev
  local ok_grub=0
  # 1) rendes NVRAM-bejegyzéssel
  if grub-install --target=x86_64-efi --efi-directory="$I_ESP" --bootloader-id=GRUB --recheck; then ok_grub=1
  else warn "grub-install (NVRAM-bejegyzéssel) nem sikerült."; fi
  # 2) fallback útvonal (EFI/BOOT/BOOTX64.EFI): új ESP-nél, vagy ha az 1) elhasalt.
  #    Meglévő (pl. Windows-os) ESP-n NEM írjuk felül a közös fallback fájlt.
  if [[ $I_ESP_FORMATTED == 1 || $ok_grub == 0 ]]; then
    grub-install --target=x86_64-efi --efi-directory="$I_ESP" --bootloader-id=GRUB --removable --recheck && ok_grub=1 \
      || warn "grub-install --removable sem sikerült."
  fi
  grub-mkconfig -o "$grub_dir/grub.cfg"
  mountpoint -q /run/udev && umount /run/udev
  if (( ok_grub == 0 )) || [[ ! -s "$grub_dir/grub.cfg" ]]; then
    warn "A GRUB telepítése NEM sikerült!"
    return 1
  fi
  grep -q 'menuentry' "$grub_dir/grub.cfg" || { warn "A grub.cfg-ben nincs menüpont!"; return 1; }
}

aur_build() {
  local pkgs=() pkg
  has aur      && pkgs+=(yay-bin google-chrome)
  has rustdesk && pkgs+=(rustdesk-bin)
  has glava    && pkgs+=(glava ksuperkey)
  say "AUR csomagok: ${pkgs[*]}"
  # Az ideiglenes építő felhasználó home-ja nem a /home alatt van (meglévő /home védelme)
  useradd -m -d /var/tmp/builder -s /bin/bash builder
  echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-builder
  chmod 440 /etc/sudoers.d/99-builder

  for pkg in "${pkgs[@]}"; do
    say "AUR: $pkg"
    runuser -l builder -c "rm -rf /tmp/$pkg && cd /tmp && git clone https://aur.archlinux.org/$pkg.git && cd $pkg && makepkg -si --noconfirm" || warn "Nem sikerült: $pkg"
  done
  userdel -r builder 2>/dev/null
  rm -f /etc/sudoers.d/99-builder

  if has rustdesk && pacman -Q rustdesk-bin >/dev/null 2>&1; then
    systemctl enable rustdesk || warn "A rustdesk szolgáltatás engedélyezése nem sikerült."
  fi
}

# ---------- segédfüggvények (a felhasználói beállításokhoz) ----------

# <xfce4-panel.xml> <ikon-útvonal>: a Whisker menü gomb ikonja (xfconf-ban van, nem rc-fájlban)
set_whisker_icon() {
  local x=$1 icon=$2 tmp
  [[ -f $x ]] || return 0
  tmp=$(mktemp)
  if awk -v icon="$icon" '
       /<property name="plugin-[0-9]+" type="string" value="whiskermenu"/ { inw=1; print; next }
       inw && /<property name="plugin-[0-9]+"/ { inw=0 }
       inw && /name="button-icon"/ { sub(/value="[^"]*"/, "value=\"" icon "\""); seen=1 }
       { print }
       END { exit seen ? 0 : 3 }' "$x" > "$tmp"; then
    cat "$tmp" > "$x"
  else
    # nincs még button-icon: beszúrjuk (önzáró és gyerekes plugin-bejegyzés is lehet)
    if grep -qE '<property name="plugin-[0-9]+" type="string" value="whiskermenu"/>' "$x"; then
      sed -i -E 's|(<property name="plugin-[0-9]+" type="string" value="whiskermenu")/>|\1>\n      <property name="button-icon" type="string" value="'"$icon"'"/>\n    </property>|' "$x"
    else
      sed -i -E '/<property name="plugin-[0-9]+" type="string" value="whiskermenu">/a\      <property name="button-icon" type="string" value="'"$icon"'"/>' "$x"
    fi
  fi
  rm -f "$tmp"
}

# <xml> <csatorna> <szülő-property> <kulcs> <érték>: string típusú xfconf-beállítás fájlban
set_xfconf_string() {
  local x=$1 ch=$2 parent=$3 key=$4 val=$5
  if [[ ! -f $x ]]; then
    printf '<?xml version="1.0" encoding="UTF-8"?>\n\n<channel name="%s" version="1.0">\n  <property name="%s" type="empty">\n    <property name="%s" type="string" value="%s"/>\n  </property>\n</channel>\n' \
      "$ch" "$parent" "$key" "$val" > "$x"
  elif grep -q "name=\"$key\" type=\"string\"" "$x"; then
    sed -i -E "s#(name=\"$key\" type=\"string\" value=\")[^\"]*\"#\1$val\"#" "$x"
  elif grep -q "<property name=\"$parent\" type=\"empty\">" "$x"; then
    sed -i -E "/<property name=\"$parent\" type=\"empty\">/a\\    <property name=\"$key\" type=\"string\" value=\"$val\"/>" "$x"
  else
    sed -i "s#</channel>#  <property name=\"$parent\" type=\"empty\">\n    <property name=\"$key\" type=\"string\" value=\"$val\"/>\n  </property>\n</channel>#" "$x"
  fi
}

# <xfce4-desktop.xml> <kép>: minden monitor / munkaterület háttere erre a képre
set_wallpaper_xml() {
  local x=$1 img=$2
  [[ -f $x ]] || return 1
  sed -i -E 's#(name="(last-image|image-path)" type="string" value=")[^"]*"#\1'"$img"'"#g' "$x"
}

# <thunar.xml>: a rejtett fájlok alapból ne látszódjanak
thunar_hidden_off() {
  local x=$1
  [[ -f $x ]] || return 0
  if grep -q 'name="last-show-hidden"' "$x"; then
    sed -i -E 's#(name="last-show-hidden" type="bool" value=")true"#\1false"#' "$x"
  else
    sed -i 's#</channel>#  <property name="last-show-hidden" type="bool" value="false"/>\n</channel>#' "$x"
  fi
}

# ini_set <fájl> <[szakasz]> <kulcs> <érték>
ini_set() {
  local f=$1 sec=$2 key=$3 val=$4 tmp
  mkdir -p "$(dirname "$f")"; [[ -f $f ]] || : > "$f"
  tmp=$(mktemp)
  awk -v sec="$sec" -v key="$key" -v val="$val" '
    BEGIN { insec=0; done=0 }
    /^\[/ { if (insec && !done) { print key "=" val; done=1 } insec = ($0 == "[" sec "]"); print; next }
    insec && index($0, key "=") == 1 { print key "=" val; done=1; next }
    { print }
    END { if (!done) { if (!insec) print "[" sec "]"; print key "=" val } }' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
}

# Profilkép: ~/.face (Whisker menü, Mugshot) + AccountsService (bejelentkező képernyő)
set_avatar() {
  local img=$1 h="/home/$I_USER"
  [[ -f $img ]] || return 0
  if [[ $I_HOME_NEW == 1 || ! -e $h/.face ]]; then
    cp -f "$img" "$h/.face"
    chown "$I_USER:$I_USER" "$h/.face"; chmod 644 "$h/.face"
  fi
  mkdir -p /var/lib/AccountsService/users /var/lib/AccountsService/icons
  chmod 755 /var/lib/AccountsService /var/lib/AccountsService/icons; chmod 700 /var/lib/AccountsService/users
  cp -f "$img" "/var/lib/AccountsService/icons/$I_USER"; chmod 644 "/var/lib/AccountsService/icons/$I_USER"
  printf '[User]\nIcon=/var/lib/AccountsService/icons/%s\n' "$I_USER" > "/var/lib/AccountsService/users/$I_USER"
  chmod 600 "/var/lib/AccountsService/users/$I_USER"
}

# Audacious Winamp-skin: a repó Skins/*.wsz fájljai -> ~/.local/share/audacious/Skins + [skins] skin=
audacious_skin() {
  local h="/home/$I_USER" src=/tmp/repo-src f skin="" cfg dir
  local -a files=()
  rm -rf "$src"; mkdir -p "$src"
  if ! { curl -fsSL -o /tmp/repo-src.tar.gz "https://github.com/${I_GH_USER}/${I_GH_REPO}/archive/refs/heads/${I_GH_BRANCH}.tar.gz" \
         && tar -xzf /tmp/repo-src.tar.gz -C "$src" --strip-components=1; }; then
    warn "A repó letöltése nem sikerült, az Audacious skin kimarad."; rm -rf "$src" /tmp/repo-src.tar.gz; return 0
  fi
  shopt -s nullglob
  files=("$src/Winamp Skins"/*.wsz "$src/Winamp Skins"/*.zip "$src"/Skins/*.wsz "$src"/Skins/*.zip)
  shopt -u nullglob
  if (( ${#files[@]} == 0 )); then
    say "Nincs "Winamp Skins/*.wsz" a GitHub-repóban, az Audacious skin kimarad."
    rm -rf "$src" /tmp/repo-src.tar.gz; return 0
  fi
  dir="$h/.local/share/audacious/Skins"
  mkdir -p "$dir"
  for f in "${files[@]}"; do cp -f "$f" "$dir/"; [[ ${f##*/} == "$I_AUD_SKIN" ]] && skin=${f##*/}; done
  [[ -n $skin ]] || skin=${files[0]##*/}
  cfg="$h/.config/audacious/config"
  if [[ $I_HOME_NEW == 1 ]] || ! grep -q '^skin=' "$cfg" 2>/dev/null; then
    ini_set "$cfg" skins skin "$dir/$skin"
  fi
  chown -R "$I_USER:$I_USER" "$h/.local/share/audacious" "$h/.config/audacious"
  say "Audacious skin: $skin"
  rm -rf "$src" /tmp/repo-src.tar.gz
}

# SolidCraft: GitHub release AppImage, SHA256 ellenőrzéssel
install_solidcraft() {
  local base=$I_SC_URL app=/opt/solidcraft/solidcraft.AppImage sums=/tmp/solidcraft.sums h
  say "SolidCraft telepítése (AppImage)"
  mkdir -p /opt/solidcraft
  if ! curl -fsSL -o "$app" "$base/solidcraft-linux-x86_64.AppImage"; then
    warn "A SolidCraft letöltése nem sikerült."; rm -f "$app"; return 0
  fi
  if curl -fsSL -o "$sums" "$base/SHA256SUMS.txt"; then
    h=$(sha256sum "$app" | cut -d' ' -f1)
    if ! grep -q "$h" "$sums"; then
      warn "A SolidCraft ellenőrzőösszege NEM egyezik, nem telepítem."; rm -f "$app" "$sums"; return 0
    fi
  else
    warn "Az ellenőrzőösszeg-fájl nem érhető el, ellenőrzés nélkül telepítem."
  fi
  rm -f "$sums"
  chmod 755 "$app"
  ln -sf "$app" /usr/local/bin/solidcraft
  cat > /usr/share/applications/solidcraft.desktop <<EOF
[Desktop Entry]
Type=Application
Name=SolidCraft
Comment=Parametrikus 3D CAD
Exec=$app %F
Icon=applications-engineering
Terminal=false
Categories=Graphics;Engineering;
EOF
}

aur_build() {
  local pkgs=() pkg
  has aur      && pkgs+=(yay-bin google-chrome)
  has rustdesk && pkgs+=(rustdesk-bin)
  has glava    && pkgs+=(glava ksuperkey)
  say "AUR csomagok: ${pkgs[*]}"
  # Az ideiglenes építő felhasználó home-ja nem a /home alatt van (meglévő /home védelme)
  useradd -m -d /var/tmp/builder -s /bin/bash builder
  echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-builder
  chmod 440 /etc/sudoers.d/99-builder

  for pkg in "${pkgs[@]}"; do
    say "AUR: $pkg"
    runuser -l builder -c "rm -rf /tmp/$pkg && cd /tmp && git clone https://aur.archlinux.org/$pkg.git && cd $pkg && makepkg -si --noconfirm" || warn "Nem sikerült: $pkg"
  done
  userdel -r builder 2>/dev/null
  rm -f /etc/sudoers.d/99-builder

  if has rustdesk && pacman -Q rustdesk-bin >/dev/null 2>&1; then
    systemctl enable rustdesk || warn "A rustdesk szolgáltatás engedélyezése nem sikerült."
  fi
}

xfce_user_setup() {
  local pic_dir=$1 h="/home/$I_USER" rc xml="/home/$I_USER/.config/xfce4/xfconf/xfce-perchannel-xml"
  mkdir -p "$h/.config/autostart" "$xml" "$h/.local/bin"

  # autostart <név> <stdin: .desktop tartalom> – új home-nál felülírjuk (a profilból származó régit is),
  # meglévő home-nál a felhasználó fájlját nem bántjuk
  autostart() {
    local f="$h/.config/autostart/$1.desktop"
    if [[ -e $f && $I_HOME_NEW != 1 ]]; then cat >/dev/null; else cat > "$f"; fi
  }

  if [[ $I_HOME_NEW == 1 ]]; then
    # Profil nélkül az alap panel "Alkalmazások" menüje helyett Whisker menü kerül a panelre
    if [[ ! -f $xml/xfce4-panel.xml && -f /etc/xdg/xfce4/panel/default.xml ]]; then
      sed 's/value="applicationsmenu"/value="whiskermenu"/' /etc/xdg/xfce4/panel/default.xml > "$xml/xfce4-panel.xml"
    fi
    # A Whisker menü gombjának ikonja: ~/Képek/menu.png (a panel-beállításban)
    [[ -f $pic_dir/menu.png ]] && set_whisker_icon "$xml/xfce4-panel.xml" "$pic_dir/menu.png"
    # Thunar: rejtett fájlok alapból rejtve
    thunar_hidden_off "$xml/thunar.xml"

    # Háttérkép: a profil (régi gépről származó) beállítását átírjuk, és első belépéskor
    # még egyszer, a tényleges monitorokra is beállítjuk (a chrootban nincs D-Bus / xfconf).
    if [[ -f $pic_dir/Wallpaper.jpg ]]; then
      set_wallpaper_xml "$xml/xfce4-desktop.xml" "$pic_dir/Wallpaper.jpg" || true
      cat > "$h/.local/bin/set-wallpaper-once" <<'WPEOF'
#!/usr/bin/env bash
img=$1
mkdir -p "$HOME/.cache"; exec >>"$HOME/.cache/set-wallpaper.log" 2>&1
for _ in $(seq 1 40); do pgrep -x xfdesktop >/dev/null && break; sleep 1; done
sleep 4
mapfile -t props < <(xfconf-query -c xfce4-desktop -l | grep '/last-image$')
for m in $(xrandr --listmonitors 2>/dev/null | awk 'NR>1 {print $NF}'); do
  props+=("/backdrop/screen0/monitor${m}/workspace0/last-image")
done
for p in "${props[@]}"; do
  xfconf-query -c xfce4-desktop -p "$p" -n -t string -s "$img"
  xfconf-query -c xfce4-desktop -p "${p%last-image}image-style" -n -t int -s 5
done
xfdesktop --reload 2>/dev/null
rm -f "$HOME/.config/autostart/set-wallpaper-once.desktop"
WPEOF
      chmod +x "$h/.local/bin/set-wallpaper-once"
      autostart set-wallpaper-once <<EOF
[Desktop Entry]
Type=Application
Name=Háttérkép beállítása (egyszeri)
Exec=$h/.local/bin/set-wallpaper-once "$pic_dir/Wallpaper.jpg"
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF
    fi
  fi

  # Sötét téma: GTK + ablakkeret + ikonok + Qt/Kvantum (új home-nál a profil régi beállítását is felülírja)
  if [[ -n $GTK_THEME ]]; then
    if [[ $I_HOME_NEW == 1 || ! -e $xml/xsettings.xml ]]; then
      set_xfconf_string "$xml/xsettings.xml" xsettings Net ThemeName "$GTK_THEME"
      set_xfconf_string "$xml/xsettings.xml" xsettings Net IconThemeName "$ICON_THEME"
    fi
    if [[ $I_HOME_NEW == 1 || ! -e $xml/xfwm4.xml ]]; then
      set_xfconf_string "$xml/xfwm4.xml" xfwm4 general theme "$WM_THEME"
    fi
    mkdir -p "$h/.config/gtk-3.0" "$h/.config/gtk-4.0" "$h/.config/Kvantum"
    if [[ $I_HOME_NEW == 1 || ! -e $h/.config/gtk-3.0/settings.ini ]]; then
      printf '[Settings]\ngtk-theme-name=%s\ngtk-icon-theme-name=%s\ngtk-application-prefer-dark-theme=1\n' "$GTK_THEME" "$ICON_THEME" > "$h/.config/gtk-3.0/settings.ini"
    fi
    if [[ $I_HOME_NEW == 1 || ! -e $h/.config/gtk-4.0/settings.ini ]]; then
      printf '[Settings]\ngtk-application-prefer-dark-theme=1\n' > "$h/.config/gtk-4.0/settings.ini"
    fi
    if [[ -n $KV_THEME && ( $I_HOME_NEW == 1 || ! -e $h/.config/Kvantum/kvantum.kvconfig ) ]]; then
      printf '[General]\ntheme=%s\n' "$KV_THEME" > "$h/.config/Kvantum/kvantum.kvconfig"
    fi
    # KDE/KF6 programok (Okular) ikontémája
    if [[ $I_HOME_NEW == 1 || ! -e $h/.config/kdeglobals ]]; then
      printf '[Icons]\nTheme=%s\n' "$ICON_THEME" > "$h/.config/kdeglobals"
    fi
  fi

  if has glava; then
    mkdir -p "$h/.config/glava"
    cp -rn /etc/xdg/glava/. "$h/.config/glava/" 2>/dev/null || true
    cat > "$h/.local/bin/glava-start" <<'GLV'
#!/usr/bin/env bash
# GLava indító: az aktuális kijelző geometriáját beírja az rc.glsl-be, majd elindítja a vizualizálót.
mkdir -p "$HOME/.cache" "$HOME/.config/glava"
exec >>"$HOME/.cache/glava-autostart.log" 2>&1
echo "=== $(date) ==="
command -v glava >/dev/null || { echo "glava nincs telepítve"; exit 1; }
[[ -f $HOME/.config/glava/rc.glsl ]] || cp -rn /etc/xdg/glava/. "$HOME/.config/glava/"
for _ in $(seq 1 40); do pgrep -x xfdesktop >/dev/null && break; sleep 1; done
sleep 5
g=$(xrandr --listmonitors 2>/dev/null | awk '/\*/ {print $3; exit}')
[[ -n $g ]] || g=$(xrandr --listmonitors 2>/dev/null | awk 'NR==2 {print $3}')
if [[ $g =~ ^([0-9]+)/[0-9]+x([0-9]+)/[0-9]+\+(-?[0-9]+)\+(-?[0-9]+)$ ]]; then
  rc="$HOME/.config/glava/rc.glsl"
  sed -i '/#request setgeometry/d' "$rc"
  printf '#request setgeometry %s %s %s %s\n' "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" >> "$rc"
  echo "geometria: ${BASH_REMATCH[3]} ${BASH_REMATCH[4]} ${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
else
  echo "a kijelző geometriája nem állapítható meg ('$g')"
fi
exec glava --desktop
GLV
    chmod +x "$h/.local/bin/glava-start"
    autostart glava <<EOF
[Desktop Entry]
Type=Application
Name=GLava
Exec=$h/.local/bin/glava-start
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF
    command -v ksuperkey >/dev/null 2>&1 && autostart ksuperkey <<EOF
[Desktop Entry]
Type=Application
Name=KSuperKey
Exec=ksuperkey
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF
  fi

  if has screensaver && command -v xscreensaver >/dev/null 2>&1; then
    autostart xscreensaver <<EOF
[Desktop Entry]
Type=Application
Name=XScreenSaver
Exec=xscreensaver -no-splash
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF
    # Képernyővédő: GL Matrix, 10 perc után indul, a zárolás (jelszó) a képernyővédő indulása után 30 perccel
    if [[ $I_HOME_NEW == 1 || ! -e $h/.xscreensaver ]]; then
      cat > "$h/.xscreensaver" <<'XSC'
timeout:	0:10:00
cycle:		0:10:00
lock:		True
lockTimeout:	0:30:00
passwdTimeout:	0:00:30
dpmsEnabled:	False
visualID:	default
installColormap:	True
verbose:	False
splash:		False
fade:		True
unfade:		False
mode:		one
selected:	0
programs:	\
		GL: glmatrix -root			    \n\

XSC
    fi
    # XFCE energiakezelő: minden automatikus kikapcsolás / alvás TILTVA
    rc="$xml/xfce4-power-manager.xml"
    if [[ $I_HOME_NEW == 1 || ! -e $rc ]]; then
      cat > "$rc" <<'PMXML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <property name="dpms-enabled" type="bool" value="false"/>
    <property name="blank-on-ac" type="int" value="0"/>
    <property name="blank-on-battery" type="int" value="0"/>
    <property name="dpms-on-ac-sleep" type="uint" value="0"/>
    <property name="dpms-on-ac-off" type="uint" value="0"/>
    <property name="dpms-on-battery-sleep" type="uint" value="0"/>
    <property name="dpms-on-battery-off" type="uint" value="0"/>
    <property name="inactivity-on-ac" type="uint" value="14"/>
    <property name="inactivity-on-battery" type="uint" value="14"/>
    <property name="lock-screen-suspend-hibernate" type="bool" value="false"/>
  </property>
</channel>
PMXML
    fi
  fi
}

phase2() {
  say "Csomagadatbázis frissítése"
  pacman -Sy --noconfirm

  runuser -l "$I_USER" -c "LANG=$I_LOCALE xdg-user-dirs-update" 2>/dev/null

  say "GitHub képek letöltése a lokalizált felhasználói mappába"
  local pic_dir
  pic_dir=$(runuser -l "$I_USER" -c "xdg-user-dir PICTURES" 2>/dev/null)
  [[ -n $pic_dir ]] || pic_dir="/home/$I_USER/Képek"
  mkdir -p "$pic_dir"; chown "$I_USER:$I_USER" "$pic_dir"
  dl_pic "$pic_dir" Avatar.png
  dl_pic "$pic_dir" Wallpaper.jpg
  dl_pic "$pic_dir" menu.png

  PROFILE_RESTORED=0
  if has profile && [[ $I_DE == xfce && $I_HOME_NEW == 1 ]]; then
    say "XFCE profil visszatöltése"
    if curl -fsSL -o /tmp/xfce-backup.tar.gz "$I_XFCE_URL" && tar -xzf /tmp/xfce-backup.tar.gz -C "/home/$I_USER"; then
      PROFILE_RESTORED=1
    else
      warn "Az XFCE profil letöltése/kicsomagolása nem sikerült."
    fi
    rm -f /tmp/xfce-backup.tar.gz
  fi

  set_avatar "$pic_dir/Avatar.png"

  if has flatpak; then
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
  fi

  need_aur && aur_build
  [[ $I_DE == xfce ]] && xfce_user_setup "$pic_dir"
  audacious_skin
  has solidcraft && install_solidcraft
  fix_home_owner
}

case "${1:-}" in
  phase1) phase1 ;;
  phase2) phase2 ;;
esac
CHROOT
  chmod +x /mnt/root/chroot-setup.sh
}

configure_system() {
  write_chroot_script
  step "Chroot fázis 1"
  must mkdir -p /mnt/udev-host
  mount --bind /run/udev /mnt/udev-host 2>/dev/null || true
  run_logged arch-chroot /mnt /root/chroot-setup.sh phase1 || P1_FAIL=1
  umount /mnt/udev-host 2>/dev/null || true
  rmdir /mnt/udev-host 2>/dev/null || true

  if [[ ${P1_FAIL:-0} == 1 ]]; then
    warn "A fázis 1 hibával állt le (lásd fent / $LOG_FILE) – GRUB vagy alapbeállítás hiányos lehet."
    yn "Hiba" "A rendszerkonfiguráció hibát jelzett.\n\nMégis folytassam (felhasználó, jelszó, AUR)?" || { cp "$LOG_FILE" /mnt/var/log/arch-install.log 2>/dev/null; die "Megszakítva. Napló: $LOG_FILE"; }
  fi

  step "Jelszavak beállítása"
  printf '%s:%s\n' root "$ROOTPW"        | arch-chroot /mnt chpasswd
  printf '%s:%s\n' "$USERNAME_" "$USERPW" | arch-chroot /mnt chpasswd

  step "Chroot fázis 2 (AUR, profilok, Képek)"
  run_logged arch-chroot /mnt /root/chroot-setup.sh phase2 || warn "A fázis 2 figyelmeztetéssel zárult (AUR/profil), lásd $LOG_FILE"

  rm -f /mnt/root/install.env /mnt/root/chroot-setup.sh
  cp "$LOG_FILE" /mnt/var/log/arch-install.log 2>/dev/null || true
}

finish() {
  sync
  umount -R /mnt 2>/dev/null || true
  swapoff -a 2>/dev/null || true
  clear
  printf '%s=== A telepítés elkészült! Napló: /var/log/arch-install.log ===%s\n\n' "$GRN" "$RST"
  if yn "Kész" "Indítsuk újra a gépet?\n\n(Ne felejtsd el kihúzni a telepítő USB-t.)"; then
    reboot
  fi
}

main() {
  : > "$LOG_FILE"
  set_console
  banner
  read -rp "  Nyomj Entert a folytatáshoz... " _
  preflight
  ask_basics
  ask_software
  ask_disk
  confirm_all
  prepare_disks
  install_base
  configure_system
  finish
}
main "$@"
