@testset "resource API" begin
    scenario = Scenario(Constant(1.0), Constant(2.0), 3, 42)
    jobs = [Job(1, 0.0, 2.0)]

    @testset "resource configuration is required" begin
        @test_throws MethodError QueueLens.SimState(scenario)
        @test_throws MethodError simulate(jobs)
        @test_throws MethodError simulate(scenario)
        @test_throws MethodError simulate_repeated(scenario, 2)
    end

    @testset "explicit RNG and resource configuration coexist" begin
        rng = Xoshiro(19)
        state = QueueLens.SimState(scenario, Dict(:db => 2), 3, rng)
        @test state.rng === rng
        @test state.capacity == 3
        @test state.resources[:db].capacity == 2
        @test state.resources[:db].in_use == 0
        @test isempty(state.resource_waiting[:db])
    end

    @testset "resource contention flows through simulate with fresh pools" begin
        staged_jobs = [
            Job(1, 0.0, [QueueLens.ServiceStep(:db, 2.0), QueueLens.ServiceStep(:db, 1.0)]),
            Job(2, 0.0, [QueueLens.ServiceStep(:db, 3.0)]),
        ]
        config = Dict(:db => 1)
        expected = [JobResult(2, 0.0, 0.0, 5.0, 0.0, 5.0),
                    JobResult(1, 0.0, 0.0, 6.0, 0.0, 6.0)]
        @test simulate(staged_jobs, config, 2).completed == expected
        @test simulate(staged_jobs, config, 2).completed == expected
        @test config == Dict(:db => 1)
        @test simulate(staged_jobs, config).completed == simulate(staged_jobs, config, 1).completed
        @test_throws ArgumentError simulate(staged_jobs, Dict{Symbol,Int}(), 2)
    end

    @testset "distinct named pools and resource-free stages" begin
        staged_jobs = [
            Job(1, 0.0, [QueueLens.ServiceStep(nothing, 1.0),
                         QueueLens.ServiceStep(:db, 2.0), QueueLens.ServiceStep(:http, 1.0)]),
            Job(2, 0.0, [QueueLens.ServiceStep(:http, 2.0), QueueLens.ServiceStep(:db, 1.0)]),
        ]
        @test simulate(staged_jobs, Dict(:db => 1, :http => 1), 2).completed == [
            JobResult(2, 0.0, 0.0, 4.0, 0.0, 4.0),
            JobResult(1, 0.0, 0.0, 4.0, 0.0, 4.0),
        ]
    end

    @testset "invalid resource capacity reaches every entry point ($capacity)" for capacity in (0, -1)
        config = Dict(:db => capacity)
        @test_throws ArgumentError simulate(jobs, config)
        @test_throws ArgumentError simulate(Job[], config)
        @test_throws ArgumentError simulate(scenario, config)
        @test_throws ArgumentError simulate_repeated(scenario, config, 2)
        @test config == Dict(:db => capacity)
    end

    @testset "repeated runs forward configuration without mutating it" begin
        config = Dict(:db => 2)
        configured = simulate_repeated(scenario, config, 3, 2; warmup_fraction = 1 / 3)
        baseline = simulate_repeated(scenario, Dict{Symbol,Int}(), 3, 2; warmup_fraction = 1 / 3)
        for field in fieldnames(RepeatedSummary)
            if field in (:resource_mean_queue_length, :resource_utilization)
                @test isempty(getfield(baseline, field))
                @test getfield(configured, field) == Dict(:db => Estimate(0.0, 0.0, 3))
            else
                @test getfield(configured, field) == getfield(baseline, field)
            end
        end
        @test config == Dict(:db => 2)
    end
end
