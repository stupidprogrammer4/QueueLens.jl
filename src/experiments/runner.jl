"""JSON-ready mean and approximate 95% interval across independent seed runs."""
function experiment_estimate(values)
    any(isnothing,values) && return nothing
    result = estimate(Float64.(values))
    return Dict("mean"=>result.mean, "halfwidth"=>isfinite(result.halfwidth) ? result.halfwidth : nothing,
                "runs"=>result.num_runs)
end

"""Full-run outcome rates and completed-job latency, with explicit warm-up semantics."""
function experiment_metrics(result::SimulationResult, warmup)
    n = length(result.completed)+length(result.failed)+length(result.rejected)
    summary = isempty(result.completed) ? nothing : summarize(result;warmup_fraction=warmup)
    started = length(Set(attempt.job_id for attempt in result.attempts))
    return Dict{String,Any}(
        "completed"=>length(result.completed), "failed"=>length(result.failed), "rejected"=>length(result.rejected),
        "duration"=>result.monitoring.duration, "attempts"=>length(result.attempts),
        "amplification"=>started == 0 ? 0.0 : length(result.attempts)/started,
        "success_rate"=>length(result.completed)/n, "loss_rate"=>(length(result.failed)+length(result.rejected))/n,
        "throughput"=>result.monitoring.duration == 0 ? nothing : length(result.completed)/result.monitoring.duration,
        "mean_latency"=>summary === nothing ? nothing : summary.mean_latency,
        "p50"=>summary === nothing ? nothing : summary.p50_latency,
        "p95"=>summary === nothing ? nothing : summary.p95_latency,
        "p99"=>summary === nothing ? nothing : summary.p99_latency,
        "mean_waiting"=>summary === nothing ? nothing : summary.mean_waiting,
        "worker_utilization"=>result.monitoring.worker_utilization,
        "mean_queue"=>result.monitoring.mean_queue_length,
        "resources"=>Dict(string(k)=>Dict("capacity"=>v.capacity,"utilization"=>v.utilization,"mean_queue"=>v.mean_queue_length)
                          for (k,v) in result.monitoring.resources))
end

"""Portable first-replication rows; failed jobs never get fake zero latency."""
function experiment_rows(result)
    counts = Dict{Int,Int}()
    for attempt in result.attempts
        counts[attempt.job_id] = get(counts,attempt.job_id,0)+1
    end
    rows = Dict{String,Any}[]
    for r in result.completed
        push!(rows,Dict("id"=>r.id,"status"=>"completed","arrival"=>r.arrival_time,"finish"=>r.completion_time,
            "latency"=>r.latency,"waiting"=>r.waiting_time,"attempts"=>get(counts,r.id,0),"reason"=>""))
    end
    for r in result.failed
        push!(rows,Dict("id"=>r.id,"status"=>"failed","arrival"=>r.arrival_time,"finish"=>r.failure_time,
            "latency"=>nothing,"waiting"=>nothing,"attempts"=>get(counts,r.id,0),"reason"=>string(r.reason)))
    end
    for r in result.rejected
        push!(rows,Dict("id"=>r.id,"status"=>"rejected","arrival"=>r.arrival_time,"finish"=>r.rejection_time,
            "latency"=>nothing,"waiting"=>nothing,"attempts"=>0,"reason"=>string(r.reason)))
    end
    sort!(rows;by=row->row["id"])
    return rows
end

"""Run reproducible replications through the production engine and return a portable report."""
function run_experiment(input::AbstractDict; cancelled::Function=()->false, progress::Function=(done,total)->nothing,
                        detailed::Bool=true)
    cfg = validate_configuration(input)
    runs = Dict{String,Any}[]
    first_result = nothing
    for i in 1:cfg["replications"]
        cancelled() && throw(InterruptException())
        seed = cfg["seed"] + i - 1
        jobs = configured_jobs(cfg,seed)
        result = simulate(jobs,Dict{Symbol,Int}(Symbol(r["name"])=>r["capacity"] for r in cfg["resources"]),cfg["workers"];
            queue_capacity=cfg["queue_capacity"],retry_policy=configured_retry(cfg),seed=seed+100_001,
            trace=detailed && i == 1, cancelled)
        first_result === nothing && (first_result = result)
        push!(runs,experiment_metrics(result,cfg["warmup_fraction"]))
        progress(i,cfg["replications"])
        yield()
    end
    metric_keys = ("completed","failed","rejected","duration","attempts","amplification","success_rate","loss_rate",
            "throughput","mean_latency","p50","p95","p99","mean_waiting","worker_utilization","mean_queue")
    aggregate = Dict(key=>experiment_estimate([run[key] for run in runs]) for key in metric_keys)
    resource_stats = Dict(r["name"]=>Dict(key=>experiment_estimate([run["resources"][r["name"]][key] for run in runs])
                         for key in ("utilization","mean_queue")) for r in cfg["resources"])
    toml = configuration_toml(cfg)
    report = Dict{String,Any}("configuration"=>cfg,"metrics"=>aggregate,"resources"=>resource_stats,"runs"=>runs,
        "metadata"=>Dict("created_at"=>string(now(UTC)),"julia_version"=>string(VERSION),"package_version"=>string(pkgversion(@__MODULE__)),
                         "fingerprint"=>bytes2hex(sha256(toml))[1:12],"seeds"=>collect(cfg["seed"]:cfg["seed"]+cfg["replications"]-1),
                         "warmup_fraction"=>cfg["warmup_fraction"],"trace_replication"=>1,"trace_is_sampled"=>true,
                         "latency_scope"=>"successful jobs after completion-order warm-up",
                         "throughput_scope"=>"successful completions / full run duration",
                         "attempt_duration_scope"=>"worker start to attempt end, including resource waits"))
    if detailed
        report["jobs"] = experiment_rows(first_result)
        report["attempts"] = [Dict(string(f)=>(getfield(a,f) isa Symbol ? string(getfield(a,f)) : getfield(a,f))
                                   for f in fieldnames(AttemptResult)) for a in first_result.attempts]
        report["trace"] = [Dict("time"=>p.time,"waiting"=>p.waiting,"busy"=>p.busy,"completed"=>p.completed,
            "failed"=>p.failed,"rejected"=>p.rejected,"resource_busy"=>p.resource_busy,"resource_waiting"=>p.resource_waiting)
            for p in first_result.trace]
    end
    return report
end

"""Compare capacity grids using common workload seeds and explicit performance targets."""
function run_sweep(input::AbstractDict, options::AbstractDict; cancelled::Function=()->false,
                   progress::Function=(done,total)->nothing)
    cfg = validate_configuration(input)
    workers = sort(unique([config_number(x,"worker candidate",1,256;integer=true) for x in get(options,"workers",[1,2,4,8])]))
    pools = sort(unique([config_number(x,"resource candidate",1,256;integer=true) for x in get(options,"capacities",[1,2,4])]))
    name = get(options,"resource",isempty(cfg["resources"]) ? "" : cfg["resources"][1]["name"])
    name == "" || any(r->r["name"]==name,cfg["resources"]) || throw(ArgumentError("unknown sweep resource"))
    name == "" && (pools=[0])
    1 <= length(workers)*length(pools) <= 36 || throw(ArgumentError("sweep must contain 1-36 configurations"))
    workload_budget(cfg)*length(workers)*length(pools) <= 8_000_000 || throw(ArgumentError("sweep too large; reduce jobs or grid size"))
    slo = config_number(get(options,"p99_target",1.0),"P99 target",0,100_000)
    max_loss = config_number(get(options,"max_loss",0.05),"maximum loss",0,1)
    worker_cost = config_number(get(options,"worker_cost",1.0),"worker weight",0.001,100_000)
    resource_cost = config_number(get(options,"resource_cost",2.0),"resource weight",0.001,100_000)
    rows = Dict{String,Any}[]
    total = length(workers)*length(pools)*cfg["replications"]
    for worker in workers, pool in pools
        cancelled() && throw(InterruptException())
        variant = deepcopy(cfg)
        variant["workers"] = worker
        for r in variant["resources"]
            r["name"] == name && (r["capacity"] = pool)
        end
        done = length(rows)*cfg["replications"]
        report = run_experiment(variant;cancelled,detailed=false,progress=(i,n)->progress(done+i,total))
        metrics = report["metrics"]
        latency = metrics["p99"]
        # Single-seed runs cannot establish an interval-based recommendation.
        upper_latency = latency === nothing || latency["halfwidth"] === nothing ? nothing : latency["mean"]+latency["halfwidth"]
        loss = metrics["loss_rate"]
        upper_loss = loss["halfwidth"] === nothing ? nothing : min(1.0,loss["mean"]+loss["halfwidth"])
        feasible = upper_latency !== nothing && upper_loss !== nothing && upper_latency <= slo && upper_loss <= max_loss
        push!(rows,Dict("workers"=>worker,"capacity"=>pool,"score"=>worker*worker_cost+pool*resource_cost,
                        "feasible"=>feasible,"metrics"=>metrics,"resources"=>report["resources"],"configuration"=>variant))
    end
    eligible = findall(row->row["feasible"],rows)
    best = isempty(eligible) ? nothing : first(sort(eligible;by=i->(rows[i]["score"],rows[i]["metrics"]["p99"]["mean"])))
    return Dict("rows"=>rows,"recommended_index"=>best,"resource"=>name,"p99_target"=>slo,"max_loss"=>max_loss,
                "configuration"=>cfg,"options"=>options,
                "method"=>"Lowest weighted capacity among tested points meeting upper 95% mean-P99 and loss bounds; not a production guarantee.")
end
