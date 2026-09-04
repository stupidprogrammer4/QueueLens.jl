# A scenario is the complete description of one run: what arrives, how long
# work takes, how much of it there is, and the seed that makes it repeatable.
#
# Guide section 12: "configuration, package version, and seed accompany every
# report". The seed lives here, in the scenario, rather than being a loose
# argument to simulate, so that a scenario and its results can never drift
# apart.

"""
    Scenario(arrivals, service, num_jobs, seed)

Everything needed to run one simulation.

  - `arrivals` — distribution of the *gap* between consecutive arrivals, not
    of absolute arrival times. `Exponential(rate)` makes arrivals a Poisson
    process at `rate` jobs per unit time.
  - `service`  — distribution of how long the worker is busy with one job.
  - `num_jobs` — how many jobs to generate before the run winds down. Guide
    section 6 also allows stopping on elapsed time; that is not implemented
    yet.
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
