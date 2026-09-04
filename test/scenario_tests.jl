@testset "scenario runs" begin

    @testset "invalid scenarios are rejected" begin
        @test_throws ArgumentError Scenario(Constant(1.0), Constant(1.0), 0, 1)
        @test_throws ArgumentError Scenario(Constant(1.0), Constant(1.0), -5, 1)
    end

    @testset "the same seed reproduces the same run" begin
        s = Scenario(Exponential(0.5), LogNormal(1.1, 0.6), 200, 42)

        @test simulate(s) == simulate(s)
    end

    @testset "different seeds diverge" begin
        a = Scenario(Exponential(0.5), LogNormal(1.1, 0.6), 200, 42)
        b = Scenario(Exponential(0.5), LogNormal(1.1, 0.6), 200, 43)

        @test simulate(a) != simulate(b)
    end

    @testset "every job gets exactly one result" begin
        s = Scenario(Exponential(0.5), LogNormal(1.1, 0.6), 300, 7)
        results = simulate(s)

        @test length(results) == 300
        @test length(unique(r.id for r in results)) == 300
    end

    @testset "result invariants hold under random workloads" begin
        s = Scenario(Exponential(0.8), LogNormal(0.5, 0.9), 500, 11)

        for r in simulate(s)
            @test r.arrival_time <= r.start_time <= r.completion_time
            @test r.waiting_time ≈ r.start_time - r.arrival_time
            @test r.latency ≈ r.completion_time - r.arrival_time
        end
    end

    @testset "constant distributions reproduce a hand-calculated run" begin
        # Gaps of 2.0 against a service time of 3.0: the worker falls 1.0
        # further behind on every job, so waiting times are 0, 1, 2.
        #
        # Deliberately written so it holds whether the first arrival lands at
        # t = 0 or at t = 2.0 — that decision is yours, and this test does not
        # prejudge it.
        s = Scenario(Constant(2.0), Constant(3.0), 3, 1)
        r = simulate(s)

        @test r[2].arrival_time - r[1].arrival_time ≈ 2.0
        @test r[3].arrival_time - r[2].arrival_time ≈ 2.0

        @test [x.waiting_time for x in r] ≈ [0.0, 1.0, 2.0]
        @test [x.latency for x in r] ≈ [3.0, 4.0, 5.0]

        @test all(x -> x.completion_time - x.start_time ≈ 3.0, r)
    end

    @testset "lazy generation keeps the calendar small" begin
        # This is the answer to the prediction question. Drives the loop by
        # hand so that the state stays reachable after the run.
        s = Scenario(Exponential(0.5), Constant(1.0), 500, 3)
        state = QueueLens.SimState(s)

        QueueLens.schedule_next_arrival!(state)
        while !isempty(state.calendar)
            event = QueueLens.pop_next!(state)
            state.now = event.time
            QueueLens.handle!(state, event)
        end

        @test length(state.results) == 500
        @test state.max_calendar_size <= 2
    end

end
