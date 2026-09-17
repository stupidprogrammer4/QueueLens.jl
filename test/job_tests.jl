@testset "job construction" begin

    @testset "empty steps have zero service demand" begin
        @test Job(1, 0.0).service_time === 0.0
        @test Job(1, 0.0, QueueLens.ServiceStep[]).service_time === 0.0
    end

    @testset "jobs retain ordered steps and their total service demand" begin
        steps = [QueueLens.ServiceStep(nothing, 0.25),
                 QueueLens.ServiceStep(:http, 0.5),
                 QueueLens.ServiceStep(:db, 0.25)]
        job = Job(7, 2.0, steps)
        @test job.id == 7
        @test job.arrival_time == 2.0
        @test job.steps == steps
        @test job.service_time == 1.0
    end

    @testset "legacy service times become one resource-free step" begin
        for duration in (0.0, 3.0)
            job = Job(1, 0.0, duration)
            @test job.service_time == duration
            @test length(job.steps) == 1
            @test job.steps[1].resource === nothing
            @test job.steps[1].duration == duration
        end
    end

    @testset "arrival times must be finite and nonnegative" begin
        for arrival in (-1.0, Inf, -Inf, NaN)
            @test_throws ArgumentError Job(1, arrival, [QueueLens.ServiceStep(nothing, 1.0)])
            @test_throws ArgumentError Job(1, arrival, 1.0)
        end
    end

    @testset "legacy durations follow the service-step contract" begin
        for duration in (-1.0, Inf, -Inf, NaN)
            @test_throws ArgumentError Job(1, 0.0, duration)
        end
    end

    @testset "total service demand must remain finite" begin
        # Individually finite steps can overflow when their durations are added.
        steps = [QueueLens.ServiceStep(nothing, floatmax(Float64)),
                 QueueLens.ServiceStep(:db, floatmax(Float64))]
        @test_throws ArgumentError Job(1, 0.0, steps)
    end

    @testset "records retain the job and begin at the first step" begin
        steps = [QueueLens.ServiceStep(nothing, 0.25), QueueLens.ServiceStep(:db, 0.75)]
        record = QueueLens.JobRecord(Job(7, 2.0, steps))
        @test record.id == 7
        @test record.arrival_time == 2.0
        @test record.service_time == 1.0
        @test isnan(record.start_time)
        @test record.steps == steps
        @test record.step_index == 1
    end

    @testset "an empty job record has no pending steps" begin
        record = QueueLens.JobRecord(Job(1, 0.0))
        @test isempty(record.steps)
        @test record.step_index == 1
        @test record.step_index > length(record.steps)
    end

    @testset "legacy jobs retain their single step in the record" begin
        record = QueueLens.JobRecord(Job(1, 0.0, 3.0))
        @test record.steps == [QueueLens.ServiceStep(nothing, 3.0)]
        @test record.step_index == 1
    end

end
