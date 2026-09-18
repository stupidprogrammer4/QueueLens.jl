using TOML, JSON3

@testset "experiment configuration and reports" begin
    cfg = default_configuration()
    cfg["jobs"] = 20
    cfg["replications"] = 2
    @test validate_configuration(cfg) == cfg
    @test validate_configuration(TOML.parse(configuration_toml(cfg))) == cfg
    for (key,value) in (("jobs",0),("workers",-1),("replications",1.5),("warmup_fraction",NaN),("version",true))
        bad = deepcopy(cfg)
        bad[key] = value
        @test_throws ArgumentError validate_configuration(bad)
    end
    bad = deepcopy(cfg)
    bad["steps"][1]["resource"] = "missing"
    @test_throws ArgumentError validate_configuration(bad)
    a = run_experiment(cfg)
    b = run_experiment(cfg)
    @test a["metrics"] == b["metrics"]
    @test a["trace"] == b["trace"]
    @test a["metadata"]["fingerprint"] == b["metadata"]["fingerprint"]
    @test length(a["jobs"]) == 20
    @test a["metrics"]["completed"]["mean"]+a["metrics"]["failed"]["mean"]+a["metrics"]["rejected"]["mean"] == 20
    @test !isempty(JSON3.write(a))
    @test_throws InterruptException run_experiment(cfg;cancelled=()->true)
    sweep = run_sweep(cfg,Dict("workers"=>[1,2],"capacities"=>[1,2],"p99_target"=>100.0,"max_loss"=>1.0))
    @test length(sweep["rows"]) == 4
    @test sweep["recommended_index"] !== nothing
    cfg["replications"] = 1
    sweep = run_sweep(cfg,Dict("workers"=>[1],"capacities"=>[1]))
    @test sweep["recommended_index"] === nothing
    cfg["steps"][2]["failure_probability"] = 1.0
    cfg["retry"]["strategy"] = "none"
    cfg["timeout"] = 0.0
    failed = run_experiment(cfg)
    @test failed["metrics"]["p99"] === nothing
    @test failed["metrics"]["failed"]["mean"] == 20
    @test !isempty(JSON3.write(failed))
    @testset "worker-only and zero-duration workloads" begin
        plain = default_configuration()
        plain["jobs"] = 10
        plain["resources"] = []
        plain["arrivals"]["kind"] = "constant"
        plain["arrivals"]["mean"] = 0.0
        for step in plain["steps"]
            step["resource"] = ""
            step["kind"] = "constant"
            step["mean"] = 0.0
            step["failure_probability"] = 0.0
        end
        report = run_experiment(plain)
        @test report["metrics"]["completed"]["mean"] == 10
        @test report["metrics"]["throughput"] === nothing
        @test report["metrics"]["p99"]["mean"] == 0.0
        @test isempty(report["resources"])
        @test !isempty(JSON3.write(report))
        comparison = run_sweep(plain,Dict("workers"=>[1,2]))
        @test length(comparison["rows"]) == 2
        @test comparison["recommended_index"] == 1
    end
    @testset "trace thinning preserves exact monitoring" begin
        jobs = [Job(i,0.0,0.01) for i in 1:1200]
        traced = simulate(jobs,Dict{Symbol,Int}();trace=true)
        exact = simulate(jobs,Dict{Symbol,Int}())
        @test length(traced.trace) <= 2048
        @test traced.monitoring.mean_queue_length == exact.monitoring.mean_queue_length
        @test traced.monitoring.worker_utilization == exact.monitoring.worker_utilization
        @test first(traced.trace).time == 0.0
        @test last(traced.trace).time == traced.monitoring.duration
        @test last(traced.trace).completed == 1200
    end
end
