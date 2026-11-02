A szkript (install.sh), egy teljesen automatizált, konzolos (Dialog-alapú) Arch Linux telepítő program. A szkript a Bluelight rendszerhez igazodik (szerző: pbalee), és kifejezetten arra lett tervezve, hogy egy gép összerakását (particionálástól a végső szoftverekig) gyorsan és gördülékenyen elvégezze.

Részletes leírás arról, hogy mit csinál a szkript:
1. Előkészületek és Ellenőrzések (preflight)
    Környezetellenőrzés: Megvizsgálja, hogy root jogosultasággal fut-e a telepítő, UEFI módban indul-e a gép, és hogy az Arch ISO környezetben vagyunk-e.
    Hálózat és Idő: Teszteli az internetkapcsolatot (archlinux.org), beállítja a pontos időt (NTP), valamint magyar billentyűzetkiosztást (hu) és konzol betűtípust (ter-122b) érvényesít.
    Tükörszerverek (Reflector): Ha elérhető a reflector, automatikusan kiválasztja a leggyorsabb európai (magyar, osztrák, cseh, német, stb.) tükörszervereket.
    Pacman finomhangolás: Engedélyezi a színes kimenetet (Color), az ILoveCandy animációt, a párhuzamos letöltéseket (ParallelDownloads = 9) és a multilib tárolót.

2. Felhasználói Interakciók és Kérdések (ask_*)
A szkript egy interaktív ncurses/dialog felületen keresztül kérdezi be a szükséges paramétereket:
    Alapadatok: Gépnév (alapértelmezett: bluelight), felhasználónév (pbalee), valamint root és felhasználói jelszavak.
    Asztali környezet és GPU:
        Választható az XFCE (alapértelmezett, X11-gyel kényszerítve a Wayland elkerülése miatt), GNOME, KDE Plasma, vagy egy tiszta konzolos rendszer (none).
        Videókártya illesztőprogram kiválasztása (nvidia [beállítva nvidia-drm modeset-tel], amd, intel, vagy other).
    GRUB Téma: Választható a Blackice (saját GitHub repóból), a HyperFluent (Arch változat), vagy az alap téma.
    XFCE Sötét Téma (opcionális): Arc-Dark vagy Materia-dark stílus, Papirus-Dark ikonokkal és Kvantum Qt integrációval.
    Extrák (Csomagok és szolgáltatások checklist): LibreOffice, Játékos csomagok (Steam, Lutris, Wine, GameMode, MangoHud), VirtualBox, AUR támogatás (yay + Google Chrome), RustDesk, GLava hangvizualizáló, Flatpak, Samba, médiaeszközök (yt-dlp, ffmpeg), FreeCAD, SolidCraft CAD (AppImage), XFCE profil visszatöltése, és extra meghajtók csatolása.

3. Lemezkezelés és Particionálás (prepare_disks)
Háromféle módot kínál fel a lemezkezelésre:
    ÚJ partíciós tábla (new): Teljes lemez törlése GPT-vel, EFI partícióval, Root-tal, opciós külön /home-mal és Swap-mel.
    Megtartott /home (keephome): Érintetlenül hagyja a meglévő /home partíciót, de a többi területet (EFI, Root, Swap) újrahúzza és formázza.
    Meglévő partíciók (existing): Kézzel kiválaszthatók a meglévő partíciók.

4. Alapcsomagok Telepítése (install_base)
    Processzor-függő mikrokód: Automatikusan felismeri, hogy Intel vagy AMD CPU-ról van-e szó, és telepíti a megfelelő mikrokódot (intel-ucode vagy amd-ucode).
    Csomagcsoportok: Telepíti a Linux kernelt, alap fejlesztői eszköztárat, hálózati eszközöket, multimédiás kodekeket, tömörítőket, fájlkezelőket, betűtípusokat és a kiválasztott asztali környezet csomagjait.
    Fstab és Extra Csomagok: Generálja az fstab-ot, és ha kérted, beállítja a különálló /Games (ext4) és /Download (NTFS) partíciókat nofail opcióval.

5. Rendszerkonfiguráció Chrootban (chroot-setup.sh)
A chroot környezeten belül futó fázisok:
    Időzóna és Lokális beállítások: Beállítja a Europe/Budapest időzónát, a hu_HU.UTF-8 nyelvet, valamint a billentyűzetet és a konzol betűtípusát (mkinitcpio újragenerálással).
    Kényelmi funkciók és aliasok: Létrehozza a arch-clean (paccache takarító, árvacsomag-eltávolító, journal tisztító) és arch-update (rendszerfrissítés + Flatpak) parancsokat, valamint hasznos parancsikonokat (cl, e, sr, in, u, ll, stb.).
    Felhasználó és Jogosultságok: Létrehozza a felhasználót a megfelelő csoportokban (wheel sudo joggal, audio, video, storage, stb.), és beállítja a jelszavakat.
    Szolgáltatások: Engedélyezi a NetworkManager, Bluetooth, fstrim, systemd-timesyncd és a Reflector időzítőket.
    GRUB és Bootloader: Beállítja az os-prober-t, az NVIDIA drm modeset-et, telepíti a választott GRUB témát, majd elvégzi a grub-install-t (NVRAM és cserélhető/fallback módban is).

6. Testreszabás és Utómunkák (phase2)
    AUR Csomagok: Ideiglenes builder felhasználó alatt letölti és fordítja a kért AUR csomagokat (yay-bin, google-chrome, rustdesk-bin, glava, ksuperkey).
    Profilkép és Hátterek: Letölti a GitHubról a felhasználói mappába a profilképet (Avatar.png), a háttérképet (Wallpaper.jpg) és a Whisker menü ikonját (menu.png). Beállítja az AccountsService-t, hogy a bejelentkező képernyőn is látszódjon az avatar.
    XFCE Profil és Beállítások: Ha kérted, letölti és kicsomagolja a korábbi XFCE beállításokat (xfce-backup.tar.gz), valamint beállítja a sötét témát, az Audacious zenelejátszóhoz a Winamp skint, a GLava indítót és az energiagazdálkodási szabályokat (alvás/képernyőkikapcsolás tiltása).
    SolidCraft CAD: Letölti a SolidCraft AppImage verzióját SHA256 ellenőrzéssel a /opt könyvtárba, és létrehozza a parancsikonját.

7. Befejezés (finish)
Szinkronizálja a lemezeket, leválasztja a partíciókat, és felajánlja a gépújraindítást.
