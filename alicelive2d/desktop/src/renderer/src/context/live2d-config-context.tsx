import {
  createContext, useCallback, useContext, useMemo, useState,
} from 'react';
import { useLocalStorage } from '@/hooks/utils/use-local-storage';
import { buildStoredModelInfo } from '@/live2d-config-utils.ts';
import { useConfig } from '@/context/character-config-context';

/**
 * Model emotion mapping interface
 * @interface EmotionMap
 */
interface EmotionMap {
  [key: string]: number | string;
}

/**
 * Motion weight mapping interface
 * @interface MotionWeightMap
 */
export interface MotionWeightMap {
  [key: string]: number;
}

/**
 * Tap motion mapping interface
 * @interface TapMotionMap
 */
export interface TapMotionMap {
  [key: string]: MotionWeightMap;
}

/**
 * Live2D model information interface
 * @interface ModelInfo
 */
export interface ModelInfo {
  /** Model name */
  name?: string;

  /** Model description */
  description?: string;

  /** Model URL */
  url: string;

  /** Scale factor */
  kScale: number;

  /** Initial X position shift */
  initialXshift: number;

  /** Initial Y position shift */
  initialYshift: number;

  /** Idle motion group name */
  idleMotionGroupName?: string;

  /** Default emotion */
  defaultEmotion?: number | string;

  /** Emotion mapping configuration */
  emotionMap: EmotionMap;

  /** Enable pointer interactivity */
  pointerInteractive?: boolean;

  /** Tap motion mapping configuration */
  tapMotions?: TapMotionMap;

  /** Enable scroll to resize */
  scrollToResize?: boolean;

  /** Initial scale */
  initialScale?: number;

  /** Fallback lip sync parameter id */
  lipSyncParamId?: string;
}

/**
 * Live2D configuration context state interface
 * @interface Live2DConfigState
 */
interface Live2DConfigState {
  modelInfo?: ModelInfo;
  setModelInfo: (info: ModelInfo | undefined) => void;
  isLoading: boolean;
  setIsLoading: (loading: boolean) => void;
}

/**
 * Default values and constants
 */
const DEFAULT_CONFIG = {
  modelInfo: {
    scrollToResize: true,
  } as ModelInfo | undefined,
  isLoading: false,
};

/**
 * Create the Live2D configuration context
 */
export const Live2DConfigContext = createContext<Live2DConfigState | null>(null);

/**
 * Live2D Configuration Provider Component
 * @param {Object} props - Provider props
 * @param {React.ReactNode} props.children - Child components
 */
export function Live2DConfigProvider({ children }: { children: React.ReactNode }) {
  useConfig();

  const [isLoading, setIsLoading] = useState(DEFAULT_CONFIG.isLoading);

  const storageFilter = useCallback(
    (value: ModelInfo | undefined) => (value ? { ...value, url: "" } : value),
    [],
  );

  const [modelInfo, setModelInfoState] = useLocalStorage<ModelInfo | undefined>(
    "modelInfo",
    DEFAULT_CONFIG.modelInfo,
    {
      filter: storageFilter,
    },
  );

  // const [modelInfo, setModelInfoState] = useState<ModelInfo | undefined>(DEFAULT_CONFIG.modelInfo);

  const setModelInfo = useCallback((info: ModelInfo | undefined) => {
    setModelInfoState((previousModelInfo) => {
      const nextModelInfo = buildStoredModelInfo(previousModelInfo, info);
      if (nextModelInfo) {
        console.log("Setting model info with default scale:", nextModelInfo.kScale);
      }
      return nextModelInfo as ModelInfo | undefined;
    });
  }, [setModelInfoState]);

  const contextValue = useMemo(
    () => ({
      modelInfo,
      setModelInfo,
      isLoading,
      setIsLoading,
    }),
    [isLoading, modelInfo, setModelInfo, setIsLoading],
  );

  return (
    <Live2DConfigContext.Provider value={contextValue}>
      {children}
    </Live2DConfigContext.Provider>
  );
}

/**
 * Custom hook to use the Live2D configuration context
 * @throws {Error} If used outside of Live2DConfigProvider
 */
export function useLive2DConfig() {
  const context = useContext(Live2DConfigContext);

  if (!context) {
    throw new Error('useLive2DConfig must be used within a Live2DConfigProvider');
  }

  return context;
}

// Export the provider as default
export default Live2DConfigProvider;
