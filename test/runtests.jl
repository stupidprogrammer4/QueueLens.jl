using Test
using Random
using QueueLens

include("support/fixtures.jl")

@testset "QueueLens.jl" begin
    @testset "Models" begin
        include("models/distribution_tests.jl")
        include("models/service_step_tests.jl")
        include("models/job_tests.jl")
    end
    @testset "Calendar and scheduling" begin
        include("simulation/calendar_tests.jl")
        include("simulation/engine_tests.jl")
        include("simulation/step_engine_tests.jl")
        include("simulation/worker_tests.jl")
        include("simulation/scenario_tests.jl")
        include("simulation/engine_helpers_tests.jl")
    end
    @testset "Admission and resources" begin
        include("resources/resource_tests.jl")
        include("resources/resource_api_tests.jl")
        include("resources/admission_tests.jl")
        include("resources/admission_api_tests.jl")
    end
    @testset "Failures" begin
        include("failures/failure_scaffolding_tests.jl")
        include("failures/failure_handler_tests.jl")
        include("failures/failure_contract_tests.jl")
    end
    @testset "Timeouts" begin
        include("timeouts/timeout_scaffolding_tests.jl")
        include("timeouts/timeout_contract_tests.jl")
    end
    @testset "Monitoring and reporting" begin
        include("reporting/monitoring_tests.jl")
        include("reporting/monitoring_report_tests.jl")
        include("reporting/capacity_tradeoff_tests.jl")
        include("reporting/metric_tests.jl")
        include("reporting/repeated_tests.jl")
    end
end
