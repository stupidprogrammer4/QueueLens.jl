@testset "failure scaffolding" begin
    event = QueueLens.JobFailed(2.0, 1, 1)
    @test (event.time, event.job_id, event.step_index, event.reason) == (2.0, 1, 1, :injected)
    @test QueueLens.JobFailed(2.0, 1, 1, :db_error).reason == :db_error
    for time in (-1.0, Inf, -Inf, NaN)
        @test_throws ArgumentError QueueLens.JobFailed(time, 1, 1)
    end
    for step in (0, -1)
        @test_throws ArgumentError QueueLens.JobFailed(2.0, 1, step)
    end

    @testset "ownership follows actual acquisition, not demand" begin
        state = failure_fixture([
            Job(1, 0.0, [QueueLens.ServiceStep(:db, 3.0), QueueLens.ServiceStep(nothing, 2.0)]),
            Job(2, 0.0, [QueueLens.ServiceStep(:db, 3.0)]),
        ], Dict(:db => 1), 2)
        @test !state.records[1].step_active
        @test state.records[1].held_resource === nothing
        for _ in 1:2
            arrival = QueueLens.pop_next!(state)
            state.now = arrival.time
            QueueLens.handle!(state, arrival)
        end
        @test state.records[1].step_active
        @test state.records[1].held_resource === :db
        @test !state.records[2].step_active
        @test state.records[2].held_resource === nothing
        @test state.resource_waiting[:db] == [2]
        stage = QueueLens.pop_next!(state)
        state.now = stage.time
        QueueLens.handle!(state, stage)
        @test state.records[1].step_active
        @test state.records[1].held_resource === nothing
        @test state.records[1].step_index == 2
        @test state.records[2].step_active
        @test state.records[2].held_resource === :db
        @test isempty(state.resource_waiting[:db])
        stage = QueueLens.pop_next!(state)
        state.now = stage.time
        QueueLens.handle!(state, stage)
        @test !state.records[1].step_active
        @test state.records[1].held_resource === nothing
    end

    @testset "failure bookkeeping does not implement release logic" for resource in (nothing, :db)
        state = active_failure_fixture(; resource)
        record = state.records[1]
        calendar_size = length(state.calendar)
        returned = QueueLens.record_failure!(state, event)
        @test returned === record
        @test returned.held_resource === resource
        @test returned.step_active
        @test !haskey(state.records, 1)
        @test state.failed_ids == Set([1])
        @test state.failed == [JobFailure(1, 0.0, 0.0, 2.0, 1, :injected)]
        @test isempty(state.results)
        @test isempty(state.rejected)
        @test state.in_use == 1
        @test length(state.calendar) == calendar_size
        @test state.worker_busy_stat.area == 2.0
        if resource !== nothing
            @test state.resources[resource].in_use == 1
        end
        @test_throws ArgumentError QueueLens.record_failure!(state, event)
        @test length(state.failed) == 1
    end

    @testset "invalid failure leaves bookkeeping unchanged ($kind)" for kind in
        (:unknown, :wrong_time, :wrong_stage, :not_active, :worker_queue,
         :resource_queue, :no_worker, :wrong_owner, :empty_pool, :missing_pool)
        state = active_failure_fixture()
        fault = event
        if kind == :unknown
            fault = QueueLens.JobFailed(2.0, 99, 1)
        elseif kind == :wrong_time
            fault = QueueLens.JobFailed(3.0, 1, 1)
        elseif kind == :wrong_stage
            fault = QueueLens.JobFailed(2.0, 1, 2)
        elseif kind == :not_active
            state.records[1].step_active = false
        elseif kind == :worker_queue
            push!(state.waiting, 1)
        elseif kind == :resource_queue
            push!(state.resource_waiting[:db], 1)
        elseif kind == :no_worker
            state.in_use = 0
        elseif kind == :wrong_owner
            state.records[1].held_resource = nothing
        elseif kind == :empty_pool
            state.resources[:db].in_use = 0
        elseif kind == :missing_pool
            delete!(state.resources, :db)
        end
        record = state.records[1]
        before = (state.in_use, copy(state.waiting), copy(state.resource_waiting[:db]),
                  length(state.calendar), record.step_active, record.held_resource)
        @test_throws ArgumentError QueueLens.record_failure!(state, fault)
        @test state.records[1] === record
        @test isempty(state.failed)
        @test isempty(state.failed_ids)
        @test before == (state.in_use, state.waiting, state.resource_waiting[:db],
                         length(state.calendar), record.step_active, record.held_resource)
    end

    @testset "failure storage and reporting" begin
        a, b = active_failure_fixture(), active_failure_fixture()
        @test a.failed !== b.failed
        @test a.failed_ids !== b.failed_ids
        QueueLens.record_failure!(a, event)
        @test isempty(b.failed)
        @test isempty(b.failed_ids)
        result = SimulationResult(JobResult[], [JobRejection(2, 0.0, 0.0, :queue_full)], nothing, a.failed)
        @test result.failed == a.failed
        @test rejection_rate(result) == 0.5
        @test_throws ArgumentError summarize(result)
        @test occursin("failed: 1", sprint(show, MIME("text/plain"), result))
        first = SimulationResult(JobResult[], JobRejection[])
        second = SimulationResult(JobResult[], JobRejection[])
        @test first.failed !== second.failed
        @test isempty(first.failed)
        @test isempty(simulate([Job(1, 0.0, 1.0)], Dict{Symbol,Int}()).failed)
    end

    @testset "injection configuration is validated before dispatch" begin
        jobs = [Job(1, 1.0, 5.0)]
        for failures in (
            [QueueLens.JobFailed(2.0, 99, 1)],
            [QueueLens.JobFailed(0.0, 1, 1)],
            [QueueLens.JobFailed(2.0, 1, 2)],
            [QueueLens.JobFailed(2.0, 1, 1), QueueLens.JobFailed(3.0, 1, 1)],
        )
            @test_throws ArgumentError simulate(jobs, Dict{Symbol,Int}(); failures)
        end
        result = simulate(jobs, Dict{Symbol,Int}(); failures = QueueLens.JobFailed[])
        @test isempty(result.failed)
        @test result.completed[1].completion_time == 6.0
    end
end
