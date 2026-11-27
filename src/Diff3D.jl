"""
    Diff3D

A differentiable three-dimensional graphics engine in Julia, mirroring the
three.js API with native automatic differentiation support.

Core subsystems:
- Math types (Vec2, Vec3, Vec4, Mat3, Mat4, Quaternion, Euler, Color3)
- Scene graph (Object3D, Scene, Group, Mesh)
- Geometries (Box, Sphere, Cylinder, Cone, Torus, Plane, ...)
- Materials (Basic, Lambert, Phong, Standard/PBR, Normal)
- Lights (Ambient, Directional, Point, Spot, Hemisphere)
- Cameras (Perspective, Orthographic)
- CPU rasterizer (z-buffer)
- Differentiable soft rasterizer (ForwardDiff compatible)
- Image loss functions (MSE, SSIM, Silhouette IoU)
- Inverse rendering optimizer (gradient descent, Adam)
"""
module Diff3D

using LinearAlgebra: norm as la_norm, dot as la_dot, cross as la_cross,
                     pinv as la_pinv
using Printf
using ForwardDiff

# ========================== Math ==========================
include("math.jl")

# ========================== Scene Graph ==========================
include("scene_graph.jl")

# ========================== Cameras ==========================
include("cameras.jl")

# ========================== Geometries ==========================
include("geometries.jl")
include("geometries_extra.jl")
include("teapot_geometry.jl")
include("csg.jl")

# ========================== Materials ==========================
include("materials.jl")

# ========================== Textures ==========================
include("textures.jl")

# ========================== Lights ==========================
include("lights.jl")

# ========================== Shading ==========================
include("shading.jl")

# ========================== CPU Rasterizer ==========================
include("rasterizer.jl")

# ========================== Objects (instancing, sprites, skinning) ==========================
include("objects.jl")

# ========================== Raycaster ==========================
include("raycaster.jl")

# ========================== Shadow mapping ==========================
include("shadows.jl")

# ========================== Renderer extras ==========================
include("renderer_extra.jl")

# ========================== Controls / Animation / Helpers ==========================
include("controls.jl")

# ========================== Benchmark / scaling ==========================
include("benchmark.jl")

# ========================== Soft Rasterizer ==========================
include("soft_rasterizer.jl")

# ========================== Losses ==========================
include("losses.jl")

# ========================== Inverse Rendering ==========================
include("inverse.jl")
include("reverse_ad.jl")
include("differentiable.jl")

# ========================== I/O ==========================
include("io.jl")
include("web_export.jl")

# ========================== Loaders ==========================
include("loaders.jl")
include("jpeg.jl")
include("loaders_extra.jl")

# ========================== API documentation ==========================
include("docs.jl")

# ========================== Exports ==========================
export
    # Math
    Vec2, Vec3, Vec4, Color3, Mat3, Mat4, Quaternion, Euler,
    dot, cross, norm, normalize, lerp, distance,
    mat4_get, mat4_multiply, mat4_transform_vec4, mat4_transform_point,
    mat4_transform_direction,
    mat4_translation, mat4_scaling, mat4_rotation_x, mat4_rotation_y, mat4_rotation_z,
    mat4_look_at, mat4_perspective, mat4_orthographic,
    mat4_inverse, mat4_transpose,
    mat4_compose, mat4_decompose, mat4_determinant,
    quat_from_euler, quat_to_mat4, quat_multiply, quat_normalize,
    quat_slerp, quat_from_unit_vectors, quat_dot, quat_from_rotation_matrix,
    quat_from_axis_angle, quat_conjugate, quat_invert, quat_angle_to,
    quat_rotate_towards, quat_rotate_vector,
    euler_from_rotation_matrix, euler_from_quaternion,
    Box3, BoundingSphere, Ray, Plane, box3_expand_by_point,
    box3_is_empty, box3_center, box3_size, box3_union, box3_intersect,
    box3_contains_point, box3_intersects_box, box3_apply_matrix4,
    plane_distance_to_point, clamp_color,
    Triangle, triangle_normal, triangle_area, triangle_centroid,
    triangle_barycentric, triangle_contains_point,
    Line3, line3_delta, line3_length, line3_center, line3_at,
    line3_closest_point, line3_closest_point_parameter,
    Spherical, spherical_to_cartesian, cartesian_to_spherical,
    Cylindrical, cylindrical_to_cartesian, cartesian_to_cylindrical,
    interpolate_linear,
    Frustum, frustum_from_matrix, frustum_contains_point,
    frustum_intersects_sphere, frustum_intersects_box,

    # Scene graph
    AbstractObject3D, Object3D, Scene, Group, Mesh, LineObject, PointsObject,
    AbstractFog, Fog, FogExp2,
    add!, remove!, traverse, collect_meshes,
    get_position, get_rotation, get_scale, get_children, get_parent,
    is_visible, compute_local_matrix, compute_world_matrix,
    compute_world_matrices,

    # Objects (§2 breadth)
    InstancedMesh, instanced_count, set_instance_matrix!, get_instance_matrix,
    set_instance_color!, get_instance_color,
    collect_instanced,
    LineSegments, LineLoop, Sprite, sprite_world_matrix,
    LOD, add_lod_level!, lod_select, lod_update!,
    Bone, Skeleton, calculate_inverses!, skeleton_matrices, SkinnedMesh,
    bind_skeleton!, apply_skinning,
    Layers, layers_set!, layers_enable!, layers_disable!, layers_toggle!,
    layers_enable_all!, layers_disable_all!, layers_test,

    # Raycaster
    Raycaster, Intersection, ray_triangle_intersect, set_from_camera!, raycast,

    # Cameras
    AbstractCamera, PerspectiveCamera, OrthographicCamera,
    StereoCamera, stereo_update!, CubeCamera, ArrayCamera,
    projection_matrix, view_matrix,
    view_matrix_from_params, projection_matrix_from_params,

    # Geometries
    BufferAttribute, BufferGeometry,
    BoxGeometry, SphereGeometry, PlaneGeometry, CylinderGeometry,
    ConeGeometry, TorusGeometry, TorusKnotGeometry, RingGeometry,
    CircleGeometry, IcosahedronGeometry,
    PolyhedronGeometry, OctahedronGeometry, TetrahedronGeometry, DodecahedronGeometry,
    ConvexGeometry, LatheGeometry, TubeGeometry, ShapeGeometry, ExtrudeGeometry, TextGeometry,
    CatmullRomCurve, catmull_rom_point, catmull_rom_points, CatmullRomCurveGeometry,
    NURBSCurve, NURBSSurface, NURBSVolume, nurbs_point,
    NURBSCurveGeometry, NURBSSurfaceGeometry, ParametricGeometry,
    TeapotGeometry,
    CapsuleGeometry,
    wireframe_geometry, edges_geometry,
    get_vertex, get_normal, get_face, compute_face_normal,
    count_triangles, merge_geometries, merge_vertices,
    set_attribute!, get_attribute, has_attribute,
    compute_line_distances!,
    compute_bounding_box, compute_bounding_sphere,
    csg_union, csg_subtract, csg_intersect, csg_evaluate, transform_geometry,

    # Materials
    AbstractMaterial,
    MeshBasicMaterial, MeshLambertMaterial, MeshPhongMaterial,
    MeshStandardMaterial, MeshNormalMaterial,
    MeshPhysicalMaterial, MeshToonMaterial, MeshMatcapMaterial, MeshDepthMaterial,
    SpriteMaterial,
    LineBasicMaterial, LineDashedMaterial, PointsMaterial, ShaderMaterial,
    material_opacity, material_transparent, is_transparent_material,
    material_depth_test, material_depth_write, material_alpha_test, material_wireframe,

    # Lights
    AbstractLight, AmbientLight, DirectionalLight, PointLight,
    SpotLight, HemisphereLight, RectAreaLight, LightProbe, collect_lights,
    ShadowMap, compute_shadow_map, shadow_visibility,

    # Shading
    shade_lambert, shade_phong, shade_pbr,
    shade_mesh_faces, shade_face, light_contribution,

    # Rasterizer
    RenderTarget, clear!, render!, render_to_rgb8, edge_function,
    material_side, render_tiled!,
    RenderCache, render_pooled!, render_msaa!,
    tone_map_reinhard, tone_map_aces, srgb_encode, linear_to_srgb, srgb_to_linear,
    downsample, render_aa,
    render_lines!, render_points!,
    EffectComposer, add_pass!, compose, tone_map, output_pass,
    grayscale_pass, reinhard_pass, aces_pass, srgb_pass,
    BenchResult, benchmark_render, build_instanced_scene, scene_triangle_count,

    # Soft rasterizer
    SoftRasterizerConfig, SoftRenderWorkspace, SoftRenderSceneWorkspace,
    soft_render, soft_render_scene,
    differentiable_render,
    sigmoid_approx, signed_distance_to_triangle,
    point_line_distance, point_segment_distance,

    # Losses
    loss_mse, loss_l1, loss_ssim, loss_silhouette_iou,

    # Controls / Animation / Helpers
    OrbitControls, MapControls, orbit_set!, orbit_save_state!, orbit_reset!,
    orbit_rotate!, orbit_zoom!, orbit_pan!,
    TrackballControls, trackball_save_state!, trackball_reset!,
    trackball_rotate!, trackball_zoom!, trackball_pan!,
    FlyControls, fly_translate!, fly_rotate!,
    PointerLockControls, pointerlock_lock!, pointerlock_unlock!, pointerlock_move!,
    DragControls, drag_start!, drag_pick_start!, drag_move!, drag_end!,
    TransformControls, transform_attach!, transform_detach!, transform_set_mode!,
    transform_set_space!, transform_set_enabled!, transform_set_axis!,
    transform_set_translation_snap!, transform_set_rotation_snap!,
    transform_set_scale_snap!, transform_apply!,
    Clock, clock_elapsed, clock_delta!,
    KeyframeTrack, NumberKeyframeTrack, MorphWeightsKeyframeTrack, AnimationClip, AnimationMixer, mixer_set_time!, mixer_update!,
    CubicSplineKeyframeTrack, CubicSplineQuaternionKeyframeTrack,
    CubicSplineMorphWeightsKeyframeTrack,
    AxesHelper, GridHelper, BoxHelper, Box3Helper, ArrowHelper, CameraHelper,
    DirectionalLightHelper, PointLightHelper,

    # Inverse rendering
    inverse_render_optimize, inverse_render_adam, numerical_gradient,
    vertex_render_fn, color_render_fn, optimize_vertices, optimize_face_colors,
    ADVar, reverse_gradient, reverse_value_gradient,

    # Textures
    Texture, DataTexture, CanvasTexture, DepthTexture, CubeTexture,
    sample_texture, sample_texture_lod, sample_cube, sample_cube_lod,
    equirectangular_to_cubemap, generate_mipmaps!,
    PMREM, generate_pmrem, sample_pmrem,
    checker_texture, grid_texture, texture_transform_uv, texture_update_matrix!,

    # I/O
    save_ppm, save_ppm_binary, render_target_to_image, test_pattern,
    save_png, save_png_rgba, save_png16, save_pdf, image_to_uint8,
    WebGLExportCase, save_webgl_html,

    # Loaders
    compute_vertex_normals!, compute_tangents!, save_stl_binary, save_stl_ascii,
    save_obj, save_ply, load_stl, load_obj,
    inflate, zlib_inflate, load_png, load_jpeg, load_ktx2, load_image,
    load_rgbe, load_hdr, TextureLoader, RGBELoader, load_exr, EXRLoader,
    AudioBufferData, audio_duration, load_wav, load_audio, AudioLoader,
    FontCommand, FontGlyph, FontData, load_font, FontLoader,
    font_glyph_shapes, font_text_shapes, font_kerning,
    SVGStyle, SVGPath, SVGDocument, load_svg, SVGLoader, svg_shapes,
    svg_geometry, points_to_stroke_geometry,
    svg_meshes, svg_strokes, svg_stroke_meshes,
    load_mtl, load_obj_groups, base64_decode, load_gltf,
    GLTFAsset, load_gltf_asset, parse_xyz, load_xyz,

    # Audit round-2 feature additions (2026-05-29)
    orbit_update!, AbstractKeyframeTrack, QuaternionKeyframeTrack, sample_track,
    interpolate_catmull_rom,
    SpotLightHelper, HemisphereLightHelper, SkeletonHelper, PlaneHelper, PolarGridHelper,
    object_layers,
    sample_texture_linear, sample_texture_auto,
    add_group!, get_groups, clear_groups!, set_draw_range!, get_draw_range,
    clear_draw_range!, apply_morph_targets,
    apply_morph_normals, apply_morph_tangents,
    render_sprites!,

    # Audit round-2 SCOPED feature completions (2026-05-29)
    IESProfile, parse_ies, ies_candela, ies_intensity,
    sample_texture_aniso,
    bloom_pass, fxaa_pass, outline_pass, ssao_pass, bokeh_pass,
    load_glb, load_glb_asset, load_ply

# ========================== Exports added in 1.2 ==========================
export
    # Lights
    light_probe_from_cube_texture,

    # Geometry
    apply_matrix4!, apply_quaternion!, rotate_geometry_x!, rotate_geometry_y!,
    rotate_geometry_z!, translate_geometry!, scale_geometry!, look_at_geometry!,
    center_geometry!, to_non_indexed, normalize_normals!, set_from_points!,
    delete_attribute!, estimate_bytes_used, merge_groups!, to_triangles_draw_mode!,
    to_creased_normals, ParametricFunctions, RoundedBoxGeometry, BoxLineGeometry,
    DecalGeometry, Curve, LineCurve, LineCurve3, QuadraticBezierCurve,
    QuadraticBezierCurve3, CubicBezierCurve, CubicBezierCurve3, EllipseCurve,
    ArcCurve, SplineCurve, CurvePath, Path, Shape, ShapePath, get_point,
    get_point_at, get_points, get_spaced_points, get_length, get_lengths,
    get_u_to_t_mapping, get_tangent, get_tangent_at, compute_frenet_frames,
    close_path!, move_to!, line_to!, quadratic_curve_to!, bezier_curve_to!,
    spline_thru!, arc!, absarc!, ellipse!, absellipse!, get_points_holes,
    extract_points, to_shapes,

    # Cameras
    CameraView, set_view_offset!, clear_view_offset!, get_film_width,
    get_film_height, get_focal_length, set_focal_length!, get_effective_fov,
    get_view_bounds, get_view_size, vec3_project, vec3_unproject,

    # Scene graph
    look_at!, rotate_on_axis!, rotate_on_world_axis!, rotate_x!, rotate_y!,
    rotate_z!, translate_on_axis!, translate_x!, translate_y!, translate_z!,
    local_to_world, world_to_local, get_world_position, get_world_quaternion,
    get_world_scale, get_world_direction, traverse_visible, traverse_ancestors,
    get_object_by_property, get_object_by_name, get_object_by_id, attach!,
    remove_from_parent!, clear_children!,

    # Math
    vec3_distance_squared, vec3_manhattan_distance, vec3_angle_to,
    vec3_project_on_vector, vec3_project_on_plane, vec3_reflect, vec3_clamp_length,
    vec3_apply_axis_angle, vec3_apply_euler, vec3_min, vec3_max, vec3_clamp,
    mat4_max_scale_on_axis, mat4_get_position, mat4_get_scale, mat4_get_column,
    mat4_set_position, mat4_make_basis, mat4_extract_basis, mat4_extract_rotation,
    mat4_make_rotation_axis, mat4_make_shear, mat3_from_mat4, mat3_determinant,
    mat3_transpose, mat3_inverse, mat3_normal_matrix, mat3_set_uv_transform,
    mat3_transform_vec3, sphere_is_empty, sphere_contains_point,
    sphere_distance_to_point, sphere_intersects_sphere, sphere_intersects_plane,
    sphere_intersects_box, sphere_clamp_point, sphere_bounding_box,
    sphere_apply_matrix4, sphere_expand_by_point, sphere_union, box3_clamp_point,
    box3_distance_to_point, box3_bounding_sphere, box3_intersects_sphere,
    box3_intersects_plane, plane_from_normal_and_coplanar_point,
    plane_from_coplanar_points, plane_normalize, plane_project_point,
    plane_coplanar_point, plane_intersect_line, plane_intersects_line,
    plane_intersects_box, plane_intersects_sphere, plane_apply_matrix4, ray_at,
    ray_closest_point_to_point, ray_distance_sq_to_point, ray_distance_to_point,
    ray_distance_sq_to_segment, ray_intersect_sphere, ray_intersects_sphere,
    ray_distance_to_plane, ray_intersect_plane, ray_intersects_plane,
    ray_intersect_box, ray_intersects_box, ray_apply_matrix4, triangle_plane,
    triangle_is_front_facing, triangle_closest_point_to_point, map_linear,
    inverse_lerp, damp, pingpong, smoothstep, smootherstep,

    # Controls / Animation
    clock_start!, clock_stop!, FrameTimer, timer_update!, timer_reset!, timer_delta,
    timer_elapsed, mixer_reset!, mixer_stop!, mixer_play!, mixer_is_running,
    mixer_is_scheduled, mixer_set_loop!, track_shift!, track_scale!, track_trim,
    track_optimize, track_validate, clip_reset_duration, clip_trim, clip_optimize,
    clip_validate, clip_find_by_name, clip_subclip, clip_from_morph_target_sequence,
    clips_from_morph_target_sequences,

    # Loaders
    load_obj_scene, save_gltf

end # module Diff3D
