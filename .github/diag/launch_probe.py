"""Launch Firefox repeatedly and record whether each instance can create a WebGL context,
and Firefox's own reason when it cannot. Usage: launch_probe.py <launches per mode>"""
import collections, json, sys
from playwright.sync_api import sync_playwright

PAGE = "data:text/html,<canvas id=c></canvas>"
PROBE = """() => { const c=document.getElementById('c'); let reason=null;
  c.addEventListener('webglcontextcreationerror', e => { reason = e.statusMessage || '(empty statusMessage)'; });
  const gl=c.getContext('webgl'); const i=gl&&gl.getExtension('WEBGL_debug_renderer_info');
  return {ok:!!gl, reason, renderer: gl ? gl.getParameter(i ? i.UNMASKED_RENDERER_WEBGL : gl.RENDERER) : null}; }"""
count = int(sys.argv[1])
with sync_playwright() as pw:
    for mode in ("headless", "headful"):
        tally, reasons = collections.Counter(), collections.Counter()
        for i in range(count):
            browser = pw.firefox.launch(headless=(mode == "headless"),
                                        firefox_user_prefs={"webgl.sanitize-unmasked-renderer": False})
            try:
                page = browser.new_page()
                page.goto(PAGE)
                first = page.evaluate(PROBE)
                second = page.evaluate(PROBE)  # a second context in the same instance
            finally:
                browser.close()
            tally["first_ok" if first["ok"] else "first_fail"] += 1
            tally["second_ok" if second["ok"] else "second_fail"] += 1
            if not first["ok"]:
                reasons[first["reason"]] += 1
                print("LAUNCH_FAIL", mode, i, json.dumps(first), "second:", json.dumps(second), flush=True)
        print("LAUNCH_TALLY", mode, dict(tally), "reasons", dict(reasons), flush=True)
