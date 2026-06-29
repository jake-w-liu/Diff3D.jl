# --------------------------------------------------------------------------
# Browser/WebGL export for interactive examples.
#
# The exporter serializes Diff3D.jl scene objects into a standalone HTML file
# with a small generic WebGL runtime. Scene construction, geometry generation,
# materials, transforms, instancing, and keyframe clips come from Diff3D.jl.
# --------------------------------------------------------------------------

struct WebGLExportCase
    id::String
    title::String
    subtitle::String
    scene::Scene
    target::Vec3{Float64}
    radius::Float64
    height::Float64
    fov::Float64
    tone_mapping::Symbol
    tone_exposure::Float64
    output_color_space::Symbol
    animations::Vector{AnimationClip}
    clipping_planes::Vector{Plane{Float64}}
    camera::Union{Nothing, AbstractCamera, ArrayCamera}
end

function WebGLExportCase(id::String, title::String, subtitle::String, scene::Scene;
                         target=Vec3(0.0, 0.0, 0.0), radius::Real=8.0,
                         height::Real=3.0, fov::Real=pi/4,
                         tone_mapping::Symbol=:none,
                         tone_exposure::Real=1.0,
                         output_color_space::Symbol=:srgb,
                         animations::AbstractVector{AnimationClip}=AnimationClip[],
                         clipping_planes::AbstractVector{<:Plane}=Plane{Float64}[],
                         camera=nothing)
    _web_tone_mapping_id(tone_mapping)
    _web_output_color_space_id(output_color_space)
    camera === nothing || camera isa AbstractCamera || camera isa ArrayCamera ||
        throw(ArgumentError("WebGLExportCase camera must be nothing, PerspectiveCamera, OrthographicCamera, or ArrayCamera"))
    exposure = Float64(tone_exposure)
    (isfinite(exposure) && exposure >= 0.0) ||
        throw(ArgumentError("tone_exposure must be finite and non-negative"))
    WebGLExportCase(id, title, subtitle, scene, target, Float64(radius),
                    Float64(height), Float64(fov), tone_mapping, exposure,
                    output_color_space,
                    collect(AnimationClip, animations),
                    [Plane(Vec3(Float64(p.normal.x), Float64(p.normal.y), Float64(p.normal.z)),
                           Float64(p.constant)) for p in clipping_planes],
                    camera)
end

function _web_tone_mapping_id(tone_mapping::Symbol)
    tone_mapping === :none && return 0
    tone_mapping === :linear && return 1
    tone_mapping === :reinhard && return 2
    tone_mapping === :aces && return 3
    throw(ArgumentError("unsupported WebGL export tone_mapping: $tone_mapping"))
end

function _web_output_color_space_id(output_color_space::Symbol)
    output_color_space === :linear && return 0
    output_color_space === :srgb && return 1
    throw(ArgumentError("unsupported WebGL export output_color_space: $output_color_space"))
end

# Escape `<` to its \uXXXX form so no embedded user string can trip the HTML
# script-data tokenizer (`</script`, or the `<!--<script` double-escape entry)
# and break the surrounding <script> block. `<` is exactly `<` inside a JS
# string literal, so the decoded value is preserved.
_js_str(s::AbstractString) = "\"" * replace(s,
    "\\"=>"\\\\", "\""=>"\\\"", "\b"=>"\\b", "\f"=>"\\f", "\n"=>"\\n",
    "\r"=>"\\r", "\t"=>"\\t", "<"=>"\\u003c") * "\""
_js_num(x::Real) = isfinite(Float64(x)) ? @sprintf("%.17g", Float64(x)) : "0"
_js_array(xs) = "[" * join((_js_num(x) for x in xs), ",") * "]"
_js_vec(v::Vec2) = "[" * _js_num(v.x) * "," * _js_num(v.y) * "]"
_js_vec(v::Vec3) = "[" * _js_num(v.x) * "," * _js_num(v.y) * "," * _js_num(v.z) * "]"
_js_quat(q::Quaternion) = "[" * _js_num(q.x) * "," * _js_num(q.y) * "," *
                          _js_num(q.z) * "," * _js_num(q.w) * "]"
_js_color(c::Color3) = "[" * _js_num(c.r) * "," * _js_num(c.g) * "," * _js_num(c.b) * "]"
_js_color_array(colors::AbstractVector{<:Color3}) =
    "[" * join((_js_color(c) for c in colors), ",") * "]"
_js_mat(m::Mat4) = _js_array(m.e)
_js_mat_array(ms::AbstractVector{<:Mat4}) = "[" * join((_js_mat(m) for m in ms), ",") * "]"
_js_plane(p::Plane) = "[" * _js_num(p.normal.x) * "," * _js_num(p.normal.y) * "," *
                      _js_num(p.normal.z) * "," * _js_num(p.constant) * "]"
_html_escape(s::AbstractString) = replace(s, "&"=>"&amp;", "<"=>"&lt;", ">"=>"&gt;", "\""=>"&quot;")
# Component-wise color product (three.js InstancedMesh per-instance color
# multiplies the material color).
_web_color_mul(a::Color3, b::Color3) = Color3(a.r * b.r, a.g * b.g, a.b * b.b)

function _web_material_color(mat)
    if hasproperty(mat, :color)
        return getproperty(mat, :color)
    elseif mat isa MeshNormalMaterial
        return Color3(0.62, 0.86, 1.0)
    else
        return Color3(1.0, 1.0, 1.0)
    end
end

_web_material_size(mat) = hasproperty(mat, :size) ? Float64(getproperty(mat, :size)) : 4.0
function _web_material_linewidth(mat)
    w = hasproperty(mat, :linewidth) ? Float64(getproperty(mat, :linewidth)) : 1.0
    return isfinite(w) && w > 0.0 ? w : 1.0
end
_web_material_line_dashed(mat) = mat isa LineDashedMaterial
_web_material_dash_size(mat) = mat isa LineDashedMaterial ? mat.dash_size : 1.0
_web_material_gap_size(mat) = mat isa LineDashedMaterial ? mat.gap_size : 0.0
_web_material_dash_scale(mat) = mat isa LineDashedMaterial ? mat.scale : 1.0
_web_material_glow(mat) = mat isa MeshBasicMaterial ? 0.35 : mat isa PointsMaterial ? 1.0 : 0.08
_web_material_opacity(mat) = hasproperty(mat, :opacity) ? clamp(Float64(getproperty(mat, :opacity)), 0.0, 1.0) : 1.0
_web_material_alpha_test(mat) =
    hasproperty(mat, :alpha_test) ? clamp(Float64(getproperty(mat, :alpha_test)), 0.0, 1.0) : 0.0
_web_material_alpha_texture(mat) =
    hasproperty(mat, :alpha_map) && getproperty(mat, :alpha_map) isa Texture ? getproperty(mat, :alpha_map) : nothing
_web_material_emissive_texture(mat) =
    hasproperty(mat, :emissive_map) && getproperty(mat, :emissive_map) isa Texture ? getproperty(mat, :emissive_map) : nothing
_web_material_ao_texture(mat) =
    hasproperty(mat, :ao_map) && getproperty(mat, :ao_map) isa Texture ? getproperty(mat, :ao_map) : nothing
_web_material_light_texture(mat) =
    hasproperty(mat, :light_map) && getproperty(mat, :light_map) isa Texture ? getproperty(mat, :light_map) : nothing
_web_material_roughness_texture(mat) =
    hasproperty(mat, :roughness_map) && getproperty(mat, :roughness_map) isa Texture ? getproperty(mat, :roughness_map) : nothing
_web_material_metalness_texture(mat) =
    hasproperty(mat, :metalness_map) && getproperty(mat, :metalness_map) isa Texture ? getproperty(mat, :metalness_map) : nothing
_web_material_normal_texture(mat) =
    hasproperty(mat, :normal_map) && getproperty(mat, :normal_map) isa Texture ? getproperty(mat, :normal_map) : nothing
_web_material_normal_scale(mat) =
    hasproperty(mat, :normal_scale) ? Float64(getproperty(mat, :normal_scale)) : 1.0
_web_material_matcap_texture(mat) =
    hasproperty(mat, :matcap) && getproperty(mat, :matcap) isa Texture ? getproperty(mat, :matcap) : nothing
_web_material_gradient_texture(mat) =
    hasproperty(mat, :gradient_map) && getproperty(mat, :gradient_map) isa Texture ? getproperty(mat, :gradient_map) : nothing
_web_material_clearcoat_texture(mat) =
    hasproperty(mat, :clearcoat_map) && getproperty(mat, :clearcoat_map) isa Texture ? getproperty(mat, :clearcoat_map) : nothing
_web_material_clearcoat_roughness_texture(mat) =
    hasproperty(mat, :clearcoat_roughness_map) && getproperty(mat, :clearcoat_roughness_map) isa Texture ? getproperty(mat, :clearcoat_roughness_map) : nothing
_web_material_clearcoat_normal_texture(mat) =
    hasproperty(mat, :clearcoat_normal_map) && getproperty(mat, :clearcoat_normal_map) isa Texture ? getproperty(mat, :clearcoat_normal_map) : nothing
_web_material_clearcoat_normal_scale(mat) =
    hasproperty(mat, :clearcoat_normal_scale) ? Float64(getproperty(mat, :clearcoat_normal_scale)) : 1.0
_web_material_transmission_texture(mat) =
    hasproperty(mat, :transmission_map) && getproperty(mat, :transmission_map) isa Texture ? getproperty(mat, :transmission_map) : nothing
_web_material_thickness_texture(mat) =
    hasproperty(mat, :thickness_map) && getproperty(mat, :thickness_map) isa Texture ? getproperty(mat, :thickness_map) : nothing
_web_material_sheen_color_texture(mat) =
    hasproperty(mat, :sheen_color_map) && getproperty(mat, :sheen_color_map) isa Texture ? getproperty(mat, :sheen_color_map) : nothing
_web_material_sheen_roughness_texture(mat) =
    hasproperty(mat, :sheen_roughness_map) && getproperty(mat, :sheen_roughness_map) isa Texture ? getproperty(mat, :sheen_roughness_map) : nothing
_web_material_iridescence_texture(mat) =
    hasproperty(mat, :iridescence_map) && getproperty(mat, :iridescence_map) isa Texture ? getproperty(mat, :iridescence_map) : nothing
_web_material_iridescence_thickness_texture(mat) =
    hasproperty(mat, :iridescence_thickness_map) && getproperty(mat, :iridescence_thickness_map) isa Texture ? getproperty(mat, :iridescence_thickness_map) : nothing
_web_material_specular_intensity_texture(mat) =
    hasproperty(mat, :specular_intensity_map) && getproperty(mat, :specular_intensity_map) isa Texture ? getproperty(mat, :specular_intensity_map) : nothing
_web_material_specular_color_texture(mat) =
    hasproperty(mat, :specular_color_map) && getproperty(mat, :specular_color_map) isa Texture ? getproperty(mat, :specular_color_map) :
    hasproperty(mat, :specular_map) && getproperty(mat, :specular_map) isa Texture ? getproperty(mat, :specular_map) : nothing
_web_material_glossiness_texture(mat) =
    hasproperty(mat, :glossiness_map) && getproperty(mat, :glossiness_map) isa Texture ? getproperty(mat, :glossiness_map) : nothing
_web_material_glossiness_packed(mat) =
    _web_material_glossiness_texture(mat) !== nothing &&
    _web_material_glossiness_texture(mat) === _web_material_specular_color_texture(mat)
_web_material_anisotropy_texture(mat) =
    hasproperty(mat, :anisotropy_map) && getproperty(mat, :anisotropy_map) isa Texture ? getproperty(mat, :anisotropy_map) : nothing
_web_material_env_texture(mat) =
    hasproperty(mat, :envmap) && getproperty(mat, :envmap) isa CubeTexture ? getproperty(mat, :envmap) : nothing
_web_material_clipping_planes(mat) =
    hasproperty(mat, :clipping_planes) ? getproperty(mat, :clipping_planes) : Plane{Float64}[]
_web_material_emissive_color(mat) =
    hasproperty(mat, :emissive) ? getproperty(mat, :emissive) : Color3(0.0, 0.0, 0.0)
_web_material_emissive_intensity(mat) =
    hasproperty(mat, :emissive_intensity) ? Float64(getproperty(mat, :emissive_intensity)) : 1.0
_web_material_ao_intensity(mat) =
    hasproperty(mat, :ao_map_intensity) ? Float64(getproperty(mat, :ao_map_intensity)) : 1.0
_web_material_light_intensity(mat) =
    hasproperty(mat, :light_map_intensity) ? Float64(getproperty(mat, :light_map_intensity)) : 1.0
_web_material_roughness(mat) =
    hasproperty(mat, :roughness) ? clamp(Float64(getproperty(mat, :roughness)), 0.0, 1.0) : 0.65
_web_material_metalness(mat) =
    hasproperty(mat, :metalness) ? clamp(Float64(getproperty(mat, :metalness)), 0.0, 1.0) : 0.0
_web_material_env_intensity(mat) =
    hasproperty(mat, :env_map_intensity) ? Float64(getproperty(mat, :env_map_intensity)) : 1.0
_web_material_clearcoat(mat) =
    hasproperty(mat, :clearcoat) ? clamp(Float64(getproperty(mat, :clearcoat)), 0.0, 1.0) : 0.0
_web_material_clearcoat_roughness(mat) =
    hasproperty(mat, :clearcoat_roughness) ? clamp(Float64(getproperty(mat, :clearcoat_roughness)), 0.0, 1.0) : 0.0
_web_material_transmission(mat) =
    hasproperty(mat, :transmission) ? clamp(Float64(getproperty(mat, :transmission)), 0.0, 1.0) : 0.0
_web_material_thickness(mat) =
    hasproperty(mat, :thickness) ? max(Float64(getproperty(mat, :thickness)), 0.0) : 0.0
_web_material_attenuation_distance(mat) =
    hasproperty(mat, :attenuation_distance) ? max(Float64(getproperty(mat, :attenuation_distance)), 0.0) : 0.0
_web_material_attenuation_color(mat) =
    hasproperty(mat, :attenuation_color) ? getproperty(mat, :attenuation_color) : Color3(1.0, 1.0, 1.0)
_web_material_ior(mat) =
    hasproperty(mat, :ior) ? max(Float64(getproperty(mat, :ior)), 1.0) : 1.5
_web_material_sheen(mat) =
    hasproperty(mat, :sheen) ? clamp(Float64(getproperty(mat, :sheen)), 0.0, 1.0) : 0.0
_web_material_sheen_color(mat) =
    hasproperty(mat, :sheen_color) ? getproperty(mat, :sheen_color) : Color3(1.0, 1.0, 1.0)
_web_material_sheen_roughness(mat) =
    hasproperty(mat, :sheen_roughness) ? clamp(Float64(getproperty(mat, :sheen_roughness)), 0.0, 1.0) : 1.0
_web_material_iridescence(mat) =
    hasproperty(mat, :iridescence) ? clamp(Float64(getproperty(mat, :iridescence)), 0.0, 1.0) : 0.0
_web_material_iridescence_ior(mat) =
    hasproperty(mat, :iridescence_ior) ? max(Float64(getproperty(mat, :iridescence_ior)), 1.0) : 1.3
_web_material_iridescence_thickness(mat) =
    hasproperty(mat, :iridescence_thickness) ? max(Float64(getproperty(mat, :iridescence_thickness)), 0.0) : 400.0
_web_material_specular_intensity(mat) =
    hasproperty(mat, :specular_intensity) ? clamp(Float64(getproperty(mat, :specular_intensity)), 0.0, 1.0) : 1.0
_web_material_specular_color(mat) =
    hasproperty(mat, :specular_color) ? getproperty(mat, :specular_color) :
    hasproperty(mat, :specular) ? getproperty(mat, :specular) : Color3(1.0, 1.0, 1.0)
_web_material_anisotropy(mat) =
    hasproperty(mat, :anisotropy) ? clamp(Float64(getproperty(mat, :anisotropy)), 0.0, 1.0) : 0.0
_web_material_anisotropy_rotation(mat) =
    hasproperty(mat, :anisotropy_rotation) ? Float64(getproperty(mat, :anisotropy_rotation)) : 0.0
_web_material_dispersion(mat) =
    hasproperty(mat, :dispersion) ? max(Float64(getproperty(mat, :dispersion)), 0.0) : 0.0
_web_material_shininess(mat) =
    hasproperty(mat, :shininess) ? max(Float64(getproperty(mat, :shininess)), 0.0001) : 32.0
_web_material_glossiness(mat) =
    hasproperty(mat, :glossiness) ? clamp(Float64(getproperty(mat, :glossiness)), 0.0, 1.0) :
    _phong_glossiness_from_shininess(_web_material_shininess(mat))

function _web_texture_average_color(tex::Texture)
    H, W, C = size(tex.data)
    (H > 0 && W > 0 && C > 0) || return Color3(0.0, 0.0, 0.0)
    n = Float64(H * W)
    channel_average(ch) = begin
        s = 0.0
        @inbounds for y in 1:H, x in 1:W
            v = tex.data[y, x, ch]
            s += isfinite(v) ? clamp(v, 0.0, 1.0) : 0.0
        end
        s / n
    end
    r = channel_average(1)
    g = C >= 2 ? channel_average(2) : r
    b = C >= 3 ? channel_average(3) : r
    return Color3(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0))
end

function _web_env_json(env)
    env isa CubeTexture || return "null"
    colors = join((_js_color(_web_texture_average_color(face)) for face in env.faces), ",")
    faces = join((_web_cube_face_json(face) for face in env.faces), ",")
    return "{\"colors\":[" * colors * "],\"faces\":[" * faces * "]}"
end

function _web_fog_json(fog)
    fog === nothing && return "null"
    if fog isa Fog
        return "{\"type\":\"linear\",\"color\":" * _js_color(fog.color) *
               ",\"near\":" * _js_num(fog.near) *
               ",\"far\":" * _js_num(fog.far) * "}"
    elseif fog isa FogExp2
        return "{\"type\":\"exp2\",\"color\":" * _js_color(fog.color) *
               ",\"density\":" * _js_num(fog.density) * "}"
    end
    return "null"
end

function _web_camera_json(camera)
    camera === nothing && return "null"
    if camera isa PerspectiveCamera
        return "{" *
               "\"type\":\"perspective\"" *
               ",\"id\":" * string(camera.id) *
               ",\"name\":" * _js_str(camera.name) *
               ",\"position\":" * _js_vec(camera.position) *
               ",\"target\":" * _js_vec(camera.target) *
               ",\"up\":" * _js_vec(camera.up) *
               ",\"fov\":" * _js_num(camera.fov) *
               ",\"aspect\":" * _js_num(camera.aspect) *
               ",\"near\":" * _js_num(camera.near) *
               # _js_num maps Inf -> "0"; emit the JS literal Infinity instead so
               # an infinite far clip plane (CPU-supported) is not silently turned
               # into far=0, which collapses the JS depth range.
               ",\"far\":" * (camera.far == Inf ? "Infinity" : _js_num(camera.far)) *
               ",\"zoom\":" * _js_num(camera.zoom) *
               "}"
    elseif camera isa OrthographicCamera
        return "{" *
               "\"type\":\"orthographic\"" *
               ",\"id\":" * string(camera.id) *
               ",\"name\":" * _js_str(camera.name) *
               ",\"position\":" * _js_vec(camera.position) *
               ",\"target\":" * _js_vec(camera.target) *
               ",\"up\":" * _js_vec(camera.up) *
               ",\"left\":" * _js_num(camera.left) *
               ",\"right\":" * _js_num(camera.right) *
               ",\"bottom\":" * _js_num(camera.bottom) *
               ",\"top\":" * _js_num(camera.top) *
               ",\"near\":" * _js_num(camera.near) *
               ",\"far\":" * _js_num(camera.far) *
               ",\"zoom\":" * _js_num(camera.zoom) *
               "}"
    elseif camera isa ArrayCamera
        length(camera.cameras) == length(camera.viewports) ||
            throw(ArgumentError("ArrayCamera cameras and viewports lengths must match"))
        cameras_json = join((_web_camera_json(cam) for cam in camera.cameras), ",")
        viewports_json = join((_js_array(viewport) for viewport in camera.viewports), ",")
        return "{" *
               "\"type\":\"array\"" *
               ",\"cameras\":[" * cameras_json * "]" *
               ",\"viewports\":[" * viewports_json * "]" *
               "}"
    end
    throw(ArgumentError("unsupported WebGL export camera type: $(typeof(camera))"))
end

_web_material_transparent(mat) =
    (hasproperty(mat, :transparent) && Bool(getproperty(mat, :transparent))) ||
    _web_material_opacity(mat) < 1.0
_web_material_side(mat) = hasproperty(mat, :side) ? String(getproperty(mat, :side)) : "front"
_web_material_depth_test(mat) =
    hasproperty(mat, :depth_test) ? Bool(getproperty(mat, :depth_test)) : true
_web_material_depth_write(mat) =
    hasproperty(mat, :depth_write) ? Bool(getproperty(mat, :depth_write)) : true
_web_material_depth_near(mat) =
    hasproperty(mat, :near) ? max(Float64(getproperty(mat, :near)), 1e-6) : 0.1
_web_material_depth_far(mat) =
    hasproperty(mat, :far) ? max(Float64(getproperty(mat, :far)), _web_material_depth_near(mat) + 1e-6) : 100.0
function _web_material_depth_packing(mat)
    hasproperty(mat, :depth_packing) || return "basic"
    p = getproperty(mat, :depth_packing)
    p === :rgba && return "rgba"
    p === :rgb && return "rgb"
    p === :rg && return "rg"
    return "basic"
end
function _web_material_depth_packing_id(mat)
    p = _web_material_depth_packing(mat)
    p == "rgba" && return 1
    p == "rgb" && return 2
    p == "rg" && return 3
    return 0
end
_web_material_toon_steps(mat) =
    hasproperty(mat, :gradient_steps) ? max(Float64(getproperty(mat, :gradient_steps)), 1.0) : 3.0
_web_material_sprite_rotation(mat) =
    hasproperty(mat, :rotation) ? Float64(getproperty(mat, :rotation)) : 0.0
_web_material_sprite_size_attenuation(mat) =
    hasproperty(mat, :size_attenuation) ? Bool(getproperty(mat, :size_attenuation)) : true
_web_material_point_size_attenuation(mat) =
    hasproperty(mat, :size_attenuation) ? Bool(getproperty(mat, :size_attenuation)) : true

function _web_texture_json(tex)
    tex isa Texture || return "null"
    tex.matrix_auto_update && texture_update_matrix!(tex)
    H, W, C = size(tex.data)
    (H > 0 && W > 0 && C > 0) || return "null"
    unit_byte(v) = round(Int, 255 * (isfinite(v) ? clamp(v, 0.0, 1.0) : 0.0))
    rgba = Int[]
    sizehint!(rgba, 4 * H * W)
    @inbounds for y in H:-1:1, x in 1:W
        r = tex.data[y, x, 1]
        g = C >= 2 ? tex.data[y, x, 2] : r
        b = C >= 3 ? tex.data[y, x, 3] : r
        a = C >= 4 ? tex.data[y, x, 4] : 1.0
        append!(rgba, (unit_byte(r), unit_byte(g), unit_byte(b), unit_byte(a)))
    end
    return "{" *
           "\"width\":" * string(W) *
           ",\"height\":" * string(H) *
           ",\"wrapS\":" * _js_str(String(tex.wrap_s)) *
           ",\"wrapT\":" * _js_str(String(tex.wrap_t)) *
           ",\"filter\":" * _js_str(String(tex.filter)) *
           ",\"minFilter\":" * _js_str(String(tex.min_filter)) *
           ",\"magFilter\":" * _js_str(String(tex.mag_filter)) *
           ",\"maxAnisotropy\":" * _js_num(tex.max_anisotropy) *
           ",\"colorspace\":" * _js_str(String(tex.colorspace)) *
           ",\"offset\":[" * _js_num(tex.offset.x) * "," * _js_num(tex.offset.y) * "]" *
           ",\"repeat\":[" * _js_num(tex.repeat.x) * "," * _js_num(tex.repeat.y) * "]" *
           ",\"rotation\":" * _js_num(tex.rotation) *
           ",\"center\":[" * _js_num(tex.center.x) * "," * _js_num(tex.center.y) * "]" *
           ",\"matrix\":[" * join((_js_num(x) for x in tex.matrix.e), ",") * "]" *
           ",\"matrixAutoUpdate\":" * (tex.matrix_auto_update ? "true" : "false") *
           ",\"texCoord\":" * string(tex.tex_coord) *
           ",\"needsUpdate\":" * (tex.needs_update ? "true" : "false") *
           ",\"data\":[" * join(rgba, ",") * "]" *
           "}"
end

function _web_cube_level_json(data::Array{Float64,3})
    H, W, C = size(data)
    (H > 0 && W > 0 && C > 0) || return "null"
    unit_byte(v) = round(Int, 255 * (isfinite(v) ? clamp(v, 0.0, 1.0) : 0.0))
    rgba = Int[]
    sizehint!(rgba, 4 * H * W)
    @inbounds for y in 1:H, x in 1:W
        r = data[y, x, 1]
        g = C >= 2 ? data[y, x, 2] : r
        b = C >= 3 ? data[y, x, 3] : r
        a = C >= 4 ? data[y, x, 4] : 1.0
        append!(rgba, (unit_byte(r), unit_byte(g), unit_byte(b), unit_byte(a)))
    end
    return "{" *
           "\"width\":" * string(W) *
           ",\"height\":" * string(H) *
           ",\"data\":[" * join(rgba, ",") * "]" *
           "}"
end

function _web_cube_face_json(tex)
    tex isa Texture || return "null"
    H, W, C = size(tex.data)
    (H > 0 && W > 0 && C > 0) || return "null"
    base = _web_cube_level_json(tex.data)
    base == "null" && return "null"
    mipmaps = join((_web_cube_level_json(mip) for mip in tex.mipmaps
                    if ndims(mip) == 3 && all(size(mip) .> 0)), ",")
    return base[1:end-1] *
           ",\"filter\":" * _js_str(String(tex.filter)) *
           ",\"minFilter\":" * _js_str(String(tex.min_filter)) *
           ",\"magFilter\":" * _js_str(String(tex.mag_filter)) *
           ",\"maxAnisotropy\":" * _js_num(tex.max_anisotropy) *
           ",\"colorspace\":" * _js_str(String(tex.colorspace)) *
           ",\"mipmaps\":[" * mipmaps * "]" *
           "}"
end

function _web_material_texture(mat)
    if hasproperty(mat, :map)
        tex = getproperty(mat, :map)
        tex isa Texture && return tex
    end
    return nothing
end

const WEB_SHADOW_RESOLUTION = 64
const WEB_MAX_SHADOW_PCF_RADIUS = 4

function _web_shadow_pcf_radius(light, fallback::Integer)
    r = _light_shadow_pcf_radius(light, fallback)
    r <= WEB_MAX_SHADOW_PCF_RADIUS ||
        throw(ArgumentError("compact WebGL shadow_pcf_radius supports 0:$(WEB_MAX_SHADOW_PCF_RADIUS), got $r"))
    return r
end

function _web_shadow_json(scene::Scene, light::Union{DirectionalLight,PointLight,SpotLight};
                          shadow_mode::Symbol=:static,
                          clipping_planes=_NO_PLANES)
    (hasproperty(light, :cast_shadow) && getproperty(light, :cast_shadow)) || return "null"
    shadow_mode === :none && return "null"
    if shadow_mode === :directional_dynamic || shadow_mode === :spot_dynamic ||
       shadow_mode === :point_dynamic
        if shadow_mode === :directional_dynamic
            light isa DirectionalLight || return "null"
            typ = "directionalDynamic"
        elseif shadow_mode === :spot_dynamic
            light isa SpotLight || return "null"
            typ = "spotDynamic"
        else
            light isa PointLight || return "null"
            typ = "pointDynamic"
        end
        pcf = _web_shadow_pcf_radius(light, shadow_mode === :point_dynamic ? 0 : 1)
        bias = _light_shadow_bias(light, 3e-3) * 0.5
        return "{" *
               "\"type\":" * _js_str(typ) *
               ",\"size\":" * string(WEB_SHADOW_RESOLUTION) *
               ",\"bias\":" * _js_num(bias) *
               ",\"pcfRadius\":" * string(pcf) *
               ",\"matrix\":" * _js_mat(Mat4()) *
               "}"
    end
    shadow_mode === :static || return "null"
    pcf = _web_shadow_pcf_radius(light, 1)
    sm = compute_shadow_map(scene, light; resolution=WEB_SHADOW_RESOLUTION,
                            bias=_light_shadow_bias(light, 3e-3), pcf_radius=pcf,
                            clipping_planes=clipping_planes)
    H, W = size(sm.depth)
    data = Int[]
    sizehint!(data, H * W)
    @inbounds for y in H:-1:1, x in 1:W
        d = sm.depth[y, x]
        z = isfinite(d) ? clamp((d + 1.0) * 0.5, 0.0, 1.0) : 1.0
        push!(data, round(Int, 255z))
    end
    return "{" *
           "\"type\":" * _js_str(light isa DirectionalLight ? "directionalStatic" :
                                 light isa PointLight ? "pointStatic" : "spotStatic") *
           ",\"size\":" * string(W) *
           ",\"bias\":" * _js_num(sm.bias * 0.5) *
           ",\"pcfRadius\":" * string(sm.pcf_radius) *
           ",\"matrix\":" * _js_mat(sm.light_vp) *
           ",\"data\":[" * join(data, ",") * "]" *
           "}"
end

function _web_visibility_chain(obj::AbstractObject3D)
    chain = AbstractObject3D[]
    current = obj
    while current !== nothing
        push!(chain, current)
        current = get_parent(current)
    end
    ids = Int[]
    values = Bool[]
    for item in reverse(chain)
        push!(ids, item.id)
        push!(values, is_visible(item))
    end
    return ids, values
end

function _web_visible_or_forced(obj::AbstractObject3D, force_ids::Set{Int})
    ids, values = _web_visibility_chain(obj)
    return all(values) || any(id -> id in force_ids, ids)
end

function _web_light_visibility_json(light::AbstractLight,
                                    visibility_target_ids::AbstractVector{Int},
                                    visibility_values::AbstractVector{Bool})
    ids = isempty(visibility_target_ids) ? [light.id] : visibility_target_ids
    values = isempty(visibility_values) ? [is_visible(light)] : visibility_values
    return ",\"visibilityStates\":" * _web_visibility_states_json(ids, values)
end

function _web_light_json(light::AmbientLight;
                         visibility_target_ids::AbstractVector{Int}=Int[],
                         visibility_values::AbstractVector{Bool}=Bool[],
                         shadow_mode::Symbol=:static,
                         clipping_planes=_NO_PLANES)
    return "{" *
           "\"type\":\"ambient\"" *
           ",\"id\":" * string(light.id) *
           ",\"name\":" * _js_str(light.name) *
           ",\"visible\":" * (is_visible(light) ? "true" : "false") *
           ",\"color\":" * _js_color(light.color) *
           ",\"intensity\":" * _js_num(light.intensity) *
           _web_light_visibility_json(light, visibility_target_ids, visibility_values) *
           "}"
end

function _web_light_json(light::DirectionalLight, scene::Scene;
                         visibility_target_ids::AbstractVector{Int}=Int[],
                         visibility_values::AbstractVector{Bool}=Bool[],
                         shadow_mode::Symbol=:static,
                         clipping_planes=_NO_PLANES)
    pos = get_position(light)
    target = light.target
    dir = normalize(pos - target)
    return "{" *
           "\"type\":\"directional\"" *
           ",\"id\":" * string(light.id) *
           ",\"name\":" * _js_str(light.name) *
           ",\"visible\":" * (is_visible(light) ? "true" : "false") *
           ",\"color\":" * _js_color(light.color) *
           ",\"intensity\":" * _js_num(light.intensity) *
           ",\"position\":" * _js_vec(pos) *
           ",\"target\":" * _js_vec(target) *
           ",\"direction\":" * _js_vec(dir) *
           ",\"castShadow\":" * (light.cast_shadow ? "true" : "false") *
           ",\"shadow\":" * _web_shadow_json(scene, light; shadow_mode=shadow_mode,
                                             clipping_planes=clipping_planes) *
           _web_light_visibility_json(light, visibility_target_ids, visibility_values) *
           "}"
end

function _web_light_json(light::PointLight, scene::Scene;
                         visibility_target_ids::AbstractVector{Int}=Int[],
                         visibility_values::AbstractVector{Bool}=Bool[],
                         shadow_mode::Symbol=:static,
                         clipping_planes=_NO_PLANES)
    return "{" *
           "\"type\":\"point\"" *
           ",\"id\":" * string(light.id) *
           ",\"name\":" * _js_str(light.name) *
           ",\"visible\":" * (is_visible(light) ? "true" : "false") *
           ",\"color\":" * _js_color(light.color) *
           ",\"intensity\":" * _js_num(light.intensity) *
           ",\"position\":" * _js_vec(get_position(light)) *
           ",\"distance\":" * _js_num(light.distance) *
           ",\"decay\":" * _js_num(light.decay) *
           ",\"castShadow\":" * (light.cast_shadow ? "true" : "false") *
           ",\"shadow\":" * _web_shadow_json(scene, light; shadow_mode=shadow_mode,
                                             clipping_planes=clipping_planes) *
           _web_light_visibility_json(light, visibility_target_ids, visibility_values) *
           "}"
end

function _web_light_json(light::SpotLight, scene::Scene;
                         visibility_target_ids::AbstractVector{Int}=Int[],
                         visibility_values::AbstractVector{Bool}=Bool[],
                         shadow_mode::Symbol=:static,
                         clipping_planes=_NO_PLANES)
    pos = get_position(light)
    target = light.target
    dir = normalize(target - pos)
    penumbra = clamp(Float64(light.penumbra), 0.0, 1.0)
    cone = clamp(Float64(light.angle), 0.0, pi)
    inner = cone * (1.0 - penumbra)
    return "{" *
           "\"type\":\"spot\"" *
           ",\"id\":" * string(light.id) *
           ",\"name\":" * _js_str(light.name) *
           ",\"visible\":" * (is_visible(light) ? "true" : "false") *
           ",\"color\":" * _js_color(light.color) *
           ",\"intensity\":" * _js_num(light.intensity) *
           ",\"position\":" * _js_vec(pos) *
           ",\"target\":" * _js_vec(target) *
           ",\"direction\":" * _js_vec(dir) *
           ",\"distance\":" * _js_num(light.distance) *
           ",\"decay\":" * _js_num(light.decay) *
           ",\"angle\":" * _js_num(light.angle) *
           ",\"penumbra\":" * _js_num(light.penumbra) *
           ",\"coneCos\":" * _js_num(cos(cone)) *
           ",\"penumbraCos\":" * _js_num(cos(inner)) *
           ",\"castShadow\":" * (light.cast_shadow ? "true" : "false") *
           ",\"shadow\":" * _web_shadow_json(scene, light; shadow_mode=shadow_mode,
                                             clipping_planes=clipping_planes) *
           _web_light_visibility_json(light, visibility_target_ids, visibility_values) *
           "}"
end

function _web_light_json(light::HemisphereLight;
                         visibility_target_ids::AbstractVector{Int}=Int[],
                         visibility_values::AbstractVector{Bool}=Bool[],
                         shadow_mode::Symbol=:static,
                         clipping_planes=_NO_PLANES)
    return "{" *
           "\"type\":\"hemisphere\"" *
           ",\"id\":" * string(light.id) *
           ",\"name\":" * _js_str(light.name) *
           ",\"visible\":" * (is_visible(light) ? "true" : "false") *
           ",\"color\":" * _js_color(light.color) *
           ",\"groundColor\":" * _js_color(light.ground_color) *
           ",\"intensity\":" * _js_num(light.intensity) *
           _web_light_visibility_json(light, visibility_target_ids, visibility_values) *
           "}"
end

function _web_light_json(light::RectAreaLight;
                         visibility_target_ids::AbstractVector{Int}=Int[],
                         visibility_values::AbstractVector{Bool}=Bool[],
                         shadow_mode::Symbol=:static,
                         clipping_planes=_NO_PLANES)
    pos = get_position(light)
    forward = normalize(light.target - pos)
    ref = abs(forward.y) < 0.95 ? Vec3(0.0, 1.0, 0.0) : Vec3(1.0, 0.0, 0.0)
    u = normalize(cross(ref, forward))
    v = cross(forward, u)
    return "{" *
           "\"type\":\"rectArea\"" *
           ",\"id\":" * string(light.id) *
           ",\"name\":" * _js_str(light.name) *
           ",\"visible\":" * (is_visible(light) ? "true" : "false") *
           ",\"color\":" * _js_color(light.color) *
           ",\"intensity\":" * _js_num(light.intensity) *
           ",\"position\":" * _js_vec(pos) *
           ",\"target\":" * _js_vec(light.target) *
           ",\"forward\":" * _js_vec(forward) *
           ",\"u\":" * _js_vec(u) *
           ",\"v\":" * _js_vec(v) *
           ",\"width\":" * _js_num(light.width) *
           ",\"height\":" * _js_num(light.height) *
           _web_light_visibility_json(light, visibility_target_ids, visibility_values) *
           "}"
end

function _web_light_json(light::LightProbe;
                         visibility_target_ids::AbstractVector{Int}=Int[],
                         visibility_values::AbstractVector{Bool}=Bool[],
                         shadow_mode::Symbol=:static,
                         clipping_planes=_NO_PLANES)
    coeffs = "[" * join((_js_color(c) for c in light.coeffs), ",") * "]"
    return "{" *
           "\"type\":\"lightProbe\"" *
           ",\"id\":" * string(light.id) *
           ",\"name\":" * _js_str(light.name) *
           ",\"visible\":" * (is_visible(light) ? "true" : "false") *
           ",\"position\":" * _js_vec(get_position(light)) *
           ",\"coeffs\":" * coeffs *
           ",\"intensity\":" * _js_num(light.intensity) *
           _web_light_visibility_json(light, visibility_target_ids, visibility_values) *
           "}"
end

_web_light_json(light::AbstractLight; kwargs...) = nothing
_web_light_json(light::AbstractLight, scene::Scene; kwargs...) = _web_light_json(light; kwargs...)

function _web_lights_json(scene::Scene, force_ids::Set{Int}=Set{Int}(),
                          stale_shadow_ids::Set{Int}=Set{Int}(),
                          dynamic_shadow_ids::Set{Int}=Set{Int}(),
                          dynamic_spot_shadow_ids::Set{Int}=Set{Int}(),
                          dynamic_point_shadow_ids::Set{Int}=Set{Int}();
                          clipping_planes=_NO_PLANES)
    lights = String[]
    # Unpruned traversal (collect_lights skips invisible subtrees): lights whose
    # own visibility or ancestor visibility is animated (force_ids) must be
    # exported even while currently hidden. Statically hidden lights are dropped
    # to match the CPU renderer's hierarchical visibility.
    all_lights = SceneLight[]
    traverse(scene, o -> o isa AbstractLight && push!(all_lights, o))
    for light in all_lights
        _web_visible_or_forced(light, force_ids) || continue
        visibility_ids, visibility_values = _web_visibility_chain(light)
        shadow_mode = if light.id in dynamic_shadow_ids
            :directional_dynamic
        elseif light.id in dynamic_spot_shadow_ids
            :spot_dynamic
        elseif light.id in dynamic_point_shadow_ids
            :point_dynamic
        elseif light.id in stale_shadow_ids
            :none
        else
            :static
        end
        item = _web_light_json(light, scene;
                               visibility_target_ids=visibility_ids,
                               visibility_values=visibility_values,
                               shadow_mode=shadow_mode,
                               clipping_planes=clipping_planes)
        item !== nothing && push!(lights, item)
    end
    return "[" * join(lights, ",") * "]"
end

function _web_flatten_vec3(vs::AbstractVector{<:Vec3})
    out = Vector{Float64}(undef, 3 * length(vs))
    for (i, v) in enumerate(vs)
        j = 3i - 2
        out[j] = v.x
        out[j + 1] = v.y
        out[j + 2] = v.z
    end
    return out
end

function _web_positions(obj, geo::BufferGeometry)
    obj isa SkinnedMesh && return geo.positions
    morphed_positions = _object_morph_positions(obj, geo)
    if morphed_positions !== nothing
        return _web_flatten_vec3(morphed_positions)
    end
    return geo.positions
end

function _web_tangent_data(geo::BufferGeometry)
    fallback = [j == 1 || j == 4 ? 1.0 : 0.0 for _ in 1:geo.n_vertices for j in 1:4]
    has_attribute(geo, :tangent) || return false, fallback
    attr = get_attribute(geo, :tangent)
    attr.item_size >= 4 && length(attr.data) >= attr.item_size * geo.n_vertices ||
        return false, fallback
    tangents = [Float64(attr.data[(i - 1) * attr.item_size + j])
                for i in 1:geo.n_vertices for j in 1:4]
    return true, tangents
end

function _web_morph_vec3_targets(geo::BufferGeometry, prefix::String)
    targets = String[]
    i = 0
    while true
        name = Symbol(prefix * string(i))
        has_attribute(geo, name) || break
        attr = get_attribute(geo, name)
        attr.item_size >= 3 && length(attr.data) >= geo.n_vertices * attr.item_size || break
        data = [Float64(attr.data[(vi - 1) * attr.item_size + j])
                for vi in 1:geo.n_vertices for j in 1:3]
        push!(targets, _js_array(data))
        i += 1
    end
    return targets
end

function _web_morph_targets_json(obj, geo::BufferGeometry)
    hasproperty(obj, :morph_target_influences) ||
        return "\"morphTargets\":[],\"morphWeights\":[]"
    targets = String[]
    i = 0
    while true
        name = Symbol("morphPosition$i")
        has_attribute(geo, name) || break
        attr = get_attribute(geo, name)
        attr.item_size == 3 && length(attr.data) == length(geo.positions) || break
        push!(targets, _js_array(attr.data))
        i += 1
    end
    normals = _web_morph_vec3_targets(geo, "morphNormal")
    tangents = _web_morph_vec3_targets(geo, "morphTangent")
    has_morph_channels = !(isempty(targets) && isempty(normals) && isempty(tangents))
    weights = has_morph_channels ? Float64.(obj.morph_target_influences) : Float64[]
    morph_json = "\"morphTargets\":[" * join(targets, ",") * "]" *
                 ",\"morphNormals\":[" * join(normals, ",") * "]" *
                 ",\"morphTangents\":[" * join(tangents, ",") * "]" *
                 ",\"morphWeights\":" * _js_array(weights)
    return obj isa SkinnedMesh ? morph_json :
           "\"basePositions\":" * _js_array(geo.positions) * "," * morph_json
end

function _web_skin_json(obj, geo::BufferGeometry)
    obj isa SkinnedMesh || return "\"skin\":null"
    length(obj.skin_indices) == geo.n_vertices || error("skinned mesh skin_indices length must match vertex count")
    length(obj.skin_weights) == geo.n_vertices || error("skinned mesh skin_weights length must match vertex count")
    indices = Int[]
    weights = Float64[]
    sizehint!(indices, 4 * geo.n_vertices)
    sizehint!(weights, 4 * geo.n_vertices)
    for vi in 1:geo.n_vertices
        append!(indices, obj.skin_indices[vi] .- 1)
        append!(weights, obj.skin_weights[vi])
    end
    bones = String[]
    bind_inverses = String[]
    for (i, bone) in enumerate(obj.skeleton.bones)
        rot = get_rotation(bone)
        parent = get_parent(bone)
        parent_id = parent === nothing ? 0 : parent.id
        parent_matrix = parent === nothing ? Mat4() : compute_world_matrix(parent)
        push!(bones, "{\"id\":" * string(bone.id) *
                     ",\"name\":" * _js_str(bone.name) *
                     ",\"parentId\":" * string(parent_id) *
                     ",\"matrix\":" * _js_mat(compute_world_matrix(bone)) *
                     ",\"parentMatrix\":" * _js_mat(parent_matrix) *
                     ",\"basePosition\":" * _js_vec(get_position(bone)) *
                     ",\"baseEuler\":" * _js_vec(Vec3(rot.x, rot.y, rot.z)) *
                     ",\"baseEulerOrder\":" * _js_str(String(rot.order)) *
                     ",\"baseScale\":" * _js_vec(get_scale(bone)) *
                     ",\"baseQuaternion\":" *
                         _js_quat(quat_from_euler(rot.x, rot.y, rot.z; order=rot.order)) *
                     "}")
        push!(bind_inverses, _js_mat(obj.skeleton.bind_inverses[i]))
    end
    return "\"basePositions\":" * _js_array(geo.positions) *
           ",\"bindMode\":" * _js_str(String(obj.bind_mode)) *
           ",\"bindMatrix\":" * _js_mat(obj.bind_matrix) *
           ",\"bindMatrixInverse\":" * _js_mat(_skinned_bind_matrix_inverse(obj)) *
           ",\"skin\":{\"indices\":" * _js_array(indices) *
           ",\"weights\":" * _js_array(weights) *
           ",\"bones\":[" * join(bones, ",") * "]" *
           ",\"bindInverses\":[" * join(bind_inverses, ",") * "]}"
end

_web_material_vertex_colors(mat) =
    hasproperty(mat, :vertex_colors) && Bool(getproperty(mat, :vertex_colors))

function _web_color_data(geo::BufferGeometry, use_vertex_colors::Bool)
    if use_vertex_colors && has_attribute(geo, :color)
        attr = get_attribute(geo, :color)
        if attr.item_size >= 3 && length(attr.data) >= attr.item_size * geo.n_vertices
            return [attr.data[(i - 1) * attr.item_size + j] for i in 1:geo.n_vertices for j in 1:3]
        end
    end
    return ones(Float64, 3 * geo.n_vertices)
end

function _web_line_distance_data(geo::BufferGeometry)
    if has_attribute(geo, :lineDistance)
        attr = get_attribute(geo, :lineDistance)
        if attr.item_size >= 1 && length(attr.data) >= attr.item_size * geo.n_vertices
            return [Float64(attr.data[(i - 1) * attr.item_size + 1]) for i in 1:geo.n_vertices]
        end
    end
    return zeros(Float64, geo.n_vertices)
end

function _web_draw_range_values(geo::BufferGeometry)
    total = _draw_entry_count(geo)
    entries = _draw_entry_range(geo)
    return (clamp(first(entries) - 1, 0, total), length(entries))
end

function _web_geo_object(geo::BufferGeometry, positions::AbstractVector{<:Real}=geo.positions;
                         use_vertex_colors::Bool=true)
    normals = length(geo.normals) == length(geo.positions) ? geo.normals : zeros(Float64, length(geo.positions))
    has_tangents, tangents = _web_tangent_data(geo)
    uvs = length(geo.uvs) == 2 * geo.n_vertices ? geo.uvs : zeros(Float64, 2 * geo.n_vertices)
    uv2s = if has_attribute(geo, :uv2)
        attr = get_attribute(geo, :uv2)
        attr.item_size >= 2 && length(attr.data) >= attr.item_size * geo.n_vertices ?
            [attr.data[(i-1)*attr.item_size + j] for i in 1:geo.n_vertices for j in 1:2] : uvs
    else
        uvs
    end
    colors = _web_color_data(geo, use_vertex_colors)
    line_distances = _web_line_distance_data(geo)
    indices = isempty(geo.indices) ? collect(1:geo.n_vertices) : geo.indices
    draw_start, draw_count = _web_draw_range_values(geo)
    return "\"positions\":" * _js_array(positions) *
           ",\"normals\":" * _js_array(normals) *
           ",\"tangents\":" * _js_array(tangents) *
           ",\"hasTangents\":" * (has_tangents ? "true" : "false") *
           ",\"uvs\":" * _js_array(uvs) *
           ",\"uv2s\":" * _js_array(uv2s) *
           ",\"colors\":" * _js_array(colors) *
           ",\"lineDistances\":" * _js_array(line_distances) *
           ",\"indices\":" * _js_array(indices .- 1) *
           ",\"drawStart\":" * string(draw_start) *
           ",\"drawCount\":" * string(draw_count)
end

function _web_visibility_states_json(ids::AbstractVector{Int}, values::AbstractVector{Bool})
    parts = String[]
    for (id, visible) in zip(ids, values)
        push!(parts, "{\"id\":" * string(id) *
                    ",\"visible\":" * (visible ? "true" : "false") * "}")
    end
    return "[" * join(parts, ",") * "]"
end

function _web_material_type(mat)
    mat isa MeshBasicMaterial && return "basic"
    mat isa MeshNormalMaterial && return "normal"
    mat isa MeshDepthMaterial && return "depth"
    mat isa MeshToonMaterial && return "toon"
    mat isa MeshMatcapMaterial && return "matcap"
    mat isa MeshLambertMaterial && return "lambert"
    mat isa MeshPhongMaterial && return "phong"
    return "lit"
end

function _web_transform_node_json(obj::AbstractObject3D)
    rot = get_rotation(obj)
    parent = get_parent(obj)
    parent_id = parent === nothing ? 0 : parent.id
    parent_matrix = parent === nothing ? Mat4() : compute_world_matrix(parent)
    return "{" *
           "\"id\":" * string(obj.id) *
           ",\"name\":" * _js_str(getproperty(obj, :name)) *
           ",\"parentId\":" * string(parent_id) *
           ",\"matrix\":" * _js_mat(compute_world_matrix(obj)) *
           ",\"parentMatrix\":" * _js_mat(parent_matrix) *
           ",\"basePosition\":" * _js_vec(get_position(obj)) *
           ",\"baseEuler\":" * _js_vec(Vec3(rot.x, rot.y, rot.z)) *
           ",\"baseEulerOrder\":" * _js_str(String(rot.order)) *
           ",\"baseScale\":" * _js_vec(get_scale(obj)) *
           ",\"baseQuaternion\":" *
               _js_quat(quat_from_euler(rot.x, rot.y, rot.z; order=rot.order)) *
           "}"
end

function _web_is_drawable(obj::AbstractObject3D)
    return obj isa Mesh || obj isa SkinnedMesh || obj isa InstancedMesh ||
           obj isa PointsObject || obj isa LineObject || obj isa LineLoop ||
           obj isa LineSegments || obj isa Sprite
end

function _web_collect_transform_nodes(root::AbstractObject3D, force_ids::Set{Int}=Set{Int}())
    out = String[]
    function forced_subtree(obj::AbstractObject3D)
        obj.id in force_ids && return true
        for child in get_children(obj)
            forced_subtree(child) && return true
        end
        return false
    end
    function visit(obj::AbstractObject3D)
        (is_visible(obj) || forced_subtree(obj)) || return
        if !(obj isa Scene) && !_web_is_drawable(obj) && !(obj isa AbstractLight)
            push!(out, _web_transform_node_json(obj))
        end
        if obj isa LOD
            # LOD level objects are also registered as children (add_lod_level! ->
            # add!), so visit each level once here and skip it in the child loop
            # below; otherwise every level's subtree is emitted twice with the
            # same node id.
            level_ids = Set{Int}()
            for (_, _, child) in obj.levels
                push!(level_ids, child.id)
                visit(child)
            end
            for child in get_children(obj)
                child.id in level_ids || visit(child)
            end
        else
            for child in get_children(obj)
                visit(child)
            end
        end
    end
    visit(root)
    return out
end

function _web_drawable_json(obj, world::Mat4; matrix=nothing, mode::String="triangles",
                            transform_obj::AbstractObject3D=obj,
                            color_override::Union{Nothing,Color3}=nothing,
                            instance_matrix=nothing,
                            instance_matrices::AbstractVector{<:Mat4}=Mat4{Float64}[],
                            instance_colors::AbstractVector{<:Color3}=Color3{Float64}[],
                            morph_target_ids::AbstractVector{Int}=Int[],
                            visibility_target_ids::AbstractVector{Int}=Int[],
                            visibility_values::AbstractVector{Bool}=Bool[],
                            lod_group_id::Int=0,
                            lod_distance::Real=0.0,
                            lod_hysteresis::Real=0.0,
                            sprite_center::Vec2{Float64}=Vec2(0.5, 0.5),
                            sprite_rotation::Real=0.0,
                            sprite_size_attenuation::Bool=true)
    geo = obj.geometry
    mat = obj.material
    mat isa ShaderMaterial &&
        throw(ArgumentError("WebGL export does not support ShaderMaterial; render it with the CPU path or use a built-in browser-exported material"))
    m = matrix === nothing ? world : matrix
    rot = get_rotation(transform_obj)
    parent = get_parent(transform_obj)
    parent_id = parent === nothing ? 0 : parent.id
    parent_matrix = if matrix === nothing
        parent === nothing ? Mat4() : compute_world_matrix(parent)
    else
        Mat4()
    end
    visibility_ids = isempty(visibility_target_ids) ? [obj.id] : visibility_target_ids
    visibility = isempty(visibility_values) ? [is_visible(obj)] : visibility_values
    return "{" *
           "\"id\":" * string(transform_obj.id) *
           ",\"name\":" * _js_str(getproperty(obj, :name)) *
           ",\"mode\":" * _js_str(mode) *
           ",\"visible\":" * (is_visible(obj) ? "true" : "false") *
           ",\"castShadow\":" * (object_casts_shadow(obj) ? "true" : "false") *
           ",\"receiveShadow\":" * (object_receives_shadow(obj) ? "true" : "false") *
           ",\"visibilityStates\":" * _web_visibility_states_json(visibility_ids, visibility) *
           ",\"lodGroup\":" * string(lod_group_id) *
           ",\"lodDistance\":" * _js_num(lod_distance) *
           ",\"lodHysteresis\":" * _js_num(lod_hysteresis) *
           ",\"parentId\":" * string(parent_id) *
           ",\"matrix\":" * _js_mat(m) *
           ",\"parentMatrix\":" * _js_mat(parent_matrix) *
           ",\"instanceMatrix\":" * (instance_matrix === nothing ? "null" : _js_mat(instance_matrix)) *
           ",\"instanceMatrices\":" * (isempty(instance_matrices) ? "null" : _js_mat_array(instance_matrices)) *
           ",\"instanceColors\":" * (isempty(instance_colors) ? "null" : _js_color_array(instance_colors)) *
           ",\"basePosition\":" * _js_vec(get_position(transform_obj)) *
           ",\"baseEuler\":" * _js_vec(Vec3(rot.x, rot.y, rot.z)) *
           ",\"baseEulerOrder\":" * _js_str(String(rot.order)) *
           ",\"baseScale\":" * _js_vec(get_scale(transform_obj)) *
           ",\"baseQuaternion\":" *
               _js_quat(quat_from_euler(rot.x, rot.y, rot.z; order=rot.order)) *
           ",\"materialType\":" * _js_str(_web_material_type(mat)) *
           ",\"depthNear\":" * _js_num(_web_material_depth_near(mat)) *
           ",\"depthFar\":" * _js_num(_web_material_depth_far(mat)) *
           ",\"depthPacking\":" * _js_str(_web_material_depth_packing(mat)) *
           ",\"depthPackingMode\":" * string(_web_material_depth_packing_id(mat)) *
           ",\"toonSteps\":" * _js_num(_web_material_toon_steps(mat)) *
           ",\"color\":" * _js_color(color_override === nothing ? _web_material_color(mat) : color_override) *
           ",\"opacity\":" * _js_num(_web_material_opacity(mat)) *
           ",\"alphaTest\":" * _js_num(_web_material_alpha_test(mat)) *
           ",\"transparent\":" * (_web_material_transparent(mat) ? "true" : "false") *
           ",\"side\":" * _js_str(_web_material_side(mat)) *
           ",\"depthTest\":" * (_web_material_depth_test(mat) ? "true" : "false") *
           ",\"depthWrite\":" * (_web_material_depth_write(mat) ? "true" : "false") *
           ",\"clippingPlanes\":[" *
               join((_js_plane(p) for p in _web_material_clipping_planes(mat)), ",") *
           "]" *
           ",\"pointSize\":" * _js_num(_web_material_size(mat)) *
           ",\"pointSizeAttenuation\":" * (_web_material_point_size_attenuation(mat) ? "true" : "false") *
           ",\"linewidth\":" * _js_num(_web_material_linewidth(mat)) *
           ",\"lineDashed\":" * (_web_material_line_dashed(mat) ? "true" : "false") *
           ",\"dashSize\":" * _js_num(_web_material_dash_size(mat)) *
           ",\"gapSize\":" * _js_num(_web_material_gap_size(mat)) *
           ",\"dashScale\":" * _js_num(_web_material_dash_scale(mat)) *
           ",\"spriteCenter\":" * _js_vec(sprite_center) *
           ",\"spriteRotation\":" * _js_num(sprite_rotation) *
           ",\"spriteSizeAttenuation\":" * (sprite_size_attenuation ? "true" : "false") *
           ",\"glow\":" * _js_num(_web_material_glow(mat)) *
           ",\"texture\":" * _web_texture_json(_web_material_texture(mat)) *
           ",\"alphaTexture\":" * _web_texture_json(_web_material_alpha_texture(mat)) *
           ",\"emissiveTexture\":" * _web_texture_json(_web_material_emissive_texture(mat)) *
           ",\"aoTexture\":" * _web_texture_json(_web_material_ao_texture(mat)) *
           ",\"lightTexture\":" * _web_texture_json(_web_material_light_texture(mat)) *
           ",\"roughnessTexture\":" * _web_texture_json(_web_material_roughness_texture(mat)) *
           ",\"metalnessTexture\":" * _web_texture_json(_web_material_metalness_texture(mat)) *
           ",\"normalTexture\":" * _web_texture_json(_web_material_normal_texture(mat)) *
           ",\"normalScale\":" * _js_num(_web_material_normal_scale(mat)) *
           ",\"matcapTexture\":" * _web_texture_json(_web_material_matcap_texture(mat)) *
           ",\"gradientTexture\":" * _web_texture_json(_web_material_gradient_texture(mat)) *
           ",\"clearcoatTexture\":" * _web_texture_json(_web_material_clearcoat_texture(mat)) *
           ",\"clearcoatRoughnessTexture\":" * _web_texture_json(_web_material_clearcoat_roughness_texture(mat)) *
           ",\"clearcoatNormalTexture\":" * _web_texture_json(_web_material_clearcoat_normal_texture(mat)) *
           ",\"clearcoatNormalScale\":" * _js_num(_web_material_clearcoat_normal_scale(mat)) *
           ",\"transmissionTexture\":" * _web_texture_json(_web_material_transmission_texture(mat)) *
           ",\"thicknessTexture\":" * _web_texture_json(_web_material_thickness_texture(mat)) *
           ",\"sheenColorTexture\":" * _web_texture_json(_web_material_sheen_color_texture(mat)) *
           ",\"sheenRoughnessTexture\":" * _web_texture_json(_web_material_sheen_roughness_texture(mat)) *
           ",\"iridescenceTexture\":" * _web_texture_json(_web_material_iridescence_texture(mat)) *
           ",\"iridescenceThicknessTexture\":" * _web_texture_json(_web_material_iridescence_thickness_texture(mat)) *
           ",\"specularIntensityTexture\":" * _web_texture_json(_web_material_specular_intensity_texture(mat)) *
           ",\"specularColorTexture\":" * _web_texture_json(_web_material_specular_color_texture(mat)) *
           ",\"anisotropyTexture\":" * _web_texture_json(_web_material_anisotropy_texture(mat)) *
           ",\"envTexture\":" * _web_env_json(_web_material_env_texture(mat)) *
           ",\"emissive\":" * _js_color(_web_material_emissive_color(mat)) *
           ",\"emissiveIntensity\":" * _js_num(_web_material_emissive_intensity(mat)) *
           ",\"aoIntensity\":" * _js_num(_web_material_ao_intensity(mat)) *
           ",\"lightMapIntensity\":" * _js_num(_web_material_light_intensity(mat)) *
           ",\"roughness\":" * _js_num(_web_material_roughness(mat)) *
           ",\"metalness\":" * _js_num(_web_material_metalness(mat)) *
           ",\"envMapIntensity\":" * _js_num(_web_material_env_intensity(mat)) *
           ",\"clearcoat\":" * _js_num(_web_material_clearcoat(mat)) *
           ",\"clearcoatRoughness\":" * _js_num(_web_material_clearcoat_roughness(mat)) *
           ",\"transmission\":" * _js_num(_web_material_transmission(mat)) *
           ",\"thickness\":" * _js_num(_web_material_thickness(mat)) *
           ",\"attenuationDistance\":" * _js_num(_web_material_attenuation_distance(mat)) *
           ",\"attenuationColor\":" * _js_color(_web_material_attenuation_color(mat)) *
           ",\"ior\":" * _js_num(_web_material_ior(mat)) *
           ",\"sheen\":" * _js_num(_web_material_sheen(mat)) *
           ",\"sheenColor\":" * _js_color(_web_material_sheen_color(mat)) *
           ",\"sheenRoughness\":" * _js_num(_web_material_sheen_roughness(mat)) *
           ",\"iridescence\":" * _js_num(_web_material_iridescence(mat)) *
           ",\"iridescenceIor\":" * _js_num(_web_material_iridescence_ior(mat)) *
           ",\"iridescenceThickness\":" * _js_num(_web_material_iridescence_thickness(mat)) *
           ",\"specularIntensity\":" * _js_num(_web_material_specular_intensity(mat)) *
           ",\"specularColor\":" * _js_color(_web_material_specular_color(mat)) *
           ",\"anisotropy\":" * _js_num(_web_material_anisotropy(mat)) *
           ",\"anisotropyRotation\":" * _js_num(_web_material_anisotropy_rotation(mat)) *
           ",\"dispersion\":" * _js_num(_web_material_dispersion(mat)) *
           ",\"shininess\":" * _js_num(_web_material_shininess(mat)) *
           ",\"glossiness\":" * _js_num(_web_material_glossiness(mat)) *
           ",\"glossinessPacked\":" * (_web_material_glossiness_packed(mat) ? "true" : "false") *
           ",\"morphTargetIds\":" * _js_array(unique([morph_target_ids; transform_obj.id])) *
           "," * _web_morph_targets_json(obj, geo) *
           "," * _web_skin_json(obj, geo) *
           "," * _web_geo_object(geo, _web_positions(obj, geo);
                                  use_vertex_colors=(mode != "triangles" ||
                                                     _web_material_vertex_colors(mat))) *
           "}"
end

function _web_animation_target_ids(animations::AbstractVector{AnimationClip})
    ids = Set{Int}()
    for clip in animations, track in clip.tracks
        push!(ids, track.target.id)
    end
    return ids
end

const WEB_STALE_SHADOW_LIGHT_TRACK_PROPERTIES = Set(("position", "target", "angle"))
const WEB_DYNAMIC_DIRECTIONAL_SHADOW_TRACK_PROPERTIES = Set(("position", "target"))
const WEB_DYNAMIC_SPOT_SHADOW_TRACK_PROPERTIES = Set(("position", "target", "angle"))
const WEB_DYNAMIC_POINT_SHADOW_TRACK_PROPERTIES = Set(("position", "distance"))
const WEB_SHADOW_DRAWABLE_TRACK_PROPERTIES = Set((
    "position", "scale", "quaternion", "rotation", "visible",
    "morph_target_influences", "morphTargetInfluences",
    "opacity", "transparent", "alphaTest", "alpha_test",
    "depthTest", "depth_test", "depthWrite", "depth_write",
))

function _web_shadow_track_root_name(track::AbstractKeyframeTrack)
    name = _web_track_property_name(track)
    split_at = findfirst(c -> c == '.' || c == '[', name)
    split_at === nothing && return name
    return name[firstindex(name):prevind(name, split_at)]
end

function _web_stale_shadow_light_ids(animations::AbstractVector{AnimationClip})
    ids = Set{Int}()
    for clip in animations, track in clip.tracks
        target = track.target
        target isa Union{DirectionalLight,PointLight,SpotLight} || continue
        _web_shadow_track_root_name(track) in WEB_STALE_SHADOW_LIGHT_TRACK_PROPERTIES || continue
        push!(ids, target.id)
    end
    return ids
end

function _web_dynamic_directional_shadow_light_ids(animations::AbstractVector{AnimationClip})
    ids = Set{Int}()
    for clip in animations, track in clip.tracks
        target = track.target
        target isa DirectionalLight || continue
        target.cast_shadow || continue
        _web_shadow_track_root_name(track) in WEB_DYNAMIC_DIRECTIONAL_SHADOW_TRACK_PROPERTIES || continue
        push!(ids, target.id)
    end
    return ids
end

function _web_dynamic_spot_shadow_light_ids(animations::AbstractVector{AnimationClip})
    ids = Set{Int}()
    for clip in animations, track in clip.tracks
        target = track.target
        target isa SpotLight || continue
        target.cast_shadow || continue
        _web_shadow_track_root_name(track) in WEB_DYNAMIC_SPOT_SHADOW_TRACK_PROPERTIES || continue
        push!(ids, target.id)
    end
    return ids
end

function _web_dynamic_point_shadow_light_ids(animations::AbstractVector{AnimationClip})
    ids = Set{Int}()
    for clip in animations, track in clip.tracks
        target = track.target
        target isa PointLight || continue
        target.cast_shadow || continue
        _web_shadow_track_root_name(track) in WEB_DYNAMIC_POINT_SHADOW_TRACK_PROPERTIES || continue
        push!(ids, target.id)
    end
    return ids
end

function _web_shadow_drawable_animation_target_ids(animations::AbstractVector{AnimationClip})
    ids = Set{Int}()
    for clip in animations, track in clip.tracks
        track.target isa AbstractLight && continue
        _web_shadow_track_root_name(track) in WEB_SHADOW_DRAWABLE_TRACK_PROPERTIES || continue
        push!(ids, track.target.id)
    end
    return ids
end

function _web_object_or_ancestor_targeted(obj::AbstractObject3D, target_ids::Set{Int})
    current = obj
    while current !== nothing
        current.id in target_ids && return true
        current = get_parent(current)
    end
    return false
end

function _web_shadow_drawable_targeted(obj::AbstractObject3D, target_ids::Set{Int})
    _web_object_or_ancestor_targeted(obj, target_ids) && return true
    obj isa SkinnedMesh || return false
    return any(bone -> bone.id in target_ids, obj.skeleton.bones)
end

function _web_has_animated_shadow_drawable(scene::Scene,
                                           animations::AbstractVector{AnimationClip})
    target_ids = _web_shadow_drawable_animation_target_ids(animations)
    isempty(target_ids) && return false
    found = Ref(false)
    traverse(scene, obj -> begin
        found[] && return
        _web_is_drawable(obj) || return
        (object_casts_shadow(obj) || object_receives_shadow(obj)) || return
        _web_shadow_drawable_targeted(obj, target_ids) || return
        found[] = true
    end)
    return found[]
end

function _web_stale_shadow_light_ids(scene::Scene, animations::AbstractVector{AnimationClip})
    ids = _web_stale_shadow_light_ids(animations)
    _web_has_animated_shadow_drawable(scene, animations) || return ids
    traverse(scene, obj -> begin
        obj isa Union{PointLight,SpotLight} || return
        obj.cast_shadow || return
        push!(ids, obj.id)
    end)
    return ids
end

function _web_dynamic_directional_shadow_light_ids(scene::Scene,
                                                   animations::AbstractVector{AnimationClip})
    ids = _web_dynamic_directional_shadow_light_ids(animations)
    _web_has_animated_shadow_drawable(scene, animations) || return ids
    traverse(scene, obj -> begin
        obj isa DirectionalLight || return
        obj.cast_shadow || return
        push!(ids, obj.id)
    end)
    return ids
end

function _web_dynamic_spot_shadow_light_ids(scene::Scene,
                                            animations::AbstractVector{AnimationClip})
    ids = _web_dynamic_spot_shadow_light_ids(animations)
    _web_has_animated_shadow_drawable(scene, animations) || return ids
    traverse(scene, obj -> begin
        obj isa SpotLight || return
        obj.cast_shadow || return
        push!(ids, obj.id)
    end)
    return ids
end

function _web_dynamic_point_shadow_light_ids(scene::Scene,
                                             animations::AbstractVector{AnimationClip})
    ids = _web_dynamic_point_shadow_light_ids(animations)
    _web_has_animated_shadow_drawable(scene, animations) || return ids
    traverse(scene, obj -> begin
        obj isa PointLight || return
        obj.cast_shadow || return
        push!(ids, obj.id)
    end)
    return ids
end

function _web_wireframe_proxy(obj)
    mat = obj.material
    proxy_mat = LineBasicMaterial(color=_web_material_color(mat),
                                  opacity=_web_material_opacity(mat),
                                  depth_test=_web_material_depth_test(mat),
                                  depth_write=_web_material_depth_write(mat))
    return LineSegments(wireframe_geometry(obj.geometry), proxy_mat; name=obj.name)
end

function _web_collect_drawables(root::AbstractObject3D, force_ids::Set{Int}=Set{Int}(),
                                camera_distance::Real=0.0)
    out = String[]
    function forced_subtree(obj::AbstractObject3D)
        obj.id in force_ids && return true
        for child in get_children(obj)
            forced_subtree(child) && return true
        end
        return false
    end
    function visit(obj::AbstractObject3D, ancestors::Vector{AbstractObject3D},
                   lod_group_id::Int=0, lod_distance::Real=0.0,
                   lod_hysteresis::Real=0.0)
        (is_visible(obj) || forced_subtree(obj)) || return
        if obj isa LOD
            for (distance, hysteresis, child) in obj.levels
                visit(child, [ancestors; obj], obj.id, distance, hysteresis)
            end
            return
        end
        world = compute_world_matrix(obj)
        ancestor_ids = [a.id for a in ancestors]
        visibility_ids = [ancestor_ids; obj.id]
        visibility_values = [is_visible(a) for a in ancestors]
        push!(visibility_values, is_visible(obj))
        if obj isa Mesh || obj isa SkinnedMesh
            if material_wireframe(obj.material)
                proxy = _web_wireframe_proxy(obj)
                push!(out, _web_drawable_json(proxy, world; mode="lines",
                                              transform_obj=obj,
                                              morph_target_ids=ancestor_ids,
                                              visibility_target_ids=visibility_ids,
                                              visibility_values=visibility_values,
                                              lod_group_id=lod_group_id,
                                              lod_distance=lod_distance,
                                              lod_hysteresis=lod_hysteresis))
            else
                push!(out, _web_drawable_json(obj, world; mode="triangles",
                                              morph_target_ids=ancestor_ids,
                                              visibility_target_ids=visibility_ids,
                                              visibility_values=visibility_values,
                                              lod_group_id=lod_group_id,
                                              lod_distance=lod_distance,
                                              lod_hysteresis=lod_hysteresis))
            end
        elseif obj isa InstancedMesh
            parent = compute_world_matrix(obj)
            draw_mode = String(obj.draw_mode)
            wire_triangles = obj.draw_mode === :triangles && material_wireframe(obj.material)
            if !_web_material_transparent(obj.material)
                if wire_triangles
                    proxy = _web_wireframe_proxy(obj)
                    push!(out, _web_drawable_json(proxy, parent; mode="lines",
                                                  transform_obj=obj,
                                                  instance_matrices=obj.instance_matrices,
                                                  instance_colors=obj.instance_colors,
                                                  morph_target_ids=ancestor_ids,
                                                  visibility_target_ids=visibility_ids,
                                                  visibility_values=visibility_values,
                                                  lod_group_id=lod_group_id,
                                                  lod_distance=lod_distance,
                                                  lod_hysteresis=lod_hysteresis))
                else
                    push!(out, _web_drawable_json(obj, parent; mode=draw_mode,
                                                  instance_matrices=obj.instance_matrices,
                                                  instance_colors=obj.instance_colors,
                                                  morph_target_ids=ancestor_ids,
                                                  visibility_target_ids=visibility_ids,
                                                  visibility_values=visibility_values,
                                                  lod_group_id=lod_group_id,
                                                  lod_distance=lod_distance,
                                                  lod_hysteresis=lod_hysteresis))
                end
            else
                # Transparent instanced meshes are split into one draw per
                # instance for correct back-to-front sorting (each split bakes its
                # instance matrix into o.matrix). A single-instance draw is NOT
                # GPU-instanced, so the per-instance color attribute is inactive;
                # fold material_color × instance_color into the emitted base color
                # so transparent instances keep their colors like the opaque path.
                for (i, im) in enumerate(obj.instance_matrices)
                    ic = i <= length(obj.instance_colors) ? obj.instance_colors[i] : nothing
                    if wire_triangles
                        proxy = _web_wireframe_proxy(obj)
                        ov = ic === nothing ? nothing :
                             _web_color_mul(_web_material_color(proxy.material), ic)
                        push!(out, _web_drawable_json(proxy, parent * im; mode="lines",
                                                      transform_obj=obj,
                                                      color_override=ov,
                                                      instance_matrix=im,
                                                      morph_target_ids=ancestor_ids,
                                                      visibility_target_ids=visibility_ids,
                                                      visibility_values=visibility_values,
                                                      lod_group_id=lod_group_id,
                                                      lod_distance=lod_distance,
                                                      lod_hysteresis=lod_hysteresis))
                    else
                        ov = ic === nothing ? nothing :
                             _web_color_mul(_web_material_color(obj.material), ic)
                        push!(out, _web_drawable_json(obj, parent * im; mode=draw_mode,
                                                      color_override=ov,
                                                      instance_matrix=im,
                                                      morph_target_ids=ancestor_ids,
                                                      visibility_target_ids=visibility_ids,
                                                      visibility_values=visibility_values,
                                                      lod_group_id=lod_group_id,
                                                      lod_distance=lod_distance,
                                                      lod_hysteresis=lod_hysteresis))
                    end
                end
            end
        elseif obj isa PointsObject
            push!(out, _web_drawable_json(obj, world; mode="points",
                                          morph_target_ids=ancestor_ids,
                                          visibility_target_ids=visibility_ids,
                                          visibility_values=visibility_values,
                                          lod_group_id=lod_group_id,
                                          lod_distance=lod_distance,
                                          lod_hysteresis=lod_hysteresis))
        elseif obj isa LineObject
            push!(out, _web_drawable_json(obj, world; mode="line_strip",
                                          morph_target_ids=ancestor_ids,
                                          visibility_target_ids=visibility_ids,
                                          visibility_values=visibility_values,
                                          lod_group_id=lod_group_id,
                                          lod_distance=lod_distance,
                                          lod_hysteresis=lod_hysteresis))
        elseif obj isa LineLoop
            push!(out, _web_drawable_json(obj, world; mode="line_loop",
                                          morph_target_ids=ancestor_ids,
                                          visibility_target_ids=visibility_ids,
                                          visibility_values=visibility_values,
                                          lod_group_id=lod_group_id,
                                          lod_distance=lod_distance,
                                          lod_hysteresis=lod_hysteresis))
        elseif obj isa LineSegments
            push!(out, _web_drawable_json(obj, world; mode="lines",
                                          morph_target_ids=ancestor_ids,
                                          visibility_target_ids=visibility_ids,
                                          visibility_values=visibility_values,
                                          lod_group_id=lod_group_id,
                                          lod_distance=lod_distance,
                                          lod_hysteresis=lod_hysteresis))
        elseif obj isa Sprite
            mat = obj.material
            geo = BufferGeometry(Float64[0.0, 0.0, 0.0,
                                         1.0, 0.0, 0.0,
                                         1.0, 1.0, 0.0,
                                         0.0, 1.0, 0.0],
                                 Float64[0.0, 0.0, 1.0,
                                         0.0, 0.0, 1.0,
                                         0.0, 0.0, 1.0,
                                         0.0, 0.0, 1.0],
                                 Float64[0.0, 0.0,
                                         1.0, 0.0,
                                         1.0, 1.0,
                                         0.0, 1.0],
                                 Int[1, 2, 3, 1, 3, 4], 4, 2)
            proxy = Mesh(geo, MeshBasicMaterial(color=_web_material_color(mat),
                                                opacity=_web_material_opacity(mat),
                                                transparent=_web_material_transparent(mat) ||
                                                            _web_material_texture(mat) isa Texture ||
                                                            _web_material_alpha_texture(mat) isa Texture,
                                                side=:double,
                                                map=_web_material_texture(mat),
                                                alpha_map=_web_material_alpha_texture(mat),
                                                alpha_test=_web_material_alpha_test(mat),
                                                depth_test=_web_material_depth_test(mat),
                                                depth_write=_web_material_depth_write(mat));
                         name=obj.name)
            push!(out, _web_drawable_json(proxy, world; mode="sprite",
                                          transform_obj=obj,
                                          morph_target_ids=ancestor_ids,
                                          visibility_target_ids=[ancestor_ids; obj.id],
                                          visibility_values=visibility_values,
                                          lod_group_id=lod_group_id,
                                          lod_distance=lod_distance,
                                          lod_hysteresis=lod_hysteresis,
                                          sprite_center=obj.center,
                                          sprite_rotation=_web_material_sprite_rotation(mat),
                                          sprite_size_attenuation=_web_material_sprite_size_attenuation(mat)))
        end
        next_ancestors = [ancestors; obj]
        for child in get_children(obj)
            visit(child, next_ancestors, lod_group_id, lod_distance, lod_hysteresis)
        end
    end
    visit(root, AbstractObject3D[])
    return out
end

function _web_track_property_name(prop::Symbol)
    prop === :alpha_test && return "alphaTest"
    prop === :depth_test && return "depthTest"
    prop === :depth_write && return "depthWrite"
    prop === :normal_scale && return "normalScale"
    prop === :ground_color && return "groundColor"
    (prop === :line_width || prop === :lineWidth) && return "linewidth"
    (prop === :dash_size || prop === :dashSize) && return "dashSize"
    (prop === :gap_size || prop === :gapSize) && return "gapSize"
    (prop === :dash_scale || prop === :dashScale) && return "dashScale"
    prop === :gradient_steps && return "toonSteps"
    prop === :near && return "depthNear"
    prop === :far && return "depthFar"
    prop === :specular && return "specularColor"
    prop === :emissive_intensity && return "emissiveIntensity"
    prop === :ao_map_intensity && return "aoIntensity"
    prop === :light_map_intensity && return "lightMapIntensity"
    prop === :env_map_intensity && return "envMapIntensity"
    prop === :clearcoat_roughness && return "clearcoatRoughness"
    prop === :clearcoat_normal_scale && return "clearcoatNormalScale"
    prop === :sheen_color && return "sheenColor"
    prop === :sheen_roughness && return "sheenRoughness"
    prop === :iridescence_ior && return "iridescenceIor"
    prop === :iridescence_thickness && return "iridescenceThickness"
    prop === :specular_intensity && return "specularIntensity"
    prop === :specular_color && return "specularColor"
    prop === :attenuation_distance && return "attenuationDistance"
    prop === :attenuation_color && return "attenuationColor"
    prop === :anisotropy_rotation && return "anisotropyRotation"
    prop === :material_rotation && return "spriteRotation"
    prop === :size_attenuation && return "spriteSizeAttenuation"
    prop === :size && return "pointSize"
    return String(prop)
end

_web_track_property_name(prop::AbstractString) = String(prop)

function _web_track_property_name(tr::AbstractKeyframeTrack)
    tr.target isa AbstractCamera && tr.property in (:near, :far) && return String(tr.property)
    if tr.property === :size_attenuation
        tr.target isa PointsObject && return "pointSizeAttenuation"
        tr.target isa Sprite && return "spriteSizeAttenuation"
    end
    return _web_track_property_name(tr.property)
end

function _web_track_json(tr::KeyframeTrack)
    values = Float64[]
    for v in tr.values
        append!(values, (v.x, v.y, v.z))
    end
    return "{" *
           "\"target\":" * string(tr.target.id) *
           ",\"property\":" * _js_str(_web_track_property_name(tr)) *
           ",\"kind\":\"vec3\"" *
           ",\"times\":" * _js_array(tr.times) *
           ",\"values\":" * _js_array(values) *
           ",\"interpolation\":" * _js_str(String(tr.interpolation)) *
           "}"
end

function _web_track_json(tr::NumberKeyframeTrack)
    return "{" *
           "\"target\":" * string(tr.target.id) *
           ",\"property\":" * _js_str(_web_track_property_name(tr)) *
           ",\"component\":" * string(tr.component) *
           ",\"kind\":\"number\"" *
           ",\"times\":" * _js_array(tr.times) *
           ",\"values\":" * _js_array(tr.values) *
           ",\"interpolation\":" * _js_str(String(tr.interpolation)) *
           "}"
end

function _web_track_json(tr::QuaternionKeyframeTrack)
    values = Float64[]
    for q in tr.values
        append!(values, (q.x, q.y, q.z, q.w))
    end
    return "{" *
           "\"target\":" * string(tr.target.id) *
           ",\"property\":" * _js_str(_web_track_property_name(tr)) *
           ",\"kind\":\"quat\"" *
           ",\"times\":" * _js_array(tr.times) *
           ",\"values\":" * _js_array(values) *
           ",\"interpolation\":" * _js_str(String(tr.interpolation)) *
           "}"
end

function _web_track_json(tr::MorphWeightsKeyframeTrack)
    values = Float64[]
    stride = isempty(tr.values) ? 0 : length(tr.values[1])
    for v in tr.values
        length(v) == stride || error("morph-weight keyframes must have matching lengths")
        append!(values, v)
    end
    return "{" *
           "\"target\":" * string(tr.target.id) *
           ",\"property\":" * _js_str(_web_track_property_name(tr)) *
           ",\"kind\":\"weights\"" *
           ",\"stride\":" * string(stride) *
           ",\"times\":" * _js_array(tr.times) *
           ",\"values\":" * _js_array(values) *
           ",\"interpolation\":" * _js_str(String(tr.interpolation)) *
           "}"
end

function _web_track_json(tr::CubicSplineMorphWeightsKeyframeTrack)
    values = Float64[]
    in_tangents = Float64[]
    out_tangents = Float64[]
    stride = isempty(tr.values) ? 0 : length(tr.values[1])
    for v in tr.values
        length(v) == stride || error("morph-weight keyframes must have matching lengths")
        append!(values, v)
    end
    for v in tr.in_tangents
        length(v) == stride || error("morph-weight in-tangents must match keyframe length")
        append!(in_tangents, v)
    end
    for v in tr.out_tangents
        length(v) == stride || error("morph-weight out-tangents must match keyframe length")
        append!(out_tangents, v)
    end
    return "{" *
           "\"target\":" * string(tr.target.id) *
           ",\"property\":" * _js_str(_web_track_property_name(tr)) *
           ",\"kind\":\"weights\"" *
           ",\"stride\":" * string(stride) *
           ",\"times\":" * _js_array(tr.times) *
           ",\"values\":" * _js_array(values) *
           ",\"inTangents\":" * _js_array(in_tangents) *
           ",\"outTangents\":" * _js_array(out_tangents) *
           ",\"interpolation\":\"cubicspline\"" *
           "}"
end

function _web_track_json(tr::CubicSplineKeyframeTrack)
    values = Float64[]
    in_tangents = Float64[]
    out_tangents = Float64[]
    for v in tr.values
        append!(values, (v.x, v.y, v.z))
    end
    for v in tr.in_tangents
        append!(in_tangents, (v.x, v.y, v.z))
    end
    for v in tr.out_tangents
        append!(out_tangents, (v.x, v.y, v.z))
    end
    return "{" *
           "\"target\":" * string(tr.target.id) *
           ",\"property\":" * _js_str(_web_track_property_name(tr)) *
           ",\"kind\":\"vec3\"" *
           ",\"times\":" * _js_array(tr.times) *
           ",\"values\":" * _js_array(values) *
           ",\"inTangents\":" * _js_array(in_tangents) *
           ",\"outTangents\":" * _js_array(out_tangents) *
           ",\"interpolation\":\"cubicspline\"" *
           "}"
end

function _web_track_json(tr::CubicSplineQuaternionKeyframeTrack)
    values = Float64[]
    in_tangents = Float64[]
    out_tangents = Float64[]
    for q in tr.values
        append!(values, (q.x, q.y, q.z, q.w))
    end
    for q in tr.in_tangents
        append!(in_tangents, (q.x, q.y, q.z, q.w))
    end
    for q in tr.out_tangents
        append!(out_tangents, (q.x, q.y, q.z, q.w))
    end
    return "{" *
           "\"target\":" * string(tr.target.id) *
           ",\"property\":" * _js_str(_web_track_property_name(tr)) *
           ",\"kind\":\"quat\"" *
           ",\"times\":" * _js_array(tr.times) *
           ",\"values\":" * _js_array(values) *
           ",\"inTangents\":" * _js_array(in_tangents) *
           ",\"outTangents\":" * _js_array(out_tangents) *
           ",\"interpolation\":\"cubicspline\"" *
           "}"
end

function _web_clip_json(clip::AnimationClip)
    tracks = join((_web_track_json(t) for t in clip.tracks), ",")
    return "{" *
           "\"name\":" * _js_str(clip.name) *
           ",\"duration\":" * _js_num(clip.duration) *
           ",\"loop\":" * _js_str(String(clip.loop)) *
           ",\"repetitions\":" * string(clip.repetitions) *
           ",\"clampWhenFinished\":" * (clip.clamp_when_finished ? "true" : "false") *
           ",\"timeScale\":" * _js_num(clip.time_scale) *
           ",\"tracks\":[" * tracks * "]" *
           "}"
end

function _web_case_json(case::WebGLExportCase)
    animation_target_ids = _web_animation_target_ids(case.animations)
    stale_shadow_ids = _web_stale_shadow_light_ids(case.scene, case.animations)
    dynamic_shadow_ids = _web_dynamic_directional_shadow_light_ids(case.scene, case.animations)
    dynamic_spot_shadow_ids = _web_dynamic_spot_shadow_light_ids(case.scene, case.animations)
    dynamic_point_shadow_ids = _web_dynamic_point_shadow_light_ids(case.scene, case.animations)
    return "{" *
           "\"id\":" * _js_str(case.id) *
           ",\"title\":" * _js_str(case.title) *
           ",\"subtitle\":" * _js_str(case.subtitle) *
           ",\"background\":" * _js_color(case.scene.background) *
           ",\"fog\":" * _web_fog_json(case.scene.fog) *
           ",\"target\":" * _js_vec(case.target) *
           ",\"radius\":" * _js_num(case.radius) *
           ",\"height\":" * _js_num(case.height) *
           ",\"fov\":" * _js_num(case.fov) *
           ",\"camera\":" * _web_camera_json(case.camera) *
           ",\"toneMapping\":" * _js_str(String(case.tone_mapping)) *
           ",\"toneMappingMode\":" * string(_web_tone_mapping_id(case.tone_mapping)) *
           ",\"toneExposure\":" * _js_num(case.tone_exposure) *
           ",\"outputColorSpace\":" * _js_str(String(case.output_color_space)) *
           ",\"outputColorSpaceMode\":" * string(_web_output_color_space_id(case.output_color_space)) *
           ",\"clippingPlanes\":[" * join((_js_plane(p) for p in case.clipping_planes), ",") * "]" *
           ",\"lights\":" * _web_lights_json(case.scene, animation_target_ids, stale_shadow_ids,
                                             dynamic_shadow_ids,
                                             dynamic_spot_shadow_ids,
                                             dynamic_point_shadow_ids;
                                             clipping_planes=case.clipping_planes) *
           ",\"nodes\":[" * join(_web_collect_transform_nodes(case.scene, animation_target_ids), ",") * "]" *
           ",\"objects\":[" * join(_web_collect_drawables(case.scene, animation_target_ids,
                                                          case.radius), ",") * "]" *
           ",\"animations\":[" * join((_web_clip_json(c) for c in case.animations), ",") * "]" *
           "}"
end

function _web_light_caps(cases::AbstractVector{WebGLExportCase})
    max_dir = max_point = max_spot = max_hemi = max_rect = 0
    for case in cases
        force_ids = _web_animation_target_ids(case.animations)
        dir = point = spot = hemi = rect = 0
        traverse(case.scene, obj -> begin
            obj isa AbstractLight || return
            _web_visible_or_forced(obj, force_ids) || return
            if obj isa DirectionalLight
                dir += 1
            elseif obj isa PointLight
                point += 1
            elseif obj isa SpotLight
                spot += 1
            elseif obj isa HemisphereLight
                hemi += 1
            elseif obj isa RectAreaLight
                rect += 1
            end
        end)
        max_dir = max(max_dir, dir)
        max_point = max(max_point, point)
        max_spot = max(max_spot, spot)
        max_hemi = max(max_hemi, hemi)
        max_rect = max(max_rect, rect)
    end
    return (dir=max(1, max_dir), point=max(1, max_point), spot=max(1, max_spot),
            hemi=max(1, max_hemi), rect=max(1, max_rect))
end

function _webgl_html(data_json::String, title::String; light_caps=(dir=4, point=4, spot=4, hemi=4, rect=4))
    max_dir = max(1, Int(light_caps.dir))
    max_point = max(1, Int(light_caps.point))
    max_spot = max(1, Int(light_caps.spot))
    max_hemi = max(1, Int(light_caps.hemi))
    max_rect = max(1, Int(light_caps.rect))
    html = """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$(_html_escape(title))</title>
  <style>
    :root { color-scheme: dark; --bg:#080b10; --panel:#111821; --text:#f2f7ff; --muted:#9eb0c4; --edge:#273443; --accent:#50c8ff; }
    * { box-sizing:border-box; }
    body { margin:0; background:var(--bg); color:var(--text); font-family:Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    main { width:min(1220px, calc(100vw - 28px)); margin:0 auto; padding:24px 0 34px; }
    header { display:flex; justify-content:space-between; align-items:end; gap:16px; margin-bottom:16px; }
    h1 { margin:0 0 6px; font-size:26px; letter-spacing:0; }
    p { margin:0; color:var(--muted); line-height:1.45; }
    .top { display:flex; flex-wrap:wrap; justify-content:flex-end; align-items:center; gap:10px; }
    .controls { display:flex; align-items:center; gap:9px; padding:8px 10px; border:1px solid var(--edge); border-radius:8px; background:var(--panel); }
    .controls button { width:34px; height:30px; display:grid; place-items:center; text-align:center; padding:0; border-radius:6px; }
    .controls label { display:flex; align-items:center; gap:8px; color:var(--muted); font-size:12px; white-space:nowrap; }
    .controls input { width:116px; accent-color:var(--accent); }
    .controls output { min-width:32px; color:var(--text); font-variant-numeric:tabular-nums; text-align:right; }
    .layout { display:grid; grid-template-columns:minmax(0, 1fr) 300px; gap:16px; align-items:start; }
    .stage { border:1px solid var(--edge); border-radius:8px; overflow:hidden; background:#020305; }
    canvas { display:block; width:100%; aspect-ratio:16 / 10; touch-action:none; cursor:grab; }
    canvas:active { cursor:grabbing; }
    .bar { display:flex; justify-content:space-between; gap:12px; padding:12px 14px; background:var(--panel); border-top:1px solid var(--edge); }
    .bar strong { font-size:14px; }
    .bar span { color:var(--muted); font-size:13px; text-align:right; }
    .cases { display:grid; gap:10px; }
    button { text-align:left; border:1px solid var(--edge); border-radius:8px; background:var(--panel); color:var(--text); padding:12px; cursor:pointer; }
    button.active { border-color:var(--accent); background:#102233; box-shadow:0 0 0 1px rgba(80,200,255,.3) inset; }
    button strong { display:block; font-size:14px; margin-bottom:5px; }
    button span { display:block; color:var(--muted); font-size:12px; line-height:1.35; }
    @media (max-width: 840px) { header { display:block; } .layout { grid-template-columns:1fr; } .cases { grid-template-columns:repeat(auto-fit, minmax(220px,1fr)); } }
  </style>
</head>
<body>
  <main>
    <header>
      <div>
        <h1>Diff3D.jl Live WebGL Showcase</h1>
        <p>Scenes, geometry, materials, instancing, and keyframes are exported from Diff3D.jl. Drag to orbit; wheel to zoom.</p>
      </div>
      <div class="top">
        <div class="controls" aria-label="Animation playback">
          <button id="playToggle" type="button" title="Pause animation" aria-label="Pause animation">||</button>
          <label for="speed">Speed <input id="speed" type="range" min="0" max="2.5" step="0.05" value="1"><output id="speedValue">1.00x</output></label>
        </div>
        <p id="stats">loading</p>
      </div>
    </header>
    <section class="layout">
      <div class="stage">
        <canvas id="canvas"></canvas>
        <div class="bar"><strong id="title"></strong><span id="subtitle"></span></div>
      </div>
      <nav id="cases" class="cases"></nav>
    </section>
  </main>
  <script>
  function reportStartupError(err){
    const el=document.getElementById("stats");
    const msg=err&&(err.message||err.description)?(err.message||err.description):String(err||"unknown error");
    if(el) el.textContent="error: "+msg;
  }
  window.addEventListener("error",e=>reportStartupError(e.error||e.message));
  window.addEventListener("unhandledrejection",e=>reportStartupError(e.reason));
  const DATA = $data_json;
  const canvas = document.getElementById("canvas");
  canvas.tabIndex = 0;
  const gl = canvas.getContext("webgl", {antialias:true, preserveDrawingBuffer:true});
  if (!gl) throw new Error("WebGL is not available");
  gl.getExtension("OES_standard_derivatives");
  const instancingExt=gl.getExtension("ANGLE_instanced_arrays");
  const anisotropyExt=gl.getExtension("EXT_texture_filter_anisotropic")||gl.getExtension("MOZ_EXT_texture_filter_anisotropic")||gl.getExtension("WEBKIT_EXT_texture_filter_anisotropic");
  const maxTextureAnisotropy=anisotropyExt?gl.getParameter(anisotropyExt.MAX_TEXTURE_MAX_ANISOTROPY_EXT):1;

  const M4 = {
    ident(){ return [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]; },
    mul(a,b){ const r=new Array(16); for(let c=0;c<4;c++) for(let row=0;row<4;row++) r[c*4+row]=a[row]*b[c*4]+a[4+row]*b[c*4+1]+a[8+row]*b[c*4+2]+a[12+row]*b[c*4+3]; return r; },
    translate(x,y,z){ return [1,0,0,0, 0,1,0,0, 0,0,1,0, x,y,z,1]; },
    scale(x,y,z){ return [x,0,0,0, 0,y,0,0, 0,0,z,0, 0,0,0,1]; },
    quat(q){ const x=q[0],y=q[1],z=q[2],w=q[3], x2=x+x,y2=y+y,z2=z+z, xx=x*x2,xy=x*y2,xz=x*z2, yy=y*y2,yz=y*z2,zz=z*z2, wx=w*x2,wy=w*y2,wz=w*z2; return [1-(yy+zz),xy+wz,xz-wy,0, xy-wz,1-(xx+zz),yz+wx,0, xz+wy,yz-wx,1-(xx+yy),0, 0,0,0,1]; },
    trs(p,q,s){ return M4.mul(M4.translate(p[0],p[1],p[2]), M4.mul(M4.quat(q), M4.scale(s[0],s[1],s[2]))); },
    perspective(fov, aspect, near, far){ const t=Math.tan(fov/2); const c=isFinite(far)?-(far+near)/(far-near):-1, d=isFinite(far)?-2*far*near/(far-near):-2*near; return [1/(aspect*t),0,0,0, 0,1/t,0,0, 0,0,c,-1, 0,0,d,0]; },
    orthographic(left,right,bottom,top,near,far){ const w=right-left,h=top-bottom,p=far-near,x=(right+left)/w,y=(top+bottom)/h,z=(far+near)/p; return [2/w,0,0,0, 0,2/h,0,0, 0,0,-2/p,0, -x,-y,-z,1]; },
    lookAt(eye,target,up){ const z=norm(sub(eye,target)), x=norm(cross(up,z)), y=cross(z,x); return [x[0],y[0],z[0],0, x[1],y[1],z[1],0, x[2],y[2],z[2],0, -dot(x,eye),-dot(y,eye),-dot(z,eye),1]; },
    normal3(m){ const a=m[0],b=m[1],c=m[2],d=m[4],e=m[5],f=m[6],g=m[8],h=m[9],i=m[10]; const A=e*i-f*h,B=-(d*i-f*g),C=d*h-e*g,D=-(b*i-c*h),E=a*i-c*g,F=-(a*h-b*g),G=b*f-c*e,H=-(a*f-c*d),I=a*e-b*d; const det=a*A+b*B+c*C; if(Math.abs(det)<1e-10) return [1,0,0,0,1,0,0,0,1]; const inv=1/det; return [A*inv,B*inv,C*inv,D*inv,E*inv,F*inv,G*inv,H*inv,I*inv]; },
    inv(m){ const a00=m[0],a10=m[1],a20=m[2],a30=m[3],a01=m[4],a11=m[5],a21=m[6],a31=m[7],a02=m[8],a12=m[9],a22=m[10],a32=m[11],a03=m[12],a13=m[13],a23=m[14],a33=m[15]; const b00=a00*a11-a01*a10,b01=a00*a12-a02*a10,b02=a00*a13-a03*a10,b03=a01*a12-a02*a11,b04=a01*a13-a03*a11,b05=a02*a13-a03*a12,b06=a20*a31-a21*a30,b07=a20*a32-a22*a30,b08=a20*a33-a23*a30,b09=a21*a32-a22*a31,b10=a21*a33-a23*a31,b11=a22*a33-a23*a32; const det=b00*b11-b01*b10+b02*b09+b03*b08-b04*b07+b05*b06; if(!det) return new Array(16).fill(0); const id=1/det; return [(a11*b11-a12*b10+a13*b09)*id,(-a10*b11+a12*b08-a13*b07)*id,(a10*b10-a11*b08+a13*b06)*id,(-a10*b09+a11*b07-a12*b06)*id,(-a01*b11+a02*b10-a03*b09)*id,(a00*b11-a02*b08+a03*b07)*id,(-a00*b10+a01*b08-a03*b06)*id,(a00*b09-a01*b07+a02*b06)*id,(a31*b05-a32*b04+a33*b03)*id,(-a30*b05+a32*b02-a33*b01)*id,(a30*b04-a31*b02+a33*b00)*id,(-a30*b03+a31*b01-a32*b00)*id,(-a21*b05+a22*b04-a23*b03)*id,(a20*b05-a22*b02+a23*b01)*id,(-a20*b04+a21*b02-a23*b00)*id,(a20*b03-a21*b01+a22*b00)*id]; }
  };
  const add=(a,b)=>[a[0]+b[0],a[1]+b[1],a[2]+b[2]];
  const sub=(a,b)=>[a[0]-b[0],a[1]-b[1],a[2]-b[2]];
  const scale=(a,s)=>[a[0]*s,a[1]*s,a[2]*s];
  const dot=(a,b)=>a[0]*b[0]+a[1]*b[1]+a[2]*b[2];
  const cross=(a,b)=>[a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]];
  const norm=a=>{ const l=Math.hypot(a[0],a[1],a[2])||1; return [a[0]/l,a[1]/l,a[2]/l]; };
  const mix=(a,b,t)=>a+(b-a)*t;
  const mix3=(a,b,t)=>[mix(a[0],b[0],t),mix(a[1],b[1],t),mix(a[2],b[2],t)];
  const sub3=(a,b)=>[a[0]-b[0],a[1]-b[1],a[2]-b[2]];
  const scale3=(a,s)=>[a[0]*s,a[1]*s,a[2]*s];
  const add3=(a,b)=>[a[0]+b[0],a[1]+b[1],a[2]+b[2]];
  function hermite3(p1,p2,m1,m2,u){ const u2=u*u,u3=u2*u,h00=2*u3-3*u2+1,h10=u3-2*u2+u,h01=-2*u3+3*u2,h11=u3-u2; return add3(add3(scale3(p1,h00),scale3(m1,h10)),add3(scale3(p2,h01),scale3(m2,h11))); }
  function catmull3(times,values,i,u,stride){ const lo=i, hi=Math.min(i+1,times.length-1), h=times[hi]-times[lo]; const p1=values.slice(lo*stride,lo*stride+3), p2=values.slice(hi*stride,hi*stride+3); let m1,m2; if(lo>0){ const p0=values.slice((lo-1)*stride,(lo-1)*stride+3); m1=scale3(sub3(p2,p0),h/(times[hi]-times[lo-1])); } else m1=sub3(p2,p1); if(hi+1<times.length){ const p3=values.slice((hi+1)*stride,(hi+1)*stride+3); m2=scale3(sub3(p3,p1),h/(times[hi+1]-times[lo])); } else m2=sub3(p2,p1); return hermite3(p1,p2,m1,m2,u); }
  const scaleN=(a,s)=>a.map(v=>v*s);
  const addN=(a,b)=>a.map((v,i)=>v+b[i]);
  const mixN=(a,b,t)=>a.map((v,i)=>mix(v,b[i],t));
  const norm4=q=>{ const l=Math.hypot(q[0],q[1],q[2],q[3])||1; return [q[0]/l,q[1]/l,q[2]/l,q[3]/l]; };
  function hermiteN(p1,p2,m1,m2,u){ const u2=u*u,u3=u2*u,h00=2*u3-3*u2+1,h10=u3-2*u2+u,h01=-2*u3+3*u2,h11=u3-u2; return addN(addN(scaleN(p1,h00),scaleN(m1,h10)),addN(scaleN(p2,h01),scaleN(m2,h11))); }
  function catmullN(times,values,i,u,stride){ const lo=i, hi=Math.min(i+1,times.length-1), h=times[hi]-times[lo]; const p1=values.slice(lo*stride,lo*stride+stride), p2=values.slice(hi*stride,hi*stride+stride); let m1,m2; if(lo>0){ const p0=values.slice((lo-1)*stride,(lo-1)*stride+stride); m1=scaleN(p2.map((v,j)=>v-p0[j]),h/(times[hi]-times[lo-1])); } else m1=p2.map((v,j)=>v-p1[j]); if(hi+1<times.length){ const p3=values.slice((hi+1)*stride,(hi+1)*stride+stride); m2=scaleN(p3.map((v,j)=>v-p1[j]),h/(times[hi+1]-times[lo])); } else m2=p2.map((v,j)=>v-p1[j]); return hermiteN(p1,p2,m1,m2,u); }
  function slerp(a,b,t){ let cos=a[0]*b[0]+a[1]*b[1]+a[2]*b[2]+a[3]*b[3]; if(cos<0){ b=[-b[0],-b[1],-b[2],-b[3]]; cos=-cos; } if(cos>.9995){ const q=[mix(a[0],b[0],t),mix(a[1],b[1],t),mix(a[2],b[2],t),mix(a[3],b[3],t)]; const l=Math.hypot(...q)||1; return q.map(v=>v/l); } const th=Math.acos(cos), s=Math.sin(th); return [Math.sin((1-t)*th)/s*a[0]+Math.sin(t*th)/s*b[0], Math.sin((1-t)*th)/s*a[1]+Math.sin(t*th)/s*b[1], Math.sin((1-t)*th)/s*a[2]+Math.sin(t*th)/s*b[2], Math.sin((1-t)*th)/s*a[3]+Math.sin(t*th)/s*b[3]]; }

  const MAX_BONES=64;
  const VSH=`attribute vec3 aPosition; attribute vec3 aNormal; attribute vec4 aTangent; attribute vec3 aColor; attribute vec2 aUv; attribute vec2 aUv2; attribute vec4 aSkinIndex; attribute vec4 aSkinWeight; attribute vec4 aInstanceMatrix0; attribute vec4 aInstanceMatrix1; attribute vec4 aInstanceMatrix2; attribute vec4 aInstanceMatrix3; attribute vec3 aInstanceColor; uniform mat4 uModel,uView,uProj,uBindMatrix,uBindMatrixInverse; uniform mat3 uNormalMat; uniform int uUseSkin,uUseInstancing,uUseInstanceColor; uniform mat4 uBoneMatrices[64]; varying vec3 vNormal,vWorld,vColor; varying vec4 vTangent; varying vec2 vUv,vUv2; varying float vViewZ; mat4 boneMat(float idx){ for(int i=0;i<64;i++){ if(float(i)==idx) return uBoneMatrices[i]; } return mat4(1.0); } mat4 skinMatrix(){ if(uUseSkin==0) return mat4(1.0); return aSkinWeight.x*boneMat(aSkinIndex.x)+aSkinWeight.y*boneMat(aSkinIndex.y)+aSkinWeight.z*boneMat(aSkinIndex.z)+aSkinWeight.w*boneMat(aSkinIndex.w); } mat4 instMatrix(){ return uUseInstancing==1?mat4(aInstanceMatrix0,aInstanceMatrix1,aInstanceMatrix2,aInstanceMatrix3):mat4(1.0); } vec3 instColor(){ return uUseInstancing==1&&uUseInstanceColor==1?aInstanceColor:vec3(1.0); } vec4 skinPosition(mat4 skin){ vec4 p=vec4(aPosition,1.0); return uUseSkin==1?uBindMatrixInverse*(skin*(uBindMatrix*p)):p; } vec3 skinDirection(mat4 skin, vec3 d){ return uUseSkin==1?mat3(uBindMatrixInverse)*mat3(skin)*mat3(uBindMatrix)*d:d; } void main(){ mat4 skin=skinMatrix(); mat4 inst=instMatrix(); vec4 w=uModel*(inst*skinPosition(skin)); vec3 skinnedNormal=mat3(inst)*skinDirection(skin,aNormal); vec3 skinnedTangent=mat3(uModel)*mat3(inst)*skinDirection(skin,aTangent.xyz); vWorld=w.xyz; vViewZ=(uView*w).z; vUv=aUv; vUv2=aUv2; vColor=aColor*instColor(); vNormal=normalize(uNormalMat*skinnedNormal); vTangent=vec4(normalize(skinnedTangent),aTangent.w); gl_Position=uProj*uView*w; }`;
  const VSH_BONE_TEXTURE=VSH
    .replace("uniform int uUseSkin,uUseInstancing,uUseInstanceColor; uniform mat4 uBoneMatrices[64];",
             "uniform int uUseSkin,uUseInstancing,uUseInstanceColor,uUseBoneTexture; uniform mat4 uBoneMatrices[64]; uniform sampler2D uBoneTexture; uniform vec2 uBoneTextureSize;")
    .replace("mat4 boneMat(float idx){ for(int i=0;i<64;i++){ if(float(i)==idx) return uBoneMatrices[i]; } return mat4(1.0); }",
             "mat4 boneMat(float idx){ if(uUseBoneTexture==1){ float j=idx*4.0; float x=mod(j,uBoneTextureSize.x); float y=floor(j/uBoneTextureSize.x); float dx=1.0/uBoneTextureSize.x; float dy=(y+0.5)/uBoneTextureSize.y; return mat4(texture2D(uBoneTexture,vec2((x+0.5)*dx,dy)),texture2D(uBoneTexture,vec2((x+1.5)*dx,dy)),texture2D(uBoneTexture,vec2((x+2.5)*dx,dy)),texture2D(uBoneTexture,vec2((x+3.5)*dx,dy))); } for(int i=0;i<64;i++){ if(float(i)==idx) return uBoneMatrices[i]; } return mat4(1.0); }");
  const DVSH=`attribute vec3 aPosition; attribute vec2 aUv; attribute vec2 aUv2; attribute vec4 aSkinIndex; attribute vec4 aSkinWeight; attribute vec4 aInstanceMatrix0; attribute vec4 aInstanceMatrix1; attribute vec4 aInstanceMatrix2; attribute vec4 aInstanceMatrix3; uniform mat4 uModel,uViewProj,uBindMatrix,uBindMatrixInverse; uniform int uUseSkin,uUseInstancing; uniform mat4 uBoneMatrices[64]; varying float vShadowDepth; varying vec3 vShadowWorld; varying vec2 vShadowUv,vShadowUv2; mat4 boneMat(float idx){ for(int i=0;i<64;i++){ if(float(i)==idx) return uBoneMatrices[i]; } return mat4(1.0); } mat4 skinMatrix(){ if(uUseSkin==0) return mat4(1.0); return aSkinWeight.x*boneMat(aSkinIndex.x)+aSkinWeight.y*boneMat(aSkinIndex.y)+aSkinWeight.z*boneMat(aSkinIndex.z)+aSkinWeight.w*boneMat(aSkinIndex.w); } mat4 instMatrix(){ return uUseInstancing==1?mat4(aInstanceMatrix0,aInstanceMatrix1,aInstanceMatrix2,aInstanceMatrix3):mat4(1.0); } vec4 skinPosition(mat4 skin){ vec4 p=vec4(aPosition,1.0); return uUseSkin==1?uBindMatrixInverse*(skin*(uBindMatrix*p)):p; } void main(){ mat4 skin=skinMatrix(); mat4 inst=instMatrix(); vec4 world=uModel*(inst*skinPosition(skin)); vec4 clip=uViewProj*world; vShadowWorld=world.xyz; vShadowUv=aUv; vShadowUv2=aUv2; vShadowDepth=clip.z/clip.w*.5+.5; gl_Position=clip; }`;
  const DVSH_BONE_TEXTURE=DVSH
    .replace("uniform int uUseSkin,uUseInstancing; uniform mat4 uBoneMatrices[64];",
             "uniform int uUseSkin,uUseInstancing,uUseBoneTexture; uniform mat4 uBoneMatrices[64]; uniform sampler2D uBoneTexture; uniform vec2 uBoneTextureSize;")
    .replace("mat4 boneMat(float idx){ for(int i=0;i<64;i++){ if(float(i)==idx) return uBoneMatrices[i]; } return mat4(1.0); }",
             "mat4 boneMat(float idx){ if(uUseBoneTexture==1){ float j=idx*4.0; float x=mod(j,uBoneTextureSize.x); float y=floor(j/uBoneTextureSize.x); float dx=1.0/uBoneTextureSize.x; float dy=(y+0.5)/uBoneTextureSize.y; return mat4(texture2D(uBoneTexture,vec2((x+0.5)*dx,dy)),texture2D(uBoneTexture,vec2((x+1.5)*dx,dy)),texture2D(uBoneTexture,vec2((x+2.5)*dx,dy)),texture2D(uBoneTexture,vec2((x+3.5)*dx,dy))); } for(int i=0;i<64;i++){ if(float(i)==idx) return uBoneMatrices[i]; } return mat4(1.0); }");
  const DFSH=`precision mediump float; const int MAX_SHADOW_CLIP=4; varying float vShadowDepth; varying vec3 vShadowWorld; varying vec2 vShadowUv,vShadowUv2; uniform int uShadowClipCount,uShadowMapTexCoord,uShadowAlphaTexCoord; uniform vec4 uShadowClipPlane[MAX_SHADOW_CLIP]; uniform mat3 uShadowMapMatrix,uShadowAlphaMatrix; uniform float uShadowAlphaTest,uShadowOpacity,uShadowUseMap,uShadowUseAlphaMap; uniform sampler2D uShadowColorMap,uShadowAlphaMap; bool shadowDepthClipped(vec3 p){ for(int i=0;i<MAX_SHADOW_CLIP;i++){ if(i>=uShadowClipCount) break; vec4 pl=uShadowClipPlane[i]; if(dot(pl.xyz,p)+pl.w<0.0) return true; } return false; } vec2 shadowDepthUv(mat3 m,int tc){ vec2 base=tc==1?vShadowUv2:vShadowUv; vec3 uv=m*vec3(base,1.0); return uv.xy; } float shadowDepthAlpha(){ vec2 uv=shadowDepthUv(uShadowMapMatrix,uShadowMapTexCoord), auv=shadowDepthUv(uShadowAlphaMatrix,uShadowAlphaTexCoord); return uShadowOpacity*mix(1.0,texture2D(uShadowColorMap,uv).a,uShadowUseMap)*mix(1.0,texture2D(uShadowAlphaMap,auv).g,uShadowUseAlphaMap); } void shadowDepthDiscard(){ if(shadowDepthClipped(vShadowWorld)) discard; if(shadowDepthAlpha()<uShadowAlphaTest) discard; } void main(){ shadowDepthDiscard(); gl_FragColor=vec4(vec3(clamp(vShadowDepth,0.0,1.0)),1.0); }`;
  const PDVSH=DVSH.replace("vShadowDepth=clip.z/clip.w*.5+.5; gl_Position=clip;","gl_Position=clip;");
  const PDVSH_BONE_TEXTURE=DVSH_BONE_TEXTURE.replace("vShadowDepth=clip.z/clip.w*.5+.5; gl_Position=clip;","gl_Position=clip;");
  const PDFSH=`precision mediump float; const int MAX_SHADOW_CLIP=4; varying float vShadowDepth; varying vec3 vShadowWorld; varying vec2 vShadowUv,vShadowUv2; uniform vec3 uPointShadowPos; uniform float uPointShadowFar; uniform int uShadowClipCount,uShadowMapTexCoord,uShadowAlphaTexCoord; uniform vec4 uShadowClipPlane[MAX_SHADOW_CLIP]; uniform mat3 uShadowMapMatrix,uShadowAlphaMatrix; uniform float uShadowAlphaTest,uShadowOpacity,uShadowUseMap,uShadowUseAlphaMap; uniform sampler2D uShadowColorMap,uShadowAlphaMap; bool shadowDepthClipped(vec3 p){ for(int i=0;i<MAX_SHADOW_CLIP;i++){ if(i>=uShadowClipCount) break; vec4 pl=uShadowClipPlane[i]; if(dot(pl.xyz,p)+pl.w<0.0) return true; } return false; } vec2 shadowDepthUv(mat3 m,int tc){ vec2 base=tc==1?vShadowUv2:vShadowUv; vec3 uv=m*vec3(base,1.0); return uv.xy; } float shadowDepthAlpha(){ vec2 uv=shadowDepthUv(uShadowMapMatrix,uShadowMapTexCoord), auv=shadowDepthUv(uShadowAlphaMatrix,uShadowAlphaTexCoord); return uShadowOpacity*mix(1.0,texture2D(uShadowColorMap,uv).a,uShadowUseMap)*mix(1.0,texture2D(uShadowAlphaMap,auv).g,uShadowUseAlphaMap); } void shadowDepthDiscard(){ if(shadowDepthClipped(vShadowWorld)) discard; if(shadowDepthAlpha()<uShadowAlphaTest) discard; } void main(){ shadowDepthDiscard(); float d=length(vShadowWorld-uPointShadowPos)/max(uPointShadowFar,0.0001); gl_FragColor=vec4(vec3(clamp(d,0.0,1.0)),1.0); }`;
  const FSH=`precision mediump float; const int MAX_DIR=4; const int MAX_POINT=4; const int MAX_SPOT=4; const int MAX_HEMI=4; varying vec3 vNormal,vWorld; varying vec2 vUv; uniform vec3 uColor,uCamera,uAmbientColor; uniform vec3 uDirColor[MAX_DIR],uDirLight[MAX_DIR]; uniform vec3 uPointColor[MAX_POINT],uPointPos[MAX_POINT]; uniform vec3 uSpotColor[MAX_SPOT],uSpotPos[MAX_SPOT],uSpotDir[MAX_SPOT]; uniform vec3 uHemiSky[MAX_HEMI],uHemiGround[MAX_HEMI]; uniform vec2 uMapOffset,uMapRepeat,uMapCenter; uniform float uGlow,uOpacity,uUseMap,uUseAlphaMap,uMapRotation,uToneExposure,uShininess; uniform int uDirCount,uPointCount,uSpotCount,uHemiCount,uToneMapping,uOutputColorSpace; uniform float uPointDistance[MAX_POINT],uPointDecay[MAX_POINT],uSpotDistance[MAX_SPOT],uSpotDecay[MAX_SPOT],uSpotConeCos[MAX_SPOT],uSpotPenumbraCos[MAX_SPOT]; uniform sampler2D uMap,uAlphaMap; vec2 txUv(vec2 uv){ uv-=uMapCenter; float c=cos(uMapRotation), s=sin(uMapRotation); uv=vec2(c*uv.x+s*uv.y,-s*uv.x+c*uv.y); return uv*uMapRepeat+uMapCenter+uMapOffset; } float attenuation(float dist,float maxDist,float decay){ float d=max(dist,0.0001); float a=1.0/pow(d,max(decay,0.0001)); if(maxDist>0.0){ float w=max(1.0-(d/maxDist)*(d/maxDist),0.0); a*=w; } return a; } float spotCone(float theta,float outerCos,float innerCos){ if(innerCos<=outerCos+0.00001) return theta>=outerCos?1.0:0.0; return smoothstep(outerCos,innerCos,theta); } vec3 toneMap(vec3 c){ c=max(c,vec3(0.0)); if(uToneMapping==0) return clamp(c,0.0,1.0); c*=uToneExposure; if(uToneMapping==2) c=c/(vec3(1.0)+c); else if(uToneMapping==3) c=(c*(2.51*c+0.03))/(c*(2.43*c+0.59)+0.14); return clamp(c,0.0,1.0); } vec3 outputColor(vec3 c){ return uOutputColorSpace==1?mix(12.92*c,1.055*pow(c,vec3(1.0/2.4))-0.055,step(vec3(0.0031308),c)):c; } void main(){ vec3 n=normalize(vNormal); if(!gl_FrontFacing)n=-n; vec3 v=normalize(uCamera-vWorld); vec3 diffuse=uAmbientColor; vec3 specular=vec3(0.0); for(int i=0;i<MAX_HEMI;i++){ if(i>=uHemiCount) break; float h=clamp(n.y*.5+.5,0.0,1.0); diffuse+=mix(uHemiGround[i],uHemiSky[i],h); } for(int i=0;i<MAX_DIR;i++){ if(i>=uDirCount) break; vec3 l=normalize(uDirLight[i]); vec3 h=normalize(l+v); float d=max(dot(n,l),0.0); diffuse+=uDirColor[i]*d; specular+=uDirColor[i]*pow(max(dot(n,h),0.0),uShininess); } for(int i=0;i<MAX_POINT;i++){ if(i>=uPointCount) break; vec3 lv=uPointPos[i]-vWorld; float dist=length(lv); vec3 l=normalize(lv); vec3 h=normalize(l+v); float a=attenuation(dist,uPointDistance[i],uPointDecay[i]); diffuse+=uPointColor[i]*max(dot(n,l),0.0)*a; specular+=uPointColor[i]*pow(max(dot(n,h),0.0),uShininess)*a; } for(int i=0;i<MAX_SPOT;i++){ if(i>=uSpotCount) break; vec3 lv=uSpotPos[i]-vWorld; float dist=length(lv); vec3 l=normalize(lv); float theta=dot(normalize(vWorld-uSpotPos[i]),normalize(uSpotDir[i])); float cone=spotCone(theta,uSpotConeCos[i],uSpotPenumbraCos[i]); float a=attenuation(dist,uSpotDistance[i],uSpotDecay[i])*cone; vec3 h=normalize(l+v); diffuse+=uSpotColor[i]*max(dot(n,l),0.0)*a; specular+=uSpotColor[i]*pow(max(dot(n,h),0.0),uShininess)*a; } vec2 uv=txUv(vUv); vec4 tex=mix(vec4(1.0),texture2D(uMap,uv),uUseMap); float alphaTex=mix(1.0,texture2D(uAlphaMap,uv).g,uUseAlphaMap); vec3 base=uColor*tex.rgb; vec3 c=base*diffuse+specular+uGlow*base*.28; gl_FragColor=vec4(outputColor(toneMap(c)),uOpacity*tex.a*alphaTex); }`;
  const FSH_EMISSIVE=`#extension GL_OES_standard_derivatives : enable
  precision mediump float;
  const int MAX_DIR=4; const int MAX_POINT=4; const int MAX_SPOT=4; const int MAX_HEMI=4; const int MAX_RECT=4; const int MAX_CLIP=4; const int MAX_SHADOW=2;
  varying vec3 vNormal,vWorld,vColor; varying vec4 vTangent; varying vec2 vUv,vUv2; varying float vViewZ;
  uniform mat3 uViewNormalMat;
  uniform vec3 uColor,uCamera,uAmbientColor,uEmissive,uFogColor;
  uniform float uToneExposure;
  uniform vec3 uEnvColor[6];
  uniform vec3 uDirColor[MAX_DIR],uDirLight[MAX_DIR],uPointColor[MAX_POINT],uPointPos[MAX_POINT],uSpotColor[MAX_SPOT],uSpotPos[MAX_SPOT],uSpotDir[MAX_SPOT],uHemiSky[MAX_HEMI],uHemiGround[MAX_HEMI],uRectColor[MAX_RECT],uRectPos[MAX_RECT],uRectForward[MAX_RECT],uRectU[MAX_RECT],uRectV[MAX_RECT];
  uniform vec2 uRectSize[MAX_RECT];
  uniform mat3 uMapMatrix,uAlphaMatrix,uEmissiveMatrix,uAoMatrix,uLightMatrix,uRoughnessMatrix,uMetalnessMatrix,uNormalMatrix,uClearcoatNormalMatrix,uClearcoatMatrix,uClearcoatRoughnessMatrix,uTransmissionMatrix,uSheenRoughnessMatrix,uIridescenceMatrix,uIridescenceThicknessMatrix,uSpecularIntensityMatrix,uThicknessMatrix,uAnisotropyMatrix,uSheenColorMatrix,uSpecularColorMatrix;
  uniform mat4 uShadowMatrix[MAX_SHADOW];
  uniform mat4 uShadowPointMatrix0[6],uShadowPointMatrix1[6];
  uniform float uGlow,uOpacity,uAlphaTest,uUseMap,uUseAlphaMap,uUseEmissiveMap,uUseAoMap,uUseLightMap,uUseRoughnessMap,uUseMetalnessMap,uUseNormalMap,uUseClearcoatNormalMap,uUseMatcapMap,uUseGradientMap,uUseEnvMap,uUseEnvCubeMap,uEnvMaxLod,uUsePhysicalScalarMap,uUsePhysicalScalar2Map,uUseClearcoatMap,uUseClearcoatRoughnessMap,uUseTransmissionMap,uUseSheenRoughnessMap,uUseIridescenceMap,uUseIridescenceThicknessMap,uUseSpecularIntensityMap,uUseSheenColorMap,uUseSpecularColorMap,uUseGlossinessMap,uUseThicknessMap,uUseAnisotropyMap,uEmissiveIntensity,uAoIntensity,uLightMapIntensity,uEnvMapIntensity,uNormalScale,uClearcoatNormalScale,uRoughness,uMetalness,uClearcoat,uClearcoatRoughness,uTransmission,uThickness,uAttenuationDistance,uIor,uDispersion,uSheen,uSheenRoughness,uIridescence,uIridescenceIor,uIridescenceThickness,uSpecularIntensity,uAnisotropy,uAnisotropyRotation,uGlossiness,uShininess,uFogNear,uFogFar,uFogDensity,uDepthNear,uDepthFar,uToonSteps;
  uniform float uShadowBias[MAX_SHADOW],uShadowTexel[MAX_SHADOW],uShadowPointFar[MAX_SHADOW];
  uniform vec3 uSheenColor,uSpecularColor,uAttenuationColor,uShadowPointPos[MAX_SHADOW];
  uniform int uDirCount,uPointCount,uSpotCount,uHemiCount,uRectCount,uClipCount,uFogType,uToneMapping,uOutputColorSpace,uShadowCount,uMaterialMode,uDepthPacking,uDepthOrthographic,uMapTexCoord,uAlphaTexCoord,uEmissiveTexCoord,uAoTexCoord,uLightTexCoord,uRoughnessTexCoord,uMetalnessTexCoord,uNormalTexCoord,uClearcoatNormalTexCoord,uClearcoatTexCoord,uClearcoatRoughnessTexCoord,uTransmissionTexCoord,uSheenRoughnessTexCoord,uIridescenceTexCoord,uIridescenceThicknessTexCoord,uSpecularIntensityTexCoord,uThicknessTexCoord,uAnisotropyTexCoord,uSheenColorTexCoord,uSpecularColorTexCoord,uMapColorSpace,uEmissiveColorSpace,uMatcapColorSpace,uSheenColorSpace,uSpecularColorSpace,uUseTangents;
  uniform int uShadowLightIndex[MAX_SHADOW],uShadowKind[MAX_SHADOW],uShadowMode[MAX_SHADOW],uShadowPcfRadius[MAX_SHADOW];
  uniform vec4 uClipPlane[MAX_CLIP];
  uniform float uPointDistance[MAX_POINT],uPointDecay[MAX_POINT],uSpotDistance[MAX_SPOT],uSpotDecay[MAX_SPOT],uSpotConeCos[MAX_SPOT],uSpotPenumbraCos[MAX_SPOT];
  uniform sampler2D uMap,uAlphaMap,uEmissiveMap,uAoMap,uLightMap,uRoughnessMap,uMetalnessMap,uNormalMap,uClearcoatNormalMap,uMatcapMap,uGradientMap,uPhysicalScalarMap,uPhysicalScalar2Map,uSheenColorMap,uSpecularColorMap,uShadowMap0,uShadowMap1;
  uniform samplerCube uEnvCubeMap;
  vec2 txUv(mat3 m, vec2 uv){ vec3 q=m*vec3(uv,1.0); return q.xy; }
  vec2 uvFor(mat3 m, int set){ return set==1?txUv(m,vUv2):txUv(m,vUv); }
  vec3 srgbToLinear(vec3 c){ return mix(c/12.92,pow((c+vec3(0.055))/1.055,vec3(2.4)),step(vec3(0.04045),c)); }
  vec4 colorTex(sampler2D tex, vec2 uv, int colorSpace){ vec4 c=texture2D(tex,uv); if(colorSpace==1) c.rgb=srgbToLinear(c.rgb); return c; }
  float attenuation(float dist,float maxDist,float decay){ float d=max(dist,0.0001); float a=1.0/pow(d,max(decay,0.0001)); if(maxDist>0.0){ float w=max(1.0-(d/maxDist)*(d/maxDist),0.0); a*=w; } return a; }
  float spotCone(float theta,float outerCos,float innerCos){ if(innerCos<=outerCos+0.00001) return theta>=outerCos?1.0:0.0; return smoothstep(outerCos,innerCos,theta); }
  bool clipped(vec3 p){ for(int i=0;i<MAX_CLIP;i++){ if(i>=uClipCount) break; vec4 pl=uClipPlane[i]; if(dot(pl.xyz,p)+pl.w<0.0) return true; } return false; }
  float fogFactor(float d){ if(uFogType==1) return smoothstep(uFogNear,uFogFar,d); if(uFogType==2){ float f=1.0-exp(-uFogDensity*uFogDensity*d*d); return clamp(f,0.0,1.0); } return 0.0; }
  vec3 toneMap(vec3 c){ c=max(c,vec3(0.0)); if(uToneMapping==0) return clamp(c,0.0,1.0); c*=uToneExposure; if(uToneMapping==2) c=c/(vec3(1.0)+c); else if(uToneMapping==3) c=(c*(2.51*c+0.03))/(c*(2.43*c+0.59)+0.14); return clamp(c,0.0,1.0); }
  vec3 outputColor(vec3 c){ return uOutputColorSpace==1?mix(12.92*c,1.055*pow(c,vec3(1.0/2.4))-0.055,step(vec3(0.0031308),c)):c; }
  vec4 packDepthToRGBA(float v){ if(v<=0.0) return vec4(0.0); if(v>=1.0) return vec4(1.0); float x=v*16777216.0; float vuf=floor(x); float af=x-vuf; x=vuf/256.0; vuf=floor(x); float bf=x-vuf; x=vuf/256.0; vuf=floor(x); float gf=x-vuf; return vec4(vuf/255.0,gf*(256.0/255.0),bf*(256.0/255.0),af); }
  vec3 packDepthToRGB(float v){ if(v<=0.0) return vec3(0.0); if(v>=1.0) return vec3(1.0); float x=v*65536.0; float vuf=floor(x); float bf=x-vuf; x=vuf/256.0; vuf=floor(x); float gf=x-vuf; return vec3(vuf/255.0,gf*(256.0/255.0),bf); }
  vec2 packDepthToRG(float v){ if(v<=0.0) return vec2(0.0); if(v>=1.0) return vec2(1.0); float x=v*256.0; float vuf=floor(x); float gf=x-vuf; return vec2(vuf/255.0,gf); }
  float viewZToPerspectiveDepth(float viewZ){ return clamp(((uDepthNear+viewZ)*uDepthFar)/((uDepthFar-uDepthNear)*viewZ),0.0,1.0); }
  float viewZToOrthographicDepth(float viewZ){ return clamp((-viewZ-uDepthNear)/(uDepthFar-uDepthNear),0.0,1.0); }
  vec4 depthColor(float viewZ){ float d=uDepthOrthographic==1?viewZToOrthographicDepth(viewZ):viewZToPerspectiveDepth(viewZ); if(uDepthPacking==1) return packDepthToRGBA(d); if(uDepthPacking==2) return vec4(packDepthToRGB(d),1.0); if(uDepthPacking==3) return vec4(packDepthToRG(d),0.0,1.0); return vec4(vec3(1.0-d),uOpacity); }
  float toonBand(float d){ if(uMaterialMode!=3) return max(d,0.0); if(uUseGradientMap>0.5) return texture2D(uGradientMap,vec2(clamp(d*.5+.5,0.0,1.0),0.0)).r; return ceil(clamp(max(d,0.0),0.0,1.0)*uToonSteps)/uToonSteps; }
  vec3 mappedNormal(vec3 n, vec2 uv){ if(uUseNormalMap<0.5) return n; vec3 map=texture2D(uNormalMap,uv).xyz*2.0-1.0; map.xy*=uNormalScale; if(uUseTangents==1){ vec3 tr=vTangent.xyz-n*dot(n,vTangent.xyz); if(dot(tr,tr)>1e-8){ vec3 t=normalize(tr); vec3 b=normalize(cross(n,t)*vTangent.w); return normalize(mat3(t,b,n)*map); } } vec3 q1=dFdx(vWorld), q2=dFdy(vWorld); vec2 st1=dFdx(uv), st2=dFdy(uv); vec3 s=normalize(q1*st2.t-q2*st1.t); vec3 t=normalize(-q1*st2.s+q2*st1.s); return normalize(mat3(s,t,n)*map); }
  vec3 mappedClearcoatNormal(vec3 n, vec2 uv){ if(uUseClearcoatNormalMap<0.5) return n; vec3 map=texture2D(uClearcoatNormalMap,uv).xyz*2.0-1.0; map.xy*=uClearcoatNormalScale; if(uUseTangents==1){ vec3 tr=vTangent.xyz-n*dot(n,vTangent.xyz); if(dot(tr,tr)>1e-8){ vec3 t=normalize(tr); vec3 b=normalize(cross(n,t)*vTangent.w); return normalize(mat3(t,b,n)*map); } } vec3 q1=dFdx(vWorld), q2=dFdy(vWorld); vec2 st1=dFdx(uv), st2=dFdy(uv); vec3 s=normalize(q1*st2.t-q2*st1.t); vec3 t=normalize(-q1*st2.s+q2*st1.s); return normalize(mat3(s,t,n)*map); }
  vec3 envColor(vec3 dir,float rough){ if(uUseEnvCubeMap>0.5) return textureCube(uEnvCubeMap,dir).rgb; vec3 a=abs(dir); if(a.x>=a.y && a.x>=a.z) return dir.x>0.0?uEnvColor[0]:uEnvColor[1]; if(a.y>=a.x && a.y>=a.z) return dir.y>0.0?uEnvColor[2]:uEnvColor[3]; return dir.z>0.0?uEnvColor[4]:uEnvColor[5]; }
  vec3 iridescenceTint(float ndv){ float phase=uIridescenceThickness*.018 + uIridescenceIor*2.1 + ndv*3.14159; return .5+.5*cos(vec3(phase,phase+2.094,phase+4.188)); }
  float rectNode(int i){ return i==0?-0.7745967:(i==1?0.0:0.7745967); }
  float rectWeight(int i){ return i==1?0.8888889:0.5555556; }
  float shadowSample0(vec3 p){ vec4 q=uShadowMatrix[0]*vec4(p,1.0); if(q.w<=0.0) return 1.0; vec3 ndc=q.xyz/q.w; if(abs(ndc.x)>1.0||abs(ndc.y)>1.0||ndc.z<-1.0||ndc.z>1.0) return 1.0; vec2 uv=ndc.xy*.5+.5; float current=ndc.z*.5+.5-uShadowBias[0]; int r=uShadowPcfRadius[0]; if(r<0) r=0; if(r>4) r=4; float sum=0.0,total=0.0; for(int yy=-4;yy<=4;yy++) for(int xx=-4;xx<=4;xx++){ if(xx < -r || xx > r || yy < -r || yy > r) continue; vec2 off=vec2(float(xx),float(yy))*uShadowTexel[0]; float stored=texture2D(uShadowMap0,clamp(uv+off,0.0,1.0)).r; sum += current>stored ? 0.35 : 1.0; total += 1.0; } return total>0.0 ? sum/total : 1.0; }
  float shadowSample1(vec3 p){ vec4 q=uShadowMatrix[1]*vec4(p,1.0); if(q.w<=0.0) return 1.0; vec3 ndc=q.xyz/q.w; if(abs(ndc.x)>1.0||abs(ndc.y)>1.0||ndc.z<-1.0||ndc.z>1.0) return 1.0; vec2 uv=ndc.xy*.5+.5; float current=ndc.z*.5+.5-uShadowBias[1]; int r=uShadowPcfRadius[1]; if(r<0) r=0; if(r>4) r=4; float sum=0.0,total=0.0; for(int yy=-4;yy<=4;yy++) for(int xx=-4;xx<=4;xx++){ if(xx < -r || xx > r || yy < -r || yy > r) continue; vec2 off=vec2(float(xx),float(yy))*uShadowTexel[1]; float stored=texture2D(uShadowMap1,clamp(uv+off,0.0,1.0)).r; sum += current>stored ? 0.35 : 1.0; total += 1.0; } return total>0.0 ? sum/total : 1.0; }
  vec2 pointAtlasOffset(int face){ if(face==0) return vec2(0.0,0.0); if(face==1) return vec2(1.0,0.0); if(face==2) return vec2(2.0,0.0); if(face==3) return vec2(3.0,0.0); if(face==4) return vec2(0.0,1.0); return vec2(1.0,1.0); }
  float pointShadowSample0(vec3 p){ vec3 rel=p-uShadowPointPos[0]; float current=length(rel)/max(uShadowPointFar[0],0.0001)-uShadowBias[0]; int r=uShadowPcfRadius[0]; if(r<0) r=0; if(r>4) r=4; for(int i=0;i<6;i++){ vec4 q=uShadowPointMatrix0[i]*vec4(p,1.0); if(q.w<=0.0) continue; vec3 ndc=q.xyz/q.w; if(abs(ndc.x)>1.0||abs(ndc.y)>1.0||ndc.z<-1.0||ndc.z>1.0) continue; vec2 uv=(ndc.xy*.5+.5+pointAtlasOffset(i))/vec2(4.0,2.0); float sum=0.0,total=0.0; for(int yy=-4;yy<=4;yy++) for(int xx=-4;xx<=4;xx++){ if(xx < -r || xx > r || yy < -r || yy > r) continue; vec2 off=vec2(float(xx)*uShadowTexel[0]*0.25,float(yy)*uShadowTexel[0]*0.5); float stored=texture2D(uShadowMap0,clamp(uv+off,0.0,1.0)).r; sum += current>stored ? 0.35 : 1.0; total += 1.0; } return total>0.0 ? sum/total : 1.0; } return 1.0; }
  float pointShadowSample1(vec3 p){ vec3 rel=p-uShadowPointPos[1]; float current=length(rel)/max(uShadowPointFar[1],0.0001)-uShadowBias[1]; int r=uShadowPcfRadius[1]; if(r<0) r=0; if(r>4) r=4; for(int i=0;i<6;i++){ vec4 q=uShadowPointMatrix1[i]*vec4(p,1.0); if(q.w<=0.0) continue; vec3 ndc=q.xyz/q.w; if(abs(ndc.x)>1.0||abs(ndc.y)>1.0||ndc.z<-1.0||ndc.z>1.0) continue; vec2 uv=(ndc.xy*.5+.5+pointAtlasOffset(i))/vec2(4.0,2.0); float sum=0.0,total=0.0; for(int yy=-4;yy<=4;yy++) for(int xx=-4;xx<=4;xx++){ if(xx < -r || xx > r || yy < -r || yy > r) continue; vec2 off=vec2(float(xx)*uShadowTexel[1]*0.25,float(yy)*uShadowTexel[1]*0.5); float stored=texture2D(uShadowMap1,clamp(uv+off,0.0,1.0)).r; sum += current>stored ? 0.35 : 1.0; total += 1.0; } return total>0.0 ? sum/total : 1.0; } return 1.0; }
  float shadowFor(int kind, int index, vec3 p){ float sh=1.0; if(uShadowCount>0&&uShadowKind[0]==kind&&uShadowLightIndex[0]==index) sh*=uShadowMode[0]==1?pointShadowSample0(p):shadowSample0(p); if(uShadowCount>1&&uShadowKind[1]==kind&&uShadowLightIndex[1]==index) sh*=uShadowMode[1]==1?pointShadowSample1(p):shadowSample1(p); return sh; }
  void main(){ if(clipped(vWorld)) discard; vec2 uv=uvFor(uMapMatrix,uMapTexCoord); vec2 alphaUv=uvFor(uAlphaMatrix,uAlphaTexCoord); vec2 emissiveUv=uvFor(uEmissiveMatrix,uEmissiveTexCoord); vec2 aoUv=uvFor(uAoMatrix,uAoTexCoord); vec2 lightUv=uvFor(uLightMatrix,uLightTexCoord); vec2 roughnessUv=uvFor(uRoughnessMatrix,uRoughnessTexCoord); vec2 metalnessUv=uvFor(uMetalnessMatrix,uMetalnessTexCoord); vec2 normalUv=uvFor(uNormalMatrix,uNormalTexCoord); vec2 clearcoatNormalUv=uvFor(uClearcoatNormalMatrix,uClearcoatNormalTexCoord); vec2 clearcoatUv=uvFor(uClearcoatMatrix,uClearcoatTexCoord); vec2 clearcoatRoughnessUv=uvFor(uClearcoatRoughnessMatrix,uClearcoatRoughnessTexCoord); vec2 transmissionUv=uvFor(uTransmissionMatrix,uTransmissionTexCoord); vec2 sheenRoughnessUv=uvFor(uSheenRoughnessMatrix,uSheenRoughnessTexCoord); vec2 iridescenceUv=uvFor(uIridescenceMatrix,uIridescenceTexCoord); vec2 iridescenceThicknessUv=uvFor(uIridescenceThicknessMatrix,uIridescenceThicknessTexCoord); vec2 specularIntensityUv=uvFor(uSpecularIntensityMatrix,uSpecularIntensityTexCoord); vec2 thicknessUv=uvFor(uThicknessMatrix,uThicknessTexCoord); vec2 anisotropyUv=uvFor(uAnisotropyMatrix,uAnisotropyTexCoord); vec2 sheenColorUv=uvFor(uSheenColorMatrix,uSheenColorTexCoord); vec2 specularColorUv=uvFor(uSpecularColorMatrix,uSpecularColorTexCoord); vec3 n=normalize(vNormal); if(!gl_FrontFacing)n=-n; n=mappedNormal(n,normalUv); vec3 clearcoatN=mappedClearcoatNormal(n,clearcoatNormalUv); float viewDistance=length(uCamera-vWorld); if(uMaterialMode==1){ vec3 nc=clamp(n*.5+.5,0.0,1.0); nc=mix(nc,uFogColor,fogFactor(viewDistance)); gl_FragColor=vec4(outputColor(nc),uOpacity); return; } if(uMaterialMode==2){ vec4 depthTex=mix(vec4(1.0),colorTex(uMap,uv,uMapColorSpace),uUseMap); float depthAlphaTex=mix(1.0,texture2D(uAlphaMap,alphaUv).g,uUseAlphaMap); float depthAlpha=uOpacity*depthTex.a*depthAlphaTex; if(depthAlpha<uAlphaTest) discard; vec4 dc=depthColor(vViewZ); dc.a=depthAlpha; gl_FragColor=dc; return; } vec3 v=normalize(uCamera-vWorld); if(uMaterialMode==4){ float f=max(dot(n,v),0.0); vec3 viewN=normalize(uViewNormalMat*n); vec3 viewDir=normalize(uViewNormalMat*v); vec3 matcapX=normalize(vec3(viewDir.z,0.0,-viewDir.x)); vec3 matcapY=cross(viewDir,matcapX); vec2 muv=clamp(vec2(dot(matcapX,viewN),dot(matcapY,viewN))*.495+vec2(.5),0.0,1.0); vec4 matcapTex=mix(vec4(1.0),colorTex(uMap,uv,uMapColorSpace),uUseMap); float matcapAlphaTex=mix(1.0,texture2D(uAlphaMap,alphaUv).g,uUseAlphaMap); float matcapAlpha=uOpacity*matcapTex.a*matcapAlphaTex; if(matcapAlpha<uAlphaTest) discard; vec3 fallback=vec3(0.35+0.65*f); vec3 mc=uColor*vColor*matcapTex.rgb*mix(fallback,colorTex(uMatcapMap,muv,uMatcapColorSpace).rgb,uUseMatcapMap); mc=mix(mc,uFogColor,fogFactor(viewDistance)); gl_FragColor=vec4(outputColor(toneMap(mc)),matcapAlpha); return; } float glossiness=clamp(uGlossiness*mix(1.0,texture2D(uSpecularColorMap,specularColorUv).a,uUseGlossinessMap),0.0,1.0); float phongShininess=max(2.0/max(pow(max(1.0-glossiness,0.0),4.0),0.0001)-2.0,0.0001); vec3 diffuse=uAmbientColor; vec3 specular=vec3(0.0);
    for(int i=0;i<MAX_HEMI;i++){ if(i>=uHemiCount) break; float h=clamp(n.y*.5+.5,0.0,1.0); diffuse+=mix(uHemiGround[i],uHemiSky[i],h); }
    for(int i=0;i<MAX_DIR;i++){ if(i>=uDirCount) break; vec3 l=normalize(uDirLight[i]); vec3 h=normalize(l+v); float d=toonBand(dot(n,l)); float sh=shadowFor(1,i,vWorld); diffuse+=uDirColor[i]*d*sh; specular+=uDirColor[i]*pow(max(dot(n,h),0.0),phongShininess)*sh; }
    for(int i=0;i<MAX_RECT;i++){ if(i>=uRectCount) break; float hx=max(uRectSize[i].x,0.0)*0.5; float hy=max(uRectSize[i].y,0.0)*0.5; float area=hx*hy; vec3 f=normalize(uRectForward[i]); for(int ix=0;ix<3;ix++){ for(int iy=0;iy<3;iy++){ float x=rectNode(ix), y=rectNode(iy); vec3 sp=uRectPos[i]+uRectU[i]*(hx*x)+uRectV[i]*(hy*y); vec3 lv=sp-vWorld; float dist2=max(dot(lv,lv),0.0001); vec3 l=lv*inversesqrt(dist2); float emit=max(dot(-l,f),0.0); float a=area*rectWeight(ix)*rectWeight(iy)*emit/dist2; vec3 h=normalize(l+v); diffuse+=uRectColor[i]*toonBand(dot(n,l))*a; specular+=uRectColor[i]*pow(max(dot(n,h),0.0),phongShininess)*(dot(n,l)>0.0?1.0:0.0)*a; } } }
    for(int i=0;i<MAX_POINT;i++){ if(i>=uPointCount) break; vec3 lv=uPointPos[i]-vWorld; float dist=length(lv); vec3 l=normalize(lv); vec3 h=normalize(l+v); float sh=shadowFor(3,i,vWorld); float a=attenuation(dist,uPointDistance[i],uPointDecay[i])*sh; diffuse+=uPointColor[i]*toonBand(dot(n,l))*a; specular+=uPointColor[i]*pow(max(dot(n,h),0.0),phongShininess)*a; }
    for(int i=0;i<MAX_SPOT;i++){ if(i>=uSpotCount) break; vec3 lv=uSpotPos[i]-vWorld; float dist=length(lv); vec3 l=normalize(lv); float theta=dot(normalize(vWorld-uSpotPos[i]),normalize(uSpotDir[i])); float cone=spotCone(theta,uSpotConeCos[i],uSpotPenumbraCos[i]); float sh=shadowFor(2,i,vWorld); float a=attenuation(dist,uSpotDistance[i],uSpotDecay[i])*cone*sh; vec3 h=normalize(l+v); diffuse+=uSpotColor[i]*toonBand(dot(n,l))*a; specular+=uSpotColor[i]*pow(max(dot(n,h),0.0),phongShininess)*a; }
    vec4 tex=mix(vec4(1.0),colorTex(uMap,uv,uMapColorSpace),uUseMap); float alphaTex=mix(1.0,texture2D(uAlphaMap,alphaUv).g,uUseAlphaMap); float outAlpha=uOpacity*tex.a*alphaTex; if(outAlpha<uAlphaTest) discard; vec3 base=uColor*vColor*tex.rgb; vec3 ao=mix(vec3(1.0),texture2D(uAoMap,aoUv).rgb,uUseAoMap); vec3 lm=mix(vec3(1.0),texture2D(uLightMap,lightUv).rgb,uUseLightMap); vec3 aoMix=mix(vec3(1.0),ao,uAoIntensity); vec3 lightMix=mix(vec3(1.0),lm,uLightMapIntensity); if(uMaterialMode==5){ vec3 bc=base*aoMix*lightMix; bc=mix(bc,uFogColor,fogFactor(viewDistance)); gl_FragColor=vec4(outputColor(toneMap(bc)),outAlpha); return; } vec3 emissiveTex=mix(vec3(1.0),colorTex(uEmissiveMap,emissiveUv,uEmissiveColorSpace).rgb,uUseEmissiveMap); float rough=clamp(uRoughness*mix(1.0,texture2D(uRoughnessMap,roughnessUv).g,uUseRoughnessMap),0.02,1.0); float metal=clamp(uMetalness*mix(1.0,texture2D(uMetalnessMap,metalnessUv).b,uUseMetalnessMap),0.0,1.0); float clearcoatMap=uUseClearcoatMap<0.5?1.0:texture2D(uPhysicalScalarMap,clearcoatUv).r; float clearcoatRoughMap=uUseClearcoatRoughnessMap<0.5?1.0:texture2D(uPhysicalScalarMap,clearcoatRoughnessUv).g; float transmissionMap=uUseTransmissionMap<0.5?1.0:texture2D(uPhysicalScalarMap,transmissionUv).b; float sheenRoughMap=uUseSheenRoughnessMap<0.5?1.0:texture2D(uPhysicalScalarMap,sheenRoughnessUv).a; float iridescenceMap=uUseIridescenceMap<0.5?1.0:texture2D(uPhysicalScalar2Map,iridescenceUv).r; float iridThicknessMap=uUseIridescenceThicknessMap<0.5?1.0:texture2D(uPhysicalScalar2Map,iridescenceThicknessUv).g; float specIntensityMap=uUseSpecularIntensityMap<0.5?1.0:texture2D(uPhysicalScalar2Map,specularIntensityUv).b; float thicknessMap=uUseThicknessMap<0.5?1.0:texture2D(uPhysicalScalar2Map,thicknessUv).a; float anisotropyMap=uUseAnisotropyMap<0.5?1.0:texture2D(uPhysicalScalar2Map,anisotropyUv).a; float clearcoat=clamp(uClearcoat*clearcoatMap,0.0,1.0); float clearcoatRough=clamp(uClearcoatRoughness*clearcoatRoughMap,0.0,1.0); float transmission=clamp(uTransmission*transmissionMap,0.0,1.0); vec3 sheenColor=uSheenColor*mix(vec3(1.0),colorTex(uSheenColorMap,sheenColorUv,uSheenColorSpace).rgb,uUseSheenColorMap); float sheenRough=clamp(uSheenRoughness*sheenRoughMap,0.0,1.0); float iridescence=clamp(uIridescence*iridescenceMap,0.0,1.0); float iridThickness=uIridescenceThickness*iridThicknessMap; float specIntensity=clamp(uSpecularIntensity*specIntensityMap,0.0,1.0); vec3 specColor=uSpecularColor*mix(vec3(1.0),colorTex(uSpecularColorMap,specularColorUv,uSpecularColorSpace).rgb,uUseSpecularColorMap); float anisotropy=clamp(uAnisotropy*anisotropyMap,0.0,1.0); rough=sqrt(mix(rough*rough,1.0,anisotropy*anisotropy)); if(uMaterialMode==6){ specular=vec3(0.0); metal=0.0; clearcoat=0.0; transmission=0.0; } if(uMaterialMode==7){ metal=0.0; rough=0.02; clearcoat=0.0; transmission=0.0; specIntensity=1.0; anisotropy=0.0; } if(uMaterialMode==3){ specular=vec3(0.0); metal=0.0; clearcoat=0.0; transmission=0.0; } vec3 env=envColor(reflect(-v,n),rough)*uUseEnvMap*uEnvMapIntensity; float ndv=max(dot(n,v),0.0); float iorF0=pow((uIor-1.0)/(uIor+1.0),2.0); float fresnel=iorF0+(1.0-iorF0)*pow(1.0-ndv,5.0); float dispersion=max(uDispersion,0.0); float halfSpread=max(uIor-1.0,0.0)*0.025*dispersion; vec3 dispersionIor=max(vec3(uIor-halfSpread,uIor,uIor+halfSpread),vec3(1.0)); vec3 dispersionF0=pow((dispersionIor-1.0)/(dispersionIor+1.0),vec3(2.0)); vec3 dispersionFresnel=dispersionF0+(vec3(1.0)-dispersionF0)*pow(1.0-ndv,5.0); vec3 specTint=mix(specColor,specColor*(.5+.5*cos(vec3(iridThickness*.018 + uIridescenceIor*2.1 + ndv*3.14159,iridThickness*.018 + uIridescenceIor*2.1 + ndv*3.14159+2.094,iridThickness*.018 + uIridescenceIor*2.1 + ndv*3.14159+4.188))),iridescence); float specScale=mix(1.0,2.0,metal)*(1.0-rough*.7)*specIntensity; float coatPower=mix(96.0,18.0,clearcoatRough); float coatNdv=max(dot(clearcoatN,v),0.0); vec3 coat=specular*pow(coatNdv,coatPower)*clearcoat; vec3 sheen=diffuse*sheenColor*uSheen*(0.15+0.35*sheenRough)*pow(1.0-ndv,2.0); vec3 transmitted=env*base*transmission*(vec3(1.0)-dispersionFresnel); vec3 lit=base*diffuse*(1.0-metal*.55)*(1.0-transmission*.7)+specular*specScale*mix(specTint,base*specTint,metal); vec3 c=lit*aoMix*lightMix+coat+sheen+transmitted+env*(0.12+metal*.88)*(1.0-rough*.45)+uGlow*base*.28+uEmissive*emissiveTex*uEmissiveIntensity; c=mix(c,uFogColor,fogFactor(length(uCamera-vWorld))); gl_FragColor=vec4(outputColor(toneMap(c)),outAlpha); }`;
  const FSH_EMISSIVE_VOLUME=FSH_EMISSIVE
    .replace("float transmission=clamp(uTransmission*transmissionMap,0.0,1.0);",
             "float transmission=clamp(uTransmission*transmissionMap,0.0,1.0); float thickness=max(uThickness*thicknessMap,0.0);")
    .replace("vec3 specTint=mix(specColor",
             "float vol=step(0.000001,thickness)*step(0.000001,uAttenuationDistance); vec3 volAtt=mix(vec3(1.0),pow(max(uAttenuationColor,vec3(0.0)),vec3(thickness/max(ndv,0.001)/max(uAttenuationDistance,0.000001))),vol); vec3 specTint=mix(specColor")
    .replace("vec3 transmitted=env*base*transmission*(vec3(1.0)-dispersionFresnel);",
             "vec3 transmitted=env*base*volAtt*transmission*(vec3(1.0)-dispersionFresnel);");
  const FSH_EMISSIVE_CORE=FSH_EMISSIVE_VOLUME
    .replace(",uUsePhysicalScalarMap,uUsePhysicalScalar2Map,uUseSheenColorMap,uUseSpecularColorMap,uUseGlossinessMap,uUseThicknessMap,uUseAnisotropyMap","")
    .replace(",uPhysicalScalarMap,uPhysicalScalar2Map,uSheenColorMap,uSpecularColorMap","")
    .replace("vec3 mappedClearcoatNormal(vec3 n, vec2 uv){ if(uUseClearcoatNormalMap<0.5) return n; vec3 map=texture2D(uClearcoatNormalMap,uv).xyz*2.0-1.0; map.xy*=uClearcoatNormalScale; if(uUseTangents==1){ vec3 tr=vTangent.xyz-n*dot(n,vTangent.xyz); if(dot(tr,tr)>1e-8){ vec3 t=normalize(tr); vec3 b=normalize(cross(n,t)*vTangent.w); return normalize(mat3(t,b,n)*map); } } vec3 q1=dFdx(vWorld), q2=dFdy(vWorld); vec2 st1=dFdx(uv), st2=dFdy(uv); vec3 s=normalize(q1*st2.t-q2*st1.t); vec3 t=normalize(-q1*st2.s+q2*st1.s); return normalize(mat3(s,t,n)*map); }",
             "vec3 mappedClearcoatNormal(vec3 n, vec2 uv){ return n; }")
    .replace("float clearcoatMap=uUseClearcoatMap<0.5?1.0:texture2D(uPhysicalScalarMap,clearcoatUv).r; float clearcoatRoughMap=uUseClearcoatRoughnessMap<0.5?1.0:texture2D(uPhysicalScalarMap,clearcoatRoughnessUv).g; float transmissionMap=uUseTransmissionMap<0.5?1.0:texture2D(uPhysicalScalarMap,transmissionUv).b; float sheenRoughMap=uUseSheenRoughnessMap<0.5?1.0:texture2D(uPhysicalScalarMap,sheenRoughnessUv).a; float iridescenceMap=uUseIridescenceMap<0.5?1.0:texture2D(uPhysicalScalar2Map,iridescenceUv).r; float iridThicknessMap=uUseIridescenceThicknessMap<0.5?1.0:texture2D(uPhysicalScalar2Map,iridescenceThicknessUv).g; float specIntensityMap=uUseSpecularIntensityMap<0.5?1.0:texture2D(uPhysicalScalar2Map,specularIntensityUv).b; float thicknessMap=uUseThicknessMap<0.5?1.0:texture2D(uPhysicalScalar2Map,thicknessUv).a; float anisotropyMap=uUseAnisotropyMap<0.5?1.0:texture2D(uPhysicalScalar2Map,anisotropyUv).a; float clearcoat=clamp(uClearcoat*clearcoatMap,0.0,1.0); float clearcoatRough=clamp(uClearcoatRoughness*clearcoatRoughMap,0.0,1.0); float transmission=clamp(uTransmission*transmissionMap,0.0,1.0); float thickness=max(uThickness*thicknessMap,0.0); vec3 sheenColor=uSheenColor*mix(vec3(1.0),colorTex(uSheenColorMap,sheenColorUv,uSheenColorSpace).rgb,uUseSheenColorMap); float sheenRough=clamp(uSheenRoughness*sheenRoughMap,0.0,1.0); float iridescence=clamp(uIridescence*iridescenceMap,0.0,1.0); float iridThickness=uIridescenceThickness*iridThicknessMap; float specIntensity=clamp(uSpecularIntensity*specIntensityMap,0.0,1.0); vec3 specColor=uSpecularColor*mix(vec3(1.0),colorTex(uSpecularColorMap,specularColorUv,uSpecularColorSpace).rgb,uUseSpecularColorMap); float anisotropy=clamp(uAnisotropy*anisotropyMap,0.0,1.0); rough=sqrt(mix(rough*rough,1.0,anisotropy*anisotropy));",
             "float clearcoat=clamp(uClearcoat,0.0,1.0); float clearcoatRough=clamp(uClearcoatRoughness,0.0,1.0); float transmission=clamp(uTransmission,0.0,1.0); float thickness=max(uThickness,0.0); vec3 sheenColor=uSheenColor; float sheenRough=clamp(uSheenRoughness,0.0,1.0); float iridescence=clamp(uIridescence,0.0,1.0); float iridThickness=uIridescenceThickness; float specIntensity=clamp(uSpecularIntensity,0.0,1.0); vec3 specColor=uSpecularColor; float anisotropy=clamp(uAnisotropy,0.0,1.0); rough=sqrt(mix(rough*rough,1.0,anisotropy*anisotropy));")
    .replace("float glossiness=clamp(uGlossiness*mix(1.0,texture2D(uSpecularColorMap,specularColorUv).a,uUseGlossinessMap),0.0,1.0);",
             "float glossiness=clamp(uGlossiness,0.0,1.0);");
  const CVSH=`attribute vec3 aPosition; attribute vec3 aColor; attribute float aLineDistance; attribute vec4 aInstanceMatrix0; attribute vec4 aInstanceMatrix1; attribute vec4 aInstanceMatrix2; attribute vec4 aInstanceMatrix3; attribute vec3 aInstanceColor; uniform mat4 uModel,uView,uProj; uniform int uUseInstancing,uUseInstanceColor; varying vec3 vWorld,vColor; varying float vLineDistance; mat4 instMatrix(){ return uUseInstancing==1?mat4(aInstanceMatrix0,aInstanceMatrix1,aInstanceMatrix2,aInstanceMatrix3):mat4(1.0); } vec3 instColor(){ return uUseInstancing==1&&uUseInstanceColor==1?aInstanceColor:vec3(1.0); } void main(){ vec4 w=uModel*(instMatrix()*vec4(aPosition,1.0)); vWorld=w.xyz; vColor=aColor*instColor(); vLineDistance=aLineDistance; gl_Position=uProj*uView*w; }`;
  const CFSH=`precision mediump float; const int MAX_CLIP=4; varying vec3 vWorld,vColor; varying float vLineDistance; uniform vec3 uColor,uCamera,uFogColor; uniform float uGlow,uOpacity,uFogNear,uFogFar,uFogDensity,uToneExposure,uLineDashed,uDashSize,uGapSize,uDashScale; uniform int uClipCount,uFogType,uToneMapping,uOutputColorSpace; uniform vec4 uClipPlane[MAX_CLIP]; bool clipped(vec3 p){ for(int i=0;i<MAX_CLIP;i++){ if(i>=uClipCount) break; vec4 pl=uClipPlane[i]; if(dot(pl.xyz,p)+pl.w<0.0) return true; } return false; } float fogFactor(float d){ if(uFogType==1) return smoothstep(uFogNear,uFogFar,d); if(uFogType==2){ float f=1.0-exp(-uFogDensity*uFogDensity*d*d); return clamp(f,0.0,1.0); } return 0.0; } vec3 toneMap(vec3 c){ c=max(c,vec3(0.0)); if(uToneMapping==0) return clamp(c,0.0,1.0); c*=uToneExposure; if(uToneMapping==2) c=c/(vec3(1.0)+c); else if(uToneMapping==3) c=(c*(2.51*c+0.03))/(c*(2.43*c+0.59)+0.14); return clamp(c,0.0,1.0); } vec3 outputColor(vec3 c){ return uOutputColorSpace==1?mix(12.92*c,1.055*pow(c,vec3(1.0/2.4))-0.055,step(vec3(0.0031308),c)):c; } void main(){ if(clipped(vWorld)) discard; if(uLineDashed>0.5){ float total=max(uDashSize+uGapSize,0.0001); if(mod(vLineDistance*max(uDashScale,0.0001),total)>uDashSize) discard; } vec3 c=uColor*vColor*(.75+.65*uGlow); c=mix(c,uFogColor,fogFactor(length(uCamera-vWorld))); gl_FragColor=vec4(outputColor(toneMap(c)),uOpacity); }`;
  const PVSH=`attribute vec3 aPosition; attribute vec3 aColor; uniform mat4 uModel,uView,uProj; uniform float uPointSize,uPointSizeAttenuation,uPointReferenceDistance; varying vec3 vWorld,vColor; void main(){ vec4 w=uModel*vec4(aPosition,1.0); vec4 viewPos=uView*w; vWorld=w.xyz; vColor=aColor; gl_Position=uProj*viewPos; float atten=uPointSizeAttenuation<0.5?1.0:max(0.1,uPointReferenceDistance/max(0.0001,-viewPos.z)); gl_PointSize=uPointSize*atten; }`;
  const PFSH=`precision mediump float; const int MAX_CLIP=4; varying vec3 vWorld,vColor; uniform vec3 uColor,uCamera,uFogColor; uniform float uGlow,uOpacity,uUsePointMap,uUsePointAlphaMap,uPointAlphaTest,uFogNear,uFogFar,uFogDensity,uToneExposure; uniform int uClipCount,uFogType,uToneMapping,uOutputColorSpace,uPointColorSpace; uniform vec4 uClipPlane[MAX_CLIP]; uniform sampler2D uPointMap,uPointAlphaMap; uniform mat3 uPointMatrix,uPointAlphaMatrix; bool clipped(vec3 p){ for(int i=0;i<MAX_CLIP;i++){ if(i>=uClipCount) break; vec4 pl=uClipPlane[i]; if(dot(pl.xyz,p)+pl.w<0.0) return true; } return false; } float fogFactor(float d){ if(uFogType==1) return smoothstep(uFogNear,uFogFar,d); if(uFogType==2){ float f=1.0-exp(-uFogDensity*uFogDensity*d*d); return clamp(f,0.0,1.0); } return 0.0; } vec3 srgbToLinear(vec3 c){ return mix(c/12.92,pow((c+vec3(0.055))/1.055,vec3(2.4)),step(vec3(0.04045),c)); } vec4 colorTex(sampler2D tex, vec2 uv, int colorSpace){ vec4 c=texture2D(tex,uv); if(colorSpace==1) c.rgb=srgbToLinear(c.rgb); return c; } vec3 toneMap(vec3 c){ c=max(c,vec3(0.0)); if(uToneMapping==0) return clamp(c,0.0,1.0); c*=uToneExposure; if(uToneMapping==2) c=c/(vec3(1.0)+c); else if(uToneMapping==3) c=(c*(2.51*c+0.03))/(c*(2.43*c+0.59)+0.14); return clamp(c,0.0,1.0); } vec3 outputColor(vec3 c){ return uOutputColorSpace==1?mix(12.92*c,1.055*pow(c,vec3(1.0/2.4))-0.055,step(vec3(0.0031308),c)):c; } void main(){ if(clipped(vWorld)) discard; vec2 d=gl_PointCoord-vec2(.5); float r=dot(d,d); if(r>.25) discard; float a=smoothstep(.25,0.0,r); vec2 pointUv=(uPointMatrix*vec3(gl_PointCoord,1.0)).xy; vec2 pointAlphaUv=(uPointAlphaMatrix*vec3(gl_PointCoord,1.0)).xy; vec4 tex=mix(vec4(1.0),colorTex(uPointMap,pointUv,uPointColorSpace),uUsePointMap); float alphaTex=uUsePointAlphaMap<0.5?1.0:texture2D(uPointAlphaMap,pointAlphaUv).g; float outAlpha=uOpacity*a*tex.a*alphaTex; if(outAlpha<uPointAlphaTest) discard; vec3 c=mix(uColor*vColor*tex.rgb*(.65+uGlow*.85)*a,uFogColor,fogFactor(length(uCamera-vWorld))); gl_FragColor=vec4(outputColor(toneMap(c)),outAlpha); }`;
  const SVSH=`attribute vec3 aPosition; attribute vec3 aColor; attribute vec2 aUv; uniform mat4 uModel,uView,uProj; uniform vec3 uCameraRight,uCameraUp; uniform vec2 uSpriteCenter; uniform float uSpriteRotation,uSpriteSizeAttenuation; varying vec3 vWorld,vColor; varying vec2 vUv; void main(){ vec2 p=aPosition.xy-uSpriteCenter; float c=cos(uSpriteRotation), s=sin(uSpriteRotation); p=vec2(c*p.x-s*p.y,s*p.x+c*p.y); vec3 center=uModel[3].xyz; float sx=length(uModel[0].xyz); float sy=length(uModel[1].xyz); vec4 cv=uView*vec4(center,1.0); float atten=mix(max(0.0001,-cv.z),1.0,uSpriteSizeAttenuation); vec3 w=center+uCameraRight*p.x*sx*atten+uCameraUp*p.y*sy*atten; vWorld=w; vColor=aColor; vUv=aUv; gl_Position=uProj*uView*vec4(w,1.0); }`;
  const SFSH=`precision mediump float; const int MAX_CLIP=4; varying vec3 vWorld,vColor; varying vec2 vUv; uniform vec3 uColor,uCamera,uFogColor; uniform float uGlow,uOpacity,uUseSpriteMap,uUseSpriteAlphaMap,uSpriteAlphaTest,uFogNear,uFogFar,uFogDensity,uToneExposure; uniform int uClipCount,uFogType,uToneMapping,uOutputColorSpace,uSpriteColorSpace; uniform vec4 uClipPlane[MAX_CLIP]; uniform sampler2D uSpriteMap,uSpriteAlphaMap; uniform mat3 uSpriteMatrix,uSpriteAlphaMatrix; bool clipped(vec3 p){ for(int i=0;i<MAX_CLIP;i++){ if(i>=uClipCount) break; vec4 pl=uClipPlane[i]; if(dot(pl.xyz,p)+pl.w<0.0) return true; } return false; } float fogFactor(float d){ if(uFogType==1) return smoothstep(uFogNear,uFogFar,d); if(uFogType==2){ float f=1.0-exp(-uFogDensity*uFogDensity*d*d); return clamp(f,0.0,1.0); } return 0.0; } vec3 srgbToLinear(vec3 c){ return mix(c/12.92,pow((c+vec3(0.055))/1.055,vec3(2.4)),step(vec3(0.04045),c)); } vec4 colorTex(sampler2D tex, vec2 uv, int colorSpace){ vec4 c=texture2D(tex,uv); if(colorSpace==1) c.rgb=srgbToLinear(c.rgb); return c; } vec3 toneMap(vec3 c){ c=max(c,vec3(0.0)); if(uToneMapping==0) return clamp(c,0.0,1.0); c*=uToneExposure; if(uToneMapping==2) c=c/(vec3(1.0)+c); else if(uToneMapping==3) c=(c*(2.51*c+0.03))/(c*(2.43*c+0.59)+0.14); return clamp(c,0.0,1.0); } vec3 outputColor(vec3 c){ return uOutputColorSpace==1?mix(12.92*c,1.055*pow(c,vec3(1.0/2.4))-0.055,step(vec3(0.0031308),c)):c; } void main(){ if(clipped(vWorld)) discard; vec2 spriteUv=(uSpriteMatrix*vec3(vUv,1.0)).xy; vec2 spriteAlphaUv=(uSpriteAlphaMatrix*vec3(vUv,1.0)).xy; vec4 tex=mix(vec4(1.0),colorTex(uSpriteMap,spriteUv,uSpriteColorSpace),uUseSpriteMap); float alphaTex=uUseSpriteAlphaMap<0.5?1.0:texture2D(uSpriteAlphaMap,spriteAlphaUv).g; float outAlpha=uOpacity*tex.a*alphaTex; if(outAlpha<uSpriteAlphaTest) discard; vec3 base=uColor*vColor*tex.rgb*(.75+.55*uGlow); vec3 c=mix(base,uFogColor,fogFactor(length(uCamera-vWorld))); gl_FragColor=vec4(outputColor(toneMap(c)),outAlpha); }`;
  function shader(type,src){ const s=gl.createShader(type); gl.shaderSource(s,src); gl.compileShader(s); if(!gl.getShaderParameter(s,gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s)); return s; }
  function program(vs,fs){ const p=gl.createProgram(); gl.attachShader(p,shader(gl.VERTEX_SHADER,vs)); gl.attachShader(p,shader(gl.FRAGMENT_SHADER,fs)); gl.linkProgram(p); if(!gl.getProgramParameter(p,gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p)); return p; }
  const maxTextureUnits=gl.getParameter(gl.MAX_TEXTURE_IMAGE_UNITS) || 8;
  const maxCombinedTextureUnits=gl.getParameter(gl.MAX_COMBINED_TEXTURE_IMAGE_UNITS) || maxTextureUnits;
  const vertexTextureUnits=gl.getParameter(gl.MAX_VERTEX_TEXTURE_IMAGE_UNITS) || 0;
  const lineWidthRange=gl.getParameter(gl.ALIASED_LINE_WIDTH_RANGE)||[1,1];
  const floatTextureExt=gl.getExtension("OES_texture_float");
  const textureLodExt=gl.getExtension("EXT_shader_texture_lod");
  const boneTextureUnit=13;
  const envCubeTextureUnit=14;
  const clearcoatNormalTextureUnit=15;
  const usesClearcoatNormal=(DATA.cases||[]).some(c=>(c.objects||[]).some(o=>!!o.clearcoatNormalTexture));
  const clearcoatNormalTexturesEnabled=usesClearcoatNormal&&maxTextureUnits>clearcoatNormalTextureUnit&&maxCombinedTextureUnits>clearcoatNormalTextureUnit;
  const shadowTextureUnits=usesClearcoatNormal&&clearcoatNormalTexturesEnabled?[12]:[12,15];
  const boneTexturesEnabled=!!floatTextureExt&&vertexTextureUnits>0&&maxCombinedTextureUnits>boneTextureUnit;
  const cubeTexturesEnabled=maxTextureUnits>envCubeTextureUnit&&maxCombinedTextureUnits>envCubeTextureUnit;
  // Full physical materials declare 17 sampler2D uniforms plus the optional env cube sampler.
  const fullPhysicalSamplerCount=17+(cubeTexturesEnabled?1:0);
  const physicalTexturesEnabled=maxTextureUnits>=fullPhysicalSamplerCount&&maxCombinedTextureUnits>=fullPhysicalSamplerCount;
  const meshFragmentShader=physicalTexturesEnabled?FSH_EMISSIVE_VOLUME:FSH_EMISSIVE_CORE;
  const meshFragmentShaderCubeLod=(cubeTexturesEnabled&&textureLodExt)?meshFragmentShader
    .replace("#extension GL_OES_standard_derivatives : enable\\n  precision",
             "#extension GL_OES_standard_derivatives : enable\\n#extension GL_EXT_shader_texture_lod : enable\\n  precision")
    .replace("return textureCube(uEnvCubeMap,dir).rgb;",
             "return textureCubeLodEXT(uEnvCubeMap,dir,clamp(rough,0.0,1.0)*uEnvMaxLod).rgb;")
    :meshFragmentShader;
  const meshFragmentShaderRuntime=cubeTexturesEnabled?meshFragmentShaderCubeLod:meshFragmentShaderCubeLod.replace(/\\n  uniform samplerCube uEnvCubeMap;/,"").replace("vec3 envColor(vec3 dir,float rough){ if(uUseEnvCubeMap>0.5) return textureCube(uEnvCubeMap,dir).rgb; ","vec3 envColor(vec3 dir,float rough){ ");
  const meshProgram=program(VSH,meshFragmentShaderRuntime), meshBoneProgram=boneTexturesEnabled?program(VSH_BONE_TEXTURE,meshFragmentShaderRuntime):meshProgram, colorProgram=program(CVSH,CFSH), pointProgram=program(PVSH,PFSH), spriteProgram=program(SVSH,SFSH), depthProgram=program(DVSH,DFSH), depthBoneProgram=boneTexturesEnabled?program(DVSH_BONE_TEXTURE,DFSH):depthProgram, pointDepthProgram=program(PDVSH,PDFSH), pointDepthBoneProgram=boneTexturesEnabled?program(PDVSH_BONE_TEXTURE,PDFSH):pointDepthProgram;
  function buf(data,target=gl.ARRAY_BUFFER,ctor=Float32Array,usage=gl.STATIC_DRAW){ const b=gl.createBuffer(); gl.bindBuffer(target,b); gl.bufferData(target,new ctor(data),usage); return b; }
  const identityInstanceBuf=buf([1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]);
  const identityInstanceColorBuf=buf([1,1,1]);
  function isPow2(v){ return (v & (v - 1)) === 0; }
  function wrapMode(v){ return v==="mirror"?gl.MIRRORED_REPEAT:(v==="clamp"?gl.CLAMP_TO_EDGE:gl.REPEAT); }
  function magFilterMode(v){ return v==="nearest"?gl.NEAREST:gl.LINEAR; }
  function minFilterMode(v,pot){
    if(v==="nearest") return gl.NEAREST;
    if(v==="linear"||v==="bilinear") return gl.LINEAR;
    if(!pot) return v&&v.indexOf("nearest")===0?gl.NEAREST:gl.LINEAR;
    if(v==="nearest_mipmap_nearest") return gl.NEAREST_MIPMAP_NEAREST;
    if(v==="nearest_mipmap_linear") return gl.NEAREST_MIPMAP_LINEAR;
    if(v==="linear_mipmap_nearest") return gl.LINEAR_MIPMAP_NEAREST;
    return gl.LINEAR_MIPMAP_LINEAR;
  }
  function usesMipmaps(v){ return !!v&&v.indexOf("mipmap")>=0; }
  function applyAnisotropy(target,t){
    if(!anisotropyExt) return;
    const a=Math.max(1,Math.min(maxTextureAnisotropy,Number(t.maxAnisotropy||1)));
    if(a>1) gl.texParameterf(target,anisotropyExt.TEXTURE_MAX_ANISOTROPY_EXT,a);
  }
  function validTexturePayload(t){ return !!(t&&Number.isFinite(t.width)&&Number.isFinite(t.height)&&t.width>0&&t.height>0&&t.data&&t.data.length===t.width*t.height*4); }
  function uploadTextureData(t,tex){
    if(!validTexturePayload(t)) throw new Error("Texture payload is invalid");
    gl.bindTexture(gl.TEXTURE_2D,tex);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
    gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,t.width,t.height,0,gl.RGBA,gl.UNSIGNED_BYTE,new Uint8Array(t.data));
    const pot=isPow2(t.width)&&isPow2(t.height);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,pot?wrapMode(t.wrapS):gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,pot?wrapMode(t.wrapT):gl.CLAMP_TO_EDGE);
    const minFilter=t.minFilter||t.filter, magFilter=t.magFilter||t.filter;
    if(pot&&usesMipmaps(minFilter)) gl.generateMipmap(gl.TEXTURE_2D);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,minFilterMode(minFilter,pot));
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,magFilterMode(magFilter));
    applyAnisotropy(gl.TEXTURE_2D,t);
    t.needsUpdate=false;
  }
  function makeTexture(t){
    if(!t) return null;
    const tex=gl.createTexture();
    uploadTextureData(t,tex);
    t.__webglTexture=tex;
    return tex;
  }
  const cubeTargets=[gl.TEXTURE_CUBE_MAP_POSITIVE_X,gl.TEXTURE_CUBE_MAP_NEGATIVE_X,gl.TEXTURE_CUBE_MAP_POSITIVE_Y,gl.TEXTURE_CUBE_MAP_NEGATIVE_Y,gl.TEXTURE_CUBE_MAP_POSITIVE_Z,gl.TEXTURE_CUBE_MAP_NEGATIVE_Z];
  function makeSolidCubeTexture(){
    const tex=gl.createTexture(), data=new Uint8Array([0,0,0,255]); gl.bindTexture(gl.TEXTURE_CUBE_MAP,tex);
    for(const target of cubeTargets) gl.texImage2D(target,0,gl.RGBA,1,1,0,gl.RGBA,gl.UNSIGNED_BYTE,data);
    gl.texParameteri(gl.TEXTURE_CUBE_MAP,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_CUBE_MAP,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_CUBE_MAP,gl.TEXTURE_MIN_FILTER,gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_CUBE_MAP,gl.TEXTURE_MAG_FILTER,gl.NEAREST);
    return {texture:tex,maxLod:0};
  }
  function makeCubeTexture(env){
    if(!env||!env.faces||env.faces.length!==6) return null;
    const first=env.faces[0];
    if(!first||first.width!==first.height) return null;
    const tex=gl.createTexture(); gl.bindTexture(gl.TEXTURE_CUBE_MAP,tex);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
    for(let i=0;i<6;i++){
      const f=env.faces[i];
      if(!f||f.width!==first.width||f.height!==first.height||f.width!==f.height||!f.data||f.data.length!==f.width*f.height*4){ gl.deleteTexture(tex); return null; }
      gl.texImage2D(cubeTargets[i],0,gl.RGBA,f.width,f.height,0,gl.RGBA,gl.UNSIGNED_BYTE,new Uint8Array(f.data));
    }
    let uploadedMipmaps=false, mipCount=0;
    if(env.faces.every(f=>Array.isArray(f.mipmaps))){
      const count=env.faces[0].mipmaps.length;
      let complete=count>0;
      for(let level=1;complete&&level<=count;level++){
        const w=Math.max(1, first.width>>level), h=Math.max(1, first.height>>level);
        for(let i=0;i<6;i++){
          const m=env.faces[i].mipmaps[level-1];
          if(!m||m.width!==w||m.height!==h||!m.data||m.data.length!==w*h*4){ complete=false; break; }
        }
      }
      if(complete){
        mipCount=count;
        for(let level=1;level<=mipCount;level++){
          for(let i=0;i<6;i++){
            const m=env.faces[i].mipmaps[level-1];
            gl.texImage2D(cubeTargets[i],level,gl.RGBA,m.width,m.height,0,gl.RGBA,gl.UNSIGNED_BYTE,new Uint8Array(m.data));
          }
        }
        uploadedMipmaps=true;
      }
    }
    const pot=isPow2(first.width)&&isPow2(first.height), minFilter=first.minFilter||first.filter, magFilter=first.magFilter||first.filter;
    if(pot&&!uploadedMipmaps) gl.generateMipmap(gl.TEXTURE_CUBE_MAP);
    const maxLod=uploadedMipmaps?mipCount:(pot?Math.floor(Math.log2(first.width)):0);
    gl.texParameteri(gl.TEXTURE_CUBE_MAP,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_CUBE_MAP,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_CUBE_MAP,gl.TEXTURE_MIN_FILTER,minFilterMode(minFilter,pot));
    gl.texParameteri(gl.TEXTURE_CUBE_MAP,gl.TEXTURE_MAG_FILTER,magFilterMode(magFilter));
    applyAnisotropy(gl.TEXTURE_CUBE_MAP,first);
    return {texture:tex,maxLod:maxLod};
  }
  const defaultEnvCubeTex=cubeTexturesEnabled?makeSolidCubeTexture():null;
  function makeShadowTexture(s){
    if(!s) return null;
    const rgba=new Uint8Array(s.size*s.size*4);
    for(let i=0;i<s.data.length;i++){ const v=s.data[i]; rgba[4*i]=v; rgba[4*i+1]=v; rgba[4*i+2]=v; rgba[4*i+3]=255; }
    const tex=gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D,tex);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
    gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,s.size,s.size,0,gl.RGBA,gl.UNSIGNED_BYTE,rgba);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);
    return tex;
  }
  function makeDynamicShadowTarget(size,height=size){
    const tex=gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D,tex);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL,false);
    gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,size,height,0,gl.RGBA,gl.UNSIGNED_BYTE,null);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);
    const fb=gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER,fb);
    gl.framebufferTexture2D(gl.FRAMEBUFFER,gl.COLOR_ATTACHMENT0,gl.TEXTURE_2D,tex,0);
    const depth=gl.createRenderbuffer(); gl.bindRenderbuffer(gl.RENDERBUFFER,depth);
    gl.renderbufferStorage(gl.RENDERBUFFER,gl.DEPTH_COMPONENT16,size,height);
    gl.framebufferRenderbuffer(gl.FRAMEBUFFER,gl.DEPTH_ATTACHMENT,gl.RENDERBUFFER,depth);
    const status=gl.checkFramebufferStatus(gl.FRAMEBUFFER);
    gl.bindFramebuffer(gl.FRAMEBUFFER,null); gl.bindRenderbuffer(gl.RENDERBUFFER,null);
    if(status!==gl.FRAMEBUFFER_COMPLETE) throw new Error("Dynamic shadow framebuffer is incomplete");
    return {texture:tex,framebuffer:fb,depth:depth,size:size,width:size,height:height};
  }
  function packedTexture(items, channels){
    const base=items.find(t=>t);
    if(!base) return null;
    const out=Object.assign({},base,{data:new Array(4*base.width*base.height).fill(255)});
    for(let y=0;y<base.height;y++) for(let x=0;x<base.width;x++){
      const dst=4*(y*base.width+x);
      for(let k=0;k<4;k++){
        const src=items[k];
        if(!src) continue;
        const sx=Math.min(src.width-1,Math.floor(x*src.width/base.width));
        const sy=Math.min(src.height-1,Math.floor(y*src.height/base.height));
        out.data[dst+k]=src.data[4*(sy*src.width+sx)+channels[k]];
      }
    }
    return out;
  }
  function transformPoint(m,p){ const x=p[0],y=p[1],z=p[2]; return [m[0]*x+m[4]*y+m[8]*z+m[12], m[1]*x+m[5]*y+m[9]*z+m[13], m[2]*x+m[6]*y+m[10]*z+m[14]]; }
  function transformDir(m,p){ const x=p[0],y=p[1],z=p[2]; return [m[0]*x+m[4]*y+m[8]*z, m[1]*x+m[5]*y+m[9]*z, m[2]*x+m[6]*y+m[10]*z]; }
  function boneTextureSize(count){ let size=Math.sqrt(Math.max(1,count)*4); size=Math.ceil(size/4)*4; return Math.max(size,4); }
  function writeBoneTextureData(o,size,out){ out=out||new Float32Array(size*size*4); out.fill(0); if(!(o.skin&&o.skin.bones)) return out; for(let i=0;i<o.skin.bones.length;i++){ const m=M4.mul(o.skin.bones[i].matrix,o.skin.bindInverses[i]); const off=i*16; for(let j=0;j<16;j++) out[off+j]=m[j]; } return out; }
  function makeBoneTexture(o){ const size=boneTextureSize(o.skin.bones.length), data=writeBoneTextureData(o,size); const tex=gl.createTexture(); gl.activeTexture(gl.TEXTURE13); gl.bindTexture(gl.TEXTURE_2D,tex); gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL,false); gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,size,size,0,gl.RGBA,gl.FLOAT,data); gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.NEAREST); gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.NEAREST); return {texture:tex,size:size,data:data}; }
  function updateBoneTexture(o){ const bt=o.boneTex; if(!bt) return; writeBoneTextureData(o,bt.size,bt.data); gl.activeTexture(gl.TEXTURE13); gl.bindTexture(gl.TEXTURE_2D,bt.texture); gl.texSubImage2D(gl.TEXTURE_2D,0,0,0,bt.size,bt.size,gl.RGBA,gl.FLOAT,bt.data); }
  function currentBindMatrixInverse(o){ return o.bindMode==="attached"?M4.inv(o.matrix):(o.bindMatrixInverse||M4.ident()); }
  function eulerToQuat(e,order="XYZ"){ const x=e[0],y=e[1],z=e[2], c1=Math.cos(x/2), c2=Math.cos(y/2), c3=Math.cos(z/2), s1=Math.sin(x/2), s2=Math.sin(y/2), s3=Math.sin(z/2); if(order==="YXZ") return [s1*c2*c3+c1*s2*s3,c1*s2*c3-s1*c2*s3,c1*c2*s3-s1*s2*c3,c1*c2*c3+s1*s2*s3]; if(order==="ZXY") return [s1*c2*c3-c1*s2*s3,c1*s2*c3+s1*c2*s3,c1*c2*s3+s1*s2*c3,c1*c2*c3-s1*s2*s3]; if(order==="ZYX") return [s1*c2*c3-c1*s2*s3,c1*s2*c3+s1*c2*s3,c1*c2*s3-s1*s2*c3,c1*c2*c3+s1*s2*s3]; if(order==="YZX") return [s1*c2*c3+c1*s2*s3,c1*s2*c3+s1*c2*s3,c1*c2*s3-s1*s2*c3,c1*c2*c3-s1*s2*s3]; if(order==="XZY") return [s1*c2*c3-c1*s2*s3,c1*s2*c3-s1*c2*s3,c1*c2*s3+s1*s2*c3,c1*c2*c3+s1*s2*s3]; return [s1*c2*c3+c1*s2*s3,c1*s2*c3-s1*c2*s3,c1*c2*s3+s1*s2*c3,c1*c2*c3-s1*s2*s3]; }
  function buildNode(n){ n.parentMatrix=(n.parentMatrix||M4.ident()).slice(); n.basePosition=(n.basePosition||[0,0,0]).slice(); n.baseEuler=(n.baseEuler||[0,0,0]).slice(); n.baseEulerOrder=n.baseEulerOrder||"XYZ"; n.baseScale=(n.baseScale||[1,1,1]).slice(); n.baseQuaternion=(n.baseQuaternion||eulerToQuat(n.baseEuler,n.baseEulerOrder)).slice(); n.baseMatrix=n.matrix.slice(); n.animPos=n.basePosition.slice(); n.animEuler=n.baseEuler.slice(); n.animScale=n.baseScale.slice(); n.animQuat=n.baseQuaternion.slice(); return n; }
  function buildCamera(cam){
    if(!cam) return null;
    if(cam.type==="array"){
      cam.cameras=(cam.cameras||[]).map(buildCamera).filter(c=>c);
      cam.viewports=(cam.viewports||[]).map(v=>[Number(v[0])||0,Number(v[1])||0,Number(v[2])||0,Number(v[3])||0]);
      return cam;
    }
    cam.baseCamera={position:(cam.position||[0,0,0]).slice(),target:(cam.target||[0,0,0]).slice(),up:(cam.up||[0,1,0]).slice(),fov:cam.fov,aspect:cam.aspect,near:cam.near,far:cam.far,zoom:cam.zoom,left:cam.left,right:cam.right,bottom:cam.bottom,top:cam.top};
    return cam;
  }
  function eachCamera(cam,fn){ if(!cam) return; if(cam.type==="array"){ for(const child of cam.cameras||[]) eachCamera(child,fn); } else fn(cam); }
  function primaryCamera(cam){ if(!cam) return null; return cam.type==="array" ? ((cam.cameras||[])[0]||null) : cam; }
  const textureAnimBindings=[["clearcoat_normal_map_","clearcoatNormalTexture"],["clearcoat_roughness_map_","clearcoatRoughnessTexture"],["iridescence_thickness_map_","iridescenceThicknessTexture"],["specular_intensity_map_","specularIntensityTexture"],["specular_color_map_","specularColorTexture"],["specular_map_","specularColorTexture"],["glossiness_map_","specularColorTexture"],["sheen_roughness_map_","sheenRoughnessTexture"],["sheen_color_map_","sheenColorTexture"],["transmission_map_","transmissionTexture"],["thickness_map_","thicknessTexture"],["iridescence_map_","iridescenceTexture"],["anisotropy_map_","anisotropyTexture"],["emissive_map_","emissiveTexture"],["roughness_map_","roughnessTexture"],["metalness_map_","metalnessTexture"],["gradient_map_","gradientTexture"],["normal_map_","normalTexture"],["alpha_map_","alphaTexture"],["light_map_","lightTexture"],["ao_map_","aoTexture"],["clearcoat_map_","clearcoatTexture"],["matcap_","matcapTexture"],["map_","texture"]];
  function objectTextures(o){ return [o.texture,o.alphaTexture,o.emissiveTexture,o.aoTexture,o.lightTexture,o.roughnessTexture,o.metalnessTexture,o.normalTexture,o.matcapTexture,o.gradientTexture,o.clearcoatTexture,o.clearcoatRoughnessTexture,o.clearcoatNormalTexture,o.transmissionTexture,o.thicknessTexture,o.sheenColorTexture,o.sheenRoughnessTexture,o.iridescenceTexture,o.iridescenceThicknessTexture,o.specularIntensityTexture,o.specularColorTexture,o.anisotropyTexture].filter(t=>t); }
  function refreshTexture(t){ if(t&&t.needsUpdate===true&&t.__webglTexture) uploadTextureData(t,t.__webglTexture); }
  function refreshObjectTextures(o){
    const dirty=objectTextures(o).filter(t=>t.needsUpdate===true);
    for(const t of dirty) refreshTexture(t);
    if(physicalTexturesEnabled&&dirty.length){
      if([o.clearcoatTexture,o.clearcoatRoughnessTexture,o.transmissionTexture,o.sheenRoughnessTexture].some(t=>dirty.indexOf(t)>=0)){
        const packed=packedTexture([o.clearcoatTexture,o.clearcoatRoughnessTexture,o.transmissionTexture,o.sheenRoughnessTexture],[0,1,0,3]);
        if(packed){ if(o.physicalScalarTex) uploadTextureData(packed,o.physicalScalarTex); else o.physicalScalarTex=makeTexture(packed); }
      }
      if([o.iridescenceTexture,o.iridescenceThicknessTexture,o.specularIntensityTexture,o.thicknessTexture,o.anisotropyTexture].some(t=>dirty.indexOf(t)>=0)){
        const packed=packedTexture([o.iridescenceTexture,o.iridescenceThicknessTexture,o.specularIntensityTexture,o.thicknessTexture||o.anisotropyTexture],[0,1,3,o.thicknessTexture?1:2]);
        if(packed){ if(o.physicalScalar2Tex) uploadTextureData(packed,o.physicalScalar2Tex); else o.physicalScalar2Tex=makeTexture(packed); }
      }
    }
  }
  function captureTextureBase(t){ if(!t||t.baseTexture) return; t.baseTexture={offset:(t.offset||[0,0]).slice(),repeat:(t.repeat||[1,1]).slice(),rotation:t.rotation||0,center:(t.center||[0,0]).slice(),matrix:(t.matrix||[1,0,0,0,1,0,0,0,1]).slice(),matrixAutoUpdate:t.matrixAutoUpdate!==false}; }
  function updateTextureMatrix(t){ if(!t||t.matrixAutoUpdate===false) return; const sx=(t.repeat||[1,1])[0], sy=(t.repeat||[1,1])[1], tx=(t.offset||[0,0])[0], ty=(t.offset||[0,0])[1], cx=(t.center||[0,0])[0], cy=(t.center||[0,0])[1], c=Math.cos(t.rotation||0), s=Math.sin(t.rotation||0); t.matrix=[sx*c,sx*s,-sx*(c*cx+s*cy)+cx+tx,-sy*s,sy*c,sy*(s*cx-c*cy)+cy+ty,0,0,1]; }
  function resetTextureAnim(t){ const b=t&&t.baseTexture; if(!b) return; t.offset=b.offset.slice(); t.repeat=b.repeat.slice(); t.rotation=b.rotation; t.center=b.center.slice(); t.matrix=b.matrix.slice(); t.matrixAutoUpdate=b.matrixAutoUpdate; }
  function textureAnimTarget(o,prop){ for(const b of textureAnimBindings) if(prop.startsWith(b[0])) return [o[b[1]],prop.slice(b[0].length)]; return null; }
  function buildObj(o){
    o.parentMatrix=(o.parentMatrix||M4.ident()).slice(); o.instanceMatrices=(o.instanceMatrices&&o.instanceMatrices.length)?o.instanceMatrices.map(m=>m.slice()):null; o.instanceColors=(o.instanceColors&&o.instanceColors.length)?o.instanceColors.map(c=>c.slice()):null; o.instanceSource=!!(o.instanceMatrix||o.instanceMatrices); o.instanceMatrix=o.instanceMatrix?o.instanceMatrix.slice():M4.ident(); o.bindMode=o.bindMode||"attached"; o.bindMatrix=(o.bindMatrix||M4.ident()).slice(); o.bindMatrixInverse=(o.bindMatrixInverse||M4.ident()).slice(); o.basePosition=(o.basePosition||[0,0,0]).slice(); o.baseEuler=(o.baseEuler||[0,0,0]).slice(); o.baseEulerOrder=o.baseEulerOrder||"XYZ"; o.baseScale=(o.baseScale||[1,1,1]).slice(); o.baseQuaternion=(o.baseQuaternion||eulerToQuat(o.baseEuler,o.baseEulerOrder)).slice(); o.baseMatrix=o.matrix.slice(); o.baseTransparent=!!o.transparent; o.animTransparent=o.baseTransparent; o.animPos=o.basePosition.slice(); o.animEuler=o.baseEuler.slice(); o.animScale=o.baseScale.slice(); o.animQuat=o.baseQuaternion.slice();
    o.baseRenderable={visible:o.visible,color:o.color.slice(),opacity:o.opacity,transparent:o.transparent,alphaTest:o.alphaTest,depthTest:o.depthTest,depthWrite:o.depthWrite,normalScale:o.normalScale,depthNear:o.depthNear,depthFar:o.depthFar,toonSteps:o.toonSteps,roughness:o.roughness,metalness:o.metalness,clearcoat:o.clearcoat,clearcoatRoughness:o.clearcoatRoughness,clearcoatNormalScale:o.clearcoatNormalScale,transmission:o.transmission,thickness:o.thickness,attenuationDistance:o.attenuationDistance,attenuationColor:(o.attenuationColor||[1,1,1]).slice(),ior:o.ior,sheen:o.sheen,sheenColor:(o.sheenColor||[1,1,1]).slice(),sheenRoughness:o.sheenRoughness,iridescence:o.iridescence,iridescenceIor:o.iridescenceIor,iridescenceThickness:o.iridescenceThickness,specularIntensity:o.specularIntensity,specularColor:(o.specularColor||[1,1,1]).slice(),anisotropy:o.anisotropy,anisotropyRotation:o.anisotropyRotation,dispersion:o.dispersion,shininess:o.shininess,glossiness:o.glossiness,emissive:(o.emissive||[0,0,0]).slice(),emissiveIntensity:o.emissiveIntensity,aoIntensity:o.aoIntensity,lightMapIntensity:o.lightMapIntensity,envMapIntensity:o.envMapIntensity,pointSize:o.pointSize,pointSizeAttenuation:o.pointSizeAttenuation,linewidth:o.linewidth,lineDashed:o.lineDashed,dashSize:o.dashSize,gapSize:o.gapSize,dashScale:o.dashScale,spriteRotation:o.spriteRotation,spriteSizeAttenuation:o.spriteSizeAttenuation,glow:o.glow};
    o.visibilityStates=(o.visibilityStates&&o.visibilityStates.length)?o.visibilityStates:[{id:o.id,visible:o.visible!==false}]; for(const s of o.visibilityStates) s.baseVisible=s.visible!==false;
    o.basePositions=(o.basePositions&&o.basePositions.length)?o.basePositions.slice():o.positions.slice(); o.baseNormals=(o.normals&&o.normals.length)?o.normals.slice():new Array(o.positions.length).fill(0); o.baseTangents=(o.tangents&&o.tangents.length)?o.tangents.slice():[]; o.hasTangents=!!o.hasTangents; o.baseMorphNormals=(o.morphNormals&&o.morphNormals.length)?o.morphNormals.map(m=>m.slice()):[]; o.baseMorphTangents=(o.morphTangents&&o.morphTangents.length)?o.morphTangents.map(m=>m.slice()):[]; o.baseMorphWeights=(o.morphWeights||[]).slice(); o.morphWeights=o.baseMorphWeights.slice(); o.hasMorphTargets=!!((o.morphTargets&&o.morphTargets.length)||(o.baseMorphNormals&&o.baseMorphNormals.length)||(o.baseMorphTangents&&o.baseMorphTangents.length)); o.morphedPositions=null; o.morphedNormals=null; o.morphedTangents=null; o.morphDirty=o.hasMorphTargets;
    o.shaderSkin=!!(o.skin&&o.skin.bones&&o.skin.bones.length&&o.skin.bones.length<=MAX_BONES&&!o.hasMorphTargets);
    o.textureSkin=!!(o.skin&&o.skin.bones&&o.skin.bones.length>MAX_BONES&&boneTexturesEnabled&&!o.hasMorphTargets);
    o.skinDirty=!!(o.skin&&o.skin.bones&&o.skin.bones.length&&!(o.shaderSkin||o.textureSkin)); if(o.skin){ for(const b of o.skin.bones){ b.parentMatrix=(b.parentMatrix||M4.ident()).slice(); b.basePosition=(b.basePosition||[0,0,0]).slice(); b.baseEuler=(b.baseEuler||[0,0,0]).slice(); b.baseEulerOrder=b.baseEulerOrder||"XYZ"; b.baseScale=(b.baseScale||[1,1,1]).slice(); b.baseQuaternion=(b.baseQuaternion||eulerToQuat(b.baseEuler,b.baseEulerOrder)).slice(); b.baseMatrix=b.matrix.slice(); b.matrix=b.baseMatrix.slice(); b.animPos=b.basePosition.slice(); b.animEuler=b.baseEuler.slice(); b.animScale=b.baseScale.slice(); b.animQuat=b.baseQuaternion.slice(); } }
    const vertexCount=o.positions.length/3, defaultSkinIndex=new Array(vertexCount*4).fill(0), defaultSkinWeight=new Array(vertexCount*4).fill(0); for(let i=0;i<vertexCount;i++) defaultSkinWeight[4*i]=1;
    for(const t of objectTextures(o)) captureTextureBase(t);
    o.posBuf=buf(o.positions,gl.ARRAY_BUFFER,Float32Array,(o.morphDirty||o.skinDirty)?gl.DYNAMIC_DRAW:gl.STATIC_DRAW); o.nrmBuf=buf(o.normals,gl.ARRAY_BUFFER,Float32Array,(o.morphDirty||o.skinDirty)?gl.DYNAMIC_DRAW:gl.STATIC_DRAW); o.tanBuf=buf(o.tangents,gl.ARRAY_BUFFER,Float32Array,(o.morphDirty||o.skinDirty)?gl.DYNAMIC_DRAW:gl.STATIC_DRAW); o.uvBuf=buf(o.uvs); o.uv2Buf=buf(o.uv2s||o.uvs); o.colorBuf=buf(o.colors); o.lineDistanceBuf=buf(o.lineDistances||new Array(vertexCount).fill(0)); o.skinIndexBuf=buf(o.skin?o.skin.indices:defaultSkinIndex); o.skinWeightBuf=buf(o.skin?o.skin.weights:defaultSkinWeight); o.tex=makeTexture(o.texture); o.alphaTex=makeTexture(o.alphaTexture); o.emissiveTex=makeTexture(o.emissiveTexture); o.aoTex=makeTexture(o.aoTexture); o.lightTex=makeTexture(o.lightTexture); o.roughnessTex=makeTexture(o.roughnessTexture); o.metalnessTex=makeTexture(o.metalnessTexture); o.normalTex=makeTexture(o.normalTexture); o.clearcoatNormalTex=clearcoatNormalTexturesEnabled?makeTexture(o.clearcoatNormalTexture):null; o.matcapTex=makeTexture(o.matcapTexture); o.gradientTex=makeTexture(o.gradientTexture); o.physicalScalarTex=physicalTexturesEnabled?makeTexture(packedTexture([o.clearcoatTexture,o.clearcoatRoughnessTexture,o.transmissionTexture,o.sheenRoughnessTexture],[0,1,0,3])):null; o.physicalScalar2Tex=physicalTexturesEnabled?makeTexture(packedTexture([o.iridescenceTexture,o.iridescenceThicknessTexture,o.specularIntensityTexture,o.thicknessTexture||o.anisotropyTexture],[0,1,3,o.thicknessTexture?1:2])):null; o.sheenColorTex=physicalTexturesEnabled?makeTexture(o.sheenColorTexture):null; o.specularColorTex=physicalTexturesEnabled?makeTexture(o.specularColorTexture):null; o.boneTex=o.textureSkin?makeBoneTexture(o):null; o.envCubeTex=cubeTexturesEnabled?makeCubeTexture(o.envTexture):null;
    const maxIndex=o.indices.reduce((m,v)=>Math.max(m,v),0);
    o.indexType=maxIndex>65535 ? gl.UNSIGNED_INT : gl.UNSIGNED_SHORT;
    if(o.indexType===gl.UNSIGNED_INT && !gl.getExtension("OES_element_index_uint")) throw new Error("OES_element_index_uint is required for this exported geometry");
    o.idxBuf=buf(o.indices,gl.ELEMENT_ARRAY_BUFFER,o.indexType===gl.UNSIGNED_INT ? Uint32Array : Uint16Array);
    o.instanceCount=o.instanceMatrices?o.instanceMatrices.length:1; o.instanceBuf=o.instanceMatrices?buf(o.instanceMatrices.flat()):identityInstanceBuf; o.instanceColorBuf=o.instanceColors?buf(o.instanceColors.flat()):(o.instanceMatrices?buf(new Array(o.instanceCount*3).fill(1)):identityInstanceColorBuf);
    o.drawStart=Math.max(0,Math.min(Math.floor(Number(o.drawStart)||0),o.indices.length)); const remaining=Math.max(0,o.indices.length-o.drawStart), requested=o.drawCount==null?remaining:Math.max(0,Math.floor(Number(o.drawCount)||0)); o.count=Math.min(requested,remaining); return o;
  }
  for(const c of DATA.cases) c.camera=buildCamera(c.camera);
  for(const c of DATA.cases) c.nodes=(c.nodes||[]).map(buildNode);
  for(const c of DATA.cases) c.objects=c.objects.map(buildObj);
  const shadowTextureSlots=shadowTextureUnits.filter(u=>maxTextureUnits>u&&maxCombinedTextureUnits>u);
  const shadowTexturesEnabled=shadowTextureSlots.length>0;
  function cloneAnimValue(v){ return Array.isArray(v)?v.slice():v; }
  function captureLightBase(l){ const b={visible:l.visible!==false,color:(l.color||[1,1,1]).slice(),groundColor:(l.groundColor||[0,0,0]).slice(),intensity:l.intensity||0,distance:l.distance||0,decay:l.decay==null?2:l.decay}; for(const k of ["position","target","direction","angle","penumbra","coneCos","penumbraCos","forward","u","v","width","height","coeffs"]) if(l[k]!==undefined) b[k]=cloneAnimValue(l[k]); return b; }
  function refreshLightDerived(l){ if(l.type==="directional"&&l.position&&l.target) l.direction=norm(sub(l.position,l.target)); else if(l.type==="spot"){ if(l.position&&l.target) l.direction=norm(sub(l.target,l.position)); const fallback=l.coneCos==null?Math.cos(Math.PI/3):Math.max(-1,Math.min(1,l.coneCos)); const angle=Math.max(0,Math.min(Math.PI,l.angle==null?Math.acos(fallback):l.angle)); const pen=Math.max(0,Math.min(1,l.penumbra==null?0:l.penumbra)); l.coneCos=Math.cos(angle); l.penumbraCos=Math.cos(angle*(1-pen)); } else if(l.type==="rectArea"&&l.position&&l.target){ const f=norm(sub(l.target,l.position)), ref=Math.abs(f[1])<.95?[0,1,0]:[1,0,0]; l.forward=f; l.u=norm(cross(ref,f)); l.v=cross(f,l.u); } }
  function isDynamicShadow(s){ return !!s&&(s.type==="directionalDynamic"||s.type==="spotDynamic"||s.type==="pointDynamic"); }
  function buildLight(l){ if(l.shadow) l.shadowTexture=(shadowTexturesEnabled&&!isDynamicShadow(l.shadow))?makeShadowTexture(l.shadow):null; l.visibilityStates=(l.visibilityStates&&l.visibilityStates.length)?l.visibilityStates:[{id:l.id,visible:l.visible!==false}]; for(const s of l.visibilityStates) s.baseVisible=s.visible!==false; l.baseLight=captureLightBase(l); refreshLightDerived(l); return l; }
  for(const c of DATA.cases) c.lights=(c.lights||[]).map(buildLight);
  const objectById = new Map(); for(const c of DATA.cases) for(const o of c.objects) if(!objectById.has(o.id)) objectById.set(o.id,[]); for(const c of DATA.cases) for(const o of c.objects) objectById.get(o.id).push(o);
  const lightById = new Map(); for(const c of DATA.cases) for(const l of c.lights||[]){ if(!lightById.has(l.id)) lightById.set(l.id,[]); lightById.get(l.id).push(l); }
  const cameraById = new Map(); for(const c of DATA.cases) eachCamera(c.camera,cam=>{ if(cam.id==null) return; if(!cameraById.has(cam.id)) cameraById.set(cam.id,[]); cameraById.get(cam.id).push(cam); });
  const morphById = new Map(); for(const c of DATA.cases) for(const o of c.objects) for(const id of (o.morphTargetIds||[o.id])){ if(!morphById.has(id)) morphById.set(id,[]); morphById.get(id).push(o); }
  const visibilityById = new Map(); for(const c of DATA.cases) for(const o of c.objects) for(const s of (o.visibilityStates||[])){ if(!visibilityById.has(s.id)) visibilityById.set(s.id,[]); visibilityById.get(s.id).push(s); } for(const c of DATA.cases) for(const l of c.lights||[]) for(const s of (l.visibilityStates||[])){ if(!visibilityById.has(s.id)) visibilityById.set(s.id,[]); visibilityById.get(s.id).push(s); }
  const nodeById = new Map(); for(const c of DATA.cases) for(const n of c.nodes||[]){ if(!nodeById.has(n.id)) nodeById.set(n.id,[]); nodeById.get(n.id).push(n); } for(const c of DATA.cases) for(const o of c.objects) if(o.skin) for(const b of o.skin.bones){ if(!nodeById.has(b.id)) nodeById.set(b.id,[]); nodeById.get(b.id).push(b); }
  function attrib(p,name,b,size=3){ const loc=gl.getAttribLocation(p,name); if(loc<0)return; gl.bindBuffer(gl.ARRAY_BUFFER,b); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc,size,gl.FLOAT,false,0,0); }
  function drawOffset(o){ return o.drawStart*(o.indexType===gl.UNSIGNED_INT?4:2); }
  function instanceAttribs(p,o){
    if(!(instancingExt&&o.instanceBuf&&o.instanceCount>0)) return false;
    const names=["aInstanceMatrix0","aInstanceMatrix1","aInstanceMatrix2","aInstanceMatrix3"], stride=64;
    gl.bindBuffer(gl.ARRAY_BUFFER,o.instanceBuf);
    for(let i=0;i<4;i++){
      const loc=gl.getAttribLocation(p,names[i]);
      if(loc<0) continue;
      gl.enableVertexAttribArray(loc);
      gl.vertexAttribPointer(loc,4,gl.FLOAT,false,stride,i*16);
      instancingExt.vertexAttribDivisorANGLE(loc,1);
    }
    if(o.instanceColorBuf){
      const colorLoc=gl.getAttribLocation(p,"aInstanceColor");
      if(colorLoc>=0){
        gl.bindBuffer(gl.ARRAY_BUFFER,o.instanceColorBuf);
        gl.enableVertexAttribArray(colorLoc);
        gl.vertexAttribPointer(colorLoc,3,gl.FLOAT,false,0,0);
        instancingExt.vertexAttribDivisorANGLE(colorLoc,1);
      }
    }
    return true;
  }
  function clearInstanceAttribs(p){
    if(!instancingExt) return;
    const names=["aInstanceMatrix0","aInstanceMatrix1","aInstanceMatrix2","aInstanceMatrix3"];
    for(let i=0;i<4;i++){
      const loc=gl.getAttribLocation(p,names[i]);
      if(loc<0) continue;
      instancingExt.vertexAttribDivisorANGLE(loc,0);
      gl.disableVertexAttribArray(loc);
    }
    const colorLoc=gl.getAttribLocation(p,"aInstanceColor");
    if(colorLoc>=0){
      instancingExt.vertexAttribDivisorANGLE(colorLoc,0);
      gl.disableVertexAttribArray(colorLoc);
    }
  }
  function sampleTrack(tr,t){ const times=tr.times; if(times.length===0) return null; const stride=tr.kind==="quat"?4:(tr.kind==="weights"?tr.stride:(tr.kind==="number"?1:3)); if(t<=times[0]) return tr.values.slice(0,stride); if(t>=times[times.length-1]){ const j=times.length-1; return tr.values.slice(j*stride,j*stride+stride); } let i=0; while(i+1<times.length && times[i+1]<=t)i++; if(tr.interpolation==="step") return tr.values.slice(i*stride,i*stride+stride); const hi=Math.min(i+1,times.length-1); const a=times[i], b=times[hi]; const u=b===a?0:(t-a)/(b-a); if(tr.interpolation==="cubic" && tr.kind==="vec3") return catmull3(times,tr.values,i,u,stride); if(tr.interpolation==="cubic" && tr.kind==="number") return catmullN(times,tr.values,i,u,stride); const p=tr.values.slice(i*stride,i*stride+stride), q=tr.values.slice(hi*stride,hi*stride+stride); if(tr.interpolation==="cubicspline"){ const h=b-a; const m1=scaleN(tr.outTangents.slice(i*stride,i*stride+stride),h), m2=scaleN(tr.inTangents.slice(hi*stride,hi*stride+stride),h); const r=hermiteN(p,q,m1,m2,u); return tr.kind==="quat"?norm4(r):r; } return tr.kind==="quat"?slerp(p,q,u):(tr.kind==="weights"?mixN(p,q,u):(tr.kind==="number"?[mix(p[0],q[0],u)]:mix3(p,q,u))); }
  function clipTime(clip,t){ const d=clip.duration||0; if(d<=0) return 0; const x=t*(clip.timeScale==null?1:clip.timeScale), loop=clip.loop||"repeat", reps=clip.repetitions==null?-1:clip.repetitions, clamp=!!clip.clampWhenFinished; if(loop==="once"){ if(x<=0) return 0; if(x>=d) return clamp?d:0; return x; } const finite=reps>=0; const r=finite?Math.max(0,reps):Infinity; if(r===0) return 0; if(finite && x>=d*r){ if(!clamp) return 0; return loop==="pingpong" && r%2===0 ? 0 : d; } if(loop==="pingpong"){ const y=((x%(2*d))+(2*d))%(2*d); return y<=d?y:2*d-y; } const y=((x%d)+d)%d; return x>0 && Math.abs(y)<1e-9?d:y; }
  function normalizeTriples(a,stride){ for(let i=0;i<a.length/stride;i++){ const b=i*stride, l=Math.hypot(a[b],a[b+1],a[b+2]); if(l>1e-12){ a[b]/=l; a[b+1]/=l; a[b+2]/=l; } } return a; }
  function updateMorph(o){ if(!(o.hasMorphTargets&&o.morphDirty)) return; const p=o.basePositions.slice(), n=o.baseNormals.slice(), tan=o.hasTangents?o.baseTangents.slice():null, count=Math.max(o.morphTargets?o.morphTargets.length:0,o.baseMorphNormals?o.baseMorphNormals.length:0,o.baseMorphTangents?o.baseMorphTangents.length:0); for(let ti=0;ti<count;ti++){ const w=o.morphWeights[ti]||0, d=o.morphTargets?o.morphTargets[ti]:null, dn=o.baseMorphNormals?o.baseMorphNormals[ti]:null, dt=o.baseMorphTangents?o.baseMorphTangents[ti]:null; if(!w) continue; if(d) for(let i=0;i<Math.min(p.length,d.length);i++) p[i]+=d[i]*w; if(dn) for(let i=0;i<Math.min(n.length,dn.length);i++) n[i]+=dn[i]*w; if(tan&&dt) for(let vi=0;vi<tan.length/4;vi++){ tan[4*vi]+= (dt[3*vi]||0)*w; tan[4*vi+1]+= (dt[3*vi+1]||0)*w; tan[4*vi+2]+= (dt[3*vi+2]||0)*w; } } normalizeTriples(n,3); if(tan) normalizeTriples(tan,4); o.morphedPositions=p; o.morphedNormals=n; o.morphedTangents=tan; o.positions=p; o.normals=n; gl.bindBuffer(gl.ARRAY_BUFFER,o.posBuf); gl.bufferSubData(gl.ARRAY_BUFFER,0,new Float32Array(p)); gl.bindBuffer(gl.ARRAY_BUFFER,o.nrmBuf); gl.bufferSubData(gl.ARRAY_BUFFER,0,new Float32Array(n)); if(tan){ o.tangents=tan; gl.bindBuffer(gl.ARRAY_BUFFER,o.tanBuf); gl.bufferSubData(gl.ARRAY_BUFFER,0,new Float32Array(tan)); } o.morphDirty=false; }
  function skinMatrices(o){ const out=new Array(MAX_BONES*16).fill(0); for(let i=0;i<MAX_BONES;i++){ out[i*16]=1; out[i*16+5]=1; out[i*16+10]=1; out[i*16+15]=1; } if(o.shaderSkin){ for(let i=0;i<o.skin.bones.length;i++){ const m=M4.mul(o.skin.bones[i].matrix,o.skin.bindInverses[i]); for(let j=0;j<16;j++) out[i*16+j]=m[j]; } } return out; }
  function updateSkin(o){ if(!(o.skin&&o.skinDirty)) return; if(o.shaderSkin||o.textureSkin){ o.skinDirty=false; return; } const base=o.morphedPositions||o.basePositions, baseN=o.morphedNormals||o.baseNormals, baseT=o.morphedTangents||o.baseTangents, skin=o.skin, bind=o.bindMatrix||M4.ident(), bindInv=currentBindMatrixInverse(o), p=new Array(base.length).fill(0), n=new Array(baseN.length).fill(0), tan=o.hasTangents?new Array(baseT.length).fill(0):null, mats=skin.bones.map((b,i)=>M4.mul(M4.mul(bindInv,M4.mul(b.matrix,skin.bindInverses[i])),bind)); for(let vi=0;vi<base.length/3;vi++){ const v=[base[3*vi],base[3*vi+1],base[3*vi+2]], vn=[baseN[3*vi]||0,baseN[3*vi+1]||0,baseN[3*vi+2]||0], vt=tan?[baseT[4*vi]||1,baseT[4*vi+1]||0,baseT[4*vi+2]||0]:null; if(tan) tan[4*vi+3]=baseT[4*vi+3]==null?1:baseT[4*vi+3]; for(let k=0;k<4;k++){ const w=skin.weights[4*vi+k]||0, bi=skin.indices[4*vi+k]||0; if(!w) continue; const m=mats[bi], q=transformPoint(m,v), nq=transformDir(m,vn); p[3*vi]+=q[0]*w; p[3*vi+1]+=q[1]*w; p[3*vi+2]+=q[2]*w; n[3*vi]+=nq[0]*w; n[3*vi+1]+=nq[1]*w; n[3*vi+2]+=nq[2]*w; if(tan){ const tq=transformDir(m,vt); tan[4*vi]+=tq[0]*w; tan[4*vi+1]+=tq[1]*w; tan[4*vi+2]+=tq[2]*w; } } const nl=Math.hypot(n[3*vi],n[3*vi+1],n[3*vi+2]); if(nl>1e-12){ n[3*vi]/=nl; n[3*vi+1]/=nl; n[3*vi+2]/=nl; } if(tan){ const tl=Math.hypot(tan[4*vi],tan[4*vi+1],tan[4*vi+2]); if(tl>1e-12){ tan[4*vi]/=tl; tan[4*vi+1]/=tl; tan[4*vi+2]/=tl; } else { tan[4*vi]=baseT[4*vi]||1; tan[4*vi+1]=baseT[4*vi+1]||0; tan[4*vi+2]=baseT[4*vi+2]||0; } } } o.positions=p; o.normals=n; gl.bindBuffer(gl.ARRAY_BUFFER,o.posBuf); gl.bufferSubData(gl.ARRAY_BUFFER,0,new Float32Array(p)); gl.bindBuffer(gl.ARRAY_BUFFER,o.nrmBuf); gl.bufferSubData(gl.ARRAY_BUFFER,0,new Float32Array(n)); if(tan){ o.tangents=tan; gl.bindBuffer(gl.ARRAY_BUFFER,o.tanBuf); gl.bufferSubData(gl.ARRAY_BUFFER,0,new Float32Array(tan)); } o.skinDirty=false; }
  function glossinessFromShininess(n){ return Math.max(0,Math.min(1,1-Math.pow(2/(Math.max(n,0.0001)+2),0.25))); }
  function shininessFromGlossiness(g){ const r=1-Math.max(0,Math.min(1,g)); return Math.max(2/Math.max(Math.pow(r,4),0.0001)-2,0.0001); }
  function assignComponent(dst,component,v){ if(component>0) dst[component-1]=v[0]; else for(let i=0;i<Math.min(dst.length,v.length);i++) dst[i]=v[i]; return dst; }
  function setTextureAnim(o,prop,v,component=0){ const hit=textureAnimTarget(o,prop); if(!hit) return false; const t=hit[0], field=hit[1]; if(!t) return false; if(field==="matrix_auto_update"){ t.matrixAutoUpdate=v[0]>=.5; updateTextureMatrix(t); return true; } if(field==="rotation"){ t.rotation=component>0?v[0]:v[0]; updateTextureMatrix(t); return true; } if(field==="offset"||field==="repeat"||field==="center"){ assignComponent(t[field],component,v); updateTextureMatrix(t); return true; } return false; }
  function setRenderableAnim(o,prop,v,component=0){ if(setTextureAnim(o,prop,v,component)) return true; if(!(prop in o)) return false; if(prop==="visible"||prop==="spriteSizeAttenuation"||typeof o[prop]==="boolean"){ o[prop]=v[0]>=.5; if(prop==="transparent") o.animTransparent=o.transparent||o.opacity<1; return true; } if(Array.isArray(o[prop])) assignComponent(o[prop],component,v); else o[prop]=component>0?v[0]:v[0]; if(prop==="shininess") o.glossiness=glossinessFromShininess(o.shininess); if(prop==="glossiness") o.shininess=shininessFromGlossiness(o.glossiness); if(prop==="opacity") o.animTransparent=(o.baseTransparent||false)||o.opacity<1; return true; }
  function resetRenderableAnim(o){ const b=o.baseRenderable; if(!b)return; for(const k in b) o[k]=Array.isArray(b[k])?b[k].slice():b[k]; for(const t of objectTextures(o)) resetTextureAnim(t); o.animTransparent=o.baseTransparent; for(const s of (o.visibilityStates||[])) s.visible=s.baseVisible; }
  function setLightAnim(l,prop,v,component=0){ if(!(prop in l)) return false; if(prop==="visible"){ l.visible=v[0]>=.5; refreshLightDerived(l); return true; } if(Array.isArray(l[prop])) assignComponent(l[prop],component,v); else l[prop]=component>0?v[0]:v[0]; refreshLightDerived(l); return true; }
  function resetLightAnim(l){ const b=l.baseLight; if(!b)return; for(const k in b) l[k]=cloneAnimValue(b[k]); for(const s of (l.visibilityStates||[])) s.visible=s.baseVisible; refreshLightDerived(l); }
  function setCameraAnim(cam,prop,v,component=0){ if(!cam||!(prop in cam)) return false; if(Array.isArray(cam[prop])) assignComponent(cam[prop],component,v); else cam[prop]=component>0?v[0]:v[0]; return true; }
  function resetCameraAnim(cam){ if(!cam)return; if(cam.type==="array"){ for(const child of cam.cameras||[]) resetCameraAnim(child); return; } const b=cam.baseCamera; if(!b)return; for(const k in b) if(b[k]!==undefined) cam[k]=Array.isArray(b[k])?b[k].slice():b[k]; }
  function setNodeAnim(n,prop,v,component=0){ if(prop==="position") assignComponent(n.animPos,component,v); else if(prop==="scale") assignComponent(n.animScale,component,v); else if(prop==="quaternion"){ assignComponent(n.animQuat,component,v); n.animQuat=norm4(n.animQuat); } else if(prop==="rotation"){ assignComponent(n.animEuler,component,v); n.animQuat=eulerToQuat(n.animEuler,n.baseEulerOrder||"XYZ"); } n.matrix=M4.mul(n.parentMatrix||M4.ident(),M4.trs(n.animPos,n.animQuat,n.animScale)); }
  function updateTransformGraph(c){ const nodeMap=new Map(); for(const n of c.nodes||[]){ const p=n.parentId?nodeMap.get(n.parentId):null; n.parentMatrix=p?p.matrix:M4.ident(); n.matrix=M4.mul(n.parentMatrix,M4.trs(n.animPos,n.animQuat,n.animScale)); nodeMap.set(n.id,n); } c.nodeMap=nodeMap; for(const o of c.objects){ const p=o.parentId?nodeMap.get(o.parentId):null; if(p) o.parentMatrix=p.matrix; const local=M4.trs(o.animPos,o.animQuat,o.animScale), world=M4.mul(o.parentMatrix||M4.ident(),local); o.transformMatrix=world; o.matrix=M4.mul(world,o.instanceMatrix||M4.ident()); if(!o.instanceSource) nodeMap.set(o.id,o); } }
  function updateBoneGraph(c){ const graph=c.nodeMap||new Map(), bones=new Map(), state=new Map(); for(const o of c.objects) if(o.skin&&o.skin.bones) for(const b of o.skin.bones) bones.set(b.id,b); const resolve=b=>{ const st=state.get(b.id); if(st===2) return b.matrix; if(st===1) return b.baseMatrix; state.set(b.id,1); let parent=b.parentMatrix||M4.ident(); if(b.parentId){ if(bones.has(b.parentId)) parent=resolve(bones.get(b.parentId)); else if(graph.has(b.parentId)) parent=graph.get(b.parentId).matrix; } b.parentMatrix=parent; b.matrix=M4.mul(parent,M4.trs(b.animPos,b.animQuat,b.animScale)); state.set(b.id,2); return b.matrix; }; for(const b of bones.values()) resolve(b); }
  function applyAnimations(c,t){ if(c.camera) resetCameraAnim(c.camera); for(const l of c.lights||[]) resetLightAnim(l); for(const n of c.nodes||[]){ n.animPos=n.basePosition.slice(); n.animEuler=n.baseEuler.slice(); n.animScale=n.baseScale.slice(); n.animQuat=n.baseQuaternion.slice(); n.matrix=n.baseMatrix; } for(const o of c.objects){ o.animPos=o.basePosition.slice(); o.animEuler=o.baseEuler.slice(); o.animScale=o.baseScale.slice(); o.animQuat=o.baseQuaternion.slice(); o.matrix=o.baseMatrix; resetRenderableAnim(o); if(o.hasMorphTargets){ o.morphWeights=o.baseMorphWeights.slice(); o.morphDirty=true; } if(o.skin){ o.skinDirty=true; for(const b of o.skin.bones){ b.animPos=b.basePosition.slice(); b.animEuler=b.baseEuler.slice(); b.animScale=b.baseScale.slice(); b.animQuat=b.baseQuaternion.slice(); b.matrix=b.baseMatrix; } } } for(const clip of c.animations){ const ct=clipTime(clip,t); for(const tr of clip.tracks){ const v=sampleTrack(tr,ct); if(v==null) continue; if(tr.property==="morph_target_influences"){ for(const o of (morphById.get(tr.target)||[])){ if((tr.component||0)>0) o.morphWeights[tr.component-1]=v[0]; else o.morphWeights=v.slice(); o.morphDirty=true; } continue; } const lights=lightById.get(tr.target)||[]; if(tr.property==="visible"){ for(const s of (visibilityById.get(tr.target)||[])) s.visible=v[0]>=.5; for(const l of lights) setLightAnim(l,tr.property,v,tr.component||0); continue; } for(const l of lights) setLightAnim(l,tr.property,v,tr.component||0); for(const cam of (cameraById.get(tr.target)||[])) setCameraAnim(cam,tr.property,v,tr.component||0); const objs=objectById.get(tr.target)||[]; for(const o of objs) if(!setRenderableAnim(o,tr.property,v,tr.component||0)) setNodeAnim(o,tr.property,v,tr.component||0); for(const n of (nodeById.get(tr.target)||[])) setNodeAnim(n,tr.property,v,tr.component||0); } } updateTransformGraph(c); updateBoneGraph(c); for(const o of c.objects){ updateMorph(o); updateSkin(o); } }
  const MAX_DIR=4, MAX_POINT=4, MAX_SPOT=4, MAX_HEMI=4, MAX_RECT=4;
  function padded3(items, limit, fn){ const out=new Array(limit*3).fill(0); for(let i=0;i<Math.min(limit,items.length);i++){ const v=fn(items[i]); out[i*3]=v[0]; out[i*3+1]=v[1]; out[i*3+2]=v[2]; } return out; }
  function padded2(items, limit, fn){ const out=new Array(limit*2).fill(0); for(let i=0;i<Math.min(limit,items.length);i++){ const v=fn(items[i]); out[i*2]=v[0]; out[i*2+1]=v[1]; } return out; }
  function padded1(items, limit, fn, fill=0){ const out=new Array(limit).fill(fill); for(let i=0;i<Math.min(limit,items.length);i++) out[i]=fn(items[i]); return out; }
  function clipping(c){ const planes=c.clippingPlanes||[], out=new Array(16).fill(0); for(let i=0;i<Math.min(4,planes.length);i++){ const p=planes[i]; out[i*4]=p[0]; out[i*4+1]=p[1]; out[i*4+2]=p[2]; out[i*4+3]=p[3]; } return {count:Math.min(4,planes.length), planes:out}; }
  function objectClipping(o,clip){ const planes=clip.planes.slice(), locals=o.clippingPlanes||[]; let count=clip.count; for(let i=0;i<locals.length&&count<4;i++,count++){ const p=locals[i], k=count*4; planes[k]=p[0]; planes[k+1]=p[1]; planes[k+2]=p[2]; planes[k+3]=p[3]; } return {count:count, planes:planes}; }
  function fog(c){ const f=c.fog; if(!f) return {type:0,color:[0,0,0],near:1,far:1000,density:0}; return {type:f.type==="exp2"?2:1,color:f.color,near:f.near==null?1:f.near,far:f.far||1000,density:f.density||0}; }
  function lighting(c){ const amb=[0.18,0.18,0.18], dirs=[], points=[], spots=[], hemis=[], rects=[], shadows=[]; const addShadow=(kind,index,l)=>{ if(l.shadowTexture&&shadows.length<shadowTextureSlots.length){ const pointMode=l.shadow&&l.shadow.type==="pointDynamic"; shadows.push({kind:kind,index:index,tex:l.shadowTexture,matrix:l.shadow.matrix,bias:l.shadow.bias==null?0.0015:l.shadow.bias,pcfRadius:l.shadow.pcfRadius==null?0:l.shadow.pcfRadius,texel:1/(l.shadow.size||64),mode:pointMode?1:0,pointPosition:l.position||[0,0,0],pointFar:l.shadow.far||1,pointMatrices:l.shadow.matrices||[]}); } }; for(const l of c.lights||[]){ if(l.visible===false||(l.visibilityStates||[]).some(s=>s.visible===false)) continue; const scaled=[l.color?.[0]*(l.intensity||0),l.color?.[1]*(l.intensity||0),l.color?.[2]*(l.intensity||0)]; if(l.type==="ambient"){ amb[0]+=scaled[0]; amb[1]+=scaled[1]; amb[2]+=scaled[2]; } else if(l.type==="directional" && dirs.length<MAX_DIR){ const idx=dirs.length; dirs.push({color:scaled,direction:l.direction}); addShadow(1,idx,l); } else if(l.type==="rectArea" && rects.length<MAX_RECT){ rects.push({color:scaled,position:l.position,forward:l.forward,u:l.u,v:l.v,size:[l.width||0,l.height||0]}); } else if(l.type==="point" && points.length<MAX_POINT){ const idx=points.length; points.push({color:scaled,position:l.position,distance:l.distance||0,decay:l.decay==null?2:l.decay}); addShadow(3,idx,l); } else if(l.type==="spot" && spots.length<MAX_SPOT){ const idx=spots.length; spots.push({color:scaled,position:l.position,direction:l.direction,distance:l.distance||0,decay:l.decay==null?2:l.decay,coneCos:l.coneCos,penumbraCos:l.penumbraCos}); addShadow(2,idx,l); } else if(l.type==="hemisphere" && hemis.length<MAX_HEMI){ hemis.push({sky:scaled,ground:[l.groundColor[0]*(l.intensity||0),l.groundColor[1]*(l.intensity||0),l.groundColor[2]*(l.intensity||0)]}); } } return {ambient:amb,dirCount:dirs.length,dirColor:padded3(dirs,MAX_DIR,l=>l.color),direction:padded3(dirs,MAX_DIR,l=>l.direction),shadows:shadows,rectCount:rects.length,rectColor:padded3(rects,MAX_RECT,l=>l.color),rectPosition:padded3(rects,MAX_RECT,l=>l.position),rectForward:padded3(rects,MAX_RECT,l=>l.forward),rectU:padded3(rects,MAX_RECT,l=>l.u),rectV:padded3(rects,MAX_RECT,l=>l.v),rectSize:padded2(rects,MAX_RECT,l=>l.size),pointCount:points.length,pointColor:padded3(points,MAX_POINT,l=>l.color),pointPosition:padded3(points,MAX_POINT,l=>l.position),pointDistance:padded1(points,MAX_POINT,l=>l.distance),pointDecay:padded1(points,MAX_POINT,l=>l.decay,2),spotCount:spots.length,spotColor:padded3(spots,MAX_SPOT,l=>l.color),spotPosition:padded3(spots,MAX_SPOT,l=>l.position),spotDirection:padded3(spots,MAX_SPOT,l=>l.direction),spotDistance:padded1(spots,MAX_SPOT,l=>l.distance),spotDecay:padded1(spots,MAX_SPOT,l=>l.decay,2),spotConeCos:padded1(spots,MAX_SPOT,l=>l.coneCos),spotPenumbraCos:padded1(spots,MAX_SPOT,l=>l.penumbraCos),hemiCount:hemis.length,hemiSky:padded3(hemis,MAX_HEMI,l=>l.sky),hemiGround:padded3(hemis,MAX_HEMI,l=>l.ground)}; }
  function uniform3v(p,name,val){ const loc=gl.getUniformLocation(p,name); if(loc!==null) gl.uniform3fv(loc,new Float32Array(val)); }
  function uniform2v(p,name,val){ const loc=gl.getUniformLocation(p,name); if(loc!==null) gl.uniform2fv(loc,new Float32Array(val)); }
  function uniform4v(p,name,val){ const loc=gl.getUniformLocation(p,name); if(loc!==null) gl.uniform4fv(loc,new Float32Array(val)); }
  function uniform1fv(p,name,val){ const loc=gl.getUniformLocation(p,name); if(loc!==null) gl.uniform1fv(loc,new Float32Array(val)); }
  function uniform1iv(p,name,val){ const loc=gl.getUniformLocation(p,name); if(loc!==null) gl.uniform1iv(loc,new Int32Array(val)); }
  function uniform1f(p,name,val){ const loc=gl.getUniformLocation(p,name); if(loc!==null) gl.uniform1f(loc,val); }
  function uniform1i(p,name,val){ const loc=gl.getUniformLocation(p,name); if(loc!==null) gl.uniform1i(loc,val); }
  function bindSkinState(p,o){ uniform1i(p,"uUseSkin",(o.shaderSkin||o.textureSkin)?1:0); uniform1i(p,"uUseBoneTexture",o.textureSkin?1:0); const bindLoc=gl.getUniformLocation(p,"uBindMatrix"); if(bindLoc!==null) gl.uniformMatrix4fv(bindLoc,false,new Float32Array(o.bindMatrix||M4.ident())); const bindInvLoc=gl.getUniformLocation(p,"uBindMatrixInverse"); if(bindInvLoc!==null) gl.uniformMatrix4fv(bindInvLoc,false,new Float32Array(currentBindMatrixInverse(o))); if(o.textureSkin&&o.boneTex){ updateBoneTexture(o); uniform1i(p,"uBoneTexture",boneTextureUnit); uniform2v(p,"uBoneTextureSize",[o.boneTex.size,o.boneTex.size]); } const boneLoc=gl.getUniformLocation(p,"uBoneMatrices[0]"); if(boneLoc!==null) gl.uniformMatrix4fv(boneLoc,false,new Float32Array(skinMatrices(o))); }
  function shadowMatrices(shadows){ const out=[]; for(let i=0;i<2;i++) out.push(...((shadows[i]&&shadows[i].matrix)||M4.ident())); return out; }
  function shadowValues(shadows,key,fill){ const out=[]; for(let i=0;i<2;i++) out.push(shadows[i]&&shadows[i][key]!=null?shadows[i][key]:fill); return out; }
  function shadowPointPositions(shadows){ const out=[]; for(let i=0;i<2;i++) out.push(...((shadows[i]&&shadows[i].pointPosition)||[0,0,0])); return out; }
  function shadowPointMatrices(shadows,slot){ const s=shadows[slot], out=[]; for(let i=0;i<6;i++) out.push(...((s&&s.pointMatrices&&s.pointMatrices[i])||M4.ident())); return out; }
  function bindShadowMaps(p,shadows){ const n=Math.min(shadows.length,shadowTextureSlots.length,2); for(let i=0;i<n;i++){ const s=shadows[i]; if(!s||!s.tex) continue; const unit=shadowTextureSlots[i]; gl.activeTexture(gl.TEXTURE0+unit); gl.bindTexture(gl.TEXTURE_2D,s.tex); gl.uniform1i(gl.getUniformLocation(p,i===0?"uShadowMap0":"uShadowMap1"),unit); } }
  function includeShadowPoint(bounds,p){ for(let k=0;k<3;k++){ bounds.min[k]=Math.min(bounds.min[k],p[k]); bounds.max[k]=Math.max(bounds.max[k],p[k]); } }
  function currentSkinMatrices(o){ if(!(o.skin&&o.skin.bones)) return null; const bind=o.bindMatrix||M4.ident(), bindInv=currentBindMatrixInverse(o); return o.skin.bones.map((b,i)=>M4.mul(M4.mul(bindInv,M4.mul(b.matrix,o.skin.bindInverses[i])),bind)); }
  function skinnedShadowPosition(o,vi,mats){ const p=o.positions||[], base=[p[3*vi],p[3*vi+1],p[3*vi+2]], idx=o.skin.indices, weights=o.skin.weights; let out=[0,0,0], used=false; for(let k=0;k<4;k++){ const w=weights[4*vi+k]||0, bi=idx[4*vi+k]||0; if(!w||!mats[bi]) continue; const q=transformPoint(mats[bi],base); out[0]+=q[0]*w; out[1]+=q[1]*w; out[2]+=q[2]*w; used=true; } return used?out:base; }
  function includeShadowObject(bounds,o,model){ const p=o.positions||[], skinMats=(o.shaderSkin||o.textureSkin)?currentSkinMatrices(o):null; for(let i=0;i<p.length;i+=3){ const local=skinMats?skinnedShadowPosition(o,i/3,skinMats):[p[i],p[i+1],p[i+2]]; includeShadowPoint(bounds,transformPoint(model,local)); } }
  function shadowBounds(visible){ const bounds={min:[Infinity,Infinity,Infinity],max:[-Infinity,-Infinity,-Infinity]}; for(const o of visible){ if(o.mode!=="triangles"||!(o.castShadow||o.receiveShadow)) continue; if(o.instanceMatrices&&o.instanceMatrices.length){ for(const im of o.instanceMatrices) includeShadowObject(bounds,o,M4.mul(o.matrix,im)); } else includeShadowObject(bounds,o,o.matrix); } if(!isFinite(bounds.min[0])) return {center:[0,0,0],radius:1}; const center=[(bounds.min[0]+bounds.max[0])*.5,(bounds.min[1]+bounds.max[1])*.5,(bounds.min[2]+bounds.max[2])*.5], half=[(bounds.max[0]-bounds.min[0])*.5,(bounds.max[1]-bounds.min[1])*.5,(bounds.max[2]-bounds.min[2])*.5]; return {center:center,radius:Math.max(Math.hypot(half[0],half[1],half[2]),1e-3)}; }
  function shadowSafeUp(dir){ return Math.abs(dir[1])>.99?[1,0,0]:[0,1,0]; }
  function perspectiveShadowPlanes(pos,center,radius){ const d=Math.hypot(pos[0]-center[0],pos[1]-center[1],pos[2]-center[2]), near=Math.max(d-radius,Math.max(radius,d)*1e-2,1e-4), far=Math.max(d+radius,near*(1+1e-6)); return {near:near,far:far}; }
  function directionalShadowMatrix(l,center,radius){ const pos=l.position||scale(l.direction||[0,1,0],1), tgt=l.target||[0,0,0], dir=norm(sub(pos,tgt)), eye=add(center,scale(dir,radius*2)), view=M4.lookAt(eye,center,shadowSafeUp(dir)), s=Math.max(radius*1.1,1e-3); return M4.mul(M4.orthographic(-s,s,-s,s,0.01,Math.max(radius*4,0.02)),view); }
  function spotShadowMatrix(l,center,radius){ const pos=l.position||[0,0,0]; let tgt=l.target||add(pos,l.direction||[0,-1,0]); if(Math.hypot(tgt[0]-pos[0],tgt[1]-pos[1],tgt[2]-pos[2])<1e-6) tgt=add(pos,[0,-1,0]); const dir=norm(sub(tgt,pos)), planes=perspectiveShadowPlanes(pos,center,radius), fov=Math.min(Math.max((l.angle||Math.PI/3)*2,1e-3),Math.PI*.9), view=M4.lookAt(pos,tgt,shadowSafeUp(dir)); return M4.mul(M4.perspective(fov,1,planes.near,planes.far),view); }
  function ensureDynamicShadowTarget(l){ if(!l.dynamicShadowTarget){ const size=Math.max(1,l.shadow&&l.shadow.size?l.shadow.size:64); l.dynamicShadowTarget=makeDynamicShadowTarget(size); } l.shadowTexture=l.dynamicShadowTarget.texture; return l.dynamicShadowTarget; }
  const pointShadowFaces=[
    {dir:[1,0,0],up:[0,-1,0],cell:[0,0]},
    {dir:[-1,0,0],up:[0,-1,0],cell:[1,0]},
    {dir:[0,1,0],up:[0,0,1],cell:[2,0]},
    {dir:[0,-1,0],up:[0,0,-1],cell:[3,0]},
    {dir:[0,0,1],up:[0,-1,0],cell:[0,1]},
    {dir:[0,0,-1],up:[0,-1,0],cell:[1,1]}
  ];
  function pointShadowFar(l,center,radius){ const pos=l.position||[0,0,0], bound=Math.hypot(pos[0]-center[0],pos[1]-center[1],pos[2]-center[2])+radius, ranged=l.distance&&l.distance>0?Math.min(bound,l.distance):bound; return Math.max(ranged,0.02); }
  function pointShadowMatrices(pos,far){ const near=Math.max(Math.min(far*0.01,0.1),1e-4), proj=M4.perspective(Math.PI/2,1,near,far); return pointShadowFaces.map(f=>M4.mul(proj,M4.lookAt(pos,add(pos,f.dir),f.up))); }
  function ensureDynamicPointShadowTarget(l){ if(!l.dynamicShadowTarget){ const size=Math.max(1,l.shadow&&l.shadow.size?l.shadow.size:64); l.dynamicShadowTarget=makeDynamicShadowTarget(size*4,size*2); l.dynamicShadowTarget.faceSize=size; } l.shadowTexture=l.dynamicShadowTarget.texture; return l.dynamicShadowTarget; }
  function bindShadowMaterialState(p,o,clip){ attrib(p,"aUv",o.uvBuf,2); attrib(p,"aUv2",o.uv2Buf,2); const objClip=objectClipping(o,clip||{count:0,planes:new Array(16).fill(0)}); uniform1i(p,"uShadowClipCount",objClip.count); uniform4v(p,"uShadowClipPlane[0]",objClip.planes); uniform1f(p,"uShadowAlphaTest",o.alphaTest||0); uniform1f(p,"uShadowOpacity",o.opacity==null?1:o.opacity); uniform1i(p,"uShadowMapTexCoord",texCoord(o.texture,0)); uniform1i(p,"uShadowAlphaTexCoord",texCoord(o.alphaTexture,0)); uniformTexMatrix(p,"uShadowMapMatrix",o.texture); uniformTexMatrix(p,"uShadowAlphaMatrix",o.alphaTexture); uniform1f(p,"uShadowUseMap",o.tex?1:0); uniform1f(p,"uShadowUseAlphaMap",o.alphaTex?1:0); uniform1i(p,"uShadowColorMap",0); uniform1i(p,"uShadowAlphaMap",1); if(o.tex){ gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D,o.tex); } if(o.alphaTex){ gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D,o.alphaTex); } }
  function drawShadowCaster(o,viewProj,clip){ if(o.mode!=="triangles"||o.castShadow!==true) return; applySide(o); const p=o.textureSkin?depthBoneProgram:depthProgram; gl.useProgram(p); attrib(p,"aPosition",o.posBuf); attrib(p,"aSkinIndex",o.skinIndexBuf,4); attrib(p,"aSkinWeight",o.skinWeightBuf,4); gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER,o.idxBuf); const gpuInstanced=instanceAttribs(p,o), modelLoc=gl.getUniformLocation(p,"uModel"), vpLoc=gl.getUniformLocation(p,"uViewProj"); gl.uniformMatrix4fv(vpLoc,false,new Float32Array(viewProj)); gl.uniform1i(gl.getUniformLocation(p,"uUseInstancing"),gpuInstanced?1:0); bindSkinState(p,o); bindShadowMaterialState(p,o,clip); if(gpuInstanced){ gl.uniformMatrix4fv(modelLoc,false,new Float32Array(o.matrix)); instancingExt.drawElementsInstancedANGLE(gl.TRIANGLES,o.count,o.indexType,drawOffset(o),o.instanceCount); clearInstanceAttribs(p); } else if(o.instanceMatrices&&o.instanceMatrices.length){ for(const im of o.instanceMatrices){ gl.uniformMatrix4fv(modelLoc,false,new Float32Array(M4.mul(o.matrix,im))); gl.drawElements(gl.TRIANGLES,o.count,o.indexType,drawOffset(o)); } } else { gl.uniformMatrix4fv(modelLoc,false,new Float32Array(o.matrix)); gl.drawElements(gl.TRIANGLES,o.count,o.indexType,drawOffset(o)); } }
  function drawPointShadowCaster(o,viewProj,pos,far,clip){ if(o.mode!=="triangles"||o.castShadow!==true) return; applySide(o); const p=o.textureSkin?pointDepthBoneProgram:pointDepthProgram; gl.useProgram(p); attrib(p,"aPosition",o.posBuf); attrib(p,"aSkinIndex",o.skinIndexBuf,4); attrib(p,"aSkinWeight",o.skinWeightBuf,4); gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER,o.idxBuf); const gpuInstanced=instanceAttribs(p,o), modelLoc=gl.getUniformLocation(p,"uModel"), vpLoc=gl.getUniformLocation(p,"uViewProj"); gl.uniformMatrix4fv(vpLoc,false,new Float32Array(viewProj)); gl.uniform1i(gl.getUniformLocation(p,"uUseInstancing"),gpuInstanced?1:0); gl.uniform3fv(gl.getUniformLocation(p,"uPointShadowPos"),new Float32Array(pos)); gl.uniform1f(gl.getUniformLocation(p,"uPointShadowFar"),far); bindSkinState(p,o); bindShadowMaterialState(p,o,clip); if(gpuInstanced){ gl.uniformMatrix4fv(modelLoc,false,new Float32Array(o.matrix)); instancingExt.drawElementsInstancedANGLE(gl.TRIANGLES,o.count,o.indexType,drawOffset(o),o.instanceCount); clearInstanceAttribs(p); } else if(o.instanceMatrices&&o.instanceMatrices.length){ for(const im of o.instanceMatrices){ gl.uniformMatrix4fv(modelLoc,false,new Float32Array(M4.mul(o.matrix,im))); gl.drawElements(gl.TRIANGLES,o.count,o.indexType,drawOffset(o)); } } else { gl.uniformMatrix4fv(modelLoc,false,new Float32Array(o.matrix)); gl.drawElements(gl.TRIANGLES,o.count,o.indexType,drawOffset(o)); } }
  function renderDynamicDirectionalShadow(l,visible,clip){ const target=ensureDynamicShadowTarget(l), b=shadowBounds(visible), m=directionalShadowMatrix(l,b.center,b.radius); l.shadow.matrix=m; gl.bindFramebuffer(gl.FRAMEBUFFER,target.framebuffer); gl.viewport(0,0,target.size,target.size); gl.disable(gl.BLEND); gl.enable(gl.DEPTH_TEST); gl.depthMask(true); gl.clearColor(1,1,1,1); gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT); for(const o of visible) drawShadowCaster(o,m,clip); gl.bindFramebuffer(gl.FRAMEBUFFER,null); }
  function renderDynamicSpotShadow(l,visible,clip){ const target=ensureDynamicShadowTarget(l), b=shadowBounds(visible), m=spotShadowMatrix(l,b.center,b.radius); l.shadow.matrix=m; gl.bindFramebuffer(gl.FRAMEBUFFER,target.framebuffer); gl.viewport(0,0,target.size,target.size); gl.disable(gl.BLEND); gl.enable(gl.DEPTH_TEST); gl.depthMask(true); gl.clearColor(1,1,1,1); gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT); for(const o of visible) drawShadowCaster(o,m,clip); gl.bindFramebuffer(gl.FRAMEBUFFER,null); }
  function renderDynamicPointShadow(l,visible,clip){ const target=ensureDynamicPointShadowTarget(l), b=shadowBounds(visible), pos=l.position||[0,0,0], far=pointShadowFar(l,b.center,b.radius), matrices=pointShadowMatrices(pos,far); l.shadow.matrix=M4.ident(); l.shadow.matrices=matrices; l.shadow.far=far; gl.bindFramebuffer(gl.FRAMEBUFFER,target.framebuffer); gl.viewport(0,0,target.width,target.height); gl.disable(gl.BLEND); gl.enable(gl.DEPTH_TEST); gl.depthMask(true); gl.clearColor(1,1,1,1); gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT); for(let i=0;i<6;i++){ const f=pointShadowFaces[i]; gl.viewport(f.cell[0]*target.faceSize,f.cell[1]*target.faceSize,target.faceSize,target.faceSize); for(const o of visible) drawPointShadowCaster(o,matrices[i],pos,far,clip); } gl.bindFramebuffer(gl.FRAMEBUFFER,null); }
  function updateDynamicShadows(c,visible,clip){ if(!shadowTexturesEnabled) return; for(const l of c.lights||[]){ if(!(l.shadow&&isDynamicShadow(l.shadow))) continue; if(l.visible===false||(l.visibilityStates||[]).some(s=>s.visible===false)) continue; if(l.shadow.type==="directionalDynamic") renderDynamicDirectionalShadow(l,visible,clip); else if(l.shadow.type==="spotDynamic") renderDynamicSpotShadow(l,visible,clip); else if(l.shadow.type==="pointDynamic") renderDynamicPointShadow(l,visible,clip); } }
  function applySide(o){ if(o.mode!=="triangles" || o.side==="double"){ gl.disable(gl.CULL_FACE); return; } gl.enable(gl.CULL_FACE); gl.cullFace(o.side==="back"?gl.FRONT:gl.BACK); }
  function webLineWidth(w){ const lo=Math.max(lineWidthRange[0]||1,0.000001), hi=Math.max(lineWidthRange[1]||lo,lo), x=Number.isFinite(w)?w:1; return Math.min(Math.max(x,lo),hi); }
  function tone(c){ return {mode:c.toneMappingMode||0, exposure:c.toneExposure==null?1:c.toneExposure, output:c.outputColorSpaceMode||0}; }
  function texCoord(t,def=0){ return t&&t.texCoord!=null?t.texCoord:def; }
  function textureColorSpace(t){ return t&&t.colorspace==="srgb"?1:0; }
  function texMatrix(t){ const tm=(t&&t.matrix)||[1,0,0,0,1,0,0,0,1]; return [tm[0],tm[3],tm[6],tm[1],tm[4],tm[7],tm[2],tm[5],tm[8]]; }
  function uniformTexMatrix(p,name,t){ const loc=gl.getUniformLocation(p,name); if(loc!==null) gl.uniformMatrix3fv(loc,false,new Float32Array(texMatrix(t))); }
  function draw(o,view,proj,eye,basis,light,clip,fg,tm){
    applySide(o);
    if(o.mode==="lines"||o.mode==="line_loop"||o.mode==="line_strip") gl.lineWidth(webLineWidth(o.linewidth)); else gl.lineWidth(1);
    if(o.depthTest===false) gl.disable(gl.DEPTH_TEST); else gl.enable(gl.DEPTH_TEST);
    gl.depthMask(o.depthWrite!==false);
    const p=o.mode==="points"?pointProgram:(o.mode==="sprite"?spriteProgram:(o.mode==="triangles"?(o.textureSkin?meshBoneProgram:meshProgram):colorProgram));
    gl.useProgram(p);
    attrib(p,"aPosition",o.posBuf);
    attrib(p,"aColor",o.colorBuf);
    if(o.mode==="lines"||o.mode==="line_loop"||o.mode==="line_strip") attrib(p,"aLineDistance",o.lineDistanceBuf,1);
    if(o.mode==="triangles"){ attrib(p,"aNormal",o.nrmBuf); attrib(p,"aTangent",o.tanBuf,4); attrib(p,"aUv",o.uvBuf,2); attrib(p,"aUv2",o.uv2Buf,2); attrib(p,"aSkinIndex",o.skinIndexBuf,4); attrib(p,"aSkinWeight",o.skinWeightBuf,4); }
    if(o.mode==="sprite"){ attrib(p,"aUv",o.uvBuf,2); }
    const gpuInstanced=instanceAttribs(p,o);
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER,o.idxBuf);
    gl.uniformMatrix4fv(gl.getUniformLocation(p,"uModel"),false,new Float32Array(o.matrix));
    gl.uniformMatrix4fv(gl.getUniformLocation(p,"uView"),false,new Float32Array(view));
    gl.uniformMatrix4fv(gl.getUniformLocation(p,"uProj"),false,new Float32Array(proj));
    gl.uniform3fv(gl.getUniformLocation(p,"uColor"),new Float32Array(o.color));
    gl.uniform1f(gl.getUniformLocation(p,"uGlow"),o.glow||0);
    gl.uniform1f(gl.getUniformLocation(p,"uOpacity"),o.opacity);
    const objClip=objectClipping(o,clip);
    uniform1i(p,"uClipCount",objClip.count);
    uniform4v(p,"uClipPlane[0]",objClip.planes);
    uniform1i(p,"uToneMapping",tm.mode);
    uniform1f(p,"uToneExposure",tm.exposure);
    uniform1i(p,"uOutputColorSpace",tm.output);
    uniform1i(p,"uUseInstancing",gpuInstanced?1:0);
    uniform1i(p,"uUseInstanceColor",(gpuInstanced&&o.instanceColorBuf)?1:0);
    gl.uniform3fv(gl.getUniformLocation(p,"uCamera"),new Float32Array(eye));
    gl.uniform3fv(gl.getUniformLocation(p,"uFogColor"),new Float32Array(fg.color));
    uniform1i(p,"uFogType",fg.type);
    gl.uniform1f(gl.getUniformLocation(p,"uFogNear"),fg.near);
    gl.uniform1f(gl.getUniformLocation(p,"uFogFar"),fg.far);
    gl.uniform1f(gl.getUniformLocation(p,"uFogDensity"),fg.density);
    if(o.mode==="triangles"){
      gl.uniformMatrix3fv(gl.getUniformLocation(p,"uNormalMat"),false,new Float32Array(M4.normal3(o.matrix)));
      gl.uniformMatrix3fv(gl.getUniformLocation(p,"uViewNormalMat"),false,new Float32Array(M4.normal3(view)));
      bindSkinState(p,o);
      uniform1i(p,"uUseTangents",o.hasTangents?1:0);
      uniform1i(p,"uMaterialMode",o.materialType==="normal"?1:(o.materialType==="depth"?2:(o.materialType==="toon"?3:(o.materialType==="matcap"?4:(o.materialType==="basic"?5:(o.materialType==="lambert"?6:(o.materialType==="phong"?7:0)))))));
      uniform1f(p,"uDepthNear",o.depthNear==null?0.1:o.depthNear);
      uniform1f(p,"uDepthFar",o.depthFar==null?100:o.depthFar);
      uniform1i(p,"uDepthPacking",o.depthPackingMode||0);
      uniform1i(p,"uDepthOrthographic",currentDrawCamera&&currentDrawCamera.type==="orthographic"?1:0);
      uniform1f(p,"uToonSteps",o.toonSteps==null?3:o.toonSteps);
      gl.uniform3fv(gl.getUniformLocation(p,"uCamera"),new Float32Array(eye));
      gl.uniform3fv(gl.getUniformLocation(p,"uAmbientColor"),new Float32Array(light.ambient));
      uniform3v(p,"uDirLight[0]",light.direction); uniform3v(p,"uDirColor[0]",light.dirColor); uniform1i(p,"uDirCount",light.dirCount);
      const objShadows=(o.receiveShadow!==false)?(light.shadows||[]):[];
      uniform1i(p,"uShadowCount",objShadows.length);
      gl.uniformMatrix4fv(gl.getUniformLocation(p,"uShadowMatrix[0]"),false,new Float32Array(shadowMatrices(objShadows)));
      uniform1fv(p,"uShadowBias[0]",shadowValues(objShadows,"bias",0.0015));
      uniform1iv(p,"uShadowPcfRadius[0]",shadowValues(objShadows,"pcfRadius",1));
      uniform1fv(p,"uShadowTexel[0]",shadowValues(objShadows,"texel",0.015625));
      uniform1iv(p,"uShadowKind[0]",shadowValues(objShadows,"kind",0));
      uniform1iv(p,"uShadowLightIndex[0]",shadowValues(objShadows,"index",-1));
      uniform1iv(p,"uShadowMode[0]",shadowValues(objShadows,"mode",0));
      uniform3v(p,"uShadowPointPos[0]",shadowPointPositions(objShadows));
      uniform1fv(p,"uShadowPointFar[0]",shadowValues(objShadows,"pointFar",1));
      const spm0=gl.getUniformLocation(p,"uShadowPointMatrix0[0]"); if(spm0!==null) gl.uniformMatrix4fv(spm0,false,new Float32Array(shadowPointMatrices(objShadows,0)));
      const spm1=gl.getUniformLocation(p,"uShadowPointMatrix1[0]"); if(spm1!==null) gl.uniformMatrix4fv(spm1,false,new Float32Array(shadowPointMatrices(objShadows,1)));
      uniform3v(p,"uPointColor[0]",light.pointColor); uniform3v(p,"uPointPos[0]",light.pointPosition); uniform1i(p,"uPointCount",light.pointCount);
      uniform1fv(p,"uPointDistance[0]",light.pointDistance); uniform1fv(p,"uPointDecay[0]",light.pointDecay);
      uniform3v(p,"uSpotColor[0]",light.spotColor); uniform3v(p,"uSpotPos[0]",light.spotPosition); uniform3v(p,"uSpotDir[0]",light.spotDirection); uniform1i(p,"uSpotCount",light.spotCount);
      uniform1fv(p,"uSpotDistance[0]",light.spotDistance); uniform1fv(p,"uSpotDecay[0]",light.spotDecay); uniform1fv(p,"uSpotConeCos[0]",light.spotConeCos); uniform1fv(p,"uSpotPenumbraCos[0]",light.spotPenumbraCos);
      uniform3v(p,"uHemiSky[0]",light.hemiSky); uniform3v(p,"uHemiGround[0]",light.hemiGround); uniform1i(p,"uHemiCount",light.hemiCount);
      uniform3v(p,"uRectColor[0]",light.rectColor); uniform3v(p,"uRectPos[0]",light.rectPosition); uniform3v(p,"uRectForward[0]",light.rectForward);
      uniform3v(p,"uRectU[0]",light.rectU); uniform3v(p,"uRectV[0]",light.rectV); uniform2v(p,"uRectSize[0]",light.rectSize); uniform1i(p,"uRectCount",light.rectCount);
      gl.uniform1f(gl.getUniformLocation(p,"uUseMap"),o.tex?1:0);
      gl.uniform1f(gl.getUniformLocation(p,"uUseAlphaMap"),o.alphaTex?1:0);
      gl.uniform1f(gl.getUniformLocation(p,"uUseEmissiveMap"),o.emissiveTex?1:0);
      gl.uniform1f(gl.getUniformLocation(p,"uUseAoMap"),o.aoTex?1:0);
      gl.uniform1f(gl.getUniformLocation(p,"uUseLightMap"),o.lightTex?1:0);
      gl.uniform1f(gl.getUniformLocation(p,"uUseRoughnessMap"),o.roughnessTex?1:0);
      gl.uniform1f(gl.getUniformLocation(p,"uUseMetalnessMap"),o.metalnessTex?1:0);
      gl.uniform1f(gl.getUniformLocation(p,"uUseNormalMap"),o.normalTex?1:0);
      gl.uniform1f(gl.getUniformLocation(p,"uUseClearcoatNormalMap"),o.clearcoatNormalTex?1:0);
      gl.uniform1f(gl.getUniformLocation(p,"uUseMatcapMap"),o.matcapTex?1:0);
      gl.uniform1f(gl.getUniformLocation(p,"uUseGradientMap"),o.gradientTex?1:0);
      gl.uniform1f(gl.getUniformLocation(p,"uUsePhysicalScalarMap"),o.physicalScalarTex?1:0);
      gl.uniform1f(gl.getUniformLocation(p,"uUseSheenColorMap"),o.sheenColorTex?1:0);
      gl.uniform1f(gl.getUniformLocation(p,"uUsePhysicalScalar2Map"),o.physicalScalar2Tex?1:0);
      gl.uniform1f(gl.getUniformLocation(p,"uUseSpecularColorMap"),o.specularColorTex?1:0);
      uniform1f(p,"uUseGlossinessMap",o.glossinessPacked&&o.specularColorTex?1:0);
      uniform1f(p,"uUseClearcoatMap",o.physicalScalarTex&&o.clearcoatTexture?1:0);
      uniform1f(p,"uUseClearcoatRoughnessMap",o.physicalScalarTex&&o.clearcoatRoughnessTexture?1:0);
      uniform1f(p,"uUseTransmissionMap",o.physicalScalarTex&&o.transmissionTexture?1:0);
      uniform1f(p,"uUseSheenRoughnessMap",o.physicalScalarTex&&o.sheenRoughnessTexture?1:0);
      uniform1f(p,"uUseIridescenceMap",o.physicalScalar2Tex&&o.iridescenceTexture?1:0);
      uniform1f(p,"uUseIridescenceThicknessMap",o.physicalScalar2Tex&&o.iridescenceThicknessTexture?1:0);
      uniform1f(p,"uUseSpecularIntensityMap",o.physicalScalar2Tex&&o.specularIntensityTexture?1:0);
      gl.uniform1f(gl.getUniformLocation(p,"uUseThicknessMap"),o.physicalScalar2Tex&&o.thicknessTexture?1:0);
      gl.uniform1f(gl.getUniformLocation(p,"uUseAnisotropyMap"),o.physicalScalar2Tex&&!o.thicknessTexture&&o.anisotropyTexture?1:0);
      gl.uniform1f(gl.getUniformLocation(p,"uUseEnvMap"),o.envTexture?1:0);
      gl.uniform1f(gl.getUniformLocation(p,"uUseEnvCubeMap"),o.envCubeTex?1:0);
      uniform1i(p,"uMapTexCoord",texCoord(o.texture,0));
      uniform1i(p,"uAlphaTexCoord",texCoord(o.alphaTexture,0));
      uniform1i(p,"uEmissiveTexCoord",texCoord(o.emissiveTexture,0));
      uniform1i(p,"uAoTexCoord",texCoord(o.aoTexture,1));
      uniform1i(p,"uLightTexCoord",texCoord(o.lightTexture,1));
      uniform1i(p,"uRoughnessTexCoord",texCoord(o.roughnessTexture,0));
      uniform1i(p,"uMetalnessTexCoord",texCoord(o.metalnessTexture,0));
      uniform1i(p,"uNormalTexCoord",texCoord(o.normalTexture,0));
      uniform1i(p,"uClearcoatNormalTexCoord",texCoord(o.clearcoatNormalTexture,0));
      uniform1i(p,"uClearcoatTexCoord",texCoord(o.clearcoatTexture,0));
      uniform1i(p,"uClearcoatRoughnessTexCoord",texCoord(o.clearcoatRoughnessTexture,0));
      uniform1i(p,"uTransmissionTexCoord",texCoord(o.transmissionTexture,0));
      uniform1i(p,"uSheenRoughnessTexCoord",texCoord(o.sheenRoughnessTexture,0));
      uniform1i(p,"uIridescenceTexCoord",texCoord(o.iridescenceTexture,0));
      uniform1i(p,"uIridescenceThicknessTexCoord",texCoord(o.iridescenceThicknessTexture,0));
      uniform1i(p,"uSpecularIntensityTexCoord",texCoord(o.specularIntensityTexture,0));
      uniform1i(p,"uThicknessTexCoord",texCoord(o.thicknessTexture,0));
      uniform1i(p,"uAnisotropyTexCoord",texCoord(o.anisotropyTexture,0));
      uniform1i(p,"uSheenColorTexCoord",texCoord(o.sheenColorTexture,0));
      uniform1i(p,"uSpecularColorTexCoord",texCoord(o.specularColorTexture,0));
      uniform1i(p,"uMapColorSpace",textureColorSpace(o.texture));
      uniform1i(p,"uEmissiveColorSpace",textureColorSpace(o.emissiveTexture));
      uniform1i(p,"uMatcapColorSpace",textureColorSpace(o.matcapTexture));
      uniform1i(p,"uSheenColorSpace",textureColorSpace(o.sheenColorTexture));
      uniform1i(p,"uSpecularColorSpace",textureColorSpace(o.specularColorTexture));
      gl.uniform3fv(gl.getUniformLocation(p,"uEmissive"),new Float32Array(o.emissive||[0,0,0]));
      gl.uniform1f(gl.getUniformLocation(p,"uEmissiveIntensity"),o.emissiveIntensity==null?1:o.emissiveIntensity);
      gl.uniform1f(gl.getUniformLocation(p,"uAoIntensity"),o.aoIntensity==null?1:o.aoIntensity);
      gl.uniform1f(gl.getUniformLocation(p,"uLightMapIntensity"),o.lightMapIntensity==null?1:o.lightMapIntensity);
      gl.uniform1f(gl.getUniformLocation(p,"uEnvMapIntensity"),o.envMapIntensity==null?1:o.envMapIntensity);
      gl.uniform1f(gl.getUniformLocation(p,"uAlphaTest"),o.alphaTest||0);
      gl.uniform1f(gl.getUniformLocation(p,"uNormalScale"),o.normalScale==null?1:o.normalScale);
      gl.uniform1f(gl.getUniformLocation(p,"uClearcoatNormalScale"),o.clearcoatNormalScale==null?1:o.clearcoatNormalScale);
      uniform3v(p,"uEnvColor[0]",o.envTexture?o.envTexture.colors.flat():new Array(18).fill(0));
      gl.uniform1f(gl.getUniformLocation(p,"uRoughness"),o.roughness==null?.65:o.roughness);
      gl.uniform1f(gl.getUniformLocation(p,"uMetalness"),o.metalness||0);
      gl.uniform1f(gl.getUniformLocation(p,"uClearcoat"),o.clearcoat||0);
      gl.uniform1f(gl.getUniformLocation(p,"uClearcoatRoughness"),o.clearcoatRoughness||0);
      gl.uniform1f(gl.getUniformLocation(p,"uTransmission"),o.transmission||0);
      gl.uniform1f(gl.getUniformLocation(p,"uThickness"),o.thickness||0);
      gl.uniform1f(gl.getUniformLocation(p,"uAttenuationDistance"),o.attenuationDistance||0);
      gl.uniform3fv(gl.getUniformLocation(p,"uAttenuationColor"),new Float32Array(o.attenuationColor||[1,1,1]));
      gl.uniform1f(gl.getUniformLocation(p,"uIor"),o.ior||1.5);
      gl.uniform1f(gl.getUniformLocation(p,"uDispersion"),o.dispersion||0);
      gl.uniform1f(gl.getUniformLocation(p,"uSheen"),o.sheen||0);
      gl.uniform3fv(gl.getUniformLocation(p,"uSheenColor"),new Float32Array(o.sheenColor||[1,1,1]));
      gl.uniform1f(gl.getUniformLocation(p,"uSheenRoughness"),o.sheenRoughness==null?1:o.sheenRoughness);
      gl.uniform1f(gl.getUniformLocation(p,"uIridescence"),o.iridescence||0);
      gl.uniform1f(gl.getUniformLocation(p,"uIridescenceIor"),o.iridescenceIor||1.3);
      gl.uniform1f(gl.getUniformLocation(p,"uIridescenceThickness"),o.iridescenceThickness==null?400:o.iridescenceThickness);
      gl.uniform1f(gl.getUniformLocation(p,"uSpecularIntensity"),o.specularIntensity==null?1:o.specularIntensity);
      gl.uniform3fv(gl.getUniformLocation(p,"uSpecularColor"),new Float32Array(o.specularColor||[1,1,1]));
      gl.uniform1f(gl.getUniformLocation(p,"uAnisotropy"),o.anisotropy||0);
      gl.uniform1f(gl.getUniformLocation(p,"uAnisotropyRotation"),o.anisotropyRotation||0);
      gl.uniform1f(gl.getUniformLocation(p,"uGlossiness"),o.glossiness==null?0.5:o.glossiness);
      gl.uniform1f(gl.getUniformLocation(p,"uShininess"),o.shininess==null?32:o.shininess);
      uniformTexMatrix(p,"uMapMatrix",o.texture);
      uniformTexMatrix(p,"uAlphaMatrix",o.alphaTexture);
      uniformTexMatrix(p,"uEmissiveMatrix",o.emissiveTexture);
      uniformTexMatrix(p,"uAoMatrix",o.aoTexture);
      uniformTexMatrix(p,"uLightMatrix",o.lightTexture);
      uniformTexMatrix(p,"uRoughnessMatrix",o.roughnessTexture);
      uniformTexMatrix(p,"uMetalnessMatrix",o.metalnessTexture);
      uniformTexMatrix(p,"uNormalMatrix",o.normalTexture);
      uniformTexMatrix(p,"uClearcoatNormalMatrix",o.clearcoatNormalTexture);
      uniformTexMatrix(p,"uClearcoatMatrix",o.clearcoatTexture);
      uniformTexMatrix(p,"uClearcoatRoughnessMatrix",o.clearcoatRoughnessTexture);
      uniformTexMatrix(p,"uTransmissionMatrix",o.transmissionTexture);
      uniformTexMatrix(p,"uSheenRoughnessMatrix",o.sheenRoughnessTexture);
      uniformTexMatrix(p,"uIridescenceMatrix",o.iridescenceTexture);
      uniformTexMatrix(p,"uIridescenceThicknessMatrix",o.iridescenceThicknessTexture);
      uniformTexMatrix(p,"uSpecularIntensityMatrix",o.specularIntensityTexture);
      uniformTexMatrix(p,"uThicknessMatrix",o.thicknessTexture);
      uniformTexMatrix(p,"uAnisotropyMatrix",o.anisotropyTexture);
      uniformTexMatrix(p,"uSheenColorMatrix",o.sheenColorTexture);
      uniformTexMatrix(p,"uSpecularColorMatrix",o.specularColorTexture);
      if(o.tex){ gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D,o.tex); gl.uniform1i(gl.getUniformLocation(p,"uMap"),0); }
      if(o.alphaTex){ gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D,o.alphaTex); gl.uniform1i(gl.getUniformLocation(p,"uAlphaMap"),1); }
      if(o.emissiveTex){ gl.activeTexture(gl.TEXTURE2); gl.bindTexture(gl.TEXTURE_2D,o.emissiveTex); gl.uniform1i(gl.getUniformLocation(p,"uEmissiveMap"),2); }
      if(o.aoTex){ gl.activeTexture(gl.TEXTURE3); gl.bindTexture(gl.TEXTURE_2D,o.aoTex); gl.uniform1i(gl.getUniformLocation(p,"uAoMap"),3); }
      if(o.lightTex){ gl.activeTexture(gl.TEXTURE4); gl.bindTexture(gl.TEXTURE_2D,o.lightTex); gl.uniform1i(gl.getUniformLocation(p,"uLightMap"),4); }
      if(o.roughnessTex){ gl.activeTexture(gl.TEXTURE5); gl.bindTexture(gl.TEXTURE_2D,o.roughnessTex); gl.uniform1i(gl.getUniformLocation(p,"uRoughnessMap"),5); }
      if(o.metalnessTex){ gl.activeTexture(gl.TEXTURE6); gl.bindTexture(gl.TEXTURE_2D,o.metalnessTex); gl.uniform1i(gl.getUniformLocation(p,"uMetalnessMap"),6); }
      if(o.normalTex){ gl.activeTexture(gl.TEXTURE7); gl.bindTexture(gl.TEXTURE_2D,o.normalTex); gl.uniform1i(gl.getUniformLocation(p,"uNormalMap"),7); }
      if(o.clearcoatNormalTex){ gl.activeTexture(gl.TEXTURE0+clearcoatNormalTextureUnit); gl.bindTexture(gl.TEXTURE_2D,o.clearcoatNormalTex); gl.uniform1i(gl.getUniformLocation(p,"uClearcoatNormalMap"),clearcoatNormalTextureUnit); }
      if(o.matcapTex){ gl.activeTexture(gl.TEXTURE7); gl.bindTexture(gl.TEXTURE_2D,o.matcapTex); gl.uniform1i(gl.getUniformLocation(p,"uMatcapMap"),7); }
      if(o.gradientTex){ gl.activeTexture(gl.TEXTURE7); gl.bindTexture(gl.TEXTURE_2D,o.gradientTex); gl.uniform1i(gl.getUniformLocation(p,"uGradientMap"),7); }
      if(o.physicalScalarTex){ gl.activeTexture(gl.TEXTURE8); gl.bindTexture(gl.TEXTURE_2D,o.physicalScalarTex); gl.uniform1i(gl.getUniformLocation(p,"uPhysicalScalarMap"),8); }
      if(o.physicalScalar2Tex){ gl.activeTexture(gl.TEXTURE9); gl.bindTexture(gl.TEXTURE_2D,o.physicalScalar2Tex); gl.uniform1i(gl.getUniformLocation(p,"uPhysicalScalar2Map"),9); }
      if(o.sheenColorTex){ gl.activeTexture(gl.TEXTURE10); gl.bindTexture(gl.TEXTURE_2D,o.sheenColorTex); gl.uniform1i(gl.getUniformLocation(p,"uSheenColorMap"),10); }
      if(o.specularColorTex){ gl.activeTexture(gl.TEXTURE11); gl.bindTexture(gl.TEXTURE_2D,o.specularColorTex); gl.uniform1i(gl.getUniformLocation(p,"uSpecularColorMap"),11); }
      bindShadowMaps(p,objShadows);
      if(cubeTexturesEnabled){ const envTex=o.envCubeTex||defaultEnvCubeTex; gl.activeTexture(gl.TEXTURE14); gl.bindTexture(gl.TEXTURE_CUBE_MAP,envTex.texture); uniform1i(p,"uEnvCubeMap",envCubeTextureUnit); uniform1f(p,"uEnvMaxLod",envTex.maxLod||0); }
    }
    if(o.mode==="points"){
      gl.uniform1f(gl.getUniformLocation(p,"uPointSize"),Math.max(2,o.pointSize*1.5));
      gl.uniform1f(gl.getUniformLocation(p,"uPointSizeAttenuation"),(o.pointSizeAttenuation===false||(currentDrawCamera&&currentDrawCamera.type==="orthographic"))?0:1);
      gl.uniform1f(gl.getUniformLocation(p,"uPointReferenceDistance"),Math.max(1e-6,currentDrawDistance));
      gl.uniform1f(gl.getUniformLocation(p,"uUsePointMap"),o.tex?1:0);
      gl.uniform1f(gl.getUniformLocation(p,"uUsePointAlphaMap"),o.alphaTex?1:0);
      gl.uniform1f(gl.getUniformLocation(p,"uPointAlphaTest"),o.alphaTest||0);
      uniform1i(p,"uPointColorSpace",textureColorSpace(o.texture));
      uniformTexMatrix(p,"uPointMatrix",o.texture);
      uniformTexMatrix(p,"uPointAlphaMatrix",o.alphaTexture);
      if(o.tex){ gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D,o.tex); gl.uniform1i(gl.getUniformLocation(p,"uPointMap"),0); }
      if(o.alphaTex){ gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D,o.alphaTex); gl.uniform1i(gl.getUniformLocation(p,"uPointAlphaMap"),1); }
    }
    if(o.mode==="sprite"){
      gl.uniform3fv(gl.getUniformLocation(p,"uCameraRight"),new Float32Array(basis.right));
      gl.uniform3fv(gl.getUniformLocation(p,"uCameraUp"),new Float32Array(basis.up));
      gl.uniform2fv(gl.getUniformLocation(p,"uSpriteCenter"),new Float32Array(o.spriteCenter||[.5,.5]));
      gl.uniform1f(gl.getUniformLocation(p,"uSpriteRotation"),o.spriteRotation||0);
      gl.uniform1f(gl.getUniformLocation(p,"uSpriteSizeAttenuation"),o.spriteSizeAttenuation===false?0:1);
      gl.uniform1f(gl.getUniformLocation(p,"uUseSpriteMap"),o.tex?1:0);
      gl.uniform1f(gl.getUniformLocation(p,"uUseSpriteAlphaMap"),o.alphaTex?1:0);
      gl.uniform1f(gl.getUniformLocation(p,"uSpriteAlphaTest"),o.alphaTest||0);
      uniform1i(p,"uSpriteColorSpace",textureColorSpace(o.texture));
      uniformTexMatrix(p,"uSpriteMatrix",o.texture);
      uniformTexMatrix(p,"uSpriteAlphaMatrix",o.alphaTexture);
      if(o.tex){ gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D,o.tex); gl.uniform1i(gl.getUniformLocation(p,"uSpriteMap"),0); }
      if(o.alphaTex){ gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D,o.alphaTex); gl.uniform1i(gl.getUniformLocation(p,"uSpriteAlphaMap"),1); }
    }
    if(o.mode==="lines"||o.mode==="line_loop"||o.mode==="line_strip"){
      gl.uniform1f(gl.getUniformLocation(p,"uLineDashed"),o.lineDashed?1:0);
      gl.uniform1f(gl.getUniformLocation(p,"uDashSize"),Math.max(0,o.dashSize||0));
      gl.uniform1f(gl.getUniformLocation(p,"uGapSize"),Math.max(0,o.gapSize||0));
      gl.uniform1f(gl.getUniformLocation(p,"uDashScale"),Math.max(0.0001,o.dashScale||1));
    }
    const mode=o.mode==="points"?gl.POINTS:(o.mode==="lines"?gl.LINES:(o.mode==="line_loop"?gl.LINE_LOOP:(o.mode==="line_strip"?gl.LINE_STRIP:gl.TRIANGLES)));
    const offset=drawOffset(o);
    if(gpuInstanced){
      instancingExt.drawElementsInstancedANGLE(mode,o.count,o.indexType,offset,o.instanceCount);
      clearInstanceAttribs(p);
    } else if(o.instanceMatrices&&o.instanceMatrices.length){
      const base=o.matrix.slice(), modelLoc=gl.getUniformLocation(p,"uModel"), normalLoc=o.mode==="triangles"?gl.getUniformLocation(p,"uNormalMat"):null;
      for(const im of o.instanceMatrices){
        const model=M4.mul(base,im);
        gl.uniformMatrix4fv(modelLoc,false,new Float32Array(model));
        if(normalLoc!==null) gl.uniformMatrix3fv(normalLoc,false,new Float32Array(M4.normal3(model)));
        gl.drawElements(mode,o.count,o.indexType,offset);
      }
      gl.uniformMatrix4fv(modelLoc,false,new Float32Array(base));
      if(normalLoc!==null) gl.uniformMatrix3fv(normalLoc,false,new Float32Array(M4.normal3(base)));
    } else {
      gl.drawElements(mode,o.count,o.indexType,offset);
    }
  }
  const nav=document.getElementById("cases"), titleEl=document.getElementById("title"), subEl=document.getElementById("subtitle"), stats=document.getElementById("stats"), speedEl=document.getElementById("speed"), speedValue=document.getElementById("speedValue"), playToggle=document.getElementById("playToggle");
  let active=DATA.cases[0], yaw=.65, pitch=.53, dist=active.radius, orbitYawOffset=0, orbitPitchOffset=0, orbitDistScale=1, targetOffset=[0,0,0], currentDrawCamera=null, currentDrawDistance=1, dragging=false, panMode=false, dollyMode=false, pinchMode=false, lx=0, ly=0, pinchDist=0, pinchCenter=[0,0], animTime=0, lastFrameTime=performance.now()*.001, animSpeed=1, animPaused=false;
  window.__diff3dDebug={activeObjectCount:()=>activeVisibleCount(), activeViewCount:()=>activeViewCount(), animationTime:()=>animTime, animationSpeed:()=>animSpeed, animationPaused:()=>animPaused, orbitDistance:()=>dist, targetOffset:()=>targetOffset.slice(), orbitAngles:()=>({yaw:yaw,pitch:pitch})};
  const pointers=new Map();
  for(const c of DATA.cases){ const b=document.createElement("button"); b.dataset.case=c.id; const strong=document.createElement("strong"); strong.textContent=c.title; const span=document.createElement("span"); span.textContent=c.subtitle; b.append(strong,span); b.onclick=()=>setCase(c.id); nav.appendChild(b); }
  function orbitStateFromVector(v){ const d=Math.max(1e-6,Math.hypot(v[0],v[1],v[2])); return {dist:d,yaw:Math.atan2(v[2],v[0]),pitch:Math.max(-1.35,Math.min(1.35,Math.asin(Math.max(-1,Math.min(1,v[1]/d)))))}; }
  function setOrbitFromVector(v){ const s=orbitStateFromVector(v); dist=s.dist; yaw=s.yaw; pitch=s.pitch; }
  function applyCameraOrbit(cam){ if(!cam) return; const s=orbitStateFromVector(sub(cam.position,cam.target)); yaw=s.yaw+orbitYawOffset; pitch=Math.max(-1.35,Math.min(1.35,s.pitch+orbitPitchOffset)); dist=Math.max(1e-6,s.dist*orbitDistScale); }
  function rememberCameraOrbitOffsets(){ const cam=primaryCamera(active.camera); if(!cam) return; const s=orbitStateFromVector(sub(cam.position,cam.target)); orbitYawOffset=yaw-s.yaw; orbitPitchOffset=pitch-s.pitch; orbitDistScale=dist/Math.max(s.dist,1e-6); }
  function setCase(id){ active=DATA.cases.find(c=>c.id===id); if(active.camera) resetCameraAnim(active.camera); const cam=primaryCamera(active.camera); if(cam){ setOrbitFromVector(sub(cam.position,cam.target)); } else { dist=active.radius; pitch=Math.max(-1.35,Math.min(1.35,Math.asin(Math.max(-1,Math.min(1,(active.height==null?3.0:active.height)/Math.max(dist,1e-6)))))); } active.baseDistance=dist; orbitYawOffset=0; orbitPitchOffset=0; orbitDistScale=1; targetOffset=[0,0,0]; titleEl.textContent=active.title; subEl.textContent=active.subtitle; document.querySelectorAll("button[data-case]").forEach(b=>b.classList.toggle("active",b.dataset.case===id)); }
  function resize(){ const r=canvas.getBoundingClientRect(), dpr=Math.min(devicePixelRatio||1,2); const w=Math.max(1,Math.round(r.width*dpr)), h=Math.max(1,Math.round(r.height*dpr)); if(canvas.width!==w||canvas.height!==h){ canvas.width=w; canvas.height=h; } }
  function objectDepth(o,eye){ const x=o.matrix[12]-eye[0], y=o.matrix[13]-eye[1], z=o.matrix[14]-eye[2]; return x*x+y*y+z*z; }
  function cameraOrbitState(cam){
    if(!cam){ const target=add(active.target,targetOffset); return {target:target,eye:[target[0]+dist*Math.cos(pitch)*Math.cos(yaw),target[1]+dist*Math.sin(pitch),target[2]+dist*Math.cos(pitch)*Math.sin(yaw)],up:[0,1,0],distance:dist}; }
    const s=orbitStateFromVector(sub(cam.position,cam.target)), d=Math.max(1e-6,s.dist*orbitDistScale), py=Math.max(-1.35,Math.min(1.35,s.pitch+orbitPitchOffset)), yw=s.yaw+orbitYawOffset, target=add(cam.target,targetOffset);
    return {target:target,eye:[target[0]+d*Math.cos(py)*Math.cos(yw),target[1]+d*Math.sin(py),target[2]+d*Math.cos(py)*Math.sin(yw)],up:cam.up||[0,1,0],distance:d};
  }
  function cameraProjection(cam,viewport){
    const viewportAspect=viewport&&viewport[3]>0?Math.max(1e-6,viewport[2]/viewport[3]):Math.max(1e-6,canvas.width/canvas.height), aspect=cam&&cam.aspect!=null?cam.aspect:viewportAspect, camZoom=cam&&cam.zoom!=null?Math.max(1e-6,cam.zoom):1, near=cam&&cam.near!=null?cam.near:.1, far=cam&&cam.far!=null?cam.far:180;
    if(cam&&cam.type==="orthographic"){ const left=cam.left==null?-aspect:cam.left, right=cam.right==null?aspect:cam.right, bottom=cam.bottom==null?-1:cam.bottom, top=cam.top==null?1:cam.top, s=orbitDistScale/camZoom, cx=(left+right)*.5, cy=(bottom+top)*.5, hx=(right-left)*.5*s, hy=(top-bottom)*.5*s; return M4.orthographic(cx-hx,cx+hx,cy-hy,cy+hy,near,far); }
    const fov=cam&&cam.fov?cam.fov:active.fov, zoomedFov=2*Math.atan(Math.tan(fov*.5)/camZoom);
    return M4.perspective(zoomedFov,aspect,near,far);
  }
  function cameraViewState(cam,viewport){ const orbit=cameraOrbitState(cam), view=M4.lookAt(orbit.eye,orbit.target,orbit.up), forward=norm(sub(orbit.target,orbit.eye)); let cameraRight=norm(cross(forward,orbit.up)); if(!isFinite(cameraRight[0])) cameraRight=[1,0,0]; return {camera:cam,eye:orbit.eye,target:orbit.target,view:view,proj:cameraProjection(cam,viewport),basis:{right:cameraRight,up:cross(cameraRight,forward)},viewport:viewport,distance:orbit.distance}; }
  function arrayViewportBounds(cam){ let minX=Infinity,minY=Infinity,maxX=-Infinity,maxY=-Infinity; for(const v of cam.viewports||[]){ const x=Number(v[0])||0, y=Number(v[1])||0, w=Number(v[2])||0, h=Number(v[3])||0; if(w<=0||h<=0) continue; minX=Math.min(minX,x); minY=Math.min(minY,y); maxX=Math.max(maxX,x+w); maxY=Math.max(maxY,y+h); } if(!isFinite(minX)) return {x:0,y:0,w:canvas.width,h:canvas.height}; return {x:minX,y:minY,w:Math.max(1,maxX-minX),h:Math.max(1,maxY-minY)}; }
  function arrayViewport(cam,index){ const v=(cam.viewports||[])[index]; if(!v) return null; const b=arrayViewportBounds(cam), sx=canvas.width/b.w, sy=canvas.height/b.h, x0=Math.floor((v[0]-b.x)*sx), y0=Math.floor((v[1]-b.y)*sy), x1=Math.ceil((v[0]+v[2]-b.x)*sx), y1=Math.ceil((v[1]+v[3]-b.y)*sy), x=Math.max(0,Math.min(canvas.width,x0)), y=Math.max(0,Math.min(canvas.height,y0)), r=Math.max(x,Math.min(canvas.width,x1)), t=Math.max(y,Math.min(canvas.height,y1)); return r>x&&t>y?[x,y,r-x,t-y]:null; }
  function cameraViews(cam){ if(cam&&cam.type==="array"){ const out=[], cams=cam.cameras||[]; for(let i=0;i<cams.length;i++){ const vp=arrayViewport(cam,i); if(vp) out.push(cameraViewState(cams[i],vp)); } return out; } return [cameraViewState(primaryCamera(cam),[0,0,canvas.width,canvas.height])]; }
  function activeViewCount(){ return cameraViews(active.camera).length; }
  function currentEye(){ return cameraViewState(primaryCamera(active.camera),[0,0,canvas.width,canvas.height]).eye; }
  function activeVisibleCount(){ const lod=lodChoices(active,currentEye()); return active.objects.filter(o=>(!o.lodGroup||lod.get(o.lodGroup)===o)&&(o.visibilityStates||[]).every(s=>s.visible!==false)).length; }
  function lodChoices(c,eye){ const objects=c.objects, state=c.lodState||(c.lodState=new Map()), groups=new Map(), choices=new Map(); for(const o of objects){ if(!o.lodGroup) continue; if(!groups.has(o.lodGroup)) groups.set(o.lodGroup,[]); groups.get(o.lodGroup).push(o); } for(const [id,levels] of groups){ levels.sort((a,b)=>(a.lodDistance||0)-(b.lodDistance||0)); const d=Math.sqrt(objectDepth(levels[0],eye)); const current=state.get(id); let chosen=levels[0]; for(let i=1;i<levels.length;i++){ const o=levels[i], threshold=(o.lodDistance||0)*(o===current?1-(o.lodHysteresis||0):1); if(d>=threshold) chosen=o; else break; } state.set(id,chosen); choices.set(id,chosen); } return choices; }
  function pointerList(){ return Array.from(pointers.values()); }
  function pointerCenter(ps){ return [(ps[0].x+ps[1].x)*.5,(ps[0].y+ps[1].y)*.5]; }
  function pointerDistance(ps){ return Math.hypot(ps[0].x-ps[1].x,ps[0].y-ps[1].y)||1; }
  function panBy(dx,dy){ const cam=primaryCamera(active.camera), cameraUp=cam&&cam.up?cam.up:[0,1,0], forward=norm([-Math.cos(pitch)*Math.cos(yaw),-Math.sin(pitch),-Math.cos(pitch)*Math.sin(yaw)]); let right=norm(cross(forward,cameraUp)); if(!isFinite(right[0])) right=[1,0,0]; const up=cross(right,forward), s=dist*.0015; targetOffset=add(targetOffset,add(scale(right,-dx*s),scale(up,dy*s))); }
  function zoomBy(f){ dist=Math.max(2.5,Math.min(24,dist*f)); rememberCameraOrbitOffsets(); }
  speedEl.addEventListener("input",()=>{ animSpeed=Number(speedEl.value); speedValue.textContent=animSpeed.toFixed(2)+"x"; });
  playToggle.addEventListener("click",()=>{ animPaused=!animPaused; playToggle.textContent=animPaused?">":"||"; playToggle.title=animPaused?"Play animation":"Pause animation"; playToggle.setAttribute("aria-label",playToggle.title); });
  function drawSceneView(state,visible,light,clip,fg,tm){ const vp=state.viewport||[0,0,canvas.width,canvas.height]; if(vp[2]<=0||vp[3]<=0) return 0; gl.viewport(vp[0],vp[1],vp[2],vp[3]); gl.scissor(vp[0],vp[1],vp[2],vp[3]); gl.enable(gl.SCISSOR_TEST); gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT); currentDrawCamera=state.camera; currentDrawDistance=state.distance; let drawn=0; for(const o of visible.filter(o=>!(o.animTransparent==null?o.transparent:o.animTransparent))){ draw(o,state.view,state.proj,state.eye,state.basis,light,clip,fg,tm); drawn++; } const transparent=visible.filter(o=>(o.animTransparent==null?o.transparent:o.animTransparent)).sort((a,b)=>objectDepth(b,state.eye)-objectDepth(a,state.eye)); for(const o of transparent){ draw(o,state.view,state.proj,state.eye,state.basis,light,clip,fg,tm); drawn++; } return drawn; }
  function render(nowMs){ resize(); const now=(nowMs||performance.now())*.001, dt=Math.min(.08,Math.max(0,now-lastFrameTime)); lastFrameTime=now; if(!animPaused) animTime+=dt*animSpeed; applyAnimations(active,animTime); const orbitCam=primaryCamera(active.camera); if(orbitCam) applyCameraOrbit(orbitCam); const primaryState=cameraViewState(orbitCam,[0,0,canvas.width,canvas.height]), eye=primaryState.eye, clip=clipping(active), fg=fog(active), tm=tone(active), lod=lodChoices(active,eye); const visible=active.objects.filter(o=>(!o.lodGroup||lod.get(o.lodGroup)===o)&&(o.visibilityStates||[]).every(s=>s.visible!==false)); for(const o of visible) refreshObjectTextures(o); updateDynamicShadows(active,visible,clip); const light=lighting(active); gl.disable(gl.SCISSOR_TEST); gl.viewport(0,0,canvas.width,canvas.height); gl.enable(gl.DEPTH_TEST); gl.enable(gl.BLEND); gl.blendFunc(gl.SRC_ALPHA,gl.ONE_MINUS_SRC_ALPHA); gl.clearColor(active.background[0],active.background[1],active.background[2],1); gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT); let drawn=0; for(const state of cameraViews(active.camera)) drawn+=drawSceneView(state,visible,light,clip,fg,tm); currentDrawCamera=null; gl.disable(gl.SCISSOR_TEST); gl.depthMask(true); gl.enable(gl.DEPTH_TEST); stats.textContent=`\${drawn} draw items`; requestAnimationFrame(render); }
  canvas.addEventListener("contextmenu",e=>e.preventDefault());
  canvas.addEventListener("pointerdown",e=>{ canvas.focus(); dragging=true; pointers.set(e.pointerId,{x:e.clientX,y:e.clientY}); const ps=pointerList(); if(ps.length>=2){ pinchMode=true; dollyMode=false; pinchDist=pointerDistance(ps); pinchCenter=pointerCenter(ps); } else { pinchMode=false; dollyMode=e.button===1; panMode=e.button===2||e.shiftKey||e.ctrlKey||e.metaKey; lx=e.clientX; ly=e.clientY; } try{ canvas.setPointerCapture(e.pointerId); }catch(_){} });
  canvas.addEventListener("pointermove",e=>{ if(!dragging)return; if(pointers.has(e.pointerId)) pointers.set(e.pointerId,{x:e.clientX,y:e.clientY}); const ps=pointerList(); if(ps.length>=2){ const nd=pointerDistance(ps), nc=pointerCenter(ps); dist=Math.max(2.5,Math.min(24,dist*(pinchDist/nd))); panBy(nc[0]-pinchCenter[0],nc[1]-pinchCenter[1]); rememberCameraOrbitOffsets(); pinchDist=nd; pinchCenter=nc; return; } const dx=e.clientX-lx, dy=e.clientY-ly; lx=e.clientX; ly=e.clientY; if(dollyMode) zoomBy(Math.exp(dy*.003)); else if(panMode) panBy(dx,dy); else { yaw+=dx*.008; pitch=Math.max(-1.35,Math.min(1.35,pitch+dy*.006)); rememberCameraOrbitOffsets(); } });
  function updatePointerEndState(){ const ps=pointerList(); if(ps.length>=2){ pinchMode=true; dollyMode=false; pinchDist=pointerDistance(ps); pinchCenter=pointerCenter(ps); } else { dragging=ps.length>0; pinchMode=false; panMode=false; dollyMode=false; if(ps.length===1){ lx=ps[0].x; ly=ps[0].y; } } }
  function endPointer(e){ pointers.delete(e.pointerId); updatePointerEndState(); }
  canvas.addEventListener("pointerup",endPointer); canvas.addEventListener("pointercancel",endPointer); canvas.addEventListener("lostpointercapture",endPointer);
  function touchFallbackEnabled(e){ return !window.PointerEvent || e.__diff3dForceTouchFallback===true; }
  function touchKey(t){ return "touch:"+t.identifier; }
  function touchStart(e){ if(!touchFallbackEnabled(e)) return; e.preventDefault(); canvas.focus(); dragging=true; for(const t of Array.from(e.changedTouches||[])) pointers.set(touchKey(t),{x:t.clientX,y:t.clientY}); const ps=pointerList(); if(ps.length>=2){ pinchMode=true; dollyMode=false; panMode=false; pinchDist=pointerDistance(ps); pinchCenter=pointerCenter(ps); } else if(ps.length===1){ pinchMode=false; dollyMode=false; panMode=false; lx=ps[0].x; ly=ps[0].y; } }
  function touchMove(e){ if(!touchFallbackEnabled(e)) return; e.preventDefault(); if(!dragging) return; for(const t of Array.from(e.changedTouches||[])){ const id=touchKey(t); if(pointers.has(id)) pointers.set(id,{x:t.clientX,y:t.clientY}); } const ps=pointerList(); if(ps.length>=2){ const nd=pointerDistance(ps), nc=pointerCenter(ps); dist=Math.max(2.5,Math.min(24,dist*(pinchDist/nd))); panBy(nc[0]-pinchCenter[0],nc[1]-pinchCenter[1]); rememberCameraOrbitOffsets(); pinchDist=nd; pinchCenter=nc; return; } if(ps.length===1){ const dx=ps[0].x-lx, dy=ps[0].y-ly; lx=ps[0].x; ly=ps[0].y; yaw+=dx*.008; pitch=Math.max(-1.35,Math.min(1.35,pitch+dy*.006)); rememberCameraOrbitOffsets(); } }
  function touchEnd(e){ if(!touchFallbackEnabled(e)) return; e.preventDefault(); for(const t of Array.from(e.changedTouches||[])) pointers.delete(touchKey(t)); updatePointerEndState(); }
  canvas.addEventListener("touchstart",touchStart,{passive:false}); canvas.addEventListener("touchmove",touchMove,{passive:false}); canvas.addEventListener("touchend",touchEnd,{passive:false}); canvas.addEventListener("touchcancel",touchEnd,{passive:false});
  canvas.addEventListener("keydown",e=>{ const k=e.key; if(k==="ArrowLeft"){ panBy(-32,0); e.preventDefault(); } else if(k==="ArrowRight"){ panBy(32,0); e.preventDefault(); } else if(k==="ArrowUp"){ panBy(0,-32); e.preventDefault(); } else if(k==="ArrowDown"){ panBy(0,32); e.preventDefault(); } else if(k==="+"||k==="="){ zoomBy(.92); e.preventDefault(); } else if(k==="-"){ zoomBy(1.08); e.preventDefault(); } });
  canvas.addEventListener("wheel",e=>{ e.preventDefault(); zoomBy(1+Math.sign(e.deltaY)*.08); },{passive:false});
  setCase(active.id); requestAnimationFrame(render);
  </script>
</body>
</html>
"""
    return replace(html,
        "uniform vec3 uColor,uCamera,uAmbientColor;" =>
            "uniform vec3 uColor,uCamera,uAmbientColor,uProbeCoeff[4];",
        "uniform vec3 uColor,uCamera,uAmbientColor,uEmissive,uFogColor;" =>
            "uniform vec3 uColor,uCamera,uAmbientColor,uProbeCoeff[4],uEmissive,uFogColor;",
        "vec3 diffuse=uAmbientColor; vec3 specular=vec3(0.0);" =>
            "vec3 diffuse=uAmbientColor; diffuse+=max(uProbeCoeff[0]+uProbeCoeff[1]*n.x+uProbeCoeff[2]*n.y+uProbeCoeff[3]*n.z,vec3(0.0)); vec3 specular=vec3(0.0);",
        "const amb=[0.18,0.18,0.18], dirs=[], points=[], spots=[], hemis=[], rects=[], shadows=[];" =>
            "const amb=[0.18,0.18,0.18], probe=[[0,0,0],[0,0,0],[0,0,0],[0,0,0]], dirs=[], points=[], spots=[], hemis=[], rects=[], shadows=[];",
        "const addShadow=(kind,index,l)=>{" =>
            "const addProbe=(coeffs,intensity)=>{ if(!coeffs) return; for(let i=0;i<4;i++){ const c=coeffs[i]||[0,0,0]; probe[i][0]+=c[0]*(intensity||0); probe[i][1]+=c[1]*(intensity||0); probe[i][2]+=c[2]*(intensity||0); } }; const addShadow=(kind,index,l)=>{",
        "const scaled=[l.color?.[0]*(l.intensity||0),l.color?.[1]*(l.intensity||0),l.color?.[2]*(l.intensity||0)];" =>
            "const color=l.color||[1,1,1], scaled=[color[0]*(l.intensity||0),color[1]*(l.intensity||0),color[2]*(l.intensity||0)];",
        "} else if(l.type===\"directional\" && dirs.length<MAX_DIR){" =>
            "} else if(l.type===\"lightProbe\"){ addProbe(l.coeffs,l.intensity||0); } else if(l.type===\"directional\" && dirs.length<MAX_DIR){",
        "return {ambient:amb,dirCount:" =>
            "return {ambient:amb,probeCoeffs:probe.flat(),dirCount:",
        "gl.uniform3fv(gl.getUniformLocation(p,\"uAmbientColor\"),new Float32Array(light.ambient));" =>
            "gl.uniform3fv(gl.getUniformLocation(p,\"uAmbientColor\"),new Float32Array(light.ambient)); uniform3v(p,\"uProbeCoeff[0]\",light.probeCoeffs||new Array(12).fill(0));",
        "const int MAX_DIR=4; const int MAX_POINT=4; const int MAX_SPOT=4; const int MAX_HEMI=4; const int MAX_RECT=4;" =>
            "const int MAX_DIR=$max_dir; const int MAX_POINT=$max_point; const int MAX_SPOT=$max_spot; const int MAX_HEMI=$max_hemi; const int MAX_RECT=$max_rect;",
        "const int MAX_DIR=4; const int MAX_POINT=4; const int MAX_SPOT=4; const int MAX_HEMI=4;" =>
            "const int MAX_DIR=$max_dir; const int MAX_POINT=$max_point; const int MAX_SPOT=$max_spot; const int MAX_HEMI=$max_hemi;",
        "const MAX_DIR=4, MAX_POINT=4, MAX_SPOT=4, MAX_HEMI=4, MAX_RECT=4;" =>
            "const MAX_DIR=$max_dir, MAX_POINT=$max_point, MAX_SPOT=$max_spot, MAX_HEMI=$max_hemi, MAX_RECT=$max_rect;")
end

"""
    save_webgl_html(path, cases; title="Diff3D.jl Live WebGL Showcase")

Export one or more `WebGLExportCase`s to a standalone interactive HTML file.
The browser runtime is intentionally small; the scene data is produced from
Diff3D.jl objects, materials, instancing, and optional `AnimationClip`s.
"""
function save_webgl_html(path::String, cases::AbstractVector{WebGLExportCase};
                         title::String="Diff3D.jl Live WebGL Showcase")
    isempty(cases) && throw(ArgumentError("save_webgl_html requires at least one WebGLExportCase"))
    data = "{\"cases\":[" * join((_web_case_json(c) for c in cases), ",") * "]}"
    light_caps = _web_light_caps(cases)
    open(path, "w") do io
        write(io, _webgl_html(data, title; light_caps))
    end
    return path
end
