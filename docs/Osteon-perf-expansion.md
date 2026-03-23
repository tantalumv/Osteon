# Osteon Performance & Memory Safety Expansion
**Document:** Supplementary to Osteon Language Specification v0.3.0
**Version:** 1.0.0 (Draft)
**Status:** Pre-implementation

---

## Overview

This document specifies the performance and memory safety expansion layer for Osteon. All features described here are additive — they extend the v0.3 spec without breaking any existing syntax or behavior.

Every feature in this document obeys Osteon's core identity:

- **Explicit over implicit.** No feature generates instructions the programmer did not authorize.
- **Sugar is visible.** Every new construct desugars transparently via `--dry-run`.
- **Safety is opt-in.** No safety feature is default. You choose the dial position per build.
- **1:1 mapping preserved.** Every instruction still corresponds to exactly one machine instruction.

---

## Part 1: Performance Features

---

## 1. Manual Vectorization — The `vec` Abstraction

Raw SIMD is hard not because the operations are complex but because the syntax is hostile. Osteon's vectorization abstraction makes explicit SIMD readable without hiding what executes.

### 1.1 Vec Type Syntax

```osteon
vec(type, lanes)
```

Maps 1:1 to a physical SIMD register:

| Expression      | Register | ISA Required |
|-----------------|----------|--------------|
| `vec(f32, 4)`   | xmm      | SSE          |
| `vec(f32, 8)`   | ymm      | AVX          |
| `vec(f32, 16)`  | zmm      | AVX-512      |
| `vec(u32, 8)`   | ymm      | AVX2         |
| `vec(f64, 4)`   | ymm      | AVX          |

The type annotation in `v`-prefixed instructions follows the same paren style as all Osteon instructions. Every vector instruction maps to exactly one SIMD instruction — visible in `--dry-run` output.

### 1.2 Vector Instruction Reference

**Memory:**

```osteon
vload(type, lanes)    dst, src          # unaligned load
vloada(type, lanes)   dst, src          # aligned load (fatal/vec_align if unaligned)
vstore(type, lanes)   dst, src          # unaligned store
vstorea(type, lanes)  dst, src          # aligned store
```

**Arithmetic:**

```osteon
vadd(type, lanes)     dst, a, b
vsub(type, lanes)     dst, a, b
vmul(type, lanes)     dst, a, b
vdiv(type, lanes)     dst, a, b
vfma(type, lanes)     dst, a, b, c      # dst = a*b + c (fused multiply-add)
vsqrt(type, lanes)    dst, src
vabs(type, lanes)     dst, src
vmin(type, lanes)     dst, a, b
vmax(type, lanes)     dst, a, b
```

**Broadcast / Splat:**

```osteon
vbroadcast(type, lanes)  dst, src       # fill all lanes with scalar
```

**Shuffle / Permute:**

```osteon
vshuffle(type, lanes)    dst, src, imm(mask)
vpermute(type, lanes)    dst, src, idx_reg
```

**Comparison:**

```osteon
vcmp(type, lanes)        dst, a, b, imm(predicate)
# predicates: EQ=0, LT=1, LE=2, NEQ=4, GE=5, GT=6
```

**Mask Operations:**

```osteon
vmaskedload(type, lanes)    dst, src, mask_reg
vmaskedstore(type, lanes)   dst, mask_reg, src
vblend(type, lanes)         dst, a, b, imm(mask)     # select lanes by mask
vblendv(type, lanes)        dst, a, b, mask_reg      # select lanes by register mask
```

Mask operations are essential for array tails when COUNT is not a multiple of lane width, and for conditional SIMD without branching.

**Reduction:**

```osteon
vhsum(type, lanes)       dst, src      # horizontal sum → scalar in dst[0]
vhmax(type, lanes)       dst, src      # horizontal max → scalar in dst[0]
vhmin(type, lanes)       dst, src      # horizontal min → scalar in dst[0]
```

**Conversion:**

```osteon
vcvt(src_type, dst_type, lanes)  dst, src
# e.g. vcvt(f32, i32, 8) dst, src  — float to int, 8 lanes
```

### 1.3 SIMD Register Aliases

The `let` alias system extends to SIMD registers for complex kernels:

```osteon
fn matrix_multiply {
    let row0 = ymm0
    let row1 = ymm1
    let row2 = ymm2
    let row3 = ymm3
    let acc  = ymm4
    let tmp  = ymm5

    vload(f32, 8)  row0, deref(rdi, 0)
    vload(f32, 8)  row1, deref(rdi, 32)
    vfma(f32, 8)   acc, row0, row1, acc
    ret
}
```

Aliases appear in all error messages and `--dry-run` output.

### 1.4 `--dry-run` Vector Output

`--dry-run` annotates every vector instruction with its exact x86-64 mnemonic:

```osteon
# vbroadcast(f32, 8) ymm1, xmm0  →  vbroadcastss ymm1, xmm0
# vload(f32, 8) ymm2, [rdi]      →  vmovups ymm2, [rdi]
# vmul(f32, 8) ymm3, ymm3, ymm1  →  vmulps ymm3, ymm3, ymm1
# vadd(f32, 8) ymm2, ymm2, ymm3  →  vaddps ymm2, ymm2, ymm3
# vstore(f32, 8) [rdi], ymm2     →  vmovups [rdi], ymm2
```

### 1.5 Vector Static Analysis

Two new error codes for vector instructions:

`fatal/vec_align` — `vloada`/`vstorea` on a pointer the compiler can prove is not aligned to the required boundary (16 bytes for xmm, 32 bytes for ymm, 64 bytes for zmm).

`warn/vec_width` — using a wider vector than the target supports:

```
warn/vec_width: vec(f32, 8) requires AVX
  target x86_64-windows-sse42 only supports 4-wide (xmm)
  Correction: vec(f32, 4) with xmm registers
```

### 1.6 Example: SoA Particle Position Update

```osteon
fn update_positions {
    let pos  = rdi    # f32* positions SoA array
    let vel  = rsi    # f32* velocities SoA array
    let dt   = xmm0   # scalar f32 delta time
    let n    = rdx    # u64 count

    # broadcast dt into all 8 lanes
    vbroadcast(f32, 8) ymm1, xmm0

    # main loop — 8 elements per iteration
    for rcx = imm(0), n, imm(8) {
        vload(f32, 8)  ymm2, deref(pos, 0)
        vload(f32, 8)  ymm3, deref(vel, 0)
        vfma(f32, 8)   ymm2, ymm3, ymm1, ymm2    # pos += vel * dt
        vstore(f32, 8) deref(pos, 0), ymm2
        add(u64) pos, imm(32)
        add(u64) vel, imm(32)
    }

    # scalar epilogue for tail (when n % 8 != 0)
    # handled by caller or via masked load
    ret
}
```

---

## 2. Cache Control

Cache behavior is often the difference between L1-resident and RAM-bound code. Osteon exposes cache control instructions directly.

### 2.1 Software Prefetch

```osteon
prefetch(hint)  src
```

| Hint | Meaning                          | x86-64     |
|------|----------------------------------|------------|
| `t0` | Prefetch into all cache levels   | prefetcht0 |
| `t1` | Prefetch into L2 and higher      | prefetcht1 |
| `t2` | Prefetch into L3 and higher      | prefetcht2 |
| `nta`| Non-temporal — minimize cache pollution | prefetchnta |

Prefetch 4–8 cache lines ahead of the current access in tight loops:

```osteon
for rcx = imm(0), imm(COUNT), imm(8) {
    prefetch(t0) deref(rdi, 256)     # prefetch 64 bytes ahead (4 cache lines)
    vload(f32, 8) ymm0, deref(rdi, 0)
    # ... process ymm0 ...
    add(u64) rdi, imm(32)
}
```

### 2.2 Non-Temporal Stores

Bypass the cache entirely when writing data you will never read back. Critical for bulk zeroing and streaming write patterns:

```osteon
ntstore(u64)  deref(rdi, 0), rax    # non-temporal store 64-bit
ntstore(f32)  deref(rdi, 0), xmm0   # non-temporal store scalar float

# non-temporal vector store:
vntstorea(f32, 8) deref(rdi, 0), ymm0   # requires 32-byte alignment
```

### 2.3 Memory Fences

```osteon
mfence    # full memory barrier — all loads and stores complete
lfence    # load fence — all prior loads complete before any future loads
sfence    # store fence — all prior stores complete before any future stores
```

`sfence` is required after a sequence of `ntstore` or `vntstorea` instructions to ensure visibility to other cores.

### 2.4 Cache Line Flush

```osteon
clflush   deref(rdi, 0)    # flush and invalidate cache line containing address
clflushopt deref(rdi, 0)   # optimized flush (weaker ordering, better throughput)
```

### 2.5 Compiler-Known Hardware Constants

```osteon
CACHE_LINE_SIZE   # 64 (x86-64 target)
L1_CACHE_SIZE     # target-dependent, from --target profile
SIMD_WIDTH        # widest SIMD register in bytes for target (16/32/64)
PAGE_SIZE         # OS page size (4096 on Windows/Linux)
```

Use instead of magic numbers:

```osteon
prefetch(t0) deref(rdi, imm(CACHE_LINE_SIZE * 4))
static_assert(SIZEOF_SOA(Particle, CAP) % CACHE_LINE_SIZE == 0,
              "SoA block must be cache-line aligned")
```

---

## 3. Atomic Operations

Lock-free data structures, reference counting, and cross-thread communication require atomic instructions. Osteon exposes these directly.

### 3.1 Lock-Prefixed Instructions

```osteon
lock add(type)     deref(addr, 0), src    # atomic add
lock sub(type)     deref(addr, 0), src    # atomic sub
lock and(type)     deref(addr, 0), src    # atomic AND
lock or(type)      deref(addr, 0), src    # atomic OR
lock xor(type)     deref(addr, 0), src    # atomic XOR
lock inc(type)     deref(addr, 0)         # atomic increment
lock dec(type)     deref(addr, 0)         # atomic decrement
lock xchg(type)    deref(addr, 0), reg    # atomic exchange — result in reg
lock cmpxchg(type) deref(addr, 0), reg    # compare and swap
                                           # compare rax with [addr]
                                           # if equal: store reg to [addr], ZF=1
                                           # if not:   load [addr] to rax, ZF=0
```

`lock cmpxchg` is the foundation of all lock-free algorithms:

```osteon
fn atomic_cas {
    let addr     = rdi    # u64* target address
    let expected = rsi    # u64 expected value → must be in rax
    let desired  = rdx    # u64 desired new value

    mov(u64) rax, expected
    lock cmpxchg(u64) deref(addr, 0), desired
    # ZF=1: swap succeeded, rax = old expected value
    # ZF=0: swap failed, rax = current value at addr
    ret
}
```

### 3.2 Memory Ordering

Memory fences from section 2.3 apply here. Additionally, `pause` is essential in spin-wait loops:

```osteon
pause    # hint to CPU that this is a spin-wait — reduces power and improves
         # performance when another thread holds a lock
```

Typical spin-wait pattern:

```osteon
fn spin_acquire {
    let lock = rdi

    label spin:
        lock cmpxchg(u32) deref(lock, 0), imm(1)
        jz      acquired
        pause               # spin hint
        jmp     spin

    label acquired:
        mfence              # acquire barrier
        ret
}
```

### 3.3 Static Analysis for Atomics

`warn/atomic_fence` — a `lock` instruction is followed immediately by a `ntstore` or `vntstorea` without an intervening `sfence`. Non-temporal stores can bypass the lock's memory ordering.

---

## 4. Bit Manipulation Intrinsics

These map to single instructions on modern x86-64. Compilers sometimes fail to emit them even when the pattern is obvious. In Osteon they're explicit.

```osteon
popcnt(type)  dst, src    # count set bits (POPCNT)
lzcnt(type)   dst, src    # leading zero count (LZCNT)
tzcnt(type)   dst, src    # trailing zero count (TZCNT / BSF)
bsr(type)     dst, src    # bit scan reverse — index of highest set bit
bsf(type)     dst, src    # bit scan forward — index of lowest set bit
bswap(type)   dst         # byte swap — endian flip (32/64-bit only)
```

Common uses in game engine code:

```osteon
# find next free slot in bitmask
fn find_free_slot {
    let mask = rdi    # u64 bitmask — 0 bit = free slot

    not(u64)  mask          # flip: 1 bit = free slot
    tzcnt(u64) rax, mask    # index of first free slot
    ret                     # rax = slot index, or 64 if all full
}

# fast log2 (floor)
fn fast_log2 {
    let val = rdi
    bsr(u64) rax, val       # index of highest set bit = floor(log2(val))
    ret
}

# population count for SIMD lane selection
fn active_lane_count {
    let mask = rdi
    popcnt(u64) rax, mask
    ret
}
```

---

## 5. Branch Hints

Static programmer assertions about expected branch behavior. Different from PGO — PGO reshapes layout based on measured data. Branch hints are declared intent about runtime behavior, encoded as instruction prefixes.

```osteon
likely   cmp(u64) rax, imm(0) / jnz hot_path
unlikely cmp(u64) rdx, imm(1) / je  error_path
```

`likely` emits the `0x3E` branch hint prefix (predict taken).
`unlikely` emits the `0x2E` branch hint prefix (predict not taken).

These compose with PGO — PGO does layout optimization, hints do per-branch prediction. Both can be present on the same branch.

```osteon
fn dispatch {
    let cmd = rdi

    likely   cmp(u64) cmd, imm(MAX_CMD) / jb  valid_cmd
    unlikely cmp(u64) cmd, imm(0)       / je  null_cmd

    label valid_cmd:
        # 99.9% of execution here
        ret

    label null_cmd:
        unreachable
}
```

---

## 6. Loop Unroll Hints

Unrolled loops reduce branch overhead and expose more instruction-level parallelism to the CPU. Osteon's `for` loop accepts an `unroll` modifier.

```osteon
for[unroll(N)] reg = start, end, step { ... }
```

The loop body is repeated N times before the counter check. The compiler emits the full unrolled expansion. If COUNT is not a multiple of N, the compiler appends a scalar cleanup loop automatically (visible in `--dry-run`).

```osteon
for[unroll(4)] rcx = imm(0), imm(COUNT), imm(1) {
    mov(u64) deref(rdi, 0), imm(0)
    add(u64) rdi, imm(8)
}
```

`--dry-run` expansion of `for[unroll(4)]`:

```osteon
# desugared for[unroll(4)] — main loop (4x unrolled):
    mov(u64) rcx, imm(0)
label __for_unroll_0_main:
    cmp(u64) rcx, imm(COUNT - 3)
    jge     __for_unroll_0_tail
    # iteration 0
    mov(u64) deref(rdi, 0), imm(0)
    add(u64) rdi, imm(8)
    # iteration 1
    mov(u64) deref(rdi, 0), imm(0)
    add(u64) rdi, imm(8)
    # iteration 2
    mov(u64) deref(rdi, 0), imm(0)
    add(u64) rdi, imm(8)
    # iteration 3
    mov(u64) deref(rdi, 0), imm(0)
    add(u64) rdi, imm(8)
    add(u64) rcx, imm(4)
    jmp     __for_unroll_0_main

label __for_unroll_0_tail:
    # scalar cleanup for remainder
    cmp(u64) rcx, imm(COUNT)
    jge     __for_unroll_0_end
    mov(u64) deref(rdi, 0), imm(0)
    add(u64) rdi, imm(8)
    inc(u64) rcx
    jmp     __for_unroll_0_tail

label __for_unroll_0_end:
```

`warn/unroll_remainder` fires if COUNT is a compile-time constant and not divisible by the unroll factor — indicating the tail loop will always execute.

---

## 7. Runtime CPU Feature Detection

Dispatch at runtime to different code paths based on actual CPU capabilities.

### 7.1 `cpuid` Instruction

```osteon
cpuid    # eax=leaf → eax/ebx/ecx/edx populated with feature info
```

The programmer sets `eax` (and optionally `ecx`) to the desired leaf before calling `cpuid`. The compiler provides named constants for feature bit positions:

```osteon
# CPUID leaf 1 — ECX feature bits
const CPUID_SSE42   = 1 << 20
const CPUID_AVX     = 1 << 28
const CPUID_F16C    = 1 << 29

# CPUID leaf 7 — EBX feature bits
const CPUID_AVX2    = 1 << 5
const CPUID_AVX512F = 1 << 16

# CPUID leaf 7 — ECX feature bits
const CPUID_AVX512VL = 1 << 31
```

### 7.2 Runtime Dispatch Example

```osteon
fn detect_and_dispatch {
    # query leaf 1
    mov(u32) eax, imm(1)
    cpuid

    # test for AVX
    test(u32) ecx, imm(CPUID_AVX)
    jnz      has_avx

    # fallback: SSE path
    call process_sse
    ret

    label has_avx:
        # query leaf 7 for AVX2
        mov(u32) eax, imm(7)
        xor(u32) ecx, ecx
        cpuid
        test(u32) ebx, imm(CPUID_AVX2)
        jnz      has_avx2
        call process_avx
        ret

    label has_avx2:
        call process_avx2
        ret
}
```

### 7.3 `warn/cpuid_unused`

Fires if `cpuid` is called but the result registers are never tested. Likely a programming error.

---

## 8. `noalias` Declarations

Declare that two pointers are guaranteed not to overlap. Emits no instructions — it's a programmer contract. Currently informational, informs future analysis passes, and documents intent clearly for LLMs.

```osteon
fn copy_buffer {
    let src = rdi   noalias    # src and dst guaranteed non-overlapping
    let dst = rsi   noalias

    for rcx = imm(0), rdx, imm(8) {
        mov(u64) rax, deref(src, 0)
        mov(u64) deref(dst, 0), rax
        add(u64) src, imm(8)
        add(u64) dst, imm(8)
    }
    ret
}
```

`warn/noalias_violation` fires (where statically provable) if two `noalias` pointers are derived from the same base.

---

## 9. Profile-Guided Layout Optimization

Osteon's PGO never changes which instructions execute. It only changes where they live in memory — hot blocks placed first, cold blocks moved to function tails, branch directions flipped for fall-through prediction. This is measurable and real: 5–15% on branch-heavy code with zero instruction-level changes.

### 9.1 Philosophy

> **Osteon PGO is layout-only. Instructions are yours. The compiler moves them, never substitutes them.**

This is consistent with "no optimizer" — the optimizer rule means no instruction substitution. Layout is a different concern entirely. The CPU's branch predictor and instruction cache both benefit from layout without any invisible semantic changes.

### 9.2 Three-Phase Workflow

**Phase 1 — Instrumented Build**

```bash
osteon --instrument program.ostn --out program_inst.exe
```

The compiler injects counter increments at every branch point and function entry. Counters live in a compiler-emitted static data block. `--dry-run --instrument` shows every injection point.

**Phase 2 — Profile Collection**

```bash
./program_inst.exe --osteon-profile=program.prof
```

The instrumented binary writes `program.prof` on exit — a flat binary array of u64 counters, one per instrumented site. Run with your real workload, not synthetic benchmarks.

**Phase 3 — Guided Build**

```bash
osteon --profile program.prof program.ostn --out program.exe
```

The compiler reads the profile and runs a layout pass (Pass 16) between inlining and encoding. Hot basic blocks are placed first. Cold blocks move to function tails. Branch directions flip where the fall-through path is more frequently taken.

### 9.3 `--dry-run` with Profile

`--dry-run --profile program.prof` shows the reordered layout with frequency annotations:

```osteon
# PGO layout — program.prof
# fn dispatch:
#   branch_0: taken=9821034 not_taken=142 (99.99% taken)
#   branch_1: taken=87 not_taken=9820989 (0.001% taken)

fn dispatch {
    cmp(u64) rax, imm(MAX_CMD)
    jb      cold_invalid_cmd    # flipped: hot path falls through
    # [HOT: 99.99%] — directly here, no branch taken
    imul(u64) rax, imm(8)
    add(u64)  rax, rdi
    jmp     deref(rax, 0)

    label cold_invalid_cmd:     # [COLD: 0.001%] — moved to tail
        unreachable
}
```

### 9.4 Layout Pass Details

Pass 16 (PGO Layout) performs:

- Sort basic blocks within each function by execution frequency (hot first)
- Flip branch conditions where the not-taken path is hotter (fall-through is faster)
- Move error paths, cold branches, and `unreachable` blocks to function tail
- Emit `nop` padding at hot loop entries for cache line alignment (when beneficial per profile)
- Insert `prefetch` hints before loops where profile shows predictable access patterns

### 9.5 PGO CLI Reference

```bash
osteon --instrument program.ostn                     # instrument only
osteon --instrument --dry-run program.ostn           # see injection points
osteon --profile program.prof program.ostn           # PGO build
osteon --profile program.prof --dry-run program.ostn # see reordered layout
osteon --profile program.prof --release program.ostn # PGO + release
```

### 9.6 Composing PGO with Vec and Cache Control

```osteon
fn particle_update {
    # PGO confirms this is the hottest function
    # Vec makes SIMD explicit
    # Cache control ensures data is ready

    for[unroll(2)] rcx = imm(0), imm(COUNT), imm(8) {
        prefetch(t0) deref(rdi, 256)
        prefetch(t0) deref(rsi, 256)

        vload(f32, 8)  ymm0, deref(rdi, 0)
        vload(f32, 8)  ymm1, deref(rsi, 0)
        vfma(f32, 8)   ymm0, ymm1, ymm2, ymm0
        vstorea(f32, 8) deref(rdi, 0), ymm0

        add(u64) rdi, imm(32)
        add(u64) rsi, imm(32)
    }
    ret
}
```

PGO confirms this loop is the hot path and places it at the function entry with optimal cache line alignment. Your manual SIMD runs in optimal cache conditions with zero compiler inference.

---

## Part 2: Memory Safety Features

---

## 10. The Safety Dial

Osteon treats memory safety as a dial, not a switch. Each level is a strict superset of the previous. You choose per build based on context.

```
--unsafe     Raw access. No safety checks. Maximum performance.
             (default — current behavior)

--check      Static analysis only. Existing passes plus
             extended provenance warnings.

--safe       Checked array access sugar. Stack canaries.
             Provenance tracking. Runtime overhead where opted in.

--sanitize   Full instrumentation. Shadow memory. All accesses
             checked. Debug and testing only. ~2x overhead.

--release    Strip assert/breakpoint. Keep expect/unreachable
             as ud2 traps. Combine with any safety level.
```

All safety features are transparent. Every check desugars visibly in `--dry-run`. Nothing is hidden.

---

## 11. Checked Array Access — `mova`

Bounds-checked memory access sugar. Desugars to a compare + trap before the actual access.

```osteon
mova(type)  dst, deref(base, idx, scale, offset), imm(count)
```

- `count` — array element count as a const expression.
- `idx` — the index being checked.
- Trap fires if `idx >= count`.

```osteon
fn safe_read {
    let arr   = rdi    # u32* array
    let idx   = rsi    # u64 index
    let count = rdx    # u64 count

    mova(u32) rax, deref(arr, idx, 4, 0), count
    ret
}
```

`--dry-run` desugaring:

```osteon
# desugared mova(u32) rax, deref(arr, idx, 4, 0), count:
cmp(u64)  idx, count
jb        __bounds_ok_0
# debug: emit "array out of bounds at safe_read:4" via RADDBG
ud2
label __bounds_ok_0:
mov(u32)  rax, deref(arr, idx, 4, 0)
```

The unchecked `mov` form always exists. `mova` is opt-in sugar for when you haven't validated bounds externally. In `--release` mode, `mova` checks are stripped — same as `assert`.

`warn/mova_redundant` fires if `idx` is a compile-time constant less than `count` — the check is provably unnecessary.

---

## 12. Stack Canaries

Detect stack buffer overflow before the return address is reached.

```osteon
canary          # place canary value on stack
check_canary    # verify before ret — trap if corrupted
```

`canary` is placed immediately after the stack frame is set up. `check_canary` is placed immediately before `ret`. Both are explicit — the programmer chooses where.

```osteon
fn handle_input {
    push(u64) rbp
    mov(u64)  rbp, rsp
    sub(u64)  rsp, imm(256)    # allocate local buffer
    canary                      # place canary

    # ... process untrusted input into local buffer ...

    check_canary                # verify before return
    add(u64)  rsp, imm(256)
    pop(u64)  rbp
    ret
}
```

`--dry-run` desugaring:

```osteon
# desugared canary (CANARY_VALUE = 0xA3F2C1D4B5E60789, generated per compilation):
mov(u64) deref(rbp, -8), imm(0xA3F2C1D4B5E60789)

# desugared check_canary:
cmp(u64) deref(rbp, -8), imm(0xA3F2C1D4B5E60789)
je       __canary_ok_0
# debug: emit "stack smash detected in handle_input" via RADDBG
ud2
label __canary_ok_0:
```

`CANARY_VALUE` is a per-compilation random constant. Different value every build — prevents attackers from knowing the canary. Stripped in `--release` when combined with `--unsafe`. Kept in `--safe` builds.

`warn/canary_missing` fires on any function that allocates more than 64 bytes on the stack without a `canary` declaration (in `--safe` mode only).

---

## 13. Pointer Provenance

Lightweight pointer origin tracking. Emits no instructions. Enables a new class of static warnings about dangerous pointer flows.

### 13.1 Provenance Declaration

```osteon
let name = reg  provenance(kind)
```

| Kind          | Meaning                                      |
|---------------|----------------------------------------------|
| `arena(name)` | Pointer came from this named arena           |
| `extern`      | Pointer came from outside — unknown origin   |
| `stack`       | Pointer into the current stack frame         |
| `static`      | Pointer to static data                       |
| `raw`         | Explicitly untracked — opt out of warnings   |

```osteon
fn process {
    let buf  = rdi  provenance(extern)           # caller-provided
    let tmp  = rax  provenance(arena(frame))     # from our arena
    let raw  = rcx  provenance(raw)              # untracked, intentional
}
```

### 13.2 Provenance Warnings

`warn/provenance_escape` — a shorter-lived provenance pointer flows into a longer-lived context. Classic dangling pointer risk:

```
warn/provenance_escape: arena(frame) pointer stored to extern location
  at process.ostn:14 — arena may reset after this function returns
  The pointer in rax (tmp) escapes into deref(rdi, 0) which has extern provenance
```

`warn/provenance_extern_deref` — dereferencing an `extern` pointer without a prior null check:

```
warn/provenance_extern_deref: reading deref(buf, 0) without null check
  buf (rdi) has extern provenance — caller may pass null
  Consider: test(u64) buf, buf / jnz safe_to_deref
```

`warn/provenance_stack_escape` — a `stack` provenance pointer is stored to a location that outlives the current function:

```
warn/provenance_stack_escape: stack pointer stored to extern location
  at process.ostn:22 — stack frame is invalid after ret
```

### 13.3 Provenance is Not a Borrow Checker

Provenance tracking does not prevent you from doing anything. It warns. The programmer decides whether the warning is relevant. This keeps Osteon writable by LLMs — the LLM can respond to the `correction` field in the JSON output and add a null check or change provenance to `raw` explicitly.

---

## 14. `--sanitize` Mode — Full Instrumentation

A debug/testing build flag that instruments every memory access against a shadow memory region. Catches use-after-free, heap overflow, stack overflow, and use of uninitialized memory at runtime with precise error reporting.

```bash
osteon --sanitize program.ostn --out program_san.exe
```

### 14.1 Shadow Memory Model

Every byte of addressable memory has a corresponding shadow byte. The shadow byte encodes validity:

```
0x00 = valid, accessible
0xFA = heap redzone
0xFB = heap freed
0xFC = stack redzone
0xFD = global redzone
0xFE = uninitialized
```

The shadow map lives at a fixed offset from the real address:

```
shadow_addr = (real_addr >> 3) + SHADOW_OFFSET
```

`SHADOW_OFFSET` is platform-specific and embedded in the instrumented binary.

### 14.2 Instrumented Access

Every `deref` access is wrapped with a shadow check:

```osteon
# original:
mov(u64) rax, deref(rdi, 0)

# sanitized:
mov(u64) r11, rdi
shr(u64) r11, imm(3)
add(u64) r11, imm(SHADOW_OFFSET)
cmp(u8)  deref(r11, 0), imm(0)
jne     __san_report_0          # report if shadow byte nonzero
mov(u64) rax, deref(rdi, 0)    # original access
```

`__san_report_0` calls a runtime reporting routine that prints:

```
OSTEON SANITIZER: invalid memory access
  address: 0x00007FF9A3C10040
  shadow:  0xFB (heap use after free)
  at:      process.ostn:14  fn handle_input
  stack:   ...
```

### 14.3 What `--sanitize` Catches

| Bug Class              | Detected |
|------------------------|----------|
| Heap buffer overflow   | Yes      |
| Stack buffer overflow  | Yes      |
| Use after free         | Yes      |
| Use after arena reset  | Yes      |
| Out of bounds read     | Yes      |
| Out of bounds write    | Yes      |
| Uninitialized read     | Yes      |
| Null pointer deref     | Yes      |

### 14.4 Sanitizer Overhead

Approximately 2x slowdown and 8x memory overhead (shadow map). Acceptable for testing. Never use in production.

### 14.5 Combining Flags

```bash
# development: full checking
osteon --sanitize --safe program.ostn

# testing: sanitizer only
osteon --sanitize program.ostn

# production: no checks, maximum speed
osteon --release --unsafe program.ostn

# production: keep expect/unreachable traps
osteon --release --safe program.ostn
```

---

## Part 3: New Error Codes

### Performance Errors

| Code                    | Severity | Description                                              |
|-------------------------|----------|----------------------------------------------------------|
| `fatal/vec_align`       | fatal    | `vloada`/`vstorea` on provably unaligned pointer         |
| `warn/vec_width`        | warn     | Vector wider than target ISA supports                    |
| `warn/cpuid_unused`     | warn     | `cpuid` result registers never tested                    |
| `warn/atomic_fence`     | warn     | `lock` instruction followed by `ntstore` without `sfence`|
| `warn/unroll_remainder` | warn     | Loop count not divisible by unroll factor                |
| `warn/noalias_violation`| warn     | Two `noalias` pointers derived from same base            |

### Memory Safety Errors

| Code                          | Severity | Description                                        |
|-------------------------------|----------|----------------------------------------------------|
| `warn/mova_redundant`         | warn     | Bounds check provably unnecessary                  |
| `warn/canary_missing`         | warn     | Large stack allocation without canary (--safe)     |
| `warn/provenance_escape`      | warn     | Shorter-lived pointer flows to longer-lived context|
| `warn/provenance_extern_deref`| warn     | Extern pointer dereferenced without null check     |
| `warn/provenance_stack_escape`| warn     | Stack pointer stored beyond function lifetime      |

---

## Part 4: Updated Analysis Pass Table

| Pass | Name                      | Errors Produced                       |
|------|---------------------------|---------------------------------------|
| 1    | Syntax validation         | `fatal/syntax`                        |
| 2    | Import resolution         | `fatal/import`, `fatal/undef`         |
| 3    | Namespace resolution      | `fatal/namespace`, `fatal/undef`      |
| 4    | Const evaluation          | `fatal/undef`, `fatal/assert`         |
| 5    | Struct layout check       | `fatal/layout`                        |
| 6    | Desugaring                | (transforms AST)                      |
| 7    | Inlining                  | (transforms AST)                      |
| 8    | Arena scratch alloc       | `fatal/arena`                         |
| 9    | Vec width check           | `fatal/vec_align`, `warn/vec_width`   |
| 10   | Width consistency         | `fatal/width`                         |
| 11   | Uninit register reads     | `fatal/uninit`                        |
| 12   | Dead instruction          | `warn/dead`                           |
| 13   | Unreachable code          | `warn/unreachable`                    |
| 14   | Clobber analysis          | `warn/clobber`                        |
| 15   | Noalias check             | `warn/noalias_violation`              |
| 16   | Provenance tracking       | `warn/provenance_*`                   |
| 17   | Atomic fence check        | `warn/atomic_fence`                   |
| 18   | Canary check (--safe)     | `warn/canary_missing`                 |
| 19   | Noret check               | `hint/noret`                          |
| 20   | Breakpoint check          | `hint/breakpoint`                     |
| 21   | PGO layout (--profile)    | (transforms block ordering)           |
| 22   | Sanitizer inject (--san)  | (transforms all deref accesses)       |

---

## Part 5: Updated Compiler Module Layout

```
compiler/
├── main.odin
├── lexer.odin
├── parser.odin
├── ast.odin
├── import.odin
├── namespace.odin
├── const_eval.odin
├── layout.odin
├── desugar.odin              # for/while/assert/expect/arena/mova/canary
├── inline.odin
├── analysis.odin             # passes 9–20
├── pgo/
│   ├── instrument.odin       # --instrument injection
│   ├── profile.odin          # .prof read/write
│   └── layout.odin           # pass 21: block reordering
├── sanitizer/
│   ├── shadow.odin           # shadow memory map
│   └── instrument.odin       # pass 22: deref wrapping
├── error.odin
├── encoder/
│   ├── encoder.odin
│   ├── x86_64.odin           # scalar + SIMD encoding
│   ├── arm64.odin            # future
│   └── wasm32.odin           # future
└── emit/
    ├── coff.odin
    ├── elf.odin               # future
    └── raddbg.odin
```

---

## Part 6: Complete Feature Reference

### Build Flags Added

```
--instrument          Inject profiling counters
--profile <file>      Use profile for layout optimization
--sanitize            Full shadow memory instrumentation
--safe                Enable safe-mode checks (mova, canary, provenance)
--unsafe              Disable all safety checks (default)
--release             Strip assert/breakpoint, keep expect/unreachable
```

### New Instruction Keywords

```
# Vectors
vload vloada vstore vstorea
vadd vsub vmul vdiv vfma vsqrt vabs vmin vmax
vbroadcast vshuffle vpermute vcmp
vmaskedload vmaskedstore vblend vblendv
vhsum vhmax vhmin vcvt
vntstorea

# Cache
prefetch ntstore clflush clflushopt
mfence lfence sfence

# Atomics
lock pause

# Bit manipulation
popcnt lzcnt tzcnt bsr bsf bswap

# Branch hints
likely unlikely

# CPU detection
cpuid

# Safety
mova canary check_canary
```

### New Modifiers

```
let name = reg  noalias          # non-aliasing declaration
let name = reg  provenance(kind) # pointer provenance
for[unroll(N)]                   # loop unroll hint
```

### New Constants

```
CACHE_LINE_SIZE
L1_CACHE_SIZE
SIMD_WIDTH
PAGE_SIZE
CPUID_SSE42
CPUID_AVX
CPUID_AVX2
CPUID_AVX512F
CPUID_AVX512VL
CPUID_F16C
```

---

## Part 7: Composition Example — Full Performance Stack

This example shows all performance features composing together in a realistic particle simulation hot path:

```osteon
namespace sim

import "structs/particle.ostn"

const CAP        = 8192
const BLOCK_SIZE = SIZEOF_SOA(Particle, CAP)

static_assert(BLOCK_SIZE % CACHE_LINE_SIZE == 0,
              "SoA block must be cache-line aligned")
static_assert(SIMD_WIDTH >= 32,
              "This path requires AVX (256-bit SIMD)")

fn update_sim {
    let pos  = rdi  noalias  provenance(arena(sim_arena))
    let vel  = rsi  noalias  provenance(arena(sim_arena))
    let dt   = xmm0          # f32 scalar delta time

    vbroadcast(f32, 8) ymm15, xmm0    # broadcast dt to all lanes

    # main SIMD loop — 8 particles per iteration, unrolled 2x
    for[unroll(2)] rcx = imm(0), imm(CAP), imm(8) {
        # prefetch 8 cache lines ahead
        prefetch(t0) deref(pos, 256)
        prefetch(t0) deref(vel, 256)

        # load 8 positions and velocities
        vloada(f32, 8) ymm0, deref(pos, 0)
        vloada(f32, 8) ymm1, deref(vel, 0)

        # pos += vel * dt (fused multiply-add)
        vfma(f32, 8) ymm0, ymm1, ymm15, ymm0

        # streaming store — we won't read pos back this frame
        vntstorea(f32, 8) deref(pos, 0), ymm0

        add(u64) pos, imm(32)
        add(u64) vel, imm(32)
    }

    sfence    # ensure streaming stores are visible
    ret
}
```

With `--profile sim.prof`, PGO confirms `update_sim` is the hottest function and places it at the top of the `.text` section with optimal cache line alignment. With `--safe`, provenance tracking verifies the pointers don't escape their arena. With `--sanitize` during testing, every `vloada` access is validated against shadow memory.

---

## Version History

| Version | Document                           | Notes                              |
|---------|------------------------------------|------------------------------------|
| 1.0.0   | Perf & Memory Safety Expansion     | Vec abstraction, cache control,    |
|         |                                    | atomics, bit ops, branch hints,    |
|         |                                    | loop unroll, CPUID dispatch,       |
|         |                                    | noalias, PGO layout, mova,         |
|         |                                    | stack canaries, provenance,        |
|         |                                    | --sanitize mode                    |

---

*Osteon — bone-level code.*