@testset "worker capacity" begin

    @testset "state defaults and explicit RNG" begin
        scenario = Scenario(Constant(1.0), Constant(3.0), 3, 42)
        state = QueueLens.SimState(scenario)
        @test state.capacity == 1
        @test state.in_use == 0

        rng = Xoshiro(7)
        state = QueueLens.SimState(scenario, 2, rng)
        @test state.capacity == 2
        @test state.in_use == 0
        @test state.rng === rng
        @test state isa QueueLens.SimState{typeof(rng)}
    end

    @testset "capacity must be positive" begin
        jobs = [Job(1, 0.0, 1.0)]
        scenario = Scenario(Constant(1.0), Constant(1.0), 1, 42)
        for capacity in (0, -1)
            @test_throws ArgumentError QueueLens.SimState(scenario, capacity)
            @test_throws ArgumentError simulate(jobs, capacity)
            @test_throws ArgumentError simulate(scenario, capacity)
        end
    end

    @testset "two workers match the hand-calculated table" begin
        jobs = [Job(1, 0.0, 3.0), Job(2, 1.0, 3.0), Job(3, 2.0, 3.0)]
        @test simulate(jobs) == simulate(jobs, 1)
        @test simulate(jobs, 2) == [
            JobResult(1, 0.0, 0.0, 3.0, 0.0, 3.0),
            JobResult(2, 1.0, 1.0, 4.0, 0.0, 3.0),
            JobResult(3, 2.0, 3.0, 6.0, 1.0, 4.0),
        ]
    end

    @testset "FIFO starts allow completions out of arrival order" begin
        # Job 1 occupies one worker until time 5; the other serves jobs 2-4.
        jobs = [Job(1, 0.0, 5.0), Job(2, 0.0, 1.0),
                Job(3, 0.0, 2.0), Job(4, 0.0, 1.0)]
        @test simulate(jobs, 2) == [
            JobResult(2, 0.0, 0.0, 1.0, 0.0, 1.0),
            JobResult(3, 0.0, 1.0, 3.0, 1.0, 3.0),
            JobResult(4, 0.0, 3.0, 4.0, 3.0, 4.0),
            JobResult(1, 0.0, 0.0, 5.0, 0.0, 5.0),
        ]
    end

    @testset "simultaneous completions refill all freed slots" begin
        jobs = [Job(i, 0.0, 2.0) for i in 1:6]
        results = simulate(jobs, 2)
        @test [r.id for r in results] == collect(1:6)
        @test [r.start_time for r in results] == [0.0, 0.0, 2.0, 2.0, 4.0, 4.0]
        @test [r.completion_time for r in results] == [2.0, 2.0, 4.0, 4.0, 6.0, 6.0]
        @test simulate(jobs, 2) == results

        @test all(r -> r.waiting_time == 0.0, simulate(jobs, 8))
    end

    @testset "zero-duration jobs drain at the same timestamp" begin
        jobs = [Job(i, 0.0, 0.0) for i in 1:5]
        @test simulate(jobs, 2) == [JobResult(i, 0.0, 0.0, 0.0, 0.0, 0.0) for i in 1:5]
    end

    @testset "scenario runs forward capacity" begin
        scenario = Scenario(Constant(1.0), Constant(3.0), 3, 42)
        @test simulate(scenario) == simulate(scenario, 1)
        @test simulate(scenario, 2) == [
            JobResult(1, 1.0, 1.0, 4.0, 0.0, 3.0),
            JobResult(2, 2.0, 2.0, 5.0, 0.0, 3.0),
            JobResult(3, 3.0, 4.0, 7.0, 1.0, 4.0),
        ]

        random_scenario = Scenario(Exponential(10.0), LogNormal(-0.5, 1.0), 50, 42)
        @test simulate(random_scenario, 3) == simulate(random_scenario, 3)
    end

    @testset "resource and calendar invariants after every event" begin
        scenario = Scenario(Exponential(10.0), LogNormal(-0.5, 1.0), 50, 42)
        for capacity in (1, 2, 4)
            state = QueueLens.SimState(scenario, capacity)
            QueueLens.schedule_next_arrival!(state)
            while !isempty(state.calendar)
                event = QueueLens.pop_next!(state)
                @test event.time >= state.now
                state.now = event.time
                QueueLens.handle!(state, event)
                @test 0 <= state.in_use <= capacity
                @test state.in_use == count(r -> !isnan(r.start_time), values(state.records))
                # Waiting work must never coexist with an idle service slot.
                @test isempty(state.waiting) || state.in_use == capacity
            end
            @test state.in_use == 0
            @test isempty(state.records)
            @test isempty(state.waiting)
            @test length(state.results) == scenario.num_jobs
            @test length(unique(r.id for r in state.results)) == scenario.num_jobs
            @test state.max_calendar_size <= capacity + 1
        end
    end

end
