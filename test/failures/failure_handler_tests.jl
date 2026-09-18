@testset "failure handler" begin
    @testset "free worker starts its first waiting job" begin
        state = failure_fixture([
            Job(1, 0.0, [QueueLens.ServiceStep(:db, 5.0)]),
            Job(2, 1.0, [QueueLens.ServiceStep(:db, 3.0)]),
        ], Dict(:db => 1))
        for _ in 1:2
            event = QueueLens.pop_next!(state)
            state.now = event.time
            QueueLens.handle!(state, event)
        end
        state.now = 2.0
        event = QueueLens.JobFailed(2.0, 1, 1)
        @test QueueLens.handle!(state, event) === nothing
        @test state.failed == [JobFailure(1, 0.0, 0.0, 2.0, 1, :injected)]
        @test state.failed_ids == Set([1])
        @test !haskey(state.records, 1)
        @test isempty(state.results)
        @test isempty(state.rejected)
        @test isempty(state.waiting)
        @test isempty(state.resource_waiting[:db])
        @test state.records[2].start_time == 2.0
        @test state.records[2].step_active
        @test state.records[2].held_resource === :db
        @test state.in_use == state.resources[:db].in_use == 1
        @test state.jobs_generated == 2
        @test length(state.calendar) == 2

        # Repeated failure must not release the slot now owned by job 2.
        before = (state.in_use, state.resources[:db].in_use, length(state.calendar), state.next_sequence)
        @test QueueLens.handle!(state, event) === nothing
        @test before == (state.in_use, state.resources[:db].in_use, length(state.calendar), state.next_sequence)
        @test length(state.failed) == 1
        @test state.now == 2.0
    end

    @testset "resource waiters precede new worker starts" begin
        state = failure_fixture([
            Job(1, 0.0, [QueueLens.ServiceStep(:db, 5.0)]),
            Job(2, 1.0, [QueueLens.ServiceStep(:db, 3.0)]),
            Job(3, 1.5, [QueueLens.ServiceStep(:db, 1.0)]),
        ], Dict(:db => 1), 2)
        for _ in 1:3
            event = QueueLens.pop_next!(state)
            state.now = event.time
            QueueLens.handle!(state, event)
        end
        state.now = 2.0
        @test QueueLens.handle!(state, QueueLens.JobFailed(2.0, 1, 1)) === nothing
        @test state.records[2].step_active
        @test state.records[2].held_resource === :db
        @test state.records[2].start_time == 1.0
        @test state.records[3].start_time == 2.0
        @test !state.records[3].step_active
        @test state.records[3].held_resource === nothing
        @test state.resource_waiting[:db] == [3]
        @test isempty(state.waiting)
        @test state.in_use == 2
        @test state.resources[:db].in_use == 1
    end

    @testset "no waiter and optional resource ($resource)" for resource in (nothing, :db)
        state = active_failure_fixture(; resource)
        @test QueueLens.handle!(state, QueueLens.JobFailed(2.0, 1, 1)) === nothing
        @test state.in_use == 0
        @test isempty(state.records)
        @test length(state.failed) == 1
        @test length(state.calendar) == 1
        if resource !== nothing
            @test state.resources[resource].in_use == 0
        end
    end

    @testset "failure in a resource-free stage preserves another job's DB" begin
        state = failure_fixture([
            Job(1, 0.0, [QueueLens.ServiceStep(:db, 1.0), QueueLens.ServiceStep(nothing, 5.0)]),
            Job(2, 0.5, [QueueLens.ServiceStep(:db, 3.0)]),
        ], Dict(:db => 1), 2)
        for _ in 1:3
            event = QueueLens.pop_next!(state)
            state.now = event.time
            QueueLens.handle!(state, event)
        end
        state.now = 2.0
        @test QueueLens.handle!(state, QueueLens.JobFailed(2.0, 1, 2)) === nothing
        @test state.in_use == 1
        @test state.resources[:db].in_use == 1
        @test state.records[2].held_resource === :db
        @test state.records[2].step_active
        @test state.failed[1].step_index == 2
    end

    @testset "invalid fault has no side effects ($fault)" for fault in (
        QueueLens.JobFailed(2.0, 99, 1), QueueLens.JobFailed(2.0, 1, 2),
        QueueLens.JobFailed(3.0, 1, 1),
    )
        state = active_failure_fixture()
        record = state.records[1]
        @test_throws ArgumentError QueueLens.handle!(state, fault)
        @test state.records[1] === record
        @test state.in_use == state.resources[:db].in_use == 1
        @test isempty(state.failed)
        @test isempty(state.failed_ids)
        @test length(state.calendar) == 1
    end
end
