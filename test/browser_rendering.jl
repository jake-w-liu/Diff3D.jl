using Diff3D
include("fixtures/skin_binding.jl")
include("fixtures/texture_transform.jl")
include("fixtures/animated_view_nodes.jl")

length(ARGS) == 1 || error("usage: browser_rendering.jl OUTPUT_DIRECTORY")
output = ARGS[1]
mkpath(output)

function camera_at(x, z)
    camera = PerspectiveCamera(fov=pi/4, aspect=4/3, near=0.1, far=20.0)
    camera.position = Vec3(x, 0.0, z)
    camera.target = Vec3(x, 0.0, 0.0)
    return camera
end

function fog_comparison_cases(mode)
    view_camera=PerspectiveCamera(fov=pi/2,aspect=1.5,near=0.1,far=30.0)
    view_camera.position=Vec3(0.0,0.0,5.0)
    fog=mode===:exponential ? FogExp2(color=Color3(0.0,0.0,1.0),density=0.2) :
        Fog(color=Color3(0.0,0.0,1.0),near=2.0,far=8.0)
    function amount(depth)
        mode===:exponential && return 1-exp(-(0.2depth)^2)
        t=clamp((depth-2)/6,0,1);return t*t*(3-2t)
    end
    actual=Scene(fog=fog);reference=Scene()
    if mode===:transparent
        for (color,z,opacity) in ((Color3(0.0,1.0,0.0),0.0,1.0),(Color3(1.0,0.0,0.0),1.0,0.5))
            f=amount(5-z);baked=color*(1-f)+fog.color*f
            for (root,tint) in ((actual,color),(reference,baked))
                mesh=Mesh(PlaneGeometry(width=5.0,height=3.0),MeshBasicMaterial(color=tint,opacity=opacity,transparent=opacity<1,depth_write=opacity==1))
                mesh.position=Vec3(0.0,0.0,z);add!(root,mesh)
            end
        end
    else
        f=amount(5.0);original=Color3(1.0,0.0,0.0);baked=Color3(1-f,0.0,f)
        for (root,tint) in ((actual,original),(reference,baked))
            for (kind,x) in ((:mesh,-3.0),(:sprite,-1.0),(:line,1.0),(:point,3.0))
                object=if kind===:mesh
                    Mesh(PlaneGeometry(width=1.4,height=1.4),MeshBasicMaterial(color=tint))
                elseif kind===:sprite
                    Sprite(SpriteMaterial(color=tint))
                elseif kind===:line
                    LineSegments(BufferGeometry([-0.7,0.0,0.0,0.7,0.0,0.0],Float64[],Float64[],Int[],2,0),LineBasicMaterial(color=tint))
                else
                    PointsObject(BufferGeometry([0.0,0.0,0.0],Float64[],Float64[],Int[],1,0),PointsMaterial(color=tint,size=20.0,size_attenuation=false))
                end
                object.position=Vec3(x,0.0,0.0);add!(root,object)
            end
        end
    end
    return [WebGLExportCase("normal-actual","Scene fog","View-depth fog before compositing",actual;camera=view_camera,tone_mapping=:none,output_color_space=:linear),
            WebGLExportCase("normal-reference","Baked fog colors","Per-object analytic colors",reference;camera=view_camera,tone_mapping=:none,output_color_space=:linear)]
end
for mode in (:linear,:exponential,:transparent)
    save_webgl_html(joinpath(output,"fog_$mode.html"),fog_comparison_cases(mode))
end

function lighting_energy_cases()
    result=WebGLExportCase[]
    view_camera=camera_at(0.0,5.0)
    for (name,material) in (("lambert",MeshLambertMaterial(color=Color3(0.4,0.6,0.8))),
        ("phong",MeshPhongMaterial(color=Color3(0.4,0.6,0.8))),
        ("standard",MeshStandardMaterial(color=Color3(0.4,0.6,0.8))),
        ("physical",MeshPhysicalMaterial(color=Color3(0.4,0.6,0.8))))
        scene=Scene();add!(scene,Mesh(PlaneGeometry(width=3.0,height=3.0),material))
        push!(result,WebGLExportCase("dark-$name","Unlit scene","No incident or emitted light",scene;camera=view_camera,tone_mapping=:none,output_color_space=:linear))
    end
    ambient_scene=Scene();add!(ambient_scene,Mesh(PlaneGeometry(width=3.0,height=3.0),MeshLambertMaterial(color=Color3(0.4,0.6,0.8))))
    add!(ambient_scene,AmbientLight(intensity=0.5))
    push!(result,WebGLExportCase("ambient","Explicit ambient light","Authored ambient illumination",ambient_scene;camera=view_camera,tone_mapping=:none,output_color_space=:linear))
    emissive_scene=Scene();add!(emissive_scene,Mesh(PlaneGeometry(width=3.0,height=3.0),MeshLambertMaterial(color=Color3(0.0,0.0,0.0),emissive=Color3(0.2,0.1,0.05))))
    push!(result,WebGLExportCase("emissive","Emitted light","Emission remains visible without lights",emissive_scene;camera=view_camera,tone_mapping=:none,output_color_space=:linear))
    for kind in (:directional,:point,:spot)
        scene=Scene()
        add!(scene,Mesh(PlaneGeometry(width=3.0,height=3.0),MeshPhongMaterial(color=Color3(0.0,0.0,0.0),shininess=4.0)))
        light=kind===:directional ? DirectionalLight(position=Vec3(1.0,0.0,-0.5),intensity=3.0) :
              kind===:point ? PointLight(position=Vec3(1.0,0.0,-0.5),intensity=3.0) :
              SpotLight(position=Vec3(1.0,0.0,-0.5),target=Vec3(),intensity=3.0)
        add!(scene,light)
        push!(result,WebGLExportCase("back-$kind","Back-facing illumination","A front face receives no light from behind",scene;camera=view_camera,tone_mapping=:none,output_color_space=:linear))
    end
    return result
end
save_webgl_html(joinpath(output,"lighting_energy.html"),lighting_energy_cases())

function iridescence_range_cases(descending)
    minimum,maximum=descending ? (500.0,100.0) : (100.0,400.0)
    sample=85/255
    texture=Texture(reshape([0.0,sample,0.0],1,1,3);colorspace=:linear)
    mapped=MeshPhysicalMaterial(color=Color3(0.8,0.8,0.8),metalness=0.6,roughness=0.3,
        iridescence=1.0,iridescence_thickness=maximum,iridescence_thickness_min=minimum,
        iridescence_thickness_map=texture)
    baked=MeshPhysicalMaterial(color=Color3(0.8,0.8,0.8),metalness=0.6,roughness=0.3,
        iridescence=1.0,iridescence_thickness=(1-sample)*minimum+sample*maximum)
    cases=WebGLExportCase[];camera=camera_at(0.0,4.0)
    for (id,material) in (("normal-actual",mapped),("normal-reference",baked))
        scene=Scene();add!(scene,Mesh(PlaneGeometry(width=2.0,height=2.0),material))
        add!(scene,DirectionalLight(position=Vec3(1.0,1.0,3.0),intensity=1.0))
        push!(cases,WebGLExportCase(id,"Iridescence thickness range","Mapped and constant thickness",scene;
            camera=camera,tone_mapping=:none,output_color_space=:linear))
    end
    return cases
end
for (name,descending) in (("ascending",false),("descending",true))
    save_webgl_html(joinpath(output,"iridescence_range_$name.html"),iridescence_range_cases(descending))
end

function gltf_view_cases(mode)
    asset=mktempdir() do directory
        animated_view_fixture(directory)
    end
    rig=only(get_children(asset.scene))
    imported_camera,directional,spot=get_children(rig)
    angle=mode===:pole ? pi/2 : pi/4
    local_position=Vec3(4.0,1.0,2.5)
    quaternion=quat_from_euler(0.0,angle,0.0)
    tracks=AbstractKeyframeTrack[]
    for object in (imported_camera,directional,spot)
        push!(tracks,KeyframeTrack(object,:position,[0.0,1.0],[local_position,local_position]))
        push!(tracks,QuaternionKeyframeTrack(object,:rotation,[0.0,1.0],[quaternion,quaternion]))
    end
    clip=AnimationClip("Imported view pose",tracks)
    parent=mat4_translation(10.0,3.0,0.0)*mat4_rotation_z(pi/2)*mat4_scaling(2.0,3.0,4.0)
    position=mat4_transform_point(parent,local_position)
    rotation=mat4_rotation_z(pi/2)*mat4_rotation_y(angle)
    forward=mat4_transform_direction(rotation,Vec3(0.0,0.0,-1.0))
    up=mat4_transform_direction(rotation,Vec3(0.0,1.0,0.0))
    emitted=normalize(mat4_transform_direction(parent*mat4_rotation_y(angle),Vec3(0.0,0.0,-1.0)))
    reference_camera=PerspectiveCamera(fov=1.0,aspect=1.0,near=0.1,far=100.0)
    reference_camera.position=position
    reference_camera.target=position+forward
    reference_camera.up=up
    view_camera=imported_camera
    if mode===:lights
        reference_camera.target=position+emitted
        reference_camera.up=Vec3(1.0,0.0,0.0)
        view_camera=deepcopy(reference_camera)
        rotation=mat4_transpose(mat4_look_at(Vec3(),emitted,reference_camera.up))
        forward=emitted
    end
    pixels=Array{Float64}(undef,4,4,3)
    for y in 1:4,x in 1:4
        pixels[y,x,:].=isodd(x+y) ? (0.8,0.3,0.2) : (0.2,0.6,0.8)
    end
    texture=Texture(pixels;colorspace=:linear,wrap_s=:clamp,wrap_t=:clamp)
    material=mode===:lights ? MeshLambertMaterial(map=texture) : MeshBasicMaterial(map=texture)
    center=position+4forward
    geometry=transform_geometry(PlaneGeometry(width=3.0,height=3.0),
        mat4_translation(center.x,center.y,center.z)*rotation)
    reference=Scene()
    for root in (asset.scene,reference)
        add!(root,Mesh(geometry,material))
    end
    if mode===:lights
        baked_directional=DirectionalLight(position=position)
        baked_directional.target=position+emitted
        baked_spot=SpotLight(position=position,target=position+emitted,angle=0.4,penumbra=1.0)
        add!(reference,baked_directional);add!(reference,baked_spot)
    end
    return [WebGLExportCase("normal-actual","glTF view pose","Animated transform orientation",asset.scene;
                camera=view_camera,animations=[clip],tone_mapping=:none,output_color_space=:linear),
            WebGLExportCase("normal-reference","Baked view pose","Independent world pose",reference;
                camera=reference_camera,tone_mapping=:none,output_color_space=:linear)]
end
for mode in (:camera,:lights,:pole)
    save_webgl_html(joinpath(output,"gltf_view_$mode.html"),gltf_view_cases(mode))
end

function family_normal_cases(family, tangents)
    normal_scale=1.3
    encoded=[204/255,128/255,230/255]
    sampled=normalize(Vec3((2encoded[1]-1)*normal_scale,
        (2encoded[2]-1)*normal_scale,2encoded[3]-1))
    normal_texture=Texture(reshape(encoded,1,1,3);colorspace=:linear)
    family_pixels=Array{Float64}(undef,16,16,3)
    for y in 1:16, x in 1:16
        family_pixels[y,x,1]=(x-1)/15
        family_pixels[y,x,2]=(y-1)/15
        family_pixels[y,x,3]=0.25
    end
    family_texture=Texture(family_pixels;colorspace=:linear,wrap_s=:clamp,wrap_t=:clamp)
    constant_texture(rgb)=Texture(reshape(Float64[rgb...],1,1,3);colorspace=:linear)
    base_map=constant_texture((0.8,0.6,0.4))
    alpha_map=constant_texture((0.0,1.0,0.0))
    cases=WebGLExportCase[]
    for (id,mapped) in (("normal-actual",true),("normal-reference",false))
        geometry=PlaneGeometry(width=2.0,height=2.0)
        if mapped && tangents
            set_attribute!(geometry,:tangent,repeat([1.0,0.0,0.0,1.0],geometry.n_vertices),4)
        elseif !mapped
            geometry.normals=repeat([sampled.x,sampled.y,sampled.z],geometry.n_vertices)
        end
        normal_map=mapped ? normal_texture : nothing
        material=if family===:matcap
            MeshMatcapMaterial(matcap=family_texture,map=base_map,alpha_map=alpha_map,
                normal_map=normal_map,normal_scale=normal_scale)
        else
            MeshToonMaterial(gradient_map=family_texture,map=base_map,alpha_map=alpha_map,
                normal_map=normal_map,normal_scale=normal_scale,
                emissive=Color3(0.1,0.05,0.0),emissive_map=constant_texture((0.5,0.5,0.5)),
                ao_map=constant_texture((0.8,0.0,0.0)),
                light_map=constant_texture((0.03,0.03,0.03)))
        end
        scene=Scene();add!(scene,Mesh(geometry,material))
        add!(scene,DirectionalLight(position=Vec3(0.0,0.0,3.0),intensity=1.0))
        push!(cases,WebGLExportCase(id,"Normal and family textures","Independent texture samples",scene;
            camera=camera_at(0.0,4.0),tone_mapping=:none,output_color_space=:linear))
    end
    return cases
end
for family in (:matcap,:toon), (basis,tangents) in (("tangent",true),("derivative",false))
    save_webgl_html(joinpath(output,"$(family)_normal_$basis.html"),family_normal_cases(family,tangents))
end

function gltf_texture_cases(mode)
    offset=Vec2(0.25,0.5)
    scale=mode===:mirrored ? Vec2(-2.0,0.5) : Vec2(2.0,3.0)
    rotation=mode===:mirrored ? -0.5 : 0.75
    tex_coord=mode===:uv0 ? 0 : 1
    imported,mesh=mktempdir() do directory
        texture_transform_fixture(directory;offset=offset,scale=scale,rotation=rotation,tex_coord=tex_coord)
    end
    baked_geometry=deepcopy(mesh.geometry)
    uv=tex_coord==0 ? baked_geometry.uvs : get_attribute(baked_geometry,:uv2).data
    for vertex in 1:baked_geometry.n_vertices
        u,v=texture_transform_reference(uv[2vertex-1],uv[2vertex],offset,scale,rotation)
        uv[2vertex-1]=u;uv[2vertex]=v
    end
    baked_material=deepcopy(mesh.material)
    baked_material.map.matrix_auto_update=false;baked_material.map.matrix=Mat3()
    reference_scene=Scene();add!(reference_scene,Mesh(baked_geometry,baked_material))
    view_camera=camera_at(0.0,3.0)
    return [WebGLExportCase("normal-actual","Imported texture transform","glTF UV transform matrix",imported;
                camera=view_camera,tone_mapping=:none,output_color_space=:linear),
            WebGLExportCase("normal-reference","Baked texture coordinates","Independent transformed UVs",reference_scene;
                camera=view_camera,tone_mapping=:none,output_color_space=:linear)]
end
for mode in (:uv0,:uv1,:mirrored)
    save_webgl_html(joinpath(output,"gltf_texture_$mode.html"),gltf_texture_cases(mode))
end

function sprite_camera_cases(perspective)
    sprite_camera=perspective ? PerspectiveCamera(fov=pi/2,aspect=2.0,near=0.1,far=20.0) :
        OrthographicCamera(left=-1.0,right=1.0,bottom=-1.0,top=1.0,near=0.1,far=20.0)
    sprite_camera.position=Vec3();sprite_camera.target=Vec3(0.0,0.0,-1.0)
    sprite_scene=Scene();sprite_reference=Scene()
    object=Sprite(SpriteMaterial(color=Color3(0.0,0.0,1.0),size_attenuation=false))
    object.position=Vec3(0.0,0.0,-4.0);object.scale=Vec3(0.25,0.375,1.0)
    add!(sprite_scene,object)
    factor=perspective ? 4.0 : 1.0
    reference_quad=Mesh(PlaneGeometry(width=0.25factor,height=0.375factor),
        MeshBasicMaterial(color=Color3(0.0,0.0,1.0)))
    reference_quad.position=object.position;add!(sprite_reference,reference_quad)
    return [WebGLExportCase("normal-actual","Sprite camera sizing","Camera projection determines attenuation",sprite_scene;
                camera=sprite_camera,tone_mapping=:none,output_color_space=:linear),
            WebGLExportCase("normal-reference","Baked camera sizing","Equivalent world-sized quad",sprite_reference;
                camera=sprite_camera,tone_mapping=:none,output_color_space=:linear)]
end
for (file,perspective) in (("sprite_orthographic",false),("sprite_perspective",true))
    save_webgl_html(joinpath(output,"$file.html"),sprite_camera_cases(perspective))
end

unlit_scene=Scene()
unlit_color=Color3(0.2,0.4,0.6)
unlit_mesh=Mesh(PlaneGeometry(width=0.3,height=0.3),MeshBasicMaterial(color=unlit_color))
unlit_sprite=Sprite(SpriteMaterial(color=unlit_color))
unlit_sprite.scale=Vec3(0.3,0.3,1.0)
unlit_line=LineSegments(BufferGeometry([-0.15,0.0,0.0,0.15,0.0,0.0],Float64[],Float64[],Int[],2,0),
    LineBasicMaterial(color=unlit_color))
unlit_point=PointsObject(BufferGeometry([0.0,0.0,0.0],Float64[],Float64[],Int[],1,0),
    PointsMaterial(color=unlit_color,size=16.0,size_attenuation=false))
for (object,x) in zip((unlit_mesh,unlit_sprite,unlit_line,unlit_point),(-1.5,-0.5,0.5,1.5))
    object.position=Vec3(x,0.0,0.0);add!(unlit_scene,object)
end
unlit_camera=OrthographicCamera(left=-2.0,right=2.0,bottom=-1.0,top=1.0,near=0.1,far=20.0)
unlit_camera.position=Vec3(0.0,0.0,4.0)
save_webgl_html(joinpath(output,"unlit_colors.html"),[
    WebGLExportCase("normal-actual","Unlit colors","Shared linear material color",unlit_scene;
        camera=unlit_camera,tone_mapping=:none,output_color_space=:linear)])

point_texture_data=zeros(2,2,4)
for (row,column,color) in ((1,1,(1.0,0.0,0.0)),(1,2,(0.0,1.0,0.0)),
                            (2,1,(0.0,0.0,1.0)),(2,2,(1.0,1.0,0.0)))
    point_texture_data[row,column,1:3].=color;point_texture_data[row,column,4]=1.0
end
point_texture_map=Texture(point_texture_data;filter=:nearest,colorspace=:linear)
point_texture_cases=WebGLExportCase[]
for (case_id,alpha) in (("normal-actual",nothing),
    ("point-alpha-zero",Texture(reshape([1.0,0.0,1.0,1.0],1,1,4);filter=:nearest,colorspace=:linear)),
    ("point-alpha-one",Texture(reshape([1.0,1.0,1.0,0.0],1,1,4);filter=:nearest,colorspace=:linear)))
    texture_scene=Scene()
    texture_geometry=BufferGeometry([0.0,0.0,0.0],Float64[],Float64[],Int[],1,0)
    add!(texture_scene,PointsObject(texture_geometry,
        PointsMaterial(size=64.0,size_attenuation=false,map=point_texture_map,alpha_map=alpha,alpha_test=0.5)))
    push!(point_texture_cases,WebGLExportCase(case_id,"Point texture coordinates","Texture orientation and alpha channels",texture_scene;
        camera=unlit_camera,tone_mapping=:none,output_color_space=:linear))
end
save_webgl_html(joinpath(output,"point_texture.html"),point_texture_cases)

attenuation_scene=Scene()
attenuation_camera=PerspectiveCamera(fov=pi/2,aspect=2.0,near=0.1,far=200.0)
attenuation_camera.position=Vec3(0.0,0.0,4.0)
for (ndc_x,distance,size,color) in ((-0.75,2.0,16.0,Color3(1.0,0.0,0.0)),
    (-0.25,4.0,16.0,Color3(0.0,1.0,0.0)),(0.25,80.0,16.0,Color3(0.0,0.0,1.0)),
    (0.75,2.0,0.5,Color3(1.0,1.0,0.0)))
    attenuation_geometry=BufferGeometry([ndc_x*distance*2.0,0.0,4.0-distance],
        Float64[],Float64[],Int[],1,0)
    add!(attenuation_scene,PointsObject(attenuation_geometry,PointsMaterial(size=size,color=color)))
end
default_point_geometry=BufferGeometry([0.0,0.0,0.0],Float64[],Float64[],Int[],1,0)
add!(attenuation_scene,InstancedMesh(default_point_geometry,MeshBasicMaterial(),1;draw_mode=:points))
save_webgl_html(joinpath(output,"point_attenuation.html"),[
    WebGLExportCase("normal-actual","Point depth attenuation","Size is clamped after depth scaling",attenuation_scene;
        camera=attenuation_camera,tone_mapping=:none,output_color_space=:linear)])

function wireframe_comparison_cases(mode)
    wire_geometry=PlaneGeometry(width=0.75,height=0.75)
    set_draw_range!(wire_geometry,4,3)
    wire_color=mode===:instanced ? Color3(1.0,1.0,1.0) : Color3(0.2,0.4,0.8)
    wire_material=MeshBasicMaterial(color=wire_color,wireframe=true)
    wire_scene=Scene();wire_reference=Scene();wire_animations=AnimationClip[]
    selected_geometry=deepcopy(wire_geometry)
    selected_geometry.indices=selected_geometry.indices[4:6]
    selected_geometry.n_faces=1;selected_geometry.draw_range=nothing
    transforms=Mat4{Float64}[];colors=Color3{Float64}[]
    if mode===:instanced
        wire_object=InstancedMesh(wire_geometry,wire_material,2)
        for (index,x,tint) in ((1,-0.5,Color3(1.0,0.0,0.0)),(2,0.5,Color3(0.0,0.0,1.0)))
            instance_transform=mat4_translation(x,0.0,0.0)
            set_instance_matrix!(wire_object,index,instance_transform)
            set_instance_color!(wire_object,index,tint)
            push!(transforms,instance_transform);push!(colors,tint)
        end
    elseif mode===:morph
        set_attribute!(wire_geometry,:morphPosition0,
            repeat([0.25,0.125,0.0],wire_geometry.n_vertices),3)
        wire_object=Mesh(wire_geometry,wire_material;morph_target_influences=[0.5])
        wire_object.position=Vec3(0.25,0.0,0.0)
        push!(transforms,mat4_translation(0.375,0.0625,0.0));push!(colors,wire_color)
    else
        bone_count=mode in (:texture,:cpu) ? 65 : 1
        wire_bones=[Bone() for _ in 1:bone_count]
        wire_bones[1].position=Vec3(0.25,0.125,0.0)
        wire_bones[1].scale=Vec3(1.5,0.5,1.0)
        wire_object=SkinnedMesh(wire_geometry,wire_material,Skeleton(wire_bones,fill(Mat4(),bone_count)),
            fill((1,1,1,1),wire_geometry.n_vertices),
            fill((1.0,0.0,0.0,0.0),wire_geometry.n_vertices))
        wire_object.position=Vec3(10.0,0.0,0.0);wire_object.scale=Vec3()
        joint_matrix=mat4_translation(0.25,0.125,0.0)*mat4_scaling(1.5,0.5,1.0)
        if mode===:animated
            wire_bones[1].position=Vec3(-0.25,0.0,0.0)
            track=KeyframeTrack(wire_bones[1],:position,[0.0,1.0],
                [Vec3(0.25,0.125,0.0),Vec3(0.25,0.125,0.0)])
            push!(wire_animations,AnimationClip("wire-bone-motion",[track]))
        elseif mode===:detached
            wire_object.bind_mode=:detached
            wire_object.bind_matrix=mat4_translation(0.5,0.25,0.0)
            wire_object.bind_matrix_inverse=mat4_translation(-0.5,-0.25,0.0)
            wire_object.position=Vec3(0.25,-0.125,0.0);wire_object.scale=Vec3(1.25,0.75,1.0)
            joint_matrix=mat4_translation(0.25,-0.125,0.0)*mat4_scaling(1.25,0.75,1.0)*
                mat4_translation(-0.5,-0.25,0.0)*joint_matrix*mat4_translation(0.5,0.25,0.0)
        end
        push!(transforms,joint_matrix);push!(colors,wire_color)
    end
    add!(wire_scene,wire_object)
    for (transform,color) in zip(transforms,colors)
        baked_wire=wireframe_geometry(transform_geometry(selected_geometry,transform))
        add!(wire_reference,LineSegments(baked_wire,LineBasicMaterial(color=color)))
    end
    wire_camera=camera_at(0.0,4.0)
    return [WebGLExportCase("normal-actual","Deformed wireframe","Selected triangle edges",wire_scene;
                camera=wire_camera,animations=wire_animations,tone_mapping=:none,output_color_space=:linear),
            WebGLExportCase("normal-reference","Baked wireframe","Independent line geometry",wire_reference;
                camera=wire_camera,tone_mapping=:none,output_color_space=:linear)]
end
for mode in (:uniform,:texture,:cpu,:animated,:detached,:morph,:instanced)
    file=mode===:morph ? "wireframe_morph" : mode===:instanced ? "instanced_wireframe" : "skin_wireframe_$mode"
    save_webgl_html(joinpath(output,"$file.html"),wireframe_comparison_cases(mode))
end

function normal_comparison_cases(mode)
    normal_material=MeshNormalMaterial(side=:double)
    base_geometry=transform_geometry(PlaneGeometry(width=1.0,height=1.0),mat4_rotation_y(pi/4))
    mode===:singular && (base_geometry=PlaneGeometry(width=1.0,height=1.0))
    normal_camera=camera_at(0.0,4.0)
    normal_scene=Scene()
    deformation = if mode===:singular
        mat4_scaling(2.0,1.0,0.0)
    elseif mode===:scaled
        normal_camera.zoom=1e6
        mat4_scaling(2e-6,1e-6,0.5e-6)
    else
        first_transform=mat4_rotation_z(0.3)*mat4_scaling(2.0,0.5,1.0)
        second_transform=mat4_rotation_y(-0.4)*mat4_scaling(0.5,2.0,1.5)
        Mat4(ntuple(i->0.4*first_transform.e[i]+0.6*second_transform.e[i],16))
    end
    mode===:instanced_reflected && (deformation=deformation*mat4_scaling(-1.0,1.0,1.0))
    if mode in (:instanced,:instanced_reflected)
        object=InstancedMesh(base_geometry,normal_material,1)
        set_instance_matrix!(object,1,deformation)
        add!(normal_scene,object)
    elseif mode===:scaled
        object=Mesh(base_geometry,normal_material)
        object.scale=Vec3(2e-6,1e-6,0.5e-6)
        add!(normal_scene,object)
    else
        bone_count=mode in (:uniform,:singular) ? 2 : 65
        bones=[Bone() for _ in 1:bone_count]
        bones[1].rotation=Euler(0.0,0.0,0.3);bones[1].scale=Vec3(2.0,0.5,1.0)
        bones[2].rotation=Euler(0.0,-0.4,0.0);bones[2].scale=Vec3(0.5,2.0,1.5)
        if mode===:singular
            for bone in bones
                bone.rotation=Euler();bone.scale=Vec3(2.0,1.0,0.0)
            end
        end
        object=SkinnedMesh(base_geometry,normal_material,Skeleton(bones,fill(Mat4(),bone_count)),
            fill((1,2,1,1),base_geometry.n_vertices),
            fill((0.4,0.6,0.0,0.0),base_geometry.n_vertices))
        add!(normal_scene,object)
    end
    reference_scene=Scene()
    reference_geometry=transform_geometry(base_geometry,deformation)
    # Deformation preserves vertex/index order; match it when baking a
    # reflection, for which transform_geometry normally reverses the winding.
    reference_geometry.indices=copy(base_geometry.indices)
    add!(reference_scene,Mesh(reference_geometry,normal_material))
    return [WebGLExportCase("normal-actual","Transformed normals","Geometry deformation",normal_scene;
                camera=normal_camera,tone_mapping=:none,output_color_space=:linear),
            WebGLExportCase("normal-reference","Baked normals","Equivalent baked geometry",reference_scene;
                camera=normal_camera,tone_mapping=:none,output_color_space=:linear)]
end
for (file,mode) in (("skin_normals_uniform",:uniform),("skin_normals_texture",:texture),
                    ("skin_normals_cpu",:cpu),("skin_normals_singular",:singular),
                    ("instanced_normals",:instanced),("instanced_normals_reflected",:instanced_reflected),
                    ("scaled_normals",:scaled))
    save_webgl_html(joinpath(output,"$file.html"),normal_comparison_cases(mode))
end

function skin_world_cases(mode)
    asset,skin,inverse_matrices=mktempdir() do directory
        skin_binding_fixture(directory,:gltf,:omitted,mode===:detached ? Vec3(1.2,0.8,1.0) : Vec3())
    end
    blue=MeshBasicMaterial(color=Color3(0.0,0.0,1.0),side=:double)
    skin.material=blue
    if mode in (:texture,:cpu)
        while length(skin.skeleton.bones)<65
            push!(skin.skeleton.bones,Bone())
            push!(skin.skeleton.bind_inverses,Mat4())
        end
    end
    if mode!==:detached
        child=Mesh(PlaneGeometry(width=0.8,height=0.8),MeshBasicMaterial(color=Color3(1.0,0.0,0.0),side=:double))
        child.position=Vec3(5.0,0.0,0.0)
        add!(skin,child)
    end
    bind=Mat4();prefix=Mat4();joint_shift=mode===:animated ? 0.3 : 0.0
    animations=AnimationClip[]
    if mode===:detached
        bind=mat4_translation(0.3,0.1,0.0)*mat4_rotation_z(0.2)*mat4_scaling(1.1,0.9,1.0)
        skin.bind_mode=:detached;skin.bind_matrix=bind;skin.bind_matrix_inverse=mat4_inverse(bind)
        prefix=mat4_translation(10.0,0.0,0.0)*mat4_scaling(1.2,0.8,1.0)*mat4_inverse(bind)
    elseif mode===:animated
        tracks=[KeyframeTrack(skin.skeleton.bones[1],:position,[0.0,1.0],
                    [Vec3(1.3,0.0,0.0),Vec3(1.3,0.0,0.0)]),
                KeyframeTrack(first(get_children(asset.scene)),:position,[0.0,1.0],
                    [Vec3(100.0,0.0,0.0),Vec3(100.0,0.0,0.0)])]
        push!(animations,AnimationClip("skin-world-motion",tracks))
    end
    reference_geometry=deepcopy(skin.geometry)
    world_positions=skin_binding_reference_positions(skin.geometry,inverse_matrices;
        bind=bind,prefix=prefix,joint_shift=joint_shift)
    reference_geometry.positions=reduce(vcat,([point.x,point.y,point.z] for point in world_positions))
    reference_scene=Scene();add!(reference_scene,Mesh(reference_geometry,blue))
    center=sum(world_positions)/length(world_positions)
    view_camera=camera_at(center.x,4.0)
    view_camera.position=center+Vec3(0.0,0.0,4.0);view_camera.target=center
    return [WebGLExportCase("normal-actual","World skin pose","Joint transforms determine the skin pose",asset.scene;camera=view_camera,animations=animations),
            WebGLExportCase("normal-reference","Baked world pose","Independent joint-transform oracle",reference_scene;camera=view_camera)]
end
for mode in (:uniform,:texture,:cpu,:detached,:animated)
    save_webgl_html(joinpath(output,"skin_world_$mode.html"),skin_world_cases(mode))
end

function tangent_comparison_cases(mode)
    geometry=PlaneGeometry(width=1.0,height=1.0)
    set_attribute!(geometry,:tangent,repeat([0.0,1.0,0.0,1.0],geometry.n_vertices),4)
    normal_map=Texture(reshape([0.5,1.0,0.5],1,1,3);colorspace=:linear)
    material=MeshLambertMaterial(normal_map=normal_map,side=:double)
    deformation=mat4_scaling(-2.0,1.0,0.5)
    actual_scene=Scene()
    if mode===:instanced
        object=InstancedMesh(geometry,material,1)
        set_instance_matrix!(object,1,deformation)
    elseif mode===:model
        object=Mesh(geometry,material);object.scale=Vec3(-2.0,1.0,0.5)
    else
        bone_count=mode===:uniform ? 1 : 65
        bones=[Bone() for _ in 1:bone_count]
        bones[1].scale=Vec3(-2.0,1.0,0.5)
        object=SkinnedMesh(geometry,material,Skeleton(bones,fill(Mat4(),bone_count)),
            fill((1,1,1,1),geometry.n_vertices),fill((1.0,0.0,0.0,0.0),geometry.n_vertices))
    end
    add!(actual_scene,object)
    reference_geometry=transform_geometry(geometry,deformation)
    reference_geometry.indices=copy(geometry.indices)
    reference_scene=Scene();add!(reference_scene,Mesh(reference_geometry,material))
    for scene in (actual_scene,reference_scene)
        add!(scene,DirectionalLight(position=Vec3(-4.0,0.0,2.0),intensity=1.0))
    end
    camera=camera_at(0.0,4.0)
    return [WebGLExportCase("normal-actual","Deformed tangent frame","Normal-mapped reflection",actual_scene;
                camera=camera,output_color_space=:linear),
            WebGLExportCase("normal-reference","Baked tangent frame","Equivalent normal-map basis",reference_scene;
                camera=camera,output_color_space=:linear)]
end
for (file,mode) in (("skin_tangent_uniform",:uniform),("skin_tangent_texture",:texture),
                    ("skin_tangent_cpu",:cpu),("instanced_tangent",:instanced),("model_tangent",:model))
    save_webgl_html(joinpath(output,"$file.html"),tangent_comparison_cases(mode))
end

function layered_view_case(id; lights=false)
    layer_scene = Scene()
    layer_parent = Group()
    layers_set!(object_layers(layer_parent),7)
    add!(layer_scene,layer_parent)
    if lights
        white = Mesh(PlaneGeometry(width=1.4,height=1.4),MeshLambertMaterial())
        layers_enable_all!(object_layers(white))
        add!(layer_parent,white)
        red_light=AmbientLight(color=Color3(1.0,0.0,0.0),intensity=0.6)
        blue_light=AmbientLight(color=Color3(0.0,0.0,1.0),intensity=0.6)
        layers_set!(object_layers(red_light),0);layers_set!(object_layers(blue_light),31)
        add!(layer_scene,red_light);add!(layer_scene,blue_light)
    else
        red_object=Mesh(PlaneGeometry(width=1.4,height=1.4),MeshBasicMaterial(color=Color3(1.0,0.0,0.0)))
        blue_object=Mesh(PlaneGeometry(width=1.4,height=1.4),MeshBasicMaterial(color=Color3(0.0,0.0,1.0)))
        layers_set!(object_layers(red_object),0);layers_set!(object_layers(blue_object),31)
        add!(layer_parent,red_object);add!(layer_parent,blue_object)
    end
    top_camera=camera_at(0.0,3.0);bottom_camera=camera_at(0.0,3.0)
    layers_set!(object_layers(top_camera),0);layers_set!(object_layers(bottom_camera),31)
    cameras=ArrayCamera([top_camera,bottom_camera],[(0,0,320,240),(0,240,320,240)])
    return WebGLExportCase(id,id,"Camera layers select each view",layer_scene;camera=cameras)
end

save_webgl_html(joinpath(output,"layered_views.html"),[layered_view_case("layered-views")])
save_webgl_html(joinpath(output,"layered_lights.html"),[layered_view_case("layered-lights";lights=true)])

function layered_shadow_case(id; reference=false, hidden=false)
    shadow_scene=Scene(background=Color3(0.02,0.03,0.04))
    receiver=Mesh(PlaneGeometry(width=3.0,height=3.0),MeshLambertMaterial(side=:double);
                  receive_shadow=true)
    layers_enable_all!(object_layers(receiver))
    caster=Mesh(BoxGeometry(width=0.6,height=0.6,depth=0.3),
                MeshBasicMaterial(color=Color3(0.2,0.2,0.2));cast_shadow=true)
    caster.position=Vec3(0.3,0.1,0.6)
    caster.visible=!hidden
    layers_set!(object_layers(caster),reference ? 0 : 1)
    add!(shadow_scene,receiver);add!(shadow_scene,caster)
    sun=DirectionalLight(position=Vec3(-1.0,1.5,4.0),intensity=0.8)
    sun.cast_shadow=true
    layers_enable_all!(object_layers(sun))
    add!(shadow_scene,sun)
    top_camera=camera_at(0.0,4.0);bottom_camera=camera_at(0.0,4.0)
    layers_set!(object_layers(top_camera),0)
    layers_set!(object_layers(bottom_camera),reference ? 0 : 1)
    cameras=ArrayCamera([top_camera,bottom_camera],[(0,0,320,240),(0,240,320,240)])
    return WebGLExportCase(id,"Layered shadow comparison","Reference views",shadow_scene;camera=cameras)
end
save_webgl_html(joinpath(output,"layered_shadows.html"),[
    layered_shadow_case("shadow-layers"),
    layered_shadow_case("shadow-hidden";reference=true,hidden=true),
    layered_shadow_case("shadow-visible";reference=true),
])

function hierarchy_case(id; animated=false, instanced=false, skinned=false)
    hierarchy_scene=Scene()
    hierarchy_scene.position=Vec3(animated ? 0.0 : 0.1,0.0,0.0)
    external=Group()
    external.position=Vec3(0.2,0.0,0.0)
    add!(external,hierarchy_scene)
    invisible_material=MeshBasicMaterial(transparent=true,opacity=0.0,depth_write=false)
    anchor=instanced ? InstancedMesh(PlaneGeometry(),invisible_material,2) :
                       Mesh(PlaneGeometry(),invisible_material)
    anchor.position=Vec3(animated ? 0.0 : 0.6,0.0,0.0)
    if instanced
        set_instance_matrix!(anchor,1,mat4_translation(-1.0,0.0,0.0))
        set_instance_matrix!(anchor,2,mat4_translation(1.0,0.0,0.0))
    end
    middle=Group()
    child_geometry=PlaneGeometry(width=0.4,height=0.4)
    child_material=MeshBasicMaterial(color=Color3(0.0,0.0,1.0))
    if skinned
        joint=Bone()
        # Bone attachments inherit the instanced object's base transform.
        add!(anchor,joint)
        rig=Skeleton([joint],[Mat4()])
        visible_child=SkinnedMesh(child_geometry,child_material,rig,
            fill((1,1,1,1),child_geometry.n_vertices),
            fill((1.0,0.0,0.0,0.0),child_geometry.n_vertices))
        add!(hierarchy_scene,visible_child)
    else
        visible_child=Mesh(child_geometry,child_material)
        add!(middle,visible_child)
    end
    add!(anchor,middle);add!(hierarchy_scene,anchor)
    clips=AnimationClip[]
    if animated
        tracks=[KeyframeTrack(hierarchy_scene,:position,[0.0,1.0],
                              [Vec3(0.1,0.0,0.0),Vec3(0.1,0.0,0.0)]),
                KeyframeTrack(anchor,:position,[0.0,1.0],
                              [Vec3(0.6,0.0,0.0),Vec3(0.6,0.0,0.0)])]
        push!(clips,AnimationClip("parent motion",tracks))
    end
    return WebGLExportCase(id,id,"A child follows its parent transform",hierarchy_scene;
                           camera=camera_at(0.0,4.0),animations=clips)
end
save_webgl_html(joinpath(output,"hierarchy_bones.html"),
    [hierarchy_case("hierarchy_bones";instanced=true,skinned=true)])
for (name,animated,instanced) in (("hierarchy_static",false,false),
                                 ("hierarchy_animated",true,false),
                                 ("hierarchy_instances",false,true))
    save_webgl_html(joinpath(output,"$name.html"),[hierarchy_case(name;animated=animated,instanced=instanced)])
end

function lod_case(id; nested=false, manual=false, zoomed=false, inner_far=false)
    lod_scene=Scene()
    root_lod=LOD(auto_update=!manual)
    near_group=Group()
    red_member=Mesh(PlaneGeometry(width=0.6,height=0.6),MeshBasicMaterial(color=Color3(1.0,0.0,0.0)))
    red_member.position=Vec3(-0.45,0.0,0.2)
    green_member=Mesh(PlaneGeometry(width=0.6,height=0.6),MeshBasicMaterial(color=Color3(0.0,1.0,0.0)))
    green_member.position=Vec3(0.45,0.0,0.2)
    add!(near_group,red_member);add!(near_group,green_member)
    near_level = if nested
        inner=LOD()
        add_lod_level!(inner,0.0,near_group)
        add_lod_level!(inner,4.0,Mesh(PlaneGeometry(),MeshBasicMaterial(color=Color3(1.0,1.0,0.0))))
        inner
    else
        near_group
    end
    far_level=Mesh(PlaneGeometry(width=1.5,height=0.6),MeshBasicMaterial(color=Color3(0.0,0.0,1.0)))
    add_lod_level!(root_lod,0.0,near_level)
    add_lod_level!(root_lod,5.0,far_level;hysteresis=0.2)
    add!(lod_scene,root_lod)
    lod_update!(root_lod,0.0)
    nested && lod_update!(near_level,0.0)
    top_camera=camera_at(0.0,zoomed ? 8.0 : inner_far ? 4.5 : 3.0)
    zoomed && (top_camera.zoom=4.0)
    bottom_camera=camera_at(0.0,8.0)
    cameras=ArrayCamera([top_camera,bottom_camera],[(0,0,320,240),(0,240,320,240)])
    return WebGLExportCase(id,id,"Whole LOD levels follow each view",lod_scene;camera=cameras)
end
save_webgl_html(joinpath(output,"lod_nested_far.html"),
    [lod_case("lod_nested_far";nested=true,inner_far=true)])
for (name,nested,manual,zoomed) in (("lod_groups",false,false,false),
                                    ("lod_nested",true,false,false),
                                    ("lod_manual",false,true,false),
                                    ("lod_zoom",false,false,true))
    save_webgl_html(joinpath(output,"$name.html"),[lod_case(name;nested=nested,manual=manual,zoomed=zoomed)])
end

function scene_for_views()
    result = Scene(background=Color3(0.01, 0.01, 0.01))
    red = Mesh(PlaneGeometry(width=1.4, height=1.4),
               MeshBasicMaterial(color=Color3(1.0, 0.0, 0.0), side=:double))
    red.position = Vec3(-2.0, 0.0, 1.0)
    blue = Mesh(PlaneGeometry(width=1.4, height=1.4),
                MeshBasicMaterial(color=Color3(0.0, 0.0, 1.0), side=:double))
    blue.position = Vec3(2.0, 0.0, 0.0)
    add!(result, red)
    add!(result, blue)
    return result
end

stacked_scene = scene_for_views()
stacked_camera = ArrayCamera([camera_at(-2.0, 3.0), camera_at(2.0, 3.0)],
                             [(0, 0, 320, 240), (0, 240, 320, 240)])
stacked = WebGLExportCase("stacked", "Stacked views", "Top red, bottom blue",
                          stacked_scene; camera=stacked_camera)
save_webgl_html(joinpath(output, "stacked.html"), [stacked])

overlap_scene = scene_for_views()
offscreen = Mesh(PlaneGeometry(),
                 MeshBasicMaterial(transparent=true, opacity=0.1, depth_write=false))
offscreen.position = Vec3(100.0, 0.0, 0.0)
add!(overlap_scene, offscreen)
overlap_camera = ArrayCamera([camera_at(-2.0, 3.0), camera_at(2.0, 5.0)],
                             [(0, 0, 320, 240), (0, 0, 320, 240)])
overlap = WebGLExportCase("overlap", "Overlapping views", "The second view is blue",
                          overlap_scene; camera=overlap_camera)
save_webgl_html(joinpath(output, "overlap.html"), [overlap])

empty_scene = Scene()
empty_batch = InstancedMesh(PlaneGeometry(), MeshBasicMaterial(), 0)
add!(empty_scene, empty_batch)
save_webgl_html(joinpath(output, "empty_instances.html"),
    [WebGLExportCase("empty", "Empty instances", "No instances are visible",
                     empty_scene; camera=camera_at(0.0, 3.0))])

parent_scene = Scene()
empty_parent = InstancedMesh(PlaneGeometry(), MeshBasicMaterial(), 0)
empty_parent.position = Vec3(0.4, 0.0, 0.0)
child = Mesh(PlaneGeometry(), MeshBasicMaterial(color=Color3(0.0, 0.0, 1.0)))
add!(empty_parent, child)
add!(parent_scene, empty_parent)
save_webgl_html(joinpath(output, "empty_instance_parent.html"),
    [WebGLExportCase("parent", "Empty instance parent", "The child remains visible",
                     parent_scene; camera=camera_at(0.4, 3.0))])

for mode in (:triangles, :lines, :points)
    instance_scene = Scene()
    instance_geometry = mode === :triangles ? PlaneGeometry(width=0.4, height=0.4) :
        mode === :lines ? BufferGeometry([-0.15, 0.0, 0.0, 0.15, 0.0, 0.0],
                                          Float64[], Float64[], [1, 2], 2, 0) :
        BufferGeometry([0.0, 0.0, 0.0], Float64[], Float64[], [1], 1, 0)
    instance_material = mode === :triangles ? MeshBasicMaterial() :
        mode === :lines ? LineBasicMaterial(linewidth=2.0) :
        PointsMaterial(size=24.0, size_attenuation=false)
    instance_batch = InstancedMesh(instance_geometry, instance_material, 2; draw_mode=mode)
    set_instance_matrix!(instance_batch, 1, mat4_translation(-0.6, 0.0, 0.0))
    set_instance_matrix!(instance_batch, 2, mat4_translation(0.6, 0.0, 0.0))
    set_instance_color!(instance_batch, 1, Color3(1.0, 0.0, 0.0))
    set_instance_color!(instance_batch, 2, Color3(0.0, 0.0, 1.0))
    add!(instance_scene, instance_batch)
    save_webgl_html(joinpath(output, "instanced_$mode.html"),
        [WebGLExportCase("instanced-$mode", "Instanced $mode", "Red left, blue right",
                         instance_scene; camera=camera_at(0.0, 3.0))])
end

# Orbit limits without an explicit camera: the runtime must fit, zoom and clip a scene 2200
# units across exactly like a 2-unit one (0.1.7 clamped the orbit to 2.5..24 units and the
# far plane to 180 units, so this plane was invisible and the fitted view unreachable).
orbit_scene = Scene(background=Color3(0.01, 0.01, 0.01))
orbit_plane = Mesh(PlaneGeometry(width=4000.0, height=4000.0),
                   MeshBasicMaterial(color=Color3(0.0, 0.0, 1.0), side=:double))
orbit_plane.rotation = Euler(-pi / 2, 0.0, 0.0)
add!(orbit_scene, orbit_plane)
save_webgl_html(joinpath(output, "orbit_zoom_limits.html"),
    [WebGLExportCase("orbit-zoom", "Orbit zoom limits", "Scale-relative zoom and clip planes",
                     orbit_scene; radius=2200.0, height=825.0)])
