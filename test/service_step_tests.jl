@testset "service steps" begin

    @testset "steps retain their resource and duration" begin
        for resource in (nothing, :db, :http), duration in (0.0, 0.02, 1.0)
            step = QueueLens.ServiceStep(resource, duration)
            @test step.resource === resource
            @test step.duration === duration
        end
    end

    @testset "negative and non-finite durations are rejected" begin
        for resource in (nothing, :db), duration in (-1.0, Inf, -Inf, NaN)
            @test_throws ArgumentError QueueLens.ServiceStep(resource, duration)
        end
    end

end
