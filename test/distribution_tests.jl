@testset "distributions" begin

    # Compute the sample mean directly for the distribution checks.
    sample_mean(xs) = sum(xs) / length(xs)

    draws(d, seed, n) = (rng = Xoshiro(seed); [sample(rng, d) for _ in 1:n])

    @testset "the same seed reproduces the same samples" begin
        d = Exponential(2.0)

        @test draws(d, 42, 100) == draws(d, 42, 100)
    end

    @testset "different seeds diverge" begin
        d = Exponential(2.0)

        @test draws(d, 42, 100) != draws(d, 43, 100)
    end

    @testset "invalid parameters are rejected" begin
        @test_throws ArgumentError Constant(-1.0)
        @test_throws ArgumentError Exponential(0.0)
        @test_throws ArgumentError Exponential(-1.0)
        @test_throws ArgumentError LogNormal(4.0, 0.0)
        @test_throws ArgumentError LogNormal(4.0, -1.0)

        # mu is the parameter in log space, so a negative mu is legitimate.
        @test LogNormal(-2.0, 0.6) isa LogNormal
    end

    @testset "Constant always returns its value" begin
        d = Constant(3.0)
        rng = Xoshiro(1)

        @test all(sample(rng, d) == 3.0 for _ in 1:100)
    end

    @testset "durations are never negative" begin
        rng = Xoshiro(7)

        for d in (Constant(0.0), Exponential(2.0), LogNormal(4.0, 0.6))
            @test all(sample(rng, d) >= 0.0 for _ in 1:1000)
        end
    end

    @testset "Exponential sample mean matches 1 / rate" begin
        @test sample_mean(draws(Exponential(2.0), 11, 200_000)) ≈ 0.5 rtol = 0.02
        @test sample_mean(draws(Exponential(0.25), 12, 200_000)) ≈ 4.0 rtol = 0.02
    end

    @testset "sampling n at once matches sampling n times" begin
        d = LogNormal(1.1, 0.6)

        many = sample(Xoshiro(21), d, 50)
        one_at_a_time = (rng = Xoshiro(21); [sample(rng, d) for _ in 1:50])

        @test length(many) == 50
        @test many == one_at_a_time
    end

    @testset "LogNormal sample mean matches exp(mu + sigma^2 / 2)" begin
        # NOT exp(mu) — that is the trap. With sigma = 0.6 the two differ by
        # about 20%, so a wrong formula here still looks plausible.
        mu, sigma = 4.0, 0.6
        expected = exp(mu + sigma^2 / 2)

        @test sample_mean(draws(LogNormal(mu, sigma), 13, 200_000)) ≈ expected rtol = 0.02
    end

end
