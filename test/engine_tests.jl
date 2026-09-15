@testset "engine" begin

    @testset "three jobs, one worker, FIFO" begin
        # Hand-calculated reference case:
        #   arrivals at 0, 1, 2 with a service time of 3 on a single worker.
        jobs = [Job(1, 0.0, 3.0), Job(2, 1.0, 3.0), Job(3, 2.0, 3.0)]
        results = simulate(jobs)

        @test length(results) == 3

        @test results[1] == JobResult(1, 0.0, 0.0, 3.0, 0.0, 3.0)
        @test results[2] == JobResult(2, 1.0, 3.0, 6.0, 2.0, 5.0)
        @test results[3] == JobResult(3, 2.0, 6.0, 9.0, 4.0, 7.0)
    end

    @testset "arrival order does not depend on input order" begin
        shuffled = [Job(3, 2.0, 3.0), Job(1, 0.0, 3.0), Job(2, 1.0, 3.0)]
        results = simulate(shuffled)

        @test [r.id for r in results] == [1, 2, 3]
    end

    @testset "identical inputs produce identical results" begin
        jobs = [Job(i, Float64(i), 3.0) for i in 1:5]

        @test simulate(jobs) == simulate(jobs)
    end

    @testset "an idle worker starts a job immediately" begin
        # Arrivals spaced further apart than the service time: nobody ever waits.
        jobs = [Job(1, 0.0, 3.0), Job(2, 10.0, 3.0), Job(3, 20.0, 3.0)]
        results = simulate(jobs)

        @test all(r -> r.waiting_time == 0.0, results)
        @test all(r -> r.start_time == r.arrival_time, results)
    end

    @testset "per-job service times are honoured" begin
        # Hand-calculated: arrivals at 0, 1, 2 with service times 3, 1, 4.
        #   j1: start 0, completes 3
        #   j2: waits until 3, completes 4
        #   j3: waits until 4, completes 8
        jobs = [Job(1, 0.0, 3.0), Job(2, 1.0, 1.0), Job(3, 2.0, 4.0)]
        results = simulate(jobs)

        @test results[1] == JobResult(1, 0.0, 0.0, 3.0, 0.0, 3.0)
        @test results[2] == JobResult(2, 1.0, 3.0, 4.0, 2.0, 3.0)
        @test results[3] == JobResult(3, 2.0, 4.0, 8.0, 2.0, 6.0)
    end

    @testset "virtual clock is monotonic" begin
        jobs = [Job(1, 0.0, 3.0), Job(2, 1.0, 3.0), Job(3, 2.0, 3.0)]

        # Rebuild the state the same way simulate does so the log is reachable.
        # This test populates clock_log; simulate itself does not record it.
        scenario = Scenario(Constant(0.0), Constant(0.0), length(jobs), 0)
        state = QueueLens.SimState(scenario)
        state.jobs_generated = length(jobs)   # no lazy generation on this path
        for job in jobs
            QueueLens.schedule!(state, QueueLens.JobArrival(job.arrival_time, job.id))
            state.records[job.id] = QueueLens.JobRecord(job)
        end
        while !isempty(state.calendar)
            event = QueueLens.pop_next!(state)
            state.now = event.time
            push!(state.clock_log, state.now)
            QueueLens.handle!(state, event)
        end

        @test issorted(state.clock_log)
    end

    @testset "result invariants hold for every job" begin
        jobs = [Job(i, Float64(i), 3.0) for i in 1:20]
        results = simulate(jobs)

        @test length(results) == 20
        for r in results
            @test r.arrival_time <= r.start_time <= r.completion_time
            @test r.waiting_time ≈ r.start_time - r.arrival_time
            @test r.latency ≈ r.completion_time - r.arrival_time
        end
    end

end
