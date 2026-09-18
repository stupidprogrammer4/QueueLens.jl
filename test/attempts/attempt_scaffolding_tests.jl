using Test
using QueueLens
if !isdefined(@__MODULE__, :failure_fixture)
    include(joinpath(@__DIR__, "..", "support", "fixtures.jl"))
end
if !isdefined(@__MODULE__, :attempt_fixture)
    include(joinpath(@__DIR__, "..", "support", "attempt_fixtures.jl"))
end

@testset "attempt identity scaffolding" begin
    @testset "constructors and immutable event snapshots" begin
        job = Job(1, 0.0, 3.0)
        record = QueueLens.JobRecord(job)
        @test record.attempt_id == 1
        @test !hasproperty(job, :attempt_id)
        @test !hasproperty(QueueLens.JobArrival(0.0, 1), :attempt_id)
        defaults = (QueueLens.StepCompleted(3.0, 1, 1),
                    QueueLens.ServiceCompleted(3.0, 1),
                    QueueLens.JobFailed(3.0, 1, 1), QueueLens.JobTimedOut(3.0, 1))
        for event in defaults
            @test event.attempt_id == 1
            @test event isa QueueLens.AttemptEvent
            @test !ismutabletype(typeof(event))
        end
        events = attempt_events(record.attempt_id)
        record.attempt_id = 2
        @test all(event -> event.attempt_id == 1, events)
        @test all(event -> event.attempt_id == 2, attempt_events(2))
        for invalid in (0, -1)
            @test_throws ArgumentError QueueLens.StepCompleted(1.0, 1, 1; attempt_id=invalid)
            @test_throws ArgumentError QueueLens.ServiceCompleted(1.0, 1; attempt_id=invalid)
            @test_throws ArgumentError QueueLens.JobFailed(1.0, 1, 1; attempt_id=invalid)
            @test_throws ArgumentError QueueLens.JobTimedOut(1.0, 1; attempt_id=invalid)
        end
        @test QueueLens.JobFailed(1.0, 1, 1, :network; attempt_id=2).reason === :network
        @test QueueLens.StepCompleted(1, 1, 1).time === 1.0
        @test QueueLens.ServiceCompleted(1, 1).time === 1.0
    end

    @testset "scheduling preserves identity through all stages" begin
        steps = [QueueLens.ServiceStep(:db, 1.0), QueueLens.ServiceStep(nothing, 2.0)]
        state = attempt_fixture(; steps)
        @test Set(typeof(entry.event) for entry in attempt_calendar(state)) ==
              Set([QueueLens.StepCompleted, QueueLens.JobTimedOut])
        @test all(entry -> entry.event.attempt_id == 2, attempt_calendar(state))
        for (time, kind) in ((1.0, QueueLens.StepCompleted), (3.0, QueueLens.StepCompleted),
                             (3.0, QueueLens.ServiceCompleted))
            event = QueueLens.pop_next!(state)
            @test event isa kind
            @test event.time == time
            @test event.attempt_id == state.records[1].attempt_id == 2
            state.now = event.time
            QueueLens.handle!(state, event)
            QueueLens.observe_state!(state)
        end
        result = QueueLens.run!(state)
        @test only(result.completed).completion_time == 3.0
        @test result.monitoring.duration == 3.0
        @test isempty(result.failed)

        empty_job = attempt_fixture(; steps=QueueLens.ServiceStep[])
        event = QueueLens.pop_next!(empty_job)
        @test event isa QueueLens.ServiceCompleted
        @test event.attempt_id == 2
    end

    @testset "resource wake-up preserves the waiting attempt" begin
        state = failure_fixture([Job(1, 0.0, [QueueLens.ServiceStep(:db, 1.0)]),
                                 Job(2, 0.0, [QueueLens.ServiceStep(:db, 2.0)])], Dict(:db => 1), 2)
        state.records[2].attempt_id = 2
        for _ in 1:2
            QueueLens.handle!(state, QueueLens.pop_next!(state))
        end
        @test state.resource_waiting[:db] == [2]
        event = QueueLens.pop_next!(state)
        state.now = event.time
        QueueLens.handle!(state, event)
        completion = only(entry.event for entry in attempt_calendar(state) if entry.event.job_id == 2)
        @test completion isa QueueLens.StepCompleted
        @test completion.attempt_id == 2
        @test state.records[2].attempt_id == 2
        @test isempty(state.resource_waiting[:db])
        @test [r.completion_time for r in QueueLens.run!(state).completed] == [1.0, 3.0]
    end

    @testset "future attempts fail without handler mutation" begin
        for resource in (nothing, :db), event in attempt_events(3)
            state = attempt_fixture(; resource, timeout=2.0)
            state.now = 2.0
            before = attempt_snapshot(state)
            @test !QueueLens.is_stale_event(state, event)
            @test_throws ArgumentError QueueLens.handle!(state, event)
            @test isequal(attempt_snapshot(state), before)
        end
        for (helper, event) in ((QueueLens.record_failure!, QueueLens.JobFailed(2.0, 1, 1; attempt_id=3)),
                                (QueueLens.record_timeout!, QueueLens.JobTimedOut(2.0, 1; attempt_id=3)))
            state = attempt_fixture(; timeout=2.0)
            state.now = 2.0
            before = attempt_snapshot(state)
            @test_throws ArgumentError helper(state, event)
            @test isequal(attempt_snapshot(state), before)
        end
        for event in attempt_events(3)
            state = attempt_fixture()
            QueueLens.schedule!(state, event)
            @test_throws ArgumentError QueueLens.run!(state)
            @test state.now == 0.0
            @test state.records[1].attempt_id == 2
            @test state.in_use == state.resources[:db].in_use == 1
            @test isempty(state.results) && isempty(state.failed)
        end
    end

    @testset "matching-attempt faults and deadlines still terminate" begin
        for event in (QueueLens.JobFailed(2.0, 1, 1; attempt_id=2),
                      QueueLens.JobTimedOut(2.0, 1; attempt_id=2))
            state = attempt_fixture(; timeout=2.0)
            state.now = 2.0
            @test QueueLens.handle!(state, event) === nothing
            @test only(state.failed).id == 1
            @test state.in_use == state.resources[:db].in_use == 0
        end
        @test_throws ArgumentError simulate([Job(1, 0.0, 5.0)], Dict{Symbol,Int}();
            failures=[QueueLens.JobFailed(2.0, 1, 1; attempt_id=2)])
    end
end
