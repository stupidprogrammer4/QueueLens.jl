@testset "admission decision" begin
    scenario = Scenario(Constant(1.0), Constant(3.0), 3, 42)

    @testset "busy=$busy queued=$queued limit=$limit" for (busy, queued, limit, expected) in (
        (0, 0, 0, true),
        (1, 0, 0, true),
        (2, 0, 0, false),
        (2, 0, 1, true),
        (2, 1, 1, false),
        (2, 1, 2, true),
        (2, 2, 2, false),
        (2, 3, 2, false),
        (1, 2, 2, true),
    )
        state = QueueLens.SimState(scenario, Dict{Symbol,Int}(), 2)
        state.in_use = busy
        append!(state.waiting, 1:queued)
        @test QueueLens.can_admit(state, limit) === expected
    end

    @testset "negative capacity is invalid even with free workers" for busy in (0, 2)
        state = QueueLens.SimState(scenario, Dict{Symbol,Int}(), 2)
        state.in_use = busy
        @test_throws ArgumentError QueueLens.can_admit(state, -1)
        @test_throws ArgumentError QueueLens.can_admit(state, typemin(Int))
    end

    @testset "deciding never changes state (limit $limit)" for limit in (-1, 1, 2)
        state = QueueLens.SimState(scenario, Dict(:db => 1), 1)
        state.in_use = 1
        state.now = 2.0
        state.records[7] = QueueLens.JobRecord(Job(7, 0.0, 3.0))
        push!(state.waiting, 7)
        QueueLens.try_acquire!(state.resources[:db])
        QueueLens.schedule!(state, QueueLens.JobArrival(4.0, 8))
        queue = state.waiting

        if limit < 0
            @test_throws ArgumentError QueueLens.can_admit(state, limit)
        else
            @test QueueLens.can_admit(state, limit) === (limit == 2)
        end
        @test state.waiting === queue
        @test state.waiting == [7]
        @test state.in_use == 1
        @test state.capacity == 1
        @test state.now == 2.0
        @test state.records[7].step_index == 1
        @test isnan(state.records[7].start_time)
        @test state.resources[:db].in_use == 1
        @test isempty(state.resource_waiting[:db])
        @test isempty(state.results)
        @test state.next_sequence == 1
        @test state.max_calendar_size == 1
        @test QueueLens.pop_next!(state) == QueueLens.JobArrival(4.0, 8)
        @test isempty(state.calendar)
    end
end

@testset "arrival admission integration" begin
    # Run the real event handlers while checking queue and worker bounds.
    function drain_admission_state!(state)
        while !isempty(state.calendar)
            event = QueueLens.pop_next!(state)
            state.now = event.time
            QueueLens.handle!(state, event)
            @test length(state.waiting) <= state.queue_capacity
            @test 0 <= state.in_use <= state.capacity
        end
        @test state.in_use == 0
        @test isempty(state.waiting)
        @test isempty(state.records)
        return state
    end

    # Explicit arrivals disable lazy generation, matching simulate(jobs, ...).
    function admission_state(jobs; capacity = 1, queue_capacity = 1, resources = Dict{Symbol,Int}())
        scenario = Scenario(Constant(1.0), Constant(3.0), length(jobs), 42)
        state = QueueLens.SimState(scenario, resources, capacity; queue_capacity)
        state.jobs_generated = length(jobs)
        for job in jobs
            state.records[job.id] = QueueLens.JobRecord(job)
            QueueLens.schedule!(state, QueueLens.JobArrival(job.arrival_time, job.id))
        end
        return state
    end

    @testset "one waiting slot matches the hand calculation" begin
        jobs = [Job(i, time, 3.0) for (i, time) in enumerate((0.0, 0.5, 1.0, 3.5))]
        state = drain_admission_state!(admission_state(jobs))
        @test state.results == [
            JobResult(1, 0.0, 0.0, 3.0, 0.0, 3.0),
            JobResult(2, 0.5, 3.0, 6.0, 2.5, 5.5),
            JobResult(4, 3.5, 6.0, 9.0, 2.5, 5.5),
        ]
        @test state.rejected == [QueueLens.JobRejection(3, 1.0, 1.0, :queue_full)]
        @test length(state.results) + length(state.rejected) == length(jobs)
    end

    @testset "zero waiting slots still allow free workers and later arrivals" begin
        jobs = [Job(1, 0.0, 3.0), Job(2, 0.5, 3.0), Job(3, 3.5, 3.0)]
        state = drain_admission_state!(admission_state(jobs; queue_capacity = 0))
        @test state.results == [JobResult(1, 0.0, 0.0, 3.0, 0.0, 3.0),
                               JobResult(3, 3.5, 3.5, 6.5, 0.0, 3.0)]
        @test state.rejected == [QueueLens.JobRejection(2, 0.5, 0.5, :queue_full)]
    end

    @testset "rejection does not stop lazy arrivals" begin
        scenario = Scenario(Constant(0.5), Constant(3.0), 4, 42)
        state = QueueLens.SimState(scenario, Dict{Symbol,Int}(); queue_capacity = 0)
        QueueLens.schedule_next_arrival!(state)
        drain_admission_state!(state)
        @test state.jobs_generated == 4
        @test state.results == [JobResult(1, 0.5, 0.5, 3.5, 0.0, 3.0)]
        @test state.rejected == [QueueLens.JobRejection(i, i * 0.5, i * 0.5, :queue_full) for i in 2:4]
        @test state.max_calendar_size <= state.capacity + 1
    end

    @testset "resource waits occupy workers but not worker queue slots" begin
        jobs = [Job(i, time, [QueueLens.ServiceStep(:db, 2.0)])
                for (i, time) in enumerate((0.0, 0.25, 0.5))]
        state = drain_admission_state!(admission_state(jobs; capacity = 2,
            queue_capacity = 0, resources = Dict(:db => 1)))
        @test state.results == [JobResult(1, 0.0, 0.0, 2.0, 0.0, 2.0),
                               JobResult(2, 0.25, 0.25, 4.0, 0.0, 3.75)]
        @test state.rejected == [QueueLens.JobRejection(3, 0.5, 0.5, :queue_full)]
        @test state.resources[:db].in_use == 0
        @test isempty(state.resource_waiting[:db])
    end
end

@testset "admission bookkeeping" begin
    scenario = Scenario(Constant(1.0), Constant(3.0), 3, 42)

    @testset "queue configuration and rejection storage" begin
        default = QueueLens.SimState(scenario, Dict{Symbol,Int}())
        @test default.queue_capacity == typemax(Int)
        @test isempty(default.rejected)
        for limit in (0, 1, 4)
            state = QueueLens.SimState(scenario, Dict{Symbol,Int}(); queue_capacity = limit)
            @test state.queue_capacity == limit
            @test isempty(state.rejected)
            @test state.rejected !== default.rejected
        end
        @test_throws ArgumentError QueueLens.SimState(scenario, Dict{Symbol,Int}(); queue_capacity = -1)
        rng = Xoshiro(19)
        state = QueueLens.SimState(scenario, Dict(:db => 1), 2, rng; queue_capacity = 3)
        @test state.rng === rng
        @test state.capacity == 2
        @test state.queue_capacity == 3
        @test state.resources[:db].capacity == 1
    end

    @testset "rejection records the outcome without affecting accepted work" begin
        state = QueueLens.SimState(scenario, Dict(:db => 1); queue_capacity = 1)
        state.now = 1.0
        state.in_use = 1
        state.jobs_generated = 3
        state.records[1] = QueueLens.JobRecord(Job(1, 0.0, [QueueLens.ServiceStep(:db, 3.0)]))
        state.records[1].start_time = 0.0
        state.records[2] = QueueLens.JobRecord(Job(2, 0.5, 3.0))
        state.records[3] = QueueLens.JobRecord(Job(3, 1.0, 3.0))
        push!(state.waiting, 2)
        QueueLens.try_acquire!(state.resources[:db])
        QueueLens.schedule!(state, QueueLens.StepCompleted(3.0, 1, 1))

        @test QueueLens.record_rejection!(state, 3) === nothing
        @test state.rejected == [QueueLens.JobRejection(3, 1.0, 1.0, :queue_full)]
        @test !haskey(state.records, 3)
        @test Set(keys(state.records)) == Set([1, 2])
        @test state.waiting == [2]
        @test state.in_use == 1
        @test state.resources[:db].in_use == 1
        @test isempty(state.resource_waiting[:db])
        @test isempty(state.results)
        @test state.now == 1.0
        @test state.jobs_generated == 3
        @test state.next_sequence == 1
        @test state.max_calendar_size == 1
        @test QueueLens.pop_next!(state) == QueueLens.StepCompleted(3.0, 1, 1)
        @test isempty(state.calendar)
        @test_throws ArgumentError QueueLens.record_rejection!(state, 3)
        @test length(state.rejected) == 1
    end

    @testset "invalid rejection is nonmutating ($kind)" for kind in (:unknown, :queued, :started, :future)
        state = QueueLens.SimState(scenario, Dict{Symbol,Int}())
        if kind != :unknown
            state.records[7] = QueueLens.JobRecord(Job(7, kind == :future ? 1.0 : 0.0, 3.0))
        end
        if kind == :queued
            push!(state.waiting, 7)
        elseif kind == :started
            state.records[7].start_time = 0.0
            state.in_use = 1
        end
        @test_throws ArgumentError QueueLens.record_rejection!(state, 7)
        @test isempty(state.rejected)
        @test isempty(state.results)
        @test isempty(state.calendar)
        @test haskey(state.records, 7) == (kind != :unknown)
        @test state.waiting == (kind == :queued ? [7] : Int[])
        @test state.in_use == (kind == :started ? 1 : 0)
    end
end
