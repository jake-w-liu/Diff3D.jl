"""Print the WebGL renderer Firefox reports with and without its renderer sanitising."""
from playwright.sync_api import sync_playwright

PAGE = "data:text/html,<canvas id=c></canvas>"
QUERY = """() => { const gl=document.getElementById('c').getContext('webgl'); if(!gl) return null;
    const i=gl.getExtension('WEBGL_debug_renderer_info');
    return {renderer:gl.getParameter(i?i.UNMASKED_RENDERER_WEBGL:gl.RENDERER), vendor:gl.getParameter(i?i.UNMASKED_VENDOR_WEBGL:gl.VENDOR)}; }"""
with sync_playwright() as pw:
    for sanitize in (True, False):
        browser = pw.firefox.launch(headless=True, firefox_user_prefs={"webgl.sanitize-unmasked-renderer": sanitize})
        try:
            page = browser.new_page()
            page.goto(PAGE)
            print("FIREFOX_GPU", {"sanitized": sanitize, **(page.evaluate(QUERY) or {})}, flush=True)
        finally:
            browser.close()
