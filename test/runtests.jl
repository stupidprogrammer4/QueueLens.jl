using Test
using QueueLens

@testset "QueueLens.jl" begin
    include("calendar_tests.jl")
    include("engine_tests.jl")
end
