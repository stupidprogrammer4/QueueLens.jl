@testset "timeout scaffolding" begin
    @testset "optional whole-job duration" begin
        @test Job(1, 0.0).timeout === nothing
        @test Job(1, 0.0, 2.0).timeout === nothing
        @test Job(1, 0.0; timeout=2).timeout === 2.0
        @test Job(1, 0.0, 3.0; timeout=2).timeout === 2.0
        job = Job(1, 0.0, [QueueLens.ServiceStep(:db, 3.0)]; timeout=2.0)
        record = QueueLens.JobRecord(job)
        @test record.timeout === 2.0
        @test isnan(record.start_time)
        @test record.held_resource === nothing
        for invalid in (0.0, -1.0, Inf, -Inf, NaN)
            @test_throws ArgumentError Job(1, 0.0; timeout=invalid)
            @test_throws ArgumentError Job(1, 0.0, 3.0; timeout=invalid)
        end
        @test QueueLens.JobTimedOut(0.0, 1).time == 0.0
        for invalid in (-1.0, Inf, -Inf, NaN)
            @test_throws ArgumentError QueueLens.JobTimedOut(invalid, 1)
        end
    end

    @testset "calendar defers only equal-time timeouts" begin
        state = QueueLens.SimState(Scenario(Constant(1.0), Constant(1.0), 1, 0),
                                   Dict{Symbol,Int}())
        timeout1 = QueueLens.JobTimedOut(2.0, 1)
        timeout2 = QueueLens.JobTimedOut(2.0, 2)
        ordinary = [QueueLens.JobArrival(2.0, 3), QueueLens.StepCompleted(2.0, 4, 1),
                    QueueLens.ServiceCompleted(2.0, 5), QueueLens.JobFailed(2.0, 6, 1)]
        for event in (timeout1, ordinary[1], timeout2, ordinary[2:end]...)
            QueueLens.schedule!(state, event)
        end
        @test [QueueLens.pop_next!(state) for _ in ordinary] == ordinary
        # A completion created while processing this instant must still beat timeout.
        completion = QueueLens.ServiceCompleted(2.0, 4)
        QueueLens.schedule!(state, completion)
        @test QueueLens.pop_next!(state) === completion
        @test QueueLens.pop_next!(state) === timeout1
        @test QueueLens.pop_next!(state) === timeout2
        QueueLens.schedule!(state, QueueLens.JobArrival(3.0, 9))
        QueueLens.schedule!(state, timeout1)
        @test QueueLens.pop_next!(state) === timeout1
    end

    @testset "schedule once at worker start, never reset between stages" begin
        jobs = [Job(1, 0.0, 3.0),
                Job(2, 0.0, [QueueLens.ServiceStep(nothing, 1.0),
                             QueueLens.ServiceStep(nothing, 4.0)]; timeout=2.0)]
        state = failure_fixture(jobs, Dict{Symbol,Int}())
        while !isempty(state.calendar) && first(state.calendar).time <= 3.0
            event = QueueLens.pop_next!(state)
            state.now = event.time
            QueueLens.handle!(state, event)
        end
        @test state.records[2].start_time == 3.0
        @test first(state.calendar).time == 4.0
        event = QueueLens.pop_next!(state)
        state.now = event.time
        QueueLens.handle!(state, event)
        timeout = QueueLens.pop_next!(state)
        @test timeout isa QueueLens.JobTimedOut
        @test timeout.time == 5.0
        @test timeout.job_id == 2
        @test QueueLens.pop_next!(state) isa QueueLens.StepCompleted
        @test isempty(state.calendar)
    end

    @testset "deadline overflow is rejected before worker mutation" begin
        for (now, limit) in ((floatmax(Float64), floatmax(Float64)), (1.0e20, 1.0))
            job = Job(1, now, 0.0; timeout=limit)
            state = failure_fixture([job], Dict{Symbol,Int}())
            QueueLens.pop_next!(state)
            state.now = now
            push!(state.waiting, 1)
            @test_throws ArgumentError QueueLens.start_next_job!(state)
            @test state.waiting == [1]
            @test state.in_use == 0
            @test isnan(state.records[1].start_time)
            @test isempty(state.calendar)
        end
    end

    @testset "bookkeeping retains ownership and queues for the handler" begin
        for resource in (:db, nothing)
            state = timeout_fixture(; resource)
            record = state.records[1]
            calendar_size = length(state.calendar)
            @test QueueLens.record_timeout!(state, QueueLens.JobTimedOut(2.0, 1)) === record
            @test state.failed == [JobFailure(1, 0.0, 0.0, 2.0, 1, :timeout)]
            @test state.failed_ids == Set([1])
            @test isempty(state.records)
            @test isempty(state.results)
            @test state.in_use == 1
            @test record.held_resource === resource
            @test length(state.calendar) == calendar_size
            if resource !== nothing
                @test state.resources[resource].in_use == 1
            end
        end
        state = timeout_fixture(; waiting=true)
        record = QueueLens.record_timeout!(state, QueueLens.JobTimedOut(2.0, 2))
        @test record.id == 2
        @test !record.step_active
        @test record.held_resource === nothing
        @test state.resource_waiting[:db] == [2]
        @test state.resources[:db].in_use == 1
        @test state.in_use == 2
        @test haskey(state.records, 1)
        @test state.failed[1].reason == :timeout
    end

    @testset "invalid bookkeeping is nonmutating" begin
        for kind in (:unknown, :early, :wrong_clock, :disabled, :not_started,
                     :wrong_stage, :worker_queued, :missing_resource, :wrong_owner,
                     :missing_waiter, :duplicate_waiter)
            waiting = kind in (:missing_waiter, :duplicate_waiter)
            state = timeout_fixture(; waiting)
            id = waiting ? 2 : 1
            event = QueueLens.JobTimedOut(2.0, id)
            if kind == :unknown
                event = QueueLens.JobTimedOut(2.0, 99)
            elseif kind == :early
                state.now = 1.0
                event = QueueLens.JobTimedOut(1.0, id)
            elseif kind == :wrong_clock
                event = QueueLens.JobTimedOut(3.0, id)
            elseif kind == :disabled
                state.records[id].timeout = nothing
            elseif kind == :not_started
                state.records[id].start_time = NaN
            elseif kind == :wrong_stage
                state.records[id].step_index = 2
            elseif kind == :worker_queued
                push!(state.waiting, id)
            elseif kind == :missing_resource
                delete!(state.resources, :db)
            elseif kind == :wrong_owner
                state.records[id].held_resource = nothing
            elseif kind == :missing_waiter
                empty!(state.resource_waiting[:db])
            else
                push!(state.resource_waiting[:db], id)
            end
            busy = state.in_use
            queues = deepcopy(state.resource_waiting)
            @test_throws ArgumentError QueueLens.record_timeout!(state, event)
            @test isempty(state.failed)
            @test isempty(state.failed_ids)
            @test haskey(state.records, id)
            @test state.in_use == busy
            @test state.resource_waiting == queues
        end
    end

    @testset "existing completion classification is preserved" begin
        state = timeout_fixture()
        push!(state.failed_ids, 9)
        @test QueueLens.is_stale_event(state, QueueLens.StepCompleted(5.0, 9, 1))
        @test QueueLens.is_stale_event(state, QueueLens.ServiceCompleted(5.0, 9))
        @test !QueueLens.is_stale_event(state, QueueLens.JobArrival(5.0, 9))
        @test !QueueLens.is_stale_event(state, QueueLens.StepCompleted(5.0, 99, 1))
    end
end
