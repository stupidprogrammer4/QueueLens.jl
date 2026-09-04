# The calendar is the foundation of the engine: if events do not come out in
# time order, every result above it is meaningless. Test it in isolation.

@testset "event calendar" begin

    # The calendar does not depend on the scenario; any valid one will do.
    calendar_state() = QueueLens.SimState(Scenario(Constant(1.0), Constant(1.0), 1, 0))

    @testset "events come out in time order regardless of insertion order" begin
        state = calendar_state()

        QueueLens.schedule!(state, QueueLens.JobArrival(5.0, 3))
        QueueLens.schedule!(state, QueueLens.JobArrival(1.0, 1))
        QueueLens.schedule!(state, QueueLens.JobArrival(3.0, 2))

        @test QueueLens.pop_next!(state).time == 1.0
        @test QueueLens.pop_next!(state).time == 3.0
        @test QueueLens.pop_next!(state).time == 5.0
        @test isempty(state.calendar)
    end

    @testset "mixed event types are ordered by time, not by type" begin
        state = calendar_state()

        QueueLens.schedule!(state, QueueLens.ServiceCompleted(4.0, 1))
        QueueLens.schedule!(state, QueueLens.JobArrival(2.0, 2))

        @test QueueLens.pop_next!(state) isa QueueLens.JobArrival
        @test QueueLens.pop_next!(state) isa QueueLens.ServiceCompleted
    end

    @testset "scheduling into the past is rejected" begin
        state = calendar_state()
        state.now = 10.0

        @test_throws Exception QueueLens.schedule!(state, QueueLens.JobArrival(9.0, 1))
    end

    @testset "equal timestamps resolve deterministically" begin
        # Whatever tie-breaking rule you chose, it must be stable: building the
        # same calendar twice must produce the same output order every time.
        build() = begin
            state = calendar_state()
            QueueLens.schedule!(state, QueueLens.ServiceCompleted(3.0, 1))
            QueueLens.schedule!(state, QueueLens.JobArrival(3.0, 2))
            QueueLens.schedule!(state, QueueLens.JobArrival(3.0, 3))
            [QueueLens.pop_next!(state) for _ in 1:3]
        end

        @test build() == build()
    end

end
