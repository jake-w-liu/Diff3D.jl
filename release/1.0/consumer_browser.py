"""Check the installed consumer's standalone export against known pixels."""

import argparse
from pathlib import Path
import sys

from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "examples"))
from browser_support import BROWSERS, launch_browser, report_browser_environment


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("html", type=Path)
    parser.add_argument("--browser", choices=BROWSERS, required=True)
    args = parser.parse_args()
    if not args.html.is_file():
        parser.error(f"missing consumer export: {args.html}")
    with sync_playwright() as playwright:
        browser = launch_browser(playwright, args.browser)
        try:
            page = browser.new_page(viewport={"width": 800, "height": 600})
            # Loading and initialising the exported viewer takes far longer than
            # Playwright's 30s default on the slower release runners.
            page.set_default_timeout(120000)
            errors, remote_requests = [], []
            page.on("pageerror", lambda error: errors.append(str(error)))
            page.on("console", lambda message: errors.append(message.text)
                    if message.type == "error" else None)
            page.on("request", lambda request: remote_requests.append(request.url)
                    if request.url.startswith(("http:", "https:")) else None)
            page.goto(args.html.resolve().as_uri())
            page.wait_for_function("window.__diff3dDebug && window.__diff3dDebug.activeObjectCount() === 1")
            page.evaluate("() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))")
            report_browser_environment(browser, page)
            result = page.evaluate("""() => {
                const canvas=document.querySelector('canvas'), gl=canvas.getContext('webgl');
                gl.finish();
                const center=new Uint8Array(4), corner=new Uint8Array(4);
                gl.readPixels(Math.floor(canvas.width/2),Math.floor(canvas.height/2),1,1,
                              gl.RGBA,gl.UNSIGNED_BYTE,center);
                gl.readPixels(1,1,1,1,gl.RGBA,gl.UNSIGNED_BYTE,corner);
                return {center:Array.from(center),corner:Array.from(corner),error:gl.getError()};
            }""")
            if any(abs(actual - expected) > 1 for actual, expected in
                   zip(result["center"], [51, 102, 153, 255])):
                raise AssertionError(f"Imported triangle color: {result}")
            if result["corner"] != [0, 0, 0, 255] or result["error"] != 0:
                raise AssertionError(f"Imported triangle background/WebGL error: {result}")
            if errors or remote_requests:
                raise AssertionError(f"Standalone export errors={errors}, remote requests={remote_requests}")
            print(f"CONSUMER_BROWSER_OK {args.browser} {result}", flush=True)
        finally:
            browser.close()


if __name__ == "__main__":
    main()
