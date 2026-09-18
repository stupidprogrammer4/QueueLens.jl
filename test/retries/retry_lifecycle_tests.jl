@testset "retry lifecycle" begin
    @test_throws ArgumentError QueueLens.RetryReady(-1.0,1,2)
    @test_throws ArgumentError QueueLens.RetryReady(1.0,1,0)
    @test_throws ArgumentError QueueLens.RetryReady(Inf,1,2)
    jobs = [Job(1,0.0,[ServiceStep(:db,5.0)]), Job(2,0.0,[ServiceStep(:db,1.0)])]
    result = simulate(jobs,Dict(:db=>1),1;retry_policy=RetryPolicy(max_attempts=2,backoff=FixedBackoff(1.0)),
                      failures=[QueueLens.JobFailed(2.0,1,1)],trace=true)
    @test [r.id for r in result.completed] == [2,1]
    @test [r.completion_time for r in result.completed] == [3.0,8.0]
    @test isempty(result.failed)
    @test [(a.job_id,a.attempt_id,a.reason) for a in result.attempts] == [(1,1,:injected),(2,1,:completed),(1,2,:completed)]
    @test last(result.trace).busy == 0
    @test last(result.trace).resource_busy[:db] == 0
    @test result.completed[2].start_time == 0.0
    @test result.completed[2].latency == 8.0
    @test all(a->a.step_index==1,result.attempts)

    @testset "obsolete completion after newer success" begin
        result = simulate([Job(1,0.0,5.0)],Dict{Symbol,Int}();
            retry_policy=RetryPolicy(max_attempts=2),failures=[QueueLens.JobFailed(1.0,1,1)],trace=true)
        @test only(result.completed).completion_time == 6.0
        @test result.monitoring.duration == 6.0
    end
    @testset "bounded timeout retries and resource release" begin
        result = simulate([Job(1,0.0,[ServiceStep(:db,10.0)];timeout=2.0)],Dict(:db=>1);
            retry_policy=RetryPolicy(max_attempts=3,backoff=FixedBackoff(1.0)),trace=true)
        @test isempty(result.completed)
        @test only(result.failed).failure_time == 8.0
        @test length(result.attempts) == 3
        @test all(a->a.reason==:timeout,result.attempts)
        @test result.monitoring.duration == 8.0
        @test last(result.trace).resource_busy[:db] == 0
    end
    @testset "backoff holds neither worker nor resource" begin
        result = simulate([Job(1,0.0,[ServiceStep(:db,5.0)])],Dict(:db=>1);
            retry_policy=RetryPolicy(max_attempts=2,backoff=FixedBackoff(10.0)),
            failures=[QueueLens.JobFailed(1.0,1,1)],trace=true)
        @test only(result.completed).completion_time == 16.0
        @test result.monitoring.worker_utilization ≈ 6/16
        @test result.monitoring.resources[:db].utilization ≈ 6/16
    end
    @testset "retry reenters the bounded FIFO" begin
        result = simulate([Job(1,0.0,5.0),Job(2,0.5,10.0)],Dict{Symbol,Int}(),1;
            queue_capacity=1,retry_policy=RetryPolicy(max_attempts=2,backoff=FixedBackoff(1.0)),
            failures=[QueueLens.JobFailed(1.0,1,1)],trace=true)
        @test length(result.completed) == 2
        @test isempty(result.failed)
        @test only(filter(r->r.id==1,result.completed)).start_time == 0.0
    end
    @testset "full queue denies retry without taking a worker" begin
        result = simulate([Job(1,0.0,5.0),Job(2,2.0,10.0)],Dict{Symbol,Int}(),1;
            queue_capacity=0,retry_policy=RetryPolicy(max_attempts=2,backoff=FixedBackoff(2.0)),
            failures=[QueueLens.JobFailed(1.0,1,1)],trace=true)
        @test only(result.failed).reason == :retry_queue_full
        @test only(result.failed).failure_time == 3.0
        @test only(result.completed).id == 2
        @test only(result.completed).completion_time == 12.0
        @test length(result.attempts) == 2
        @test last(result.trace).busy == 0
    end
    @testset "resource waiter retries without releasing another job's pool" begin
        jobs = [Job(1,0.0,[ServiceStep(:db,5.0)]),
                Job(2,0.0,[ServiceStep(:db,1.0)];timeout=2.0)]
        result = simulate(jobs,Dict(:db=>1),2;
            retry_policy=RetryPolicy(max_attempts=2,backoff=FixedBackoff(2.0)),trace=true)
        @test isempty(result.failed)
        @test [r.completion_time for r in result.completed] == [5.0,6.0]
        @test length(result.attempts) == 3
        @test result.monitoring.resources[:db].utilization == 1.0
        @test result.monitoring.resources[:db].mean_queue_length == 0.5
        @test last(result.trace).resource_waiting[:db] == 0
    end
    @testset "seeded stochastic faults are bounded" begin
        jobs = [Job(i,0.0,[ServiceStep(:db,1.0;failure_probability=1.0)]) for i in 1:4]
        result = simulate(jobs,Dict(:db=>2),3;retry_policy=RetryPolicy(max_attempts=3),seed=12,trace=true)
        @test length(result.failed) == 4
        @test length(result.attempts) == 12
        @test isempty(result.completed)
        @test last(result.trace).busy == 0
        @test all(p->0<=p.resource_busy[:db]<=2,result.trace)
    end
    @testset "cancellation and work limits" begin
        @test_throws InterruptException simulate([Job(1,0.0,1.0)],Dict{Symbol,Int}();cancelled=()->true)
        @test_throws ArgumentError simulate([Job(1,0.0,1.0)],Dict{Symbol,Int}();event_limit=1)
        @test_throws ArgumentError simulate([Job(1,0.0,1.0),Job(1,0.0,1.0)],Dict{Symbol,Int}())
    end
end
