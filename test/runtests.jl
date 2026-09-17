using Test
using Random
using QueueLens

@testset "QueueLens.jl" begin
    include("distribution_tests.jl")
    include("service_step_tests.jl")
    include("job_tests.jl")
    include("calendar_tests.jl")
    include("engine_tests.jl")
    include("step_engine_tests.jl")
    include("worker_tests.jl")
    include("resource_tests.jl")
    include("resource_api_tests.jl")
    include("admission_tests.jl")
    include("admission_api_tests.jl")
    include("monitoring_tests.jl")
    include("scenario_tests.jl")
    include("metric_tests.jl")
    include("repeated_tests.jl")
end
