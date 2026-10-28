# arch-install

Menüvezérelt, automatizált Arch Linux telepítő (UEFI). Indítás az Arch ISO-ról, működő hálózattal:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pbalee/arch-install/main/install.sh)
```

**Mit tud**
- Lemez: új tábla, **meglévő /home megtartása** vagy kézi partíció-választás; ext4 / btrfs / xfs, swap (RAM fele)
- GRUB + os-prober, választható téma (Blackice / HyperFluent / nincs)
- XFCE (Whisker menü, sötét téma: Arc-Dark / Materia-dark, Qt-s programokkal együtt), GNOME vagy KDE
- Videókártya-driverek, Steam, Lutris, VirtualBox, LibreOffice, FreeCAD, SolidCraft, RustDesk, Chrome, GLava
- XScreenSaver (GL Matrix), Audacious Winamp-skinek, XFCE-profil visszatöltése

**A repó tartalma:** `install.sh` (telepítő) · `blackice/` (GRUB téma) · `Pictures/` (avatar, háttér, menü-ikon) · `Winamp Skins/` · `xfce-backup.tar.gz` (XFCE profil)
