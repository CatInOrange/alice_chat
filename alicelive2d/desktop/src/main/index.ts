/* eslint-disable no-shadow */
import { app, ipcMain, globalShortcut, desktopCapturer, nativeImage, screen } from "electron";
import { electronApp, optimizer } from "@electron-toolkit/utils";
import {
  mkdirSync,
  existsSync,
  readdirSync,
  readFileSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { WindowManager } from "./window-manager";
import { MenuManager } from "./menu-manager";
import {
  getCaptureSourceForDisplay,
  getDisplayForScreenshotSession,
  getScreenshotCapturePlan,
} from "../shared/screenshot-flow-utils.mjs";

let windowManager: WindowManager;
let menuManager: MenuManager;
let isQuitting = false;

const sessionDataPath = join(app.getPath("userData"), "session-data");
const diskCachePath = join(sessionDataPath, "cache");

mkdirSync(diskCachePath, { recursive: true });
app.setPath("sessionData", sessionDataPath);
app.commandLine.appendSwitch("disk-cache-dir", diskCachePath);
app.commandLine.appendSwitch("disable-gpu-shader-disk-cache");

interface PluginDiscoveryItem {
  id: string;
  source: "builtin" | "local";
  rootPath: string;
  entryUrl: string;
  manifest: Record<string, unknown>;
}

interface LunariaDesktopConfig {
  desktop?: {
    backendUrl?: string;
  };
}

interface ScreenshotCaptureResult {
  buffer: Buffer;
  filename: string;
  mimeType: string;
}

interface TempScreenshotFileRef {
  fileUrl: string;
  cleanupToken: string;
  mimeType: string;
}

function mergeConfigObjects(base: Record<string, unknown>, override: Record<string, unknown>): Record<string, unknown> {
  const next = { ...base };
  for (const [key, value] of Object.entries(override)) {
    const current = next[key];
    if (
      current
      && value
      && typeof current === "object"
      && typeof value === "object"
      && !Array.isArray(current)
      && !Array.isArray(value)
    ) {
      next[key] = mergeConfigObjects(
        current as Record<string, unknown>,
        value as Record<string, unknown>,
      );
      continue;
    }
    next[key] = value;
  }
  return next;
}

function getLunariaConfigPaths(fileName: string): string[] {
  const cwd = process.cwd();
  const appPath = app.getAppPath();
  const exeDir = dirname(app.getPath("exe"));

  return [
    resolve(cwd, fileName),
    resolve(cwd, "..", fileName),
    resolve(appPath, fileName),
    resolve(appPath, "..", fileName),
    resolve(appPath, "..", "..", fileName),
    resolve(process.resourcesPath, fileName),
    resolve(process.resourcesPath, "app", fileName),
    resolve(exeDir, fileName),
  ];
}

function loadLunariaDesktopConfig(): LunariaDesktopConfig {
  const basePaths = getLunariaConfigPaths("config.json");
  const localPaths = getLunariaConfigPaths("config.local.json");

  let merged: Record<string, unknown> = {};

  for (const filePath of [...basePaths, ...localPaths]) {
    if (!existsSync(filePath)) {
      continue;
    }

    try {
      const parsed = JSON.parse(readFileSync(filePath, "utf8")) as Record<string, unknown>;
      merged = mergeConfigObjects(merged, parsed);
    } catch (error) {
      console.warn(`Failed to read lunaria config from ${filePath}:`, error);
    }
  }

  return merged as LunariaDesktopConfig;
}

function getConfiguredBackendUrl(): string | null {
  // TODO: no need to load entire config in frontend, should be configured in window config
  const backendUrl = String(loadLunariaDesktopConfig().desktop?.backendUrl || "").trim(); 
  return backendUrl || null;
}

// TODO: 插件相关的放到独立文件
// TODO: 运行时可能是一个独立的exe文件，可能找不到插件目录，需要在构建时把插件目录打包到资源里，并且在运行时正确地定位到这个目录
function getBuiltinPluginRoots(): string[] {
  return [
    resolve(app.getAppPath(), "..", "frontend", "public", "plugins"),
    join(process.resourcesPath, "plugins"),
    join(process.resourcesPath, "resources", "plugins"),
    join(app.getAppPath(), "resources", "plugins"),
  ];
}

function getLocalPluginRoot(): string {
  const pluginRoot = join(app.getPath("userData"), "plugins");
  mkdirSync(pluginRoot, { recursive: true });
  return pluginRoot;
}

function discoverPluginsInRoot(
  rootPath: string,
  source: "builtin" | "local",
): PluginDiscoveryItem[] {
  if (!existsSync(rootPath)) {
    return [];
  }

  return readdirSync(rootPath, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .flatMap((entry) => {
      const pluginDir = join(rootPath, entry.name);
      const manifestPath = join(pluginDir, "manifest.json");
      if (!existsSync(manifestPath)) {
        return [];
      }

      try {
        const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as Record<string, unknown>;
        const configuredEntry = String(manifest.entry || "index.js");
        const entryPath = join(pluginDir, configuredEntry);
        if (!existsSync(entryPath)) {
          return [];
        }

        return [{
          id: String(manifest.id || entry.name),
          source,
          rootPath: pluginDir,
          entryUrl: pathToFileURL(entryPath).toString(),
          manifest,
        }];
      } catch (error) {
        console.warn(`Failed to discover plugin in ${pluginDir}:`, error);
        return [];
      }
    });
}

function discoverPlugins(): PluginDiscoveryItem[] {
  const builtins = getBuiltinPluginRoots()
    .flatMap((rootPath) => discoverPluginsInRoot(rootPath, "builtin"));
  const localPlugins = discoverPluginsInRoot(getLocalPluginRoot(), "local");
  const deduped = new Map<string, PluginDiscoveryItem>();
  for (const item of [...builtins, ...localPlugins]) {
    deduped.set(item.id, item);
  }
  return Array.from(deduped.values());
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

// TODO: 截图相关 放独立文件？
// TODO: should it be here?
async function captureDisplayResult(
  targetDisplay: Electron.Display,
  purpose: "attachment" | "selection" = "attachment",
): Promise<ScreenshotCaptureResult | null> {
  const {
    captureSize,
    outputConfig,
    sourceSize,
  } = getScreenshotCapturePlan({
    displaySize: targetDisplay.size,
    purpose,
    scaleFactor: targetDisplay.scaleFactor,
  });
  const sources = await desktopCapturer.getSources({
    types: ["screen"],
    thumbnailSize: captureSize,
  });

  const chosen = getCaptureSourceForDisplay({
    sources: sources as Array<{
      display_id?: string;
      thumbnail?: { getSize?: () => { width?: number; height?: number } };
    }>,
    targetDisplay,
    targetSize: sourceSize,
  });
  if (!chosen) {
    return null;
  }

  const chosenSize = chosen.thumbnail?.getSize?.() || {};
  const thumbnail = Number(chosenSize.width || 0) > captureSize.width
    || Number(chosenSize.height || 0) > captureSize.height
    ? chosen.thumbnail.resize(captureSize)
    : chosen.thumbnail;
  const buffer = outputConfig.mimeType === "image/png"
    ? thumbnail.toPNG()
    : thumbnail.toJPEG(outputConfig.jpegQuality ?? 98);
  if (!buffer?.length) {
    return null;
  }

  return {
    buffer,
    filename: outputConfig.filename,
    mimeType: outputConfig.mimeType,
  };
}

async function captureDisplay(
  targetDisplay: Electron.Display,
  purpose: "attachment" | "selection" = "attachment",
): Promise<string | null> {
  const result = await captureDisplayResult(targetDisplay, purpose);
  if (!result) {
    return null;
  }

  return `data:${result.mimeType};base64,${result.buffer.toString("base64")}`;
}

function createTempScreenshotFile({
  buffer,
  mimeType,
}: {
  buffer: Buffer;
  mimeType: string;
}): TempScreenshotFileRef | null {
  if (!buffer?.length) {
    return null;
  }

  const normalizedMimeType = mimeType === "image/png" ? "image/png" : "image/jpeg";
  const extension = normalizedMimeType === "image/png" ? ".png" : ".jpg";
  const cleanupToken = `shot_${Date.now()}_${Math.random().toString(36).slice(2, 10)}${extension}`;
  const filePath = join(sessionDataPath, cleanupToken);
  writeFileSync(filePath, buffer);
  return {
    cleanupToken,
    fileUrl: pathToFileURL(filePath).toString(),
    mimeType: normalizedMimeType,
  };
}

function resolveTempScreenshotFilePath(fileUrl: string): string | null {
  try {
    const filePath = fileURLToPath(fileUrl);
    const normalizedPath = resolve(filePath);
    const normalizedRoot = `${resolve(sessionDataPath)}${sep}`;
    if (!normalizedPath.startsWith(normalizedRoot)) {
      return null;
    }
    if (!existsSync(normalizedPath)) {
      return null;
    }
    return normalizedPath;
  } catch (error) {
    console.warn("Failed to resolve temp screenshot file:", error);
    return null;
  }
}

function readTempScreenshotFile(fileUrl: string): string | null {
  try {
    const filePath = resolveTempScreenshotFilePath(fileUrl);
    if (!filePath) {
      return null;
    }
    const buffer = readFileSync(filePath);
    const extension = filePath.toLowerCase().endsWith(".png") ? "image/png" : "image/jpeg";
    return `data:${extension};base64,${buffer.toString("base64")}`;
  } catch (error) {
    console.warn("Failed to read temp screenshot file:", error);
    return null;
  }
}

function cropTempScreenshotFile(payload: {
  fileUrl: string;
  selection: { x: number; y: number; width: number; height: number };
  displaySize: { width: number; height: number };
}): TempScreenshotFileRef | null {
  try {
    const filePath = resolveTempScreenshotFilePath(payload.fileUrl);
    if (!filePath) {
      return null;
    }
    const image = nativeImage.createFromPath(filePath);
    if (image.isEmpty()) {
      return null;
    }

    const imageSize = image.getSize();
    const displayWidth = Math.max(1, Math.round(Number(payload.displaySize?.width || 0)));
    const displayHeight = Math.max(1, Math.round(Number(payload.displaySize?.height || 0)));
    const scaleX = imageSize.width / displayWidth;
    const scaleY = imageSize.height / displayHeight;
    const rawX = Math.max(0, Math.round(Number(payload.selection?.x || 0) * scaleX));
    const rawY = Math.max(0, Math.round(Number(payload.selection?.y || 0) * scaleY));
    const x = Math.min(Math.max(0, imageSize.width - 1), rawX);
    const y = Math.min(Math.max(0, imageSize.height - 1), rawY);
    const rawWidth = Math.max(1, Math.round(Number(payload.selection?.width || 0) * scaleX));
    const rawHeight = Math.max(1, Math.round(Number(payload.selection?.height || 0) * scaleY));
    const width = Math.max(1, Math.min(imageSize.width - x, rawWidth));
    const height = Math.max(1, Math.min(imageSize.height - y, rawHeight));
    const cropped = image.crop({ x, y, width, height });
    if (cropped.isEmpty()) {
      return null;
    }
    return createTempScreenshotFile({
      buffer: cropped.toPNG(),
      mimeType: "image/png",
    });
  } catch (error) {
    console.warn("Failed to crop temp screenshot file:", error);
    return null;
  }
}

function deleteTempScreenshotFile(cleanupToken?: string): void {
  const safeToken = String(cleanupToken || "").trim();
  if (!safeToken || safeToken.includes("/") || safeToken.includes("\\") || safeToken.includes("..")) {
    return;
  }

  const filePath = join(sessionDataPath, safeToken);
  if (!existsSync(filePath)) {
    return;
  }

  try {
    unlinkSync(filePath);
  } catch (error) {
    console.warn("Failed to delete temp screenshot file:", error);
  }
}

async function capturePrimaryScreen(): Promise<string | null> {
  return captureDisplay(screen.getPrimaryDisplay(), "attachment");
}

function setupIPC(): void {
  ipcMain.handle("get-platform", () => process.platform);

  ipcMain.on("set-ignore-mouse-events", (_event, ignore: boolean) => {
    const window = windowManager.getWindow();
    if (window) {
      windowManager.setIgnoreMouseEvents(ignore);
    }
  });

  ipcMain.on("get-current-mode", (event) => {
    event.returnValue = windowManager.getCurrentMode();
  });

  ipcMain.on("pre-mode-changed", (_event, newMode) => {
    if (newMode === 'window' || newMode === 'pet') {
      menuManager.setMode(newMode);
    }
  });

  ipcMain.on("window-minimize", () => {
    windowManager.getWindow()?.minimize();
  });

  ipcMain.on("window-maximize", () => {
    const window = windowManager.getWindow();
    if (window) {
      windowManager.maximizeWindow();
    }
  });

  ipcMain.on("window-close", () => {
    const window = windowManager.getWindow();
    if (window) {
      if (process.platform === "darwin") {
        window.hide();
      } else {
        window.close();
      }
    }
  });

  ipcMain.on(
    "update-component-hover",
    (_event, componentId: string, isHovering: boolean) => {
      windowManager.updateComponentHover(componentId, isHovering);
    },
  );

  ipcMain.handle("get-config-files", () => {
    const configFiles = menuManager.getConfigFiles();
    menuManager.updateConfigFiles(configFiles);
    return configFiles;
  });

  ipcMain.handle("get-configured-backend-url", () => {
    return getConfiguredBackendUrl();
  });

  ipcMain.on("update-config-files", (_event, files) => {
    menuManager.updateConfigFiles(files);
  });

  ipcMain.handle('get-screen-capture', async () => {
    const sources = await desktopCapturer.getSources({ types: ['screen'] });
    return sources[0].id;
  });

  ipcMain.handle('get-pet-overlay-bounds', () => {
    const displays = screen.getAllDisplays();
    const point = screen.getCursorScreenPoint();
    const activeDisplay = screen.getDisplayNearestPoint(point);
    const minX = Math.min(...displays.map((display) => display.bounds.x));
    const minY = Math.min(...displays.map((display) => display.bounds.y));
    const maxX = Math.max(...displays.map((display) => display.bounds.x + display.bounds.width));
    const maxY = Math.max(...displays.map((display) => display.bounds.y + display.bounds.height));

    return {
      workArea: activeDisplay.workArea,
      virtualBounds: {
        x: minX,
        y: minY,
        width: maxX - minX,
        height: maxY - minY,
      },
    };
  });

  ipcMain.handle('get-cursor-screen-point', () => {
    const point = screen.getCursorScreenPoint();
    return {
      x: point.x,
      y: point.y,
    };
  });

  const emitPetOverlayBoundsChanged = () => {
    const window = windowManager.getWindow();
    window?.webContents.send('pet-overlay-bounds-changed');
  };

  screen.on('display-added', emitPetOverlayBoundsChanged);
  screen.on('display-removed', emitPetOverlayBoundsChanged);
  screen.on('display-metrics-changed', emitPetOverlayBoundsChanged);

  ipcMain.handle("capture-primary-screen", async () => {
    return capturePrimaryScreen();
  });

  ipcMain.handle("start-screenshot-selection", async () => {
    const cursorPoint = screen.getCursorScreenPoint();
    const targetDisplay = getDisplayForScreenshotSession({
      displays: screen.getAllDisplays(),
      cursorPoint,
    }) || screen.getPrimaryDisplay();
    const selectionBounds = windowManager.beginWindowScreenshotSelection(targetDisplay.bounds);
    if (!selectionBounds) {
      return null;
    }

    await delay(80);
    const capture = await captureDisplayResult(targetDisplay, "selection");
    if (!capture) {
      windowManager.finishWindowScreenshotSelection();
      return null;
    }

    const tempFile = createTempScreenshotFile(capture);
    if (!tempFile) {
      windowManager.finishWindowScreenshotSelection();
      return null;
    }

    windowManager.armWindowScreenshotSelection(selectionBounds);
    return {
      fileUrl: tempFile.fileUrl,
      cleanupToken: tempFile.cleanupToken,
      filename: capture.filename,
    };
  });

  ipcMain.handle("show-screenshot-selection", () => {
    windowManager.showWindowScreenshotSelection();
  });

  ipcMain.handle("finish-screenshot-selection", () => {
    windowManager.finishWindowScreenshotSelection();
  });

  ipcMain.handle("delete-temp-screenshot-file", (_event, cleanupToken: string) => {
    deleteTempScreenshotFile(cleanupToken);
  });

  ipcMain.handle("read-temp-screenshot-file", (_event, fileUrl: string) => {
    return readTempScreenshotFile(fileUrl);
  });

  ipcMain.handle("crop-temp-screenshot-file", (_event, payload: {
    fileUrl: string;
    selection: { x: number; y: number; width: number; height: number };
    displaySize: { width: number; height: number };
  }) => {
    return cropTempScreenshotFile(payload);
  });

  ipcMain.handle("list-plugins", () => {
    return {
      builtinRoots: getBuiltinPluginRoots().filter((rootPath) => existsSync(rootPath)),
      localRoot: getLocalPluginRoot(),
      items: discoverPlugins(),
    };
  });
}

app.whenReady().then(() => {
  electronApp.setAppUserModelId("ai.lunaria.desktop");

  windowManager = new WindowManager();
  menuManager = new MenuManager((mode) => windowManager.setWindowMode(mode));

  const window = windowManager.createWindow({
    titleBarOverlay: {
      color: "#111111",
      symbolColor: "#FFFFFF",
      height: 30,
    },
  });
  menuManager.createTray();

  window.on("close", (event) => {
    if (!isQuitting) {
      event.preventDefault();
      window.hide();
    }
    return false;
  });

  // if (process.env.NODE_ENV === "development") {
  //   globalShortcut.register("F12", () => {
  //     const window = windowManager.getWindow();
  //     if (!window) return;

  //     if (window.webContents.isDevToolsOpened()) {
  //       window.webContents.closeDevTools();
  //     } else {
  //       window.webContents.openDevTools();
  //     }
  //   });
  // }

  setupIPC();

  app.on("activate", () => {
    const window = windowManager.getWindow();
    if (window) {
      window.show();
    }
  });

  app.on("browser-window-created", (_, window) => {
    optimizer.watchWindowShortcuts(window);
  });

  app.on('web-contents-created', (_, contents) => {
    contents.session.setPermissionRequestHandler((webContents, permission, callback) => {
      if (permission === 'media') {
        callback(true);
      } else {
        callback(false);
      }
    });
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});

app.on("before-quit", () => {
  isQuitting = true;
  menuManager.destroy();
  globalShortcut.unregisterAll();
});
