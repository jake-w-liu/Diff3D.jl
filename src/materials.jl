# --------------------------------------------------------------------------
# Material types mirroring three.js material hierarchy.
# --------------------------------------------------------------------------

abstract type AbstractMaterial end

# ========================== MeshBasicMaterial ==========================
# Unlit, flat color

struct MeshBasicMaterial <: AbstractMaterial
    color::Color3{Float64}
    opacity::Float64
    transparent::Bool
    wireframe::Bool
    side::Symbol  # :front, :back, :double
    map::Any      # optional albedo Texture
    alpha_map::Any
    vertex_colors::Bool   # modulate by geometry :color attribute when true
    alpha_test::Float64
    depth_test::Bool
    depth_write::Bool
end

function MeshBasicMaterial(; color=Color3(1.0, 1.0, 1.0), opacity=1.0,
                           transparent=false, wireframe=false, side=:front, map=nothing,
                           alpha_map=nothing, vertex_colors=false, alpha_test=0.0,
                           depth_test=true, depth_write=true)
    MeshBasicMaterial(color, opacity, transparent, wireframe, side, map, alpha_map, vertex_colors,
                      Float64(alpha_test), depth_test, depth_write)
end

struct SpriteMaterial <: AbstractMaterial
    color::Color3{Float64}
    opacity::Float64
    transparent::Bool
    map::Any
    rotation::Float64
    size_attenuation::Bool
    depth_test::Bool
    depth_write::Bool
end

function SpriteMaterial(; color=Color3(1.0, 1.0, 1.0), opacity=1.0,
                        transparent=false, map=nothing, rotation=0.0,
                        size_attenuation=true, depth_test=true, depth_write=true)
    SpriteMaterial(color, opacity, transparent, map, Float64(rotation),
                   size_attenuation, depth_test, depth_write)
end

# ========================== MeshLambertMaterial ==========================
# Diffuse-only (Lambertian)

struct MeshLambertMaterial <: AbstractMaterial
    color::Color3{Float64}
    emissive::Color3{Float64}
    opacity::Float64
    transparent::Bool
    side::Symbol
    map::Any
    ao_map::Any
    emissive_map::Any
    vertex_colors::Bool   # modulate by geometry :color attribute when true
    light_map::Any        # baked indirect-lighting texture (multiplied in, like aoMap)
    depth_test::Bool
    depth_write::Bool
end

function MeshLambertMaterial(; color=Color3(1.0, 1.0, 1.0),
                              emissive=Color3(0.0, 0.0, 0.0),
                              opacity=1.0, transparent=false, side=:front,
                              map=nothing, ao_map=nothing, emissive_map=nothing,
                              vertex_colors=false, light_map=nothing,
                              depth_test=true, depth_write=true)
    MeshLambertMaterial(color, emissive, opacity, transparent, side, map, ao_map, emissive_map,
                        vertex_colors, light_map, depth_test, depth_write)
end

# ========================== MeshPhongMaterial ==========================
# Blinn-Phong shading

struct MeshPhongMaterial <: AbstractMaterial
    color::Color3{Float64}
    specular::Color3{Float64}
    emissive::Color3{Float64}
    shininess::Float64
    opacity::Float64
    transparent::Bool
    side::Symbol
    map::Any
    light_map::Any        # baked indirect-lighting texture (multiplied in, like aoMap)
    depth_test::Bool
    depth_write::Bool
end

function MeshPhongMaterial(; color=Color3(1.0, 1.0, 1.0),
                            specular=Color3(0.066, 0.066, 0.066),
                            emissive=Color3(0.0, 0.0, 0.0),
                            shininess=30.0, opacity=1.0,
                            transparent=false, side=:front, map=nothing, light_map=nothing,
                            depth_test=true, depth_write=true)
    MeshPhongMaterial(color, specular, emissive, shininess, opacity, transparent, side, map,
                      light_map, depth_test, depth_write)
end

# ========================== MeshStandardMaterial ==========================
# PBR (metallic-roughness workflow)

struct MeshStandardMaterial <: AbstractMaterial
    color::Color3{Float64}
    emissive::Color3{Float64}
    metalness::Float64
    roughness::Float64
    opacity::Float64
    transparent::Bool
    side::Symbol
    map::Any
    normal_map::Any
    normal_scale::Float64
    roughness_map::Any
    metalness_map::Any
    alpha_map::Any
    ao_map::Any
    emissive_map::Any
    vertex_colors::Bool   # modulate by geometry :color attribute when true
    alpha_test::Float64
    envmap::Any           # optional CubeTexture for reflection (IBL specular)
    light_map::Any        # baked indirect-lighting texture (multiplied in, like aoMap)
    emissive_intensity::Float64
    ao_map_intensity::Float64
    light_map_intensity::Float64
    env_map_intensity::Float64
    depth_test::Bool
    depth_write::Bool
end

function MeshStandardMaterial(; color=Color3(1.0, 1.0, 1.0),
                               emissive=Color3(0.0, 0.0, 0.0),
                               metalness=0.0, roughness=1.0,
                               opacity=1.0, transparent=false, side=:front,
                               map=nothing, normal_map=nothing, normal_scale=1.0,
                               roughness_map=nothing, metalness_map=nothing, alpha_map=nothing,
                               ao_map=nothing, emissive_map=nothing,
                               vertex_colors=false, alpha_test=0.0,
                               envmap=nothing, light_map=nothing,
                               emissive_intensity=1.0, ao_map_intensity=1.0,
                               light_map_intensity=1.0, env_map_intensity=1.0,
                               depth_test=true, depth_write=true)
    MeshStandardMaterial(color, emissive, metalness, roughness, opacity, transparent, side,
                         map, normal_map, Float64(normal_scale), roughness_map, metalness_map, alpha_map,
                         ao_map, emissive_map, vertex_colors, Float64(alpha_test), envmap, light_map,
                         emissive_intensity, ao_map_intensity, light_map_intensity,
                         env_map_intensity, depth_test, depth_write)
end

# ========================== MeshNormalMaterial ==========================
# Maps normals to RGB

struct MeshNormalMaterial <: AbstractMaterial
    opacity::Float64
    transparent::Bool
    side::Symbol
    depth_test::Bool
    depth_write::Bool
end

function MeshNormalMaterial(; opacity=1.0, transparent=false, side=:front,
                            depth_test=true, depth_write=true)
    MeshNormalMaterial(opacity, transparent, side, depth_test, depth_write)
end

# ========================== LineBasicMaterial ==========================

struct LineBasicMaterial <: AbstractMaterial
    color::Color3{Float64}
    linewidth::Float64
    opacity::Float64
    depth_test::Bool
    depth_write::Bool
end

function LineBasicMaterial(; color=Color3(1.0, 1.0, 1.0), linewidth=1.0, opacity=1.0,
                           depth_test=true, depth_write=true)
    LineBasicMaterial(color, linewidth, opacity, depth_test, depth_write)
end

# ========================== PointsMaterial ==========================

struct PointsMaterial <: AbstractMaterial
    color::Color3{Float64}
    size::Float64
    opacity::Float64
    transparent::Bool
    map::Any
    depth_test::Bool
    depth_write::Bool
end

function PointsMaterial(; color=Color3(1.0, 1.0, 1.0), size=1.0, opacity=1.0,
                        transparent=false, map=nothing, depth_test=true, depth_write=true)
    PointsMaterial(color, size, opacity, transparent, map, depth_test, depth_write)
end

# ========================== MeshPhysicalMaterial ==========================
# PBR extended with a dielectric clearcoat lobe, transmission and IOR.

struct MeshPhysicalMaterial <: AbstractMaterial
    color::Color3{Float64}
    emissive::Color3{Float64}
    metalness::Float64
    roughness::Float64
    clearcoat::Float64
    clearcoat_roughness::Float64
    transmission::Float64
    ior::Float64
    opacity::Float64
    transparent::Bool
    side::Symbol
    envmap::Any           # optional CubeTexture for reflection (IBL specular)
    map::Any
    normal_map::Any
    normal_scale::Float64
    roughness_map::Any
    metalness_map::Any
    ao_map::Any
    emissive_map::Any
    alpha_map::Any
    emissive_intensity::Float64
    ao_map_intensity::Float64
    light_map_intensity::Float64
    env_map_intensity::Float64
    alpha_test::Float64
    # --- three.js MeshPhysicalMaterial extensions (added last, keyword defaults) ---
    sheen::Float64                 # retroreflective sheen strength (0 = off)
    sheen_color::Color3{Float64}   # tint of the sheen lobe
    sheen_roughness::Float64       # Charlie-distribution roughness (1 = broad)
    iridescence::Float64           # thin-film interference blend (0 = off)
    iridescence_ior::Float64       # refractive index of the thin film
    iridescence_thickness::Float64 # film thickness in nanometres
    light_map::Any                 # baked indirect-lighting texture (multiplied in)
    clearcoat_map::Any
    clearcoat_roughness_map::Any
    transmission_map::Any
    thickness::Float64
    thickness_map::Any
    attenuation_distance::Float64
    attenuation_color::Color3{Float64}
    sheen_color_map::Any
    sheen_roughness_map::Any
    iridescence_map::Any
    iridescence_thickness_map::Any
    specular_intensity::Float64
    specular_color::Color3{Float64}
    specular_intensity_map::Any
    specular_color_map::Any
    depth_test::Bool
    depth_write::Bool
end

function MeshPhysicalMaterial(; color=Color3(1.0,1.0,1.0), emissive=Color3(0.0,0.0,0.0),
                               metalness=0.0, roughness=1.0, clearcoat=0.0,
                               clearcoat_roughness=0.0, transmission=0.0, ior=1.5,
                               opacity=1.0, transparent=false, side=:front, envmap=nothing,
                                map=nothing, normal_map=nothing, normal_scale=1.0,
                               roughness_map=nothing, metalness_map=nothing, ao_map=nothing, emissive_map=nothing,
                               alpha_map=nothing, emissive_intensity=1.0, ao_map_intensity=1.0,
                               light_map_intensity=1.0, env_map_intensity=1.0,
                               alpha_test=0.0,
                               sheen=0.0, sheen_color=Color3(1.0,1.0,1.0), sheen_roughness=1.0,
                               iridescence=0.0, iridescence_ior=1.3, iridescence_thickness=400.0,
                               light_map=nothing,
                               clearcoat_map=nothing, clearcoat_roughness_map=nothing,
                               transmission_map=nothing, thickness=0.0, thickness_map=nothing,
                               attenuation_distance=0.0,
                               attenuation_color=Color3(1.0,1.0,1.0),
                               sheen_color_map=nothing,
                               sheen_roughness_map=nothing, iridescence_map=nothing,
                               iridescence_thickness_map=nothing,
                               specular_intensity=1.0, specular_color=Color3(1.0,1.0,1.0),
                               specular_intensity_map=nothing, specular_color_map=nothing,
                               depth_test=true, depth_write=true)
    MeshPhysicalMaterial(color, emissive, metalness, roughness, clearcoat,
                         clearcoat_roughness, transmission, ior, opacity, transparent, side,
                          envmap, map, normal_map, Float64(normal_scale), roughness_map, metalness_map, ao_map,
                          emissive_map, alpha_map, emissive_intensity, ao_map_intensity,
                          light_map_intensity, env_map_intensity, Float64(alpha_test),
                         sheen, sheen_color, sheen_roughness,
                         iridescence, iridescence_ior, iridescence_thickness, light_map,
                         clearcoat_map, clearcoat_roughness_map, transmission_map,
                         Float64(thickness), thickness_map, Float64(attenuation_distance),
                         attenuation_color,
                         sheen_color_map, sheen_roughness_map, iridescence_map,
                         iridescence_thickness_map, specular_intensity, specular_color,
                         specular_intensity_map, specular_color_map, depth_test, depth_write)
end

# ========================== MeshToonMaterial ==========================
# Quantized (cel-shaded) diffuse, optionally sampled from a toon gradient map.

function _toon_gradient_steps(gradient_steps)
    steps = Int(gradient_steps)
    steps > 0 || throw(ArgumentError("gradient_steps must be positive"))
    return steps
end

function _toon_gradient_map(gradient_map)
    gradient_map === nothing && return nothing
    gradient_map isa Texture && return gradient_map
    throw(ArgumentError("gradient_map must be a Texture or nothing"))
end

struct MeshToonMaterial <: AbstractMaterial
    color::Color3{Float64}
    emissive::Color3{Float64}
    gradient_steps::Int
    gradient_map::Any
    opacity::Float64
    transparent::Bool
    side::Symbol
    depth_test::Bool
    depth_write::Bool

    function MeshToonMaterial(color::Color3, emissive::Color3, gradient_steps,
                              gradient_map, opacity, transparent::Bool,
                              side::Symbol, depth_test::Bool, depth_write::Bool)
        new(convert(Color3{Float64}, color), convert(Color3{Float64}, emissive),
            _toon_gradient_steps(gradient_steps), _toon_gradient_map(gradient_map),
            Float64(opacity), transparent, side, depth_test, depth_write)
    end
end

function MeshToonMaterial(; color=Color3(1.0,1.0,1.0), emissive=Color3(0.0,0.0,0.0),
                           gradient_steps=3, gradient_map=nothing, opacity=1.0,
                           transparent=false, side=:front,
                           depth_test=true, depth_write=true)
    MeshToonMaterial(color, emissive, gradient_steps, gradient_map, opacity, transparent, side,
                     depth_test, depth_write)
end

function MeshToonMaterial(color::Color3, emissive::Color3, gradient_steps,
                          opacity, transparent::Bool, side::Symbol,
                          depth_test::Bool, depth_write::Bool)
    MeshToonMaterial(color, emissive, gradient_steps, nothing, opacity, transparent, side,
                     depth_test, depth_write)
end

# ========================== MeshMatcapMaterial ==========================
# Material-capture shading: appearance baked into a sphere image indexed by the
# view-space normal. `matcap` is an optional texture; without one a procedural
# view-facing falloff is used.

struct MeshMatcapMaterial <: AbstractMaterial
    color::Color3{Float64}
    matcap::Any
    opacity::Float64
    transparent::Bool
    side::Symbol
    depth_test::Bool
    depth_write::Bool
end

function MeshMatcapMaterial(; color=Color3(1.0,1.0,1.0), matcap=nothing,
                             opacity=1.0, transparent=false, side=:front,
                             depth_test=true, depth_write=true)
    MeshMatcapMaterial(color, matcap, opacity, transparent, side, depth_test, depth_write)
end

# ========================== MeshDepthMaterial ==========================
# Renders normalized camera-space depth. `:basic` displays near → bright;
# packed modes encode depth into color channels for depth-texture style output.

function _depth_packing_symbol(depth_packing)
    s = if depth_packing isa Symbol
        depth_packing
    elseif depth_packing isa AbstractString
        Symbol(depth_packing)
    else
        throw(ArgumentError("depth_packing must be one of :basic, :rgba, :rgb, or :rg"))
    end
    (s === :basic || s === :rgba || s === :rgb || s === :rg) ||
        throw(ArgumentError("depth_packing must be one of :basic, :rgba, :rgb, or :rg"))
    return s
end

struct MeshDepthMaterial <: AbstractMaterial
    near::Float64
    far::Float64
    depth_packing::Symbol
    opacity::Float64
    transparent::Bool
    side::Symbol
    depth_test::Bool
    depth_write::Bool
end

function MeshDepthMaterial(near::Real, far::Real, opacity::Real, transparent::Bool,
                           side::Symbol, depth_test::Bool, depth_write::Bool)
    MeshDepthMaterial(Float64(near), Float64(far), :basic, Float64(opacity),
                      transparent, side, depth_test, depth_write)
end

function MeshDepthMaterial(; near=0.1, far=100.0, depth_packing=:basic,
                           opacity=1.0, transparent=false, side=:front,
                           depth_test=true, depth_write=true)
    MeshDepthMaterial(Float64(near), Float64(far), _depth_packing_symbol(depth_packing),
                      Float64(opacity), transparent, side, depth_test, depth_write)
end

# ========================== ShaderMaterial ==========================
# Placeholder for custom GLSL

struct ShaderMaterial <: AbstractMaterial
    vertex_shader::String
    fragment_shader::String
    uniforms::Dict{String, Any}
    program::Any   # optional CPU fragment program: (normal, view_dir, position, uniforms) -> Color3
    side::Symbol
    depth_test::Bool
    depth_write::Bool
end

function ShaderMaterial(; vertex_shader="", fragment_shader="", uniforms=Dict{String,Any}(),
                         program=nothing, side=:front, depth_test=true, depth_write=true)
    ShaderMaterial(vertex_shader, fragment_shader, uniforms, program, side,
                   depth_test, depth_write)
end
