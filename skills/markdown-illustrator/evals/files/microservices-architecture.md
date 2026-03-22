# Microservices at Scale: A Cost-Aware Architecture

## The Monolith-to-Microservices Spectrum

Not every system needs microservices. A monolith serves well when the team is small, the domain is simple, and deployment cadence is weekly. Microservices earn their complexity when teams grow past 20 engineers, domains diverge, and independent deployment becomes a bottleneck.

The spectrum runs from pure monolith through modular monolith, to service-oriented architecture, to fine-grained microservices. Most organizations land somewhere in the middle — and that is fine.

## Service Mesh and Observability

A service mesh (Istio, Linkerd) handles cross-cutting concerns: mTLS, retries, circuit breaking, and traffic shaping. Without it, every team reinvents the wheel — and gets it wrong in different ways.

Observability stacks typically combine:
- **Metrics**: Prometheus + Grafana for throughput, latency percentiles (p50, p95, p99), error rates
- **Traces**: Jaeger or Zipkin for request-level flow across services
- **Logs**: Structured JSON logs shipped to Elasticsearch or Loki

The cost of observability infrastructure is non-trivial — often 10-15% of total cloud spend. Budget for it explicitly.

## GPU Inference as a Service

Running ML models in production means managing GPU fleets. Key economics:
- On-demand A100: ~$3.50/GPU/hour
- Reserved instances: ~$1.80/GPU/hour (1-year commitment)
- Spot/preemptible: ~$1.05/GPU/hour (can be reclaimed)

Utilization is the critical metric. An idle GPU at $3.50/hr is pure waste. Autoscaling based on queue depth (not CPU) keeps utilization above 70%.

Batch inference (offline) should always use spot instances. Real-time inference needs a mix: reserved for baseline load, on-demand for spikes.

## Data Pipeline Architecture

Event-driven pipelines (Kafka, Pulsar) decouple producers from consumers. The pattern:
1. Service emits event to topic
2. Stream processor transforms/enriches
3. Sink writes to data warehouse (BigQuery, Snowflake)
4. Analytics layer queries aggregated data

Backpressure handling matters — a slow consumer should not crash the pipeline. Use consumer group lag monitoring and automatic partition rebalancing.

## Cost Optimization Strategies

Cloud costs grow faster than revenue if left unchecked. Three levers:
- **Right-sizing**: Most VMs are over-provisioned by 40%. Use utilization data to downsize.
- **Spot/preemptible workloads**: Stateless batch jobs, CI/CD runners, and dev environments can tolerate interruption.
- **Reserved capacity**: Commit to 1-year or 3-year reservations for stable baseline workloads. Savings: 30-60%.

Tag everything. Untagged resources are invisible to cost allocation — and invisible costs are uncontrolled costs.
