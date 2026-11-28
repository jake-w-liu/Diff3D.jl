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
    :LineDashedMaterial => "Line material using `:lineDistance` attributes for dashed CPU and browser rendering.",
    :Sprite => "Camera-facing billboard object rendered from a sprite material.",
    :Bone => "Scene-graph bone node used by `Skeleton` and `SkinnedMesh`.",
    :SkinnedMesh => "Mesh whose vertices are transformed by weighted skeleton bones, with optional morph-target influences and attached/detached bind matrices.",
    :Layers => "32-bit visibility/picking mask compatible with three.js layers.",
    :Fog => "Linear scene fog with color, near distance, and far distance.",
    :FogExp2 => "Exponential-squared scene fog with color and density.",
    :StereoCamera => "Pair of perspective cameras offset for stereo rendering.",
    :ArrayCamera => "Container for multiple sub-cameras rendered as an array.",
    :BufferAttribute => "Named flat vertex attribute with `data` and `item_size` fields.",
    :BufferGeometry => """
        BufferGeometry()
        BufferGeometry(positions, normals, uvs, indices, n_vertices, n_faces)

    Indexed triangle geometry stored in flat arrays. Positions, normals, and UVs
    use one-based Julia indexing; indices are one-based triangle indices. Use
    `set_draw_range!` to restrict rendering to a one-based draw-entry range.
    """,
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
    :CatmullRomCurve => "Catmull-Rom spline curve with uniform, centripetal, or chordal parameterization.",
    :NURBSCurve => "Rational B-spline curve with weighted `Vec4` control points.",
    :NURBSSurface => "Tensor-product rational B-spline surface.",
    :NURBSVolume => "Tensor-product rational B-spline volume evaluator.",
    :CapsuleGeometry => "Capsule/capsule-like geometry with cylindrical body and round caps.",
    :MeshBasicMaterial => "Unlit mesh material with optional color, AO, light, and alpha maps, opacity, and side mode.",
    :MeshLambertMaterial => "Diffuse Lambert material with optional normal, AO, and light maps for light-dependent matte shading.",
    :MeshPhongMaterial => "Phong material with diffuse/specular highlights, optional specular/glossiness, normal, AO, and light maps, vertex colors, and local clipping planes.",
    :MeshStandardMaterial => "Metallic-roughness PBR-style material.",
    :MeshPhysicalMaterial => "Extended physical material with clearcoat, sheen, transmission, anisotropy, and related terms.",
    :MeshNormalMaterial => "Debug material visualizing interpolated normals as color.",
    :MeshToonMaterial => "Banded toon/diffuse material with optional albedo, alpha, normal, AO, light, emissive, and gradient-map sampling.",
    :MeshMatcapMaterial => "Matcap-style view-facing material approximation with optional albedo, alpha, normal, matcap, and wireframe fields.",
    :MeshDepthMaterial => "Depth-visualization material with basic/RGBA/RGB/RG packing modes plus map alpha, alpha-map, and wireframe fields.",
    :SpriteMaterial => "Material for billboard sprites.",
    :LineBasicMaterial => "Constant-color material for line primitives.",
    :PointsMaterial => "Material for square point sprites. Size is in render-target pixels; depth attenuation applies to perspective cameras.",
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
    :RenderTarget => "CPU render buffer containing RGB color and depth arrays.",
    :EffectComposer => "Post-processing pipeline composed of image pass functions.",
    :BenchResult => "Benchmark summary returned by `benchmark_render`.",
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
    :FlyControls => "Free-flight translation and rotation control state.",
    :PointerLockControls => "Pointer-lock camera control state.",
    :DragControls => "State for dragging managed scene objects.",
    :TransformControls => "Translate/rotate/scale manipulator state for an attached object.",
    :KeyframeTrack => "Generic keyframe track over scalar/vector-like values.",
    :NumberKeyframeTrack => "Scalar keyframe track.",
    :QuaternionKeyframeTrack => "Quaternion keyframe track using spherical or step interpolation.",
    :MorphWeightsKeyframeTrack => "Keyframe track for morph-target influence vectors.",
    :CubicSplineKeyframeTrack => "Cubic Hermite spline keyframe track.",
    :CubicSplineQuaternionKeyframeTrack => "Cubic spline quaternion keyframe track.",
    :CubicSplineMorphWeightsKeyframeTrack => "Cubic spline morph-weight keyframe track.",
    :GLTFAsset => "Structured result from `load_gltf_asset`/`load_glb_asset` with `scene` and `animations` fields.",
    :WebGLExportCase => "Named scene/camera case exported by `save_webgl_html`.",
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
    :projection_matrix_from_params => "Construct a perspective projection matrix from scalar `fov` (radians), `aspect`, `near`, and `far`, preserving differentiated scalar types.",
    :view_matrix => "Return the camera view matrix.",
    :view_matrix_from_params => "Construct a view matrix from the nine scalar components of the eye position, target, and up vector, preserving differentiated scalar types.",
    :clear! => "Clear a render target color and depth buffer.",
    :audio_duration => "Return the duration in seconds for decoded audio buffer data.",
    :get_attribute => "Return a named geometry attribute.",
    :has_attribute => "Return whether a geometry attribute exists.",
    :apply_morph_targets => "Apply morph-position target attributes to geometry vertices.",
    :texture_transform_uv => "Apply a texture transform to UV coordinates.",
    :collect_lights => "Collect visible lights under a scene root, skipping subtrees whose root has `visible == false`.",
    :shade_mesh_faces => "Shade all mesh faces with a chosen material/lights configuration. Pass `camera_view=view_matrix(camera)` for camera-oriented depth output and camera-roll-aware textured matcap lookup; without it, depth uses the default view from `cam_pos` and matcap lookup assumes an unrolled world-Y-up camera. For orthographic two-sided shading, pass the camera's constant world-space backward direction as `ortho_dir`.",
    :shade_face => "Shade one geometry face. Textured `MeshMatcapMaterial` accepts `camera_view=view_matrix(camera)` for camera-roll-aware lookup.",
    :light_contribution => "Compute a light's contribution at a point.",
    :ray_triangle_intersect => "Intersect a ray with a triangle.",
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
    :grayscale_pass => "Post-processing pass converting RGB to grayscale.",
    :reinhard_pass => "Post-processing pass applying Reinhard tone mapping.",
    :aces_pass => "Post-processing pass applying ACES-style tone mapping.",
    :srgb_pass => "Post-processing pass converting linear RGB to sRGB.",
    :add_pass! => "Append a post-processing pass to an `EffectComposer`.",
    :render_lines! => "Rasterize line objects into a target.",
    :base64_decode => "Decode base64 text into bytes.",
)

const _GENERIC_DOCS = Dict{Symbol,String}(
    :dot => "Dot product for Diff3D.jl vector types.",
    :cross => "Cross product for `Vec3` values.",
    :norm => "Euclidean vector norm.",
    :normalize => "Return a `Vec3` divided by its length; a zero-length vector returns the zero vector.",
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
    :quat_dot => "Quaternion dot product.",
    :box3_expand_by_point => "Return a bounding box expanded to include a point.",
    :plane_distance_to_point => "Signed distance from a plane to a point.",
    :clamp_color => "Clamp color components to `[0, 1]`.",
    :triangle_normal => "Return a triangle normal.",
    :triangle_area => "Return a triangle area.",
    :triangle_centroid => "Return a triangle centroid.",
    :triangle_contains_point => "Return whether a point lies inside a triangle.",
    :line3_delta => "Return segment delta vector.",
    :line3_length => "Return segment length.",
    :line3_center => "Return segment midpoint.",
    :line3_at => "Return point along segment at parameter `t`.",
    :line3_closest_point => "Return closest point on segment to a point.",
    :spherical_to_cartesian => "Convert spherical coordinates to `Vec3`.",
    :cartesian_to_spherical => "Convert `Vec3` to spherical coordinates.",
    :cylindrical_to_cartesian => "Convert cylindrical coordinates to `Vec3`.",
    :cartesian_to_cylindrical => "Convert `Vec3` to cylindrical coordinates.",
    :frustum_contains_point => "Return whether a point is inside a frustum.",
    :frustum_intersects_sphere => "Return whether a sphere intersects a frustum.",
    :frustum_intersects_box => "Return whether a box intersects a frustum.",
    :get_position => "Return an object's position vector.",
    :get_rotation => "Return an object's Euler rotation.",
    :get_scale => "Return an object's scale vector.",
    :get_children => "Return an object's child vector.",
    :get_parent => "Return an object's parent or `nothing`.",
    :is_visible => "Return object visibility.",
    :instanced_count => "Return the number of instances in an `InstancedMesh`.",
    :set_instance_matrix! => "Set one instance transform matrix.",
    :get_instance_matrix => "Return one instance transform matrix.",
    :set_instance_color! => "Set one instance color multiplier.",
    :get_instance_color => "Return one instance color multiplier.",
    :collect_instanced => "Collect instanced mesh objects under a root.",
    :add_lod_level! => "Add an object/distance level to an `LOD`.",
    :calculate_inverses! => "Recompute a skeleton's inverse-bind matrices from current bone world transforms.",
    :bind_skeleton! => "Bind a skeleton to a skinned mesh and update its bind matrix metadata.",
    :layers_set! => "Set an object's layer mask.",
    :layers_enable! => "Enable one layer bit.",
    :layers_disable! => "Disable one layer bit.",
    :layers_toggle! => "Toggle one layer bit.",
    :layers_enable_all! => "Enable all layer bits.",
    :layers_disable_all! => "Disable all layer bits.",
    :catmull_rom_point => "Evaluate a `CatmullRomCurve` at a normalized parameter.",
    :catmull_rom_points => "Sample a `CatmullRomCurve` into evenly spaced parameter values.",
    :CatmullRomCurveGeometry => "Build polyline BufferGeometry sampled from a Catmull-Rom curve.",
    :nurbs_point => "Evaluate a NURBS curve, surface, or volume at normalized parameters.",
    :NURBSCurveGeometry => "Build polyline BufferGeometry sampled from a NURBS curve.",
    :csg_evaluate => "Dispatch a CSG boolean operation by symbol.",
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
    :tone_map_reinhard => "Apply Reinhard tone mapping.",
    :tone_map_aces => "Apply ACES-style tone mapping.",
    :linear_to_srgb => "Convert linear RGB values to sRGB.",
    :srgb_to_linear => "Convert sRGB values to linear RGB.",
    :image_to_uint8 => "Convert image values to clamped `UInt8` data.",
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
