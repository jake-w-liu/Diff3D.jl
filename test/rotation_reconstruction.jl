using Test
using Diff3D
using ForwardDiff

@testset "Euler reconstruction preserves near-gimbal rotations" begin
    orders = (:XYZ,:XZY,:YXZ,:YZX,:ZXY,:ZYX)
    for T in (Float32,Float64), order in orders,
        phase in ((0.3,0.5),(-1.2,2.4),(2.7,-2.6)),
        gap in (-1e-3,-1e-6,-1e-10,0.0,1e-10,1e-6,1e-3), sign in (-1,1)
        axes = [findfirst(==(axis),['X','Y','Z']) for axis in String(order)]
        angles = zeros(T,3)
        angles[axes[1]]=T(phase[1]);angles[axes[3]]=T(phase[2])
        angles[axes[2]]=T(sign)*(T(pi)/2-T(gap))
        quaternion = quat_from_euler(angles...;order=order)
        euler = Diff3D._transform_quaternion_to_euler(quaternion,order)
        expected = quat_to_mat4(quat_normalize(quaternion))
        actual = quat_to_mat4(quat_from_euler(euler.x,euler.y,euler.z;order=order))
        @test euler.order === order
        @test maximum(abs.(collect(actual.e).-collect(expected.e))) <= 32eps(T)
    end
    setprecision(BigFloat,128) do
        for order in orders
            axes = [findfirst(==(axis),['X','Y','Z']) for axis in String(order)]
            angles = BigFloat[0.3,0.4,0.5]
            angles[axes[2]]=BigFloat(pi)/2-BigFloat("1e-25")
            quaternion=quat_from_euler(angles...;order=order)
            euler=Diff3D._transform_quaternion_to_euler(quaternion,order)
            restored=quat_to_mat4(quat_from_euler(euler.x,euler.y,euler.z;order=order))
            expected=quat_to_mat4(quat_normalize(quaternion))
            @test maximum(abs.(collect(restored.e).-collect(expected.e))) <= 64eps(BigFloat)
        end
    end
    @test_throws ArgumentError("unknown Euler order :invalid") Diff3D._transform_quaternion_to_euler(Quaternion(),:invalid)

    for order in orders, near_gimbal in (false,true)
        input_angles=[0.3,0.4,0.5]
        if near_gimbal
            middle_axis=findfirst(==(String(order)[2]),['X','Y','Z'])
            input_angles[middle_axis]=pi/2-1e-6
        end
        reference_function = parameters -> begin
            reference_matrix=quat_to_mat4(quat_from_euler(parameters...;order=order))
            sum(i*reference_matrix.e[i] for i in 1:16)
        end
        reconstructed_function = parameters -> begin
            reconstructed_euler=Diff3D._transform_quaternion_to_euler(
                quat_from_euler(parameters...;order=order),order)
            reconstructed_matrix=quat_to_mat4(quat_from_euler(
                reconstructed_euler.x,reconstructed_euler.y,reconstructed_euler.z;order=order))
            sum(i*reconstructed_matrix.e[i] for i in 1:16)
        end
        reference_gradient=ForwardDiff.gradient(reference_function,input_angles)
        @test ForwardDiff.gradient(reconstructed_function,input_angles) ≈ reference_gradient atol=1e-8 rtol=1e-8
        @test reverse_gradient(reconstructed_function,input_angles) ≈ reference_gradient atol=1e-8 rtol=1e-8
    end
end
