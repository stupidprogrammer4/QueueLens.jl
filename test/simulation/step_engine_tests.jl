@testset "step engine" begin

    # Isolate stage handling with job 7 already holding a worker at virtual time 5.
    function active_step_state(steps; step_index = 1)
        scenario = Scenario(Constant(1.0), Constant(1.0), 1, 42)
        state = QueueLens.SimState(scenario, Dict{Symbol,Int}(), 2)
        state.now = 5.0
        state.in_use = 1
        state.jobs_generated = 1
        record = QueueLens.JobRecord(Job(7, 0.0, steps))
        record.start_time = 1.0
        record.step_index = step_index
        state.records[7] = record
        return state
    end

    @testset "schedule the current step without advancing job or worker state" begin
        steps = [QueueLens.ServiceStep(nothing, 7.0), QueueLens.ServiceStep(nothing, 0.5)]
        state = active_step_state(steps; step_index = 2)
        QueueLens.start_current_step!(state, 7)

        @test QueueLens.pop_next!(state) == QueueLens.StepCompleted(5.5, 7, 2)
        @test isempty(state.calendar)
        @test state.now == 5.0
        @test state.in_use == 1
        @test state.records[7].start_time == 1.0
        @test state.records[7].step_index == 2
        @test isempty(state.results)
    end

    @testset "zero-duration steps complete at the current time" begin
        state = active_step_state([QueueLens.ServiceStep(nothing, 0.0)])
        QueueLens.start_current_step!(state, 7)

        @test QueueLens.pop_next!(state) == QueueLens.StepCompleted(5.0, 7, 1)
        @test isempty(state.calendar)
    end

    @testset "no remaining steps (step count $n)" for n in (0, 1)
        steps = [QueueLens.ServiceStep(nothing, 1.0) for _ in 1:n]
        state = active_step_state(steps; step_index = n + 1)
        QueueLens.start_current_step!(state, 7)

        @test QueueLens.pop_next!(state) == QueueLens.ServiceCompleted(5.0, 7)
        @test isempty(state.calendar)
        # Final bookkeeping belongs to the ServiceCompleted handler.
        @test state.in_use == 1
        @test state.records[7].start_time == 1.0
        @test state.records[7].step_index == n + 1
        @test isempty(state.results)
    end

    @testset "unregistered resource steps leave the run unchanged" begin
        state = active_step_state([QueueLens.ServiceStep(:db, 1.0)])
        @test_throws ArgumentError QueueLens.start_current_step!(state, 7)
        @test isempty(state.calendar)
        @test state.now == 5.0
        @test state.in_use == 1
        @test state.records[7].start_time == 1.0
        @test state.records[7].step_index == 1
        @test isempty(state.results)
    end

    @testset "available resource schedules exactly one completion (duration $duration)" for duration in (0.0, 1.5)
        state = active_step_state([QueueLens.ServiceStep(:db, duration)])
        QueueLens.register_resource!(state, :db, 1)

        @test QueueLens.start_current_step!(state, 7) === nothing
        @test state.resources[:db].in_use == 1
        @test isempty(state.resource_waiting[:db])
        @test QueueLens.pop_next!(state) == QueueLens.StepCompleted(5.0 + duration, 7, 1)
        @test isempty(state.calendar)
        @test state.now == 5.0
        @test state.in_use == 1
        @test state.records[7].start_time == 1.0
        @test state.records[7].step_index == 1
        @test isempty(state.results)
    end

    @testset "full resource queues the job without scheduling completion" begin
        state = active_step_state([QueueLens.ServiceStep(:db, 1.5)])
        QueueLens.register_resource!(state, :db, 1)
        QueueLens.try_acquire!(state.resources[:db])
        push!(state.resource_waiting[:db], 3)

        @test QueueLens.start_current_step!(state, 7) === nothing
        @test state.resources[:db].in_use == 1
        @test state.resource_waiting[:db] == [3, 7]
        @test isempty(state.calendar)
        @test isempty(state.waiting)
        @test state.now == 5.0
        @test state.in_use == 1
        @test state.records[7].start_time == 1.0
        @test state.records[7].step_index == 1
        @test isempty(state.results)
    end

    @testset "resource completion releases the pool before a resource-free step" begin
        state = active_step_state([QueueLens.ServiceStep(:db, 2.0),
                                   QueueLens.ServiceStep(nothing, 1.0)])
        QueueLens.register_resource!(state, :db, 1)
        QueueLens.start_current_step!(state, 7)
        event = QueueLens.pop_next!(state)
        state.now = event.time
        QueueLens.handle!(state, event)

        @test state.resources[:db].in_use == 0
        @test isempty(state.resource_waiting[:db])
        @test state.records[7].step_index == 2
        @test state.records[7].start_time == 1.0
        @test state.in_use == 1
        @test isempty(state.results)
        @test QueueLens.pop_next!(state) == QueueLens.StepCompleted(8.0, 7, 2)
        @test isempty(state.calendar)
    end

    @testset "queued job gets the resource before the completing job's next step" begin
        state = active_step_state([QueueLens.ServiceStep(:db, 2.0),
                                   QueueLens.ServiceStep(:db, 1.0)])
        QueueLens.register_resource!(state, :db, 1)
        second = QueueLens.JobRecord(Job(8, 0.0, [QueueLens.ServiceStep(:db, 3.0)]))
        second.start_time = 5.0
        state.records[8] = second
        state.in_use = 2
        QueueLens.start_current_step!(state, 7)
        QueueLens.start_current_step!(state, 8)
        @test state.resource_waiting[:db] == [8]

        event = QueueLens.pop_next!(state)
        @test event == QueueLens.StepCompleted(7.0, 7, 1)
        state.now = event.time
        QueueLens.handle!(state, event)
        @test state.resource_waiting[:db] == [7]
        @test state.resources[:db].in_use == 1
        @test state.in_use == 2
        @test state.records[7].step_index == 2
        @test second.step_index == 1
        @test second.start_time == 5.0

        event = QueueLens.pop_next!(state)
        @test event == QueueLens.StepCompleted(10.0, 8, 1)
        state.now = event.time
        QueueLens.handle!(state, event)
        @test isempty(state.resource_waiting[:db])
        @test state.resources[:db].in_use == 1
        @test state.in_use == 2

        for expected in (QueueLens.ServiceCompleted(10.0, 8),
                         QueueLens.StepCompleted(11.0, 7, 2),
                         QueueLens.ServiceCompleted(11.0, 7))
            event = QueueLens.pop_next!(state)
            @test event == expected
            state.now = event.time
            QueueLens.handle!(state, event)
        end
        @test state.resources[:db].in_use == 0
        @test state.in_use == 0
        @test isempty(state.records)
        @test isempty(state.calendar)
        @test state.results == [JobResult(8, 0.0, 5.0, 10.0, 5.0, 10.0),
                                JobResult(7, 0.0, 1.0, 11.0, 1.0, 11.0)]
    end

    @testset "invalid resource completion preserves the current step (registered $registered)" for registered in (false, true)
        state = active_step_state([QueueLens.ServiceStep(:db, 1.0)])
        if registered
            QueueLens.register_resource!(state, :db, 1)
        end
        @test_throws ArgumentError QueueLens.handle!(state, QueueLens.StepCompleted(5.0, 7, 1))
        @test state.records[7].step_index == 1
        @test state.records[7].start_time == 1.0
        @test state.in_use == 1
        @test isempty(state.calendar)
        @test isempty(state.results)
        if registered
            @test state.resources[:db].in_use == 0
            @test isempty(state.resource_waiting[:db])
        end
    end

    @testset "a worker is retained until the whole job completes" begin
        state = active_step_state([QueueLens.ServiceStep(nothing, 4.0),
                                   QueueLens.ServiceStep(nothing, 0.5)])
        QueueLens.handle!(state, QueueLens.StepCompleted(5.0, 7, 1))
        @test state.records[7].step_index == 2
        @test state.records[7].start_time == 1.0
        @test state.in_use == 1
        @test isempty(state.results)

        event = QueueLens.pop_next!(state)
        @test event == QueueLens.StepCompleted(5.5, 7, 2)
        state.now = event.time
        QueueLens.handle!(state, event)
        @test state.records[7].step_index == 3
        @test state.in_use == 1
        @test isempty(state.results)

        event = QueueLens.pop_next!(state)
        @test event == QueueLens.ServiceCompleted(5.5, 7)
        QueueLens.handle!(state, event)
        @test state.in_use == 0
        @test isempty(state.records)
        @test isempty(state.calendar)
        @test state.results == [JobResult(7, 0.0, 1.0, 5.5, 1.0, 5.5)]
    end

    @testset "unknown jobs and mismatched steps are rejected before mutation" begin
        state = active_step_state([QueueLens.ServiceStep(nothing, 4.0),
                                   QueueLens.ServiceStep(nothing, 0.5),
                                   QueueLens.ServiceStep(nothing, 0.25)]; step_index = 2)
        @test_throws ArgumentError QueueLens.handle!(state, QueueLens.StepCompleted(5.0, 999, 2))
        @test_throws ArgumentError QueueLens.handle!(state, QueueLens.StepCompleted(5.0, 7, 1))
        @test_throws ArgumentError QueueLens.handle!(state, QueueLens.StepCompleted(5.0, 7, 3))
        @test state.records[7].step_index == 2
        @test state.in_use == 1
        @test state.records[7].start_time == 1.0
        @test isempty(state.calendar)
        @test isempty(state.results)
    end

    @testset "matching but invalid step index $index for $n steps" for (n, index) in ((1, 0), (1, 2), (0, 1))
        steps = [QueueLens.ServiceStep(nothing, 1.0) for _ in 1:n]
        state = active_step_state(steps; step_index = index)
        @test_throws ArgumentError QueueLens.handle!(state, QueueLens.StepCompleted(5.0, 7, index))
        @test state.records[7].step_index == index
        @test state.in_use == 1
        @test state.records[7].start_time == 1.0
        @test isempty(state.calendar)
        @test isempty(state.results)
    end

    @testset "starting a job schedules only its first stage" begin
        state = active_step_state([QueueLens.ServiceStep(nothing, 2.0),
                                   QueueLens.ServiceStep(nothing, 1.0)])
        state.in_use = 0
        state.records[7].start_time = NaN
        push!(state.waiting, 7)
        QueueLens.start_next_job!(state)

        @test state.in_use == 1
        @test state.records[7].start_time == 5.0
        @test QueueLens.pop_next!(state) == QueueLens.StepCompleted(7.0, 7, 1)
        @test isempty(state.calendar)
    end

    @testset "multi-stage jobs keep queued jobs waiting until final completion" begin
        jobs = [Job(1, 0.0, [QueueLens.ServiceStep(nothing, 2.0),
                             QueueLens.ServiceStep(nothing, 1.0)]),
                Job(2, 1.0, 1.0)]
        @test simulate(jobs, Dict{Symbol,Int}()).completed == [JobResult(1, 0.0, 0.0, 3.0, 0.0, 3.0),
                                 JobResult(2, 1.0, 3.0, 4.0, 2.0, 3.0)]
    end

    @testset "empty and zero-duration stages finish exactly once" begin
        jobs = [Job(1, 0.0),
                Job(2, 0.0, [QueueLens.ServiceStep(nothing, 0.0)]),
                Job(3, 0.0, [QueueLens.ServiceStep(nothing, 0.0),
                             QueueLens.ServiceStep(nothing, 1.0)])]
        @test simulate(jobs, Dict{Symbol,Int}(), 2).completed == [JobResult(1, 0.0, 0.0, 0.0, 0.0, 0.0),
                                   JobResult(2, 0.0, 0.0, 0.0, 0.0, 0.0),
                                   JobResult(3, 0.0, 0.0, 1.0, 0.0, 1.0)]
    end

end
