'use strict';

const fs = require('fs');
const path = require('path');

function restoreBounds(saved, displays, primary) {
  const valid = saved && ['x', 'y', 'width', 'height'].every(key => Number.isSafeInteger(saved[key])) && saved.width > 0 && saved.height > 0;
  const area = (valid && displays.find(({ workArea: a }) =>
    saved.x < a.x + a.width && saved.x + saved.width > a.x &&
    saved.y < a.y + a.height && saved.y + saved.height > a.y))?.workArea || primary.workArea;
  const width = Math.min(area.width, Math.max(960, valid ? saved.width : 1360));
  const height = Math.min(area.height, Math.max(640, valid ? saved.height : 860));
  return {
    x: valid ? Math.max(area.x, Math.min(saved.x, area.x + area.width - width)) : area.x + Math.floor((area.width - width) / 2),
    y: valid ? Math.max(area.y, Math.min(saved.y, area.y + area.height - height)) : area.y + Math.floor((area.height - height) / 2),
    width, height,
    minWidth: Math.min(960, area.width),
    minHeight: Math.min(640, area.height),
  };
}

function readState(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')) || {}; }
  catch { return {}; }
}

function saveState(file, state) {
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(`${file}.tmp`, JSON.stringify(state));
    fs.renameSync(`${file}.tmp`, file);
  } catch (error) {
    console.warn('Could not save window state:', error.message);
  }
}

module.exports = { restoreBounds, readState, saveState };
