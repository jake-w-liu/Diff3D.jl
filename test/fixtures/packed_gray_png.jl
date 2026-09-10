using Diff3D

function packed_gray_png(samples::Matrix{UInt8},bitdepth::Int;
                         interlace::Bool=false,transparent=nothing,filter::Int=0)
    bitdepth in (1,2,4) || throw(ArgumentError("packed gray depth must be 1, 2, or 4"))
    filter in 0:4 || throw(ArgumentError("PNG filter must be between 0 and 4"))
    height,width=size(samples)
    0<width<=typemax(Int32) && 0<height<=typemax(Int32) ||
        throw(ArgumentError("PNG dimensions must be positive 31-bit integers"))
    maximum_sample=(1<<bitdepth)-1
    all(value->value<=maximum_sample,samples) ||
        throw(ArgumentError("sample exceeds the selected bit depth"))
    transparent===nothing || (transparent isa Integer && !(transparent isa Bool) &&
        0<=transparent<=maximum_sample) || throw(ArgumentError("invalid transparent sample"))
    passes=interlace ? ((0,0,8,8),(4,0,8,8),(0,4,4,8),(2,0,4,4),
                       (0,2,2,4),(1,0,2,2),(0,1,1,2)) : ((0,0,1,1),)
    raw=UInt8[]
    for (x0,y0,xstep,ystep) in passes
        columns=(x0+1):xstep:width;rows=(y0+1):ystep:height
        (isempty(columns)||isempty(rows)) && continue
        previous=zeros(UInt8,cld(length(columns)*bitdepth,8))
        for row in rows
            packed=zeros(UInt8,length(previous))
            for (index,column) in enumerate(columns)
                bit=(index-1)*bitdepth
                packed[bit÷8+1] |= samples[row,column] << (8-bitdepth-bit%8)
            end
            push!(raw,UInt8(filter))
            for index in eachindex(packed)
                a=index>1 ? Int(packed[index-1]) : 0
                b=Int(previous[index]);c=index>1 ? Int(previous[index-1]) : 0
                predictor=if filter==0
                    0
                elseif filter==1
                    a
                elseif filter==2
                    b
                elseif filter==3
                    (a+b)÷2
                else
                    p=a+b-c;da=abs(p-a);db=abs(p-b);dc=abs(p-c)
                    da<=db && da<=dc ? a : db<=dc ? b : c
                end
                push!(raw,UInt8(mod(Int(packed[index])-predictor,256)))
            end
            previous=packed
        end
    end
    big_endian(value)=UInt8[(value>>24)&0xff,(value>>16)&0xff,(value>>8)&0xff,value&0xff]
    header=vcat(big_endian(width),big_endian(height),UInt8[bitdepth,0,0,0,interlace])
    output=IOBuffer();write(output,UInt8[137,80,78,71,13,10,26,10])
    Diff3D._png_chunk(output,"IHDR",header)
    transparent===nothing || Diff3D._png_chunk(output,"tRNS",UInt8[0,transparent])
    Diff3D._png_chunk(output,"IDAT",Diff3D._zlib_store(raw))
    Diff3D._png_chunk(output,"IEND",UInt8[])
    return take!(output)
end
