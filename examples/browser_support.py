"""Shared browser launch and environment reporting for WebGL validation."""

import json
import platform


BROWSERS = ("chromium", "firefox", "webkit")


def launch_browser(playwright, name: str):
    if name not in BROWSERS:
        raise ValueError(f"unsupported validation browser: {name}")
    options = {"headless": True}
    if name == "chromium":
        options["args"] = [
            "--use-angle=swiftshader", "--use-gl=angle",
            "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist",
        ]
    return getattr(playwright, name).launch(**options)


def report_browser_environment(browser, page) -> dict:
    graphics = page.evaluate("""() => {
        const canvas = document.querySelector('canvas');
        if (!canvas) throw new Error('Validation page has no canvas');
        const gl = canvas.getContext('webgl');
        if (!gl) throw new Error('Validation browser has no WebGL 1 context');
        const info = gl.getExtension('WEBGL_debug_renderer_info');
        return {
            userAgent: navigator.userAgent, version: gl.getParameter(gl.VERSION),
            renderer: gl.getParameter(info ? info.UNMASKED_RENDERER_WEBGL : gl.RENDERER),
            vendor: gl.getParameter(info ? info.UNMASKED_VENDOR_WEBGL : gl.VENDOR),
            context: gl.getContextAttributes(), width: canvas.width, height: canvas.height,
            limits: {fragmentTextures: gl.getParameter(gl.MAX_TEXTURE_IMAGE_UNITS),
                     vertexTextures: gl.getParameter(gl.MAX_VERTEX_TEXTURE_IMAGE_UNITS),
                     combinedTextures: gl.getParameter(gl.MAX_COMBINED_TEXTURE_IMAGE_UNITS)},
        };
    }""")
    result = {"browser": browser.browser_type.name, "browser_version": browser.version,
              "os": platform.platform(), "arch": platform.machine(), "graphics": graphics}
    print("BROWSER_ENVIRONMENT " + json.dumps(result, sort_keys=True), flush=True)
    return result
