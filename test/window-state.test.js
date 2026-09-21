'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { restoreBounds, readState, saveState } = require('../window-state');
const primary = { workArea: { x: 0, y: 0, width: 1920, height: 1080 } };
const left = { workArea: { x: -1920, y: 0, width: 1920, height: 1080 } };
test('restores window size and placement on a monitor with negative coordinates', () => {
  const bounds = { x: -1800, y: 50, width: 1200, height: 800 };
  assert.deepEqual(restoreBounds(bounds, [primary, left], primary), { ...bounds, minWidth: 960, minHeight: 640 });
});
test('recovers a window after its monitor is disconnected', () => {
  assert.deepEqual(restoreBounds({ x: -1800, y: 50, width: 1200, height: 800 }, [primary], primary), { x: 0, y: 50, width: 1200, height: 800, minWidth: 960, minHeight: 640 });
});
test('fits a small display and rejects invalid stored bounds', () => {
  const small = { workArea: { x: 0, y: 25, width: 800, height: 575 } };
  for (const bounds of [undefined, {}, {x: 0, y: 0, width: -1, height: 9}]) {
    assert.deepEqual(restoreBounds(bounds, [small], small), {x: 0, y: 25, width: 800, height: 575, minWidth: 800, minHeight: 575});
  }
});
test('persists state across launches and tolerates a corrupt state file', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'keychron-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, 'profile', 'window-state.json');
  assert.deepEqual(readState(file), {});
  const state = { bounds: {x: 10, y: 20, width: 1100, height: 700}, maximized: true, fullScreen: false };
  saveState(file, state);
  assert.deepEqual(readState(file), state);
  fs.writeFileSync(file, '{broken');
  assert.deepEqual(readState(file), {});
});
test('installer and runtime ship identical rules covering arbitrary Keychron receivers', () => {
  const rule = fs.readFileSync(path.join(__dirname, '../99-keychron.rules'), 'utf8');
  const installer = fs.readFileSync(path.join(__dirname, '../build/linux-after-install.sh'), 'utf8');
  assert.equal(installer.split("<< 'EOF'\n")[1].split('EOF\n')[0], rule);
  const usb = rule.split('\n').find(line => line.startsWith('SUBSYSTEM=="usb"') && line.includes('"3434"'));
  assert.ok(usb);
  assert.ok(!usb.includes('idProduct'));
  assert.match(rule, /"0483".*"df11"/);
});
