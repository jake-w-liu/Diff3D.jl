using Diff3D, Test

# Regression for the 0.1.7 WebGL runtime, which clamped the orbit distance to an absolute
# 2.5..24 world units (zoomBy and both pinch handlers) and used fixed near/far planes of
# 0.1/180 when a case had no explicit camera. A scene fitted at 60 units could be zoomed in
# but never back out to its fitted view, and scenes larger than 180 units were clipped.
# The runtime now derives every limit from the case's fitted distance (active.baseDistance).
@testset "WebGL runtime orbit limits and clip planes are scale-relative" begin
    scene = Scene()
    add!(scene, Mesh(BoxGeometry(), MeshBasicMaterial()))
    for radius in (0.02, 8.0, 2200.0)
        file = tempname() * ".html"
        save_webgl_html(file, [WebGLExportCase("orbit", "Orbit", "limits", scene;
                                               radius=radius, height=0.375radius)]; chrome=false)
        html = read(file, String)
        rm(file; force=true)
        @test occursin("\"radius\":$(radius == round(radius) ? string(Int(radius)) : repr(radius))", html)
        # no absolute world-unit clamps or clip planes survive in the interaction runtime
        @test !occursin("Math.max(2.5,Math.min(24", html)
        @test !occursin("cam.near:.1", html)
        @test !occursin("cam.far:180", html)
        @test !occursin("active.height==null?3.0", html)
        # ratios of the fitted distance drive zoom limits, clip planes and the default pitch
        @test occursin("const ORBIT_ZOOM_IN_RATIO=1e-3, ORBIT_ZOOM_OUT_RATIO=1e3, ORBIT_NEAR_RATIO=1e-2, ORBIT_FAR_RADII=64, ORBIT_DEFAULT_HEIGHT_RATIO=.375;", html)
        @test occursin("function orbitBaseDistance(){ const b=active.baseDistance; if(b>0&&isFinite(b)) return b;", html)
        @test occursin("function orbitDistanceLimits(){ const b=orbitBaseDistance(); return {min:b*ORBIT_ZOOM_IN_RATIO,max:b*ORBIT_ZOOM_OUT_RATIO}; }", html)
        @test occursin("function clampOrbitDistance(d){ if(!(d>0&&isFinite(d))) return dist; const l=orbitDistanceLimits(); return Math.max(l.min,Math.min(l.max,d)); }", html)
        @test occursin("function zoomBy(f){ dist=clampOrbitDistance(dist*f); rememberCameraOrbitOffsets(); }", html)
        @test count("dist=clampOrbitDistance(dist*(pinchDist/nd));", html) == 2
        @test occursin("near:cam&&cam.near!=null?cam.near:d*ORBIT_NEAR_RATIO,far:cam&&cam.far!=null?cam.far:d+ORBIT_FAR_RADII*orbitBaseDistance()", html)
        @test occursin("clip=projectionClipPlanes(cam), near=clip.near, far=clip.far;", html)
        @test occursin("active.height==null?dist*ORBIT_DEFAULT_HEIGHT_RATIO:active.height", html)
        @test occursin("active.baseDistance=dist;", html)
        # browser-side hooks the Playwright harness uses to check the behaviour
        @test occursin("orbitDistanceLimits:()=>orbitDistanceLimits()", html)
        @test occursin("clipPlanes:()=>projectionClipPlanes(primaryCamera(active.camera))", html)
    end
end
