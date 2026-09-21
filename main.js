'use strict';

const { app, BrowserWindow, session, Menu, shell, dialog, Notification, screen } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { restoreBounds, readState, saveState } = require('./window-state');
const { execFile } = require('child_process');

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
  const stateFile = path.join(app.getPath('userData'), 'window-state.json');
  const saved = readState(stateFile);
  const win = new BrowserWindow({
    ...restoreBounds(saved.bounds, screen.getAllDisplays(), screen.getPrimaryDisplay()),
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

  if (saved.maximized === true) win.maximize();
  if (saved.fullScreen === true) win.setFullScreen(true);

  let saveTimer;
  const persist = () => {
    clearTimeout(saveTimer);
    if (!win.isDestroyed()) saveState(stateFile, {
      bounds: win.getNormalBounds(),
      maximized: win.isMaximized(),
      fullScreen: win.isFullScreen(),
    });
  };
  for (const event of ['resize', 'move', 'maximize', 'unmaximize', 'enter-full-screen', 'leave-full-screen']) {
    win.on(event, () => {
      clearTimeout(saveTimer);
      saveTimer = setTimeout(persist, 250);
    });
  }
  win.on('closed', () => clearTimeout(saveTimer));

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
    persist();
    win.hide();
    setImmediate(() => {
      if (!win.isDestroyed()) win.destroy();
    });
  });

  win.loadURL(SPLASH_URL);
  return win;
}

// The .deb/.rpm/.pacman postinstall scripts write this same rule at package-
// install time, but that only runs once, at whatever moment the package
// manager happens to invoke it. Checking it again on every launch, and
// rewriting it if it's missing or stale, means the rule survives even if
// something outside this app's control (an interrupted upgrade, a manual
// edit, an unrelated package touching the same file) leaves it gone.
const LINUX_UDEV_RULE_PATH = '/usr/lib/udev/rules.d/99-keychron.rules';
const LINUX_UDEV_RULE_CONTENTS = fs.readFileSync(path.join(__dirname, '99-keychron.rules'), 'utf8');

function ensureLinuxUdevRule() {
  if (process.platform !== 'linux') return;

  let current = null;
  try {
    current = fs.readFileSync(LINUX_UDEV_RULE_PATH, 'utf8');
  } catch {
    current = null;
  }

  if (current === LINUX_UDEV_RULE_CONTENTS) return;

  let stagingDir;
  let stagedPath;
  try {
    stagingDir = fs.mkdtempSync(path.join(os.tmpdir(), 'keychron-launcher-'));
    stagedPath = path.join(stagingDir, '99-keychron.rules');
    fs.writeFileSync(stagedPath, LINUX_UDEV_RULE_CONTENTS);
  } catch {
    return;
  }

  // Pass filenames as arguments, never as executable shell text.
  const restoreCommand = 'install -m 644 "$1" "$2" && ' +
    '(command -v restorecon >/dev/null 2>&1 && restorecon "$2" || true) && ' +
    'udevadm control --reload-rules && udevadm trigger';
  execFile('pkexec', ['sh', '-c', restoreCommand, 'keychron-udev', stagedPath, LINUX_UDEV_RULE_PATH], () => {
    fs.rmSync(stagingDir, { recursive: true, force: true });
  });

}

app.whenReady().then(() => {
  ensureLinuxUdevRule();

  Menu.setApplicationMenu(process.platform === 'darwin' ? Menu.buildFromTemplate([
    { role: 'appMenu' },
    { role: 'editMenu' },
    { role: 'windowMenu' },
  ]) : null);

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

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  app.quit();
});
