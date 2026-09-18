using TOML, SHA, Dates

"""Default editable workload shared by the Julia API and the graphical studio."""
function default_configuration()
    return Dict{String,Any}(
        "version"=>1, "name"=>"Checkout service", "seed"=>42, "jobs"=>800,
        "workers"=>4, "queue_capacity"=>100, "replications"=>3, "warmup_fraction"=>0.0,
        "arrivals"=>Dict("kind"=>"exponential", "mean"=>0.08, "cv"=>1.0, "burst_size"=>25),
        "resources"=>[Dict("name"=>"db", "capacity"=>2)],
        "steps"=>[
            Dict("name"=>"Validate", "resource"=>"", "kind"=>"constant", "mean"=>0.025, "cv"=>0.5, "failure_probability"=>0.0),
            Dict("name"=>"Database", "resource"=>"db", "kind"=>"lognormal", "mean"=>0.16, "cv"=>0.8, "failure_probability"=>0.02),
            Dict("name"=>"Respond", "resource"=>"", "kind"=>"constant", "mean"=>0.015, "cv"=>0.5, "failure_probability"=>0.0)],
        "timeout"=>2.0, "retry"=>Dict("strategy"=>"jitter", "max_attempts"=>3, "base_delay"=>0.1, "cap"=>2.0))
end

"""Require a bounded finite numeric input without silently truncating integers."""
function config_number(value, name, lower, upper; integer=false)
    value isa Real && !(value isa Bool) && isfinite(value) && lower <= value <= upper ||
        throw(ArgumentError("$name must be between $lower and $upper"))
    integer && !isinteger(value) && throw(ArgumentError("$name must be an integer"))
    return integer ? Int(value) : Float64(value)
end

"""Validate untrusted JSON/TOML into an isolated canonical configuration."""
function validate_configuration(input::AbstractDict)
    base = default_configuration()
    cfg = Dict{String,Any}(string(k)=>deepcopy(v) for (k,v) in input)
    for (key, value) in base
        haskey(cfg, key) || (cfg[key] = deepcopy(value))
    end
    Set(keys(cfg)) == Set(keys(base)) || throw(ArgumentError("unknown configuration fields"))
    cfg["version"] = config_number(cfg["version"], "configuration version", 1, 1; integer=true)
    cfg["name"] isa AbstractString && 1 <= length(cfg["name"]) <= 100 || throw(ArgumentError("name must contain 1-100 characters"))
    for (key, lo, hi) in (("seed",0,2_000_000_000),("jobs",1,20_000),("workers",1,256),
                           ("queue_capacity",0,100_000),("replications",1,20))
        cfg[key] = config_number(cfg[key], key, lo, hi; integer=true)
    end
    cfg["warmup_fraction"] = config_number(cfg["warmup_fraction"], "warmup_fraction", 0, 0.9)
    cfg["timeout"] = config_number(cfg["timeout"], "timeout", 0, 100_000)
    resources = cfg["resources"]
    resources isa AbstractVector && length(resources) <= 12 || throw(ArgumentError("at most 12 resources are supported"))
    names = Set{String}()
    for resource in resources
        resource isa AbstractDict || throw(ArgumentError("invalid resource"))
        name = get(resource,"name",nothing)
        name isa AbstractString && occursin(r"^[a-zA-Z][a-zA-Z0-9_-]{0,31}$", name) ||
            throw(ArgumentError("resource names must be short identifiers, such as db or cache"))
        name in names && throw(ArgumentError("duplicate resource: $name"))
        push!(names,name)
        resource["capacity"] = config_number(get(resource,"capacity",0), "resource capacity",1,256;integer=true)
    end
    steps = cfg["steps"]
    steps isa AbstractVector && 1 <= length(steps) <= 12 || throw(ArgumentError("provide 1-12 sequential steps"))
    for step in steps
        step isa AbstractDict || throw(ArgumentError("invalid step"))
        get(step,"name",nothing) isa AbstractString && 1 <= length(step["name"]) <= 60 || throw(ArgumentError("each step needs a name"))
        get(step,"resource",nothing) in union(names, Set([""])) || throw(ArgumentError("step references an unknown resource"))
        validate_distribution!(step)
        step["failure_probability"] = config_number(get(step,"failure_probability",0), "failure_probability",0,1)
    end
    cfg["arrivals"] isa AbstractDict || throw(ArgumentError("invalid arrivals"))
    validate_distribution!(cfg["arrivals"]; arrivals=true)
    retry = cfg["retry"]
    retry isa AbstractDict || throw(ArgumentError("invalid retry policy"))
    get(retry,"strategy",nothing) in ("none","fixed","exponential","jitter") || throw(ArgumentError("unknown retry strategy"))
    retry["max_attempts"] = config_number(get(retry,"max_attempts",1),"max_attempts",1,20;integer=true)
    for key in ("base_delay","cap")
        retry[key] = config_number(get(retry,key,0),key,0,100_000)
    end
    workload_budget(cfg) <= 2_000_000 || throw(ArgumentError("reduce jobs, steps, attempts or replications (workload too large)"))
    return cfg
end

"""Normalize one arrival or service distribution specification."""
function validate_distribution!(spec; arrivals=false)
    allowed = arrivals ? ("constant","exponential","lognormal","burst") : ("constant","exponential","lognormal")
    get(spec,"kind",nothing) in allowed || throw(ArgumentError("unknown distribution kind"))
    spec["mean"] = config_number(get(spec,"mean",nothing), "mean duration",0,100_000)
    spec["cv"] = config_number(get(spec,"cv",1.0), "coefficient of variation",0,5)
    spec["kind"] == "exponential" && spec["mean"] == 0 && throw(ArgumentError("exponential mean must be positive"))
    if arrivals
        spec["burst_size"] = config_number(get(spec,"burst_size",25),"burst_size",1,20_000;integer=true)
    end
    return spec
end

"""Interactive work admission bound, independent of random outcomes."""
workload_budget(cfg) = cfg["jobs"] * length(cfg["steps"]) * cfg["replications"] *
    (cfg["retry"]["strategy"] == "none" ? 1 : cfg["retry"]["max_attempts"])

"""Build an existing duration distribution from mean and coefficient of variation."""
function configured_distribution(spec)
    mean, cv = spec["mean"], spec["cv"]
    (spec["kind"] == "constant" || mean == 0 || (spec["kind"] == "lognormal" && cv == 0)) && return Constant(mean)
    spec["kind"] == "exponential" && return Exponential(1 / mean)
    sigma = sqrt(log1p(cv^2))
    return LogNormal(log(mean) - sigma^2 / 2, sigma)
end

"""Sample an explicit multi-resource workload; retries reuse sampled stage durations."""
function configured_jobs(cfg, seed::Int)
    rng = Xoshiro(seed)
    arrivals = cfg["arrivals"]
    burst = arrivals["kind"] == "burst"
    distribution = burst ? nothing : configured_distribution(arrivals)
    services = [configured_distribution(step) for step in cfg["steps"]]
    jobs = Job[]
    time = 0.0
    for id in 1:cfg["jobs"]
        time = burst ? fld(id-1, arrivals["burst_size"]) * arrivals["mean"] : time + sample(rng, distribution)
        steps = [ServiceStep(step["resource"] == "" ? nothing : Symbol(step["resource"]),
                             sample(rng, services[i]); failure_probability=step["failure_probability"])
                 for (i,step) in enumerate(cfg["steps"])]
        push!(jobs, Job(id,time,steps;timeout=cfg["timeout"] == 0 ? nothing : cfg["timeout"]))
    end
    return jobs
end

"""Only known backoff types are allowed; configuration never evaluates arbitrary code."""
function configured_retry(cfg)
    retry = cfg["retry"]
    strategy = retry["strategy"]
    strategy == "none" && return RetryPolicy()
    backoff = strategy == "fixed" ? FixedBackoff(retry["base_delay"]) :
        strategy == "exponential" ? ExponentialBackoff(retry["base_delay"];cap=retry["cap"]) :
        FullJitterBackoff(retry["base_delay"];cap=retry["cap"])
    return RetryPolicy(;max_attempts=retry["max_attempts"],backoff)
end

"""Canonical TOML for reproducible exports and configuration fingerprints."""
configuration_toml(cfg) = sprint(io -> TOML.print(io, validate_configuration(cfg); sorted=true))
