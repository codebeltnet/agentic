# Understanding Transformer Architectures

## Attention Is All You Need

The transformer architecture replaced recurrent networks by computing attention over all positions in parallel. The core insight: instead of processing tokens sequentially (which creates a bottleneck), let every token attend to every other token simultaneously.

Self-attention computes three projections for each token: Query (Q), Key (K), and Value (V). The attention score between two tokens is the dot product of Q and K, scaled by the square root of the dimension, then passed through softmax to get weights. These weights are applied to V to produce the output.

Multi-head attention runs this process multiple times in parallel with different learned projections, then concatenates the results. Each "head" can learn to attend to different types of relationships — syntactic, semantic, positional.

## Scaling Laws and Compute Budget

Kaplan et al. (2020) showed that model performance follows power laws across three axes: parameters (N), dataset size (D), and compute budget (C). The Chinchilla paper refined this: for a fixed compute budget, the optimal model is smaller and trained on more data than previously thought.

Key numbers:
- GPT-3: 175B params, ~300B tokens, ~3.6E23 FLOPs
- Chinchilla: 70B params, 1.4T tokens, ~5.8E23 FLOPs (similar compute, better performance)
- LLaMA 2 70B: 2T tokens training data

The takeaway: throwing more parameters at a problem without proportionally scaling data is wasteful. Compute-optimal training balances both.

## Inference Optimization

Training a model is expensive but one-time. Inference runs forever and dominates total cost. Key techniques:

**Quantization**: Reduce precision from FP32 → FP16 → INT8 → INT4. Each step roughly halves memory and doubles throughput, with small accuracy loss. GPTQ and AWQ are popular 4-bit methods.

**KV Cache**: During autoregressive generation, cache the Key and Value tensors from previous tokens. Without caching, every new token recomputes attention over the full context — O(n²) becomes O(n).

**Speculative Decoding**: Use a small "draft" model to propose several tokens, then verify them in parallel with the large model. If the draft model is good enough, this provides 2-3x speedup with no quality loss.

**Batching**: Group multiple requests and process them together. Continuous batching (rather than static batching) maximizes GPU utilization by inserting new requests as old ones complete.
