# Configuration Reference

JSON and TOML represent the same version-1 configuration. Export from Studio for
a complete canonical file, or call configuration_toml(default_configuration()).
All durations are seconds; probabilities and fractions lie in [0, 1].

## Fields

| Field | Meaning |
|---|---|
| version | Schema version, currently 1 |
| name | Scenario label, 1-100 characters |
| seed | Base seed, integer 0-2,000,000,000 |
| jobs | Number of logical arrivals, 1-20,000 |
| workers | Concurrent worker slots, 1-256 |
| queue_capacity | Worker waiting slots, 0-100,000 |
| replications | Consecutive seeds to run, 1-20 |
| warmup_fraction | Initial fraction of successful completions discarded, 0-0.9 |
| timeout | Per-attempt deadline from worker start; 0 disables it |
| arrivals | Arrival distribution or burst schedule |
| resources | Up to 12 named pools, each with capacity 1-256 |
| steps | 1-12 ordered service stages |
| retry | Built-in retry strategy and total attempt budget |

Duration fields are bounded by 100,000 seconds. Resource names are identifiers
of at most 32 ASCII characters, starting with a letter. Unknown root fields and
unknown resources are rejected. Partial top-level configurations inherit defaults;
nested objects should include their required fields.

## Workload

Arrival kinds: constant, exponential, lognormal, burst. Mean is the interarrival
mean except for burst, where it is the gap between batches of burst_size jobs.
The first ordinary arrival follows a sampled gap; the first burst arrives at zero.

Each step has name, resource, kind, mean, cv and failure_probability. An empty
resource string means worker-only service. Stage kinds are constant, exponential
and lognormal. CV is standard deviation divided by mean, bounded at 5. Log-normal
parameters are derived from the requested arithmetic mean and CV. A zero mean or
zero log-normal CV becomes constant. Exponential means must be positive.

Failure probability is sampled at stage start per attempt; failure occurs halfway
through the sampled stage duration. It is not a continuous-time failure hazard.

## Retry

Strategies: none, fixed, exponential, jitter.
max_attempts is 1-20 and includes the original attempt; none forces one attempt.
base_delay is the fixed delay or exponential base; cap bounds exponential/jitter.

After failed attempt n, exponential delay is min(cap, base_delay * 2^(n-1)).
Full jitter multiplies that envelope by one uniform draw from the run's RNG.
Timeout covers each attempt, not the logical job's entire lifetime.

## Limits and Reproducibility

The run budget is jobs * steps * replications * effective max_attempts <= 2 million.
A sweep allows at most 36 candidates and at most 8 million aggregate work units.
The engine additionally bounds calendar events. These limits protect the local
interactive server; they are not a simulation stopping-time definition.

Repeated seeds are base + replication - 1. Fault/backoff RNG uses that seed plus
100001. Reports include configuration fingerprint, versions, timestamp and seeds.
Reproduction requires the same Julia/package versions and model configuration,
not only the seed. Timestamps naturally differ between repeated reports.
