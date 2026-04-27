/* eslint-disable @typescript-eslint/ban-ts-comment */
import electron from 'electron';
const { contextBridge, ipcRenderer, desktopCapturer } = electron;
import { electronAPI } from '@electron-toolkit/preload';
import { ConfigFile } from '../main/menu-manager';

interface PluginDiscoveryPayload {
  builtinRoots: string[];
  localRoot: string;
  items: Array<{
    id: string;
    source: 'builtin' | 'local';
    rootPath: string;
    entryUrl: string;
    manifest: Record<string, unknown>;
  }>;
}

declare global {
  interface Window {
    electron: typeof electronAPI;
    // @ts-ignore
    api: typeof api;
  }
}

const api = {
  setIgnoreMouseEvents: (ignore: boolean) => {
    ipcRenderer.send('set-ignore-mouse-events', ignore);
  },
  toggleForceIgnoreMouse: () => {
    ipcRenderer.send('toggle-force-ignore-mouse');
  },
  onForceIgnoreMouseChanged: (callback: (isForced: boolean) => void) => {
    const handler = (_event: any, isForced: boolean) => callback(isForced);
    ipcRenderer.on('force-ignore-mouse-changed', handler);
    return () => ipcRenderer.removeListener('force-ignore-mouse-changed', handler);
  },
  showContextMenu: () => {
    console.log('Preload showContextMenu');
    ipcRenderer.send('show-context-menu');
  },
  onModeChanged: (callback: (mode: string) => void) => {
    const handler = (_event: any, mode: string) => callback(mode);
    ipcRenderer.on('mode-changed', handler);
    return () => ipcRenderer.removeListener('mode-changed', handler);
  },
  onMicToggle: (callback: () => void) => {
    const handler = (_event: any) => callback();
    ipcRenderer.on('mic-toggle', handler);
    return () => ipcRenderer.removeListener('mic-toggle', handler);
  },
  onInterrupt: (callback: () => void) => {
    const handler = (_event: any) => callback();
    ipcRenderer.on('interrupt', handler);
    return () => ipcRenderer.removeListener('interrupt', handler);
  },
  updateComponentHover: (componentId: string, isHovering: boolean) => {
    ipcRenderer.send('update-component-hover', componentId, isHovering);
  },
  onToggleScrollToResize: (callback: () => void) => {
    const handler = (_event: any) => callback();
    ipcRenderer.on('toggle-scroll-to-resize', handler);
    return () => ipcRenderer.removeListener('toggle-scroll-to-resize', handler);
  },
  onSwitchCharacter: (callback: (filename: string) => void) => {
    const handler = (_event: any, filename: string) => callback(filename);
    ipcRenderer.on('switch-character', handler);
    return () => ipcRenderer.removeListener('switch-character', handler);
  },
  setMode: (mode: 'window' | 'pet') => {
    ipcRenderer.send('pre-mode-changed', mode);
  },
  getPetOverlayBounds: () => ipcRenderer.invoke('get-pet-overlay-bounds'),
  getCursorScreenPoint: () => ipcRenderer.invoke('get-cursor-screen-point') as Promise<{
    x: number;
    y: number;
  }>,
  onPetOverlayBoundsChanged: (callback: () => void) => {
    const handler = () => callback();
    ipcRenderer.on('pet-overlay-bounds-changed', handler);
    return () => ipcRenderer.removeListener('pet-overlay-bounds-changed', handler);
  },
  capturePrimaryScreen: () => ipcRenderer.invoke('capture-primary-screen') as Promise<string | null>,
  startScreenshotSelection: () => ipcRenderer.invoke('start-screenshot-selection') as Promise<{
    fileUrl: string;
    cleanupToken: string;
    filename: string;
  } | null>,
  showScreenshotSelection: () => ipcRenderer.invoke('show-screenshot-selection') as Promise<void>,
  finishScreenshotSelection: () => ipcRenderer.invoke('finish-screenshot-selection') as Promise<void>,
  readTempScreenshotFile: (fileUrl: string) => ipcRenderer.invoke('read-temp-screenshot-file', fileUrl) as Promise<string | null>,
  cropTempScreenshotFile: (payload: {
    fileUrl: string;
    selection: { x: number; y: number; width: number; height: number };
    displaySize: { width: number; height: number };
  }) => ipcRenderer.invoke('crop-temp-screenshot-file', payload) as Promise<{
    fileUrl: string;
    cleanupToken: string;
    mimeType: string;
  } | null>,
  deleteTempScreenshotFile: (cleanupToken: string) => ipcRenderer.invoke('delete-temp-screenshot-file', cleanupToken) as Promise<void>,
  listPlugins: () => ipcRenderer.invoke('list-plugins') as Promise<PluginDiscoveryPayload>,
  getConfigFiles: () => ipcRenderer.invoke('get-config-files'),
  getConfiguredBackendUrl: () => ipcRenderer.invoke('get-configured-backend-url') as Promise<string | null>,
  updateConfigFiles: (files: ConfigFile[]) => {
    ipcRenderer.send('update-config-files', files);
  },
};

if (process.contextIsolated) {
  try {
    contextBridge.exposeInMainWorld('electron', {
      ...electronAPI,
      desktopCapturer: {
        getSources: (options) => desktopCapturer.getSources(options),
      },
      ipcRenderer: {
        invoke: (channel, ...args) => ipcRenderer.invoke(channel, ...args),
        on: (channel, func) => ipcRenderer.on(channel, func),
        once: (channel, func) => ipcRenderer.once(channel, func),
        removeListener: (channel, func) => ipcRenderer.removeListener(channel, func),
        removeAllListeners: (channel) => ipcRenderer.removeAllListeners(channel),
        send: (channel, ...args) => ipcRenderer.send(channel, ...args),
      },
      process: {
        platform: process.platform,
      },
    });
    contextBridge.exposeInMainWorld('api', api);
  } catch (error) {
    console.error(error);
  }
} else {
  window.electron = electronAPI;
  (window as any).api = api;
}
