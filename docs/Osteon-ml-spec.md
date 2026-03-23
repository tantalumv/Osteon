# Osteon ML Features Specification
**Document:** Supplementary to Osteon Language Specification v0.3.0
**Version:** 1.1.0
**File Extension:** .ostn
**Status:** Pre-implementation

---

## Overview

This document specifies the machine learning layer of the Osteon compiler. All ML features are additive, optional, and architecturally isolated from the deterministic compiler core. The deterministic core never depends on the ML sidecar for correctness — only for suggestion quality.

### The Fundamental Rule

> **ML features may only enhance suggestions, hints, and explanations. They may never touch lexing, parsing, width checking, uninit analysis, encoding, or any stage where correctness is formally required. The deterministic core is always the ground truth.**

### Architecture Overview

```
osteon (core)              ← pure Odin, deterministic, ~2MB
    ↓  JSON over stdin/stdout IPC
osteon-ml (sidecar)        ← separate process, loads model weights
    ↓  JSON suggestions
osteon (core)              ← receives suggestions, validates deterministically
    ↓
output
```

The sidecar is a separate C binary built from the Osteon source tree. It links against llama.cpp (for GGUF model inference) and ObjectBox C (for vector storage and search). If the sidecar is not running or not installed, the compiler behaves exactly as v0.3 with no ML features active. All ML suggestions are validated by the deterministic core before being emitted. A suggestion that fails deterministic validation is silently discarded and the rule-based fallback is used.

### Technology Stack

| Component | Technology | Rationale |
|-----------|-----------|-----------|
| Text generation | llama.cpp + GGUF | Local inference, no GPU required, quantized models (~1.5GB) |
| Code embedding | jina-code-embeddings-1.5b (GGUF) | 512-dim code vectors, trained on code similarity |
| Correction model | Qwen3.5-4B (GGUF) | Instruction-tuned, good at code correction tasks |
| Vector database | ObjectBox C | Embedded ACID DB with vector search, ~1MB binary, no server |
| IPC | JSON over stdin/stdout | Simple, debuggable, language-agnostic |

---

## File Extension Update

All Osteon source files use the `.ostn` extension from this version forward.

```
program.ostn        # source (previously .ostn)
program.obj         # COFF object (Windows)
program.o           # ELF object (Linux, future)
program.exe         # PE32+ executable
program.raddbg      # RADDBG debug info
program.osc         # compiler checkpoint (session state)
program.prof        # PGO profile data
osteon.log          # ML training data log (opt-in)
```

All CLI examples, import paths, and tooling references use `.ostn`.

---

## Part 1: Data Collection Infrastructure

Data collection is the foundation. Every ML feature depends on high-quality training data generated organically by using the compiler. Data collection is opt-in, anonymous, and local-first.

### 1.1 Logging Format

When `--log-ml` is passed, the compiler appends structured JSON records to `osteon.log` in the project root.

Every log record has a type field and a version field. Types:

```
check_run       — result of --check invocation
correction      — a correction was applied and re-check passed
annotation      — result of --annotate invocation
profile_run     — result of --profile invocation
intent_pair     — @intent declaration paired with function body
query_run       — result of --query invocation
superopt_result — result of --superopt invocation
```

#### `check_run` Record

```json
{
  "type": "check_run",
  "version": "1.0",
  "timestamp": "2025-01-01T00:00:00Z",
  "compiler_version": "0.3.0",
  "target": "x86_64-windows",
  "source_hash": "sha256:abc123...",
  "source": "<ostn source text>",
  "errors": [
    {
      "code": "fatal/width",
      "line": 8,
      "col": 5,
      "offending": "mov(u64) eax, rbx",
      "context_before": ["mov(u64) rax, rbx"],
      "context_after": ["ret"],
      "correction_rule": "mov(u32) eax, ebx",
      "correction_accepted": null
    }
  ],
  "pass_count": 13,
  "warn_count": 2,
  "fatal_count": 1
}
```

#### `correction` Record

```json
{
  "type": "correction",
  "version": "1.0",
  "timestamp": "2025-01-01T00:00:01Z",
  "source_hash_before": "sha256:abc123...",
  "source_hash_after":  "sha256:def456...",
  "source_before": "<broken source>",
  "source_after":  "<fixed source>",
  "errors_before": [...],
  "errors_after":  [],
  "correction_origin": "llm_agent",
  "iterations_to_clean": 2
}
```

`correction_origin` values: `llm_agent`, `human`, `ml_suggestion`, `rule_based`.

#### `intent_pair` Record

```json
{
  "type": "intent_pair",
  "version": "1.0",
  "function_name": "update_positions",
  "namespace": "particles",
  "intent_text": "zero COUNT elements in rdi using AVX streaming stores",
  "reads": ["rdi", "rsi", "xmm0"],
  "clobbers": ["ymm0", "ymm1", "rcx"],
  "invariants": ["rdi 32-byte aligned"],
  "function_body": "<ostn source of function body>",
  "compiler_semantic_summary": { ... }
}
```

### 1.2 Privacy and Data Handling

- All logging is **opt-in** via `--log-ml`.
- Logs are **local only** by default — never transmitted anywhere.
- Source text is logged as-is. If your source contains sensitive names, redact before sharing.
- A `--log-ml-redact` flag replaces all identifiers with anonymized tokens before logging, preserving structure but removing semantics.
- The log file is append-only. Use `osteon --clear-log` to wipe it.

### 1.3 Dataset Export

```bash
osteon --export-dataset ./osteon.log --out dataset.jsonl
```

Produces a JSONL file suitable for model training. Applies deduplication by source hash, filters corrupted records, and splits into train/val/test by timestamp.

---

## Part 2: ML Feature Specifications

---

## 2. Learned Correction Suggestions

**Problem addressed:** Rule-based corrections handle single errors in isolation. Multi-error situations where fixing error A affects error B produce suboptimal suggestions.

**ML approach:** A sequence-to-sequence model that takes a broken `.ostn` function body and its error list as input and produces a corrected function body as output.

### 2.1 Input/Output Contract

```
Input:
  - Broken function source (tokenized .ostn)
  - Ordered list of error codes and locations
  - Target architecture

Output:
  - Corrected function source
  - Confidence score [0.0, 1.0]
  - Per-error explanation of the correction applied
```

### 2.2 Validation Gate

Every ML-suggested correction is passed through the full deterministic analysis pipeline before being emitted:

```
ML model → suggested correction
    ↓
deterministic --check
    ↓
if clean:  emit as "correction" in JSON output, marked ml_suggested: true
if errors: discard, fall back to rule-based correction
```

The agent always knows the correction passed the deterministic checker. `ml_suggested: true` tells it the correction came from the model.

### 2.3 JSON Output Extension

```json
{
  "code": "fatal/width",
  "correction": "mov(u32) eax, ebx",
  "ml_suggested": true,
  "ml_confidence": 0.94,
  "ml_explanation": "eax is 32-bit register — width annotation updated to match.
                     Also fixed downstream add(u64) eax which had same mismatch.",
  "corrections_applied": [
    { "line": 8, "before": "mov(u64) eax, rbx", "after": "mov(u32) eax, ebx" },
    { "line": 12, "before": "add(u64) eax, imm(1)", "after": "add(u32) eax, imm(1)" }
  ]
}
```

The `corrections_applied` field shows every line touched — the agent can verify scope.

### 2.4 Model Architecture

Qwen3.5-4B (IQ4_XS quantized GGUF) is the generative model used for correction suggestions. It is instruction-tuned via the sidecar's system prompt:

```
You are Osteon assembler correction engine. Given a broken function body and
its error list, produce a corrected function body that compiles cleanly.
Output ONLY the corrected function body — no explanations, no markdown.
```

The broken function source and error list are concatenated as the input prompt. Qwen generates the corrected source as a streaming text response. The sidecar parses the output, validates token boundaries, and returns the corrected `.ostn` text to the core compiler.

Inference parameters:
- **context:** 4096 tokens (sufficient for ~50 instruction functions)
- **temperature:** 0.2 (low — correction is deterministic, not creative)
- **top_p:** 0.9
- **repeat_penalty:** 1.1
- **batch_size:** 512
- **inference time:** ~200-500ms per correction (CPU, IQ4_XS)

Training data source: `correction` records from `osteon.log` where `errors_after` is empty.

### 2.5 CLI

```bash
osteon --check --ml program.ostn          # enable ML corrections
osteon --check --ml --ml-confidence 0.9   # only emit if confidence >= 0.9
osteon --check --no-ml program.ostn       # explicitly disable (default without sidecar)
```

---

## 3. Intent Inference

**Problem addressed:** Writing `@intent` blocks manually is friction. Agents don't write them at all. Without intent declarations the `warn/intent_mismatch` pass can't run.

**ML approach:** A model that reads a function body and generates the `@intent`, `@reads`, `@clobbers`, and `@invariant` fields automatically.

### 3.1 Inferred Intent Block

```bash
osteon --infer-intent fn:update_positions program.ostn
```

Output:

```ostn
# @intent: update particle positions by adding velocity * dt for all CAP elements
# @reads: rdi (pos: f32* noalias, 32-byte aligned), rsi (vel: f32* noalias), xmm0 (dt: f32)
# @clobbers: ymm0, ymm1, ymm2, ymm15, rcx
# @invariant: rdi 32-byte aligned (required by vloada)
# @invariant: COUNT divisible by 8 (no scalar tail)
# @ml_confidence: 0.91
fn update_positions {
    ...
}
```

The inferred block is emitted as a comment — valid `.ostn`. The programmer edits it rather than writing from scratch. The `@ml_confidence` field tells them how much to trust it.

### 3.2 Batch Mode

```bash
osteon --infer-intent all program.ostn --out program_intent.ostn
```

Processes every function in the file and emits a new `.ostn` file with inferred intent blocks prepended to all functions that don't already have them.

### 3.3 Model Architecture

Qwen3.5-4B (IQ4_XS) handles intent inference with a structured prompting approach. The sidecar constructs a prompt containing the function body and asks Qwen to generate the `@intent` text:

```
Given this Osteon assembly function, write a one-line intent description
that explains what the function does in plain English. Be specific about
inputs, outputs, and operations. Output ONLY the intent text.

Function:
fn update_positions { ... }
```

Register reads, clobbers, and invariants are extracted **deterministically** from the compiler's existing Pass 13 (clobber analysis) — only the natural language `@intent` description requires ML. This means the structured fields are always correct; only the human-readable summary may need editing.

Training data source: `intent_pair` records from `osteon.log`.

---

## 4. ML-Guided PGO Layout

**Problem addressed:** Rule-based PGO layout (hot blocks first, cold blocks last) ignores cross-function locality and cache line alignment opportunities that require reasoning across the whole binary.

**ML approach:** A model trained on (source, profile, layout) triples that learns which layout decisions correlate with cache hit rates across diverse workloads.

### 4.1 What the Model Decides

Beyond the rule-based pass, the ML layout model additionally:

- Groups mutually-calling functions into the same 64-byte cache line region
- Places loop bodies at cache-line-aligned offsets where the profile shows tight iteration
- Clusters cold paths from multiple functions together (cold island packing)
- Suggests `prefetch` insertion points based on learned memory access stride patterns

### 4.2 ML Layout Output

`--dry-run --profile program.prof --ml` includes layout rationale:

```ostn
# PGO ML layout — program.prof (ml_confidence: 0.88)
# fn update_sim → placed at .text+0x000 (hottest function, 67% of execution)
# fn init_particles → placed at .text+0x400 (called once, cold)
# ML: grouped update_sim and particle_step at same cache region
#     (called together in 94% of profile samples)
# ML: inserted prefetch at loop+8 based on stride pattern (stride=32, consistent)
```

### 4.3 Model Architecture

Qwen3.5-4B (IQ4_XS) handles PGO layout analysis. The sidecar feeds the profile data (function hotness, call graph, loop counts) to Qwen as a structured prompt:

```
Given this profile data and call graph for an Osteon program, suggest
a function layout that minimizes instruction cache misses. Consider:
- Hot functions should be adjacent (same cache line region)
- Loop bodies should be cache-line aligned
- Cold paths should be packed together
Output JSON with placement suggestions.

Profile data:
{json formatted profile_run records}
```

Qwen outputs a JSON layout suggestion that the sidecar parses and validates against deterministic constraints (functions must not overlap, alignment must be power of 2). The deterministic validator rejects any suggestion that violates these constraints.

Training data source: `profile_run` records from `osteon.log` paired with measured cache miss rates from hardware performance counters (optional, requires `--perf-counters` flag during profiling).

---

## 5. Register Pressure Prediction

**Problem addressed:** The compiler can tell you what's wrong now. It can't tell you what will become painful when you extend the code.

**ML approach:** A model that predicts register pressure consequences of the current code structure and warns before the problem manifests.

### 5.1 Hints Produced

```
hint/register_pressure: fn update_sim uses 13/16 GP registers and 12/16 YMM registers
  ml_prediction: adding any additional loop variable requires a stack spill
  ml_confidence: 0.87
  suggestion: consider extracting inner loop body to a separate inline fn
              to create a fresh register context
```

```
hint/spill_risk: fn process_entity has a call site at line 34
  ml_prediction: 4 currently-live registers will spill around this call
                 on 89% of similar functions in training data
  suggestion: reorganize to reduce live registers before call:
              rsi, r8, r9, r11 are live but only rsi is read after the call
```

### 5.2 Model Architecture

Qwen3.5-4B (IQ4_XS) handles register pressure prediction. The sidecar feeds the compiler's register liveness analysis output to Qwen as a structured prompt:

```
Given this function's register liveness data, predict whether adding
loop variables or function calls will cause register spilling. Output
a register pressure assessment with spill risk per code point.

Function: update_sim
GP registers used: 13/16
SIMD registers used: 12/16
Call sites: 3
Loop depth: 2
{detailed liveness data}
```

Qwen outputs a structured assessment that the sidecar parses into hints. The deterministic core validates each hint against actual register allocation before emission — a hint that doesn't match the actual liveness analysis is discarded.

Training data source: `check_run` records annotated with actual spill counts observed in the encoder output.

---

## 6. Pattern Recognition for Missing Code

**Problem addressed:** The deterministic checker catches wrong code. It cannot catch missing code — the absence of an expected pattern.

**ML approach:** A model trained on common Osteon idioms that recognizes when an expected pattern is absent given the surrounding context.

### 6.1 Hints Produced

```
hint/pattern_missing: fn update_positions uses ntstore but no sfence after loop
  pattern: ntstore sequences are followed by sfence in 99.2% of training examples
  ml_confidence: 0.96
  suggestion: add sfence after the loop body
```

```
hint/pattern_missing: fn safe_div returns via two paths but only one sets rdx
  pattern: result-convention functions set rdx on all return paths
           in 97.8% of training examples
  ml_confidence: 0.91
  suggestion: ensure rdx is set to 0 on the success path at line 18
```

```
hint/pattern_missing: SIMD loop over 8192 elements has no scalar epilogue
  pattern: vec(f32,8) loops include scalar tail handling in 84% of training examples
           when COUNT is not a compile-time multiple of 8
  ml_confidence: 0.73
  suggestion: add masked load/store or scalar cleanup loop for COUNT % 8 remainder
```

### 6.2 Confidence Threshold

Pattern hints are only emitted above a configurable confidence threshold:

```bash
osteon --check --ml --pattern-threshold 0.85 program.ostn
```

Default threshold: `0.80`. Below this, the hint is suppressed to avoid noise.

### 6.3 Model Architecture

Qwen3.5-4B (IQ4_XS) handles pattern recognition. The sidecar constructs a masked-context prompt:

```
You are an Osteon assembler pattern analyzer. Given a function body,
identify any missing idiomatic patterns. Common patterns to check for:
- ntstore sequences must be followed by sfence
- result-convention functions must set rdx on all return paths
- SIMD loops with non-multiple-of-8 COUNT need scalar epilogue
- functions using lock prefix should have proper memory ordering
- arena alloc should have matching reset

For each missing pattern found, output JSON:
{"pattern": "...", "confidence": 0.0-1.0, "suggestion": "..."}

Function:
fn update_positions { ... }
```

The sidecar parses Qwen's output and validates each pattern against the compiler's deterministic analysis. A pattern hint is only emitted if the deterministic analysis confirms the missing code is real (not a false positive from the model).

Training data source: `check_run` records where `fatal_count == 0` and `warn_count == 0` — clean programs only. These represent correct Osteon idioms.

---

## 7. Semantic Embedding and Natural Language Query

**Problem addressed:** The `--query` flag currently requires exact names and categories. Agents need to ask questions about semantics, not just names.

**ML approach:** Embed every function, struct, and data declaration as a dense vector. Queries search the embedding space.

### 7.1 Embedding Generation

```bash
osteon --embed program.ostn --out program.emb
```

Produces a binary embedding file. Every function is represented as a 512-dimensional vector capturing its semantic behavior — what it reads, writes, calls, and computes. The embedding is generated by the jina-code-embeddings-1.5b model (GGUF) via llama.cpp inference.

Embeddings are also persisted to the ObjectBox vector database at `ml/models/objectbox/embeddings.mdb`. The ObjectBox entity schema:

```c
// Each embedded function/struct stored as an ObjectBox entity
struct Code_Embedding {
    id:          uint64   // auto-assigned ObjectBox ID
    namespace:   string   // "particles" or "" for top-level
    name:        string   // "update_positions"
    file:        string   // source file path
    line:        uint32   // line number
    kind:        string   // "function" | "struct" | "data"
    embedding:   float[512]  // jina embedding vector (HNSW indexed)
    reads:       string[] // register names the analysis detected
    clobbers:    string[] // clobbered register names
    invariants:  string[] // invariant annotations
    body_hash:   string   // SHA256 of function body (dedup)
}
```

The `embedding` field uses ObjectBox's built-in HNSW (Hierarchical Navigable Small World) vector index with:
- **dimensions:** 512 (jina model output)
- **distance type:** cosine similarity
- **ef_construction:** 128 (index build quality)
- **ef_search:** 64 (query quality vs speed tradeoff)
- **max_neighbors:** 32 (graph connectivity)

ObjectBox provides ACID persistence, crash recovery, and zero-copy vector reads — no external server or configuration needed.

### 7.2 Semantic Query

```bash
osteon --query-semantic "functions that might have race conditions" program.emb
osteon --query-semantic "what calls into vulkan" program.emb
osteon --query-semantic "show me all hot paths" program.emb
osteon --query-semantic "functions similar to update_positions" program.emb
```

The query text is embedded by the jina model, then ObjectBox performs approximate nearest neighbor (ANN) search over the stored embeddings. Results are filtered by metadata (namespace, file, kind) and ranked by cosine similarity.

Output (JSON):

```json
{
  "query": "functions that might have race conditions",
  "results": [
    {
      "function": "sim::dispatch",
      "similarity": 0.91,
      "reason": "reads and writes shared memory without lock prefix",
      "file": "sim.ostn",
      "line": 14
    },
    {
      "function": "physics::integrate",
      "similarity": 0.84,
      "reason": "writes to extern provenance pointer without fence",
      "file": "physics.ostn",
      "line": 67
    }
  ]
}
```

The `reason` field is generated by the Qwen model — it reads the matched function body and explains why it matches the query. This is post-filtering: ObjectBox returns the top-K matches, then Qwen explains each one.

### 7.3 Cross-File Semantic Search

```bash
osteon --query-semantic "functions that violate cache line alignment" \
       src/*.emb
```

Searches across all embeddings in the ObjectBox database. The database accumulates embeddings from all `--embed` runs across the project. Useful for large codebases where the agent needs to find relevant code without reading every file.

### 7.3.1 Database Management

```bash
osteon --db-stats                  # show ObjectBox database statistics
osteon --db-reindex                # rebuild HNSW index (after bulk imports)
osteon --db-compact                # compact database file
osteon --db-purge <file.ostn>     # remove embeddings for a specific file
```

### 7.4 Model Architecture

The jina-code-embeddings-1.5b model is a contrastive learning encoder trained on (function body, semantic description) pairs. Similar functions (same pattern, different registers) produce similar embeddings. Dissimilar functions (SIMD update vs dispatch table) produce distant embeddings.

The model runs via llama.cpp's embedding API. Input: function body text (tokenized). Output: 512-dimensional float vector. Inference takes ~5ms per function on CPU (IQ4_XS quantization).

Training data source: `annotation` records from `osteon.log` where `--annotate` was used — these pair function bodies with compiler-generated semantic summaries.

---

## 8. Systemic Error Deduplication

**Problem addressed:** A systematic mistake (wrong register convention used everywhere) produces 40 identical errors. The agent can't prioritize or see the pattern.

**ML approach:** A clustering model that groups related errors into systemic patterns and produces a single correction description that fixes all instances.

### 8.1 Grouped Error Output

```json
{
  "systemic_errors": [
    {
      "pattern_id": "sys_001",
      "code": "warn/clobber",
      "count": 12,
      "ml_pattern": "rsi used as scratch register across call sites",
      "ml_confidence": 0.95,
      "representative_instance": {
        "file": "program.ostn",
        "line": 14
      },
      "all_instances": [14, 28, 45, 67, 89, 102, 118, 134, 156, 178, 201, 224],
      "systemic_correction": {
        "description": "Save and restore rsi around all call sites, or declare rsi callee-saved",
        "example_fix": "push(u64) rsi\ncall target\npop(u64) rsi",
        "affects_lines": [14, 28, 45, 67, 89, 102, 118, 134, 156, 178, 201, 224]
      }
    }
  ],
  "individual_errors": [...]
}
```

### 8.2 Clustering Model

K-means over error feature vectors. Features: error code, register names involved, proximity to call sites, function membership, line distance between instances. The centroid of each cluster becomes the representative instance. The systemic correction is generated by the correction suggestion model (section 2) applied to the representative instance.

---

## 9. Superoptimization — `--superopt`

**Problem addressed:** Small hot functions can often be expressed in fewer instructions. Hand optimization is tedious and error-prone.

**ML approach:** Stochastic search over equivalent instruction sequences, guided by a learned model that predicts which transformations are likely to produce shorter/faster sequences. Formal equivalence verification before any suggestion is emitted.

### 9.1 Strict Scope

Superoptimization is the **only** ML feature that can suggest instruction-level changes. It operates under extremely strict constraints:

- Only functions explicitly marked `# @superopt` are candidates
- Only functions ≤ 50 instructions
- Only functions with no calls, no syscalls, no memory fences
- Every suggestion is formally verified for equivalence before emission
- Opt-in per function AND per build (`--superopt` flag)

### 9.2 Usage

```ostn
# @superopt
fn dot_product {
    let a = xmm0
    let b = xmm1
    vmul(f32, 4)  xmm0, xmm0, xmm1
    vhsum(f32, 4) xmm0, xmm0
    ret
}
```

```bash
osteon --superopt program.ostn
```

Output:

```
superopt: fn dot_product
  original:  5 instructions
  candidate: 3 instructions (vdpps xmm0, xmm0, xmm1, 0xF1)
  verified:  yes (formal equivalence check passed)
  speedup:   estimated 1.4x on Zen4, 1.2x on Skylake

  Suggested replacement:
    vmul(f32, 4)  xmm0, xmm0, xmm1     # keep: vdpps includes multiply
    vdpps(f32, 4) xmm0, xmm0, xmm1, imm(0xF1)  # fused dot product
```

The programmer applies the suggestion manually. Superopt never edits source files.

### 9.3 Formal Equivalence Verification

Every superopt candidate is verified by bounded model checking before emission:

- Both original and candidate are modeled as symbolic register transformations
- An SMT solver (Z3) checks whether both produce identical outputs for all inputs
- If the solver cannot prove equivalence within a timeout, the candidate is discarded

The compiler binary ships with Z3 as a dependency only when `--superopt` is enabled. The core compiler has no dependency on Z3.

### 9.4 Search Model Architecture

Qwen3.5-4B (IQ4_XS) guides the superopt search via value estimation. The sidecar constructs a prompt:

```
Given this Osteon assembly function, propose equivalent but shorter
instruction sequences. Consider:
- Instruction fusion (e.g., LEA for arithmetic)
- Register reuse patterns
- Implicit zero idioms (xor reg, reg)
- Fused operations (vdpps for dot product)

Output candidate sequences as Osteon source, one per suggestion.
Each candidate must be equivalent to the original for all inputs.

Original:
fn dot_product {
    let a = xmm0
    let b = xmm1
    vmul(f32, 4)  xmm0, xmm0, xmm1
    vhsum(f32, 4) xmm0, xmm0
    ret
}
```

Qwen generates candidate sequences. Each candidate is then formally verified by Z3 (bounded model checking) before emission. Candidates that fail Z3 equivalence check are silently discarded.

Inference parameters:
- **temperature:** 0.7 (higher — creative search for shorter sequences)
- **top_p:** 0.95
- **repeat_penalty:** 1.0 (no penalty — repetition of common idioms is expected)
- **max_candidates:** 10 (evaluate up to 10 candidates per function)
- **timeout:** 30 seconds total (10 candidates × ~3s each)

Training data source: `superopt_result` records from `osteon.log` where `verified: true`.

---

## 10. `--agent-mode` — Combined Agent Output

A single flag that configures all ML features for optimal agent consumption:

```bash
osteon --agent-mode --check program.ostn
```

Equivalent to:

```bash
osteon \
  --check \
  --json \
  --ml \
  --ml-confidence 0.80 \
  --pattern-threshold 0.80 \
  --error-budget 5 \
  --explain-output all \
  --error-dedup \
  program.ostn
```

### 10.1 Agent Mode JSON Envelope

```json
{
  "agent_mode": true,
  "compiler_version": "0.3.0",
  "ml_sidecar_version": "1.0.0",
  "status": "errors",
  "fatal_count": 1,
  "warn_count": 3,
  "hint_count": 2,
  "error_budget": 5,
  "errors_shown": 4,
  "errors_suppressed": 0,

  "suggested_next_action": {
    "priority": "fatal",
    "description": "Fix fatal/width at line 8 before addressing warnings",
    "reason": "width errors often cascade — fixing one resolves multiple warnings"
  },

  "systemic_errors": [...],
  "errors": [...],
  "hints": [...],

  "semantic_summary": {
    "fn update_sim": {
      "reads": ["rdi", "rsi", "xmm0"],
      "clobbers": ["ymm0", "ymm1", "rcx"],
      "loops": 1,
      "simd": "avx 8-wide f32",
      "side_effects": ["sfence"]
    }
  },

  "ml_suggestions": {
    "corrections_available": 1,
    "patterns_detected": 2,
    "intent_inferrable": true
  }
}
```

The `suggested_next_action` field is compiler-prioritized guidance. It tells the agent what to fix first based on known error cascade relationships — not just error severity.

---

## Part 3: ML Sidecar Architecture

### 11.1 IPC Protocol

The sidecar communicates with the core compiler over stdin/stdout using newline-delimited JSON. The core compiler spawns the sidecar as a child process on first ML feature use and keeps it alive for the session.

```
core → sidecar:  { "request_id": "abc", "type": "correction", "payload": {...} }
sidecar → core:  { "request_id": "abc", "type": "correction_response", "payload": {...} }
```

Every request has a `timeout_ms` field. If the sidecar does not respond within the timeout, the core compiler falls back to rule-based behavior silently.

### 11.2 Model Loading

The sidecar loads models lazily on first use from the `ml/models/` directory within the Osteon installation:

```
ml/models/
├── qwen3.5-4b/
│   └── Qwen3.5-4B-IQ4_XS.gguf     # correction, intent, pattern model (~2GB quantized)
├── jina-code-1.5b/
│   └── jina-code-embeddings-1.5b-IQ4_XS.gguf  # code embedding model (~600MB quantized)
└── objectbox/
    └── embeddings.mdb               # ObjectBox vector database (auto-created)
```

All models are in GGUF format (llama.cpp's native format). GGUF files contain the full model weights, tokenizer, and metadata in a single file. Models are loaded via llama.cpp's C API, which provides:
- Single-header C library (`llama.h`) — easy to link
- CPU inference with optional GPU acceleration (CUDA, Metal, Vulkan)
- Quantized inference (IQ4_XS) for ~4x reduction in model size with minimal quality loss
- Streaming token generation for responsive output

### 11.2.1 Model Roles

| Model | File | Dimensions | Purpose |
|-------|------|-----------|---------|
| Qwen3.5-4B-IQ4_XS | `qwen3.5-4b/` | — | Text generation: correction suggestions, intent inference, pattern hints, explanations |
| jina-code-embeddings-1.5b-IQ4_XS | `jina-code-1.5b/` | 512 | Code embedding: vectorize functions/structs for semantic search |

The Qwen model handles all generative tasks (corrections, intent, explanations). The jina model handles all embedding tasks (semantic search, similarity, clustering). ObjectBox stores the jina embeddings and provides the vector search index.

### 11.2.2 Model Download

```bash
osteon --update-models           # download latest models from osteon.dev
osteon --list-models             # show installed model versions
osteon --model-info correction   # show details for a specific model
```

Models can also be manually placed in the `ml/models/` directory. The sidecar verifies the GGUF file header on load and rejects corrupted or incompatible files.

### 11.3 Sidecar Implementation Language

The sidecar is written in C and links against:
- **llama.cpp** — GGUF model inference (text generation + code embedding)
- **ObjectBox C** — embedded vector database (ACID persistence + vector search)

Build dependencies:
```
llama.cpp/          # git submodule or downloaded
├── include/llama.h  # C API header
└── build/libllama.a # static library

objectbox-c/        # downloaded from GitHub
├── include/
│   ├── obx.h        # core database API
│   └── obx_model.h  # entity model definitions
└── lib/
    └── objectbox.lib # static library (Windows)
```

The sidecar binary (`osteon-ml.exe`) is built separately from the compiler. On first run, it creates the ObjectBox database in `ml/models/objectbox/embeddings.mdb` and indexes any existing `.emb` files. The binary is approximately 3-5 MB (llama.cpp static + ObjectBox static + sidecar code).

No Python installation is required. The sidecar is a single self-contained binary.

Alternatively, the sidecar can point to a remote API:

```bash
osteon --ml-endpoint https://api.osteon.dev/ml
```

Which lets users access larger cloud-hosted models without local inference overhead.

### 11.4 Model Update

```bash
osteon --update-models           # download latest models from osteon.dev
osteon --list-models             # show installed model versions
osteon --model-info correction   # show details for a specific model
```

Models are versioned independently of the compiler. A newer correction model can be installed without updating the compiler binary.

---

## Part 4: Training Infrastructure

### 12.1 Local Fine-Tuning

For users with substantial `osteon.log` data, local fine-tuning adapts the base models to their specific codebase patterns. Fine-tuning uses llama.cpp's LoRA adapter training:

```bash
osteon --fine-tune \
  --log osteon.log \
  --model correction \
  --out ml/models/qwen3.5-4b/osteon-lora.gguf \
  --epochs 10 \
  --lora-rank 16
```

The fine-tuned model is saved as a LoRA adapter (not a full model). At inference time, the sidecar merges the base GGUF model with the LoRA adapter on load. LoRA adapters are small (~50MB for rank 16) and can be loaded/unloaded without reloading the base model.

Fine-tuning runs on CPU and takes approximately 30 minutes for 10,000 log records. GPU acceleration available if CUDA is present (llama.cpp supports CUDA fine-tuning natively).

### 12.2 Dataset Statistics

```bash
osteon --dataset-stats osteon.log
```

Output:

```
osteon.log statistics:
  check_run records:      4,821
  correction records:     892
  intent_pair records:    234
  profile_run records:    67
  clean programs:         3,104  (64.4%)

  Most common errors:
    warn/clobber:         1,204 instances
    fatal/width:          887 instances
    warn/dead:            654 instances

  Average iterations to clean: 2.3
  Correction acceptance rate:  78.4%

  Recommendation: sufficient data for correction model fine-tuning
                  more intent_pair records needed for intent model (target: 1000)
```

### 12.3 Federated Learning (Future)

Users who opt in can contribute anonymized, redacted training data to a shared model. The federated learning coordinator trains on aggregated gradients — no raw source code leaves the user's machine. This produces a shared base model that improves for everyone.

This is a future feature. The logging infrastructure specified in section 1 is designed to support it.

---

## Part 5: New CLI Flags Summary

```bash
# ML control
--ml                          Enable ML features (requires sidecar)
--no-ml                       Explicitly disable ML features
--ml-confidence <float>       Minimum confidence for ML suggestions (default: 0.80)
--ml-endpoint <url>           Use remote ML API instead of local sidecar
--log-ml                      Enable training data logging to osteon.log
--log-ml-redact               Redact identifiers before logging
--clear-log                   Wipe osteon.log

# Specific ML features
--infer-intent <fn|all>       Infer @intent blocks for functions
--embed                       Generate semantic embeddings
--query-semantic <query>      Natural language semantic search
--superopt                    Enable superoptimization (strict scope)
--pattern-threshold <float>   Minimum confidence for pattern hints (default: 0.80)
--error-dedup                 Group systemic errors
--error-budget <int>          Max errors per iteration (default: unlimited)
--explain-output <fn|all>     Semantic summary output
--agent-mode                  All agent features combined

# Model management
--update-models               Download latest models
--list-models                 Show installed models
--model-info <name>           Model details
--fine-tune                   Fine-tune on local log data (llama.cpp LoRA)
--dataset-stats <log>         Log file statistics
--export-dataset <log>        Export JSONL training dataset

# ObjectBox vector database
--db-stats                    Show ObjectBox database statistics
--db-reindex                  Rebuild HNSW index
--db-compact                  Compact database file
--db-purge <file.ostn>        Remove embeddings for a specific source file
```

---

## Part 6: New Error and Hint Codes

| Code                          | Severity | Source      | Description                                  |
|-------------------------------|----------|-------------|----------------------------------------------|
| `hint/register_pressure`      | hint     | ML          | Register usage near saturation               |
| `hint/spill_risk`             | hint     | ML          | Predicted stack spills around call site      |
| `hint/pattern_missing`        | hint     | ML          | Expected idiom pattern absent                |
| `hint/superopt_available`     | hint     | ML          | Shorter equivalent sequence found            |
| `warn/intent_mismatch`        | warn     | ML+Det      | @intent declaration conflicts with analysis  |
| `info/ml_correction`          | info     | ML          | ML-suggested correction applied              |
| `info/systemic_pattern`       | info     | ML          | Multiple errors share a root cause           |

---

## Part 7: Implementation Milestones

```
M1 (Logging — complete):
  - Logging infrastructure (section 1)         ✅ spec written
  - --log-ml flag operational                    not implemented
  - osteon.log format finalized                  ✅ spec written
  - No ML models yet — just data collection

M2 (Sidecar + first model):
  - Sidecar binary skeleton (C + llama.cpp)
  - ObjectBox C integration
  - Qwen3.5-4B GGUF loading + inference
  - jina-code-embeddings-1.5b GGUF loading
  - Correction suggestion model (section 2)
  - --ml flag operational
  - --agent-mode flag operational (ML corrections only)

M3 (Embeddings):
  - ObjectBox vector DB schema + HNSW index
  - jina embedding generation pipeline
  - --embed and --query-semantic operational
  - Cross-file search via ObjectBox ANN
  - --db-stats, --db-reindex, --db-compact

M4 (Pattern and intent):
  - Pattern recognition via Qwen prompting (section 6)
  - Intent inference via Qwen prompting (section 3)
  - --infer-intent flag operational

M5 (PGO ML):
  - ML-guided PGO layout (section 4)
  - Register pressure prediction (section 5)
  - Systemic error deduplication (section 8)

M6 (Superopt):
  - Z3 integration
  - Superoptimization search via Qwen (section 9)
  - --superopt operational

M7 (Fine-tuning):
  - llama.cpp LoRA fine-tuning pipeline
  - Dataset export
  - --fine-tune operational
```

---

## Version History

| Version | Document          | Notes                                             |
|---------|-------------------|---------------------------------------------------|
| 1.1.0   | ML Features Spec  | Architecture update: GGUF models (Qwen3.5-4B,     |
|         |                   | jina-code-embeddings-1.5b) via llama.cpp,          |
|         |                   | ObjectBox C vector DB, C sidecar binary,           |
|         |                   | LoRA fine-tuning, --db-stats/--db-reindex CLI      |
| 1.0.0   | ML Features Spec  | Initial spec: ONNX models, Python sidecar,        |
|         |                   | ONNX Runtime, all ML features specified            |

---

*Osteon — bone-level code.*