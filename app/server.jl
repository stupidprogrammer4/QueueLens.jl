module QueueLensStudio

using QueueLens, HTTP, JSON3, Random, TOML

const PUBLIC = joinpath(@__DIR__, "public")
const JOBS = Dict{String,Dict{String,Any}}()
const JOB_LOCK = ReentrantLock()
const SECURITY_HEADERS = [
    "X-Content-Type-Options"=>"nosniff",
    "Referrer-Policy"=>"no-referrer",
    "Content-Security-Policy"=>"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self'; img-src 'self' data: blob:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'",
    "Cache-Control"=>"no-store",
]

"""One response boundary keeps API errors and content types predictable."""
function response(status, payload; mime="application/json; charset=utf-8")
    body = startswith(mime,"application/json") ? JSON3.write(payload) : payload
    return HTTP.Response(status;headers=vcat(SECURITY_HEADERS,["Content-Type"=>mime]),body)
end

"""Read a bounded JSON object; imported configuration is data, never Julia code."""
function payload(request)
    data = JSON3.read(String(request.body), Dict{String,Any})
    data isa AbstractDict || throw(ArgumentError("request must be a JSON object"))
    return data
end

"""Representative editable configurations, not precomputed or mocked results."""
function presets()
    base = default_configuration()
    burst = deepcopy(base)
    burst["name"] = "Burst & recovery"
    burst["jobs"] = 600
    burst["arrivals"]["kind"] = "burst"
    burst["arrivals"]["mean"] = 2.0
    burst["arrivals"]["burst_size"] = 50
    burst["queue_capacity"] = 40
    burst["steps"][2]["failure_probability"] = 0.15
    balanced = deepcopy(base)
    balanced["name"] = "Balanced pipeline"
    balanced["workers"] = 8
    balanced["resources"][1]["capacity"] = 4
    balanced["steps"][2]["failure_probability"] = 0.0
    return [base,burst,balanced]
end

"""Bound retained reports and concurrent work; progress and cancellation remain responsive."""
function submit(data)
    mode = get(data,"mode","run")
    mode in ("run","sweep") || throw(ArgumentError("unknown experiment mode"))
    cfg = validate_configuration(data["configuration"])
    options = get(data,"options",Dict{String,Any}())
    options isa AbstractDict || throw(ArgumentError("invalid sweep options"))
    id = bytes2hex(rand(RandomDevice(),UInt8,12))
    flag = Threads.Atomic{Bool}(false)
    lock(JOB_LOCK) do
        count(job->job["status"]=="running",values(JOBS)) < 2 || throw(ArgumentError("two experiments are already running"))
        finished = sort([key for (key,job) in JOBS if job["status"] != "running"];by=key->JOBS[key]["created"])
        while length(JOBS) >= 8 && !isempty(finished)
            delete!(JOBS,popfirst!(finished))
        end
        JOBS[id] = Dict("status"=>"running","done"=>0,"total"=>cfg["replications"],"created"=>time(),"cancel"=>flag)
    end
    @async begin
        progress = (done,total)->lock(JOB_LOCK) do
            JOBS[id]["done"] = done
            JOBS[id]["total"] = total
        end
        try
            result = mode == "run" ? run_experiment(cfg;cancelled=()->flag[],progress) :
                run_sweep(cfg,options;cancelled=()->flag[],progress)
            lock(JOB_LOCK) do
                JOBS[id]["status"] = flag[] ? "cancelled" : "completed"
                flag[] || (JOBS[id]["result"] = result)
            end
        catch err
            lock(JOB_LOCK) do
                JOBS[id]["status"] = err isa InterruptException ? "cancelled" : "failed"
                JOBS[id]["error"] = err isa InterruptException ? "cancelled" : sprint(showerror,err)
            end
            err isa Union{InterruptException,ArgumentError} || @error "Experiment failed" exception=(err,catch_backtrace())
        end
    end
    return response(202,Dict("id"=>id))
end

"""Serve only whitelisted local assets and same-origin, loopback-only API requests."""
function handler(request)
    try
        host = HTTP.header(request,"Host","")
        occursin(r"^(127\.0\.0\.1|localhost):[0-9]+$",host) || return response(403,Dict("error"=>"invalid host"))
        path = first(split(request.target,'?'))
        method = request.method
        if method == "POST"
            origin = HTTP.header(request,"Origin","")
            (isempty(origin) || origin == "http://$host") && HTTP.header(request,"X-QueueLens","") == "studio" ||
                return response(403,Dict("error"=>"same-origin studio requests required"))
        end
        if method == "GET" && path == "/api/health"
            return response(200,Dict("status"=>"ready","julia"=>string(VERSION),"version"=>string(pkgversion(QueueLens))))
        elseif method == "GET" && path == "/api/presets"
            return response(200,presets())
        elseif method == "POST" && path == "/api/jobs"
            return submit(payload(request))
        elseif startswith(path,"/api/jobs/")
            parts = split(path,'/';keepempty=false)
            length(parts) in (3,4) || return response(404,Dict("error"=>"not found"))
            id = parts[3]
            return lock(JOB_LOCK) do
                haskey(JOBS,id) || return response(404,Dict("error"=>"experiment expired or not found"))
                if method == "POST" && length(parts)==4 && parts[4]=="cancel"
                    JOBS[id]["cancel"][] = true
                    return response(200,Dict("status"=>"cancelling"))
                elseif method == "GET" && length(parts)==3
                    return response(200,Dict(k=>v for (k,v) in JOBS[id] if k != "cancel"))
                end
                return response(405,Dict("error"=>"method not allowed"))
            end
        elseif method == "POST" && path == "/api/config/import"
            data = payload(request)
            text = get(data,"text","")
            text isa String || throw(ArgumentError("configuration must be text"))
            format = get(data,"format","json")
            format in ("json","toml") || throw(ArgumentError("use JSON or TOML"))
            config = format=="toml" ? TOML.parse(text) : JSON3.read(text,Dict{String,Any})
            return response(200,validate_configuration(config))
        elseif method == "POST" && path == "/api/config/export"
            return response(200,configuration_toml(payload(request));mime="application/toml; charset=utf-8")
        elseif method == "GET"
            asset = path == "/" ? "index.html" : lstrip(path,'/')
            occursin(r"^[a-zA-Z0-9_./-]+$",asset) && !occursin("..",asset) || return response(404,Dict("error"=>"not found"))
            file = joinpath(PUBLIC,asset)
            isfile(file) || return response(404,Dict("error"=>"not found"))
            ext = splitext(file)[2]
            types = Dict(".html"=>"text/html; charset=utf-8",".js"=>"text/javascript; charset=utf-8",
                         ".css"=>"text/css; charset=utf-8",".woff2"=>"font/woff2",".png"=>"image/png",".svg"=>"image/svg+xml")
            haskey(types,ext) || return response(404,Dict("error"=>"not found"))
            return response(200,read(file);mime=types[ext])
        end
        return response(404,Dict("error"=>"not found"))
    catch err
        err isa Union{ArgumentError,KeyError,TOML.ParserError} || @warn "Request rejected" exception=(err,catch_backtrace())
        return response(400,Dict("error"=>sprint(showerror,err)))
    end
end

"""Start the local graphical workspace; never bind publicly by default."""
function serve(; port=8787)
    server = HTTP.serve!(handler,"127.0.0.1",port;max_body_bytes=2_000_000,
                         read_timeout=30,read_header_timeout=5,write_timeout=60)
    println("QueueLens Studio: http://127.0.0.1:$(HTTP.port(server))")
    flush(stdout)
    return server
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    server = QueueLensStudio.serve(;port=parse(Int,get(ENV,"QUEUELENS_PORT","8787")))
    try
        wait(server)
    finally
        QueueLensStudio.HTTP.forceclose(server)
    end
end
