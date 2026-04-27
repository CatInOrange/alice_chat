import React, { createContext, useContext, useState, useEffect } from 'react';
import { toaster } from '@/shared/ui/toaster';
import i18n from '@/i18n';

export type ModeType = 'window' | 'pet';

interface ModeContextType {
  mode: ModeType;
  setMode: (mode: ModeType) => void;
  isElectron: boolean;
}

const ModeContext = createContext<ModeContextType | undefined>(undefined);

export const ModeProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const [mode, setModeState] = useState<ModeType>('window');
  const isElectron = window.api !== undefined;

  const setMode = (newMode: ModeType) => {
    if (newMode === 'pet' && !isElectron) {
      toaster.create({
        title: i18n.t("mode.petUnavailableTitle"),
        description: i18n.t("mode.petUnavailableDescription"),
        type: "info",
        duration: 2000,
      });
      return;
    }

    // Electron-specific mode change
    if (isElectron && window.api) {
      (window.api as any).setMode(newMode);
    } else {
      setModeState(newMode);
    }
  };

  // Listen for mode changes from main process
  useEffect(() => {
    if (isElectron && window.electron) {
      const handlePreModeChange = (_event: any, newMode: ModeType) => {
        setTimeout(() => {
          // Tell main process we're ready for the actual mode change
          window.electron?.ipcRenderer.send('renderer-ready-for-mode-change', newMode);
        }, 50);
      };

      const handleModeChanged = (_event: any, newMode: ModeType) => {
        setModeState(newMode);
        // After mode is set, tell main process the UI has been updated
        setTimeout(() => {
          window.electron?.ipcRenderer.send('mode-change-rendered');
        }, 50);
      };

      // Listen for pre-mode-changed and mode-changed events
      window.electron.ipcRenderer.on('pre-mode-changed', handlePreModeChange);
      window.electron.ipcRenderer.on('mode-changed', handleModeChanged);

      return () => {
        if (window.electron) {
          window.electron.ipcRenderer.removeListener('pre-mode-changed', handlePreModeChange);
          window.electron.ipcRenderer.removeListener('mode-changed', handleModeChanged);
        }
      };
    }
    return undefined;
  }, [isElectron]);

  return (
    <ModeContext.Provider value={{ mode, setMode, isElectron }}>
      {children}
    </ModeContext.Provider>
  );
};

export const useMode = (): ModeContextType => {
  const context = useContext(ModeContext);
  if (context === undefined) {
    throw new Error('useMode must be used within a ModeProvider');
  }
  return context;
}; 
