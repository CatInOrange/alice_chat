import {
  BrowserWindow, screen, shell, ipcMain,
} from 'electron';
import { join } from 'path';
import { is } from '@electron-toolkit/utils';
import {
  getPetModeAlwaysOnTopLevel,
  getScreenshotRestoreWindowConfig,
  getScreenshotSelectionBounds,
} from '../shared/screenshot-flow-utils.mjs';

const isMac = process.platform === 'darwin';

export class WindowManager {
  private window: BrowserWindow | null = null;

  private windowedBounds: {
    x: number;
    y: number;
    width: number;
    height: number;
  } | null = null;

  private hoveringComponents: Set<string> = new Set();

  private currentMode: 'window' | 'pet' = 'window';

  // Track if mouse events are forcibly ignored
  private forceIgnoreMouse = false;

  private screenshotRestoreState: {
    mode: 'window' | 'pet';
    bounds: {
      x: number;
      y: number;
      width: number;
      height: number;
    };
    isFullScreen: boolean;
  } | null = null;

  constructor() {
    ipcMain.on('renderer-ready-for-mode-change', (_event, newMode) => {
      if (newMode === 'pet') {
        setTimeout(() => {
          this.continueSetWindowModePet();
        }, 500);
      } else {
        setTimeout(() => {
          this.continueSetWindowModeWindow();
        }, 500);
      }
    });

    ipcMain.on('mode-change-rendered', () => {
      this.window?.setOpacity(1);
    });

    ipcMain.on('window-unfullscreen', () => {
      const window = this.getWindow();
      if (window && window.isFullScreen()) {
        window.setFullScreen(false);
      }
    });

    // Handle toggle force ignore mouse events from renderer
    ipcMain.on('toggle-force-ignore-mouse', () => {
      this.toggleForceIgnoreMouse();
    });
  }

  createWindow(options: Electron.BrowserWindowConstructorOptions): BrowserWindow {
    this.window = new BrowserWindow({
      width: 900,
      height: 670,
      show: false,
      transparent: true,
      backgroundColor: '#00000000',
      autoHideMenuBar: true,
      frame: false,
      icon: process.platform === 'win32'
        ? join(__dirname, '../../resources/icon.ico')
        : join(__dirname, '../../resources/icon.png'),
      ...(isMac ? { titleBarStyle: 'hiddenInset' } : {}),
      webPreferences: {
        preload: join(__dirname, '../preload/index.js'),
        sandbox: false,
        contextIsolation: true,
        nodeIntegration: true,
        webSecurity: false,
      },
      hasShadow: false,
      paintWhenInitiallyHidden: true,
      ...options,
    });

    this.setupWindowEvents();
    this.loadContent();

    this.window.on('enter-full-screen', () => {
      this.window?.webContents.send('window-fullscreen-change', true);
    });

    this.window.on('leave-full-screen', () => {
      this.window?.webContents.send('window-fullscreen-change', false);
    });

    return this.window;
  }

  private setupWindowEvents(): void {
    if (!this.window) return;

    this.window.on('ready-to-show', () => {
      this.window?.show();
      this.window?.webContents.send(
        'window-maximized-change',
        this.window.isMaximized(),
      );
    });

    this.window.on('maximize', () => {
      this.window?.webContents.send('window-maximized-change', true);
    });

    this.window.on('unmaximize', () => {
      this.window?.webContents.send('window-maximized-change', false);
    });

    this.window.on('resize', () => {
      const window = this.getWindow();
      if (window) {
        const bounds = window.getBounds();
        const { width, height } = screen.getPrimaryDisplay().workArea;
        const isMaximized = bounds.width >= width && bounds.height >= height;
        window.webContents.send('window-maximized-change', isMaximized);
      }
    });

    this.window.webContents.setWindowOpenHandler((details) => {
      shell.openExternal(details.url);
      return { action: 'deny' };
    });
  }

  private loadContent(): void {
    if (!this.window) return;

    if (is.dev && process.env.ELECTRON_RENDERER_URL) {
      this.window.loadURL(process.env.ELECTRON_RENDERER_URL);
    } else {
      this.window.loadFile(join(__dirname, '../renderer/index.html'));
    }
  }

  setWindowMode(mode: 'window' | 'pet'): void {
    if (!this.window) return;

    this.currentMode = mode;
    this.window.setOpacity(0);

    if (mode === 'window') {
      this.setWindowModeWindow();
    } else {
      this.setWindowModePet();
    }
  }

  private setWindowModeWindow(): void {
    if (!this.window) return;

    this.window.setAlwaysOnTop(false);
    this.window.setIgnoreMouseEvents(false);
    this.window.setSkipTaskbar(false);
    this.window.setResizable(true);
    this.window.setFocusable(true);
    this.window.setAlwaysOnTop(false);

    this.window.setBackgroundColor('#00000000');
    this.window.webContents.send('pre-mode-changed', 'window');
  }

  private continueSetWindowModeWindow(): void {
    if (!this.window) return;
    if (this.windowedBounds) {
      this.window.setBounds(this.windowedBounds);
    } else {
      this.window.setSize(900, 670);
      this.window.center();
    }

    if (isMac) {
      this.window.setWindowButtonVisibility(true);
      this.window.setVisibleOnAllWorkspaces(false, {
        visibleOnFullScreen: false,
      });
    }

    this.window?.setIgnoreMouseEvents(false, { forward: true });

    this.window.webContents.send('mode-changed', 'window');
  }

  private setWindowModePet(): void {
    if (!this.window) return;

    this.windowedBounds = this.window.getBounds();

    if (this.window.isFullScreen()) {
      this.window.setFullScreen(false);
    }

    this.window.setBackgroundColor('#00000000');

    this.window.setAlwaysOnTop(true, getPetModeAlwaysOnTopLevel());
    this.window.setPosition(0, 0);

    this.window.webContents.send('pre-mode-changed', 'pet');
  }

  private continueSetWindowModePet(): void {
    if (!this.window) return;
    // Calculate the bounding rectangle that covers all connected displays.
    // This allows the transparent pet-mode window to span across monitors,
    // so the avatar can be dragged freely between them.
    const displays = screen.getAllDisplays();
    const minX = Math.min(...displays.map((d) => d.bounds.x));
    const minY = Math.min(...displays.map((d) => d.bounds.y));
    const maxX = Math.max(...displays.map((d) => d.bounds.x + d.bounds.width));
    const maxY = Math.max(...displays.map((d) => d.bounds.y + d.bounds.height));
    const combinedWidth = maxX - minX;
    const combinedHeight = maxY - minY;

    // Resize and position the window to cover the entire virtual screen
    // so the avatar is not clipped when dragged to a second monitor.
    this.window.setBounds({
      x: minX,
      y: minY,
      width: combinedWidth,
      height: combinedHeight,
    });

    if (isMac) this.window.setWindowButtonVisibility(false);
    this.window.setResizable(false);
    this.window.setSkipTaskbar(true);
    this.window.setFocusable(false);

    if (isMac) {
      this.window.setIgnoreMouseEvents(true);
      this.window.setVisibleOnAllWorkspaces(true, {
        visibleOnFullScreen: true,
      });
    } else {
      this.window.setIgnoreMouseEvents(true, { forward: true });
    }

    this.window.webContents.send('mode-changed', 'pet');
  }

  private applyMouseIgnoreState(ignore: boolean): void {
    if (!this.window) {
      return;
    }

    if (isMac) {
      this.window.setIgnoreMouseEvents(ignore);
    } else {
      this.window.setIgnoreMouseEvents(ignore, { forward: true });
    }
  }

  beginWindowScreenshotSelection(displayBounds?: {
    x: number;
    y: number;
    width: number;
    height: number;
  }): {
    x: number;
    y: number;
    width: number;
    height: number;
  } | null {
    if (!this.window || this.screenshotRestoreState) {
      return null;
    }

    this.screenshotRestoreState = {
      mode: this.currentMode,
      bounds: this.window.getBounds(),
      isFullScreen: this.window.isFullScreen(),
    };

    if (this.window.isFullScreen()) {
      this.window.setFullScreen(false);
    }

    // TODO: no need to hide the window
    this.window.hide();
    return getScreenshotSelectionBounds(displayBounds || screen.getPrimaryDisplay().bounds);
  }

  armWindowScreenshotSelection(bounds: {
    x: number;
    y: number;
    width: number;
    height: number;
  }): void {
    if (!this.window || !this.screenshotRestoreState) {
      return;
    }

    if (isMac) {
      this.window.setWindowButtonVisibility(false);
      this.window.setVisibleOnAllWorkspaces(true, {
        visibleOnFullScreen: true,
      });
    }

    this.window.setAlwaysOnTop(true, getPetModeAlwaysOnTopLevel());
    this.window.setIgnoreMouseEvents(false);
    this.window.setSkipTaskbar(true);
    this.window.setResizable(false);
    this.window.setFocusable(true);
    this.window.setOpacity(0);
    this.window.setBounds(bounds);
    this.window.show();
    this.window.moveTop();
    this.window.focus();
  }

  showWindowScreenshotSelection(): void {
    if (!this.window || !this.screenshotRestoreState) {
      return;
    }

    this.window.setOpacity(1);
    this.window.focus();
  }

  finishWindowScreenshotSelection(): void {
    if (!this.window || !this.screenshotRestoreState) {
      return;
    }

    const restoreState = this.screenshotRestoreState;
    this.screenshotRestoreState = null;
    const restoreConfig = getScreenshotRestoreWindowConfig({
      mode: restoreState.mode,
      forceIgnoreMouse: this.forceIgnoreMouse,
      hoveringComponentCount: this.hoveringComponents.size,
    });

    if (restoreConfig.alwaysOnTopLevel) {
      this.window.setAlwaysOnTop(restoreConfig.alwaysOnTop, restoreConfig.alwaysOnTopLevel);
    } else {
      this.window.setAlwaysOnTop(restoreConfig.alwaysOnTop);
    }
    this.applyMouseIgnoreState(restoreConfig.ignoreMouseEvents);
    this.window.setSkipTaskbar(restoreConfig.skipTaskbar);
    this.window.setResizable(restoreConfig.resizable);
    this.window.setFocusable(restoreConfig.focusable);
    this.window.setBackgroundColor('#00000000');

    if (isMac) {
      this.window.setWindowButtonVisibility(restoreState.mode === 'window');
      this.window.setVisibleOnAllWorkspaces(restoreState.mode === 'pet', {
        visibleOnFullScreen: restoreState.mode === 'pet',
      });
    }

    this.window.setBounds(restoreState.bounds);
    // TODO: 截图前不隐藏，这里也不用恢复了
    this.window.show();
    this.window.setOpacity(1);
    if (restoreConfig.moveTopAfterShow) {
      this.window.moveTop();
    }

    if (restoreState.isFullScreen) {
      this.window.setFullScreen(true);
    }
  }
  
  getWindow(): BrowserWindow | null {
    return this.window;
  }

  setIgnoreMouseEvents(ignore: boolean): void {
    if (!this.window) return;

    if (isMac) {
      this.window.setIgnoreMouseEvents(ignore);
      // this.window.setIgnoreMouseEvents(ignore, { forward: true });
    } else {
      this.window.setIgnoreMouseEvents(ignore, { forward: true });
    }
  }

  maximizeWindow(): void {
    if (!this.window) return;

    if (this.isWindowMaximized()) {
      if (this.windowedBounds) {
        this.window.setBounds(this.windowedBounds);
        this.windowedBounds = null;
        this.window.webContents.send('window-maximized-change', false);
      }
    } else {
      this.windowedBounds = this.window.getBounds();
      const { width, height } = screen.getPrimaryDisplay().workArea;
      this.window.setBounds({
        x: 0, y: 0, width, height,
      });
      this.window.webContents.send('window-maximized-change', true);
    }
  }

  isWindowMaximized(): boolean {
    if (!this.window) return false;
    const bounds = this.window.getBounds();
    const { width, height } = screen.getPrimaryDisplay().workArea;
    return bounds.width >= width && bounds.height >= height;
  }

  updateComponentHover(componentId: string, isHovering: boolean): void {
    if (this.currentMode === 'window') return;

    // If force ignore is enabled, don't change the mouse ignore state
    if (this.forceIgnoreMouse) return;

    if (isHovering) {
      this.hoveringComponents.add(componentId);
    } else {
      this.hoveringComponents.delete(componentId);
    }

    if (this.window) {
      const shouldIgnore = this.hoveringComponents.size === 0;
      if (isMac) {
        this.window.setIgnoreMouseEvents(shouldIgnore);
      } else {
        this.window.setIgnoreMouseEvents(shouldIgnore, { forward: true });
      }
      if (!shouldIgnore) {
        this.window.setFocusable(true);
      }
    }
  }

  // Toggle force ignore mouse events
  toggleForceIgnoreMouse(): void {
    this.forceIgnoreMouse = !this.forceIgnoreMouse;

    // Apply the new setting immediately
    if (this.forceIgnoreMouse) {
      if (isMac) {
        this.window?.setIgnoreMouseEvents(true);
      } else {
        this.window?.setIgnoreMouseEvents(true, { forward: true });
      }
    } else {
      // Reapply normal behavior based on hovering components
      const shouldIgnore = this.hoveringComponents.size === 0;
      if (isMac) {
        this.window?.setIgnoreMouseEvents(shouldIgnore);
      } else {
        this.window?.setIgnoreMouseEvents(shouldIgnore, { forward: true });
      }
    }

    // Notify renderer about the change
    this.window?.webContents.send('force-ignore-mouse-changed', this.forceIgnoreMouse);
  }

  // Get current force ignore state
  isForceIgnoreMouse(): boolean {
    return this.forceIgnoreMouse;
  }

  // Get current mode
  getCurrentMode(): 'window' | 'pet' {
    return this.currentMode;
  }
}
