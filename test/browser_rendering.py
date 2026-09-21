"""Verify exported rendering through browser pixels and draw counts."""

import argparse
import math
from pathlib import Path
import subprocess
import sys
import tempfile

from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "examples"))
from browser_support import BROWSERS, launch_browser, report_browser_environment


def verify_program_location_cache(page) -> None:
    result = page.evaluate("""async () => {
        const originalUniform=gl.getUniformLocation, originalAttribute=gl.getAttribLocation;
        const previousProgram=gl.getParameter(gl.CURRENT_PROGRAM), programs=[];
        let uniforms=0, attributes=0;
        gl.getUniformLocation=function(...args){ uniforms++; return originalUniform.apply(this,args); };
        gl.getAttribLocation=function(...args){ attributes++; return originalAttribute.apply(this,args); };
        let programChecks;
        try {
            const vs='attribute vec3 aPosition; void main(){ gl_Position=vec4(aPosition,1.0); }';
            const fs='precision mediump float; uniform float uValue; void main(){ gl_FragColor=vec4(uValue,0.0,0.0,1.0); }';
            for(let i=0;i<2;i++) programs.push(program(vs,fs));
            const values=[];
            for(const [index,p] of programs.entries()){
                const location=uniformLocation(p,'uValue'), attribute=attributeLocation(p,'aPosition');
                if(location===null||attribute<0) throw new Error('Active shader location missing');
                for(let i=0;i<3;i++){
                    if(uniformLocation(p,'uValue')!==location||attributeLocation(p,'aPosition')!==attribute)
                        throw new Error('Shader location changed on cache lookup');
                    if(uniformLocation(p,'inactive')!==null||attributeLocation(p,'inactive')!==-1)
                        throw new Error('Inactive shader location was not preserved');
                }
                gl.useProgram(p); gl.uniform1f(location,index===0?.25:.75);
                values.push(gl.getUniform(p,location));
            }
            programChecks={uniforms,attributes,values,error:gl.getError()};
        } finally {
            gl.getUniformLocation=originalUniform; gl.getAttribLocation=originalAttribute;
            gl.useProgram(previousProgram);
            for(const p of programs){
                for(const shader of gl.getAttachedShaders(p)) gl.deleteShader(shader);
                gl.deleteProgram(p);
            }
        }
        const frames=async () => {
            if(window.__diff3dTestRenderFrame){
                for(let i=0;i<3;i++) window.__diff3dTestRenderFrame();
            } else {
                await new Promise(resolve => {
                    let count=0;
                    function next(){ if(++count===3) resolve(); else requestAnimationFrame(next); }
                    requestAnimationFrame(next);
                });
            }
        };
        await frames();
        uniforms=0; attributes=0;
        let draws=0;
        const restorations=[];
        function countDraw(owner,name){
            const original=owner[name]; if(typeof original!=='function') return;
            owner[name]=function(...args){ draws++; return original.apply(this,args); };
            restorations.push(()=>{owner[name]=original;});
        }
        countDraw(gl,'drawArrays'); countDraw(gl,'drawElements');
        const extension=gl.getExtension('ANGLE_instanced_arrays');
        if(extension){ countDraw(extension,'drawArraysInstancedANGLE'); countDraw(extension,'drawElementsInstancedANGLE'); }
        gl.getUniformLocation=function(...args){ uniforms++; return originalUniform.apply(this,args); };
        gl.getAttribLocation=function(...args){ attributes++; return originalAttribute.apply(this,args); };
        try {
            await frames();
            return {programChecks,uniforms,attributes,draws,
                    expectedDraws:window.__diff3dDebug.activeDrawItemCount()>0,error:gl.getError()};
        } finally {
            gl.getUniformLocation=originalUniform; gl.getAttribLocation=originalAttribute;
            for(const restore of restorations) restore();
        }
    }""")
    if result["programChecks"] != {"uniforms": 4, "attributes": 4, "values": [0.25, 0.75], "error": 0}:
        raise AssertionError(f"Shader locations must belong to their linked program: {result}")
    if result["uniforms"] or result["attributes"] or result["error"] or (result["expectedDraws"] and not result["draws"]):
        raise AssertionError(f"Warmed rendering must reuse shader locations: {result}")
    print("BROWSER_LOCATION_CACHE_OK", result, flush=True)


def verify_packed_texture_storage(page) -> None:
    result = page.evaluate("""() => {
        const previousFramebuffer=gl.getParameter(gl.FRAMEBUFFER_BINDING);
        const previousTexture=gl.getParameter(gl.TEXTURE_BINDING_2D);
        const textures=new Set(), framebuffer=gl.createFramebuffer();
        const read=texture=>{
            gl.bindFramebuffer(gl.FRAMEBUFFER,framebuffer);
            gl.framebufferTexture2D(gl.FRAMEBUFFER,gl.COLOR_ATTACHMENT0,gl.TEXTURE_2D,texture,0);
            if(gl.checkFramebufferStatus(gl.FRAMEBUFFER)!==gl.FRAMEBUFFER_COMPLETE)
                throw new Error('Packed texture test framebuffer is incomplete');
            const pixels=new Uint8Array(4);
            gl.readPixels(0,0,1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixels);
            return Array.from(pixels);
        };
        try {
            const source={width:1,height:1,data:[20,40,60,80],
                          filter:'nearest',wrapS:'clamp',wrapT:'clamp'};
            const original=makeTexture(source); textures.add(original);
            const packed=packedTexture([source,source,null,source],[2,1,0,3]);
            const first=makeTexture(packed); textures.add(first);
            const second=makeTexture(packedTexture([source,source,source,source],[1,3,0,2]));
            textures.add(second);
            return {original:read(original),first:read(first),second:read(second),
                    reused:makeTexture(packed)===first,error:gl.getError()};
        } finally {
            gl.bindFramebuffer(gl.FRAMEBUFFER,previousFramebuffer);
            gl.deleteFramebuffer(framebuffer);
            for(const texture of textures) gl.deleteTexture(texture);
            gl.bindTexture(gl.TEXTURE_2D,previousTexture);
        }
    }""")
    if result != {"original": [20, 40, 60, 80], "first": [60, 40, 255, 80],
                  "second": [40, 80, 20, 60], "reused": True, "error": 0}:
        raise AssertionError(f"Packed texture storage: {result}")


def verify_shared_texture_refresh(page) -> None:
    results = page.evaluate("""() => {
        if(!physicalTexturesEnabled) throw new Error('Physical texture path is unavailable');
        const previousFramebuffer=gl.getParameter(gl.FRAMEBUFFER_BINDING);
        const previousTexture=gl.getParameter(gl.TEXTURE_BINDING_2D);
        const textures=new Set(), framebuffer=gl.createFramebuffer();
        const originalUpload=gl.texImage2D;
        let uploads=0;
        gl.texImage2D=function(...args){ uploads++; return originalUpload.apply(this,args); };
        const make=descriptor=>{ const texture=makeTexture(descriptor); textures.add(texture); return texture; };
        const read=texture=>{
            gl.bindFramebuffer(gl.FRAMEBUFFER,framebuffer);
            gl.framebufferTexture2D(gl.FRAMEBUFFER,gl.COLOR_ATTACHMENT0,gl.TEXTURE_2D,texture,0);
            if(gl.checkFramebufferStatus(gl.FRAMEBUFFER)!==gl.FRAMEBUFFER_COMPLETE)
                throw new Error('Shared texture test framebuffer is incomplete');
            const pixels=new Uint8Array(4);
            gl.readPixels(0,0,1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixels);
            return Array.from(pixels);
        };
        try {
            const results=[];
            for(const ordinary of [true,false]) for(const thickness of [true,false]){
                const source={width:1,height:1,data:[10,20,30,40],
                              filter:'nearest',wrapS:'clamp',wrapT:'clamp'};
                const objects=[0,1].map(()=>({clearcoatTexture:source,
                    iridescenceTexture:source,iridescenceThicknessTexture:source,
                    specularIntensityTexture:source,
                    thicknessTexture:thickness?source:null,anisotropyTexture:thickness?null:source,
                    physicalScalarTex:make(packedTexture([source,null,null,null],[0,1,0,3])),
                    physicalScalar2Tex:make(packedTexture([source,source,source,source],[0,1,3,thickness?1:2]))}));
                const original=ordinary?make(source):null;
                if(ordinary) for(const object of objects) object.texture=source;
                const handles=objects.map(o=>[o.physicalScalarTex,o.physicalScalar2Tex]);
                const rounds=[];
                for(const [round,red] of [70,110].entries()){
                    source.data=[red,80,90,100]; source.needsUpdate=true;
                    const before=uploads, order=round===0?objects:[objects[1],objects[0]];
                    // A later object must observe an update already consumed by an earlier one.
                    for(const object of order) refreshObjectTextures(object);
                    const changedUploads=uploads-before;
                    const packed=objects.map(o=>[read(o.physicalScalarTex),read(o.physicalScalar2Tex)]);
                    for(let frame=0;frame<3;frame++) for(const object of objects) refreshObjectTextures(object);
                    rounds.push({packed,original:ordinary?read(original):null,
                                 dirty:source.needsUpdate,changedUploads,idleUploads:uploads-before-changedUploads});
                }
                results.push({ordinary,thickness,rounds,
                    reused:objects.every((o,i)=>o.physicalScalarTex===handles[i][0]&&o.physicalScalar2Tex===handles[i][1]),
                    error:gl.getError()});
                for(const object of objects){ textures.add(object.physicalScalarTex); textures.add(object.physicalScalar2Tex); }
            }
            return results;
        } finally {
            gl.texImage2D=originalUpload;
            gl.bindFramebuffer(gl.FRAMEBUFFER,previousFramebuffer);
            gl.deleteFramebuffer(framebuffer);
            for(const texture of textures) gl.deleteTexture(texture);
            gl.bindTexture(gl.TEXTURE_2D,previousTexture);
        }
    }""")
    for result in results:
        expected_rounds = []
        for red in (70, 110):
            packed = [[red, 255, 255, 255], [red, 80, 100, 80 if result["thickness"] else 90]]
            expected_rounds.append({"packed": [packed, packed],
                                    "original": [red, 80, 90, 100] if result["ordinary"] else None,
                                    "dirty": False, "changedUploads": 5 if result["ordinary"] else 4,
                                    "idleUploads": 0})
        if result["rounds"] != expected_rounds or not result["reused"] or result["error"] != 0:
            raise AssertionError(f"Shared packed texture refresh: {result}")


def verify_fragment_precision(page) -> None:
    result = page.evaluate("""() => {
        const previous={framebuffer:gl.getParameter(gl.FRAMEBUFFER_BINDING),
            program:gl.getParameter(gl.CURRENT_PROGRAM),viewport:gl.getParameter(gl.VIEWPORT),
            texture:gl.getParameter(gl.TEXTURE_BINDING_2D),mask:gl.getParameter(gl.COLOR_WRITEMASK)};
        const capabilities=[gl.DEPTH_TEST,gl.BLEND,gl.CULL_FACE,gl.SCISSOR_TEST];
        const enabled=capabilities.map(capability=>gl.isEnabled(capability));
        const framebuffer=gl.createFramebuffer(),output=gl.createTexture();
        let probe=null;
        try {
            const formats={};
            for(const kind of ['MEDIUM_FLOAT','HIGH_FLOAT']){
                const format=gl.getShaderPrecisionFormat(gl.FRAGMENT_SHADER,gl[kind]);
                formats[kind]=format?format.precision:0;
            }
            const declarations={};
            for(const [name,source] of Object.entries({DFSH,PDFSH,FSH,FSH_EMISSIVE,CFSH,PFSH,SFSH}))
                declarations[name]=source.match(/precision\\s+(?:lowp|mediump|highp)\\s+float\\s*;/g)||[];
            gl.bindTexture(gl.TEXTURE_2D,output);
            gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,1,1,0,gl.RGBA,gl.UNSIGNED_BYTE,null);
            gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.NEAREST);
            gl.bindFramebuffer(gl.FRAMEBUFFER,framebuffer);
            gl.framebufferTexture2D(gl.FRAMEBUFFER,gl.COLOR_ATTACHMENT0,gl.TEXTURE_2D,output,0);
            if(gl.checkFramebufferStatus(gl.FRAMEBUFFER)!==gl.FRAMEBUFFER_COMPLETE)
                throw new Error('Fragment precision test framebuffer is incomplete');
            for(const capability of capabilities) gl.disable(capability);
            gl.colorMask(true,true,true,true); gl.viewport(0,0,1,1);
            // A uniform 2^-11 added to 1.0 disappears in a 10-bit mantissa and
            // survives a wider one. The uniform prevents constant folding.
            probe=program('void main(){ gl_Position=vec4(0.0,0.0,0.0,1.0); gl_PointSize=1.0; }',
                FRAGMENT_PRECISION+'uniform float uDelta; void main(){ float v=1.0+uDelta;'
                +' gl_FragColor=vec4((v-1.0)*2048.0,0.0,0.0,1.0); }');
            gl.useProgram(probe);
            gl.uniform1f(uniformLocation(probe,'uDelta'),1.0/2048.0);
            gl.drawArrays(gl.POINTS,0,1);
            const pixel=new Uint8Array(4);
            gl.readPixels(0,0,1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixel);
            return {selected:FRAGMENT_PRECISION,formats,declarations,
                    mantissa:Array.from(pixel),error:gl.getError()};
        } finally {
            gl.bindFramebuffer(gl.FRAMEBUFFER,previous.framebuffer); gl.deleteFramebuffer(framebuffer);
            gl.useProgram(previous.program);
            if(probe){
                for(const shader of gl.getAttachedShaders(probe)) gl.deleteShader(shader);
                gl.deleteProgram(probe);
            }
            gl.deleteTexture(output); gl.bindTexture(gl.TEXTURE_2D,previous.texture);
            gl.viewport(...previous.viewport); gl.colorMask(...previous.mask);
            capabilities.forEach((capability,index)=>enabled[index]?gl.enable(capability):gl.disable(capability));
        }
    }""")
    high, medium = result["formats"]["HIGH_FLOAT"], result["formats"]["MEDIUM_FLOAT"]
    expected = "precision highp float; " if high > 0 else "precision mediump float; "
    if result["selected"] != expected or result["error"]:
        raise AssertionError(f"Exported shaders must select the widest fragment precision: {result}")
    for name, declarations in result["declarations"].items():
        if declarations != [expected.strip()]:
            raise AssertionError(f"{name} must declare exactly the selected precision: {result}")
    # A declared precision is a lower bound, so a 10-bit declaration may still be
    # evaluated more precisely; a wider declaration may not be evaluated coarsely.
    bits = high if high > 0 else medium
    red, rest = result["mantissa"][0], result["mantissa"][1:]
    if rest != [0, 0, 255] or not (red == 255 if bits >= 11 else red == 255 or red <= 2):
        raise AssertionError(f"Declared fragment precision is not in effect: {result}")
    print("BROWSER_FRAGMENT_PRECISION_OK", result["selected"].strip(), result["formats"], flush=True)


def verify_cube_texture_storage(page) -> None:
    results = page.evaluate("""() => {
        const previous={framebuffer:gl.getParameter(gl.FRAMEBUFFER_BINDING),
            program:gl.getParameter(gl.CURRENT_PROGRAM),viewport:gl.getParameter(gl.VIEWPORT),
            active:gl.getParameter(gl.ACTIVE_TEXTURE),flip:gl.getParameter(gl.UNPACK_FLIP_Y_WEBGL),
            mask:gl.getParameter(gl.COLOR_WRITEMASK)};
        gl.activeTexture(gl.TEXTURE0);
        previous.cube=gl.getParameter(gl.TEXTURE_BINDING_CUBE_MAP);
        previous.texture=gl.getParameter(gl.TEXTURE_BINDING_2D);
        const capabilities=[gl.DEPTH_TEST,gl.BLEND,gl.CULL_FACE,gl.SCISSOR_TEST];
        const enabled=capabilities.map(capability=>gl.isEnabled(capability));
        const framebuffer=gl.createFramebuffer(),output=gl.createTexture(),textures=[];
        const upload=gl.texImage2D;
        let samplingProgram=null;
        try {
            samplingProgram=program('void main(){ gl_Position=vec4(0.0,0.0,0.0,1.0); gl_PointSize=4.0; }',
                'precision mediump float; uniform samplerCube uCube; uniform float uBias; void main(){ gl_FragColor=textureCube(uCube,vec3(1.0,gl_PointCoord*2.0-1.0),uBias); }');
            gl.bindTexture(gl.TEXTURE_2D,output);
            gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,4,4,0,gl.RGBA,gl.UNSIGNED_BYTE,null);
            gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.NEAREST);
            gl.bindFramebuffer(gl.FRAMEBUFFER,framebuffer);
            gl.framebufferTexture2D(gl.FRAMEBUFFER,gl.COLOR_ATTACHMENT0,gl.TEXTURE_2D,output,0);
            if(gl.checkFramebufferStatus(gl.FRAMEBUFFER)!==gl.FRAMEBUFFER_COMPLETE)
                throw new Error('Cube texture test framebuffer is incomplete');
            for(const capability of capabilities) gl.disable(capability);
            gl.colorMask(true,true,true,true); gl.viewport(0,0,4,4);
            gl.useProgram(samplingProgram); gl.uniform1i(uniformLocation(samplingProgram,'uCube'),0);
            const results=[];
            for(const size of [1,3,4,8,12]) for(const chain of ['none','complete','partial']){
                const face=(width,color)=>({width,height:width,
                    data:Array.from({length:width*width},()=>color).flat(),
                    minFilter:'linear_mipmap_linear',magFilter:'nearest'});
                const env={faces:Array.from({length:6},()=>{
                    const result=face(size,[31,63,127,255]); result.mipmaps=[];
                    if(chain!=='none') for(let width=size>>1;width;width>>=1)
                        result.mipmaps.push(face(width,[93,127,191,255]));
                    if(chain==='partial') result.mipmaps.pop();
                    return result;
                })};
                const levels=[];
                gl.texImage2D=function(...args){ levels.push(args[1]); return upload.apply(this,args); };
                const result=makeCubeTexture(env); textures.push(result.texture);
                gl.texImage2D=upload;
                gl.uniform1f(uniformLocation(samplingProgram,'uBias'),16);
                gl.drawArrays(gl.POINTS,0,1);
                const pixels=new Uint8Array(4*4*4);
                gl.readPixels(0,0,4,4,gl.RGBA,gl.UNSIGNED_BYTE,pixels);
                // On a 4-pixel point, bias one selects LOD log2(size)-1:
                // the last supplied level in the partial 4x4 and 8x8 chains.
                gl.uniform1f(uniformLocation(samplingProgram,'uBias'),1);
                gl.drawArrays(gl.POINTS,0,1);
                const supplied=new Uint8Array(4*4*4);
                gl.readPixels(0,0,4,4,gl.RGBA,gl.UNSIGNED_BYTE,supplied);
                results.push({size,chain,maxLod:result.maxLod,levels,pixels:Array.from(pixels),
                              supplied:Array.from(supplied),
                              reused:makeCubeTexture(env)===result,error:gl.getError()});
            }
            return results;
        } finally {
            gl.texImage2D=upload;
            gl.bindFramebuffer(gl.FRAMEBUFFER,previous.framebuffer); gl.deleteFramebuffer(framebuffer);
            gl.useProgram(previous.program);
            if(samplingProgram){
                for(const shader of gl.getAttachedShaders(samplingProgram)) gl.deleteShader(shader);
                gl.deleteProgram(samplingProgram);
            }
            for(const texture of textures) gl.deleteTexture(texture); gl.deleteTexture(output);
            gl.bindTexture(gl.TEXTURE_2D,previous.texture); gl.bindTexture(gl.TEXTURE_CUBE_MAP,previous.cube);
            gl.activeTexture(previous.active); gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL,previous.flip);
            gl.viewport(...previous.viewport); gl.colorMask(...previous.mask);
            capabilities.forEach((capability,index)=>enabled[index]?gl.enable(capability):gl.disable(capability));
        }
    }""")
    for result in results:
        full_lod = {1: 0, 4: 2, 8: 3}.get(result["size"], 0)
        authored_lod = (full_lod if result["chain"] == "complete" else
                        max(0, full_lod-1) if result["chain"] == "partial" else 0)
        levels = [level for level in range(authored_lod+1) for _ in range(6)]
        base, authored = [31, 63, 127, 255], [93, 127, 191, 255]
        pixel = authored if authored_lod and authored_lod == full_lod else base
        supplied = authored if authored_lod else base
        if (result["maxLod"] != (authored_lod or full_lod) or result["levels"] != levels
                or result["pixels"] != pixel*16 or result["supplied"] != supplied*16
                or not result["reused"] or result["error"]):
            raise AssertionError(f"Cube texture upload/sampling: {result}")


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
    parser.add_argument("--browser", choices=BROWSERS, default="chromium")
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
            browser = launch_browser(playwright, args.browser)
            try:
                checked_texture_storage = False
                checked_location_cache = False
                reported_environment = False
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
                        if not reported_environment:
                            report_browser_environment(browser, page)
                            reported_environment = True
                        if not checked_texture_storage:
                            verify_fragment_precision(page)
                            verify_packed_texture_storage(page)
                            verify_shared_texture_refresh(page)
                            verify_cube_texture_storage(page)
                            checked_texture_storage = True
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
                        if not checked_location_cache:
                            verify_program_location_cache(page)
                            checked_location_cache = True
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
                                # Each viewport pass starts from the fitted orbit (the previous pass
                                # leaves the orbit within one wheel notch of it).
                                page.evaluate("() => { setCase(active.id); }")
                                page.wait_for_timeout(300)
                                fitted = page.evaluate("""() => {
                                    const c=document.querySelector('canvas'),gl=c.getContext('webgl'),pixel=new Uint8Array(4);
                                    gl.readPixels(Math.floor(c.width/2),Math.floor(c.height/2),1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixel);
                                    return {pixel:Array.from(pixel).slice(0,3),error:gl.getError(),dist:window.__diff3dDebug.orbitDistance()};
                                }""")
                                blue = fitted["pixel"]
                                if not (fitted["error"] == 0 and blue[2] > 200 and max(blue[:2]) < 20 and abs(fitted["dist"] - 2200.0) <= 1e-9 * 2200.0):
                                    raise AssertionError(f"{name} at {width}x{height}: fitted view is clipped or not fitted {fitted}")
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
