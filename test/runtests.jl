using Test
using Random
using QueueLens

@testset "QueueLens.jl" begin
    include("distribution_tests.jl")
    include("calendar_tests.jl")
    include("engine_tests.jl")
    include("worker_tests.jl")
    include("scenario_tests.jl")
    include("metric_tests.jl")
    include("repeated_tests.jl")
end
