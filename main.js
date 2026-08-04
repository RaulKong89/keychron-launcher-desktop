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
    return new URL(url).host === ALLOWED_HOST;
  } catch {
    return false;
  }
};

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

  win.loadURL(APP_URL);
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
