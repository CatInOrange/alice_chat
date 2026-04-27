export function resolveLive2DGlContext(targetCanvas) {
  if (!targetCanvas?.getContext) {
    return null;
  }

  return (
    targetCanvas.getContext("webgl2") ||
    targetCanvas.getContext("webgl") ||
    null
  );
}

export function canInitializeLive2DDelegate({ canvas, gl }) {
  return Boolean(canvas && gl);
}

/**
 * Collect WebGL debug information for diagnosing rendering issues.
 * Call this and send the result to /api/debug/webgl
 */
export function collectWebGLDebugInfo(gl: WebGLRenderingContext | WebGL2RenderingContext, canvas: HTMLCanvasElement) {
  // Get texture load log if available
  const textureLog = (window as unknown as Record<string, unknown>).textureLoadLog as string[] | undefined;

  const debugInfo: Record<string, unknown> = {
    timestamp: new Date().toISOString(),
    userAgent: navigator.userAgent,
    canvas: {
      width: canvas.width,
      height: canvas.height,
      clientWidth: canvas.clientWidth,
      clientHeight: canvas.clientHeight,
      offsetWidth: canvas.offsetWidth,
      offsetHeight: canvas.offsetHeight,
    },
    devicePixelRatio: window.devicePixelRatio,
    webgl: {
      version: gl.getParameter(gl.VERSION),
      shadingLanguageVersion: gl.getParameter(gl.SHADING_LANGUAGE_VERSION),
      vendor: gl.getParameter(gl.VENDOR),
      renderer: gl.getParameter(gl.RENDERER),
    },
    precision: {
      floatVertex: gl.getShaderPrecisionFormat(gl.VERTEX_SHADER, gl.FLOAT),
      floatFragment: gl.getShaderPrecisionFormat(gl.FRAGMENT_SHADER, gl.FLOAT),
      highpFloatFragment: gl.getShaderPrecisionFormat(gl.FRAGMENT_SHADER, gl.HIGH_FLOAT),
      mediumpFloatFragment: gl.getShaderPrecisionFormat(gl.FRAGMENT_SHADER, gl.MEDIUM_FLOAT),
      lowpFloatFragment: gl.getShaderPrecisionFormat(gl.FRAGMENT_SHADER, gl.LOW_FLOAT),
    },
    limits: {
      maxTextureSize: gl.getParameter(gl.MAX_TEXTURE_SIZE),
      maxViewportDims: gl.getParameter(gl.MAX_VIEWPORT_DIMS),
      maxRenderbufferSize: gl.getParameter(gl.MAX_RENDERBUFFER_SIZE),
    },
    errors: [],
    textureLoadLog: textureLog || [],
  };

  // Collect WebGL errors
  const errorCodes = [gl.NO_ERROR, gl.INVALID_ENUM, gl.INVALID_VALUE, gl.INVALID_OPERATION, gl.OUT_OF_MEMORY, gl.INVALID_FRAMEBUFFER_OPERATION];
  const errorNames = ['NO_ERROR', 'INVALID_ENUM', 'INVALID_VALUE', 'INVALID_OPERATION', 'OUT_OF_MEMORY', 'INVALID_FRAMEBUFFER_OPERATION'];
  for (let i = 0; i < errorCodes.length; i++) {
    if (gl.getError() !== gl.NO_ERROR) {
      debugInfo.errors.push(errorNames[i]);
    }
  }

  // Try to get unmasked info if available
  const ext = gl.getExtension('WEBGL_debug_renderer_info');
  if (ext) {
    debugInfo.webglUnmasked = {
      vendor: gl.getParameter(ext.UNMASKED_VENDOR_WEBGL),
      renderer: gl.getParameter(ext.UNMASKED_RENDERER_WEBGL),
    };
  }

  return debugInfo;
}

/**
 * Send WebGL debug info to the backend.
 * Call this manually or set up automatic reporting on errors.
 */
export async function reportWebGLDebug(gl: WebGLRenderingContext | WebGL2RenderingContext, canvas: HTMLCanvasElement, backendUrl: string = '') {
  const debugInfo = collectWebGLDebugInfo(gl, canvas);

  const url = backendUrl || (window.location.protocol === 'https:' ? `https://${window.location.host}` : `http://${window.location.host}`);

  try {
    const response = await fetch(`${url}/api/debug/webgl`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(debugInfo),
    });
    if (!response.ok) {
      const text = await response.text();
      console.error(`[reportWebGLDebug] HTTP ${response.status}: ${text}`);
      return { error: `HTTP ${response.status}: ${text}` };
    }
    return await response.json();
  } catch (e) {
    console.error('[reportWebGLDebug] Fetch failed:', e);
    return { error: String(e) };
  }
}

// Expose to window for manual testing in browser console
if (typeof window !== 'undefined') {
  (window as unknown as Record<string, unknown>).reportWebGLDebug = reportWebGLDebug;
}
