# Text rendering for result containers and statistical summaries.

"""
    show(io, ::MIME"text/plain", monitoring::MonitoringSummary)

Display the full observation window and scalar metrics, sorting resource names
so output order does not depend on dictionary insertion order.
"""
function Base.show(io::IO, ::MIME"text/plain", monitoring::MonitoringSummary)
    println(io, "MonitoringSummary (full run, time 0 to ", monitoring.duration, "):")
    println(io, "  worker_capacity: ", monitoring.worker_capacity)
    println(io, "  mean_queue_length: ", monitoring.mean_queue_length)
    println(io, "  worker_utilization: ", monitoring.worker_utilization)
    for name in sort!(collect(keys(monitoring.resources)))
        resource = monitoring.resources[name]
        println(io, "  resource ", name, ": capacity=", resource.capacity,
                ", mean_queue_length=", resource.mean_queue_length,
                ", utilization=", resource.utilization)
    end
end

"""
    show(io, ::MIME"text/plain", result::SimulationResult)

Show outcome counts, the rejected fraction and available time-weighted metrics
without printing every job in a large run.
The full records remain accessible through `completed` and `rejected`.
"""
function Base.show(io::IO, ::MIME"text/plain", result::SimulationResult)
    println(io, "SimulationResult:")
    println(io, "  completed: ", length(result.completed))
    println(io, "  rejected: ", length(result.rejected))
    println(io, "  failed: ", length(result.failed))
    println(io, "  rejection_rate: ", rejection_rate(result))
    if result.monitoring === nothing
        println(io, "  monitoring: unavailable")
    else
        show(io, MIME"text/plain"(), result.monitoring)
    end
end

"""
    show(io, ::MIME"text/plain", s::Summary)

Human-readable rendering, used whenever a `Summary` is displayed on its own —
which is what the REPL does when you evaluate one.

Defining this rather than relying on the default keeps the numbers legible:
the default prints every field positionally, so reading it means counting
commas against the struct definition.

"""
function Base.show(io::IO, ::MIME"text/plain", s::Summary)
    println(io, "Summary of $(s.num_completed) jobs:")
    println(io, "  num_completed: ", s.num_completed)
    println(io, "  num_discarded: ", s.num_discarded)
    println(io, "  throughput: ", round(s.throughput, digits=2))
    println(io, "  mean_latency: ", round(s.mean_latency, digits=2))
    println(io, "  p50_latency: ", round(s.p50_latency, digits=2))
    println(io, "  p95_latency: ", round(s.p95_latency, digits=2))
    println(io, "  p99_latency: ", round(s.p99_latency, digits=2))
    println(io, "  mean_waiting: ", round(s.mean_waiting, digits=2))
end

"""
    show(io, ::MIME"text/plain", e::Estimate)

Render as `value ± halfwidth`.

"""
function Base.show(io::IO, ::MIME"text/plain", e::Estimate)
    println(io, round(e.mean, digits=3), " ± ", round(e.halfwidth, digits=3), " (n = ", e.num_runs, ")")
end

"""
    show(io, ::MIME"text/plain", r::RepeatedSummary)

Render the run count, warm-up fraction and each `Estimate` using its default
representation, including its mean, half-width and run count.
"""
function Base.show(io::IO, ::MIME"text/plain", r::RepeatedSummary)
    println(io, "RepeatedSummary of $(r.num_runs) runs (warmup_fraction = $(r.warmup_fraction)):")
    println(io, "  latency_mean: ", r.latency_mean)
    println(io, "  latency_p99: ", r.latency_p99)
    println(io, "  waiting_mean: ", r.waiting_mean)
    println(io, "  throughput: ", r.throughput)
    println(io, "  num_rejected (full run): ", r.num_rejected)
    println(io, "  rejection_rate (full run): ", r.rejection_rate)
    println(io, "  mean_queue_length (full run): ", r.mean_queue_length)
    println(io, "  worker_utilization (full run): ", r.worker_utilization)
    for name in sort!(collect(keys(r.resource_mean_queue_length)))
        println(io, "  resource ", name, " mean_queue_length (full run): ", r.resource_mean_queue_length[name])
        println(io, "  resource ", name, " utilization (full run): ", r.resource_utilization[name])
    end
end
