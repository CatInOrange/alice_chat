/**
 * Copyright(c) Live2D Inc. All rights reserved.
 *
 * Use of this source code is governed by the Live2D Open Software license
 * that can be found at https://www.live2d.com/eula/live2d-open-software-license-agreement_en.html.
 */

import { CubismFramework, Option } from '@framework/live2dcubismframework';

import * as LAppDefine from './lappdefine';
import { LAppLive2DManager } from './lapplive2dmanager';
import { LAppPal } from './lapppal';
import { LAppTextureManager } from './lapptexturemanager';
import { LAppView } from './lappview';
import { canvas, gl } from './lappglmanager';
import { releaseIfPresent } from '../../src/runtime/live2d-disposal-utils.ts';
import { canInitializeLive2DDelegate } from '../../src/runtime/live2d-gl-context-utils.ts';
import { shouldRenderLive2DFrame } from '../../src/runtime/live2d-render-loop-utils.ts';

export let s_instance: LAppDelegate | null = null;
export let frameBuffer: WebGLFramebuffer | null = null;

// Debug tracking for touch and drag display
let _lastTouchStatus = '';
let _lastDragPos: { x: number; y: number } | null = null;
const TOUCH_DEBUG_VISIBLE = false;


/**
 * アプリケーションクラス。
 * Cubism SDKの管理を行う。
 * 
 * 应用程序类。
 * 管理Cubism SDK。
 * 
 */
export class LAppDelegate {
  // Multi-drag tease detection instance variables
  private _dragTimestamps: number[] = [];
  private _lastTeaseTime: number = 0;
  private _teaseMessageShown: boolean = false;

  /**
   * クラスのインスタンス（シングルトン）を返す。
   * インスタンスが生成されていない場合は内部でインスタンスを生成する。
   * 
   * 返回类的实例（单例）。
   * 如果尚未创建实例，则在内部创建实例。
   *
   * @return クラスのインスタンス
   */
  public static getInstance(): LAppDelegate {
    if (s_instance == null) {
      s_instance = new LAppDelegate();
    }

    return s_instance;
  }

  /**
   * クラスのインスタンス（シングルトン）を解放する。
   * 
   * 释放类的实例（单例）。
   * 
   */
  public static releaseInstance(): void {
    if (s_instance != null) {
      s_instance.release();
    }

    s_instance = null;
  }

  /**
   * Initialize the application.
   */
  public initialize(): boolean {
    console.log('[DEBUG] LAppDelegate.initialize() called');
    // Comment out the following code since canvas already exists in DOM
    // let parent = document.getElementById('live2d');
    // if (parent) {
    //   parent.appendChild(canvas!);
    // } else {
    //   document.body.appendChild(canvas!);
    // }

    if (!canInitializeLive2DDelegate({ canvas, gl })) {
      console.warn("Live2D delegate initialization skipped because canvas or WebGL context is unavailable");
      return false;
    }

    if (LAppDefine.CanvasSize === 'auto') {
      this._resizeCanvas();
    } else {
      canvas!.width = LAppDefine.CanvasSize.width;
      canvas!.height = LAppDefine.CanvasSize.height;
    }

    if (!frameBuffer) {
      frameBuffer = gl!.getParameter(gl!.FRAMEBUFFER_BINDING);
    }

    // 透過設定
    // 透明设置
    gl!.enable(gl!.BLEND);
    gl!.blendFunc(gl!.SRC_ALPHA, gl!.ONE_MINUS_SRC_ALPHA);

    // 创建触摸调试窗口，默认隐藏，可在需要调试时重新开启
    console.log('[DEBUG] Initializing touch debug window (hidden by default)');
    this.showTouchDebug('waiting...');
    console.log('[DEBUG] Touch debug window initialized');

    const supportTouch: boolean = 'ontouchend' in canvas!;

    if (supportTouch) {
      // タッチ関連コールバック関数登録
      // 注册触摸相关回调函数
      canvas!.addEventListener('touchstart', onTouchBegan, { passive: false });
      canvas!.addEventListener('touchmove', onTouchMoved, { passive: false });
      canvas!.addEventListener('touchend', onTouchEnded, { passive: false });
      canvas!.addEventListener('touchcancel', onTouchCancel, { passive: false });
    } else {
      // マウス関連コールバック関数登録
      // 注册鼠标相关回调函数
      canvas!.addEventListener('mousedown', onClickBegan, { passive: true });
      canvas!.addEventListener('mousemove', onMouseMoved, { passive: true });
      canvas!.addEventListener('mouseup', onClickEnded, { passive: true });
    }

    // AppViewの初期化
    this._view!.initialize();

    // Cubism SDKの初期化
    this.initializeCubism();

    return true;
  }

  /**
   * Resize canvas and re-initialize view.
   */
  public onResize(): void {
    this._resizeCanvas();
    
    // Ensure view is properly initialized
    if (this._view && canvas) {
      this._view.initialize();
      this._view.initializeSprite();
      
      // Try to get and center the model
      const manager = LAppLive2DManager.getInstance();
      if (manager) {
        const model = manager.getModel(0);
        if (model) {
          // Keep model centered in canvas
          const width = canvas!.width;
          const height = canvas!.height;
          if (width > 0 && height > 0) {
            
            // Only force reset position if the model has not been dragged
            // @ts-ignore
            if (model.getModelMatrix && model.getModelMatrix().getArray()[12] === 0) {
              const view = this._view;
              if (view) {
                 const x = width / 2;
                 const y = height / 2;
                 const modelX = view._deviceToScreen.transformX(x);
                 const modelY = view._deviceToScreen.transformY(y);
                 
                 const matrix = model.getModelMatrix().getArray();
                 const newMatrix = [...matrix];
                 newMatrix[12] = modelX;
                 newMatrix[13] = modelY;
                 model.getModelMatrix().setMatrix(new Float32Array(newMatrix));
              }
            }
          }
        }
      }
    }
  }

  /**
   * 解放する。
   */
  public release(): void {
    releaseIfPresent(this._textureManager);
    this._textureManager = null;

    releaseIfPresent(this._view);
    this._view = null;

    // リソースを解放
    LAppLive2DManager.releaseInstance();

    // Cubism SDKの解放
    CubismFramework.dispose();
  }

  /**
   * 在页面上显示触摸调试信息
   */
  public showTouchDebug(message: string): void {
    // Track touch status (messages starting with "[")
    if (message.startsWith('[')) {
      _lastTouchStatus = message;
    }
    // Track drag position (messages starting with "drag")
    else if (message.startsWith('drag')) {
      const match = message.match(/drag \(([^,]+), ([^)]+)\)/);
      if (match) {
        _lastDragPos = { x: parseFloat(match[1]), y: parseFloat(match[2]) };
      }
    }

    let debugDiv = document.getElementById('touch-debug');
    if (!debugDiv) {
      debugDiv = document.createElement('div');
      debugDiv.id = 'touch-debug';
      debugDiv.style.cssText = `
        position: fixed;
        top: 10px;
        left: 10px;
        background: rgba(0, 0, 0, 0.8);
        color: #0f0;
        padding: 10px 15px;
        font-family: monospace;
        font-size: 14px;
        z-index: 999999;
        border-radius: 5px;
        min-width: 150px;
        display: ${TOUCH_DEBUG_VISIBLE ? 'block' : 'none'};
      `;
      document.body.appendChild(debugDiv);
    }

    debugDiv.style.display = TOUCH_DEBUG_VISIBLE ? 'block' : 'none';

    // Display both touch status and drag position
    let displayText = _lastTouchStatus || 'no touch';
    if (_lastDragPos) {
      displayText += ` | drag (${_lastDragPos.x.toFixed(2)}, ${_lastDragPos.y.toFixed(2)})`;
    }
    debugDiv.textContent = displayText;
  }

  /**
   * 実行処理。
   * 执行处理。
   */
  public run(): void {
    // メインループ
    // 主循环
    const loop = (): void => {
      if (
        !shouldRenderLive2DFrame({
          activeInstance: s_instance,
          loopInstance: this,
          view: this._view,
          glContext: gl,
        })
      ) {
        return;
      }

      // 時間更新
      if (LAppDefine.ENABLE_LIMITED_FRAME_RATE) {
        LAppPal.updateTime(false);
        if (LAppPal.getDeltaTime() < 1 / LAppDefine.LIMITED_FRAME_RATE) {
          requestAnimationFrame(loop);
          return;
        }
      }

      LAppPal.updateTime(true);


      // 画面の初期化
      // 屏幕初始化
      gl!.clearColor(0.0, 0.0, 0.0, 0.0);

      // 深度テストを有効化
      // 启用深度测试
      gl!.enable(gl!.DEPTH_TEST);

      // 近くにある物体は、遠くにある物体を覆い隠す
      // 近距离的物体会遮挡远距离的物体
      gl!.depthFunc(gl!.LEQUAL);

      // カラーバッファや深度バッファをクリアする
      // 清除颜色缓冲区和深度缓冲区
      // gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
      gl!.clear(gl!.DEPTH_BUFFER_BIT);

      gl!.clearDepth(1.0);

      // 透過設定
      gl!.enable(gl!.BLEND);
      gl!.blendFunc(gl!.SRC_ALPHA, gl!.ONE_MINUS_SRC_ALPHA);

      // 描画更新
      this._view!.render();

      // ループのために再帰呼び出し
      // 递归调用以进行循环
      requestAnimationFrame(loop);
    };
    loop();
  }

  /**
   * シェーダーを登録する。
   * 注册着色器。
   */
  public createShader(): WebGLProgram | null {
    // バーテックスシェーダーのコンパイル
    // 编译顶点着色器
    const vertexShaderId = gl!.createShader(gl!.VERTEX_SHADER);

    if (vertexShaderId == null) {
      LAppPal.printMessage('failed to create vertexShader');
      return null;
    }

    const vertexShader: string =
      'precision mediump float;' +
      'attribute vec3 position;' +
      'attribute vec2 uv;' +
      'varying vec2 vuv;' +
      'void main(void)' +
      '{' +
      '   gl_Position = vec4(position, 1.0);' +
      '   vuv = uv;' +
      '}';

    gl!.shaderSource(vertexShaderId, vertexShader);
    gl!.compileShader(vertexShaderId);

    // フラグメントシェーダのコンパイル
    const fragmentShaderId = gl!.createShader(gl!.FRAGMENT_SHADER);

    if (fragmentShaderId == null) {
      LAppPal.printMessage('failed to create fragmentShader');
      return null;
    }

    const fragmentShader: string =
      'precision mediump float;' +
      'varying vec2 vuv;' +
      'uniform sampler2D texture;' +
      'void main(void)' +
      '{' +
      '   gl_FragColor = texture2D(texture, vuv);' +
      '}';

    gl!.shaderSource(fragmentShaderId, fragmentShader);
    gl!.compileShader(fragmentShaderId);

    // プログラムオブジェクトの作成
    // 创建程序对象
    const programId = gl!.createProgram();
    gl!.attachShader(programId!, vertexShaderId);
    gl!.attachShader(programId!, fragmentShaderId);

    gl!.deleteShader(vertexShaderId);
    gl!.deleteShader(fragmentShaderId);

    // リンク
    // 链接
    gl!.linkProgram(programId!);

    gl!.useProgram(programId);

    return programId;
  }

  /**
   * View情報を取得する。
   */
  public getView(): LAppView | null {
    return this._view;
  }

  public getTextureManager(): LAppTextureManager | null {
    return this._textureManager;
  }

  /**
   * コンストラクタ
   * 构造函数
   */
  constructor() {
    this._captured = false;
    this._mouseX = 0.0;
    this._mouseY = 0.0;
    this._isEnd = false;

    this._cubismOption = new Option();
    this._view = new LAppView();
    this._textureManager = new LAppTextureManager();
  }

  /**
   * Cubism SDKの初期化
   */
  public initializeCubism(): void {
    // setup cubism
    this._cubismOption.logFunction = LAppPal.printMessage;
    this._cubismOption.loggingLevel = LAppDefine.CubismLoggingLevel;
    CubismFramework.startUp(this._cubismOption);

    // initialize cubism
    CubismFramework.initialize();

    // load model
    LAppLive2DManager.getInstance();

    LAppPal.updateTime();

    this._view!.initializeSprite();
  }

  /**
   * Resize the canvas to fill the screen.
   */
  private _resizeCanvas(): void {
    if (!canvas) {
      console.warn("Canvas is null, skipping resize");
      return;
    }
    // Guard against invalid canvas CSS size (e.g., before layout is computed)
    if (canvas.clientWidth <= 0 || canvas.clientHeight <= 0) {
      console.warn(`[CanvasCap] Invalid canvas CSS size: ${canvas.clientWidth}x${canvas.clientHeight}, skipping resize`);
      return;
    }
    // Cap canvas internal resolution to prevent GPU memory/precision issues on mobile
    const maxCanvasDim = 1920;
    let internalWidth = canvas.clientWidth * window.devicePixelRatio;
    let internalHeight = canvas.clientHeight * window.devicePixelRatio;
    const maxDim = Math.max(internalWidth, internalHeight);
    if (maxDim > maxCanvasDim) {
      const scale = maxCanvasDim / maxDim;
      internalWidth = Math.round(internalWidth * scale);
      internalHeight = Math.round(internalHeight * scale);
      console.log(`[CanvasCap] Capped canvas from ${canvas.clientWidth * window.devicePixelRatio}x${canvas.clientHeight * window.devicePixelRatio} to ${internalWidth}x${internalHeight}`);
    }
    canvas.width = internalWidth;
    canvas.height = internalHeight;
    if (gl) {
      gl.viewport(0, 0, gl.drawingBufferWidth, gl.drawingBufferHeight);
    }
  }

  _cubismOption: Option; // Cubism SDK Option
  _view: LAppView | null; // View情報  // 视图信息
  _captured: boolean; // クリックしているか // 是否点击
  _mouseX: number; // マウスX座標 // 鼠标X坐标
  _mouseY: number; // マウスY座標 // 鼠标Y坐标
  _isEnd: boolean; // APP終了しているか // APP是否已结束
  _textureManager: LAppTextureManager | null; // テクスチャマネージャー // 纹理管理器

  /**
   * 检查是否满足多次拖拽触发条件
   * 如果满足4次拖拽在60秒内，则触发撩消息
   */
  public checkMultiDragTease(): void {
    const now = Date.now();
    const windowMs = 60 * 1000;  // 60秒内
    const cooldownMs = 30 * 1000;  // 30秒冷却
    const threshold = 4;  // 4次拖拽触发

    console.log("[DEBUG] checkMultiDragTease called, _teaseMessageShown=" + this._teaseMessageShown + ", _lastTeaseTime=" + this._lastTeaseTime);

    // 检查冷却中
    if (this._teaseMessageShown && now - this._lastTeaseTime < cooldownMs) {
      console.log("[DEBUG] checkMultiDragTease: in cooldown, returning");
      return;
    }

    // 冷却过期，重置标志
    if (this._teaseMessageShown && now - this._lastTeaseTime >= cooldownMs) {
      console.log("[DEBUG] checkMultiDragTease: cooldown expired, resetting flag");
      this._teaseMessageShown = false;
    }

    this._dragTimestamps.push(now);
    console.log("[DEBUG] checkMultiDragTease: pushed timestamp, _dragTimestamps.length=" + this._dragTimestamps.length);

    // 过滤出60秒内的时间戳
    this._dragTimestamps = this._dragTimestamps.filter((t: number) => now - t <= windowMs);
    console.log("[DEBUG] checkMultiDragTease: after filter, _dragTimestamps.length=" + this._dragTimestamps.length);

    if (this._dragTimestamps.length < threshold) {
      return;
    }

    // 检查时间窗口
    const first = this._dragTimestamps[0];
    const last = this._dragTimestamps[this._dragTimestamps.length - 1];
    console.log("[DEBUG] checkMultiDragTease: threshold reached! count=" + this._dragTimestamps.length + ", first=" + first + ", last=" + last + ", diff=" + (last - first));

    if (last - first <= windowMs) {
      console.log("[DEBUG] checkMultiDragTease: time window OK, calling triggerTease!");
      this.triggerTease();
      this._dragTimestamps = [];
    } else {
      console.log("[DEBUG] checkMultiDragTease: time window too large, not triggering");
    }
  }

  /**
   * 触发撩消息
   */
  public triggerTease(): void {
    const now = Date.now();
    this._lastTeaseTime = now;
    this._teaseMessageShown = true;

    const messages = [
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

    const message = messages[Math.floor(Math.random() * messages.length)];
    this.showTouchDebug("[TEASE] " + message);

    // 调用全局的 triggerLive2DTeaseMessage 函数（如果存在）
    if (typeof (window as any).triggerLive2DTeaseMessage === 'function') {
      (window as any).triggerLive2DTeaseMessage(message);
    }
  }
}

/**
 * クリックしたときに呼ばれる。
 * 当单击时调用。
 */
function onClickBegan(e: MouseEvent): void {
  if (!LAppDelegate.getInstance()._view) {
    LAppPal.printMessage('view notfound');
    return;
  }
  LAppDelegate.getInstance()._captured = true;

  const posX: number = e.pageX;
  const posY: number = e.pageY;

  // 检查是否触发撩消息
  LAppDelegate.getInstance().checkMultiDragTease();

  LAppDelegate.getInstance()._view!.onTouchesBegan(posX, posY);
}

/**
 * マウスポインタが動いたら呼ばれる。
 */
function onMouseMoved(e: MouseEvent): void {
  if (!LAppDelegate.getInstance()._captured) {
    return;
  }

  if (!LAppDelegate.getInstance()._view) {
    LAppPal.printMessage('view notfound');
    return;
  }

  const rect = (e.target as Element).getBoundingClientRect();
  const posX: number = e.clientX - rect.left;
  const posY: number = e.clientY - rect.top;

  LAppDelegate.getInstance()._view!.onTouchesMoved(posX, posY);
}

/**
 * クリックが終了したら呼ばれる。
 */
function onClickEnded(e: MouseEvent): void {
  LAppDelegate.getInstance()._captured = false;
  if (!LAppDelegate.getInstance()._view) {
    LAppPal.printMessage('view notfound');
    return;
  }

  const rect = (e.target as Element).getBoundingClientRect();
  const posX: number = e.clientX - rect.left;
  const posY: number = e.clientY - rect.top;

  LAppDelegate.getInstance()._view!.onTouchesEnded(posX, posY);
}

/**
 * タッチしたときに呼ばれる。
 */
function onTouchBegan(e: TouchEvent): void {
  LAppDelegate.getInstance()._captured = true;

  const posX = e.changedTouches[0].pageX;
  const posY = e.changedTouches[0].pageY;

  // 检查是否触发撩消息
  LAppDelegate.getInstance().checkMultiDragTease();

  LAppDelegate.getInstance().showTouchDebug(`[START] (${posX.toFixed(0)}, ${posY.toFixed(0)})`);

  LAppDelegate.getInstance()._view!.onTouchesBegan(posX, posY);

  // 清除手指抬起重置标志，允许新的拖拽
  const live2DManager: LAppLive2DManager = LAppLive2DManager.getInstance();
  const model = live2DManager.getModel(0);
  if (model) {
    model.clearTouchEndedFlag();
  }
}

/**
 * スワイプすると呼ばれる。
 */
function onTouchMoved(e: TouchEvent): void {
  if (!LAppDelegate.getInstance()._captured) {
    return;
  }

  if (!LAppDelegate.getInstance()._view) {
    LAppPal.printMessage('view notfound');
    return;
  }

  const rect = (e.target as Element).getBoundingClientRect();

  const posX = e.changedTouches[0].clientX - rect.left;
  const posY = e.changedTouches[0].clientY - rect.top;

  LAppDelegate.getInstance()._view!.onTouchesMoved(posX, posY);
}

/**
 * タッチが終了したら呼ばれる。
 */
function onTouchEnded(e: TouchEvent): void {
  // 最显眼的调试信息，确保能看到
  LAppDelegate.getInstance().showTouchDebug('!!! ON_TOUCH_END CALLED !!!');
  console.log('[CRITICAL] onTouchEnded event fired!');
  
  try {
    LAppDelegate.getInstance()._captured = false;

    if (!LAppDelegate.getInstance()._view) {
      LAppPal.printMessage('view notfound');
      return;
    }

    const rect = (e.target as Element).getBoundingClientRect();

    const posX = e.changedTouches[0].clientX - rect.left;
    const posY = e.changedTouches[0].clientY - rect.top;
    LAppDelegate.getInstance().showTouchDebug(`[END] (${posX.toFixed(0)}, ${posY.toFixed(0)})`);

    LAppDelegate.getInstance()._view!.onTouchesEnded(posX, posY);

    // 重置drag为0，确保touchend后目光回到中心
    console.log('[DEBUG] onTouchEnded calling onDrag(0.0, 0.0)');
    const live2DManager: LAppLive2DManager = LAppLive2DManager.getInstance();
    live2DManager.onDrag(0.0, 0.0);
    console.log('[DEBUG] onDrag called');
    LAppDelegate.getInstance().showTouchDebug('[DEBUG] onDrag called');
    
    // 打印drag manager的实际值
    const model = live2DManager.getModel(0);
    if (model) {
      const dragX = model.getDraggingX();
      const dragY = model.getDraggingY();
      console.log(`[DEBUG] After onDrag: dragX=${dragX}, dragY=${dragY}`);
      LAppDelegate.getInstance().showTouchDebug(`drag=(${dragX.toFixed(2)}, ${dragY.toFixed(2)})`);

      // 通知 model 在下一帧强制归零 drag 值（安全网）
      model.resetDragOnTouchEnd();
    }
  } catch (error) {
    LAppDelegate.getInstance().showTouchDebug(`[ERROR] ${error}`);
    console.error('[DEBUG] onTouchEnded error:', error);
  }
}

/**
 * 触摸被取消时调用。
 * touchcancel时直接重置drag为(0,0)，确保目光回到中心
 */
function onTouchCancel(e: TouchEvent): void {
  e.preventDefault();  // 阻止同时触发 mouseup

  LAppDelegate.getInstance()._captured = false;

  LAppDelegate.getInstance().showTouchDebug(`[CANCEL]`);

  // 直接重置drag为0，确保touchcancel时目光回到中心
  const live2DManager: LAppLive2DManager = LAppLive2DManager.getInstance();
  live2DManager.onDrag(0.0, 0.0);

  // 通知 model 在下一帧强制归零 drag 值（安全网）
  const model = live2DManager.getModel(0);
  if (model) {
    model.resetDragOnTouchEnd();
  }
}
