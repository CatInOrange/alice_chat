interface Window {
  api?: {
    setIgnoreMouseEvents: (ignore: boolean) => void
    showContextMenu?: () => void
    onModeChanged: (callback: (mode: string) => void) => void
    updateComponentHover?: (componentId: string, isHovering: boolean) => void
    toggleForceIgnoreMouse?: () => void
    capturePrimaryScreen?: () => Promise<string | null>
    startScreenshotSelection?: () => Promise<{
      fileUrl: string
      cleanupToken: string
      filename: string
    } | null>
    showScreenshotSelection?: () => Promise<void>
    finishScreenshotSelection?: () => Promise<void>
    readTempScreenshotFile?: (fileUrl: string) => Promise<string | null>
    cropTempScreenshotFile?: (payload: {
      fileUrl: string
      selection: { x: number; y: number; width: number; height: number }
      displaySize: { width: number; height: number }
    }) => Promise<{
      fileUrl: string
      cleanupToken: string
      mimeType: string
    } | null>
    deleteTempScreenshotFile?: (cleanupToken: string) => Promise<void>
    getPetOverlayBounds?: () => Promise<any>
    getCursorScreenPoint?: () => Promise<{ x: number; y: number }>
    onInterrupt?: (callback: () => void) => () => void
    onSwitchCharacter?: (callback: (filename: string) => void) => () => void
    onToggleScrollToResize?: (callback: () => void) => () => void
    onForceIgnoreMouseChanged?: (callback: (isForced: boolean) => void) => () => void
    onPetOverlayBoundsChanged?: (callback: () => void) => () => void
    listPlugins?: () => Promise<any>
    getConfiguredBackendUrl?: () => Promise<string | null>
  }
}
