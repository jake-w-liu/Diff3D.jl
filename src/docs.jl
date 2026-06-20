# --------------------------------------------------------------------------
# Public API docstrings.
#
# Implementation files keep the subsystem code compact; this file attaches
# Julia help-mode/Documenter docstrings to the broad exported surface.
# --------------------------------------------------------------------------

# `Base.Docs.hasdoc` was added in Julia 1.11; on older releases check the
# module's docstring metadata directly so existing docs are never clobbered.
@static if isdefined(Base.Docs, :hasdoc)
    const _hasdoc = Base.Docs.hasdoc
else
    _hasdoc(m::Module, s::Symbol) = haskey(Base.Docs.meta(m), Base.Docs.Binding(m, s))
end

const _API_TYPE_DOCS = Dict{Symbol,String}(
    :Vec2 => """
        Vec2(x, y)

    Two-component immutable vector. Supports arithmetic, `dot`, and use in UV
    coordinates and screen-space calculations.
    """,
    :Vec3 => """
        Vec3(x, y, z)

    Three-component immutable vector used for positions, directions, normals,
    scales, and RGB-like intermediate values. Arithmetic is allocation-light and
    compatible with `ForwardDiff.Dual` inputs.
    """,
    :Vec4 => """
        Vec4(x, y, z, w)

    Four-component homogeneous vector used by projection and clipping code.
    """,
    :Color3 => """
        Color3(r, g, b)
        Color3(0xffcc00)

    Linear RGB color with components conventionally in `[0, 1]`. Hex input uses
    sRGB byte ordering and returns normalized floating-point components.
    """,
    :Mat3 => """
        Mat3(elements)

    Column-major 3x3 matrix type used for compact linear transforms and normal
    calculations.
    """,
    :Mat4 => """
        Mat4()

    Column-major 4x4 transform/projection matrix. Access entries with
    `mat4_get(m, row, col)` using one-based row and column indices.
    """,
    :Quaternion => """
        Quaternion(x, y, z, w)

    Rotation quaternion used by cameras, scene graph transforms, animation, and
    interpolation. Use `quat_from_euler`, `quat_to_mat4`, and `quat_slerp` for
    common conversions.
    """,
    :Euler => """
        Euler(x, y, z[, order])

    Euler-angle rotation with explicit axis order. The positional `order`
    argument defaults to `:XYZ` when omitted. All six standard three.js
    orders are supported by `quat_from_euler`.
    """,
    :Object3D => """
        Object3D(; name="")

    Base mutable scene-graph node containing transform, visibility, parent, and
    child state. Use `add!`, `remove!`, `traverse`, and world-matrix helpers to
    manage hierarchy.
    """,
    :Scene => """
        Scene(; background=Color3(0,0,0), fog=nothing, name="Scene")

    Root render container. Stores children plus background and optional `Fog` or
    `FogExp2` configuration.
    """,
    :Group => """
        Group(; name="Group")

    Transform-only scene-graph container for organizing objects without adding
    geometry.
    """,
    :Mesh => """
        Mesh(geometry, material; kwargs...)

    Renderable triangle object combining a `BufferGeometry` and material. Meshes
    support hierarchy transforms, shadow flags, optional flat-shading override,
    and morph-target influences.
    """,
    :InstancedMesh => "Renderable mesh that draws one geometry/material pair at multiple instance transforms.",
    :LineObject => "Renderable line object with geometry and line material.",
    :PointsObject => "Renderable point-cloud object with geometry and point material.",
    :LineSegments => "Line object rendered as independent segment pairs.",
    :LineLoop => "Line object rendered as a closed polyline.",
    :Sprite => "Camera-facing billboard object rendered from a sprite material.",
    :LOD => "Level-of-detail object selecting child objects by camera distance.",
    :Bone => "Scene-graph bone node used by `Skeleton` and `SkinnedMesh`.",
    :Skeleton => "Collection of bones and inverse-bind matrices for skinning.",
    :SkinnedMesh => "Mesh whose vertices are transformed by weighted skeleton bones, with optional morph-target influences and attached/detached bind matrices.",
    :Layers => "32-bit visibility/picking mask compatible with three.js layers.",
    :Fog => "Linear scene fog with color, near distance, and far distance.",
    :FogExp2 => "Exponential-squared scene fog with color and density.",
    :PerspectiveCamera => "Perspective camera configured by field of view, aspect, near, and far planes.",
    :OrthographicCamera => "Orthographic camera configured by left/right/top/bottom bounds and near/far planes.",
    :StereoCamera => "Pair of perspective cameras offset for stereo rendering.",
    :CubeCamera => "Six-camera rig for cubemap-style capture directions.",
    :ArrayCamera => "Container for multiple sub-cameras rendered as an array.",
    :BufferAttribute => "Named flat vertex attribute with `data` and `item_size` fields.",
    :BufferGeometry => """
        BufferGeometry()
        BufferGeometry(positions, normals, uvs, indices, n_vertices, n_faces)

    Indexed triangle geometry stored in flat arrays. Positions, normals, and UVs
    use one-based Julia indexing; indices are one-based triangle indices.
    """,
    :BoxGeometry => "Axis-aligned box geometry with per-face normals and UVs.",
    :SphereGeometry => "UV sphere geometry with configurable width and height segments.",
    :PlaneGeometry => "Subdivided XY plane geometry with +Z normals.",
    :CylinderGeometry => "Cylinder/cone-family geometry with side and cap triangles.",
    :ConeGeometry => "Cone geometry built on the cylinder generator.",
    :TorusGeometry => "Torus geometry with radial and tubular segment controls.",
    :TorusKnotGeometry => "Torus-knot geometry sampled along a parametric knot curve.",
    :RingGeometry => "Flat annulus/ring geometry.",
    :CircleGeometry => "Flat filled circle geometry.",
    :PolyhedronGeometry => "Generic polyhedron geometry with optional subdivision/detail.",
    :IcosahedronGeometry => "Icosahedron-derived polyhedron geometry.",
    :OctahedronGeometry => "Octahedron-derived polyhedron geometry.",
    :TetrahedronGeometry => "Tetrahedron-derived polyhedron geometry.",
    :DodecahedronGeometry => "Dodecahedron-derived polyhedron geometry.",
    :LatheGeometry => "Surface of revolution generated from a 2D profile.",
    :TubeGeometry => "Tube swept along a path of `Vec3` points.",
    :ShapeGeometry => "Flat polygon geometry with optional holes.",
    :ExtrudeGeometry => "Extruded polygon geometry with side faces.",
    :CapsuleGeometry => "Capsule/capsule-like geometry with cylindrical body and round caps.",
    :MeshBasicMaterial => "Unlit mesh material with optional color, AO, light, and alpha maps, opacity, and side mode.",
    :MeshLambertMaterial => "Diffuse Lambert material with optional normal, AO, and light maps for light-dependent matte shading.",
    :MeshPhongMaterial => "Phong material with diffuse/specular highlights, optional normal, AO, and light maps, vertex colors, and local clipping planes.",
    :MeshStandardMaterial => "Metallic-roughness PBR-style material.",
    :MeshPhysicalMaterial => "Extended physical material with clearcoat, sheen, transmission, anisotropy, and related terms.",
    :MeshNormalMaterial => "Debug material visualizing interpolated normals as color.",
    :MeshToonMaterial => "Banded toon/diffuse material with optional albedo, alpha, and gradient-map sampling.",
    :MeshMatcapMaterial => "Matcap-style view-facing material approximation.",
    :MeshDepthMaterial => "Depth-visualization material with basic/RGBA/RGB/RG packing modes.",
    :SpriteMaterial => "Material for billboard sprites.",
    :LineBasicMaterial => "Constant-color material for line primitives.",
    :PointsMaterial => "Material for point primitives and point sprites.",
    :ShaderMaterial => "Material carrying an executable Julia fragment function for CPU rendering.",
    :Texture => "2D texture storing channel data, sampling mode, wrapping, color space, and mipmaps.",
    :DataTexture => "Texture backed directly by numeric array data.",
    :CanvasTexture => "Texture intended for generated/canvas-style image data.",
    :DepthTexture => "Single-channel depth texture.",
    :CubeTexture => "Six-face cubemap texture sampled by direction.",
    :AmbientLight => "Uniform scene light independent of direction.",
    :DirectionalLight => "Distant light with direction derived from its transform.",
    :PointLight => "Omnidirectional light with distance attenuation.",
    :SpotLight => "Cone light with angle, penumbra, and distance attenuation.",
    :HemisphereLight => "Sky/ground two-color ambient light.",
    :RectAreaLight => "Area-light approximation with rectangular dimensions.",
    :LightProbe => "Spherical-harmonic ambient probe.",
    :IESProfile => "Photometric intensity profile parsed from IES data.",
    :ShadowMap => "Depth map and camera metadata used for shadow visibility tests.",
    :RenderTarget => "CPU render buffer containing RGB color and depth arrays.",
    :RenderCache => "Reusable internal buffers for allocation-conscious rendering.",
    :EffectComposer => "Post-processing pipeline composed of image pass functions.",
    :BenchResult => "Benchmark summary returned by `benchmark_render`.",
    :SoftRasterizerConfig => "Configuration for differentiable soft rasterization.",
    :Ray => "Ray with origin and direction.",
    :Plane => "Plane represented by normal and constant.",
    :Box3 => "Axis-aligned 3D bounding box.",
    :BoundingSphere => "Bounding sphere with center and radius.",
    :Triangle => "Triangle utility type storing three `Vec3` vertices.",
    :Line3 => "Finite line segment between two `Vec3` endpoints.",
    :Spherical => "Spherical coordinate triple.",
    :Cylindrical => "Cylindrical coordinate triple.",
    :Frustum => "Camera frustum represented by six planes.",
    :Raycaster => "Scene-picking helper that intersects rays with meshes, lines, points, sprites, and layers.",
    :Intersection => "Raycast hit record with distance, point, object, and face data.",
    :OrbitControls => "Orbit/pan/zoom camera control state matching common three.js behavior.",
    :TrackballControls => "Trackball-style camera rotation state.",
    :FlyControls => "Free-flight translation and rotation control state.",
    :PointerLockControls => "Pointer-lock camera control state.",
    :DragControls => "State for dragging managed scene objects.",
    :TransformControls => "Translate/rotate/scale manipulator state for an attached object.",
    :Clock => "Monotonic elapsed/delta timer for animation updates.",
    :KeyframeTrack => "Generic keyframe track over scalar/vector-like values.",
    :NumberKeyframeTrack => "Scalar keyframe track.",
    :QuaternionKeyframeTrack => "Quaternion keyframe track using spherical or step interpolation.",
    :MorphWeightsKeyframeTrack => "Keyframe track for morph-target influence vectors.",
    :CubicSplineKeyframeTrack => "Cubic Hermite spline keyframe track.",
    :CubicSplineQuaternionKeyframeTrack => "Cubic spline quaternion keyframe track.",
    :CubicSplineMorphWeightsKeyframeTrack => "Cubic spline morph-weight keyframe track.",
    :AnimationClip => "Named collection of animation tracks with duration metadata.",
    :AnimationMixer => "Playback state applying clips to scene objects.",
    :GLTFAsset => "Structured result from `load_gltf_asset`/`load_glb_asset` with `scene` and `animations` fields.",
    :WebGLExportCase => "Named scene/camera case exported by `save_webgl_html`.",
    :ADVar => "Small reverse-mode automatic-differentiation scalar used by `reverse_gradient`."
)

const _API_FUNCTION_DOCS = Dict{Symbol,String}(
    :add! => "Add a child object to a parent scene-graph node, reparenting from any previous parent.",
    :remove! => "Remove a child object from a parent scene-graph node if present.",
    :traverse => "Visit an object and its descendants in depth-first order.",
    :collect_meshes => "Collect visible mesh-like objects under a scene-graph root, skipping subtrees whose root has `visible == false`.",
    :compute_local_matrix => "Return an object's local transform matrix from position, rotation, and scale.",
    :compute_world_matrix => "Return an object's world transform matrix by composing ancestor transforms.",
    :compute_world_matrices => "Build a cache of world matrices for a scene-graph subtree.",
    :projection_matrix => "Return the projection matrix for a camera.",
    :projection_matrix_from_params => "Construct a projection matrix directly from camera parameter values.",
    :view_matrix => "Return the camera view matrix.",
    :view_matrix_from_params => "Construct a view matrix directly from position, target, and up vectors.",
    :render! => "Render a scene and camera into a `RenderTarget` using the CPU rasterizer.",
    :render_tiled! => "Render a flat-shaded scene in scanline/tile bands for large images or bounded memory.",
    :render_pooled! => "Render flat opaque meshes using a reusable `RenderCache` to reduce repeated allocations.",
    :render_msaa! => "Render with multisample anti-aliasing and resolve into the target.",
    :render_to_rgb8 => "Convert a rendered image/target into 8-bit RGB data.",
    :clear! => "Clear a render target color and depth buffer.",
    :soft_render => "Differentiably rasterize triangles with soft coverage.",
    :soft_render_scene => "Differentiably rasterize a scene into an image array.",
    :differentiable_render => "Convenience differentiable render entry point for inverse-rendering workflows.",
    :inverse_render_optimize => "Optimize parameters against a target image using gradient descent.",
    :inverse_render_adam => "Optimize parameters against a target image using Adam.",
    :numerical_gradient => "Compute a finite-difference gradient for validation.",
    :reverse_gradient => "Compute a reverse-mode gradient for a scalar `ADVar` function.",
    :reverse_value_gradient => "Return both value and reverse-mode gradient.",
    :loss_mse => "Mean-squared image loss.",
    :loss_l1 => "Mean-absolute image loss.",
    :loss_ssim => "Structural-similarity loss/score helper for image comparisons.",
    :loss_silhouette_iou => "Silhouette intersection-over-union loss helper.",
    :save_ppm => "Write an RGB image as text PPM.",
    :save_ppm_binary => "Write an RGB image as binary PPM.",
    :save_png => "Write an RGB image as PNG.",
    :save_png_rgba => "Write an RGBA image as PNG.",
    :save_png16 => "Write a 16-bit PNG image.",
    :save_pdf => "Write a simple image PDF.",
    :save_webgl_html => "Export one or more scenes as a self-contained interactive WebGL HTML document.",
    :load_obj => "Load Wavefront OBJ geometry.",
    :load_obj_groups => "Load OBJ geometry with material/group assignments.",
    :load_mtl => "Load Wavefront MTL material definitions.",
    :load_stl => "Load STL geometry.",
    :save_stl_binary => "Write geometry as binary STL.",
    :load_png => "Decode PNG data into a texture-compatible image representation.",
    :load_gltf => "Load a glTF 2.0 file into scene objects.",
    :load_gltf_asset => "Load a glTF 2.0 asset with scenes, nodes, animations, cameras, and lights.",
    :load_glb => "Load a binary GLB 2.0 file.",
    :load_glb_asset => "Load a binary GLB 2.0 file into a structured `GLTFAsset`.",
    :parse_xyz => "Parse XYZ/XYZRGB point-cloud text into `BufferGeometry`.",
    :load_xyz => "Load XYZ/XYZRGB point-cloud geometry.",
    :load_ply => "Load ASCII or binary PLY geometry.",
    :compute_vertex_normals! => "Compute smooth vertex normals in-place for geometry.",
    :merge_geometries => "Merge multiple `BufferGeometry` values into one geometry.",
    :compute_bounding_box => "Compute an axis-aligned bounding box for geometry.",
    :compute_bounding_sphere => "Compute a bounding sphere for geometry.",
    :set_attribute! => "Attach or replace a named `BufferAttribute` on geometry.",
    :get_attribute => "Return a named geometry attribute.",
    :has_attribute => "Return whether a geometry attribute exists.",
    :add_group! => "Append a draw group to geometry.",
    :get_groups => "Return geometry draw groups.",
    :clear_groups! => "Remove all geometry draw groups.",
    :apply_morph_targets => "Apply morph-position target attributes to geometry vertices.",
    :apply_morph_normals => "Apply morph-normal target attributes to geometry normals.",
    :apply_morph_tangents => "Apply morph-tangent target attributes to geometry tangents.",
    :sample_texture => "Sample a 2D texture at UV coordinates.",
    :sample_texture_linear => "Sample a 2D texture with bilinear filtering.",
    :sample_texture_auto => "Sample a texture using its configured filtering and mip state.",
    :sample_texture_lod => "Sample a texture at an explicit mip level.",
    :sample_texture_aniso => "Approximate anisotropic texture sampling over UV derivatives.",
    :sample_cube => "Sample a cubemap by direction.",
    :sample_cube_lod => "Sample a cubemap by direction at an explicit mip level.",
    :generate_mipmaps! => "Generate texture mip levels in-place.",
    :checker_texture => "Create a procedural checker texture.",
    :grid_texture => "Create a procedural grid texture.",
    :texture_transform_uv => "Apply a texture transform to UV coordinates.",
    :texture_update_matrix! => "Update cached texture transform matrix fields.",
    :collect_lights => "Collect visible lights under a scene root, skipping subtrees whose root has `visible == false`.",
    :compute_shadow_map => "Render a light-space depth map for shadow testing.",
    :shadow_visibility => "Return shadow visibility for a world-space point.",
    :shade_lambert => "Evaluate Lambert diffuse shading.",
    :shade_phong => "Evaluate Phong diffuse/specular shading.",
    :shade_pbr => "Evaluate the package's PBR-style shading approximation.",
    :shade_mesh_faces => "Shade all mesh faces with a chosen material/lights configuration.",
    :shade_face => "Shade one geometry face.",
    :light_contribution => "Compute a light's contribution at a point.",
    :ray_triangle_intersect => "Intersect a ray with a triangle.",
    :set_from_camera! => "Configure a `Raycaster` ray from normalized device coordinates and a camera.",
    :raycast => "Intersect a raycaster with an object or scene subtree.",
    :orbit_update! => "Apply damping/auto-rotation updates to orbit controls.",
    :orbit_set! => "Set orbit-control spherical state.",
    :orbit_rotate! => "Rotate orbit controls by angular deltas.",
    :orbit_zoom! => "Zoom orbit controls by a scalar factor.",
    :orbit_pan! => "Pan orbit controls in view space.",
    :orbit_save_state! => "Save orbit-control state for later reset.",
    :orbit_reset! => "Restore the saved orbit-control state.",
    :trackball_save_state! => "Save trackball-control state for later reset.",
    :trackball_reset! => "Restore the saved trackball-control state.",
    :trackball_rotate! => "Apply trackball rotation deltas.",
    :trackball_zoom! => "Zoom trackball controls by a scalar factor.",
    :trackball_pan! => "Pan trackball controls in view space.",
    :fly_translate! => "Translate fly controls.",
    :fly_rotate! => "Rotate fly controls.",
    :pointerlock_lock! => "Mark pointer-lock controls as locked.",
    :pointerlock_unlock! => "Mark pointer-lock controls as unlocked.",
    :pointerlock_move! => "Apply pointer-lock mouse movement.",
    :drag_start! => "Start dragging a managed object.",
    :drag_pick_start! => "Start dragging the nearest raycast-managed object.",
    :drag_move! => "Move the active drag target.",
    :drag_end! => "End the current drag operation.",
    :transform_attach! => "Attach transform controls to an object.",
    :transform_detach! => "Detach transform controls.",
    :transform_set_mode! => "Set transform controls mode.",
    :transform_set_space! => "Set transform controls coordinate space.",
    :transform_set_enabled! => "Enable or disable transform-control application.",
    :transform_set_axis! => "Set the transform-control axis mask.",
    :transform_set_translation_snap! => "Set transform-control translation snap distance.",
    :transform_set_rotation_snap! => "Set transform-control rotation snap angle.",
    :transform_set_scale_snap! => "Set transform-control scale snap increment.",
    :transform_apply! => "Apply a transform-control delta.",
    :clock_elapsed => "Return elapsed clock time.",
    :clock_delta! => "Return delta time since the previous call and update the clock.",
    :sample_track => "Sample an animation track at time `t`.",
    :mixer_set_time! => "Set animation mixer time and apply track values.",
    :mixer_update! => "Advance animation mixer time and apply track values.",
    :interpolate_linear => "Linearly interpolate keyframed scalar/vector data.",
    :interpolate_catmull_rom => "Catmull-Rom interpolate keyframed values.",
    :bloom_pass => "Post-processing pass adding thresholded bloom.",
    :fxaa_pass => "Post-processing pass applying an FXAA-style filter.",
    :outline_pass => "Post-processing pass highlighting depth/color edges.",
    :ssao_pass => "Post-processing pass approximating screen-space ambient occlusion.",
    :bokeh_pass => "Post-processing pass approximating depth-of-field blur.",
    :grayscale_pass => "Post-processing pass converting RGB to grayscale.",
    :reinhard_pass => "Post-processing pass applying Reinhard tone mapping.",
    :aces_pass => "Post-processing pass applying ACES-style tone mapping.",
    :srgb_pass => "Post-processing pass converting linear RGB to sRGB.",
    :add_pass! => "Append a post-processing pass to an `EffectComposer`.",
    :compose => "Run an `EffectComposer` over an image.",
    :benchmark_render => "Benchmark rendering a scene and return a `BenchResult`.",
    :build_instanced_scene => "Build a synthetic instancing benchmark scene.",
    :scene_triangle_count => "Count triangles under a scene root.",
    :render_lines! => "Rasterize line objects into a target.",
    :render_points! => "Rasterize point objects into a target.",
    :render_sprites! => "Rasterize sprite objects into a target.",
    :parse_ies => "Parse an IES photometric profile.",
    :ies_candela => "Interpolate candela from an `IESProfile`.",
    :ies_intensity => "Return normalized IES intensity for an angle.",
    :base64_decode => "Decode base64 text into bytes.",
    :inflate => "Inflate DEFLATE-compressed bytes.",
    :zlib_inflate => "Inflate zlib-wrapped DEFLATE bytes."
)

const _GENERIC_DOCS = Dict{Symbol,String}(
    :dot => "Dot product for Diff3D.jl vector types.",
    :cross => "Cross product for `Vec3` values.",
    :norm => "Euclidean vector norm.",
    :normalize => "Return a unit vector, or zero for near-zero input.",
    :lerp => "Linear interpolation between values.",
    :distance => "Euclidean distance between two points.",
    :mat4_get => "Return one 1-based row/column entry from a `Mat4`.",
    :mat4_multiply => "Matrix product for two `Mat4` values.",
    :mat4_transform_vec4 => "Transform a homogeneous `Vec4` by a matrix.",
    :mat4_transform_point => "Transform a 3D point by a matrix with homogeneous divide.",
    :mat4_transform_direction => "Transform a direction by the linear part of a matrix.",
    :mat4_translation => "Construct a translation matrix.",
    :mat4_scaling => "Construct a scaling matrix.",
    :mat4_rotation_x => "Construct an X-axis rotation matrix.",
    :mat4_rotation_y => "Construct a Y-axis rotation matrix.",
    :mat4_rotation_z => "Construct a Z-axis rotation matrix.",
    :mat4_look_at => "Construct a view matrix looking from `eye` to `target`.",
    :mat4_perspective => "Construct a perspective projection matrix.",
    :mat4_orthographic => "Construct an orthographic projection matrix.",
    :mat4_inverse => "Return the inverse of a `Mat4`.",
    :mat4_transpose => "Return the transpose of a `Mat4`.",
    :quat_from_euler => "Convert Euler angles to a quaternion.",
    :quat_to_mat4 => "Convert a quaternion to a rotation matrix.",
    :quat_multiply => "Hamilton product of two quaternions.",
    :quat_normalize => "Return a normalized quaternion.",
    :quat_slerp => "Spherical linear interpolation between quaternions.",
    :quat_from_unit_vectors => "Quaternion rotating one unit vector to another.",
    :quat_dot => "Quaternion dot product.",
    :box3_expand_by_point => "Return a bounding box expanded to include a point.",
    :plane_distance_to_point => "Signed distance from a plane to a point.",
    :clamp_color => "Clamp color components to `[0, 1]`.",
    :triangle_normal => "Return a triangle normal.",
    :triangle_area => "Return a triangle area.",
    :triangle_centroid => "Return a triangle centroid.",
    :triangle_barycentric => "Return barycentric coordinates for a point relative to a triangle.",
    :triangle_contains_point => "Return whether a point lies inside a triangle.",
    :line3_delta => "Return segment delta vector.",
    :line3_length => "Return segment length.",
    :line3_center => "Return segment midpoint.",
    :line3_at => "Return point along segment at parameter `t`.",
    :line3_closest_point => "Return closest point on segment to a point.",
    :line3_closest_point_parameter => "Return closest-point parameter on segment.",
    :spherical_to_cartesian => "Convert spherical coordinates to `Vec3`.",
    :cartesian_to_spherical => "Convert `Vec3` to spherical coordinates.",
    :cylindrical_to_cartesian => "Convert cylindrical coordinates to `Vec3`.",
    :cartesian_to_cylindrical => "Convert `Vec3` to cylindrical coordinates.",
    :frustum_from_matrix => "Extract frustum planes from a clip matrix.",
    :frustum_contains_point => "Return whether a point is inside a frustum.",
    :frustum_intersects_sphere => "Return whether a sphere intersects a frustum.",
    :frustum_intersects_box => "Return whether a box intersects a frustum.",
    :get_position => "Return an object's position vector.",
    :get_rotation => "Return an object's Euler rotation.",
    :get_scale => "Return an object's scale vector.",
    :get_children => "Return an object's child vector.",
    :get_parent => "Return an object's parent or `nothing`.",
    :is_visible => "Return object visibility.",
    :object_layers => "Return or initialize an object's `Layers` mask.",
    :instanced_count => "Return the number of instances in an `InstancedMesh`.",
    :set_instance_matrix! => "Set one instance transform matrix.",
    :get_instance_matrix => "Return one instance transform matrix.",
    :collect_instanced => "Collect instanced mesh objects under a root.",
    :add_lod_level! => "Add an object/distance level to an `LOD`.",
    :lod_select => "Select an LOD child for a distance.",
    :lod_update! => "Update LOD visibility for a camera/object distance.",
    :calculate_inverses! => "Recompute a skeleton's inverse-bind matrices from current bone world transforms.",
    :skeleton_matrices => "Return bone skinning matrices for a skeleton.",
    :bind_skeleton! => "Bind a skeleton to a skinned mesh and update its bind matrix metadata.",
    :apply_skinning => "Apply morph targets, then linear blend skinning, to skinned-mesh vertices.",
    :layers_set! => "Set an object's layer mask.",
    :layers_enable! => "Enable one layer bit.",
    :layers_disable! => "Disable one layer bit.",
    :layers_toggle! => "Toggle one layer bit.",
    :layers_enable_all! => "Enable all layer bits.",
    :layers_disable_all! => "Disable all layer bits.",
    :layers_test => "Return whether two layer masks overlap.",
    :wireframe_geometry => "Build line geometry for all triangle edges.",
    :edges_geometry => "Build edge geometry for sharp/unique edges.",
    :get_vertex => "Return geometry vertex `i` as `Vec3`.",
    :get_normal => "Return geometry normal `i` as `Vec3`.",
    :get_face => "Return one triangle face as one-based vertex indices.",
    :compute_face_normal => "Compute one face normal from geometry positions.",
    :count_triangles => "Return the number of triangles in geometry.",
    :material_opacity => "Return material opacity.",
    :material_transparent => "Return material transparency flag.",
    :is_transparent_material => "Return whether a material should be alpha-composited.",
    :material_depth_test => "Return whether a material participates in depth testing.",
    :material_depth_write => "Return whether a material writes to the depth buffer.",
    :material_alpha_test => "Return a material's alpha-test cutoff.",
    :material_wireframe => "Return whether a material requests wireframe rendering.",
    :material_side => "Return material side/culling mode.",
    :edge_function => "Signed 2D edge function used by rasterization.",
    :tone_map_reinhard => "Apply Reinhard tone mapping.",
    :tone_map_aces => "Apply ACES-style tone mapping.",
    :srgb_encode => "Encode one linear component to sRGB.",
    :linear_to_srgb => "Convert linear RGB values to sRGB.",
    :srgb_to_linear => "Convert sRGB values to linear RGB.",
    :downsample => "Downsample an image by averaging.",
    :render_aa => "Render with supersampled anti-aliasing.",
    :sigmoid_approx => "Smooth sigmoid helper for differentiable coverage.",
    :signed_distance_to_triangle => "Signed distance from a point to a screen-space triangle.",
    :point_line_distance => "Distance from point to infinite line.",
    :point_segment_distance => "Distance from point to segment.",
    :vertex_render_fn => "Build a render function over vertex parameters.",
    :color_render_fn => "Build a render function over per-face color parameters.",
    :optimize_vertices => "Optimize geometry vertices against a target.",
    :optimize_face_colors => "Optimize face colors against a target.",
    :image_to_uint8 => "Convert image values to clamped `UInt8` data.",
    :render_target_to_image => "Return the color image from a render target.",
    :test_pattern => "Create a small deterministic image test pattern.",
    :TextureLoader => "Load an image texture from disk.",
    :AxesHelper => "Create axis helper geometry.",
    :GridHelper => "Create grid helper geometry.",
    :BoxHelper => "Create bounding-box helper geometry.",
    :CameraHelper => "Create camera-frustum helper geometry.",
    :DirectionalLightHelper => "Create directional-light helper geometry.",
    :PointLightHelper => "Create point-light helper geometry.",
    :SpotLightHelper => "Create spot-light helper geometry.",
    :HemisphereLightHelper => "Create hemisphere-light helper geometry.",
    :SkeletonHelper => "Create skeleton-line helper geometry.",
    :PlaneHelper => "Create plane helper geometry.",
    :PolarGridHelper => "Create polar-grid helper geometry.",
    :AbstractObject3D => "Abstract supertype for scene-graph objects.",
    :AbstractFog => "Abstract supertype for fog models.",
    :AbstractCamera => "Abstract supertype for camera objects.",
    :AbstractMaterial => "Abstract supertype for materials.",
    :AbstractLight => "Abstract supertype for lights.",
    :AbstractKeyframeTrack => "Abstract supertype for animation keyframe tracks."
)

for docs in (_API_TYPE_DOCS, _API_FUNCTION_DOCS, _GENERIC_DOCS)
    for (name, text) in docs
        isdefined(@__MODULE__, name) || continue
        _hasdoc(@__MODULE__, name) && continue
        @eval @doc $text $name
    end
end

nothing
