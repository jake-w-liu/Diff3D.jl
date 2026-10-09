using Test, Diff3D

function _webexport_audit_html(scene; title="Audit")
    path = tempname() * ".html"
    try
        save_webgl_html(path, [WebGLExportCase("audit", title, "audit", scene)]; chrome=false)
        return read(path, String)
    finally
        rm(path; force=true)
    end
end

@testset "WebGL export: transparent is authoritative, as in three.js" begin
    # WebGLRenderLists.js push:134 and WebGLState.js setMaterial:765 consult only
    # material.transparent; opacity below one on an opaque material stays opaque.
    @test !Diff3D._web_material_transparent(MeshBasicMaterial(opacity=0.5))
    @test Diff3D._web_material_transparent(MeshBasicMaterial(opacity=0.5, transparent=true))
    @test Diff3D._web_material_transparent(MeshBasicMaterial(transparent=true))
    @test !Diff3D._web_material_transparent(MeshStandardMaterial(opacity=0.25))

    scene = Scene()
    add!(scene, Mesh(BoxGeometry(), MeshBasicMaterial(opacity=0.5); name="half_opaque"))
    drawable = only(Diff3D._web_collect_drawables(scene))
    @test occursin("\"opacity\":0.5", drawable)
    @test occursin("\"transparent\":false", drawable)

    # An opaque instanced mesh stays one GPU-instanced draw instead of being split per instance.
    matrices = [mat4_translation(Float64(i), 0.0, 0.0) for i in 1:3]
    instanced = Scene()
    add!(instanced, InstancedMesh(BoxGeometry(), MeshBasicMaterial(opacity=0.5), matrices))
    drawables = Diff3D._web_collect_drawables(instanced)
    @test length(drawables) == 1
    @test occursin("\"instanceMatrices\":[[", only(drawables))
    split_scene = Scene()
    add!(split_scene, InstancedMesh(BoxGeometry(),
                                    MeshBasicMaterial(opacity=0.5, transparent=true), matrices))
    @test length(Diff3D._web_collect_drawables(split_scene)) == 3

    html = _webexport_audit_html(scene)
    @test occursin("function objectIsTransparent(o){ return o.transparent===true; }", html)
    @test !occursin("o.opacity<1", html)
end

@testset "WebGL export: opaque draws do not blend and write alpha 1" begin
    scene = Scene()
    add!(scene, Mesh(BoxGeometry(), MeshBasicMaterial()))
    html = _webexport_audit_html(scene)
    # BLEND is off by default and enabled per transparent draw (WebGLState.js:611-629).
    @test occursin("gl.enable(gl.DEPTH_TEST); gl.disable(gl.BLEND);", html)
    @test !occursin("gl.enable(gl.BLEND)", html)
    @test occursin("setBlending(transparent);", html)
    @test occursin("gl.blendFuncSeparate(gl.SRC_ALPHA,gl.ONE_MINUS_SRC_ALPHA,gl.ONE,gl.ONE_MINUS_SRC_ALPHA)", html)
    # opaque_fragment.glsl.js: OPAQUE materials write alpha 1; MeshDepthMaterial does not.
    @test occursin("if(uOpaque>0.5) gl_FragColor.a=1.0;", html)
    @test occursin("uniform1f(p,\"uOpaque\",transparent||o.materialType===\"depth\"?0:1,REQUIRED)", html)
    @test occursin("\"uModel\",\"uView\",\"uProj\",\"uColor\",\"uOpacity\",\"uOpaque\"", html)
end

@testset "WebGL export: draw order follows three.js render lists" begin
    scene = Scene()
    add!(scene, Mesh(BoxGeometry(), MeshBasicMaterial()))
    html = _webexport_audit_html(scene)
    @test occursin("opaqueScratch.sort(painterSortStable); transparentScratch.sort(reversePainterSortStable);", html)
    @test occursin("function geometrySphere(o)", html)
    @test occursin("function instancedSphere(sphere,matrices)", html)
end

@testset "WebGL export: non-finite numbers are rejected, not written as 0" begin
    for value in (NaN, Inf, -Inf, NaN32)
        @test_throws ArgumentError Diff3D._js_num(value)
        @test_throws ArgumentError Diff3D._js_write_num(devnull, value, Diff3D._web_num_buffer())
    end
    @test Diff3D._js_num(0.25) == "0.25"
    # Geometry positions are not validated for finiteness before serialization, so the
    # writer is the check; the atomic export then leaves no file behind.
    geometry = BufferGeometry([0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, NaN, 0.0],
                              Float64[], Float64[], [1, 2, 3], 3, 1)
    scene = Scene()
    add!(scene, Mesh(geometry, MeshBasicMaterial()))
    path = tempname() * ".html"
    @test_throws ArgumentError save_webgl_html(path, [WebGLExportCase("nan", "NaN", "position", scene)])
    @test !isfile(path)
    # An infinite camera far plane keeps its explicit Infinity literal.
    camera = PerspectiveCamera(fov=pi / 3, aspect=1.0, near=0.1, far=Inf)
    @test occursin("\"far\":Infinity", Diff3D._web_camera_json(camera))
end

@testset "WebGL export: string literals escape line separators and reject invalid UTF-8" begin
    @test Diff3D._js_str("a\u2028b\u2029c") == "\"a\\u2028b\\u2029c\""
    @test Diff3D._js_str("x<y") == "\"x\\u003cy\""
    @test_throws ArgumentError Diff3D._js_str("bad\xffname")
    scene = Scene()
    add!(scene, Mesh(BoxGeometry(), MeshBasicMaterial(); name="line\u2028sep"))
    html = _webexport_audit_html(scene; title="t")
    data = html[findfirst("const DATA = ", html)[end]:end]
    @test !occursin('\u2028', data)
    @test occursin("line\\u2028sep", data)
end

@testset "WebGL export: draw uniforms are cached and grouped like three.js" begin
    scene = Scene()
    add!(scene, Mesh(BoxGeometry(), MeshBasicMaterial()))
    html = _webexport_audit_html(scene)
    # WebGLUniforms.js caches each uniform's last value; a repeated write issues no GL call.
    @test occursin("else if(reusable){ while(i<n&&exact[i]===value[i]) i++; if(i===n) return; }", html)
    @test occursin("else if(u.value===value) return;", html)
    # View, shadow and material groups are skipped when the program already holds them.
    @test occursin("function writeViewUniforms(p,state,light,fg,tm)", html)
    @test occursin("function writeShadowUniforms(p,objShadows)", html)
    @test occursin("function writeMaterialUniforms(p,o,transparent)", html)
    @test occursin("writeMaterialUniforms(UNIFORM_RECORDER,o,transparent)", html)
    # Unskinned programs declare a single bone matrix; skinned ones keep 64.
    @test occursin("function singleBoneShader(source)", html)
    @test occursin("meshProgram=program(singleBoneShader(VSH),meshColorShader)", html)
    # The dead FSH program source is gone; FSH_EMISSIVE is the mesh shader.
    @test !occursin("const FSH=", html)
    # Static cases apply their (empty) animation state once; per-frame state caches.
    @test occursin("if(active.animations.length||!active.animationStateApplied){ applyAnimations(active,animTime); active.animationStateApplied=true; }", html)
    @test occursin("function useProgram(p){ if(glCache.program!==p){ gl.useProgram(p); glCache.program=p; } }", html)
    @test occursin("if(!bt||bt.frame===frameSerial) return;", html)
end
