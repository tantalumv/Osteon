# Osteon Compiler — Status Report
**Date:** 2026-03-23
**Version:** v0.3.0
**Platform:** Windows x64, Odin nightly (dev-2026-03-nightly:6d9a611)

---

## What Osteon Is

Osteon is a structured assembly language compiler for x86-64 Windows. It takes `.ostn` source files through a full compiler pipeline (lexer → parser → semantic analysis → desugaring → encoding → binary emission) and produces either:

- **`--emit obj`** — COFF object files (linkable with `link.exe`)
- **`--emit exe`** — PE32+ executables (runnable Windows .exe files)

The language combines the explicitness of assembly with structured control flow, compile-time safety checks, and SIMD abstraction.

---

## What Osteon Can Do Right Now

### Write programs that run on Windows

```
$ osteon --emit exe my_program.ostn
PE32+: my_program.exe (512 .text, entry=my_program__main)
$ ./my_program.exe; echo $?
42
```

The compiler takes source code through all 15 analysis passes, encodes x86-64 instructions, and emits a runnable Windows executable. The entry function's return value (rax) becomes the process exit code.

### Full language specification (100%)

Every language feature in the v0.3.0 spec is implemented:

| Feature | Status |
|---------|--------|
| Functions (`fn`, `inline fn`) | ✅ |
| Registers (all GPRs, xmm0-15, ymm0-15) | ✅ |
| Let aliases (`let src = rdi`) | ✅ |
| Labels (`label foo:`) | ✅ |
| Control flow (`for`, `while`, `for[label]`, `for[unroll(N)]`) | ✅ |
| Imports (`import "pkg" as alias`) | ✅ |
| Namespaces (`namespace foo`) | ✅ |
| Structs (AoS and SoA layout) | ✅ |
| Static data (`data`, `static data`) | ✅ |
| Constants (`const`) | ✅ |
| Extern declarations | ✅ |
| Arena memory (`arena`, `alloc`, `reset`) | ✅ |
| Safety (`assert`, `static_assert`, `expect`, `result`) | ✅ |
| `breakpoint`, `unreachable` | ✅ |
| Const expressions (SIZEOF, ALIGNOF, @offset, comparisons) | ✅ |
| `section`, `global fn/data` | ✅ |
| Noalias / provenance annotations | ✅ (parse + store) |

### x86-64 instruction set (~90 mnemonics)

**Base instructions (45+):**
- ALU: `add`, `sub`, `xor`, `and`, `or`, `cmp`, `test`
- Multiply/divide: `mul`, `imul`, `div`, `not`, `neg`
- Shift/rotate: `shl`, `shr`, `sar`, `rol`, `ror`
- Increment: `inc`, `dec`
- Data movement: `mov`, `lea`, `push`, `pop`
- Control flow: `jmp`, `call`, `ret`, all Jcc (jo, jno, jb, jnb, jz, jnz, je, jne, jbe, ja, js, jns, jp, jnp, jl, jge, jle, jg)
- System: `syscall`, `nop`, `int3`, `ud2`
- SSE scalar: `movss`, `addss`, `subss`, `mulss`, `divss`, `movsd`, `addsd`, `subsd`, `mulsd`, `divsd`

**Performance expansion (20+):**
- Bit manipulation: `popcnt`, `lzcnt`, `tzcnt`, `bsr`, `bsf`, `bswap`
- Cache: `prefetch(t0/t1/t2/nta)`, `mfence`, `lfence`, `sfence`, `clflush`
- Atomics: `lock` prefix (works with any ALU on memory), `xchg`, `cmpxchg`
- Branch hints: `likely`, `unlikely` prefixes
- CPU detection: `cpuid`, `pause`

**SIMD/AVX (20+):**
- Load/store: `vload`, `vloada`, `vstore`, `vstorea`, `vntstorea`
- Arithmetic: `vaddps`, `vsubps`, `vmulps`, `vdivps`
- Min/max: `vminps`, `vmaxps`
- Sqrt: `vsqrtps`
- FMA: `vfmadd132ps`, `vfmadd213ps`, `vfmadd231ps`, `vfma`
- Broadcast: `vbroadcastss`
- Compare: `vcmpps`
- Blend: `vblendv`
- Shuffle/permute: `vshufps`, `vpermps`
- Conversion: `vcvtss2sd`, `vcvtsd2ss`, `vcvttps2dq`, `vcvtdq2ps`
- Bitwise: `vandps`, `vorps`
- Reduction: `vhsumps` (synthesized)

### Desugaring (structured → raw instructions)

| Construct | Desugars to |
|-----------|------------|
| `for` loop | `mov` + `cmp` + `jge` + body + `add` + `jmp` + labels |
| `while` loop | `cmp` + inverse `jcc` + body + `jmp` |
| `for[unroll(N)]` | N body copies per iteration + scalar tail |
| `assert` | `test`/`cmp` + `jcc` + `ud2` |
| `expect` | `test rdx, rdx` + `jnz` + `ud2` |
| `mova` | `cmp` + `jb` + `ud2` + `mov` (bounds-checked access) |
| `canary` | `mov deref(rbp, -8), imm(CANARY_VALUE)` |
| `check_canary` | `cmp` + `je` + `ud2` |
| `arena` init | `mov` + `add` + `and` (bump pointer setup) |
| `alloc` | `add` + `and` + `cmp` + `jbe` + `ud2` (overflow check) |

### Analysis passes (15)

| Pass | Code | Severity | Description |
|------|------|----------|------------|
| 1-5 | Import/Namespace/Const/Layout | Fatal | Module resolution, type layout |
| 6 | Desugaring | — | Structured → raw |
| 7 | Inline expansion | — | Inline fn body at call sites |
| 8 | Alias resolution | — | `let x = rdi` → rewrite `x` to `rdi` |
| 9 | Width check | `fatal/width` | Register width consistency |
| 10 | Uninit | `fatal/uninit` | Register read before write |
| 11 | Dead code | `warn/dead` | Code after unconditional jump |
| 12 | Unreachable | `warn/unreachable` | Instruction after `ret`/`jmp`/`ud2` |
| 13 | Clobber | `warn/clobber` | Caller-saved register not saved |
| 14 | Noret | `hint/noret` | Function missing `ret` |
| 15 | Breakpoint | `hint/breakpoint` | `int3` in non-debug build |

### Error engine

- 17 error codes (fatal/warn/hint)
- Annotated source output with caret
- JSON mode (`--json`)
- Correction hints (e.g., `vabs` error includes copy-paste fix)
- `--explain <code>` for plain English descriptions
- Color output (disable with `--no-color`)

### Binary emission

**COFF (.obj):**
- `.text` + `.data` sections
- Symbol table with string table (>8 byte names)
- Cross-function relocations (IMAGE_REL_AMD64_REL32)
- Array and struct data serialization

**PE32+ (.exe):**
- DOS header, COFF header, PE32+ Optional Header
- `.text` + `.data` sections with proper alignment
- Entry stub: `sub rsp, 0x28; call main; add rsp, 0x28; ret`
- Exit code = return value from `main`

### Test infrastructure

**`--check`:** Compile-time validation (all 15 passes)
**`--dry-run`:** Print desugared + resolved AST
**`--test`:** Compile + run + verify exit codes
```
$ osteon --test tests/exe
PASS  add_nums.30.ostn (exit 30)
PASS  exit_0.0.ostn (exit 0)
PASS  exit_42.42.ostn (exit 42)
Passed: 6, Failed: 0
```

**Test files:**
- `tests/valid/` — 8 check-mode tests
- `tests/invalid/` — 4 error-mode tests
- `tests/exe/` — 6 runtime tests (exit codes)

---

## What Osteon Is NOT Ready For

| Feature | Status | Why |
|---------|--------|-----|
| PE32+ ExitProcess import | Not working | PE loader rejects import table format — needs native Windows PE debugging |
| RADDBG debug info | Not started | Depends on PE32+ import table |
| ML sidecar | Spec written (v1.1) | Architecture updated: GGUF + ObjectBox C — ready to implement |
| --sanitize shadow memory | Flags parsed | Shadow memory infrastructure needed |
| noalias/provenance enforcement | Annotations stored | Analysis pass not implemented |
| AVX-512 | Deferred | Requires EVEX encoding + k-registers |

---

## Design Decisions

### "Every instruction maps to one machine instruction"
Osteon does NOT silently synthesize multi-instruction sequences. `vabs` produces a compile error with a correction snippet, not hidden VANDPS + broadcast. The programmer sees exactly what executes.

### "Direct x86 names, no abstraction layer"
`vshufps`, not `vshuffle`. The programmer chooses the instruction. The `--explain` flag documents what each instruction does.

### "Safety is explicit"
`canary` and `check_canary` are placed by the programmer, not auto-inserted. `--safe` warns about missing canaries but doesn't add them. Silent behavior changes are prohibited.

---

## Performance Spec Coverage

| Part | Coverage |
|------|----------|
| 1. Vec abstraction | ~85% |
| 2. Cache control | 100% |
| 3. Atomics | 100% |
| 4. Bit manipulation | 100% |
| 5. Branch hints | 100% |
| 6. Loop unroll | 100% |
| 7. CPUID | 100% |
| 8. noalias | Parse only |
| 9. PGO layout | Not started |
| 10-14. Safety features | Desugaring + flags, analysis TBD |

**Overall: ~70%** (encoding and desugaring done, analysis pass extensions pending)

---

## ML Infrastructure (Pre-implementation)

### Models (downloaded)
- `ml/models/qwen3.5-4b/Qwen3.5-4B-IQ4_XS.gguf` — correction/intent/pattern (~2GB)
- `ml/models/jina-code-1.5b/jina-code-embeddings-1.5b-IQ4_XS.gguf` — embedding (~600MB)

### Vector Database
- **ObjectBox C** (v5.2.0, downloaded) — embedded ACID DB with vector search
- Entity schema: `Code_Embedding` with 512-dim HNSW index (cosine similarity)
- Database location: `ml/models/objectbox/embeddings.mdb` (auto-created on first run)

### Sidecar Architecture
- **Language:** C (not Python — no dependency chain)
- **Dependencies:** llama.cpp (GGUF inference), ObjectBox C (vector storage)
- **Binary:** `osteon-ml.exe`, ~3-5 MB static-linked
- **IPC:** JSON over stdin/stdout with timeout fallback
- **Spec:** `docs/Osteon-ml-spec.md` v1.1.0

---

## Stats

| Metric | Value |
|--------|-------|
| Total instruction mnemonics | ~90 |
| Total error codes | 17 |
| Analysis passes | 15 |
| Source files | 10 |
| Compiler LOC | ~5500 |
| Tests | 18 (8 check + 4 error + 6 runtime) |
| Builds on | Odin 2026 nightly |
| Platform | Windows x64 |

---

## Source Files

| File | LOC | Purpose |
|------|-----|---------|
| `main.odin` | ~870 | CLI, pipeline, analysis passes, test runner |
| `lexer.odin` | ~210 | Tokenizer |
| `parser.odin` | ~950 | Recursive descent parser |
| `ast.odin` | ~310 | AST types, 22 statement types |
| `x86_64.odin` | ~2050 | Encoder, VEX infrastructure, instruction dispatch |
| `modrm.odin` | ~80 | ModR/M, SIB, REX encoding |
| `coff.odin` | ~420 | COFF .obj emitter |
| `pe32.odin` | ~210 | PE32+ .exe emitter |
| `desugar.odin` | ~480 | Structured → raw instruction desugaring |
| `error.odin` | ~190 | Error engine, JSON output |
