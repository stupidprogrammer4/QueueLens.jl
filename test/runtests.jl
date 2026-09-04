using Test
using QueueLens

@testset "QueueLens.jl" begin

    @testset "three jobs, one worker, FIFO" begin
        # Hand-calculated reference case:
        #   arrivals at 0, 1, 2 with a service time of 3 on a single worker.
        jobs = [
            QueueLens.Job(1, 0.0),
            QueueLens.Job(2, 1.0),
            QueueLens.Job(3, 2.0),
        ]
        results = QueueLens.process_jobs(jobs, 3.0)

        @test length(results) == 3

        @test results[1] == QueueLens.JobResult(1, 0.0, 3.0, 0.0, 3.0)
        @test results[2] == QueueLens.JobResult(2, 1.0, 6.0, 2.0, 5.0)
        @test results[3] == QueueLens.JobResult(3, 2.0, 9.0, 4.0, 7.0)
    end

    @testset "arrival order does not depend on input order" begin
        shuffled = [
            QueueLens.Job(3, 2.0),
            QueueLens.Job(1, 0.0),
            QueueLens.Job(2, 1.0),
        ]
        results = QueueLens.process_jobs(shuffled, 3.0)

        @test [r.id for r in results] == [1, 2, 3]
    end

    @testset "identical inputs produce identical results" begin
        jobs = [QueueLens.Job(i, Float64(i)) for i in 1:5]

        @test QueueLens.process_jobs(jobs, 3.0) == QueueLens.process_jobs(jobs, 3.0)
    end

end
