'use strict';

const { app, BrowserWindow, session, Menu, shell, dialog, Notification } = require('electron');
const path = require('path');

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
    autoHideMenuBar: true,
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

  // Force-close instead of the default graceful teardown. The site itself
  // does WebHID cleanup on unload, which can take a few seconds once a
  // keyboard is actively connected, and that's what made the window feel
  // slow to close. destroy() skips waiting on that.
  win.on('close', (event) => {
    if (win.isDestroyed()) return;
    event.preventDefault();
    win.destroy();
  });

  win.loadURL(SPLASH_URL);
  return win;
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
  if (process.platform !== 'darwin') app.quit();
});
