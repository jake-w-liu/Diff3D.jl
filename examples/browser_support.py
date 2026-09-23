"""Shared browser launch and environment reporting for WebGL validation."""

import json
import platform


BROWSERS = ("chromium", "firefox", "webkit")

# Apple's software OpenGL renderer, which Firefox falls back to on a Mac with no GPU
# (the GitHub macOS runners are such VMs), drops triangles that need clipping: drawn
# natively through CGL, one of the orbit fixture's two triangles produced no pixels in
# 50 of 50 draws, and three.js loses 57% of the same plane on it. Pixel validation on
# that rasteriser measures the rasteriser, not the export, so it is refused. See
# release/1.0/evidence.md, "the macOS Firefox blank frame".
NONCONFORMANT_RENDERERS = ("Apple Software Renderer",)

# A Firefox instance started under Xvfb occasionally comes up unable to create any WebGL
# context ("Exhausted GL driver options"): 4 of 323 launches measured on the Linux
# runners. Such an instance stays unusable (a second context fails too), and each of the
# three relaunches that followed a failure worked, so the instance is replaced.
LAUNCH_ATTEMPTS = 3

_WEBGL_PROBE = """() => {
    const canvas = document.createElement('canvas');
    let reason = null;
    canvas.addEventListener('webglcontextcreationerror',
        event => { reason = event.statusMessage || 'no status message'; });
    const gl = canvas.getContext('webgl');
    if (gl) {
        const lose = gl.getExtension('WEBGL_lose_context');
        if (lose) lose.loseContext();
    }
    return {ok: !!gl, reason};
}"""


def _probe_webgl(browser) -> dict:
    page = browser.new_page()
    try:
        return page.evaluate(_WEBGL_PROBE)
    finally:
        page.close()


def launch_browser(playwright, name: str):
    """Launch a validation browser that can create a WebGL 1 context.

    Firefox reports its real renderer (it otherwise sanitises the string, which hid that
    the macOS runners render in software). An instance that cannot create a context is
    closed and relaunched, at most LAUNCH_ATTEMPTS times, with the browser's reason
    printed for each failure.
    """
    if name not in BROWSERS:
        raise ValueError(f"unsupported validation browser: {name}")
    options = {"headless": True}
    if name == "chromium":
        options["args"] = [
            "--use-angle=swiftshader", "--use-gl=angle",
            "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist",
        ]
    elif name == "firefox":
        options["firefox_user_prefs"] = {"webgl.sanitize-unmasked-renderer": False}
    reasons = []
    for attempt in range(1, LAUNCH_ATTEMPTS + 1):
        browser = getattr(playwright, name).launch(**options)
        try:
            status = _probe_webgl(browser)
        except BaseException:
            browser.close()
            raise
        if status["ok"]:
            return browser
        browser.close()
        reasons.append(status["reason"])
        print(f"BROWSER_LAUNCH_RETRY {name} attempt {attempt}/{LAUNCH_ATTEMPTS}: "
              f"no WebGL 1 context ({status['reason']})", flush=True)
    raise RuntimeError(f"{name} could not create a WebGL 1 context in {LAUNCH_ATTEMPTS} "
                       f"launches: {reasons}")


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
    renderer = str(graphics.get("renderer") or "")
    if any(renderer.startswith(known) for known in NONCONFORMANT_RENDERERS):
        raise RuntimeError(
            f"{result['browser']} is rendering with {renderer!r}, which drops triangles that "
            "need clipping, so pixel validation on it is meaningless. Run on a GPU or on a "
            "conformant software rasteriser such as Mesa llvmpipe (Linux, under Xvfb for "
            "Firefox); see release/1.0/evidence.md, 'the macOS Firefox blank frame'.")
    return result
