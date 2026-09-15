# A scenario describes the workload: what arrives, how long
# work takes, how much of it there is, and the seed that makes it repeatable.
# Keep the seed with the workload configuration so a run can be reproduced.

"""
    Scenario(arrivals, service, num_jobs, seed)

Workload parameters and seed for one simulation. Worker capacity is supplied
separately to `simulate` and defaults to one.

  - `arrivals` — distribution of the *gap* between consecutive arrivals, not
    of absolute arrival times. `Exponential(rate)` makes arrivals a Poisson
    process at `rate` jobs per unit time.
  - `service`  — distribution of how long the worker is busy with one job.
  - `num_jobs` — how many jobs to generate before the run winds down.
    Stopping on elapsed time is not implemented yet.
  - `seed`     — seeds the run's RNG. The same scenario always produces the
    same results.
"""
struct Scenario
    arrivals::Distribution
    service::Distribution
    num_jobs::Int
    seed::Int

    function Scenario(arrivals::Distribution, service::Distribution, num_jobs::Int, seed::Int)
        if num_jobs <= 0
            throw(ArgumentError("num_jobs must be positive, got $num_jobs"))
        end
        new(arrivals, service, num_jobs, seed)
    end
end
