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

using LinearAlgebra: norm as la_norm, dot as la_dot, cross as la_cross
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
    quat_from_euler, quat_to_mat4, quat_multiply, quat_normalize,
    quat_slerp, quat_from_unit_vectors, quat_dot,
    Box3, BoundingSphere, Ray, Plane, box3_expand_by_point,
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
    LatheGeometry, TubeGeometry, ShapeGeometry, ExtrudeGeometry, CapsuleGeometry,
    wireframe_geometry, edges_geometry,
    get_vertex, get_normal, get_face, compute_face_normal,
    count_triangles, merge_geometries,
    set_attribute!, get_attribute, has_attribute,
    compute_bounding_box, compute_bounding_sphere,

    # Materials
    AbstractMaterial,
    MeshBasicMaterial, MeshLambertMaterial, MeshPhongMaterial,
    MeshStandardMaterial, MeshNormalMaterial,
    MeshPhysicalMaterial, MeshToonMaterial, MeshMatcapMaterial, MeshDepthMaterial,
    SpriteMaterial,
    LineBasicMaterial, PointsMaterial, ShaderMaterial,
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
    EffectComposer, add_pass!, compose,
    grayscale_pass, reinhard_pass, aces_pass, srgb_pass,
    BenchResult, benchmark_render, build_instanced_scene, scene_triangle_count,

    # Soft rasterizer
    SoftRasterizerConfig, soft_render, soft_render_scene,
    differentiable_render,
    sigmoid_approx, signed_distance_to_triangle,
    point_line_distance, point_segment_distance,

    # Losses
    loss_mse, loss_l1, loss_ssim, loss_silhouette_iou,

    # Controls / Animation / Helpers
    OrbitControls, orbit_set!, orbit_save_state!, orbit_reset!,
    orbit_rotate!, orbit_zoom!, orbit_pan!,
    TrackballControls, trackball_save_state!, trackball_reset!,
    trackball_rotate!, trackball_zoom!, trackball_pan!,
    FlyControls, fly_translate!, fly_rotate!,
    PointerLockControls, pointerlock_lock!, pointerlock_unlock!, pointerlock_move!,
    DragControls, drag_start!, drag_pick_start!, drag_move!, drag_end!,
    TransformControls, transform_attach!, transform_detach!, transform_set_mode!,
    transform_set_space!, transform_apply!,
    Clock, clock_elapsed, clock_delta!,
    KeyframeTrack, NumberKeyframeTrack, MorphWeightsKeyframeTrack, AnimationClip, AnimationMixer, mixer_set_time!, mixer_update!,
    CubicSplineKeyframeTrack, CubicSplineQuaternionKeyframeTrack,
    CubicSplineMorphWeightsKeyframeTrack,
    AxesHelper, GridHelper, BoxHelper, CameraHelper,
    DirectionalLightHelper, PointLightHelper,

    # Inverse rendering
    inverse_render_optimize, inverse_render_adam, numerical_gradient,
    vertex_render_fn, color_render_fn, optimize_vertices, optimize_face_colors,
    ADVar, reverse_gradient, reverse_value_gradient,

    # Textures
    Texture, DataTexture, CanvasTexture, DepthTexture, CubeTexture,
    sample_texture, sample_texture_lod, sample_cube, generate_mipmaps!,
    checker_texture, grid_texture, texture_transform_uv, texture_update_matrix!,

    # I/O
    save_ppm, save_ppm_binary, render_target_to_image, test_pattern,
    save_png, save_png_rgba, save_png16, save_pdf, image_to_uint8,
    WebGLExportCase, save_webgl_html,

    # Loaders
    compute_vertex_normals!, save_stl_binary, load_stl, load_obj,
    inflate, zlib_inflate, load_png, TextureLoader,
    load_mtl, load_obj_groups, base64_decode, load_gltf,
    GLTFAsset, load_gltf_asset, parse_xyz, load_xyz,

    # Audit round-2 feature additions (2026-05-29)
    orbit_update!, AbstractKeyframeTrack, QuaternionKeyframeTrack, sample_track,
    interpolate_catmull_rom,
    SpotLightHelper, HemisphereLightHelper, SkeletonHelper, PlaneHelper, PolarGridHelper,
    object_layers,
    sample_texture_linear, sample_texture_auto,
    add_group!, get_groups, clear_groups!, apply_morph_targets,
    apply_morph_normals, apply_morph_tangents,
    render_sprites!,

    # Audit round-2 SCOPED feature completions (2026-05-29)
    IESProfile, parse_ies, ies_candela, ies_intensity,
    sample_texture_aniso,
    bloom_pass, fxaa_pass, outline_pass, ssao_pass, bokeh_pass,
    load_glb, load_glb_asset, load_ply

end # module Diff3D
