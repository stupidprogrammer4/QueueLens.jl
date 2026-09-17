# Isolate the executable experiment's helpers from other tests and experiments.
module CapacityTradeoffExperiment
    include(joinpath(@__DIR__, "..", "experiments", "capacity_tradeoff.jl"))
end

@testset "capacity tradeoff experiment" begin
    cases = CapacityTradeoffExperiment.run_capacity_comparison()
    @test length(cases) == 3
    expected = (
        ("A", 2, 1, [3.0, 6.0, 9.0, 12.0], 0.75, 0.75, 0.875),
        ("B", 4, 1, [3.0, 6.0, 9.0, 12.0], 0.0, 1.5, 0.625),
        ("C", 2, 2, [3.0, 3.0, 6.0, 6.0], 1.0, 0.0, 1.0),
    )
    for (case, (name, workers, db_capacity, completions, worker_queue, db_queue, worker_util)) in zip(cases, expected)
        stats = case.result.monitoring
        @test case.name == name
        @test case.workers == workers
        @test case.db_capacity == db_capacity
        @test [job.id for job in case.result.completed] == [1, 2, 3, 4]
        @test [job.completion_time for job in case.result.completed] == completions
        @test isempty(case.result.rejected)
        @test stats.duration == maximum(completions)
        @test stats.worker_capacity == workers
        @test stats.resources[:db].capacity == db_capacity
        @test stats.mean_queue_length == worker_queue
        @test stats.resources[:db].mean_queue_length == db_queue
        @test stats.worker_utilization == worker_util
        @test stats.resources[:db].utilization == 1.0
    end
    @test cases[1].result.monitoring.duration == cases[2].result.monitoring.duration
    @test cases[3].result.monitoring.duration == cases[1].result.monitoring.duration / 2
    @test cases[1].result.monitoring.resources !== cases[2].result.monitoring.resources
    output = sprint(CapacityTradeoffExperiment.main)
    @test occursin("worker queue", output)
    @test occursin("DB queue", output)
    @test occursin("A completion times (s): 3.0, 6.0, 9.0, 12.0", output)
    @test occursin("B completion times (s): 3.0, 6.0, 9.0, 12.0", output)
    @test occursin("C completion times (s): 3.0, 3.0, 6.0, 6.0", output)
end
