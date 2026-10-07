import { app, BrowserWindow, screen } from 'electron';
import { dirname, join } from 'node:path';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { getConfig, saveConfig } from './store/config.js';
import type { WindowBounds } from '../shared/types.js';

const currentDir = dirname(fileURLToPath(import.meta.url));
const preloadFile = join(currentDir, '../preload/bridge.mjs');
const rendererFile = join(currentDir, '../renderer/index.html');

export function appIconPath(): string | undefined {
  const packaged = join(process.resourcesPath || '', 'appIcon.png');
  if (existsSync(packaged)) return packaged;
  const dev = join(currentDir, '../../src/renderer/assets/appIcon.png');
  return existsSync(dev) ? dev : undefined;
}

function readBounds(): WindowBounds | undefined {
  return getConfig().windowBounds;
}

function fixBounds(bounds: WindowBounds): WindowBounds {
  
  const probe = { x: bounds.x ?? 0, y: bounds.y ?? 0, width: bounds.width, height: bounds.height };
  const area = screen.getDisplayMatching(probe).workArea;
  const width = Math.min(bounds.width, area.width);
  const height = Math.min(bounds.height, area.height);
  const x = bounds.x === undefined ? undefined : Math.min(Math.max(bounds.x, area.x), area.x + area.width - width);
  const y = bounds.y === undefined ? undefined : Math.min(Math.max(bounds.y, area.y), area.y + area.height - height);
  return { ...bounds, width, height, x, y };
}

function saveBounds(window: BrowserWindow): void {
  
  const bounds: WindowBounds = { ...window.getNormalBounds(), maximized: window.isMaximized() };
  void saveConfig({ ...getConfig(), windowBounds: bounds });
}

export function createWindow(): BrowserWindow {
  const saved = readBounds();
  const bounds = saved ? fixBounds(saved) : undefined;
  const window = new BrowserWindow({
    width: bounds?.width ?? 1440,
    height: bounds?.height ?? 900,
    x: bounds?.x,
    y: bounds?.y,
    minWidth: 960,
    minHeight: 640,
    backgroundColor: '#1B1B1F',
    icon: appIconPath(),
    webPreferences: {
      preload: preloadFile,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      backgroundThrottling: false,
      autoplayPolicy: 'no-user-gesture-required',
    },
  });
  if (bounds?.maximized) window.maximize();
  window.on('close', () => saveBounds(window));
  const devUrl = process.env.VITE_DEV_SERVER_URL;
  window.webContents.setWindowOpenHandler(({ url }) => {
    try {
      const target = new URL(url);
      const base = new URL(devUrl ?? `file://${rendererFile.replace(/\\/g, '/')}`);
      if (target.origin !== base.origin || target.pathname !== base.pathname || target.search !== '?preview=1' || target.hash) return { action: 'deny' };
    } catch {
      return { action: 'deny' };
    }
    return {
      action: 'allow',
      overrideBrowserWindowOptions: {
        width: 960,
        height: 580,
        minWidth: 480,
        minHeight: 300,
        title: '预览窗口',
        backgroundColor: '#000000',
        resizable: true,
        webPreferences: {
          preload: preloadFile,
          contextIsolation: true,
          nodeIntegration: false,
          sandbox: false,
          backgroundThrottling: false,
          autoplayPolicy: 'no-user-gesture-required',
        },
      },
    };
  });
  if (devUrl) void window.loadURL(devUrl);
  else void window.loadFile(rendererFile);
  return window;
}

export function createSetup(): BrowserWindow {
  const window = new BrowserWindow({
    width: 760,
    height: 640,
    title: '初始设置',
    icon: appIconPath(),
    backgroundColor: '#1B1B1F',
    resizable: false,
    maximizable: false,
    webPreferences: {
      preload: preloadFile,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });
  const devUrl = process.env.VITE_DEV_SERVER_URL;
  if (devUrl) void window.loadURL(`${devUrl}?setup=1`);
  else void window.loadFile(rendererFile, { search: '?setup=1' });
  return window;
}

export function isReady(): boolean {
  return app.isReady() && existsSync(rendererFile);
}
