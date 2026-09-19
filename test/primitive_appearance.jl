using Test
using Diff3D

@testset "Primitive vertex colors and line dash interpolation" begin
    function appearance_geometry(positions; indices=Int[], colors=nothing, distances=nothing)
        constructed_geometry = BufferGeometry(Float64.(positions), Float64[], Float64[], indices,
                                               length(positions) ÷ 3, 0)
        colors === nothing || set_attribute!(constructed_geometry, :color, colors, 3)
        distances === nothing || set_attribute!(constructed_geometry, :lineDistance, distances, 1)
        return constructed_geometry
    end
    function appearance_render(object, camera; draw=render!, fog=nothing, kwargs...)
        container = Scene(fog=fog); add!(container, object)
        target = RenderTarget(64, 32)
        draw(target, container, camera; kwargs...)
        return target
    end
    ortho = OrthographicCamera(left=-1.0, right=1.0, bottom=-1.0, top=1.0,
                               near=0.1, far=10.0)
    ortho.position = Vec3(0.0, 0.0, 2.0)
    endpoints = [-0.75, 0.0, 0.0, 0.75, 0.0, 0.0]
    red_blue = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0]
    for indices in (Int[], [1, 2], [2, 1]), scalar_type in (Float32, Float64)
        colored = appearance_geometry(endpoints; indices=indices, colors=scalar_type.(red_blue))
        for constructor in (LineObject, LineSegments, LineLoop)
            result = appearance_render(constructor(colored, LineBasicMaterial()), ortho)
            @test result.color[16, 8, :] ≈ [1.0, 0.0, 0.0]
            @test result.color[16, 32, :] ≈ [0.5, 0.0, 0.5]
            @test result.color[16, 56, :] ≈ [0.0, 0.0, 1.0]
        end
        points = appearance_render(PointsObject(colored, PointsMaterial(
            size=1.0, size_attenuation=false, color=Color3(0.4, 0.6, 0.8))), ortho)
        @test points.color[16, 8, :] ≈ [0.4, 0.0, 0.0]
        @test points.color[16, 56, :] ≈ [0.0, 0.0, 0.8]
    end

    # Both fog models mix 50% green at this camera's depth of two units.
    for fog in (Fog(color=Color3(0.0,1.0,0.0), near=1.0, far=3.0),
                FogExp2(color=Color3(0.0,1.0,0.0), density=sqrt(log(2.0))/2)),
        material in (LineBasicMaterial(), LineDashedMaterial(gap_size=0.0))
        colored = appearance_geometry(endpoints; colors=red_blue, distances=[0.0,1.5])
        fogged = appearance_render(LineSegments(colored,material),ortho;fog)
        @test fogged.color[16,32,:] ≈ [0.25,0.5,0.25] atol=1e-12
    end

    perspective = PerspectiveCamera(fov=π/2, aspect=2.0, near=0.1, far=100.0)
    perspective.position = Vec3(0.0, 0.0, 0.0)
    perspective.target = Vec3(0.0, 0.0, -1.0)
    slanted = appearance_geometry([-1.0, 0.0, -2.0, 4.0, 0.0, -8.0];
                                  colors=red_blue, distances=[0.0, 1.0])
    gradient = appearance_render(LineSegments(slanted, LineBasicMaterial()), perspective)
    # At the projected midpoint (x=32), reciprocal depths 1/2 and 1/8 give
    # original-segment parameter 1/5, rather than the screen-space value 1/2.
    @test gradient.color[16, 32, :] ≈ [0.8, 0.0, 0.2]
    dashed_material = LineDashedMaterial(dash_size=0.3, gap_size=0.7)
    dashed_perspective = appearance_render(LineSegments(slanted, dashed_material), perspective)
    @test dashed_perspective.color[16, 32, :] ≈ [0.8, 0.0, 0.2]
    @test isinf(dashed_perspective.depth[16, 38])
    coincident_projection = appearance_geometry([0.0,0.0,-8.0,0.0,0.0,-2.0];
        colors=red_blue, distances=[0.5,0.1])
    @test appearance_render(LineSegments(coincident_projection,dashed_material),perspective).color[16,32,:] ≈ [0.0,0.0,1.0]

    distances_geo = appearance_geometry(endpoints; distances=[0.0, 1.5])
    for scale in (0.5, 1.0, 2.0), reverse in (false, true)
        distances_geo.indices = reverse ? [2, 1] : Int[]
        dashes = appearance_render(LineSegments(distances_geo, LineDashedMaterial(
            scale=scale, dash_size=0.25, gap_size=0.25)), ortho)
        for x in 9:55
            visible = mod(((x - 8) / 32) * scale, 0.5) <= 0.25
            @test isfinite(dashes.depth[16, x]) == visible
            @test dashes.color[16, x, 1] == Float64(visible)
        end
    end

    # Clipping must retain the original color and dash phase. Compare to a
    # separately authored segment clipped analytically at z=-1.
    perspective.near = 1.0
    a, b = Vec3(-0.1, 0.0, -0.25), Vec3(4.0, 0.0, -8.0)
    cut = (1.0 - 0.25) / (8.0 - 0.25)
    clipped_start = a * (1 - cut) + b * cut
    original_geo = appearance_geometry([a.x,a.y,a.z,b.x,b.y,b.z];
        colors=red_blue, distances=[0.1, 1.1])
    clipped_geo = appearance_geometry([clipped_start.x,clipped_start.y,-1.0,b.x,b.y,b.z];
        colors=[1-cut,0.0,cut,0.0,0.0,1.0], distances=[0.1+cut,1.1])
    for material in (LineBasicMaterial(), dashed_material), reverse in (false,true)
        original_geo.indices = reverse ? [2,1] : Int[]
        original = appearance_render(LineSegments(original_geo, material), perspective)
        clipped = appearance_render(LineSegments(clipped_geo, material), perspective)
        @test original.color ≈ clipped.color atol=1e-12
        @test isfinite.(original.depth) == isfinite.(clipped.depth)
        crop = appearance_render(LineSegments(original_geo, material), perspective;
            draw=render_lines!, xlo=28, xhi=39, ylo=8, yhi=24, cache=RenderCache())
        @test crop.color[8:24,28:39,:] ≈ original.color[8:24,28:39,:] atol=1e-12
    end

    # Material tint, instance tint and geometry color all contribute, including
    # primitive draw modes on InstancedMesh.
    tinted_geo = appearance_geometry(endpoints; colors=red_blue, distances=[0.0,1.5])
    for (mode, material) in ((:lines, LineBasicMaterial(color=Color3(0.8,0.6,0.4))),
                            (:points, PointsMaterial(color=Color3(0.8,0.6,0.4),size=1.0,size_attenuation=false)))
        instanced = InstancedMesh(tinted_geo, material, 1; draw_mode=mode)
        set_instance_color!(instanced, 1, Color3(0.5,0.5,0.5))
        tint_image = appearance_render(instanced, ortho)
        @test tint_image.color[16,8,:] ≈ [0.4,0.0,0.0]
        @test tint_image.color[16,56,:] ≈ [0.0,0.0,0.2]
    end

    # Preserve the established optional-attribute behavior, including padded
    # color attributes, incomplete attributes, and missing line distances.
    padded = appearance_geometry(endpoints)
    set_attribute!(padded,:color,[1.0,0.0,0.0,0.3,0.0,0.0,1.0,0.7],4)
    @test appearance_render(LineSegments(padded,LineBasicMaterial()),ortho).color[16,32,:] ≈ [0.5,0.0,0.5]
    for invalid_colors in ([0.0,1.0,0.0], Float64[])
        set_attribute!(padded,:color,invalid_colors,3)
        @test appearance_render(LineSegments(padded,LineBasicMaterial()),ortho).color[16,32,:] == [1.0,1.0,1.0]
    end
    padded.attributes[:color] = Diff3D.BufferAttribute(zeros(6),typemax(Int))
    @test Diff3D._geometry_attribute_for_components(padded,:color,3) === nothing
    @test Diff3D._web_color_json(padded,true) == "null"
    @test appearance_render(LineSegments(padded,LineBasicMaterial()),ortho).color[16,32,:] == [1.0,1.0,1.0]
    missing = appearance_render(LineSegments(padded, dashed_material), ortho)
    @test all(isfinite, missing.depth[16,8:56])
    no_gaps = appearance_render(LineSegments(distances_geo,
        LineDashedMaterial(dash_size=0.25,gap_size=0.0)), ortho)
    @test all(isfinite, no_gaps.depth[16,8:56])

    polygon = appearance_geometry([-0.75,0.0,0.0, 0.0,0.75,0.0, 0.75,0.0,0.0];
        colors=[1.0,0.0,0.0, 0.0,1.0,0.0, 0.0,0.0,1.0], distances=[0.0,0.6,1.4])
    for constructor in (LineObject, LineLoop)
        edges = constructor === LineLoop ? [1,2,2,3,3,1] : [1,2,2,3]
        reference_geo = deepcopy(polygon); reference_geo.indices = edges
        @test reference_geo !== polygon
        for material in (LineBasicMaterial(), dashed_material)
            continuous = appearance_render(constructor(polygon,material),ortho)
            separate = appearance_render(LineSegments(reference_geo,material),ortho)
            @test continuous.color ≈ separate.color
            @test continuous.depth == separate.depth
        end
    end
    # Selecting the second segment must not reset its authored phase.
    set_draw_range!(polygon,2,2)
    selected = appearance_render(LineObject(polygon,dashed_material),ortho)
    selected_geo = appearance_geometry(polygon.positions[4:9];
        colors=polygon.attributes[:color].data[4:9], distances=[0.6,1.4])
    @test selected.color ≈ appearance_render(LineSegments(selected_geo,dashed_material),ortho).color

    scaled_geo = appearance_geometry(endpoints ./ [2,1,1,2,1,1]; distances=[0.0,1.5])
    scaled_instance = InstancedMesh(scaled_geo,dashed_material,1;draw_mode=:lines)
    set_instance_matrix!(scaled_instance,1,mat4_scaling(2.0,1.0,1.0))
    @test appearance_render(scaled_instance,ortho).color ≈
        appearance_render(LineSegments(distances_geo,dashed_material),ortho).color
    morphed = appearance_geometry(endpoints;colors=red_blue)
    set_attribute!(morphed,:morphPosition0,[0.5,0.0,0.0,0.0,0.0,0.0],3)
    posed_points = PointsObject(morphed,PointsMaterial(size=1.0,size_attenuation=false);
                                morph_target_influences=[0.5])
    @test appearance_render(posed_points,ortho).color[16,16,:] ≈ [1.0,0.0,0.0]
    for colorspace in (:linear, :srgb)
        point_texture = Texture(reshape([0.4,0.6,0.8],1,1,3);colorspace=colorspace)
        textured = appearance_render(PointsObject(tinted_geo,PointsMaterial(
            size=1.0,size_attenuation=false,map=point_texture)),ortho)
        red = colorspace === :linear ? 0.4 : ((0.4+0.055)/1.055)^2.4
        blue = colorspace === :linear ? 0.8 : ((0.8+0.055)/1.055)^2.4
        @test textured.color[16,8,:] ≈ [red,0.0,0.0]
        @test textured.color[16,56,:] ≈ [0.0,0.0,blue]
    end

    # A fragment discarded by the dash test must also leave the existing depth
    # and background intact when depth testing/writing are enabled.
    dash_scene = Scene(); add!(dash_scene,LineSegments(distances_geo,
        LineDashedMaterial(dash_size=0.25,gap_size=0.25)))
    background = RenderTarget(64,32);background.color[:,:,3] .= 0.6
    render_lines!(background,dash_scene,ortho)
    @test background.color[16,20,:] == [0.0,0.0,0.6]
    @test isinf(background.depth[16,20])

    for bad in (NaN, Inf, -Inf)
        invalid = appearance_geometry(endpoints;distances=[0.0,bad])
        @test_throws "lineDistance values must be finite real numbers" appearance_render(
            LineSegments(invalid,dashed_material),ortho)
        set_attribute!(invalid,:color,[bad,0.0,0.0,1.0,1.0,1.0],3)
        @test_throws "geometry :color components must be finite" appearance_render(LineSegments(invalid,LineBasicMaterial()),ortho)
        @test_throws "geometry :color components must be finite" appearance_render(PointsObject(invalid,PointsMaterial()),ortho)
    end
    for (scale,dash,gap) in ((0.0,1.0,1.0),(NaN,1.0,1.0),(1.0,NaN,1.0),
                            (1.0,1.0,-1.0),(1.0,0.0,0.0))
        invalid_material = LineDashedMaterial(Color3(1.0,1.0,1.0),1.0,scale,dash,gap,1.0,true,true)
        @test_throws ArgumentError appearance_render(LineSegments(distances_geo,invalid_material),ortho)
    end
    # An independent high-precision remainder oracle includes product overflow,
    # underflow, negative phase, period overflow, and zero-sized dashes.
    for (distance,scale,dash,gap) in ((1e308,1e308,0.3,0.7),
        (-1e308,1e308,1e-300,1e-300),(1e-308,1e-308,0.0,1e-300),
        (1e308,1.0,1e308,1e308),(0.0,1.0,0.0,1.0),
        (0.25,1.0,0.25,0.25),(0.375,1.0,0.25,0.25))
        expected_dash = setprecision(BigFloat,8192) do
            mod(BigFloat(distance)*BigFloat(scale),BigFloat(dash)+BigFloat(gap)) <= BigFloat(dash)
        end
        @test Diff3D._line_dash_visible(distance,scale,dash,gap) == expected_dash
    end
    helper_camera = PerspectiveCamera()
    helper_camera.position = Vec3(2.0,2.0,2.0)
    axes_image = appearance_render(AxesHelper(),helper_camera).color
    for channel in 1:3
        @test count(pixel -> axes_image[pixel,channel] > 0.5,
                    CartesianIndices(axes_image[:,:,1])) > 0
    end
end

if Base.JLOptions().opt_level > 0
    @testset "Cached primitive attributes allocate per draw" begin
        function cached_appearance_bytes(material, points; count=256,
                                         scalar_type=Float64, colored=true, fog=nothing)
            positions = Float64[]
            for i in 1:count
                append!(positions,[-0.75,i/count-0.5,0.0,0.75,i/count-0.5,0.0])
            end
            geometry = BufferGeometry(positions,Float64[],Float64[],Int[],2count,0)
            colored && set_attribute!(geometry,:color,repeat(scalar_type[1,0,0,0,0,1],count),3)
            set_attribute!(geometry,:lineDistance,repeat(scalar_type[0,1.5],count),1)
            scene = Scene(fog=fog)
            add!(scene,points ? PointsObject(geometry,material) : LineSegments(geometry,material))
            camera = OrthographicCamera();camera.position=Vec3(0.0,0.0,2.0)
            target=RenderTarget(32,32);cache=RenderCache()
            draw = points ? render_points! : render_lines!
            for _ in 1:3
                draw(target,scene,camera;cache=cache)
            end
            return @allocated draw(target,scene,camera;cache=cache)
        end
        for material in (LineBasicMaterial(),LineDashedMaterial()), count in (1,256),
            scalar_type in (Float32,Float64), colored in (false,true),
            fog in (nothing,Fog(),FogExp2())
            @test cached_appearance_bytes(material,false;count,scalar_type,colored,fog) <= 4096
        end
        @test cached_appearance_bytes(PointsMaterial(),true) <= 4096
    end
end
