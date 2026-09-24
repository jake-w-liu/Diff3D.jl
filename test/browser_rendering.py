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
            const fs='precision mediump float; uniform float uValue; uniform float uArr[3]; void main(){ gl_FragColor=vec4(uValue+uArr[0]+uArr[1]+uArr[2],0.0,0.0,1.0); }';
            for(let i=0;i<2;i++) programs.push(program(vs,fs));
            // Linking enumerates each active name once; after that no lookup, active or not, queries the driver.
            const linkUniforms=uniforms, linkAttributes=attributes;
            let activeUniforms=0, activeAttributes=0;
            for(const p of programs){ activeUniforms+=gl.getProgramParameter(p,gl.ACTIVE_UNIFORMS); activeAttributes+=gl.getProgramParameter(p,gl.ACTIVE_ATTRIBUTES); }
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
                if(uniformLocation(p,'uArr')!==uniformLocation(p,'uArr[0]')||uniformLocation(p,'uArr[0]')===null)
                    throw new Error('Array base name must alias its first element');
                gl.useProgram(p); gl.uniform1f(location,index===0?.25:.75);
                values.push(gl.getUniform(p,location));
            }
            const lookupUniforms=uniforms-linkUniforms, lookupAttributes=attributes-linkAttributes;
            // A later array element is resolved once per program and then reused; out of range is inactive.
            const elements=programs.map(p=>{ const e=uniformLocation(p,'uArr[2]'); if(e===null||uniformLocation(p,'uArr[2]')!==e||uniformLocation(p,'uArr[3]')!==null) throw new Error('Array element lookup is wrong'); gl.useProgram(p); gl.uniform1f(e,.5); return gl.getUniform(p,e); });
            // A stage that does not compile is reported by stage and source line, not as a bare log.
            let compileReport='';
            try{ program(vs,'precision mediump float;\\nvoid main(){\\n  gl_FragColor=vec4(missingName);\\n}\\n'); }catch(err){ compileReport=String(err&&err.message); }
            programChecks={linkUniforms,linkAttributes,activeUniforms,activeAttributes,lookupUniforms,lookupAttributes,
                           elementQueries:uniforms-linkUniforms-lookupUniforms,elements,values,compileReport,error:gl.getError()};
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
            // The viewer drains the GL error queue itself, so an error raised by these frames is
            // read from its counter; drainGlErrors() also collects any it has not drained yet.
            const glErrorsBefore=window.__diff3dDebug.drainGlErrors();
            await frames();
            return {programChecks,uniforms,attributes,draws,
                    expectedDraws:window.__diff3dDebug.activeDrawItemCount()>0,
                    error:window.__diff3dDebug.drainGlErrors()-glErrorsBefore};
        } finally {
            gl.getUniformLocation=originalUniform; gl.getAttribLocation=originalAttribute;
            for(const restore of restorations) restore();
        }
    }""")
    checks = result["programChecks"]
    if (checks["linkUniforms"] != checks["activeUniforms"] or checks["linkAttributes"] != checks["activeAttributes"]
            or checks["activeUniforms"] != 4 or checks["activeAttributes"] != 2
            or checks["lookupUniforms"] or checks["lookupAttributes"] or checks["elementQueries"] != 2
            or checks["elements"] != [0.5, 0.5] or checks["values"] != [0.25, 0.75] or checks["error"]
            or "fragment shader did not compile" not in checks["compileReport"] or "> 3:" not in checks["compileReport"]):
        raise AssertionError(f"Shader locations must belong to their linked program: {result}")
    if result["uniforms"] or result["attributes"] or result["error"] or (result["expectedDraws"] and not result["draws"]):
        raise AssertionError(f"Warmed rendering must reuse shader locations: {result}")
    print("BROWSER_LOCATION_CACHE_OK", result, flush=True)


def verify_position_attribute_zero(page) -> None:
    """Every viewer program binds aPosition to attribute 0, where three.js binds position.

    three.js binds it there to avoid the penalty of a draw whose attribute 0 is not an enabled
    array (WebGLProgram.js:847-858). Without the bind the linker picks slot 0 itself (in Firefox,
    an instance-matrix column for most viewer programs), so aPosition, which every draw enables,
    must hold it.
    """
    result = page.evaluate("""() => {
        const programs={meshProgram,meshBoneProgram,colorProgram,colorBoneProgram,pointProgram,spriteProgram,
                        depthProgram,depthBoneProgram,pointDepthProgram,pointDepthBoneProgram}, out={};
        for(const [name,p] of Object.entries(programs))
            out[name]={table:attributeLocation(p,'aPosition'),live:gl.getAttribLocation(p,'aPosition')};
        return out;
    }""")
    wrong = {name: value for name, value in result.items() if value != {"table": 0, "live": 0}}
    if wrong:
        raise AssertionError(f"aPosition must be attribute 0 in every program: {wrong}")
    print("BROWSER_POSITION_ATTRIBUTE_ZERO_OK", flush=True)


def verify_uniform_writes(page) -> None:
    """Every uniform write is typed by the program's own active uniforms.

    An optimised-out uniform must stay a silent no-op, as in three.js. Everything WebGL would
    drop with only a GL error (a type the call cannot write, a partial or oversized element), and
    every program or write missing a uniform a draw cannot do without, must throw before reaching
    GL, so it can never leave a zero matrix or a zero opacity behind. Longer data for an array
    stays legal: GL ignores the excess and an implementation may report a shorter active array.
    """
    result = page.evaluate("""() => {
        const previous=gl.getParameter(gl.CURRENT_PROGRAM), outcome={};
        const vs='attribute vec3 aPosition; uniform mat4 uM; uniform vec4 uPlanes[4]; uniform float uUnused;'
            +' void main(){ gl_Position=uM*vec4(aPosition,1.0)+uPlanes[0]+uPlanes[1]; }';
        const fs='precision mediump float; uniform vec3 uTint; uniform int uMode;'
            +' void main(){ gl_FragColor=vec4(uMode==1?uTint:vec3(0.0),1.0); }';
        const p=program(vs,fs);
        const attempt=(key,write)=>{ try{ write(); outcome[key]='ok'; }catch(err){ outcome[key]=String(err&&err.message||err); } };
        try {
            gl.useProgram(p);
            attempt('requiredPresent',()=>requireUniforms({probe:p},['uM','uTint','uPlanes[0]']));
            attempt('requiredMissing',()=>requireUniforms({probe:p},['uM','uUnused']));
            attempt('inactiveOptional',()=>uniform1f(p,'uUnused',1));
            attempt('inactiveRequired',()=>uniform1f(p,'uUnused',1,REQUIRED));
            attempt('matrix',()=>uniformMat4(p,'uM',[2,0,0,0, 0,2,0,0, 0,0,2,0, 0,0,0,1],REQUIRED));
            attempt('vector',()=>uniform3v(p,'uTint',[0.25,0.5,0.75],REQUIRED));
            attempt('integer',()=>uniform1i(p,'uMode',1));
            attempt('arrayExcess',()=>uniform4v(p,'uPlanes[0]',new Array(24).fill(0.5)));
            const before=gl.getError();
            attempt('floatForInt',()=>uniform1f(p,'uMode',2));
            attempt('vectorForMatrix',()=>uniform3v(p,'uM',[1,2,3]));
            attempt('shortVector',()=>uniform3v(p,'uTint',[1,2]));
            attempt('severalForNonArray',()=>uniform3v(p,'uTint',[1,2,3,4,5,6]));
            attempt('partialElement',()=>uniform4v(p,'uPlanes[0]',[1,2,3,4,5,6]));
            attempt('noValue',()=>uniform3v(p,'uTint',undefined));
            attempt('scalarForVector',()=>uniform3v(p,'uTint',1));
            const value=name=>{ const v=gl.getUniform(p,uniformLocation(p,name)); return typeof v==='number'?v:Array.from(v); };
            outcome.values={uM:value('uM'),uTint:value('uTint'),uMode:value('uMode'),uPlanes:value('uPlanes[0]')};
            outcome.glErrorBefore=before; outcome.glErrorAfter=gl.getError();
        } finally {
            gl.useProgram(previous);
            for(const shader of gl.getAttachedShaders(p)) gl.deleteShader(shader);
            gl.deleteProgram(p);
        }
        return outcome;
    }""")
    accepted = ("requiredPresent", "inactiveOptional", "matrix", "vector", "integer", "arrayExcess")
    rejected = {"requiredMissing": "uUnused", "inactiveRequired": "uUnused", "floatForInt": "uMode",
                "vectorForMatrix": "uM", "shortVector": "uTint", "severalForNonArray": "uTint",
                "partialElement": "uPlanes", "noValue": "uTint", "scalarForVector": "uTint"}
    problems = [key for key in accepted if result.get(key) != "ok"]
    problems += [key for key, name in rejected.items()
                 if result.get(key) == "ok" or name not in str(result.get(key))]
    expected_values = {"uM": [2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 1],
                       "uTint": [0.25, 0.5, 0.75], "uMode": 1, "uPlanes": [0.5, 0.5, 0.5, 0.5]}
    # Rejected writes must not reach GL: the accepted values survive them and GL records no
    # error, because nothing invalid was ever submitted.
    if problems or result.get("values") != expected_values or result.get("glErrorBefore") or result.get("glErrorAfter"):
        raise AssertionError(f"Uniform writes must be typed, and loud when GL would drop them: {problems} {result}")
    print("BROWSER_UNIFORM_WRITES_OK", flush=True)


def verify_vertex_attribute_state(page, name: str, instancing_enabled: bool) -> None:
    """Each draw sees exactly the vertex arrays its own program declares.

    WebGL 1 shares one attribute state between all programs. three.js re-declares a draw's
    arrays and disables every other one before each draw (WebGLBindingStates.js
    disableUnusedAttributes). An array another program left enabled with a buffer too short for
    this draw makes WebGL reject the draw with nothing but an error code, and a divisor left on a
    location this program reads per vertex feeds it one value per instance instead. Only objects
    with their own instance matrices may draw instanced, and attribute 0 must be an enabled
    array in every draw.
    """
    result = page.evaluate("""async () => {
        const ext=gl.getExtension('ANGLE_instanced_arrays'), problems=[], counts={plain:0,instanced:0}, restore=[];
        const errorsBefore=window.__diff3dDebug.drainGlErrors();
        const inspect=kind=>{
            const info=programInfo.get(gl.getParameter(gl.CURRENT_PROGRAM));
            if(!info){ problems.push(kind+': program not linked by program()'); return; }
            const used=new Set(Array.from(info.attributes.values(),a=>a.location));
            const perInstance=new Set(['aInstanceMatrix0','aInstanceMatrix1','aInstanceMatrix2','aInstanceMatrix3','aInstanceColor']
                .filter(n=>info.attributes.has(n)).map(n=>info.attributes.get(n).location));
            if(!gl.getVertexAttrib(0,gl.VERTEX_ATTRIB_ARRAY_ENABLED)) problems.push(kind+': attribute 0 is not an enabled array');
            for(let i=0;i<maxVertexAttribs;i++){
                const enabled=gl.getVertexAttrib(i,gl.VERTEX_ATTRIB_ARRAY_ENABLED);
                const divisor=ext?gl.getVertexAttrib(i,ext.VERTEX_ATTRIB_ARRAY_DIVISOR_ANGLE):0;
                if(enabled&&!used.has(i)) problems.push(kind+': array '+i+' is enabled but not declared by the program');
                if(divisor&&(kind==='plain'||!perInstance.has(i))) problems.push(kind+': divisor '+divisor+' on attribute '+i);
                if(enabled!==(enabledAttribs[i]===1)||divisor!==attribDivisors[i]) problems.push(kind+': tracker disagrees with GL at attribute '+i);
            }
        };
        const wrap=(owner,fn,kind)=>{ const original=owner[fn]; restore.push(()=>{ owner[fn]=original; });
            owner[fn]=function(...args){ counts[kind]++; inspect(kind); return original.apply(this,args); }; };
        wrap(gl,'drawElements','plain'); wrap(gl,'drawArrays','plain');
        if(ext){ wrap(ext,'drawElementsInstancedANGLE','instanced'); wrap(ext,'drawArraysInstancedANGLE','instanced'); }
        try{
            if(window.__diff3dTestRenderFrame){ for(let i=0;i<3;i++) window.__diff3dTestRenderFrame(); }
            else for(let i=0;i<3;i++) await new Promise(resolve=>requestAnimationFrame(resolve));
        } finally{ for(const undo of restore) undo(); }
        return {problems:problems.slice(0,12),problemCount:problems.length,counts,
                glErrors:window.__diff3dDebug.drainGlErrors()-errorsBefore};
    }""")
    expect_instanced = name.startswith("instanced_") and instancing_enabled
    if (result["problemCount"] or result["glErrors"] or not result["counts"]["plain"] + result["counts"]["instanced"]
            or (result["counts"]["instanced"] > 0) != expect_instanced):
        raise AssertionError(f"{name}: draws must see exactly their own vertex arrays: {result}")
    print("BROWSER_VERTEX_ATTRIBUTES_OK", name, result["counts"], flush=True)


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


# The orbit fixture reads the centre of the fitted view twice: once after the
# case is reset and once after the zoom sequence returns to it. Both waits must
# track presented frames rather than the clock, and both must report enough
# state to diagnose a failure without another CI round trip.
ORBIT_CENTRE_PROBE = """async () => {
    const c=document.querySelector('canvas'),gl=c.getContext('webgl'),d=window.__diff3dDebug;
    const block=9;
    const read=()=>{
        const p=new Uint8Array(4*block*block); gl.finish();
        gl.readPixels(Math.floor(c.width/2)-(block>>1),Math.floor(c.height/2)-(block>>1),
                      block,block,gl.RGBA,gl.UNSIGNED_BYTE,p);
        let blue=0, worstOther=0, sample=null;
        for(let i=0;i<block*block;i++){
            const r=p[4*i],g=p[4*i+1],b=p[4*i+2];
            if(i===(block*block>>1)) sample=[r,g,b];
            if(b>200&&Math.max(r,g)<20) blue++; else worstOther=Math.max(worstOther,b);
        }
        return {blue,worstOther,sample};
    };
    const framesAtStart=d.renderedFrames();
    let state=read(), frames=0;
    while(state.blue<block*block && frames<120){
        await new Promise(resolve => requestAnimationFrame(resolve));
        frames++; state=read();
    }
    // The viewer drains the GL error queue itself, at most once a second; drainGlErrors() collects
    // any error it has not drained yet, and lastGlError is the last one seen since the page loaded.
    d.drainGlErrors();
    const glError=d.lastGlError();
    let census=null, diagnostics=null, composited=null;
    if(state.blue<block*block){
        // Read the canvas a second time through the compositor rather than through
        // readPixels. If this sees the scene while readPixels does not, the frame was
        // drawn and only the readback is wrong, which is a harness fault rather than a
        // rendering one; if both agree the frame really produced nothing.
        try{
            const copy=document.createElement('canvas');
            copy.width=c.width; copy.height=c.height;
            const ctx=copy.getContext('2d');
            ctx.drawImage(c,0,0);
            const all=ctx.getImageData(0,0,c.width,c.height).data;
            let blue=0; const seen={};
            for(let i=0;i<all.length;i+=4){
                const key=all[i]+','+all[i+1]+','+all[i+2];
                seen[key]=(seen[key]||0)+1;
                if(all[i+2]>200&&Math.max(all[i],all[i+1])<20) blue++;
            }
            const mid=4*((c.height>>1)*c.width+(c.width>>1));
            composited={bluePixels:blue,centre:[all[mid],all[mid+1],all[mid+2]],
                        topColours:Object.entries(seen).sort((a,b)=>b[1]-a[1]).slice(0,3)};
        }catch(err){ composited={error:String(err)}; }
        // Census the blank frame before the diagnostics run: their control draws paint
        // over the canvas, so every read of the frame that failed must come first.
        const all=new Uint8Array(4*c.width*c.height); gl.finish();
        gl.readPixels(0,0,c.width,c.height,gl.RGBA,gl.UNSIGNED_BYTE,all);
        let n=0,minX=c.width,maxX=-1,minY=c.height,maxY=-1,sx=0,sy=0;
        const cols=16,rows=10,map=Array.from({length:rows},()=>new Array(cols).fill(0));
        const seen={};
        for(let y=0;y<c.height;y++) for(let x=0;x<c.width;x++){
            const i=4*(y*c.width+x), r=all[i],g=all[i+1],b=all[i+2];
            const key=r+','+g+','+b; seen[key]=(seen[key]||0)+1;
            if(b>200&&Math.max(r,g)<20){
                n++; sx+=x; sy+=y;
                if(x<minX)minX=x; if(x>maxX)maxX=x;
                if(y<minY)minY=y; if(y>maxY)maxY=y;
                map[Math.min(rows-1,Math.floor(y*rows/c.height))][Math.min(cols-1,Math.floor(x*cols/c.width))]++;
            }
        }
        census={bluePixels:n,fraction:+(n/(c.width*c.height)).toFixed(4),
                box:n?[minX,minY,maxX,maxY]:null,centroid:n?[Math.round(sx/n),Math.round(sy/n)]:null,
                topColours:Object.entries(seen).sort((a,b)=>b[1]-a[1]).slice(0,4),
                map:map.map(row=>row.map(v=>v?'#':'.').join(''))};
        diagnostics=d.frameDiagnostics();
    }
    return {pixel:state.sample,blue:state.blue,of:block*block,census,diagnostics,composited,
            worstOther:state.worstOther,frames,error:glError,
            dist:d.orbitDistance(),angles:d.orbitAngles(),limits:d.orbitDistanceLimits(),
            clip:d.clipPlanes(),targetOffset:d.targetOffset(),
            objects:d.activeObjectCount(),draws:d.activeDrawItemCount(),views:d.activeViewCount(),
            // objects/draws/views re-run the visibility filter at probe time; they are
            // not a record of any frame. The fields below are, and they separate the
            // three ways this canvas can end up showing only the background colour:
            //   renderedDelta==0 and lastRenderError set -> a frame threw
            //   renderedDelta>0 and stats "0 draw items" -> the frame drew nothing
            //   renderedDelta>0 and stats "1 draw items" -> it drew and rasterised nothing
            // Comparing the stats text across one frame cannot tell these apart: render()
            // writes a pure function of the draw count, so a healthy loop on this
            // single-object fixture rewrites the identical string every frame.
            stats:document.getElementById('stats').textContent,
            renderedFrames:d.renderedFrames(),
            renderedDelta:d.renderedFrames()-framesAtStart,
            renderStopped:d.renderStopped(), lastRenderError:d.lastRenderError(),
            contextLost:d.contextLost(),
            canvas:[c.width,c.height],dpr:window.devicePixelRatio,
            rect:[Math.round(c.getBoundingClientRect().width),
                  Math.round(c.getBoundingClientRect().height)]};
}"""


def verify_render_loop_recovery(browser, fixture_path: Path) -> None:
    """The exported viewer must survive a frame that throws, and must stop retrying a
    frame that always throws.

    render() clears the whole canvas to the background colour before it draws anything,
    and the context keeps its drawing buffer, so a frame that raises after that clear
    leaves the canvas showing nothing but the background. If the loop is not re-armed
    the viewer stays that way for good; if it is re-armed without a bound, a viewer that
    fails every frame rethrows and rewrites the DOM for as long as the page is open.
    Both halves are checked here against the real exported file.
    """
    page = browser.new_page(viewport={"width": 1024, "height": 800})
    errors = []
    page.on("pageerror", lambda error, target=errors: target.append(str(error)))
    try:
        # Wrap the draw entry points before the viewer runs, so the ANGLE extension
        # object it caches at start-up is wrapped too, and keep the fault disarmed
        # until a healthy frame has been observed.
        page.add_init_script("""(() => {
            window.__fault={mode:'off',fired:0};
            const trip=()=>{
                const f=window.__fault;
                if(f.mode==='always'||(f.mode==='once'&&f.fired===0)){
                    f.fired++; throw new Error('injected render fault');
                }
            };
            const hook=(owner,name)=>{
                const original=owner&&owner[name];
                if(typeof original!=='function') return;
                owner[name]=function(...args){ trip(); return original.apply(this,args); };
            };
            for(const name of ['drawElements','drawArrays'])
                hook(WebGLRenderingContext.prototype,name);
            const getExtension=WebGLRenderingContext.prototype.getExtension;
            WebGLRenderingContext.prototype.getExtension=function(name){
                const ext=getExtension.call(this,name);
                if(ext&&name==='ANGLE_instanced_arrays'){
                    hook(ext,'drawArraysInstancedANGLE');
                    hook(ext,'drawElementsInstancedANGLE');
                }
                return ext;
            };
        })();""")
        page.goto(fixture_path.as_uri(), timeout=120000)
        page.wait_for_function(
            "window.__diff3dDebug && window.__diff3dDebug.renderedFrames() > 2", timeout=120000)

        centre = """() => {
            const c=document.querySelector('canvas'), gl=c.getContext('webgl');
            const p=new Uint8Array(4*9*9); gl.finish();
            gl.readPixels(Math.floor(c.width/2)-4,Math.floor(c.height/2)-4,9,9,
                          gl.RGBA,gl.UNSIGNED_BYTE,p);
            return Array.from(p);
        }"""
        healthy = page.evaluate(centre)
        if max(healthy) == 0:
            raise AssertionError("Render loop recovery: fixture did not draw before the fault")

        # One transient fault: the loop must report it and carry on.
        page.evaluate("() => { window.__fault.mode='once'; }")
        page.wait_for_function("window.__fault.fired >= 1", timeout=120000)
        page.evaluate("() => { window.__fault.mode='off'; }")
        resumed = page.evaluate("""async () => {
            const d=window.__diff3dDebug, start=d.renderedFrames();
            for(let i=0;i<120 && d.renderedFrames()-start<3;i++)
                await new Promise(resolve => requestAnimationFrame(resolve));
            return {advanced:d.renderedFrames()-start, stopped:d.renderStopped(),
                    lastError:d.lastRenderError(), lost:d.contextLost()};
        }""")
        restored = page.evaluate(centre)
        if resumed["advanced"] < 3 or resumed["stopped"] or resumed["lost"]:
            raise AssertionError(
                f"Render loop did not survive one thrown frame: {resumed}, errors {errors}")
        if not errors or not resumed["lastError"]:
            raise AssertionError(
                f"The thrown frame was swallowed instead of reported: "
                f"{resumed}, errors {errors}")
        if restored != healthy:
            raise AssertionError("Render loop resumed but the view did not come back")

        # A permanent fault: the loop must give up rather than retry for ever.
        page.evaluate("() => { window.__fault.mode='always'; }")
        page.wait_for_function(
            "window.__diff3dDebug.renderStopped() === true", timeout=120000)
        settled = page.evaluate("() => ({fired:window.__fault.fired,"
                                " frames:window.__diff3dDebug.renderedFrames()})")
        page.wait_for_timeout(500)
        after = page.evaluate("() => ({fired:window.__fault.fired,"
                              " frames:window.__diff3dDebug.renderedFrames()})")
        if after != settled:
            raise AssertionError(
                f"Render loop kept retrying a permanently failing frame: {settled} -> {after}")
    finally:
        page.close()
    print("BROWSER_RENDER_RECOVERY_OK", flush=True)


def verify_error_surface(browser, fixture_path: Path) -> None:
    """A GL error and a reported start-up error must stay visible after later frames, and the
    viewer must find GL errors without waiting on the GPU after every frame.

    render() rewrites #stats on every frame, so a report written only there was erased within
    one frame, and gl.getError() was read only inside the debug hook. An INVALID_ENUM raised
    between frames must reach the persistent banner, the console and the debug counters through
    the viewer's own drain, and a start-up error must still be shown after further frames, also
    when chrome=false hides the header. getError returns only once the GPU process has caught up,
    so over 30 frames the viewer may call it at most once per elapsed second, plus once.
    """
    page = browser.new_page(viewport={"width": 1024, "height": 800})
    console_errors = []
    page.on("console", lambda message, target=console_errors:
            target.append(message.text) if message.type == "error" else None)
    try:
        page.goto(fixture_path.as_uri(), timeout=120000)
        page.wait_for_function(
            "window.__diff3dDebug && window.__diff3dDebug.renderedFrames() > 2", timeout=120000)
        result = page.evaluate("""async () => {
            const d=window.__diff3dDebug, c=document.querySelector('canvas'), gl=c.getContext('webgl');
            const frames=async n => { const start=d.renderedFrames();
                for(let i=0;i<240&&d.renderedFrames()-start<n;i++) await new Promise(r=>requestAnimationFrame(r));
                return d.renderedFrames()-start; };
            // Every getError the viewer makes while 30 frames are drawn; this code makes none then.
            const getError=gl.getError; let calls=0, cadence=null;
            gl.getError=function(){ calls++; return getError.apply(this,arguments); };
            try{ const start=performance.now(), drawn=await frames(30); cadence={calls, frames:drawn, ms:performance.now()-start}; }
            finally{ delete gl.getError; }
            const before=d.drainGlErrors();
            gl.enable(0x1234);
            // The error flag stays set until it is read, so the viewer's own next drain must report it.
            const raisedAt=performance.now();
            while(d.glErrorTotal()===before&&performance.now()-raisedAt<10000) await new Promise(r=>requestAnimationFrame(r));
            const reportedAfterMs=performance.now()-raisedAt;
            reportStartupError(new Error('synthetic start-up failure'));
            const advanced=await frames(3);
            const style=document.createElement('style');
            style.textContent='header,.top,.bar,#cases{display:none!important}';
            document.head.appendChild(style);
            const diag=document.getElementById('diag');
            return {cadence, reportedAfterMs, advanced, counted:d.glErrorTotal()-before, last:d.lastGlError(),
                    queued:gl.getError(), text:diag?diag.textContent:null,
                    visible:!!diag&&getComputedStyle(diag).display!=='none'&&diag.getBoundingClientRect().height>0};
        }""")
    finally:
        page.close()
    text = result["text"] or ""
    cadence = result["cadence"] or {}
    if (not cadence or cadence["frames"] < 2 or cadence["calls"] > cadence["ms"] / 1000 + 1
            or result["advanced"] < 2 or result["counted"] != 1 or result["last"] != 1280 or result["queued"] != 0
            or "INVALID_ENUM" not in text or "synthetic start-up failure" not in text or not result["visible"]
            or not any("INVALID_ENUM" in message for message in console_errors)
            or not any("synthetic start-up failure" in message for message in console_errors)):
        raise AssertionError(f"GL and start-up errors must stay reported: {result}, console {console_errors}")
    print("BROWSER_ERROR_SURFACE_OK", flush=True)


def verify_state_reset(browser, fixture_path: Path) -> None:
    """Every frame starts from the GL state the viewer depends on, whatever the context held.

    three.js writes that state from known values (WebGLState.reset); the viewer used to set
    seven states per frame and inherit the rest, so whatever anything else left behind carried
    into every later frame. A bound framebuffer, a false colour mask, a NEVER depth test, a
    collapsed depth range, zero sample coverage or a zero depth clear can each leave nothing
    visible, and all but the framebuffer do so without a GL error. They are planted together
    between frames here, and the next frames must draw the fitted view again with no GL error.
    """
    page = browser.new_page(viewport={"width": 1024, "height": 800})
    try:
        page.goto(fixture_path.as_uri(), timeout=120000)
        page.wait_for_function(
            "window.__diff3dDebug && window.__diff3dDebug.renderedFrames() > 2", timeout=120000)
        result = page.evaluate("""async () => {
            const d=window.__diff3dDebug, c=document.querySelector('canvas'), gl=c.getContext('webgl');
            const frames=async n => { const start=d.renderedFrames();
                for(let i=0;i<240&&d.renderedFrames()-start<n;i++) await new Promise(r=>requestAnimationFrame(r)); };
            const centre=()=>{ gl.bindFramebuffer(gl.FRAMEBUFFER,null); const p=new Uint8Array(4); gl.finish();
                gl.readPixels(c.width>>1,c.height>>1,1,1,gl.RGBA,gl.UNSIGNED_BYTE,p); return Array.from(p); };
            await frames(2);
            const healthy=centre();
            gl.bindFramebuffer(gl.FRAMEBUFFER,null); gl.colorMask(true,true,true,true); gl.clearColor(0,0,0,1); gl.clear(gl.COLOR_BUFFER_BIT);
            const fb=gl.createFramebuffer();
            gl.colorMask(false,false,false,false); gl.depthFunc(gl.NEVER); gl.depthRange(1,1); gl.clearDepth(0);
            gl.enable(gl.SAMPLE_COVERAGE); gl.sampleCoverage(0,false); gl.frontFace(gl.CW);
            gl.bindFramebuffer(gl.FRAMEBUFFER,fb);
            const errorsBefore=d.drainGlErrors();
            await frames(3);
            const after=centre(), glErrors=d.drainGlErrors()-errorsBefore;
            gl.deleteFramebuffer(fb);
            return {healthy,after,glErrors};
        }""")
    finally:
        page.close()
    blue = lambda p: p[2] > 200 and max(p[:2]) < 20
    if not blue(result["healthy"]) or not blue(result["after"]) or result["glErrors"]:
        raise AssertionError(f"Frames must establish their own GL state: {result}")
    print("BROWSER_STATE_RESET_OK", flush=True)


def verify_frame_diagnostics(browser, fixture_path: Path) -> None:
    """frameDiagnostics reports the state that can blank a frame, and changes none of it.

    It used to omit the depth clear value, sample coverage, blend factors and per-attribute
    divisors, report a VALIDATE_STATUS nothing ever sets, and run its depth probe with whatever
    culling, colour mask and depth range the scene left, then leave its own state behind, so a
    second capture described the first one's changes rather than the viewer's.
    """
    page = browser.new_page(viewport={"width": 1024, "height": 800})
    try:
        page.goto(fixture_path.as_uri(), timeout=120000)
        page.wait_for_function(
            "window.__diff3dDebug && window.__diff3dDebug.renderedFrames() > 2", timeout=120000)
        result = page.evaluate("""async () => {
            const d=window.__diff3dDebug, c=document.querySelector('canvas'), gl=c.getContext('webgl');
            const frames=async n => { const start=d.renderedFrames();
                for(let i=0;i<240&&d.renderedFrames()-start<n;i++) await new Promise(r=>requestAnimationFrame(r)); };
            await frames(2);
            const first=d.frameDiagnostics(), second=d.frameDiagnostics();
            const keys=['viewport','scissorTest','depthTest','depthFunc','depthRange','depthMask','colorMask','cullFace',
                        'frontFace','blend','blendSrcRGB','blendDstRGB','blendEquationRGB','depthClear','colorClear',
                        'sampleCoverage','sampleCoverageValue','alphaToCoverage','polygonOffsetFill','stencilTest','currentProgram'];
            const errorsBefore=d.drainGlErrors();
            await frames(2);
            const px=new Uint8Array(4); gl.finish();
            gl.readPixels(c.width>>1,c.height>>1,1,1,gl.RGBA,gl.UNSIGNED_BYTE,px);
            return {missing:keys.filter(k=>!(k in first)), changed:keys.filter(k=>JSON.stringify(first[k])!==JSON.stringify(second[k])),
                    validated:Object.values(first.programs).some(p=>p&&('validated' in p)),
                    meshAttributes:first.programs.mesh&&first.programs.mesh.link?first.programs.mesh.link.attributes:null,
                    untracked:(first.attribState||[]).filter(a=>a.enabled!==a.trackedEnabled||a.divisor!==a.trackedDivisor).map(a=>a.i),
                    attribCount:(first.attribState||[]).length, depthProbe:first.depthProbe, selfTest:first.selfTest,
                    error:first.error, after:Array.from(px), glErrors:d.drainGlErrors()-errorsBefore};
        }""")
    finally:
        page.close()
    probe, control = result["depthProbe"] or {}, result["selfTest"] or {}
    if (result["missing"] or result["changed"] or result["validated"] or result["untracked"] or not result["attribCount"]
            or ["aPosition", 0, 1] not in (result["meshAttributes"] or [])
            or probe.get("sceneWroteDepth") is not True or probe.get("depthClear") != 1 or probe.get("error")
            or control.get("centre") != [0, 255, 0, 255] or result["error"] or result["glErrors"]
            or not (result["after"][2] > 200 and max(result["after"][:2]) < 20)):
        raise AssertionError(f"frameDiagnostics must report blanking state and leave it unchanged: {result}")
    print("BROWSER_FRAME_DIAGNOSTICS_OK", flush=True)


def verify_context_loss_recovery(browser, fixture_path: Path, startup: bool = False) -> None:
    """A lost WebGL context is reported, counts no frames, and comes back exactly as it was.

    three.js calls preventDefault() on webglcontextlost, draws nothing while the context is lost
    and rebuilds every GPU resource on webglcontextrestored (WebGLRenderer.js:1113-1143, :1646).
    Without the first the browser never restores the context; without the last, the restored
    context holds none of the viewer's buffers, textures or programs, so nothing drawn with the
    old handles can appear. A full-canvas signature (pixels differing from the first one, and the sum of every colour
    channel) is compared before the loss and after each of three restores. With startup,
    the two start-up cases of verify_context_loss_at_startup are checked against the same view.
    """
    page = browser.new_page(viewport={"width": 1024, "height": 800})
    errors = []
    page.on("pageerror", lambda error, target=errors: target.append(str(error)))
    page.on("console", lambda message, target=errors:
            target.append(message.text) if message.type == "error" else None)
    try:
        page.goto(fixture_path.as_uri(), timeout=120000)
        page.wait_for_function(
            "window.__diff3dDebug && window.__diff3dDebug.renderedFrames() > 2", timeout=120000)
        result = page.evaluate("""async () => {
            const d=window.__diff3dDebug, c=document.querySelector('canvas'), gl=c.getContext('webgl');
            const ext=gl.getExtension('WEBGL_lose_context');
            if(!ext) return {skipped:'WEBGL_lose_context is unavailable'};
            // A paused animation makes frames comparable pixel for pixel.
            if(!animPaused) document.getElementById('playToggle').click();
            const frames=async n => { const start=d.renderedFrames();
                for(let i=0;i<240&&d.renderedFrames()-start<n;i++) await new Promise(r=>requestAnimationFrame(r)); };
            const until=async test => { for(let i=0;i<1000&&!test();i++) await new Promise(r=>setTimeout(r,10)); return test(); };
            const signature=()=>{ const data=new Uint8Array(4*c.width*c.height); gl.finish();
                gl.readPixels(0,0,c.width,c.height,gl.RGBA,gl.UNSIGNED_BYTE,data);
                let differing=0, sum=0; for(let i=0;i<data.length;i+=4){
                    if(data[i]!==data[0]||data[i+1]!==data[1]||data[i+2]!==data[2]) differing++; sum+=data[i]+data[i+1]+data[i+2]; }
                return [differing,sum]; };
            await frames(3);
            const baseline=signature(), builtAtLoad=d.glRebuildCount(), errorsBefore=d.drainGlErrors(), cycles=[];
            for(let cycle=0;cycle<3;cycle++){
                const rebuilds=d.glRebuildCount();
                ext.loseContext();
                const lost=await until(()=>d.lastContextEvent()==='lost');
                const framesAtLoss=d.renderedFrames();
                for(let i=0;i<8;i++) await new Promise(r=>requestAnimationFrame(r));
                const framesWhileLost=d.renderedFrames()-framesAtLoss, statsWhileLost=document.getElementById('stats').textContent;
                ext.restoreContext();
                const restored=await until(()=>d.glRebuildCount()>rebuilds&&!gl.isContextLost());
                await frames(3);
                cycles.push({lost,framesWhileLost,statsWhileLost,restored,rebuilt:d.glRebuildCount()-rebuilds,
                             signature:signature(),lastError:d.lastRenderError(),stopped:d.renderStopped()});
            }
            return {baseline,builtAtLoad,cycles,glErrors:d.drainGlErrors()-errorsBefore,
                    events:[d.contextLostEvents(),d.contextRestoreCount()]};
        }""")
    finally:
        page.close()
    if "skipped" in result:
        print("BROWSER_CONTEXT_LOSS_SKIPPED", fixture_path.stem, result["skipped"], flush=True)
        return
    wrong = [cycle for cycle in result["cycles"]
             if not (cycle["lost"] and cycle["framesWhileLost"] == 0 and "lost" in cycle["statsWhileLost"]
                     and cycle["restored"] and cycle["rebuilt"] == 1 and cycle["signature"] == result["baseline"]
                     and cycle["lastError"] is None and not cycle["stopped"])]
    if (wrong or result["builtAtLoad"] != 1 or result["glErrors"] or result["events"] != [3, 3]
            or result["baseline"][0] == 0 or errors):
        raise AssertionError(f"{fixture_path.stem}: context loss must pause and restore the view exactly: "
                             f"{result}, browser errors {errors}")
    print("BROWSER_CONTEXT_LOSS_OK", fixture_path.stem, flush=True)
    if startup:
        verify_context_loss_at_startup(browser, fixture_path, result["baseline"])


# Both start-up checks inject their fault into createProgram, which the viewer first calls from
# initGLResources, after every capability query and before anything is drawn.
CONTEXT_LOSS_SIGNATURE = """() => { const c=document.querySelector('canvas'), gl=c.getContext('webgl');
    const data=new Uint8Array(4*c.width*c.height); gl.finish();
    gl.readPixels(0,0,c.width,c.height,gl.RGBA,gl.UNSIGNED_BYTE,data);
    let differing=0, sum=0; for(let i=0;i<data.length;i+=4){
        if(data[i]!==data[0]||data[i+1]!==data[1]||data[i+2]!==data[2]) differing++; sum+=data[i]+data[i+1]+data[i+2]; }
    return [differing,sum]; }"""


def open_page_with_init_script(browser, fixture_path: Path, init_script: str):
    """Open a fixture with an init script. The viewer starts, or throws, synchronously in its one
    inline script, so once the load event has fired the outcome is settled either way. Returns the
    page and the list its page and console errors are appended to."""
    page = browser.new_page(viewport={"width": 1024, "height": 800})
    errors = []
    page.on("pageerror", lambda error, target=errors: target.append(str(error)))
    page.on("console", lambda message, target=errors:
            target.append(message.text) if message.type == "error" else None)
    page.add_init_script(init_script)
    page.goto(fixture_path.as_uri(), timeout=120000, wait_until="load")
    return page, errors


def verify_context_loss_during_startup(browser, fixture_path: Path, baseline) -> None:
    """A context lost while the viewer starts is rebuilt once the browser restores it.

    The context is lost inside start-up's resource build, where a call on the dead context throws
    an error the viewer did not raise as a loss (as the index-extension check does when
    getExtension answers null). The viewer must treat it as the loss, draw nothing while it lasts,
    and show the same view as a normal start once the context is restored.
    """
    page, errors = open_page_with_init_script(browser, fixture_path, """(() => {
        const create=WebGLRenderingContext.prototype.createProgram; let armed=true;
        WebGLRenderingContext.prototype.createProgram=function(){
            // A lost context answers getExtension with null, so the test keeps this object to restore it.
            if(armed){ armed=false; const ext=this.getExtension('WEBGL_lose_context'); window.__loseContextExtension=ext;
                if(ext) ext.loseContext(); throw new Error('injected fault on a lost context'); }
            return create.call(this);
        };
    })();""")
    try:
        during = page.evaluate("""async () => {
            const d=window.__diff3dDebug, c=document.querySelector('canvas'), gl=c.getContext('webgl');
            if(!d) return {started:false, stats:document.getElementById('stats').textContent};
            const ext=window.__loseContextExtension;
            if(!ext) return {started:true, skipped:'WEBGL_lose_context is unavailable'};
            const until=async test => { for(let i=0;i<1000&&!test();i++) await new Promise(r=>setTimeout(r,10)); return test(); };
            const frames=async n => { const start=d.renderedFrames();
                for(let i=0;i<240&&d.renderedFrames()-start<n;i++) await new Promise(r=>requestAnimationFrame(r)); };
            const lost=await until(()=>d.lastContextEvent()==='lost');
            for(let i=0;i<8;i++) await new Promise(r=>requestAnimationFrame(r));
            const whileLost={frames:d.renderedFrames(), builds:d.glRebuildCount(), lostFrames:d.contextLostFrames()};
            if(!animPaused) document.getElementById('playToggle').click();
            ext.restoreContext();
            const restored=await until(()=>d.glRebuildCount()>0&&!gl.isContextLost());
            await frames(3);
            return {started:true, lost, whileLost, restored, builds:d.glRebuildCount(), rendered:d.renderedFrames(),
                    lastError:d.lastRenderError(), stopped:d.renderStopped(), glErrors:d.drainGlErrors()};
        }""")
        if during.get("started"):
            during["signature"] = page.evaluate(CONTEXT_LOSS_SIGNATURE)
    finally:
        page.close()
    if (not during.get("started") or "skipped" in during or not during["lost"] or during["whileLost"]["frames"] != 0
            or during["whileLost"]["builds"] != 0 or not during["whileLost"]["lostFrames"]
            or not during["restored"] or during["builds"] != 1 or during["rendered"] < 3
            or during["signature"] != baseline or during["lastError"] is not None or during["stopped"]
            or during["glErrors"] or errors):
        raise AssertionError(f"{fixture_path.stem}: a context lost during start-up must be rebuilt on restore: "
                             f"{during}, baseline {baseline}, browser errors {errors}")


def verify_context_loss_after_failed_startup(browser, fixture_path: Path) -> None:
    """A viewer whose start-up threw ignores a later context loss and restore.

    There is no render loop to resume, so like three.js, which removes its context listeners when
    its set-up throws (WebGLRenderer.js:431-436), the viewer must neither overwrite its start-up
    report nor raise anything when the context is lost or restored.
    """
    page, errors = open_page_with_init_script(browser, fixture_path, """(() => {
        WebGLRenderingContext.prototype.createProgram=function(){ throw new Error('injected start-up failure'); };
    })();""")
    try:
        page.evaluate("""async () => { for(let i=0;i<20;i++) await new Promise(r=>setTimeout(r,20)); }""")
        errors_before = list(errors)
        failed = page.evaluate("""async () => {
            const settle=async () => { for(let i=0;i<20;i++) await new Promise(r=>setTimeout(r,20));
                for(let i=0;i<4;i++) await new Promise(r=>requestAnimationFrame(r)); };
            const c=document.querySelector('canvas'), gl=c.getContext('webgl'), ext=gl.getExtension('WEBGL_lose_context');
            const report=()=>({stats:document.getElementById('stats').textContent,
                               banner:(document.getElementById('diag')||{}).textContent||null});
            // Registered after the viewer's own listener, so it sees whether the viewer kept the context.
            let prevented=null; c.addEventListener('webglcontextlost',e=>{ prevented=e.defaultPrevented; });
            const before=report();
            ext.loseContext(); await settle();
            // A browser restores only a context whose loss was prevented; do the same.
            if(prevented) ext.restoreContext();
            await settle();
            return {started:!!window.__diff3dDebug, prevented, before, after:report()};
        }""")
        errors_after = list(errors)
    finally:
        page.close()
    # WebKit reports a top-level start-up throw on file:// as "Script error.", so the banner is
    # required to exist and to stay unchanged rather than to quote the injected message.
    if (failed["started"] or failed["prevented"] is None or not failed["before"]["stats"].startswith("error:")
            or not failed["before"]["banner"] or failed["after"] != failed["before"]
            or not errors_before or errors_after != errors_before):
        raise AssertionError(f"{fixture_path.stem}: a viewer that failed to start must ignore context loss: "
                             f"{failed}, browser errors before {errors_before}, after {errors_after}")


def verify_context_loss_at_startup(browser, fixture_path: Path, baseline) -> None:
    """Both start-up cases: a context lost during start-up, and a start-up that threw."""
    verify_context_loss_during_startup(browser, fixture_path, baseline)
    verify_context_loss_after_failed_startup(browser, fixture_path)
    print("BROWSER_CONTEXT_LOSS_STARTUP_OK", fixture_path.stem, flush=True)


def verify_shadow_pass_exception_safety(page) -> None:
    """A dynamic shadow pass that throws must still unbind its framebuffer.

    Each pass binds its shadow target and unbinds it as its last statement; a throw in between
    left later drawing going into the shadow map. The draw inside each pass is made to throw, and
    the default framebuffer must be bound again when the pass has unwound.
    """
    result = page.evaluate("""() => {
        const o=active.objects.find(x=>x.mode==='triangles');
        if(!o) throw new Error('shadow pass check needs a triangle object');
        const light=(type)=>({type:type==='pointDynamic'?'point':(type==='spotDynamic'?'spot':'directional'),visible:true,
            position:[0,10,0],target:[0,0,0],shadow:{type,size:16}});
        const directional=drawShadowCaster, point=drawPointShadowCaster, out={};
        drawShadowCaster=()=>{ throw new Error('injected shadow fault'); };
        drawPointShadowCaster=()=>{ throw new Error('injected shadow fault'); };
        try{
            for(const [kind,run] of [['directionalDynamic',renderDynamicDirectionalShadow],['spotDynamic',renderDynamicSpotShadow],['pointDynamic',renderDynamicPointShadow]]){
                const l=light(kind); let threw=null;
                try{ run(l,[Object.assign(Object.create(o),{castShadow:true})],clipping(active)); }catch(err){ threw=String(err&&err.message); }
                out[kind]={threw,defaultBound:gl.getParameter(gl.FRAMEBUFFER_BINDING)===null};
                const t=l.dynamicShadowTarget; gl.bindFramebuffer(gl.FRAMEBUFFER,null);
                if(t){ gl.deleteFramebuffer(t.framebuffer); gl.deleteTexture(t.texture); gl.deleteRenderbuffer(t.depth); }
            }
        } finally { drawShadowCaster=directional; drawPointShadowCaster=point; }
        return out;
    }""")
    wrong = {kind: value for kind, value in result.items()
             if value != {"threw": "injected shadow fault", "defaultBound": True}}
    if wrong or len(result) != 3:
        raise AssertionError(f"A throwing shadow pass must leave the default framebuffer bound: {result}")
    print("BROWSER_SHADOW_PASS_UNWIND_OK", flush=True)


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
                checked_render_recovery = False
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
                        if not checked_render_recovery:
                            verify_render_loop_recovery(
                                browser, Path(directory) / "orbit_zoom_limits.html")
                            verify_error_surface(browser, Path(directory) / "orbit_zoom_limits.html")
                            verify_state_reset(browser, Path(directory) / "orbit_zoom_limits.html")
                            verify_frame_diagnostics(browser, Path(directory) / "orbit_zoom_limits.html")
                            checked_render_recovery = True
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
                            verify_position_attribute_zero(page)
                            verify_uniform_writes(page)
                            verify_shadow_pass_exception_safety(page)
                            checked_location_cache = True
                        if name in ("fog_linear", "instanced_triangles"):
                            verify_vertex_attribute_state(page, name, instancing_enabled)
                        if instancing_enabled and name in ("orbit_zoom_limits", "layered_shadows", "skin_normals_texture",
                                                           "gltf_texture_uv1", "instanced_triangles", "point_texture"):
                            verify_context_loss_recovery(browser, Path(directory) / f"{name}.html",
                                                         startup=name == "orbit_zoom_limits")
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
                                        glErrors: window.__diff3dDebug.drainGlErrors(),
                                        visible: window.__diff3dDebug.activeObjectCount(),
                                        instancing: !!gl.getExtension('ANGLE_instanced_arrays'),
                                        redCount, blueCount, redX: redX / Math.max(1, redCount),
                                        blueX: blueX / Math.max(1, blueCount),halves};
                            }""")
                            if pixels["error"] != 0 or pixels["glErrors"] or errors:
                                raise AssertionError(f"{name}: WebGL errors {pixels['error']}, "
                                                     f"drained {pixels['glErrors']}, {errors}")
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
                                # Record the view as loaded, before any reset: if the scene never
                                # rendered on this host, that is a different defect from a reset
                                # that loses it, and the failure message must distinguish them.
                                at_load = page.evaluate(ORBIT_CENTRE_PROBE)
                                page.evaluate("() => { setCase(active.id); }")
                                # Wait for presented frames rather than a fixed delay: a slow
                                # host can take longer than any wall-clock guess to draw the
                                # reset view, and reading early returns an undrawn buffer.
                                fitted = page.evaluate(ORBIT_CENTRE_PROBE)
                                fitted["atLoad"] = {k: at_load[k] for k in
                                                    ("blue", "pixel", "frames", "dist", "angles")}
                                if not (fitted["error"] == 0 and fitted["blue"] == fitted["of"]
                                        and abs(fitted["dist"] - 2200.0) <= 1e-9 * 2200.0):
                                    raise AssertionError(f"{name} at {width}x{height}: fitted view is not drawn "
                                                         f"or not fitted {fitted}, browser errors {errors}")
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
                                # Same rule as the fitted check above: the zoom sequence ends with
                                # ~1,400 wheel events, so wait for presented frames rather than a
                                # fixed delay, and sample a block instead of one pixel.
                                restored = page.evaluate(ORBIT_CENTRE_PROBE)
                                if not (restored["error"] == 0 and restored["blue"] == restored["of"]):
                                    raise AssertionError(f"{name} at {width}x{height}: view restored after zooming "
                                                         f"is not drawn {restored}, browser errors {errors}")
                                # Every orbit assertion above raises on failure, so reaching here
                                # means this fixture passed; the shared check below reads `correct`.
                                correct = True
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
