# Completed learner contract, included in the default suite and runnable alone.
# Run: julia --project=. test/attempts/attempt_contract_tests.jl
using Test
using QueueLens
if !isdefined(@__MODULE__, :failure_fixture)
    include(joinpath(@__DIR__, "..", "support", "fixtures.jl"))
end
if !isdefined(@__MODULE__, :attempt_fixture)
    include(joinpath(@__DIR__, "..", "support", "attempt_fixtures.jl"))
end

@testset "old-attempt filtering contract (learner exercise)" begin
    @testset "read-only classification with no terminal ids" begin
        state = attempt_fixture()
        @test isempty(state.failed_ids)
        before = attempt_snapshot(state)
        for event in attempt_events(1)
            @test QueueLens.is_stale_event(state, event)
        end
        for attempt_id in (2, 3), event in attempt_events(attempt_id)
            @test !QueueLens.is_stale_event(state, event)
        end
        @test !QueueLens.is_stale_event(state, QueueLens.JobArrival(0.0, 1))
        @test isequal(attempt_snapshot(state), before)
    end

    @testset "direct handlers ignore old attempts before stage validation" begin
        for resource in (nothing, :db), event in attempt_events(1)
            steps = [QueueLens.ServiceStep(nothing, 0.0), QueueLens.ServiceStep(resource, 5.0)]
            state = attempt_fixture(; resource, steps)
            # Advance normally to step 2; the old event still names step 1.
            QueueLens.handle!(state, QueueLens.pop_next!(state))
            QueueLens.observe_state!(state)
            before = attempt_snapshot(state)
            @test QueueLens.handle!(state, event) === nothing
            @test isequal(attempt_snapshot(state), before)
        end
    end

    @testset "old timeout cannot remove a current resource waiter" begin
        state = timeout_fixture(; waiting=true)
        state.records[2].attempt_id = 2
        before = attempt_snapshot(state)
        @test QueueLens.handle!(state, QueueLens.JobTimedOut(2.0, 2; attempt_id=1)) === nothing
        @test isequal(attempt_snapshot(state), before)
    end

    @testset "loop filters before clock and monitoring changes" begin
        for event in attempt_events(1; time=2.0)
            state = attempt_fixture()
            QueueLens.schedule!(state, event)
            result = QueueLens.run!(state)
            @test only(result.completed).completion_time == 5.0
            @test isempty(result.failed)
            @test state.in_use == state.resources[:db].in_use == 0
            @test result.monitoring.duration == 5.0
        end
        for event in attempt_events(1; time=50.0)
            state = attempt_fixture()
            # Isolate clock filtering while the newer attempt remains live.
            empty!(state.calendar)
            QueueLens.schedule!(state, event)
            result = QueueLens.run!(state)
            @test state.now == result.monitoring.duration == 0.0
            @test haskey(state.records, 1)
            @test state.in_use == state.resources[:db].in_use == 1
            @test isempty(result.completed) && isempty(result.failed)
        end
    end

    @testset "absent and terminal job rules remain unchanged" begin
        state = attempt_fixture()
        @test QueueLens.is_stale_event(state, QueueLens.JobTimedOut(2.0, 99; attempt_id=3))
        for event in (QueueLens.StepCompleted(2.0, 99, 1; attempt_id=3),
                      QueueLens.ServiceCompleted(2.0, 99; attempt_id=3),
                      QueueLens.JobFailed(2.0, 99, 1; attempt_id=3))
            @test !QueueLens.is_stale_event(state, event)
            @test_throws ArgumentError QueueLens.handle!(state, event)
        end
        delete!(state.records, 1)
        push!(state.failed_ids, 1)
        for event in attempt_events(1)
            before = attempt_snapshot(state)
            @test QueueLens.handle!(state, event) === nothing
            @test isequal(attempt_snapshot(state), before)
        end
    end
end
