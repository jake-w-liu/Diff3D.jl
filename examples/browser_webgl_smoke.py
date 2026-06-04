from pathlib import Path
import sys

from playwright.sync_api import sync_playwright


def smoke_html(path: Path) -> int:
    url = path.resolve().as_uri()
    args = [
        "--use-angle=swiftshader",
        "--use-gl=angle",
        "--enable-unsafe-swiftshader",
        "--ignore-gpu-blocklist",
    ]
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True, args=args)
        page = browser.new_page(viewport={"width": 1280, "height": 800})
        errors = []
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.on("console", lambda msg: errors.append(msg.text) if msg.type == "error" else None)
        page.goto(url)
        page.wait_for_selector("canvas")
        page.wait_for_timeout(1000)

        speed = page.locator("#speed")
        if speed.count():
            speed.evaluate(
                """el => {
                    el.value = '1.75';
                    el.dispatchEvent(new Event('input', { bubbles: true }));
                }"""
            )
            speed_state = page.evaluate("() => window.__threejlDebug.animationSpeed()")
            if abs(speed_state - 1.75) > 1e-6:
                errors.append(f"{path}: speed control did not update runtime speed")
            page.locator("#playToggle").click()
            if not page.evaluate("() => window.__threejlDebug.animationPaused()"):
                errors.append(f"{path}: pause control did not update runtime state")
            page.locator("#playToggle").click()

        buttons = page.locator("button[data-case]")
        count = max(1, buttons.count())
        for i in range(count):
            if buttons.count():
                buttons.nth(i).click()
                page.wait_for_timeout(350)
            canvas = page.locator("canvas")
            box = canvas.bounding_box()
            x = box["x"] + box["width"] / 2
            y = box["y"] + box["height"] / 2
            page.mouse.move(x, y)
            page.mouse.down()
            page.mouse.move(x + 180, y + 220, steps=12)
            page.mouse.move(x - 120, y - 160, steps=12)
            page.mouse.up()
            page.mouse.wheel(0, -180)
            page.wait_for_timeout(350)
            canvas.focus()
            page.keyboard.press("ArrowLeft")
            page.keyboard.press("ArrowUp")
            page.keyboard.press("=")
            page.wait_for_timeout(250)
            page.keyboard.down("Shift")
            page.mouse.move(x, y)
            page.mouse.down()
            page.mouse.move(x + 160, y + 80, steps=10)
            page.mouse.up()
            page.keyboard.up("Shift")
            page.wait_for_timeout(350)
            page.mouse.move(x, y)
            page.mouse.down()
            page.mouse.move(x, y - 1200, steps=16)
            page.mouse.up()
            page.wait_for_timeout(350)
            page.evaluate(
                """([x, y]) => {
                    const c = document.querySelector('canvas');
                    const fire = (type, id, cx, cy) => c.dispatchEvent(new PointerEvent(type, {
                        bubbles: true, pointerId: id, pointerType: 'touch',
                        clientX: cx, clientY: cy, button: 0, buttons: type === 'pointerup' ? 0 : 1
                    }));
                    fire('pointerdown', 31, x - 80, y - 40);
                    fire('pointerdown', 32, x + 80, y + 40);
                    fire('pointermove', 31, x - 120, y - 70);
                    fire('pointermove', 32, x + 120, y + 70);
                    fire('pointerup', 31, x - 120, y - 70);
                    fire('pointerup', 32, x + 120, y + 70);
                }""",
                [x, y],
            )
            page.wait_for_timeout(350)
            draw_counts = page.evaluate(
                """() => {
                    const expected = window.__threejlDebug.activeObjectCount();
                    const actual = Number((document.getElementById('stats').textContent.match(/\\d+/) || ['0'])[0]);
                    return { expected, actual };
                }"""
            )
            if draw_counts["actual"] != draw_counts["expected"]:
                errors.append(
                    f"{path}: drew {draw_counts['actual']} of {draw_counts['expected']} objects from underside in case {i}"
                )
            pixels = page.evaluate(
                """() => {
                    const c = document.querySelector('canvas');
                    const gl = c.getContext('webgl') || c.getContext('experimental-webgl');
                    const p = new Uint8Array(4);
                    gl.readPixels(Math.floor(c.width / 2), Math.floor(c.height / 2), 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, p);
                    return Array.from(p);
                }"""
            )
            if pixels[3] == 0:
                errors.append(f"{path}: center alpha zero after case {i}")
        browser.close()
    if errors:
        print("BROWSER_WEBGL_ERRORS", file=sys.stderr)
        for err in errors:
            print(err, file=sys.stderr)
        return 1
    print(f"BROWSER_WEBGL_OK {path} cases={count}")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: python examples/browser_webgl_smoke.py <html> [<html> ...]", file=sys.stderr)
        return 2
    rc = 0
    for arg in sys.argv[1:]:
        rc = max(rc, smoke_html(Path(arg)))
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
