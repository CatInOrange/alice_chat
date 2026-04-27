/* eslint-disable no-underscore-dangle */
/* eslint-disable @typescript-eslint/ban-ts-comment */
/* eslint-disable no-use-before-define */
/* eslint-disable no-param-reassign */
/* eslint-disable @typescript-eslint/no-unused-vars */
// @ts-nocheck
import { useEffect, useRef, useCallback, useState, RefObject } from "react";
import { ModelInfo } from "@/context/live2d-config-context";
import { updateModelConfig } from '../../../WebSDK/src/lappdefine';
import { LAppDelegate } from '../../../WebSDK/src/lappdelegate';
import { initializeLive2D } from '@cubismsdksamples/main';
import { useMode } from '@/context/mode-context';
import { useAppStore } from "@/domains/renderer-store";
import { createOptimisticChatMessage } from "@/runtime/chat-send-lifecycle.ts";
import {
  cancelScheduledLive2DInitialization,
  scheduleLive2DInitialization,
} from "@/runtime/live2d-init-scheduler-utils.ts";

interface UseLive2DModelProps {
  modelInfo: ModelInfo | undefined;
  canvasRef: RefObject<HTMLCanvasElement>;
}

interface Position {
  x: number;
  y: number;
}

// Thresholds for tap vs drag detection
const TAP_DURATION_THRESHOLD_MS = 200; // Max duration for a tap
const DRAG_DISTANCE_THRESHOLD_PX = 5; // Min distance to be considered a drag
const MIN_MODEL_SCALE = 0.1;
const WINDOW_MAX_MODEL_SCALE = 5.0;
const PET_INITIAL_MODEL_SCALE_MAX = 0.85;
const FLIRT_TRIGGER_WINDOW_MS = 60 * 1000;
const FLIRT_TRIGGER_COUNT = 4;
const FLIRT_TRIGGER_COOLDOWN_MS = 15 * 1000;
const FLIRT_TRIGGER_LINES = [
  "还没碰够呀~ 这么黏人，真拿你没办法。 😏",
  "手倒是挺诚实的呢，一直这样碰我，是在故意撩我吗？~",
  "怎么，摸上瘾了？再这样下去，我可真要误会了哦~ 😌",
  "这么喜欢招惹我呀？小心我认真了，你可就跑不掉了。",
  "别这么急着靠过来呀，不然我会忍不住想逗你。~",
  "一直这样不安分，是真觉得我不会拿你怎么样吗？ 😏",
  "再这么碰我，我可就不只是纵着你了哦~",
  "这么喜欢撩我？那后果可得自己负责呢。",
  "怎么这么会缠人，弄得我都舍不得对你冷一点了。~",
  "再这样来回招我，我就当你是在撒娇了哦。 😌",
  "还碰呀~ 这么舍不得停手，是不是有点太贪心了？",
  "手一直这么不安分，是想让我陪你玩点更过分的吗~ 😏",
  "嘴上不说，动作倒是挺大胆的呢，嗯？",
  "再这么来回撩我，我可真的会顺着你的意思想下去哦~",
  "这么喜欢碰我，是因为我太好欺负，还是太对你胃口了？ 😘",
  "你这点小心思，都快从手上漏出来了呢~",
  "一直这样黏着我，是想让我主动一点吗？ 😏",
  "再不收敛一点，我可要当你是在明目张胆勾引我了哦。",
  "碰得这么熟练，怎么，早就想这么对我了？~",
  "还不肯停呀~ 真要把我撩出点反应，你负责吗？ 😘",
  "还没玩够？你这手，可比嘴诚实多了呢~",
  "再这么碰我，我可就默认你在跟我调情了哦。 😏",
  "你这样一直撩，我会忍不住想欺负回去的。~",
  "小动作这么多，是想让我把注意力都给你吗？",
  "啧，还真是会得寸进尺呢，不过我不讨厌。 😌",
  "再缠下去，我可要怀疑你是在故意勾我了~",
  "这么黏我，是不是就喜欢看我被你闹得没办法？",
  "你这人，碰一下不够，还想要我惯着你几次呀~ 😏",
  "要是再这么撩，我可真不保证自己还端得住。",
  "手别乱呀~ 再这样，我就当你在撒娇求宠了。 😘",
  "又来了？看来你是真的很喜欢招我。~",
  "别总这么试探我，不然我会忍不住陪你玩到底。 😏",
  "你这副不老实的样子，还挺招人想收拾的。",
  "这么来来回回地碰，是想让我记住你吗？~",
  "再闹下去，我可就不只是看着你胡来了哦。 😌",
  "你碰我的时候，倒是一点都不见外呢。",
  "嗯？还不停手，是想让我夸你胆子大吗？~ 😏",
  "你这样撩人，是真的觉得我不会反击吗？",
  "再这样下去，我可就把你的心思全当真了。 😘",
  "你这手，像是在故意点火呢~",
  "碰得这么自然，是不是偷偷练过怎么撩我？ 😏",
  "我看你不是路过，是专程来惹我的吧。",
  "一直这么不安分，是觉得我会纵着你？~",
  "还闹？再闹我可真要把你留在我这儿了。 😌",
  "这么喜欢贴过来，难不成是想让我抱你？",
  "别乱碰呀，不然我会觉得你是在邀请我。~ 😘",
  "你再这么缠，我就不跟你讲道理了。",
  "小坏蛋，摸来摸去，是在试我底线吗？ 😏",
  "你这样很容易让我误会，你应该知道吧~",
  "碰一次两次也就算了，这么频繁，是故意的吧？",
  "还来呀？真把我当成只会纵着你的人了？~ 😌",
  "你这么会撩，是不是就等着我上钩呢？",
  "别这么一下一下碰我，怪让人心痒的。 😘",
  "手这么不规矩，我是不是该教教你什么叫适可而止？~",
  "嗯，胆子越来越大了，看来是我平时太惯着你。",
  "再这样闹我，我可就默认你今晚想不安分了。 😏",
  "你碰我的样子，倒像是在无声地讨宠。",
  "又来撩我？我可没你想的那么好脾气哦~",
  "这么缠人，会让我舍不得把你放开呢。 😌",
  "你再碰一下试试，看我会不会真的对你下手。",
  "别总这么黏着我，我会误以为你离不开我。~ 😘",
  "手一直不肯停，是不是就喜欢我拿你没办法？",
  "你这样，真的很像在故意让我心软。 😏",
  "再靠近一点，我可就要把这当成你的暗示了哦~",
  "老这么碰我，是觉得我不会脸红，还是想看我失控？",
  "你啊，真是会挑最容易让我动心的方式闹我。 😌",
  "这么来回招我，是不是非要我把你抱紧才肯消停？",
  "别撩得这么明显呀，我会忍不住想顺着你。~ 😘",
  "嗯？动作这么熟，是不是心里早就演练过好多遍了？",
  "你每碰一下，都像是在故意提醒我，你很想要我看你。",
  "再这么不安分，我可要怀疑你是在求我宠你了。 😏",
  "还敢继续呀？看来你是真的很享受我注意你的样子。",
  "你这点心思，连指尖都藏不住呢~",
  "别闹了，再闹下去，我就真舍不得放你走了。 😌",
  "这么喜欢往我这边靠，是不是早就对我有想法了？",
  "你的手要是再这么坏，我可就不只是口头警告了。~ 😘",
  "老这样招我，是想看我什么时候把你反过来拿捏住吗？",
  "还挺会挑地方撩，看来不是第一次这么坏了。 😏",
  "你这副样子，真像是在乖乖把自己送到我手里。",
  "再这么碰我，我会忍不住觉得你是在求我多疼你一点。~",
  "你是故意的吧？明知道这样很容易让我心动。 😌",
  "一边装无辜，一边又一直碰我，真会玩。",
  "还不停呀？你是想让我亲口说，我其实很吃你这套吗？~ 😘",
  "你这样一点点试探，反而更让人想把你欺负狠一点。",
  "真黏人……再这样，我可就舍不得对你冷着了。 😏",
  "你手上的胆子，可比你嘴上表现出来的大多了。",
  "这么喜欢撩我，是不是觉得我最后一定会纵着你？~",
  "再闹，我就把你这些小动作一笔一笔都记下来。 😌",
  "你每次碰我，都像在提醒我，你有多想引我注意。",
  "嗯，今天这么主动，是终于不打算装乖了？~ 😘",
  "一直不肯停，是想逼我承认，我对你也有点纵容吗？",
  "你这样撩久了，我可真要怀疑你是来偷心的。 😏",
  "碰得我都快习惯你这么黏了，你说该怎么办？",
  "别总这么招我，不然我真的会顺手把你收了哦~",
  "你这手再不安分一点，我都要怀疑你是故意来勾我的。 😌",
  "还敢继续？胆子不小嘛，我越来越想看看你能撑到什么时候了。",
  "这样一直碰我，会让我以为你很想被我偏爱呢~ 😘",
  "你啊，真是每一下都碰得人心里发热。",
  "再来一次，我就当你是在很认真地对我发出邀请了哦。 😏",
  "你怎么这么会磨人，弄得我都开始不想放过你了。",
  "这么撩下去，我可就真的要顺着你的坏心思陪你玩了~"
];

function appendTeaseMessage(message: string) {
  const state = useAppStore.getState();
  const sessionId = state.currentSessionId || state.sessions?.[0]?.id || null;

  console.log('[appendTeaseMessage] Triggered with message:', message, {
    currentSessionId: state.currentSessionId,
    fallbackSessionId: state.sessions?.[0]?.id,
    resolvedSessionId: sessionId,
    sessionCount: state.sessions?.length || 0,
  });

  if (!sessionId) {
    console.warn('[appendTeaseMessage] No session available, skipping chat append');
    return null;
  }

  if (state.currentSessionId !== sessionId) {
    state.setCurrentSessionId(sessionId);
    console.log('[appendTeaseMessage] Synced currentSessionId before append:', sessionId);
  }

  const optimisticMessage = createOptimisticChatMessage({
    sessionId,
    role: 'assistant',
    text: message,
    source: 'chat',
  });

  state.appendMessageForSession(sessionId, optimisticMessage);

  requestAnimationFrame(() => {
    const verifyState = useAppStore.getState();
    console.log('[appendTeaseMessage] Post-append verification:', {
      currentSessionId: verifyState.currentSessionId,
      targetSessionId: sessionId,
      targetMessageCount: verifyState.messagesBySession?.[sessionId]?.length || 0,
      appendedMessageId: optimisticMessage.id,
    });
  });

  return { sessionId, optimisticMessageId: optimisticMessage.id };
}

async function reportLive2DDragDebug(stage: string, extra: Record<string, unknown> = {}) {
  return; // debug removed
}

function resolveModelScale(rawScale: number | undefined, isPet: boolean): number | undefined {
  if (rawScale === undefined || Number.isNaN(rawScale)) {
    return undefined;
  }

  const maxScale = isPet ? PET_INITIAL_MODEL_SCALE_MAX : WINDOW_MAX_MODEL_SCALE;
  return Math.min(maxScale, Math.max(MIN_MODEL_SCALE, rawScale));
}

function parseModelUrl(url: string): { baseUrl: string; modelDir: string; modelFileName: string } {
  try {
    const urlObj = new URL(url);
    const { pathname } = urlObj;

    const lastSlashIndex = pathname.lastIndexOf('/');
    if (lastSlashIndex === -1) {
      throw new Error('Invalid model URL format');
    }

    const fullFileName = pathname.substring(lastSlashIndex + 1);
    const modelFileName = fullFileName.replace('.model3.json', '');

    const secondLastSlashIndex = pathname.lastIndexOf('/', lastSlashIndex - 1);
    if (secondLastSlashIndex === -1) {
      throw new Error('Invalid model URL format');
    }

    const modelDir = pathname.substring(secondLastSlashIndex + 1, lastSlashIndex);
    const baseUrl = `${urlObj.protocol}//${urlObj.host}${pathname.substring(0, secondLastSlashIndex + 1)}`;

    return { baseUrl, modelDir, modelFileName };
  } catch (error) {
    console.error('Error parsing model URL:', error);
    return { baseUrl: '', modelDir: '', modelFileName: '' };
  }
}

export const playAudioWithLipSync = (audioPath: string, modelIndex = 0): Promise<void> => new Promise((resolve, reject) => {
  const live2dManager = window.LAppLive2DManager?.getInstance();
  if (!live2dManager) {
    reject(new Error('Live2D manager not initialized'));
    return;
  }

  const fullPath = `/Resources/${audioPath}`;
  const audio = new Audio(fullPath);

  audio.addEventListener('canplaythrough', () => {
    const model = live2dManager.getModel(modelIndex);
    if (model) {
      if (model._wavFileHandler) {
        model._wavFileHandler.start(fullPath);
        audio.play();
      } else {
        reject(new Error('Wav file handler not available on model'));
      }
    } else {
      reject(new Error(`Model index ${modelIndex} not found`));
    }
  });

  audio.addEventListener('ended', () => {
    resolve();
  });

  audio.addEventListener('error', () => {
    reject(new Error(`Failed to load audio: ${fullPath}`));
  });

  audio.load();
});

export const useLive2DModel = ({
  modelInfo,
  canvasRef,
}: UseLive2DModelProps) => {
  const { mode } = useMode();
  const isPet = mode === 'pet';
  const [isDragging, setIsDragging] = useState(false);
  const [position, setPosition] = useState<Position>({ x: 0, y: 0 });
  const dragStartPos = useRef<Position>({ x: 0, y: 0 }); // Screen coordinates at drag start
  const modelStartPos = useRef<Position>({ x: 0, y: 0 }); // Model coordinates at drag start
  const modelPositionRef = useRef<Position>({ x: 0, y: 0 });
  const prevModelUrlRef = useRef<string | null>(null);
  const initializeTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const isHoveringModelRef = useRef(false);
  const electronApi = (window as any).electron;
  const flirtDragTimestampsRef = useRef<number[]>([]);
  const flirtCooldownUntilRef = useRef<number>(0);

  // --- State for Tap vs Drag ---
  const mouseDownTimeRef = useRef<number>(0);
  const mouseDownPosRef = useRef<Position>({ x: 0, y: 0 }); // Screen coords at mousedown
  const isPotentialTapRef = useRef<boolean>(false); // Flag for ongoing potential tap/drag action
  // ---

  useEffect(() => {
    const currentUrl = modelInfo?.url;
    const sdkScale = (window as any).LAppDefine?.CurrentKScale;
    const modelScale = resolveModelScale(
      modelInfo?.kScale !== undefined ? Number(modelInfo.kScale) : undefined,
      isPet,
    );

    const needsUpdate = currentUrl &&
                        (currentUrl !== prevModelUrlRef.current ||
                         (sdkScale !== undefined && modelScale !== undefined && sdkScale !== modelScale));

    if (needsUpdate) {
      prevModelUrlRef.current = currentUrl;

      try {
        const { baseUrl, modelDir, modelFileName } = parseModelUrl(currentUrl);

        if (baseUrl && modelDir) {
          updateModelConfig(
            baseUrl,
            modelDir,
            modelFileName,
            modelScale,
            modelInfo?.lipSyncParamId,
          );

          initializeTimeoutRef.current = scheduleLive2DInitialization({
            currentTimer: initializeTimeoutRef.current,
            delayMs: 500,
            onInitialize: () => {
              initializeTimeoutRef.current = null;
              if ((window as any).LAppLive2DManager?.releaseInstance) {
                (window as any).LAppLive2DManager.releaseInstance();
              }
              initializeLive2D();
              console.log("helloworld");
                setTimeout(() => {
                  const adapter = (window as any).getLAppAdapter?.();
                  const model = adapter?.getModel();
                  if (model && model.setInitialExpression) {
                    // 设置初始表情 Expression
                    model.setInitialExpression({
                      Type: "Live2D Expression",
                      Parameters: [
                        { Id: "Param13", Value: 1, Blend: "Add" }
                      ]
                    });
                  }
                }, 100); // 延迟一下确保模型加载完成
            },
          });
        }
      } catch (error) {
        console.error('Error processing model URL:', error);
      }
    }

    return () => {
      initializeTimeoutRef.current = cancelScheduledLive2DInitialization({
        currentTimer: initializeTimeoutRef.current,
      });
    };
  }, [isPet, modelInfo?.lipSyncParamId, modelInfo?.url, modelInfo?.kScale]);

  const getModelPosition = useCallback(() => {
    const adapter = (window as any).getLAppAdapter?.();
    if (adapter) {
      const model = adapter.getModel();
      if (model && model._modelMatrix) {
        const matrix = model._modelMatrix.getArray();
        return {
          x: matrix[12],
          y: matrix[13],
        };
      }
    }
    return { x: 0, y: 0 };
  }, []);

  const setModelPosition = useCallback((x: number, y: number) => {
    const adapter = (window as any).getLAppAdapter?.();
    if (adapter) {
      const model = adapter.getModel();
      if (model && model._modelMatrix) {
        const matrix = model._modelMatrix.getArray();

        const newMatrix = [...matrix];
        newMatrix[12] = x;
        newMatrix[13] = y;

        model._modelMatrix.setMatrix(newMatrix);
        modelPositionRef.current = { x, y };
      }
    }
  }, []);

  useEffect(() => {
    const timer = setTimeout(() => {
      const currentPos = getModelPosition();
      modelPositionRef.current = currentPos;
      setPosition(currentPos);
    }, 500);

    return () => clearTimeout(timer);
  }, [modelInfo?.url, getModelPosition]);

  const getCanvasScale = useCallback(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement;
    if (!canvas) return { width: 1, height: 1, scale: 1 };

    const { width } = canvas;
    const { height } = canvas;
    const scale = width / canvas.clientWidth;

    return { width, height, scale };
  }, []);

  const screenToModelPosition = useCallback((screenX: number, screenY: number) => {
    const { width, height, scale } = getCanvasScale();

    const x = ((screenX * scale) / width) * 2 - 1;
    const y = -((screenY * scale) / height) * 2 + 1;

    return { x, y };
  }, [getCanvasScale]);

  const handleMouseDown = useCallback((e: React.MouseEvent) => {
    const adapter = (window as any).getLAppAdapter?.();
    if (!adapter || !canvasRef.current) return;

    const model = adapter.getModel();
    const view = LAppDelegate.getInstance().getView();
    if (!view || !model) return;

    const canvas = canvasRef.current;
    const rect = canvas.getBoundingClientRect();
    const x = e.clientX - rect.left; // Screen X relative to canvas
    const y = e.clientY - rect.top; // Screen Y relative to canvas

    // --- Check if click is on model ---
    const scale = canvas.width / canvas.clientWidth;
    const scaledX = x * scale;
    const scaledY = y * scale;
    const modelX = view._deviceToScreen.transformX(scaledX);
    const modelY = view._deviceToScreen.transformY(scaledY);

    const hitAreaName = model.anyhitTest(modelX, modelY);
    const isHitOnModel = model.isHitOnModel(modelX, modelY);
    // --- End Check ---

    // Start drag sequence when interacting with the model.
    // Support touch and normal primary-button dragging, not only right click.
    if ((hitAreaName !== null || isHitOnModel) && e.button !== 1) {
      reportLive2DDragDebug("pointer_down_on_model", {
        button: e.button,
        clientX: e.clientX,
        clientY: e.clientY,
        hitAreaName,
        isHitOnModel,
      });
      // Record potential tap/drag start
      mouseDownTimeRef.current = Date.now();
      mouseDownPosRef.current = { x: e.clientX, y: e.clientY }; // Use clientX/Y for distance check
      isPotentialTapRef.current = true;
      setIsDragging(false); // Ensure dragging is false initially

      // Store initial model position IF drag starts later
      if (model._modelMatrix) {
        const matrix = model._modelMatrix.getArray();
        modelStartPos.current = { x: matrix[12], y: matrix[13] };
      }
    } else {
      reportLive2DDragDebug("pointer_down_missed_model", {
        button: e.button,
        clientX: e.clientX,
        clientY: e.clientY,
        hitAreaName,
        isHitOnModel,
      });
    }
  }, [canvasRef, modelInfo]);

  const handleMouseMove = useCallback((e: React.MouseEvent) => {
    const adapter = (window as any).getLAppAdapter?.();
    const view = LAppDelegate.getInstance().getView();
    const model = adapter?.getModel();

    // --- Start Drag Logic ---
    if (isPotentialTapRef.current && adapter && view && model && canvasRef.current) {
      const timeElapsed = Date.now() - mouseDownTimeRef.current;
      const deltaX = e.clientX - mouseDownPosRef.current.x;
      const deltaY = e.clientY - mouseDownPosRef.current.y;
      const distanceMoved = Math.sqrt(deltaX * deltaX + deltaY * deltaY);

      // Check if it's a drag (moved enough distance OR held long enough while moving slightly)
      if (distanceMoved > DRAG_DISTANCE_THRESHOLD_PX || (timeElapsed > TAP_DURATION_THRESHOLD_MS && distanceMoved > 1)) {
        reportLive2DDragDebug("drag_started", {
          timeElapsed,
          distanceMoved,
          startX: mouseDownPosRef.current.x,
          startY: mouseDownPosRef.current.y,
          currentX: e.clientX,
          currentY: e.clientY,
        });
        isPotentialTapRef.current = false; // It's a drag, not a tap
        setIsDragging(true);

        // Set initial drag screen position using the position from mousedown
        const canvas = canvasRef.current;
        const rect = canvas.getBoundingClientRect();
        dragStartPos.current = {
          x: mouseDownPosRef.current.x - rect.left,
          y: mouseDownPosRef.current.y - rect.top,
        };
        // modelStartPos is already set in handleMouseDown
      }
    }
    // --- End Start Drag Logic ---

    // --- Continue Drag Logic ---
    if (isDragging && adapter && view && model && canvasRef.current) {
      const canvas = canvasRef.current;
      const rect = canvas.getBoundingClientRect();
      const currentX = e.clientX - rect.left; // Current screen X relative to canvas
      const currentY = e.clientY - rect.top; // Current screen Y relative to canvas

      // Convert screen delta to model delta
      const scale = canvas.width / canvas.clientWidth;
      const startScaledX = dragStartPos.current.x * scale;
      const startScaledY = dragStartPos.current.y * scale;
      const startModelX = view._deviceToScreen.transformX(startScaledX);
      const startModelY = view._deviceToScreen.transformY(startScaledY);

      const currentScaledX = currentX * scale;
      const currentScaledY = currentY * scale;
      const currentModelX = view._deviceToScreen.transformX(currentScaledX);
      const currentModelY = view._deviceToScreen.transformY(currentScaledY);

      const dx = currentModelX - startModelX;
      const dy = currentModelY - startModelY;

      const newX = modelStartPos.current.x + dx;
      const newY = modelStartPos.current.y + dy;

      // Use the adapter's setModelPosition method if available, otherwise update matrix directly
      if (adapter.setModelPosition) {
        adapter.setModelPosition(newX, newY);
      } else if (model._modelMatrix) {
        const matrix = model._modelMatrix.getArray();
        const newMatrix = [...matrix];
        newMatrix[12] = newX;
        newMatrix[13] = newY;
        model._modelMatrix.setMatrix(newMatrix);
      }

      modelPositionRef.current = { x: newX, y: newY };
      setPosition({ x: newX, y: newY }); // Update React state if needed for UI feedback
    }
    // --- End Continue Drag Logic ---

    // --- Pet Hover Logic (Unchanged) ---
    if (isPet && !isDragging && !isPotentialTapRef.current && electronApi && adapter && view && model && canvasRef.current) {
      const canvas = canvasRef.current;
      const rect = canvas.getBoundingClientRect();
      const x = e.clientX - rect.left;
      const y = e.clientY - rect.top;
      const scale = canvas.width / canvas.clientWidth;
      const scaledX = x * scale;
      const scaledY = y * scale;
      const modelX = view._deviceToScreen.transformX(scaledX);
      const modelY = view._deviceToScreen.transformY(scaledY);

      const currentHitState = model.anyhitTest(modelX, modelY) !== null || model.isHitOnModel(modelX, modelY);

      if (currentHitState !== isHoveringModelRef.current) {
        isHoveringModelRef.current = currentHitState;
        electronApi.ipcRenderer.send('update-component-hover', 'live2d-model', currentHitState);
      }
    }
    // --- End Pet Hover Logic ---
  }, [isPet, isDragging, electronApi, canvasRef]);

  const handleMouseUp = useCallback((e: React.MouseEvent) => {
    const maybeTriggerFlirtyReply = () => {
      LAppDelegate.getInstance().showTouchDebug("[DEBUG] maybeTriggerFlirtyReply called");
      const state = useAppStore.getState();
      const sessionId = state.currentSessionId;
      if (!sessionId) {
        LAppDelegate.getInstance().showTouchDebug("[DEBUG] No session, skipping!");
        reportLive2DDragDebug("trigger_skipped_no_session");
        return;
      }

      const now = Date.now();
      if (now < flirtCooldownUntilRef.current) {
        LAppDelegate.getInstance().showTouchDebug(`[DEBUG] Cooldown active, remaining: ${flirtCooldownUntilRef.current - now}ms`);
        reportLive2DDragDebug("trigger_skipped_cooldown", {
          cooldownRemainingMs: flirtCooldownUntilRef.current - now,
        });
        return;
      }

      const recent = flirtDragTimestampsRef.current.filter((timestamp) => now - timestamp <= FLIRT_TRIGGER_WINDOW_MS);
      recent.push(now);
      flirtDragTimestampsRef.current = recent;
      LAppDelegate.getInstance().showTouchDebug(`[DEBUG] Drag count: ${recent.length} / ${FLIRT_TRIGGER_COUNT} (window: ${FLIRT_TRIGGER_WINDOW_MS}ms)`);
      reportLive2DDragDebug("drag_count_updated", {
        count: recent.length,
        windowMs: FLIRT_TRIGGER_WINDOW_MS,
        timestamps: recent,
      });

      if (recent.length < FLIRT_TRIGGER_COUNT) {
        LAppDelegate.getInstance().showTouchDebug(`[DEBUG] Not enough drags yet: ${recent.length} < ${FLIRT_TRIGGER_COUNT}`);
        return;
      }

      flirtCooldownUntilRef.current = now + FLIRT_TRIGGER_COOLDOWN_MS;
      flirtDragTimestampsRef.current = [];

      const text = FLIRT_TRIGGER_LINES[Math.floor(Math.random() * FLIRT_TRIGGER_LINES.length)];
      LAppDelegate.getInstance().showTouchDebug(`[TEASE] ${text}`);
      reportLive2DDragDebug("trigger_fired", {
        text,
        cooldownMs: FLIRT_TRIGGER_COOLDOWN_MS,
      });
      appendTeaseMessage(text);
    };
    const adapter = (window as any).getLAppAdapter?.();
    const model = adapter?.getModel();
    const view = LAppDelegate.getInstance().getView();

    if (isDragging) {
      LAppDelegate.getInstance().showTouchDebug("[DEBUG] isDragging=true, calling maybeTriggerFlirtyReply...");
      reportLive2DDragDebug("drag_finished", {
        clientX: e.clientX,
        clientY: e.clientY,
      });
      // Finalize drag
      setIsDragging(false);
      maybeTriggerFlirtyReply();
      if (adapter) {
        const currentModel = adapter.getModel(); // Re-get model in case adapter changed
        if (currentModel && currentModel._modelMatrix) {
          const matrix = currentModel._modelMatrix.getArray();
          const finalPos = { x: matrix[12], y: matrix[13] };
          modelPositionRef.current = finalPos;
          modelStartPos.current = finalPos; // Update base position for next potential drag
          setPosition(finalPos);
        }
      }
    } else if (isPotentialTapRef.current && adapter && model && view && canvasRef.current) {
      reportLive2DDragDebug("pointer_up_without_drag", {
        clientX: e.clientX,
        clientY: e.clientY,
      });
      // --- Tap Motion Logic ---
      const timeElapsed = Date.now() - mouseDownTimeRef.current;
      const deltaX = e.clientX - mouseDownPosRef.current.x;
      const deltaY = e.clientY - mouseDownPosRef.current.y;
      const distanceMoved = Math.sqrt(deltaX * deltaX + deltaY * deltaY);

      // Check if it qualifies as a tap (short duration, minimal movement)
      if (timeElapsed < TAP_DURATION_THRESHOLD_MS && distanceMoved < DRAG_DISTANCE_THRESHOLD_PX) {
        const allowTapMotion = modelInfo?.pointerInteractive !== false;

        if (allowTapMotion && modelInfo?.tapMotions) {
          // Use mouse down position for hit testing
          const canvas = canvasRef.current;
          const rect = canvas.getBoundingClientRect();
          const scale = canvas.width / canvas.clientWidth;
          const downX = (mouseDownPosRef.current.x - rect.left) * scale;
          const downY = (mouseDownPosRef.current.y - rect.top) * scale;
          const modelX = view._deviceToScreen.transformX(downX);
          const modelY = view._deviceToScreen.transformY(downY);

          const hitAreaName = model.anyhitTest(modelX, modelY);
          // Trigger tap motion using the specific hit area name or null for general body tap
          model.startTapMotion(hitAreaName, modelInfo.tapMotions);
        }
      }
      // --- End Tap Motion Logic ---
    }

    // Reset potential tap flag regardless of outcome
    isPotentialTapRef.current = false;
  }, [isDragging, canvasRef, modelInfo]);

  const handleMouseLeave = useCallback(() => {
    if (isDragging) {
      // If dragging and mouse leaves, treat it like a mouse up to end drag
      handleMouseUp({} as React.MouseEvent); // Pass a dummy event or adjust handleMouseUp signature
    }
    // Reset potential tap if mouse leaves before mouse up
    if (isPotentialTapRef.current) {
      isPotentialTapRef.current = false;
    }
    // --- Pet Hover Logic (Unchanged) ---
    if (isPet && electronApi && isHoveringModelRef.current) {
      isHoveringModelRef.current = false;
      electronApi.ipcRenderer.send('update-component-hover', 'live2d-model', false);
    }
  }, [isPet, isDragging, electronApi, handleMouseUp]);

  useEffect(() => {
    if (!isPet && electronApi && isHoveringModelRef.current) {
      isHoveringModelRef.current = false;
    }
  }, [isPet, electronApi]);

  // Expose motion debugging functions to window for console testing
  useEffect(() => {
    const playMotion = (motionGroup: string, motionIndex: number = 0, priority: number = 3) => {
      const adapter = (window as any).getLAppAdapter?.();
      if (!adapter) {
        console.error('Live2D adapter not available');
        return false;
      }

      const model = adapter.getModel();
      if (!model) {
        console.error('Live2D model not available');
        return false;
      }

      try {
        console.log(`Playing motion: group="${motionGroup}", index=${motionIndex}, priority=${priority}`);
        const result = model.startMotion(motionGroup, motionIndex, priority);
        console.log('Motion start result:', result);
        return result;
      } catch (error) {
        console.error('Error playing motion:', error);
        return false;
      }
    };

    const playRandomMotion = (motionGroup: string, priority: number = 3) => {
      const adapter = (window as any).getLAppAdapter?.();
      if (!adapter) {
        console.error('Live2D adapter not available');
        return false;
      }

      const model = adapter.getModel();
      if (!model) {
        console.error('Live2D model not available');
        return false;
      }

      try {
        console.log(`Playing random motion from group: "${motionGroup}", priority=${priority}`);
        const result = model.startRandomMotion(motionGroup, priority);
        console.log('Random motion start result:', result);
        return result;
      } catch (error) {
        console.error('Error playing random motion:', error);
        return false;
      }
    };

    const getMotionInfo = () => {
      const adapter = (window as any).getLAppAdapter?.();
      if (!adapter) {
        console.error('Live2D adapter not available');
        return null;
      }

      const model = adapter.getModel();
      if (!model) {
        console.error('Live2D model not available');
        return null;
      }

      try {
        const motionGroups = [];
        const setting = model._modelSetting;
        if (setting) {
          // Get all motion groups
          const groups = setting._json?.FileReferences?.Motions;
          if (groups) {
            for (const groupName in groups) {
              const motions = groups[groupName];
              motionGroups.push({
                name: groupName,
                count: motions.length,
                motions: motions.map((motion: any, index: number) => ({
                  index,
                  file: motion.File
                }))
              });
            }
          }
        }
        
        console.log('Available motion groups:', motionGroups);
        return motionGroups;
      } catch (error) {
        console.error('Error getting motion info:', error);
        return null;
      }
    };

    // Expose to window for console access
    (window as any).Live2DDebug = {
      playMotion,
      playRandomMotion,
      getMotionInfo,
      // Helper functions
      help: () => {
        console.log(`
Live2D Motion Debug Functions:
- Live2DDebug.getMotionInfo() - Get all available motion groups and their motions
- Live2DDebug.playMotion(group, index, priority) - Play specific motion
- Live2DDebug.playRandomMotion(group, priority) - Play random motion from group  
- Live2DDebug.help() - Show this help

Example usage:
Live2DDebug.getMotionInfo()  // See available motions
Live2DDebug.playMotion("", 0)  // Play first motion from default group
Live2DDebug.playRandomMotion("")  // Play random motion from default group
        `);
      }
    };

    console.log('Live2D Debug functions exposed to window.Live2DDebug');
    console.log('Type Live2DDebug.help() for usage information');

    // Enable direct tease injection path
    (window as any).triggerLive2DTeaseMessage = (_message: string) => {
      console.log('[triggerLive2DTeaseMessage] Triggering tease message:', _message);
      appendTeaseMessage(_message);
      return true;
    };

    // Cleanup function
    return () => {
      delete (window as any).Live2DDebug;
      delete (window as any).triggerLive2DTeaseMessage;
    };
  }, []);

  return {
    position,
    isDragging,
    handlers: {
      onMouseDown: handleMouseDown,
      onMouseMove: handleMouseMove,
      onMouseUp: handleMouseUp,
      onMouseLeave: handleMouseLeave,
    },
  };
};
