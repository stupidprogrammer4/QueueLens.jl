# Included in the standard suite; also runnable directly:
# julia --project=. test/failures/failure_contract_tests.jl
using Test
using QueueLens
if !isdefined(@__MODULE__, :failure_fixture)
    include(joinpath(@__DIR__, "..", "support", "fixtures.jl"))
end

@testset "active-stage failure behavior" begin
    @testset "public simulation reports success and failure separately" begin
        jobs = [Job(1, 0.0, [QueueLens.ServiceStep(:db, 5.0)]),
                Job(2, 1.0, [QueueLens.ServiceStep(:db, 3.0)])]
        result = simulate(jobs, Dict(:db => 1);
                          failures = [QueueLens.JobFailed(2.0, 1, 1)])
        @test result.failed == [JobFailure(1, 0.0, 0.0, 2.0, 1, :injected)]
        @test result.completed == [JobResult(2, 1.0, 2.0, 5.0, 1.0, 4.0)]
        @test result.monitoring.duration == 5.0
        @test result.monitoring.worker_utilization == 1.0
        @test result.monitoring.resources[:db].utilization == 1.0
        @test summarize(result).num_completed == 1
        @test rejection_rate(result) == 0.0
    end

    @testset "public simulation does not count stale calendar tail" begin
        result = simulate([Job(1, 0.0, 50.0)], Dict{Symbol,Int}();
                          failures = [QueueLens.JobFailed(2.0, 1, 1)])
        @test isempty(result.completed)
        @test length(result.failed) == 1
        @test result.monitoring.duration == 2.0
        @test result.monitoring.worker_utilization == 1.0
        @test_throws ArgumentError summarize(result)
    end

    @testset "reference: failure releases worker and DB at time two" begin
        state = failure_fixture([
            Job(1, 0.0, [QueueLens.ServiceStep(:db, 5.0)]),
            Job(2, 1.0, [QueueLens.ServiceStep(:db, 3.0)]),
        ], Dict(:db => 1))
        QueueLens.schedule!(state, QueueLens.JobFailed(2.0, 1, 1))
        drain_fixture!(state)
        @test state.failed == [JobFailure(1, 0.0, 0.0, 2.0, 1, :injected)]
        @test state.results == [JobResult(2, 1.0, 2.0, 5.0, 1.0, 4.0)]
        @test isempty(state.rejected)
        @test isempty(state.records)
        @test isempty(state.waiting)
        @test isempty(state.resource_waiting[:db])
        @test state.in_use == state.resources[:db].in_use == 0
        @test state.now == 5.0
        stats = QueueLens.summarize_monitoring(state)
        @test stats.mean_queue_length == 0.2
        @test stats.worker_utilization == stats.resources[:db].utilization == 1.0
    end

    @testset "resource waiters retain FIFO priority over new worker starts" begin
        jobs = [Job(1, 0.0, [QueueLens.ServiceStep(:db, 5.0)]),
                Job(2, 1.0, [QueueLens.ServiceStep(:db, 3.0)]),
                Job(3, 1.5, [QueueLens.ServiceStep(:db, 1.0)])]
        state = failure_fixture(jobs, Dict(:db => 1), 2)
        QueueLens.schedule!(state, QueueLens.JobFailed(2.0, 1, 1))
        drain_fixture!(state)
        @test [r.id for r in state.results] == [2, 3]
        @test [r.start_time for r in state.results] == [1.0, 2.0]
        @test [r.completion_time for r in state.results] == [5.0, 6.0]
        @test length(state.failed) == 1
        @test state.in_use == state.resources[:db].in_use == 0
    end

    @testset "resource-free failure and stale tail" begin
        state = failure_fixture([Job(1, 0.0, 5.0)], Dict{Symbol,Int}())
        QueueLens.schedule!(state, QueueLens.JobFailed(2.0, 1, 1))
        drain_fixture!(state)
        @test state.now == 2.0
        @test length(state.failed) == 1
        @test isempty(state.results)
        @test state.in_use == 0
        @test state.worker_busy_stat.last_time == 2.0
        @test QueueLens.utilization(state.worker_busy_stat, 1) == 1.0
    end

    @testset "later resource-free stage does not release a previously held DB" begin
        state = failure_fixture([
            Job(1, 0.0, [QueueLens.ServiceStep(:db, 1.0), QueueLens.ServiceStep(nothing, 5.0)]),
            Job(2, 0.5, [QueueLens.ServiceStep(:db, 3.0)]),
        ], Dict(:db => 1), 2)
        QueueLens.schedule!(state, QueueLens.JobFailed(2.0, 1, 2))
        drain_fixture!(state)
        @test state.failed[1].step_index == 2
        @test state.results[1].id == 2
        @test state.results[1].completion_time == 4.0
        @test state.now == 4.0
        @test state.resources[:db].in_use == 0
    end

    @testset "duplicates and direct late completions are harmless" begin
        state = active_failure_fixture()
        failure = QueueLens.JobFailed(2.0, 1, 1)
        @test QueueLens.handle!(state, failure) === nothing
        @test QueueLens.handle!(state, failure) === nothing
        @test QueueLens.handle!(state, QueueLens.StepCompleted(5.0, 1, 1)) === nothing
        @test QueueLens.handle!(state, QueueLens.ServiceCompleted(5.0, 1)) === nothing
        @test length(state.failed) == 1
        @test isempty(state.results)
        @test state.in_use == state.resources[:db].in_use == 0
        @test state.now == 2.0
        @test QueueLens.is_stale_completion(state, QueueLens.StepCompleted(5.0, 1, 1))
        @test QueueLens.is_stale_completion(state, QueueLens.ServiceCompleted(5.0, 1))
        @test !QueueLens.is_stale_completion(state, QueueLens.StepCompleted(5.0, 99, 1))
        @test !QueueLens.is_stale_completion(state, QueueLens.JobArrival(5.0, 1))
        @test_throws ArgumentError QueueLens.handle!(state, QueueLens.StepCompleted(5.0, 99, 1))
    end

    @testset "invalid failure does not release valid jobs' resources" begin
        state = active_failure_fixture()
        @test_throws ArgumentError QueueLens.handle!(state, QueueLens.JobFailed(2.0, 1, 2))
        @test_throws ArgumentError QueueLens.handle!(state, QueueLens.JobFailed(2.0, 99, 1))
        @test isempty(state.failed)
        @test state.in_use == state.resources[:db].in_use == 1
        @test haskey(state.records, 1)
    end
end
