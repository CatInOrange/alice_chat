// @ts-nocheck
/**
 * Copyright(c) Live2D Inc. All rights reserved.
 *
 * Use of this source code is governed by the Live2D Open Software license
 * that can be found at https://www.live2d.com/eula/live2d-open-software-license-agreement_en.html.
 */

import { gl } from "./lappglmanager";

// Global texture load log for debugging
export const textureLoadLog: string[] = [];

// Expose textureLoadLog to window for access in debug utilities
if (typeof window !== 'undefined') {
  (window as unknown as Record<string, unknown>).textureLoadLog = textureLoadLog;
}

/**
 * テクスチャ管理クラス
 * 画像読み込み、管理を行うクラス。
 */
export class LAppTextureManager {
  /**
   * コンストラクタ
   */
  constructor() {
    this._textures = new Array<TextureInfo>();
  }

  /**
   * 解放する。
   */
  public release(): void {
    for (const textureInfo of this._textures) {
      gl.deleteTexture(textureInfo.id);
    }
    this._textures = null;
  }

  /**
   * 画像読み込み
   *
   * @param fileName 読み込む画像ファイルパス名
   * @param usePremultiply Premult処理を有効にするか
   * @return 画像情報、読み込み失敗時はnullを返す
   */
  public createTextureFromPngFile(
    fileName: string,
    usePremultiply: boolean,
    callback: (textureInfo: TextureInfo) => void
  ): void {
    // search loaded texture already
    for (const textureInfo of this._textures) {
      if (
        textureInfo.fileName == fileName &&
        textureInfo.usePremultply == usePremultiply
      ) {
        // 2回目以降はキャッシュが使用される(待ち時間なし)
        // WebKitでは同じImageのonloadを再度呼ぶには再インスタンスが必要
        // 詳細：https://stackoverflow.com/a/5024181
        textureInfo.img = new Image();
        textureInfo.img.addEventListener("load", (): void => callback(textureInfo), {
          passive: true,
        });
        textureInfo.img.src = fileName;
        return;
      }
    }

    // データのオンロードをトリガーにする
    const img = new Image();
    img.crossOrigin = "anonymous";
    const logMsg = `[TextureLoad] Loading: ${fileName}`;
    console.log(logMsg);
    textureLoadLog.push(logMsg);
    img.addEventListener(
      "load",
      (): void => {
        const logMsg = `[TextureLoad] Loaded: ${fileName} (${img.width}x${img.height})`;
        console.log(logMsg);
        textureLoadLog.push(logMsg);
        // テクスチャオブジェクトの作成
        const tex: WebGLTexture = gl.createTexture();

        // テクスチャを選択
        gl.bindTexture(gl.TEXTURE_2D, tex);

        // テクスチャにピクセルを書き込む
        gl.texParameteri(
          gl.TEXTURE_2D,
          gl.TEXTURE_MIN_FILTER,
          gl.LINEAR_MIPMAP_LINEAR
        );
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);

        // Premult処理を行わせる
        if (usePremultiply) {
          gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, 1);
        }

        // テクスチャにピクセルを書き込む
        gl.texImage2D(
          gl.TEXTURE_2D,
          0,
          gl.RGBA,
          gl.RGBA,
          gl.UNSIGNED_BYTE,
          img
        );

        // ミップマップを生成
        gl.generateMipmap(gl.TEXTURE_2D);

        // テクスチャをバインド
        gl.bindTexture(gl.TEXTURE_2D, null);

        const textureInfo: TextureInfo = new TextureInfo();
        if (textureInfo != null) {
          textureInfo.fileName = fileName;
          textureInfo.width = img.width;
          textureInfo.height = img.height;
          textureInfo.id = tex;
          textureInfo.img = img;
          textureInfo.usePremultply = usePremultiply;

          if (this._textures == null) {
            gl.deleteTexture(tex);
            return;
          }

          this._textures.push(textureInfo);
        }

        callback(textureInfo);
      },
      { passive: true }
    );
    img.addEventListener("error", (): void => {
      const logMsg = `[TextureLoad] FAILED: ${fileName}`;
      console.error(logMsg);
      textureLoadLog.push(logMsg);
    });
    img.src = fileName;
  }

  /**
   * 画像の解放
   *
   * 配列に存在する画像全てを解放する。
   */
  public releaseTextures(): void {
    for (let i = 0; i < this._textures.length; i++) {
      this._textures[i] = null;
    }

    this._textures = [];
  }

  /**
   * 画像の解放
   *
   * 指定したテクスチャの画像を解放する。
   * @param texture 解放するテクスチャ
   */
  public releaseTextureByTexture(texture: WebGLTexture): void {
    for (let i = 0; i < this._textures.length; i++) {
      if (this._textures[i].id != texture) {
        continue;
      }

      this._textures[i] = null;
      this._textures.splice(i, 1);
      break;
    }
  }

  /**
   * 画像の解放
   *
   * 指定した名前の画像を解放する。
   * @param fileName 解放する画像ファイルパス名
   */
  public releaseTextureByFilePath(fileName: string): void {
    for (let i = 0; i < this._textures.length; i++) {
      if (this._textures[i].fileName == fileName) {
        this._textures[i] = null;
        this._textures.splice(i, 1);
        break;
      }
    }
  }

  _textures: Array<TextureInfo>;
}

/**
 * 画像情報構造体
 */
export class TextureInfo {
  img: HTMLImageElement; // 画像
  id: WebGLTexture = null; // テクスチャ
  width = 0; // 横幅
  height = 0; // 高さ
  usePremultply: boolean; // Premult処理を有効にするか
  fileName: string; // ファイル名
}
