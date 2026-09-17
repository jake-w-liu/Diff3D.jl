"""Verify exported rendering through Chromium pixels and draw counts."""

import argparse
import math
from pathlib import Path
import subprocess
import tempfile

from playwright.sync_api import sync_playwright


def select_render_case(page, case_id: str) -> None:
    page.evaluate("""id => {
        const button=document.querySelector('button[data-case="'+id+'"]');
        if(!button) throw new Error('Missing render case '+id);
        button.click();
        window.__diff3dTestRenderFrame();
        if(active.id!==id) throw new Error('Render case did not change to '+id);
    }""", case_id)


def compare_baked_geometry(page, name: str, width: int, height: int) -> None:
    wireframe = "wireframe" in name
    modes = page.evaluate("""() => active.objects.filter(o=>o.skin)
        .map(o=>o.textureSkin?'texture':o.shaderSkin?'uniform':'cpu')""")
    expected_modes = [name.rsplit('_', 1)[1]] if name.startswith("skin_") else []
    if name in ("skin_normals_singular", "skin_world_detached", "skin_world_animated",
                "skin_wireframe_detached", "skin_wireframe_animated"):
        expected_modes = ["uniform"]
    if modes != expected_modes:
        raise AssertionError(f"{name}: expected skin modes {expected_modes}, got {modes}")
    page.evaluate("""() => {
        const c=document.querySelector('canvas'),gl=c.getContext('webgl');
        const data=new Uint8Array(c.width*c.height*4);
        gl.readPixels(0,0,c.width,c.height,gl.RGBA,gl.UNSIGNED_BYTE,data);
        window.__normalReference={width:c.width,height:c.height,data};
    }""")
    select_render_case(page, "normal-reference")
    comparison = page.evaluate("""wireframe => {
        const c=document.querySelector('canvas'),gl=c.getContext('webgl');
        const actual=window.__normalReference;
        if(actual.width!==c.width||actual.height!==c.height) return {resized:true};
        const data=new Uint8Array(c.width*c.height*4);
        gl.readPixels(0,0,c.width,c.height,gl.RGBA,gl.UNSIGNED_BYTE,data);
        const foreground=(d,i)=>Math.max(d[i],d[i+1],d[i+2])>8;
        let actualCount=0,referenceCount=0,compared=0,maxError=0;
        for(let y=0;y<c.height;y++) for(let x=0;x<c.width;x++){
            const i=4*(y*c.width+x);
            if(foreground(actual.data,i)) actualCount++;
            if(foreground(data,i)) referenceCount++;
            if(x<1||x>=c.width-1||y<1||y>=c.height-1) continue;
            const offsets=wireframe?[0]:[0,-4,4,-4*c.width,4*c.width];
            if(!offsets.every(o=>foreground(actual.data,i+o)&&foreground(data,i+o))) continue;
            compared++;
            for(let channel=0;channel<3;channel++) maxError=Math.max(maxError,Math.abs(actual.data[i+channel]-data[i+channel]));
        }
        return {actualCount,referenceCount,compared,maxError,error:gl.getError()};
    }""", wireframe)
    # Float32 arithmetic can move boundary samples; compare the shared interior
    # while requiring matching foreground coverage.
    correct = (comparison.get("error") == 0 and comparison.get("compared", 0) > 100
               and comparison["maxError"] <= 3
               and abs(comparison["actualCount"]-comparison["referenceCount"])
               <= 0.01*max(comparison["actualCount"],comparison["referenceCount"]))
    if wireframe:
        correct = correct and comparison["compared"] >= 0.99*min(comparison["actualCount"],comparison["referenceCount"])
    if not correct:
        raise AssertionError(f"{name} baked geometry comparison at {width}x{height}: {comparison}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--julia", default="julia", help="Julia executable")
    parser.add_argument("--only", action="append", help="Run a named fixture (repeatable)")
    parser.add_argument("--fallback-only", action="store_true", help="Exercise missing ANGLE instancing")
    args = parser.parse_args()
    fixtures = ("stacked", "overlap", "empty_instances", "empty_instance_parent",
                "instanced_points", "instanced_lines", "instanced_triangles",
                "layered_views", "layered_lights", "layered_shadows",
                "hierarchy_static", "hierarchy_animated", "hierarchy_instances", "hierarchy_bones",
                "lod_groups", "lod_nested", "lod_manual", "lod_zoom", "lod_nested_far",
                "skin_normals_uniform", "skin_normals_texture", "skin_normals_cpu",
                "skin_normals_singular", "instanced_normals", "instanced_normals_reflected", "scaled_normals",
                "skin_world_uniform", "skin_world_texture", "skin_world_cpu", "skin_world_detached", "skin_world_animated",
                "skin_tangent_uniform", "skin_tangent_texture", "skin_tangent_cpu", "instanced_tangent", "model_tangent",
                "skin_wireframe_uniform", "skin_wireframe_texture", "skin_wireframe_cpu", "skin_wireframe_animated",
                "skin_wireframe_detached", "wireframe_morph", "instanced_wireframe",
                "sprite_orthographic", "sprite_perspective", "unlit_colors", "point_texture", "point_attenuation",
                "gltf_texture_uv0", "gltf_texture_uv1", "gltf_texture_mirrored",
                "fog_linear", "fog_exponential", "fog_transparent", "lighting_energy",
                "iridescence_range_ascending", "iridescence_range_descending",
                "matcap_normal_tangent", "matcap_normal_derivative", "toon_normal_tangent", "toon_normal_derivative",
                "gltf_view_camera", "gltf_view_lights", "gltf_view_pole",
                "orbit_zoom_limits")
    baked_fixtures = {"skin_normals_uniform", "skin_normals_texture", "skin_normals_cpu",
                      "skin_normals_singular", "instanced_normals", "instanced_normals_reflected", "scaled_normals",
                      "skin_world_uniform", "skin_world_texture", "skin_world_cpu", "skin_world_detached", "skin_world_animated",
                      "skin_tangent_uniform", "skin_tangent_texture", "skin_tangent_cpu", "instanced_tangent", "model_tangent",
                      "skin_wireframe_uniform", "skin_wireframe_texture", "skin_wireframe_cpu", "skin_wireframe_animated",
                      "skin_wireframe_detached", "wireframe_morph", "instanced_wireframe",
                      "sprite_orthographic", "sprite_perspective",
                      "gltf_texture_uv0", "gltf_texture_uv1", "gltf_texture_mirrored",
                      "fog_linear", "fog_exponential", "fog_transparent",
                      "iridescence_range_ascending", "iridescence_range_descending",
                "matcap_normal_tangent", "matcap_normal_derivative", "toon_normal_tangent", "toon_normal_derivative",
                "gltf_view_camera", "gltf_view_lights", "gltf_view_pole"}
    controlled_fixtures = baked_fixtures | {"unlit_colors", "point_texture", "point_attenuation", "lighting_energy"}
    if args.only and set(args.only) - set(fixtures):
        parser.error("unknown fixture: " + ", ".join(sorted(set(args.only) - set(fixtures))))
    cases = [(name, enabled) for name in fixtures if not args.only or name in args.only
             for enabled in ((False,) if args.fallback_only else
                             (True, False) if name.startswith("instanced_") else (True,))]
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="diff3d-browser-rendering-") as directory:
        subprocess.run(
            [args.julia, "--startup-file=no", f"--project={root}",
             "-O0", "--compile=min", str(root / "test/browser_rendering.jl"), directory],
            cwd=root, check=True, timeout=300,
        )
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(
                headless=True,
                args=["--use-angle=swiftshader", "--use-gl=angle",
                      "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"],
            )
            try:
                for name, instancing_enabled in cases:
                    page = browser.new_page(viewport={"width": 1024, "height": 800})
                    errors = []
                    page.on("pageerror", lambda error, target=errors: target.append(str(error)))
                    page.on("console", lambda message, target=errors:
                            target.append(message.text) if message.type == "error" else None)
                    try:
                        if name in ("unlit_colors", "point_texture", "point_attenuation"):
                            # Isolate fragment color from multisample edge coverage.
                            page.add_init_script("""(() => {
                                const getContext=HTMLCanvasElement.prototype.getContext;
                                HTMLCanvasElement.prototype.getContext=function(name,attributes){
                                    return getContext.call(this,name,name==='webgl'?{...attributes,antialias:false}:attributes);
                                };
                            })();""")
                        if name in controlled_fixtures:
                            # Drive the real frame callbacks explicitly for image comparisons.
                            # This avoids relying on headless/background frame scheduling;
                            # other fixtures keep the ordinary animation loop.
                            page.add_init_script("""(() => {
                                const pending=new Map();let next=0;
                                window.requestAnimationFrame=callback=>{const id=++next;pending.set(id,callback);return id;};
                                window.cancelAnimationFrame=id=>pending.delete(id);
                                window.__diff3dTestRenderFrame=()=>{
                                    if(pending.size===0) throw new Error('No renderer frame is scheduled');
                                    const callbacks=Array.from(pending.values());pending.clear();
                                    const now=performance.now();for(const callback of callbacks) callback(now);
                                    return callbacks.length;
                                };
                            })();""")
                        if name in ("skin_normals_cpu", "skin_world_cpu", "skin_tangent_cpu", "skin_wireframe_cpu"):
                            page.add_init_script("""(() => {
                                const original = WebGLRenderingContext.prototype.getExtension;
                                WebGLRenderingContext.prototype.getExtension = function(name) {
                                    return name === 'OES_texture_float' ? null : original.call(this, name);
                                };
                            })();""")
                        if not instancing_enabled:
                            page.add_init_script("""(() => {
                                const original = WebGLRenderingContext.prototype.getExtension;
                                WebGLRenderingContext.prototype.getExtension = function(name) {
                                    return name === 'ANGLE_instanced_arrays' ? null : original.call(this, name);
                                };
                            })();""")
                        page.goto((Path(directory) / f"{name}.html").as_uri(), timeout=120000)
                        if name in controlled_fixtures:
                            page.evaluate("window.__diff3dTestRenderFrame()")
                        expected_views = 2 if name.startswith("lod_") or name in ("stacked", "overlap", "layered_views", "layered_lights", "layered_shadows") else 1
                        if name in controlled_fixtures:
                            state = page.evaluate("""() => ({views:window.__diff3dDebug?.activeViewCount(),
                                stats:document.getElementById('stats').textContent,caseId:active.id})""")
                            if state.get("views") != expected_views or not any(c.isdigit() for c in state["stats"]):
                                raise AssertionError(f"{name}: renderer startup state {state}, errors {errors}")
                        else:
                            page.wait_for_function(
                                f"window.__diff3dDebug && window.__diff3dDebug.activeViewCount() === {expected_views}"
                                " && /\\d+/.test(document.getElementById('stats').textContent)",
                                timeout=120000,
                            )
                        for width, height in ((1024, 800), (900, 720)):
                            page.set_viewport_size({"width": width, "height": height})
                            if name in controlled_fixtures:
                                select_render_case(page, "dark-lambert" if name=="lighting_energy" else "normal-actual")
                            page.wait_for_timeout(500)
                            pixels = page.evaluate("""() => {
                                const canvas = document.querySelector('canvas');
                                const gl = canvas.getContext('webgl');
                                function pixel(y) {
                                    const value = new Uint8Array(4);
                                    gl.readPixels(Math.floor(canvas.width / 2),
                                        Math.floor(canvas.height * y), 1, 1,
                                        gl.RGBA, gl.UNSIGNED_BYTE, value);
                                    return Array.from(value);
                                }
                                const data = new Uint8Array(canvas.width * canvas.height * 4);
                                gl.readPixels(0, 0, canvas.width, canvas.height,
                                              gl.RGBA, gl.UNSIGNED_BYTE, data);
                                let redCount = 0, blueCount = 0, redX = 0, blueX = 0;
                                const halves=[{red:0,green:0,blue:0},{red:0,green:0,blue:0}];
                                for (let i = 0; i < data.length; i += 4) {
                                    const x = ((i / 4) % canvas.width) / canvas.width;
                                    const half=halves[Math.floor(i/4/canvas.width)>=canvas.height/2?1:0];
                                    if (data[i] > 80 && data[i+1] < 20 && data[i+2] < 20) {
                                        redCount++; redX += x;
                                        half.red++;
                                    }
                                    if(data[i+1]>80&&data[i]<20&&data[i+2]<20) half.green++;
                                    if (data[i+2] > 80 && data[i] < 20 && data[i+1] < 20) {
                                        blueCount++; blueX += x;
                                        half.blue++;
                                    }
                                }
                                return {top: pixel(.75), bottom: pixel(.25),
                                        center: pixel(.5), error: gl.getError(),
                                        visible: window.__diff3dDebug.activeObjectCount(),
                                        instancing: !!gl.getExtension('ANGLE_instanced_arrays'),
                                        redCount, blueCount, redX: redX / Math.max(1, redCount),
                                        blueX: blueX / Math.max(1, blueCount),halves};
                            }""")
                            if pixels["error"] != 0 or errors:
                                raise AssertionError(f"{name}: WebGL errors {pixels['error']}, {errors}")
                            if name == "lighting_energy":
                                expected_cases={**{f"dark-{kind}":[0,0,0] for kind in ("lambert","phong","standard","physical")},
                                    "ambient":[51,77,102],"emissive":[51,26,13],
                                    **{f"back-{kind}":[0,0,0] for kind in ("directional","point","spot")}}
                                for case_id,expected in expected_cases.items():
                                    select_render_case(page,case_id)
                                    result=page.evaluate("""() => {
                                        const c=document.querySelector('canvas'),gl=c.getContext('webgl'),pixel=new Uint8Array(4);
                                        gl.readPixels(Math.floor(c.width/2),Math.floor(c.height/2),1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixel);
                                        return {pixel:Array.from(pixel).slice(0,3),error:gl.getError(),count:window.__diff3dDebug.activeObjectCount()};
                                    }""")
                                    if result["error"]!=0 or result["count"]!=1 or any(abs(a-b)>1 for a,b in zip(result["pixel"],expected)):
                                        raise AssertionError(f"{name} {case_id}: {result}, expected {expected}")
                                correct=True
                            elif name == "point_attenuation":
                                bounds=page.evaluate("""() => {
                                    const c=document.querySelector('canvas'),gl=c.getContext('webgl');
                                    const data=new Uint8Array(c.width*c.height*4);
                                    gl.readPixels(0,0,c.width,c.height,gl.RGBA,gl.UNSIGNED_BYTE,data);
                                    const boxes=Array.from({length:5},()=>({x0:c.width,y0:c.height,x1:-1,y1:-1,count:0}));
                                    for(let y=0;y<c.height;y++) for(let x=0;x<c.width;x++){
                                        const i=4*(y*c.width+x),r=data[i],g=data[i+1],b=data[i+2];
                                        const slot=r>200&&g>200&&b>200?4:r>200&&g>200&&b<20?3:r>200&&g<20&&b<20?0:g>200&&r<20&&b<20?1:b>200&&r<20&&g<20?2:-1;
                                        if(slot<0) continue;const box=boxes[slot];
                                        box.x0=Math.min(box.x0,x);box.x1=Math.max(box.x1,x);box.y0=Math.min(box.y0,y);box.y1=Math.max(box.y1,y);box.count++;
                                    }
                                    return boxes.map(b=>[b.x1-b.x0+1,b.y1-b.y0+1,b.count]);
                                }""")
                                if bounds != [[32,32,1024],[16,16,256],[1,1,1],[1,1,1],[1,1,1]]:
                                    raise AssertionError(f"{name}: red/green/blue/yellow/white footprints {bounds}")
                                correct=True
                            elif name == "point_texture":
                                for case_id in ("normal-actual", "point-alpha-zero", "point-alpha-one"):
                                    select_render_case(page,case_id)
                                    samples=page.evaluate("""() => {
                                        const c=document.querySelector('canvas'),gl=c.getContext('webgl');
                                        const data=new Uint8Array(c.width*c.height*4);
                                        gl.readPixels(0,0,c.width,c.height,gl.RGBA,gl.UNSIGNED_BYTE,data);
                                        const x=Math.floor(c.width/2),y=Math.floor(c.height/2);
                                        return [[-12,12],[12,12],[-12,-12],[12,-12]].map(([dx,dy])=>{
                                            const i=4*((y+dy)*c.width+x+dx);return Array.from(data.slice(i,i+3));
                                        });
                                    }""")
                                    expected=[[0,0,0]]*4 if case_id == "point-alpha-zero" else [[255,0,0],[0,255,0],[0,0,255],[255,255,0]]
                                    if samples != expected:
                                        raise AssertionError(f"{name} {case_id}: point texture quadrants {samples}, expected {expected}")
                                correct=True
                            elif name == "unlit_colors":
                                color_result = page.evaluate("""() => {
                                    const c=document.querySelector('canvas'),gl=c.getContext('webgl');
                                    const data=new Uint8Array(c.width*c.height*4);
                                    gl.readPixels(0,0,c.width,c.height,gl.RGBA,gl.UNSIGNED_BYTE,data);
                                    if(gl.getContextAttributes().antialias) throw new Error('Color fixture requires antialias=false');
                                    const samples=[.125,.375,.625,.875].map(x=>{
                                        const cx=Math.floor(x*c.width),cy=Math.floor(c.height/2);
                                        let best=[0,0,0];
                                        for(let dy=-2;dy<=2;dy++) for(let dx=-2;dx<=2;dx++){
                                            const i=4*((cy+dy)*c.width+cx+dx),rgb=Array.from(data.slice(i,i+3));
                                            if(rgb.reduce((a,b)=>a+b,0)>best.reduce((a,b)=>a+b,0)) best=rgb;
                                        }
                                        return best;
                                    });
                                    const px=Math.floor(.875*c.width),py=Math.floor(c.height/2);
                                    for(const dx of [-6,6]) for(const dy of [-6,6]){
                                        const i=4*((py+dy)*c.width+px+dx);samples.push(Array.from(data.slice(i,i+3)));
                                    }
                                    let minX=c.width,minY=c.height,maxX=-1,maxY=-1,count=0;
                                    for(let y=0;y<c.height;y++) for(let x=Math.floor(.75*c.width);x<c.width;x++){
                                        const i=4*(y*c.width+x);
                                        if(Math.max(data[i],data[i+1],data[i+2])===0) continue;
                                        minX=Math.min(minX,x);maxX=Math.max(maxX,x);minY=Math.min(minY,y);maxY=Math.max(maxY,y);count++;
                                    }
                                    return {samples,pointWidth:maxX-minX+1,pointHeight:maxY-minY+1,pointCount:count};
                                }""")
                                samples = color_result["samples"]
                                if any(any(abs(actual-expected)>1 for actual,expected in zip(sample,(51,102,153))) for sample in samples):
                                    raise AssertionError(f"{name} at {width}x{height}: mesh/sprite/line/point and point corners {samples}")
                                if (color_result["pointWidth"],color_result["pointHeight"],color_result["pointCount"]) != (16,16,256):
                                    raise AssertionError(f"{name}: size=16 point footprint {color_result}")
                                correct = True
                            elif name in baked_fixtures:
                                if name.startswith("gltf_view_"):
                                    pose_error = page.evaluate("""() => Math.hypot(...cameraEye(active.camera)
                                        .map((value,index)=>value-active.camera.position[index]))""")
                                    if pose_error > 1e-10:
                                        raise AssertionError(f"{name}: camera orbit changed the authored eye by {pose_error}")
                                if name.startswith("instanced_") and pixels["instancing"] != instancing_enabled:
                                    raise AssertionError(f"{name}: instancing capability mismatch")
                                compare_baked_geometry(page, name, width, height)
                                correct = True
                            elif name == "layered_shadows":
                                page.locator('button[data-case="shadow-layers"]').click(force=True)
                                page.wait_for_function("/^3 /.test(document.getElementById('stats').textContent)",timeout=120000)
                                page.evaluate("""() => {
                                    const c=document.querySelector('canvas'), gl=c.getContext('webgl');
                                    const data=new Uint8Array(c.width*c.height*4);
                                    gl.readPixels(0,0,c.width,c.height,gl.RGBA,gl.UNSIGNED_BYTE,data);
                                    window.__layerReference={data,width:c.width,height:c.height};
                                }""")
                                for reference, count, top_half in (("shadow-hidden",2,True),("shadow-visible",4,False)):
                                    page.locator(f'button[data-case="{reference}"]').click(force=True)
                                    page.wait_for_function(f"/^{count} /.test(document.getElementById('stats').textContent)",timeout=120000)
                                    comparison=page.evaluate("""topHalf => {
                                        const c=document.querySelector('canvas'), gl=c.getContext('webgl');
                                        const data=new Uint8Array(c.width*c.height*4);
                                        gl.readPixels(0,0,c.width,c.height,gl.RGBA,gl.UNSIGNED_BYTE,data);
                                        const saved=window.__layerReference;
                                        if(saved.width!==c.width||saved.height!==c.height) return {sizeChanged:true};
                                        let different=0,maxError=0;
                                        for(let y=0;y<c.height;y++){
                                            if(topHalf ? y<c.height/2+2 : y>=c.height/2-2) continue;
                                            for(let x=0;x<c.width;x++) for(let channel=0;channel<3;channel++){
                                                const i=4*(y*c.width+x)+channel,d=Math.abs(data[i]-saved.data[i]);
                                                if(d>1) different++;
                                                maxError=Math.max(maxError,d);
                                            }
                                        }
                                        return {different,maxError,error:gl.getError()};
                                    }""",top_half)
                                    if comparison.get("different") != 0 or comparison.get("error") != 0:
                                        raise AssertionError(f"{name} {reference}: {comparison}")
                                correct=True
                            elif name=="lod_nested_far":
                                top,bottom=pixels["top"],pixels["bottom"]
                                correct=top[0]>200 and top[1]>200 and top[2]<20
                                correct=correct and bottom[2]>200 and max(bottom[:2])<20
                            elif name.startswith("lod_"):
                                bottom,top=pixels["halves"]
                                correct=top["red"]>0 and top["green"]>0 and top["blue"]==0
                                if name=="lod_manual":
                                    correct=correct and bottom["red"]>0 and bottom["green"]>0 and bottom["blue"]==0
                                else:
                                    correct=correct and bottom["blue"]>0 and bottom["red"]==0 and bottom["green"]==0
                            elif name.startswith("hierarchy_"):
                                expected_x=(1+0.9/(4*math.tan(math.pi/8)*(4/3)))/2
                                correct=pixels["blueCount"]>0 and abs(pixels["blueX"]-expected_x)<0.015
                            elif name.startswith("instanced_"):
                                correct = pixels["instancing"] == instancing_enabled
                                correct = correct and pixels["redCount"] > 0 and pixels["blueCount"] > 0
                                correct = correct and pixels["redX"] < .45 and pixels["blueX"] > .55
                            elif name == "layered_lights":
                                red, blue = pixels["top"], pixels["bottom"]
                                correct = red[0] > red[2]+80 and blue[2] > blue[0]+80
                            elif name in ("stacked", "layered_views"):
                                red, blue = pixels["top"], pixels["bottom"]
                                correct = red[0] > 200 and max(red[1:3]) < 20
                                correct = correct and blue[2] > 200 and max(blue[:2]) < 20
                            elif name == "empty_instances":
                                correct = max(pixels["center"][:3]) < 20 and pixels["visible"] == 0
                            elif name == "orbit_zoom_limits":
                                # No explicit camera: the runtime derives zoom limits and clip planes
                                # from the fitted distance (2200 units here), never from fixed units.
                                blue = pixels["center"]
                                if not (blue[2] > 200 and max(blue[:2]) < 20):
                                    raise AssertionError(f"{name} at {width}x{height}: fitted view is clipped {pixels}")
                                zoom = page.evaluate("""() => {
                                    const d=window.__diff3dDebug, canvas=document.querySelector('canvas');
                                    const wheel=(dy,n)=>{ for(let i=0;i<n;i++) canvas.dispatchEvent(new WheelEvent('wheel',{deltaY:dy,bubbles:true,cancelable:true})); };
                                    const base=d.orbitDistance(), limits=d.orbitDistanceLimits(), fitted=d.clipPlanes();
                                    wheel(-1,60); const zoomedIn=d.orbitDistance(), zoomedClip=d.clipPlanes();
                                    wheel(1,460); const farOut=d.orbitDistance(), farClip=d.clipPlanes();
                                    wheel(-1,900); const nearIn=d.orbitDistance();
                                    canvas.dispatchEvent(new WheelEvent('wheel',{deltaY:0,bubbles:true,cancelable:true}));
                                    const afterZero=d.orbitDistance();
                                    let steps=0; while(d.orbitDistance()<base/1.0001&&steps++<2000) wheel(1,1);
                                    return {base,limits,fitted,zoomedIn,zoomedClip,farOut,farClip,nearIn,afterZero,restored:d.orbitDistance()};
                                }""")
                                base = zoom["base"]
                                def close(actual, expected, rel=1e-9):
                                    return abs(actual - expected) <= rel * abs(expected)
                                checks = (
                                    close(base, 2200.0),
                                    close(zoom["limits"]["min"], 1e-3 * base) and close(zoom["limits"]["max"], 1e3 * base),
                                    close(zoom["fitted"]["near"], 1e-2 * base) and close(zoom["fitted"]["far"], base + 64 * base),
                                    close(zoom["zoomedIn"], base * 0.92 ** 60, 1e-6),
                                    close(zoom["zoomedClip"]["near"], 1e-2 * zoom["zoomedIn"]) and close(zoom["zoomedClip"]["far"], zoom["zoomedIn"] + 64 * base),
                                    close(zoom["farOut"], 1e3 * base),
                                    close(zoom["farClip"]["near"], 10 * base) and close(zoom["farClip"]["far"], 1e3 * base + 64 * base),
                                    close(zoom["nearIn"], 1e-3 * base),
                                    zoom["afterZero"] == zoom["nearIn"],
                                    base / 1.0001 <= zoom["restored"] < base * 1.08,
                                )
                                if not all(checks):
                                    raise AssertionError(f"{name} at {width}x{height}: orbit limits {zoom} checks {checks}")
                                page.wait_for_timeout(500)
                                restored = page.evaluate("""() => {
                                    const c=document.querySelector('canvas'),gl=c.getContext('webgl'),pixel=new Uint8Array(4);
                                    gl.readPixels(Math.floor(c.width/2),Math.floor(c.height/2),1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixel);
                                    return {pixel:Array.from(pixel).slice(0,3),error:gl.getError()};
                                }""")
                                correct = restored["error"] == 0 and restored["pixel"][2] > 200 and max(restored["pixel"][:2]) < 20
                                if not correct:
                                    raise AssertionError(f"{name} at {width}x{height}: view restored after zooming is clipped {restored}")
                            else:
                                blue = pixels["center"]
                                correct = blue[2] > 200 and max(blue[:2]) < 20
                                if name == "empty_instance_parent":
                                    correct = correct and pixels["visible"] == 1
                            if not correct:
                                raise AssertionError(f"{name} at {width}x{height}: unexpected pixels {pixels}")
                            if errors:
                                raise AssertionError(f"{name}: browser errors {errors}")
                    finally:
                        page.close()
                    print(f"BROWSER_RENDERING_OK {name} instancing={instancing_enabled}", flush=True)
            finally:
                browser.close()


if __name__ == "__main__":
    main()
