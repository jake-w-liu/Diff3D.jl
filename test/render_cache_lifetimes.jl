using Test, Diff3D
function lifetime_render!(mode, cache, scene; shadows=false, frustum=false)
    camera=PerspectiveCamera(); camera.position=Vec3(0.0,0.0,2.0)
    if mode===:soft
        soft_render_scene(scene,camera,2,2;workspace=cache)
    else
        target=RenderTarget(2,2)
        if mode===:hard
            render!(target,scene,camera;cache,shadows,shadow_resolution=2,frustum_cull=frustum)
        elseif mode===:pooled
            render_pooled!(target,scene,camera,cache)
        elseif mode===:tiled
            render_tiled!(target,scene,camera;tiles=1,cache=[cache])
        else
            error("unknown renderer")
        end
    end
    return nothing
end
@noinline function lifetime_seed!(mode,cache,kind;shadows=false,frustum=false)
    scene=Scene(); geometry=PlaneGeometry(); texture=Texture(fill(0.8,1,1,3))
    material=MeshBasicMaterial(map=texture,transparent=kind===:transparent,opacity=kind===:transparent ? 0.5 : 1.0)
    if kind===:morph
        set_attribute!(geometry,:morphPosition0,repeat([0.1,0.0,0.0],geometry.n_vertices),3)
        object=Mesh(geometry,material;morph_target_influences=[1.0])
    elseif kind===:skin
        bone=Bone()
        object=SkinnedMesh(geometry,material,Skeleton([bone],[Mat4()]),
            fill((1,1,1,1),geometry.n_vertices),fill((1.0,0.0,0.0,0.0),geometry.n_vertices))
    elseif kind===:instance
        object=InstancedMesh(geometry,material,1)
    else
        object=Mesh(geometry,material)
    end
    add!(scene,object)
    shadows && add!(scene,DirectionalLight(cast_shadow=true))
    lifetime_render!(mode,cache,scene;shadows,frustum)
    return (scene=WeakRef(scene),object=WeakRef(object),geometry=WeakRef(geometry),texture=WeakRef(texture))
end

function lifetime_collected(refs)
    GC.gc(true)
    GC.gc(true)
    return map(reference -> reference.value === nothing, refs)
end

@testset "Rendering drops obsolete scene ownership" begin
    for mode in (:soft, :hard, :pooled, :tiled), kind in (:morph, :skin, :instance)
        cache = mode === :soft ? SoftRenderSceneWorkspace() : RenderCache()
        refs = lifetime_seed!(mode, cache, kind)
        lifetime_render!(mode, cache, Scene())
        collected = GC.@preserve cache lifetime_collected(refs)
        @test all(collected)
    end
end

@testset "Changing render paths releases inactive caches" begin
    for next_mode in (:hard, :pooled, :tiled), kind in (:mesh, :transparent),
        feature in (:shadows, :frustum)
        cache = RenderCache()
        refs = lifetime_seed!(:hard, cache, kind;
                              shadows=feature === :shadows, frustum=feature === :frustum)
        lifetime_render!(next_mode, cache, Scene())
        collected = GC.@preserve cache lifetime_collected(refs)
        @test all(collected)
    end
end

@testset "Skipped instance batches release the prior slot owner" begin
    for mode in (:soft, :hard, :pooled, :tiled)
        cache = mode === :soft ? SoftRenderSceneWorkspace() : RenderCache()
        refs = lifetime_seed!(mode, cache, :instance)
        replacement = Scene()
        next_instance = InstancedMesh(PlaneGeometry(),
            MeshBasicMaterial(transparent=true, opacity=0.5), 1;
            draw_mode=mode === :hard ? :points : :triangles)
        mode === :soft && set_draw_range!(next_instance.geometry, 1, 0)
        add!(replacement, next_instance)
        lifetime_render!(mode, cache, replacement)
        collected = GC.@preserve cache lifetime_collected(refs)
        @test all(collected)
    end
end

@testset "Skipped batches release replaced materials" begin
    for mode in (:soft, :hard, :pooled, :tiled)
        cache = mode === :soft ? SoftRenderSceneWorkspace() : RenderCache()
        refs = lifetime_seed!(mode, cache, :instance)
        scene = refs.scene.value
        object = refs.object.value
        object.material = MeshBasicMaterial(transparent=true, opacity=0.5)
        if mode === :soft
            set_draw_range!(object.geometry, 1, 0)
        elseif mode === :hard
            object.draw_mode = :points
        end
        lifetime_render!(mode, cache, scene)
        collected = GC.@preserve cache scene object lifetime_collected((texture=refs.texture,))
        @test collected.texture
    end
end

@testset "Tiled workers release former scene owners" begin
    if Threads.nthreads() > 1
        caches = [RenderCache(), RenderCache()]
        refs = lifetime_seed!(:hard, caches[2], :morph)
        render_tiled!(RenderTarget(2, 2), Scene(), PerspectiveCamera(); tiles=2, cache=caches)
        collected = GC.@preserve caches lifetime_collected(refs)
        @test all(collected)
    end
end

function instance_state_prepare_allocations(states, objects)
    Diff3D._prepare_instanced_material_states!(states, objects)
    return @allocated Diff3D._prepare_instanced_material_states!(states, objects)
end

@testset "Instance cache preparation preserves warm storage" begin
    geometry = PlaneGeometry()
    material = MeshBasicMaterial()
    for count in (1, 100)
        objects = [InstancedMesh(geometry, material, 1) for _ in 1:count]
        states = Diff3D._InstancedMaterialState[]
        for (slot, object) in pairs(objects)
            Diff3D._instanced_materials!(states, slot, object, material, object.instance_colors)
        end
        materials = [state.materials for state in states]
        Diff3D._prepare_instanced_material_states!(states, objects)
        @test all(index -> states[index].materials === materials[index], eachindex(states))
        if Base.JLOptions().opt_level > 0
            instance_state_prepare_allocations(states, objects)
            @test instance_state_prepare_allocations(states, objects) <= 256
        end
        # Preparation must release owners without imposing a material type
        # assertion on an otherwise skipped batch.
        objects[1].material = nothing
        @test Diff3D._prepare_instanced_material_states!(states, objects) === states
        @test states[1].base_material === nothing
        @test isempty(states[1].materials)
    end
end
