"""Draw the failing plane's exact clip-space triangles (and controls) in fresh WebGL
contexts in Firefox and report how many pixels each produced. mode: hardware|software
(software forces webgl.forbid-hardware). Extra key=value args are Firefox prefs."""
import json, sys
from pathlib import Path
from playwright.sync_api import sync_playwright
mode, trials = sys.argv[1], int(sys.argv[2])
extra = dict(kv.split("=",1) for kv in sys.argv[3:])
extra = {k: (v=="true" if v in ("true","false") else v) for k,v in extra.items()}
here = Path(__file__).resolve().parent  # clip.html sits beside this script
# Clip coordinates of the four plane corners at the failing restored view (from the CI log,
# canvas 678x424) and at the fitted view (dist 2200), computed from the uniforms read back.
R = [[576.4, 2537.2, 4796.32, 4839.64], [4231.2, -345.7, 1843.43, 1887.68], [-4231.2, 345.7, 2551.52, 2595.55], [-576.4, -2537.2, -401.36, -356.41]]
F = [[586.9, 2528.9, 4755.49, 4798.02], [4217.2, -337.7, 1802.63, 1846.07], [-4217.2, 337.7, 2510.71, 2553.93], [-586.9, -2528.9, -442.15, -398.02]]
tri = lambda V, i: [V[i[0]], V[i[1]], V[i[2]]]
cases = {
    "plane_restored (both tris contain w<0 vertex)": [tri(R, (0, 3, 1)), tri(R, (0, 2, 3))],
    "plane_fitted": [tri(F, (0, 3, 1)), tri(F, (0, 2, 3))],
    "one_tri_w_negative": [tri(R, (0, 3, 1))],
    "control_all_w_positive_offscreen_extent": [[R[0], R[1], R[2]]],
    "control_fullscreen_w1": [[[-1, -1, 0, 1], [3, -1, 0, 1], [-1, 3, 0, 1]]],
    "small_w_negative": [[[-0.5, -0.5, 0, 1], [0.5, -0.5, 0, 1], [0, 0.5, -2, -0.5]]],
}
def grid(V, n):
    lerp = lambda a, b, t: [a[k] + (b[k] - a[k]) * t for k in range(4)]
    # corners in plane order: 0=(-,+) 1=(+,+) 2=(-,-) 3=(+,-); bilinear is exact for an affine image of a square
    at = lambda u, v: lerp(lerp(V[2], V[3], u), lerp(V[0], V[1], u), v)
    out = []
    for i in range(n):
        for j in range(n):
            a, b, c, d = at(i/n, j/n), at((i+1)/n, j/n), at(i/n, (j+1)/n), at((i+1)/n, (j+1)/n)
            out += [[a, b, d], [a, d, c]]
    return out
for n in (2, 4, 8, 16):
    cases["plane_restored_grid%dx%d" % (n, n)] = grid(R, n)
prefs = {"webgl.forbid-hardware": True} if mode == "software" else {}
prefs.update(extra)
with sync_playwright() as pw:
    b = pw.firefox.launch(headless=True, firefox_user_prefs={**prefs, "webgl.sanitize-unmasked-renderer": False})
    try:
        p = b.new_page(); p.goto((here / "clip.html").as_uri())
        res = p.evaluate("([c,t,w,h])=>runClip(c,t,w,h)", [cases, trials, 678, 424])
    finally:
        b.close()
for k, v in res.items():
    print(mode, json.dumps(v), k)
