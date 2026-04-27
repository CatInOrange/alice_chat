import { ElectronAPI } from '@electron-toolkit/preload';

declare global {
  interface Window {
    electron: ElectronAPI
    api: {
      setIgnoreMouseEvents: (ignore: boolean) => void
      toggleForceIgnoreMouse: () => void
      onForceIgnoreMouseChanged: (callback: (isForced: boolean) => void) => () => void
      onModeChanged: (callback: (mode: 'pet' | 'window') => void) => () => void
      showContextMenu: () => void
      onMicToggle: (callback: () => void) => () => void
      onInterrupt: (callback: () => void) => () => void
      updateComponentHover: (componentId: string, isHovering: boolean) => void
      onToggleScrollToResize: (callback: () => void) => () => void
      onSwitchCharacter: (callback: (filename: string) => void) => () => void
      setMode: (mode: 'window' | 'pet') => void
      getPetOverlayBounds: () => Promise<{
        workArea: { x: number; y: number; width: number; height: number }
        virtualBounds: { x: number; y: number; width: number; height: number }
      }>
      getCursorScreenPoint: () => Promise<{ x: number; y: number }>
      onPetOverlayBoundsChanged: (callback: () => void) => () => void
      capturePrimaryScreen: () => Promise<string | null>
      startScreenshotSelection: () => Promise<{
        fileUrl: string
        cleanupToken: string
        filename: string
      } | null>
      showScreenshotSelection: () => Promise<void>
      finishScreenshotSelection: () => Promise<void>
      readTempScreenshotFile: (fileUrl: string) => Promise<string | null>
      cropTempScreenshotFile: (payload: {
        fileUrl: string
        selection: { x: number; y: number; width: number; height: number }
        displaySize: { width: number; height: number }
      }) => Promise<{
        fileUrl: string
        cleanupToken: string
        mimeType: string
      } | null>
      deleteTempScreenshotFile: (cleanupToken: string) => Promise<void>
      listPlugins: () => Promise<{
        builtinRoots: string[]
        localRoot: string
        items: Array<{
          id: string
          source: 'builtin' | 'local'
          rootPath: string
          entryUrl: string
          manifest: Record<string, unknown>
        }>
      }>
      getConfigFiles: () => Promise<any>
      getConfiguredBackendUrl: () => Promise<string | null>
      updateConfigFiles: (files: any[]) => void
    }
  }
}

interface IpcRenderer {
  on(channel: 'mode-changed', func: (_event: any, mode: 'pet' | 'window') => void): void;
  send(channel: string, ...args: any[]): void;
}
