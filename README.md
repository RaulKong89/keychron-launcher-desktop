# Keychron Launcher Desktop (unofficial)

A native desktop wrapper for [Keychron Launcher](https://launcher.keychron.com/), the web app used to remap keys, tune Hall Effect settings, adjust RGB lighting, and flash firmware on Keychron keyboards.

This is not made or endorsed by Keychron. It is a community project, built because Keychron Launcher has no installable desktop app on Linux or Windows, only the website.

## Why this exists

Keychron Launcher talks to keyboards over USB using the WebHID API (`navigator.hid`). WebHID is only implemented in Chromium-based engines:

- Chrome, Edge, and Electron: supported
- WebKit (Safari): not implemented ([standards-positions #510](https://github.com/WebKit/standards-positions/issues/510))
- Firefox: not implemented, and the Connect button does not work ([bugzilla #1976862](https://bugzilla.mozilla.org/show_bug.cgi?id=1976862))

So a native-feeling app that can actually connect to a keyboard has to embed Chromium somehow. This project uses Electron for that, but hides it completely: no tabs, no address bar, no browser chrome, a single window, one entry in the application menu. WebHID permission is restricted to `https://launcher.keychron.com`, and navigation outside that origin is blocked.

On Linux there is a second problem: Linux blocks unprivileged access to `/dev/hidraw` by default. This project ships a udev rule for Keychron's USB vendor ID that fixes that on install, so users are not stuck writing their own rules (which is what people have been doing manually on forums and in blog posts for a while now).

## What is included

- `main.js`: the Electron main process. Single `BrowserWindow`, sandboxed, `contextIsolation` on, `nodeIntegration` off. WebHID permission handlers scoped to the Keychron origin. A native "Save As" dialog and completion notification for downloads (firmware files, etc).
- `assets/`: app icon (PNG, ICO, and the source SVG).
- `99-keychron.rules`: udev rule covering Keychron's USB vendor ID (`3434`), the STM32 firmware bootloader (`0483:df11`), and the Keychron Link 2.4G receiver (`3434:0d30`).
- `keychron-launcher.desktop` / `keychron-launcher.metainfo.xml`: Linux desktop entry and AppStream metadata.
- `package.json`: electron-builder config that produces `.deb`, `.rpm`, and Arch `.pkg.tar.zst` packages on Linux, and an NSIS installer on Windows.

## Install

Prebuilt installers are attached to the [latest release](../../releases/latest):

| Platform | File |
|---|---|
| Debian, Ubuntu, Mint, Pop!_OS | `.deb` |
| Fedora, RHEL, Rocky, Alma, openSUSE | `.rpm` |
| Arch, Manjaro, CachyOS | `.pkg.tar.zst` |
| Windows 10/11 | `-setup.exe` |

```
# Debian/Ubuntu
sudo dpkg -i keychron-launcher_*.deb

# Fedora/RHEL
sudo dnf install keychron-launcher-*.rpm

# Arch/CachyOS
sudo pacman -U keychron-launcher-*.pkg.tar.zst

# Windows: run the .exe installer
```

After installing on Linux, the udev rule reloads automatically. Plug in a Keychron keyboard, open the app, and hit Connect.

## Build from source

```
npm install
npm run dist:linux   # deb, rpm, pacman
npm run dist:win     # nsis .exe (cross-builds fine from Linux)
```

## What works, what does not

Everything the web Launcher supports works the same way here: remapping, macros, layers, RGB lighting, Hall Effect / Rapid Trigger tuning, polling rate, and firmware updates.

The one thing that does not work on Linux is Quick Start (the shortcuts that open apps or sites from the keyboard). That feature depends on Keychron Assistant, a separate native helper that Keychron only publishes for Windows and macOS.

## For Keychron

If anyone from Keychron sees this: happy to hand this off as a starting point for an official Linux and Windows release, or just get feedback on it as a project you could point Linux users to from your support docs. Reach out via the repo issues or the email on the profile.

---

## Română

Wrapper desktop nativ pentru [Keychron Launcher](https://launcher.keychron.com/), neoficial, făcut de un utilizator, nu de Keychron. Există pentru că Launcherul nu are o aplicație instalabilă pe Linux sau Windows, doar site-ul web.

Motivul tehnic: Launcherul are nevoie de WebHID ca să vorbească cu tastatura prin USB, iar WebHID există doar în motoarele bazate pe Chromium (Chrome, Edge, Electron). Nici WebKit, nici Firefox nu îl suportă. De-aici vine alegerea de a folosi Electron, dar ascuns complet: fără tab-uri, fără bară de adrese, o singură fereastră, permisiuni WebHID limitate strict la `launcher.keychron.com`.

Pe Linux mai există regula udev inclusă, care dă acces la tastaturile Keychron fără configurare manuală.

Instalatoarele sunt atașate la [ultimul release](../../releases/latest), câte unul pentru fiecare familie de distribuții plus Windows. Instrucțiunile de instalare sunt mai sus, în engleză, dar comenzile sunt aceleași indiferent de limbă.
