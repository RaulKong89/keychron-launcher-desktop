'use strict';

const { app, BrowserWindow, session, Menu, shell, dialog, Notification } = require('electron');
const path = require('path');
const { exec } = require('child_process');

const APP_URL = 'https://launcher.keychron.com/';
const ALLOWED_HOST = 'launcher.keychron.com';
const ALLOWED_ORIGIN = 'https://launcher.keychron.com';
const APP_ICON = path.join(
  __dirname,
  'assets',
  process.platform === 'win32' ? 'icon.ico' : 'icon.png'
);

app.setName('Keychron Launcher');
app.setPath('userData', path.join(app.getPath('appData'), 'Keychron Launcher'));
if (process.platform === 'win32') app.setAppUserModelId('com.keychron.launcher');

const isAllowed = (url) => {
  try {
    const parsed = new URL(url);
    return parsed.protocol === 'data:' || parsed.host === ALLOWED_HOST;
  } catch {
    return false;
  }
};

// A tiny local splash, so something appears the instant the window opens
// instead of a blank dark rectangle while launcher.keychron.com loads over
// the network. Swapped out for the real site as soon as it's requested.
const SPLASH_URL = `data:text/html;charset=utf-8,${encodeURIComponent(`<!DOCTYPE html>
<html><head><style>
  html, body { height: 100%; margin: 0; background: #111111; }
  body { display: flex; align-items: center; justify-content: center; font-family: sans-serif; color: #888; }
  .wrap { display: flex; flex-direction: column; align-items: center; gap: 12px; }
  .spinner { width: 32px; height: 32px; border: 3px solid #333; border-top-color: #888; border-radius: 50%; animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
</style></head>
<body><div class="wrap"><div class="spinner"></div><div>Loading Keychron Launcher…</div></div></body></html>`)}`;

function createWindow() {
  const win = new BrowserWindow({
    width: 1360,
    height: 860,
    minWidth: 960,
    minHeight: 640,
    title: 'Keychron Launcher',
    backgroundColor: '#111111',
    icon: APP_ICON,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      spellcheck: false,
    },
  });

  win.webContents.setWindowOpenHandler(({ url }) => {
    if (isAllowed(url)) return { action: 'allow' };
    shell.openExternal(url);
    return { action: 'deny' };
  });

  win.webContents.on('will-navigate', (event, url) => {
    if (!isAllowed(url)) event.preventDefault();
  });

  win.webContents.once('did-finish-load', () => {
    if (win.webContents.getURL().startsWith('data:')) win.loadURL(APP_URL);
  });

  // Hide first, so the window visibly disappears the instant close is
  // requested, then tear the rest down right after. destroy() alone still
  // waited on the compositor to finish the forced teardown before the
  // window vanished from screen; hiding is a plain unmap and happens
  // immediately, regardless of what the page's WebHID cleanup is doing.
  win.on('close', (event) => {
    if (win.isDestroyed()) return;
    event.preventDefault();
    win.hide();
    setImmediate(() => {
      if (!win.isDestroyed()) win.destroy();
    });
  });

  win.loadURL(SPLASH_URL);
  return win;
}

// OpenRGB and this app's Launcher both talk to the keyboard over the same
// VIA-based raw HID channel: OpenRGB for lighting, the Launcher for
// everything else (remaps, macros, HE actuation). The OS lets both hold the
// device open at once, so this is informational only; it never touches the
// OpenRGB process or blocks anything. Firmware updates aren't affected
// either way, since the keyboard drops off as a HID device and
// re-enumerates on a separate bootloader interface while flashing.
function notifyIfOpenRGBRunning() {
  if (!Notification.isSupported()) return;

  const checkCommand =
    process.platform === 'win32'
      ? 'tasklist /FI "IMAGENAME eq OpenRGB.exe"'
      : 'pgrep -ix openrgb';

  exec(checkCommand, (error, stdout) => {
    const running =
      !error &&
      (process.platform === 'win32'
        ? /OpenRGB\.exe/i.test(stdout)
        : stdout.trim().length > 0);

    if (!running) return;

    new Notification({
      title: 'OpenRGB detected',
      body:
        "OpenRGB is running and shares this keyboard's configuration channel with the Launcher. Lighting and Launcher changes can run side by side, and firmware updates aren't affected since the keyboard switches to a separate interface while flashing.",
    }).show();
  });
}

app.whenReady().then(() => {
  Menu.setApplicationMenu(null);

  const ses = session.defaultSession;

  ses.setPermissionCheckHandler((webContents, permission, requestingOrigin) => {
    if (permission === 'hid') return requestingOrigin === ALLOWED_ORIGIN;
    return false;
  });

  ses.setPermissionRequestHandler((webContents, permission, callback, details) => {
    if (permission === 'hid' && isAllowed(details.requestingUrl)) {
      callback(true);
    } else {
      callback(false);
    }
  });

  // Grants HID access straight away for any device this app can see, so the
  // page never has to show a prompt or wait on one. This is what lets an
  // already-known keyboard, or the different device the keyboard becomes
  // once it reboots into its firmware-update bootloader, connect the moment
  // it's plugged in.
  ses.setDevicePermissionHandler(
    (details) => details.deviceType === 'hid' && details.origin === ALLOWED_ORIGIN
  );

  // Belt and suspenders: Electron has no built-in HID chooser UI (unlike
  // Chrome, which shows one natively), so if navigator.hid.requestDevice()
  // ever does reach this event instead of being pre-granted above, resolving
  // it ourselves is the only way to avoid leaving it hanging on the page.
  // Since this app only ever talks to one kind of device, it auto-picks
  // rather than asking the user to choose. If the list is empty when the
  // request comes in, which happens during a firmware update when the
  // keyboard drops off USB and re-enumerates under a different VID/PID once
  // it reboots into its bootloader, it waits for hid-device-added instead of
  // failing immediately.
  ses.on('select-hid-device', (event, details, callback) => {
    event.preventDefault();

    if (details.deviceList.length > 0) {
      callback(details.deviceList[0].deviceId);
      return;
    }

    const timeout = setTimeout(() => {
      ses.removeListener('hid-device-added', onDeviceAdded);
      callback('');
    }, 20000);

    const onDeviceAdded = (_event, device) => {
      clearTimeout(timeout);
      ses.removeListener('hid-device-added', onDeviceAdded);
      callback(device.deviceId);
    };

    ses.on('hid-device-added', onDeviceAdded);
  });

  ses.on('will-download', (event, item, webContents) => {
    const win = BrowserWindow.getFocusedWindow() || BrowserWindow.getAllWindows()[0];
    const defaultPath = path.join(app.getPath('downloads'), item.getFilename());

    dialog.showSaveDialog(win, {
      title: 'Save file - Keychron Launcher',
      defaultPath,
      buttonLabel: 'Save',
    }).then(({ canceled, filePath }) => {
      if (canceled || !filePath) {
        item.cancel();
        return;
      }
      item.setSavePath(filePath);
    }).catch(() => item.cancel());

    item.once('done', (event, state) => {
      if (state === 'completed') {
        const notif = new Notification({
          title: 'Download complete',
          body: item.getFilename(),
        });
        notif.show();
      }
    });
  });

  createWindow();
  notifyIfOpenRGBRunning();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
