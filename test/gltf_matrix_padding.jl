using Test
using Diff3D

@testset "glTF matrix columns obey four-byte alignment" begin
    # Each record is authored column by column. Nonzero 0xee padding makes an
    # accidental contiguous read visible; the third field counts trailing pad.
    fixtures = (
        ("MAT2",5121,2,UInt8[1,2,0xee,0xee,3,4,0xee,0xee],Float64[1,2,3,4]),
        ("MAT3",5121,1,UInt8[1,2,3,0xee,4,5,6,0xee,7,8,9,0xee],Float64.(1:9)),
        ("MAT3",5123,2,UInt8[1,0,2,0,3,0,0xee,0xee,4,0,5,0,6,0,0xee,0xee,7,0,8,0,9,0,0xee,0xee],Float64.(1:9)),
        ("MAT2",5120,2,UInt8[0x80,0x7f,0xee,0xee,0xff,0,0xee,0xee],Float64[-128,127,-1,0]),
        ("MAT3",5122,2,UInt8[0,0x80,0xff,0x7f,0xff,0xff,0xee,0xee,0,0,1,0,2,0,0xee,0xee,3,0,4,0,5,0,0xee,0xee],Float64[-32768,32767,-1,0,1,2,3,4,5]),
        ("MAT2",5123,0,UInt8[1,0,2,0,3,0,4,0],Float64[1,2,3,4]),
        ("MAT4",5121,0,UInt8.(1:16),Float64.(1:16)),
    )
    function matrix_payload(record, count, gap, trailing_pad, omit_trailing)
        encoded = UInt8[]
        for element in 1:count
            append!(encoded,record)
            element < count && append!(encoded,fill(UInt8(0xdc),gap))
        end
        count > 0 && omit_trailing && resize!(encoded,length(encoded)-trailing_pad)
        return encoded
    end
    function dense_matrix_fixture(fixture, count, gap, prefix, omit_trailing, normalized)
        fixture_kind, fixture_component_type, fixture_trailing_pad, fixture_record, _ = fixture
        encoded = matrix_payload(fixture_record,count,gap,fixture_trailing_pad,omit_trailing)
        # The bufferView starts after an external canary. Its accessor offset
        # and its own extent are independent of the containing buffer's tail.
        storage = vcat(fill(UInt8(0xbc),4+prefix),encoded,fill(UInt8(0xab),4))
        accessor = Dict{String,Any}("bufferView"=>0,"byteOffset"=>prefix,
            "count"=>count,"type"=>fixture_kind,"componentType"=>fixture_component_type,"normalized"=>normalized)
        view = Dict{String,Any}("buffer"=>0,"byteOffset"=>4,"byteLength"=>prefix+length(encoded))
        gap > 0 && (view["byteStride"]=length(fixture_record)+gap)
        document = Dict{String,Any}("accessors"=>[accessor],"bufferViews"=>[view])
        return document,[storage]
    end
    for fixture in fixtures, normalized in (false,true)
        kind, component_type, trailing_pad, record, values = fixture
        divisor = component_type==5120 ? 127 : component_type==5121 ? 255 :
                  component_type==5122 ? 32767 : 65535
        decoded_values = normalized ? max.(values ./ divisor,-1.0) : values
        for count in (1,3), gap in (0,4), prefix in (0,8), omit_trailing in (false,true)
            dense_doc,dense_buffers = dense_matrix_fixture(fixture,count,gap,prefix,omit_trailing,normalized)
            saved_dense = deepcopy(dense_buffers)
            output,ncomp,n = Diff3D._gltf_accessor(dense_doc,dense_buffers,0)
            @test (ncomp,n)==(length(values),count)
            @test output ≈ repeat(decoded_values,count)
            @test dense_buffers == saved_dense
        end
        short_doc,short_buffers = dense_matrix_fixture(fixture,2,4,8,true,normalized)
        short_doc["bufferViews"][1]["byteLength"] -= 1
        @test_throws "exceeds bufferView byteLength" Diff3D._gltf_accessor(short_doc,short_buffers,0)
        offset_doc,offset_buffers = dense_matrix_fixture(fixture,2,0,1,true,normalized)
        @test_throws "column alignment" Diff3D._gltf_accessor(offset_doc,offset_buffers,0)
        stride_doc,stride_buffers = dense_matrix_fixture(fixture,2,2,0,true,normalized)
        @test_throws "column alignment" Diff3D._gltf_accessor(stride_doc,stride_buffers,0)

        for has_dense in (false,true), omit_trailing in (false,true)
            sparse_payload = matrix_payload(record,2,0,trailing_pad,omit_trailing)
            sparse_buffers = [UInt8[0,2],
                vcat(fill(UInt8(0xbc),8),sparse_payload,fill(UInt8(0xab),4)),
                zeros(UInt8,3*length(record))]
            sparse_accessor = Dict{String,Any}("count"=>3,"type"=>kind,
                "componentType"=>component_type,"normalized"=>normalized,
                "sparse"=>Dict{String,Any}("count"=>2,
                    "indices"=>Dict{String,Any}("bufferView"=>0,"componentType"=>5121),
                    "values"=>Dict{String,Any}("bufferView"=>1,"byteOffset"=>4)))
            has_dense && (sparse_accessor["bufferView"]=2)
            sparse_doc = Dict{String,Any}("accessors"=>[sparse_accessor],
                "bufferViews"=>[Dict{String,Any}("buffer"=>0,"byteLength"=>2),
                    Dict{String,Any}("buffer"=>1,"byteOffset"=>4,"byteLength"=>4+length(sparse_payload)),
                    Dict{String,Any}("buffer"=>2,"byteLength"=>3*length(record))])
            sparse_output,ncomp,n = Diff3D._gltf_accessor(sparse_doc,sparse_buffers,0)
            @test (ncomp,n)==(length(values),3)
            @test sparse_output ≈ vcat(decoded_values,zeros(length(values)),decoded_values)
            for invalid_indices in (UInt8[2,0], UInt8[0,0], UInt8[0,3])
                invalid_buffers = [invalid_indices,sparse_buffers[2],sparse_buffers[3]]
                @test_throws ErrorException Diff3D._gltf_accessor(sparse_doc,invalid_buffers,0)
            end
            if omit_trailing
                sparse_doc["bufferViews"][2]["byteLength"] -= 1
                @test_throws "sparse values payload exceeds bufferView byteLength" Diff3D._gltf_accessor(sparse_doc,sparse_buffers,0)
            end
            # Keep a complete view while moving the sparse matrix start by one
            # byte, so alignment is checked independently of payload length.
            sparse_doc["bufferViews"][2]["byteLength"] = 5+length(sparse_payload)
            sparse_doc["accessors"][1]["sparse"]["values"]["byteOffset"] = 5
            @test_throws "column alignment" Diff3D._gltf_accessor(sparse_doc,sparse_buffers,0)
        end
        empty_doc,empty_buffers = dense_matrix_fixture(fixture,0,0,0,true,normalized)
        @test Diff3D._gltf_accessor(empty_doc,empty_buffers,0) == (Float64[],length(values),0)
    end

    vectors = Dict{String,Any}("accessors"=>[Dict{String,Any}("bufferView"=>0,
        "count"=>2,"type"=>"VEC4","componentType"=>5121)],
        "bufferViews"=>[Dict{String,Any}("buffer"=>0,"byteLength"=>8)])
    @test Diff3D._gltf_accessor(vectors,[UInt8.(1:8)],0) == (Float64.(1:8),4,2)
    float_matrix_bytes = IOBuffer()
    for value in Float32.(1:9)
        write(float_matrix_bytes,htol(reinterpret(UInt32,value)))
    end
    float_matrix = Dict{String,Any}("accessors"=>[Dict{String,Any}("bufferView"=>0,
        "count"=>1,"type"=>"MAT3","componentType"=>5126)],
        "bufferViews"=>[Dict{String,Any}("buffer"=>0,"byteLength"=>36)])
    @test Diff3D._gltf_accessor(float_matrix,[take!(float_matrix_bytes)],0) == (Float64.(1:9),9,1)
    indices = Dict{String,Any}("accessors"=>[Dict{String,Any}("bufferView"=>0,
        "count"=>3,"type"=>"SCALAR","componentType"=>5121)],
        "bufferViews"=>[Dict{String,Any}("buffer"=>0,"byteLength"=>3)])
    @test Diff3D._gltf_primitive_indices(indices,[UInt8[0,2,1]],0,3) == [1,3,2]

    if Base.JLOptions().opt_level > 0
        function warmed_accessor_bytes(document, buffers)
            for _ in 1:3
                Diff3D._gltf_accessor(document,buffers,0)
            end
            return @allocated Diff3D._gltf_accessor(document,buffers,0)
        end
        matrix_count = 1000
        allocation_doc,allocation_buffers = dense_matrix_fixture(fixtures[2],matrix_count,0,0,true,false)
        # The output contains nine Float64 components per matrix. Metadata and
        # tuple setup must stay bounded independently of the matrix count.
        allocation_limit = 9*matrix_count*sizeof(Float64)+16384
        @test warmed_accessor_bytes(allocation_doc,allocation_buffers) <= allocation_limit
        sparse_indices = collect(reinterpret(UInt8,htol.(UInt16.(0:matrix_count-1))))
        push!(allocation_buffers,sparse_indices)
        push!(allocation_doc["bufferViews"],Dict{String,Any}("buffer"=>1,"byteLength"=>length(sparse_indices)))
        allocation_accessor = allocation_doc["accessors"][1]
        delete!(allocation_accessor,"bufferView")
        delete!(allocation_accessor,"byteOffset")
        allocation_accessor["sparse"] = Dict{String,Any}("count"=>matrix_count,
            "indices"=>Dict{String,Any}("bufferView"=>1,"componentType"=>5123),
            "values"=>Dict{String,Any}("bufferView"=>0))
        @test warmed_accessor_bytes(allocation_doc,allocation_buffers) <= allocation_limit
    end
end
