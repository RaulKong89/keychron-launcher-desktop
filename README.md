# Keychron Launcher Desktop (unofficial)

A native desktop wrapper for [Keychron Launcher](https://launcher.keychron.com/), the web app used to remap keys, tune Hall Effect settings, adjust RGB lighting, and flash firmware on Keychron keyboards.

This is not made or endorsed by Keychron. It is a community project, built because Keychron Launcher has no installable desktop app on Linux, Windows, or macOS, only the website.

## Why this exists

Keychron Launcher talks to keyboards over USB using the WebHID API (`navigator.hid`). WebHID is only implemented in Chromium-based engines:

- Chrome, Edge, and Electron: supported
- WebKit (Safari): not implemented ([standards-positions #510](https://github.com/WebKit/standards-positions/issues/510))
- Firefox: not implemented, and the Connect button does not work ([bugzilla #1976862](https://bugzilla.mozilla.org/show_bug.cgi?id=1976862))

So a native-feeling app that can actually connect to a keyboard has to embed Chromium somehow. This project uses Electron for that, but hides it completely: no tabs, no address bar, no browser chrome, a single window, one entry in the application menu. WebHID permission is restricted to `https://launcher.keychron.com`, and navigation outside that origin is blocked.

On Linux there is a second problem: Linux blocks unprivileged access to `/dev/hidraw` by default. This project ships a udev rule for Keychron's USB vendor ID that fixes that on install, so users are not stuck writing their own rules (which is what people have been doing manually on forums and in blog posts for a while now).

## Compared to other Keychron Launcher projects

A few other people have built something similar. Worth knowing how this one differs, and why, before picking one.

**[Tymon3310/keychron-vial](https://github.com/tymon3310/keychron-vial)** (vial-qmk fork, Pipette/vial-gui desktop apps) has more features where it applies: full Vial protocol, SOCD, gamepad mode, wireless bridge, per-key RGB tuning beyond what stock Launcher exposes. It requires flashing custom firmware onto the keyboard, and only works for keyboards it has a board definition for. As of this writing that covers the Q, Q HE, K Pro/Max/HE, V, C Pro, S/X, and Lemokey series, but nothing in the J series (J2, J2 HE, J2 HE 8K, J8 HE). This wrapper never touches the keyboard's firmware. It runs the official Launcher, so it works with whatever stock firmware a keyboard shipped with, including boards too new for anyone to have reverse-engineered yet.

**[ArtCC/keychron-launcher-wrapper](https://github.com/ArtCC/keychron-launcher-wrapper)** is the same basic idea, an Electron shell around the official Launcher site, but it's built and distributed primarily for macOS. Its own README notes Windows and Linux support "may vary by OS/runtime support," and it doesn't ship a udev rule or distro packages. This project targets Linux first: real `.deb`/`.rpm`/`.pacman` packages with proper dependency declarations, a udev rule covering the vendor ID plus the bootloader and 2.4G receiver IDs, and Windows/macOS builds on top of that.

**[StefanMarAntonsson/keychron-launcher-arch-setup](https://github.com/StefanMarAntonsson/keychron-launcher-arch-setup)** is a script, not an app. It scans connected USB devices and generates the matching udev rules, which is useful, but you still open the Launcher as a regular tab in your own Chromium install, and it only targets Arch. This project is a standalone application with its own icon and its own entry in the app menu, packaged for the Debian, Fedora, and Arch families plus Windows and macOS.

This wrapper trades away the extra features a firmware fork can offer for something that works, unmodified, with any Keychron keyboard from day one, without touching the firmware.

## What is included

- `main.js`: the Electron main process. Single `BrowserWindow`, sandboxed, `contextIsolation` on, `nodeIntegration` off. WebHID permission handlers scoped to the Keychron origin. A native "Save As" dialog and completion notification for downloads (firmware files, etc).
- `assets/`: app icon (PNG, ICO, ICNS, and the source SVG).
- `99-keychron.rules`: udev rule covering Keychron's USB vendor ID (`3434`, every keyboard and mouse they make), the STM32 firmware bootloader (`0483:df11`), and all Keychron USB receivers under vendor `3434`, regardless of product ID. Used directly by the AUR package; `.deb`/`.rpm`/`.pacman` get the same rule from `build/linux-after-install.sh` below, since those formats don't install arbitrary files outside the app directory on their own.
- `build/linux-after-install.sh` / `build/linux-after-remove.sh`: postinst/postrm scripts (wired up as `afterInstall`/`afterRemove` for the `deb`, `rpm`, and `pacman` targets) that write the udev rule to `/usr/lib/udev/rules.d/`, reload udev, and reset the rule file's SELinux context with `restorecon` on SELinux-enforcing distros like Fedora. A file dropped in by a postinst script rather than the RPM database can otherwise get the wrong label and get silently ignored. On Linux, `main.js` also checks this same rule against its expected contents on every launch and rewrites it via `pkexec` if it's missing or changed, since the postinstall script only runs once and has no way to react to the file being altered or removed afterward.
- `keychron-launcher.desktop` / `keychron-launcher.metainfo.xml`: Linux desktop entry and AppStream metadata.
- `package.json`: electron-builder config that produces `.deb`, `.rpm`, and Arch `.pacman` packages on Linux, an NSIS installer on Windows, and an `.app` bundle on macOS.

## Install

Prebuilt installers are attached to the [latest release](../../releases/latest):

| Platform | File |
|---|---|
| Debian, Ubuntu, Mint, Pop!_OS | `.deb` |
| Fedora, RHEL, Rocky, Alma, openSUSE | `.rpm` |
| Arch, Manjaro, CachyOS | `.pacman` |
| Windows 10/11 | `-setup.exe` |
| macOS (Intel) | `-mac-x64.zip` |
| macOS (Apple Silicon) | `-mac-arm64.zip` |

```
# Debian/Ubuntu
sudo dpkg -i keychron-launcher_*.deb

# Fedora/RHEL
sudo dnf install keychron-launcher-*.rpm

# Arch/CachyOS
sudo pacman -U keychron-launcher-*.pacman

# Windows: run the .exe installer

# macOS: unzip, drag Keychron Launcher.app to Applications
```

After installing on Linux, the udev rule reloads automatically. Plug in a Keychron keyboard, open the app, and hit Connect.

The macOS build is not code-signed or notarized (no Apple Developer signing identity is configured). Gatekeeper will block the first launch; right-click the app, choose Open, and confirm once. A signed build through Keychron's own Apple Developer account would not have this problem.

## Build from source

```
npm install
npm run dist:linux   # deb, rpm, pacman
npm run dist:win     # nsis .exe (cross-builds fine from Linux)
npm run dist:mac     # .app + .zip for x64 and arm64 (needs a Mac for .dmg and signing)
```

## What works, what does not

Everything the web Launcher supports works the same way here: remapping, macros, layers, RGB lighting, Hall Effect / Rapid Trigger tuning, polling rate, and firmware updates.

The one thing that does not work on Linux is Quick Start (the shortcuts that open apps or sites from the keyboard). That feature depends on Keychron Assistant, a separate native helper that Keychron only publishes for Windows and macOS.

## Window behavior

The app remembers window size, position, maximized state, and full-screen state. If a saved monitor is no longer connected, the window is moved onto an available screen. Closing the last window quits the app on all platforms, including macOS. The macOS application menu also supports Quit / Cmd+Q.

## Offline availability

This wrapper loads the official website and requires an internet connection. It does not bundle the Launcher web application, device definitions, or firmware catalog. A cached page is not a reliable offline backup.

A fully offline edition would require a separately maintained copy of the web application and its required resources, replacement of online API dependencies, and device-by-device testing with networking disabled. Redistribution permissions for those upstream assets would also need to be established. This release does not provide that functionality or guarantee operation if Keychron's service disappears.

## Updates

The window just loads `launcher.keychron.com` live, so whatever Keychron ships on the website shows up here too, with no update to this wrapper needed. Settings are saved by the site itself and persist between launches like they would in a browser.

The wrapper itself only needs a new release if Keychron changes something the wrapper depends on directly: a new permission type beyond WebHID, a different origin, or a new USB vendor/product ID that the udev rule does not cover yet.

## Troubleshooting

- **Keyboard shows up but won't connect / "HID device connected" hangs:** close any other window with a WebHID lock on the keyboard first, another Launcher tab in a real browser, a QMK Toolbox instance, VIA desktop. Only one process can hold the HID handle at a time.
- **Still nothing after reinstalling:** unplug and replug the keyboard so it re-enumerates under the freshly reloaded udev rule, and check which connection mode your device supports in Launcher. Some devices require a wired connection; Linux permissions alone do not add wireless support to the official site.
- **Running OpenRGB at the same time:** on boards OpenRGB supports through its Keychron QMK driver, both it and this Launcher talk to the keyboard's stock firmware over the same raw HID channel, OpenRGB for lighting, the Launcher for everything else. The OS allows both to hold the device open at once, so this generally works. Firmware updates aren't affected either way: the keyboard drops off as a HID device and re-enumerates on a separate bootloader interface while flashing, so OpenRGB has nothing left to talk to during that step.

Credit to the people documenting this on their own before this project existed: [morkev's fix-keychron.sh gist](https://gist.github.com/morkev/3f08cf45f38610565455bf48190b1b7e) is what first flagged the SELinux mislabeling issue that `linux-after-install.sh` now handles automatically here, and [StefanMarAntonsson/keychron-launcher-arch-setup](https://github.com/StefanMarAntonsson/keychron-launcher-arch-setup) (referenced above) is a good read for anyone who wants to understand what the udev rule is actually doing.

## For Keychron

If anyone from Keychron sees this: happy to hand this off as a starting point for an official Linux and Windows release, or just get feedback on it as a project you could point Linux users to from your support docs. Reach out via the repo issues or the email on the profile.

---

## Română

Wrapper desktop nativ pentru [Keychron Launcher](https://launcher.keychron.com/), neoficial, făcut de un utilizator, nu de Keychron. Există pentru că Launcherul nu are o aplicație instalabilă pe Linux, Windows sau macOS, doar site-ul web.

Motivul tehnic: Launcherul are nevoie de WebHID ca să vorbească cu tastatura prin USB, iar WebHID există doar în motoarele bazate pe Chromium (Chrome, Edge, Electron). Nici WebKit, nici Firefox nu îl suportă. De-aici vine alegerea de a folosi Electron, dar ascuns complet: fără tab-uri, fără bară de adrese, o singură fereastră, permisiuni WebHID limitate strict la `launcher.keychron.com`.

Pe Linux mai există regula udev inclusă, care dă acces la tastaturile Keychron fără configurare manuală. Aplicația verifică regula la fiecare pornire și o rescrie singură prin `pkexec` dacă lipsește sau s-a schimbat, nu doar la instalare.

### Față de alte proiecte similare

**[Tymon3310/keychron-vial](https://github.com/tymon3310/keychron-vial)** (fork vial-qmk, aplicații desktop Pipette/vial-gui) are mai multe funcții acolo unde se aplică: protocol Vial complet, SOCD, mod gamepad, punte wireless, RGB per-tastă dincolo de ce oferă Launcherul oficial. Prețul e că cere reflashuirea firmware-ului tastaturii, și funcționează doar pentru board-urile pentru care are definiție scrisă. La data asta acoperă seriile Q, Q HE, K Pro/Max/HE, V, C Pro, S/X și Lemokey, dar nimic din seria J (J2, J2 HE, J2 HE 8K, J8 HE). Wrapper-ul de aici nu atinge firmware-ul tastaturii. Rulează Launcherul oficial, deci merge cu orice firmware din fabrică, inclusiv pe tastaturi atât de noi încât nimeni din comunitate nu a apucat să le suporte.

**[ArtCC/keychron-launcher-wrapper](https://github.com/ArtCC/keychron-launcher-wrapper)** e aceeași idee de bază, un shell Electron peste site-ul oficial, dar construit și distribuit în primul rând pentru macOS. Chiar README-ul lor spune că suportul Windows și Linux "poate varia în funcție de sistem", fără regulă udev inclusă și fără pachete pentru distribuții Linux. Proiectul de aici țintește Linux întâi: pachete reale `.deb`/`.rpm`/`.pacman` cu dependențe corecte, regulă udev care acoperă vendor ID-ul plus bootloader-ul și receiverul 2.4G, și build-uri Windows/macOS pe lângă.

**[StefanMarAntonsson/keychron-launcher-arch-setup](https://github.com/StefanMarAntonsson/keychron-launcher-arch-setup)** e un script, nu o aplicație. Scanează dispozitivele USB conectate și generează regulile udev potrivite, util, dar tot deschizi Launcherul într-un tab obișnuit din propriul Chromium, și acoperă doar Arch. Proiectul de aici e o aplicație de sine stătătoare, cu iconița ei și intrare proprie în meniul de aplicații, împachetată pentru familiile Debian, Fedora și Arch, plus Windows și macOS.

Wrapper-ul ăsta renunță la funcțiile în plus pe care le poate oferi un fork de firmware, în schimbul a ceva ce merge, nemodificat, cu orice tastatură Keychron din prima zi, fără să atingă firmware-ul.

Instalatoarele sunt atașate la [ultimul release](../../releases/latest), câte unul pentru fiecare familie de distribuții, plus Windows și macOS (Intel și Apple Silicon separat). Instrucțiunile de instalare sunt mai sus, în engleză, dar comenzile sunt aceleași indiferent de limbă.

Wrapper-ul nu are nevoie de actualizări doar pentru că Keychron schimbă ceva pe site, fereastra arată direct pagina live, deci orice modifică ei apare automat aici. Ar avea nevoie de o versiune nouă doar dacă Keychron schimbă ceva ce ține strict de partea nativă: alt tip de permisiune în afară de WebHID, alt domeniu, sau un ID de tastatură/mouse pe care regula udev nu-l acoperă încă.

Fereastra își păstrează dimensiunea, poziția și starea între porniri. Închiderea ultimei ferestre oprește aplicația inclusiv pe macOS. Regula USB acoperă toate receptoarele cu vendor ID `3434`, indiferent de product ID.

Aplicația necesită internet: nu include o copie offline a site-ului, definițiilor de dispozitive sau catalogului de firmware. Un mod complet offline ar necesita dezvoltare și verificări separate, inclusiv clarificarea drepturilor de redistribuire a resurselor Keychron.

### Probleme frecvente

- **Tastatura apare dar nu se conectează / rămâne blocat pe "HID device connected":** închide orice altă fereastră care mai ține tastatura ocupată prin WebHID, un alt tab de Launcher într-un browser normal, QMK Toolbox, VIA desktop. Un singur proces poate ține handle-ul HID la un moment dat.
- **Tot nu merge după reinstalare:** scoate și rebagă tastatura ca să se reînregistreze sub regula udev proaspăt reîncărcată, și verifică modul de conectare acceptat de Launcher pentru dispozitiv. Unele modele necesită cablu; permisiunile Linux nu adaugă suport wireless în site-ul oficial.
- **OpenRGB pornit în același timp:** pe tastaturile pe care OpenRGB le suportă prin driverul lui Keychron QMK, atât el cât și Launcherul vorbesc cu firmware-ul original al tastaturii pe același canal raw HID, OpenRGB pentru lumini, Launcherul pentru tot restul. Sistemul de operare permite ambelor să țină dispozitivul deschis simultan, deci de regulă merge. Update-urile de firmware nu sunt afectate în niciun caz, tastatura dispare ca dispozitiv HID și reapare pe o interfață separată de bootloader cât timp se face flash-ul, deci OpenRGB nu mai are cu ce să vorbească în pasul ăla.

Credit celor care au documentat asta înainte să existe proiectul de aici: [gist-ul fix-keychron.sh al lui morkev](https://gist.github.com/morkev/3f08cf45f38610565455bf48190b1b7e) a semnalat primul problema de etichetare SELinux pe care `linux-after-install.sh` o rezolvă acum automat aici, iar [StefanMarAntonsson/keychron-launcher-arch-setup](https://github.com/StefanMarAntonsson/keychron-launcher-arch-setup) (menționat mai sus) e o lectură bună pentru cine vrea să înțeleagă ce face de fapt regula udev.
