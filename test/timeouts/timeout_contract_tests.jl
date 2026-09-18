# Included in the standard suite; also runnable directly:
# Run: julia --project=. test/timeouts/timeout_contract_tests.jl
using Test
using QueueLens
if !isdefined(@__MODULE__, :failure_fixture)
    include(joinpath(@__DIR__, "..", "support", "fixtures.jl"))
end

@testset "whole-job timeout behavior" begin
    @testset "read-only stale-event classification" begin
        state = timeout_fixture()
        @test !QueueLens.is_stale_event(state, QueueLens.JobTimedOut(2.0, 1))
        @test QueueLens.is_stale_event(state, QueueLens.JobTimedOut(2.0, 99))
        @test !QueueLens.is_stale_event(state, QueueLens.JobArrival(2.0, 99))
        @test !QueueLens.is_stale_event(state, QueueLens.StepCompleted(5.0, 99, 1))
        @test !QueueLens.is_stale_event(state, QueueLens.ServiceCompleted(5.0, 99))
        @test haskey(state.records, 1)
        @test isempty(state.failed)
        @test state.now == 2.0
        waiting = timeout_fixture(; waiting=true)
        @test !QueueLens.is_stale_event(waiting, QueueLens.JobTimedOut(2.0, 2))
    end

    @testset "active timeout releases worker and resource for the next job" begin
        jobs = [Job(1, 0.0, [QueueLens.ServiceStep(:db, 50.0)]; timeout=2.0),
                Job(2, 1.0, [QueueLens.ServiceStep(:db, 3.0)])]
        result = simulate(jobs, Dict(:db => 1))
        @test result.failed == [JobFailure(1, 0.0, 0.0, 2.0, 1, :timeout)]
        @test result.completed == [JobResult(2, 1.0, 2.0, 5.0, 1.0, 4.0)]
        @test isempty(result.rejected)
        @test result.monitoring.duration == 5.0
        @test result.monitoring.mean_queue_length == 0.2
        @test result.monitoring.worker_utilization == 1.0
        @test result.monitoring.resources[:db].utilization == 1.0
        @test rejection_rate(result) == 0.0
        @test summarize(result).num_completed == 1
    end

    @testset "resource waiters precede new worker starts" begin
        state = failure_fixture([
            Job(1, 0.0, [QueueLens.ServiceStep(:db, 10.0)]; timeout=2.0),
            Job(2, 0.0, [QueueLens.ServiceStep(:db, 3.0)]),
            Job(3, 0.0, [QueueLens.ServiceStep(:db, 1.0)]),
        ], Dict(:db => 1), 2)
        drain_fixture!(state)
        @test [r.id for r in state.results] == [2, 3]
        @test [r.completion_time for r in state.results] == [5.0, 6.0]
        @test state.in_use == state.resources[:db].in_use == 0
        @test isempty(state.resource_waiting[:db])
        @test state.now == 6.0
    end

    @testset "resource waiter timeout does not release another job's DB" begin
        state = timeout_fixture(; waiting=true)
        event = QueueLens.JobTimedOut(2.0, 2)
        @test QueueLens.handle!(state, event) === nothing
        @test state.failed == [JobFailure(2, 0.0, 0.0, 2.0, 1, :timeout)]
        @test state.resources[:db].in_use == 1
        @test state.records[1].held_resource === :db
        @test isempty(state.resource_waiting[:db])
        @test state.in_use == 1
        @test QueueLens.handle!(state, event) === nothing
        @test state.resources[:db].in_use == state.in_use == 1
        QueueLens.observe_state!(state)
        drain_fixture!(state)
        @test only(state.results).id == 1
        @test state.now == 5.0
        @test state.in_use == state.resources[:db].in_use == 0
    end

    @testset "removing a middle waiter preserves FIFO and starts worker work" begin
        jobs = [Job(1, 0.0, [QueueLens.ServiceStep(:db, 10.0)]),
                Job(2, 0.0, [QueueLens.ServiceStep(:db, 1.0)]),
                Job(3, 0.0, [QueueLens.ServiceStep(:db, 1.0)]; timeout=2.0),
                Job(4, 0.0, [QueueLens.ServiceStep(:db, 1.0)]),
                Job(5, 0.0, 1.0)]
        state = failure_fixture(jobs, Dict(:db => 1), 4)
        drain_fixture!(state)
        @test [r.id for r in state.results] == [5, 1, 2, 4]
        @test [r.completion_time for r in state.results] == [3.0, 10.0, 11.0, 12.0]
        @test state.results[1].start_time == 2.0
        @test only(state.failed).id == 3
        @test isempty(state.records)
        @test isempty(state.resource_waiting[:db])
        @test state.in_use == state.resources[:db].in_use == 0
    end

    @testset "deadline starts at worker start, not arrival" begin
        result = simulate([Job(1, 0.0, 5.0), Job(2, 0.0, 1.0; timeout=2.0)], Dict{Symbol,Int}())
        @test isempty(result.failed)
        @test result.completed[2] == JobResult(2, 0.0, 5.0, 6.0, 5.0, 6.0)
        @test result.monitoring.duration == 6.0
    end

    @testset "successful and zero-step jobs leave harmless timeout tails" begin
        for job in (Job(1, 0.0, 1.0; timeout=50.0), Job(1, 0.0; timeout=50.0))
            result = simulate([job], Dict{Symbol,Int}())
            @test isempty(result.failed)
            @test length(result.completed) == 1
            @test result.monitoring.duration == job.service_time
        end
    end

    @testset "whole-job completion exactly at deadline wins, including zero steps" begin
        for steps in ([QueueLens.ServiceStep(nothing, 2.0)],
                      [QueueLens.ServiceStep(:db, 1.0), QueueLens.ServiceStep(nothing, 1.0),
                       QueueLens.ServiceStep(:db, 0.0), QueueLens.ServiceStep(nothing, 0.0)])
            result = simulate([Job(1, 0.0, steps; timeout=2.0)], Dict(:db => 1))
            @test isempty(result.failed)
            @test only(result.completed).completion_time == 2.0
            @test result.monitoring.duration == 2.0
        end
    end

    @testset "resource acquisition at deadline succeeds only for zero remaining work" begin
        for duration in (0.0, 1.0)
            result = simulate([Job(1, 0.0, [QueueLens.ServiceStep(:db, 2.0)]),
                               Job(2, 0.0, [QueueLens.ServiceStep(:db, duration)]; timeout=2.0)],
                              Dict(:db => 1), 2)
            @test length(result.completed) == (duration == 0.0 ? 2 : 1)
            @test length(result.failed) == (duration == 0.0 ? 0 : 1)
            @test result.monitoring.duration == 2.0
        end
    end

    @testset "later resource-free stage does not release old ownership" begin
        result = simulate([
            Job(1, 0.0, [QueueLens.ServiceStep(:db, 1.0), QueueLens.ServiceStep(nothing, 5.0)]; timeout=2.0),
            Job(2, 0.5, [QueueLens.ServiceStep(:db, 3.0)]),
        ], Dict(:db => 1), 2)
        @test only(result.failed).step_index == 2
        @test only(result.completed).completion_time == 4.0
        @test result.monitoring.duration == 4.0
        @test result.monitoring.resources[:db].utilization == 1.0
    end

    @testset "injected failure cancels timeout; old completions remain stale" begin
        result = simulate([Job(1, 0.0, 50.0; timeout=10.0)], Dict{Symbol,Int}();
                          failures=[QueueLens.JobFailed(2.0, 1, 1)])
        @test only(result.failed).reason == :injected
        @test isempty(result.completed)
        @test result.monitoring.duration == 2.0
    end

    @testset "simultaneous timeouts leave no occupied slots" begin
        state = failure_fixture([
            Job(1, 0.0, [QueueLens.ServiceStep(:db, 50.0)]; timeout=2.0),
            Job(2, 0.0, [QueueLens.ServiceStep(:db, 50.0)]; timeout=2.0),
        ], Dict(:db => 1), 2)
        drain_fixture!(state)
        @test length(state.failed) == 2
        @test isempty(state.results)
        @test isempty(state.records)
        @test isempty(state.resource_waiting[:db])
        @test state.in_use == state.resources[:db].in_use == 0
        @test state.now == 2.0
    end

    @testset "direct stale timeout calls and completions are harmless" begin
        state = failure_fixture([Job(1, 0.0, 1.0; timeout=2.0)], Dict{Symbol,Int}())
        drain_fixture!(state)
        @test QueueLens.handle!(state, QueueLens.JobTimedOut(2.0, 1)) === nothing
        @test QueueLens.handle!(state, QueueLens.JobTimedOut(2.0, 99)) === nothing
        @test state.now == 1.0
        @test length(state.results) == 1
        @test isempty(state.failed)
        @test_throws ArgumentError QueueLens.handle!(state, QueueLens.StepCompleted(2.0, 99, 1))
        state = timeout_fixture(; resource=nothing)
        @test QueueLens.handle!(state, QueueLens.JobTimedOut(2.0, 1)) === nothing
        @test QueueLens.handle!(state, QueueLens.StepCompleted(5.0, 1, 1)) === nothing
        @test QueueLens.handle!(state, QueueLens.ServiceCompleted(5.0, 1)) === nothing
        @test state.now == 2.0
        @test isempty(state.results)
        @test state.in_use == 0
    end

    @testset "invalid live timeout is rejected before mutation" begin
        state = timeout_fixture()
        state.now = 1.0
        @test_throws ArgumentError QueueLens.handle!(state, QueueLens.JobTimedOut(1.0, 1))
        @test isempty(state.failed)
        @test state.in_use == state.resources[:db].in_use == 1
        @test haskey(state.records, 1)
    end
end
