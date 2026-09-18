@testset "shared engine helpers" begin
    @testset "empty loop returns an idle report without changing time" begin
        state = QueueLens.SimState(Scenario(Constant(1.0), Constant(1.0), 1, 0),
                                   Dict(:db => 1))
        result = QueueLens.run!(state)
        @test result.completed === state.results
        @test result.rejected === state.rejected
        @test result.failed === state.failed
        @test result.monitoring.duration == 0.0
        @test result.monitoring.worker_utilization == 0.0
        @test state.now == 0.0
    end

    @testset "completed timeout tail does not extend monitoring" begin
        state = failure_fixture([Job(1, 0.0, 1.0; timeout=50.0)], Dict{Symbol,Int}())
        result = QueueLens.run!(state)
        @test only(result.completed).completion_time == 1.0
        @test result.monitoring.duration == 1.0
        @test result.monitoring.worker_utilization == 1.0
        @test state.worker_busy_stat.last_time == 1.0
        @test isempty(state.calendar)
        @test state.in_use == 0
    end

    @testset "release transfers ownership to the oldest resource waiter" begin
        state = timeout_fixture(; waiting=true)
        owner = state.records[1]
        waiter = state.records[2]
        @test QueueLens.release_resource!(state, owner) === nothing
        @test owner.held_resource === nothing
        @test waiter.held_resource === :db
        @test waiter.step_active
        @test state.resources[:db].in_use == 1
        @test state.in_use == 2
        @test isempty(state.resource_waiting[:db])
        count = length(state.calendar)
        @test QueueLens.release_resource!(state, owner) === nothing
        @test length(state.calendar) == count
        @test state.resources[:db].in_use == 1
    end
end
