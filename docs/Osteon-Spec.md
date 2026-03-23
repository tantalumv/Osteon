# Osteon Language Specification
**Version:** 0.3.0 (Draft)
**Author:** Osteon Project
**Status:** Pre-implementation

---

## 1. Overview

Osteon is a structured assembly language with a type-aware, human-readable syntax designed for two audiences: human systems programmers who want assembly-level control without raw assembly's noise, and LLM agents that need an unambiguous, parseable instruction format to generate correct low-level code.

Osteon is **not** a high-level language. There is no garbage collector, no implicit stack management, no hidden calling convention. What you write is what executes. Every instruction maps 1:1 to a machine instruction. All sugar constructs desugar transparently and are visible via `--dry-run`.

### Design Principles

- **Explicit over implicit.** If it affects machine state, you write it.
- **Parens mean explicitness.** All metadata — widths, addresses, immediates, layouts — lives in parentheses.
- **Sugar is visible.** Every desugaring is inspectable via `--dry-run`. Nothing hides.
- **LLM-first error design.** Compiler output enables agent self-correction loops without human intervention.
- **Arch-agnostic source.** The same `.ostn` source is valid for any target.
- **No optimizer.** What you wrote is what runs.

### What Osteon Is Not

Osteon is not competing with Zig or Odin for application-level code. It is the layer *below* them — the thing you reach for when writing hot functions, syscall wrappers, SIMD kernels, allocators, or bootloader routines where you need the LLM to generate correct, verifiable machine-level code.

---

## 2. File Format

```
program.ostn          # source
program.obj         # COFF object (Windows)
program.o           # ELF object (Linux, future)
program.exe         # PE32+ executable (Windows)
program.raddbg      # RADDBG debug info
```

Files are UTF-8 encoded. Line endings are LF or CRLF.

---

## 3. Namespacing

### 3.1 Automatic Namespace

By default, every `.ostn` file is automatically namespaced by its filename (without extension). All symbols defined in `entity.ostn` are accessible as `entity::symbol_name` from other files.

```
entity.ostn       → namespace entity
transform.ostn    → namespace transform
arena.ostn        → namespace arena
```

Within the file itself, symbols are referenced without the namespace prefix. External files must use the fully qualified name.

```osteon
# entity.ostn
fn get_health {
    # referenced as entity::get_health from outside
    ret
}
```

```osteon
# main.ostn
import "entity.ostn"

fn entry {
    call entity::get_health
    ret
}
```

### 3.2 Explicit Namespace Override

The automatic filename namespace can be overridden with an explicit declaration at the top of the file. The explicit namespace replaces the filename namespace entirely.

```osteon
namespace physics

# all symbols in this file are now physics::symbol_name
fn integrate {
    ret
}
```

### 3.3 Namespace Rules

- Namespace names follow identifier rules: `[a-zA-Z_][a-zA-Z0-9_]*`
- Namespaces are flat — no nesting, no hierarchical paths.
- Two files with the same resolved namespace name is a `fatal/namespace` error.
- `extern` declarations are not namespaced — they resolve to raw linker symbols.
- `inline fn` definitions are resolved at compile time and never emit a namespaced symbol.
- Object file symbol names are mangled as `namespace__symbol` (double underscore).

### 3.4 Importing Namespaces

```osteon
import "path/to/file.ostn"            # import and use as file::symbol
import "path/to/file.ostn" as ent     # import and use as ent::symbol
```

The `as` alias renames the namespace for the current file only. It does not affect object file symbol mangling.

---

## 4. Lexical Structure

### 4.1 Comments

```osteon
# line comment
mov(u64) rax, rbx   # inline comment
```

### 4.2 Keywords

```
fn  inline  label  extern  import  as  namespace
section  static  global  const  struct  layout  data  let
for  while  arena  alloc  reset
unreachable  breakpoint
assert  static_assert  expect
result
```

### 4.3 Integer Literals

```osteon
42      0xFF    0b1010    0o17
```

### 4.4 Float Literals

```osteon
3.14    1.0e-5    0.5
```

Used in `data` declarations for `f32`/`f64` fields only.

### 4.5 String Literals

```osteon
"hello world\n\0"
```

Standard C escape sequences. Null terminator is explicit.

---

## 5. Type System

Width types only. No compound types at the instruction level.

| Type | Width  | Description            |
|------|--------|------------------------|
| u8   | 8-bit  | byte                   |
| u16  | 16-bit | word                   |
| u32  | 32-bit | doubleword             |
| u64  | 64-bit | quadword               |
| f32  | 32-bit | single-precision float |
| f64  | 64-bit | double-precision float |

---

## 6. Registers

### 6.1 x86-64 General Purpose

| 64-bit | 32-bit   | 16-bit   | 8-bit low |
|--------|----------|----------|-----------|
| rax    | eax      | ax       | al        |
| rbx    | ebx      | bx       | bl        |
| rcx    | ecx      | cx       | cl        |
| rdx    | edx      | dx       | dl        |
| rsi    | esi      | si       | sil       |
| rdi    | edi      | di       | dil       |
| rsp    | esp      | sp       | spl       |
| rbp    | ebp      | bp       | bpl       |
| r8–r15 | r8d–r15d | r8w–r15w | r8b–r15b  |

### 6.2 Special and SIMD

```
rip  rflags
xmm0–xmm15   ymm0–ymm15   zmm0–zmm31
```

### 6.3 Register Aliases

```osteon
let name = register
```

Per-function compile-time names. Emit no instructions. Appear in all error messages and `--dry-run` output.

```osteon
fn process {
    let src    = rdi
    let count  = rsi
    let result = rax
    ret
}
```

---

## 7. Compile-Time Constants

```osteon
const NAME = expr
```

Full arithmetic and bitwise const expressions evaluated entirely at compile time.

```osteon
const PAGE_SIZE     = 4096
const PAGE_MASK     = PAGE_SIZE - 1
const CACHE_LINE    = 64
const MAX_ENTITIES  = 1024
```

### 7.1 Const Operators

`+  -  *  /  %  <<  >>  &  |  ^  ~`

### 7.2 Const Intrinsics

```osteon
SIZEOF(Type)                           # byte size of type
ALIGNOF(Type)                          # alignment in bytes
SIZEOF_SOA(Type, capacity)             # byte size of full SoA block
@offset(Type, field)                   # byte offset of field in AoS struct
@soa_offset(Type, field, capacity)     # byte offset of field array in SoA block
```

---

## 8. Structs

Structs define memory layout only. No methods, no runtime presence, no implicit padding.

### 8.1 AoS (Array of Structs) — Default

```osteon
struct Entity {
    id:       u64,
    position: u64,
    health:   u32,
    flags:    u16,
    _pad:     u16,
}
```

Padding fields prefixed with `_` are explicit. The compiler emits `fatal/layout` if a field would naturally misalign without an explicit pad.

### 8.2 SoA (Struct of Arrays) — DOD Layout

```osteon
layout(soa) struct Entity {
    id:       u64,
    position: u64,
    health:   u32,
    flags:    u16,
}
```

`layout(soa)` tells the compiler this struct is intended as a Struct of Arrays. The struct describes per-element field types and names. The compiler generates SoA-aware offset intrinsics.

For a capacity of N elements, the SoA memory block is laid out as:

```
[ id[0..N] ][ position[0..N] ][ health[0..N] ][ flags[0..N] ]
```

Use `@soa_offset(Entity, field, capacity)` to get the byte offset of each field array within the block:

```osteon
const CAP            = 1024
const ID_OFF         = @soa_offset(Entity, id,       CAP)   # 0
const POSITION_OFF   = @soa_offset(Entity, position, CAP)   # 8192
const HEALTH_OFF     = @soa_offset(Entity, health,   CAP)   # 16384
const FLAGS_OFF      = @soa_offset(Entity, flags,    CAP)   # 20480
const BLOCK_SIZE     = SIZEOF_SOA(Entity, CAP)
```

**Accessing SoA fields:**

```osteon
fn get_health_soa {
    let base = rdi    # pointer to SoA block
    let idx  = rsi    # element index

    imul(u64) idx, imm(SIZEOF(u32))
    add(u64)  idx, imm(HEALTH_OFF)
    mov(u32)  rax, deref(base, idx, 1, 0)
    ret
}
```

`--dry-run` resolves all `@soa_offset` and `SIZEOF_SOA` calls to their final integer values.

### 8.3 Layout Validation

```osteon
static_assert(SIZEOF(Entity) == 24, "Entity layout changed")
static_assert(@offset(Entity, health) == 16, "health field moved")
static_assert(SIZEOF_SOA(Entity, 1024) == 24576, "SoA block size changed")
```

### 8.4 Mixed AoS and SoA

Both layout modes can coexist in the same file. The layout attribute is per-struct.

```osteon
struct Transform {              # AoS — single instances
    x: f32,
    y: f32,
    z: f32,
    w: f32,
}

layout(soa) struct Particle {   # SoA — large homogeneous arrays
    x:        f32,
    y:        f32,
    z:        f32,
    lifetime: f32,
    flags:    u32,
}
```

---

## 9. Static Data

```osteon
data name: type = value
static data name: type = value    # translation-unit scope only
```

**Scalars:**
```osteon
data version: u32 = 2
data pi:      f64 = 3.14159265358979
```

**Arrays:**
```osteon
data masks:  u32[] = [0xFF, 0xFF00, 0xFF0000, 0xFF000000]
```

**Strings:**
```osteon
data hello: u8[] = "hello world\n\0"
```

**Struct instances:**
```osteon
data default_entity: Entity = {
    id:       0,
    position: 0,
    health:   100,
    flags:    0,
    _pad:     0,
}
```

Data declarations are namespaced like functions.

---

## 10. Arena Allocation

Arena allocation is a language construct. The compiler emits bump pointer arithmetic inline and visibly. Everything it generates appears in `--dry-run` output.

### 10.1 Declaration

```osteon
arena name = init(buf, size)
```

- `buf` — register or alias holding a pointer to the backing buffer.
- `size` — const expression for the buffer size in bytes.

Emits no instructions. Declares a named arena handle. The compiler assigns one scratch register per active arena to track the bump pointer. This scratch register is reported in `--dry-run`.

### 10.2 `alloc`

```osteon
alloc(arena_name, size, align)
```

Result pointer in `rax`. Advances the bump pointer. Overflow check emits `ud2` on failure.

`--dry-run` desugaring of `alloc(frame, imm(64), imm(8))`:

```osteon
# desugared alloc(frame, imm(64), imm(8)):
# bump pointer in r11 (compiler-assigned scratch)
add(u64) r11, imm(7)             # round up for align=8
and(u64) r11, imm(~7)            # mask to alignment
mov(u64) rax, r11                # result = current bump
add(u64) r11, imm(64)            # advance bump
cmp(u64) r11, imm(FRAME_END)     # overflow check
ja      __arena_overflow          # ud2 if exceeded
```

### 10.3 `reset`

```osteon
reset(arena_name)
```

Resets bump pointer to base. Emits a single `mov`.

`--dry-run` desugaring:

```osteon
# desugared reset(frame):
mov(u64) r11, rdi    # restore bump to base
```

### 10.4 Arena Rules

- Arena handles are scoped to the function they are declared in.
- One scratch register is allocated per active arena.
- If no scratch register is available: `fatal/arena`.
- The backing buffer is the programmer's responsibility.

### 10.5 DOD + Arena Composition

SoA structs and arenas compose naturally. Allocate a SoA block from an arena:

```osteon
const CAP        = 1024
const BLOCK_SIZE = SIZEOF_SOA(Particle, CAP)

fn init_particles {
    let buf = rdi

    arena pool = init(buf, imm(BLOCK_SIZE * 4))
    alloc(pool, imm(BLOCK_SIZE), imm(ALIGNOF(Particle)))
    let pts = rax

    for rcx = imm(0), imm(CAP), imm(1) {
        imul(u64) rcx, imm(SIZEOF(f32))
        mov(f32) deref(pts, @soa_offset(Particle, x, CAP)), imm(0)
        mov(f32) deref(pts, @soa_offset(Particle, y, CAP)), imm(0)
        mov(f32) deref(pts, @soa_offset(Particle, z, CAP)), imm(0)
    }
    ret
}
```

---

## 11. Result Type and Error Handling

Two mechanisms: compile-time assertions and a runtime Result convention. Both are transparent.

### 11.1 Result Convention

`result(type)` is a two-register return contract:

```
rax = value   (on success)
rdx = error   (0 = ok, nonzero = error code)
```

A *contract annotation* only — emits no code. Documents intent and enables `expect` at call sites.

```osteon
fn divide {
    let num = rdi
    let den = rsi

    test(u64) den, den
    jnz      ok
    mov(u64) rdx, imm(1)    # err: divide by zero
    xor(u64) rax, rax
    ret

    label ok:
        xor(u64) rdx, rdx   # no error
        mov(u64) rax, num
        div(u64) den
        ret
}
```

### 11.2 `expect`

Checks `rdx` after a call. Traps on nonzero. Emits `test rdx + jz + ud2` inline.

```osteon
fn caller {
    mov(u64) rdi, imm(10)
    mov(u64) rsi, imm(5)
    call    divide
    expect("divide failed")
    # rax = result here
    ret
}
```

`--dry-run` desugaring:

```osteon
# desugared expect("divide failed"):
test(u64) rdx, rdx
jz       __expect_ok_0
# debug: emit message via RADDBG
ud2
label __expect_ok_0:
```

### 11.3 Runtime `assert`

```osteon
assert(cmp(u64) rax, imm(0), jnz, "rax must be nonzero")
```

Syntax: `assert(cmp_instr, jump_if_ok, message)`

`--dry-run` desugaring:

```osteon
# desugared assert:
cmp(u64) rax, imm(0)
jnz      __assert_ok_0
# debug: emit message via RADDBG
ud2
label __assert_ok_0:
```

Stripped entirely in `--release` builds.

### 11.4 `static_assert` (Compile-Time)

```osteon
static_assert(SIZEOF(Entity) == 24, "Entity layout changed")
```

Produces `fatal/assert` at compile time if false. Emits no instructions. Never stripped.

### 11.5 Error Handling Summary

| Construct       | When         | Emits          | Release build   |
|-----------------|--------------|----------------|-----------------|
| `static_assert` | Compile time | Nothing        | N/A             |
| `assert`        | Runtime      | cmp + ud2      | Stripped        |
| `expect`        | After call   | test + ud2     | Kept (ud2 only) |
| `unreachable`   | Explicit     | ud2            | Kept            |
| `breakpoint`    | Debug pause  | int3           | Stripped        |

---

## 12. Functions

### 12.1 Regular Functions

```osteon
fn name { ... }
static fn name { ... }    # translation-unit scope only
```

No implicit prologue, epilogue, or calling convention. Namespaced by file.

### 12.2 Inline Functions

```osteon
inline fn name { ... }
```

Pasted at every call site at compile time. Emits no symbol. Never namespaced.

---

## 13. Structured Control Flow

### 13.1 While

```osteon
while cmp(u64) rcx, imm(0) / jnz {
    sub(u64) rcx, imm(1)
}
```

### 13.2 For (Counted Iteration)

```osteon
for rcx = imm(0), imm(16), imm(1) {
    # body
}
```

Both desugar to labels and jumps. `--dry-run` shows full expansion. Named loops via `for[label]` for explicit break targets.

---

## 14. Developer Intrinsics

```osteon
breakpoint      # int3 — stripped in release
unreachable     # ud2  — kept in release
```

---

## 15. Imports

```osteon
import "path/file.ostn"
import "path/file.ostn" as alias
```

Import rules:
- Paths relative to source file directory.
- Circular imports → `fatal/import`.
- Diamond imports deduplicated by resolved path.
- `inline fn` and `const` resolve at compile time.
- `fn` and `data` symbols resolve via linker as `namespace::name`.

---

## 16. Calling Conventions

Osteon enforces no calling convention. When interfacing with C, Zig, Odin, or Rust you must manually comply with the platform ABI.

### Microsoft x64 (Windows)

```
Arguments:    rcx, rdx, r8, r9 — rest on stack
Return:       rax
Callee-save:  rbx, rbp, rdi, rsi, r12–r15, xmm6–xmm15
Shadow space: 32 bytes allocated before any call
Alignment:    16-byte stack at point of call
```

### System V AMD64 (Linux)

```
Arguments:    rdi, rsi, rdx, rcx, r8, r9 — rest on stack
Return:       rax
Callee-save:  rbx, rbp, r12–r15
Alignment:    16-byte stack at point of call
```

---

## 17. Compiler CLI

```
osteon [options] <file.ostn>

Options:
  --target <arch-os>    x86_64-windows, x86_64-linux, wasm32-wasi
  --emit <format>       obj, exe (default: exe)
  --out <path>          Output path
  --release             Strip assert/breakpoint, keep expect/unreachable as ud2
  --check               Validate only. No output. Exit 0 = clean.
  --dry-run             Show fully desugared/inlined/resolved source. No output.
  --debug               Emit RADDBG debug info
  --explain <CODE>      Plain-English description of error code
  --json                Errors as JSON to stderr
  --no-color            Disable ANSI color
```

---

## 18. Error System

### 18.1 Error Codes

| Code                | Severity | Description                                             |
|---------------------|----------|---------------------------------------------------------|
| `fatal/width`       | fatal    | Instruction width conflicts with register width         |
| `fatal/uninit`      | fatal    | Register read before write on this path                 |
| `fatal/syntax`      | fatal    | Malformed instruction or unexpected token               |
| `fatal/undef`       | fatal    | Undefined label, const, struct, extern, or namespace    |
| `fatal/assert`      | fatal    | `static_assert` evaluated false at compile time         |
| `fatal/import`      | fatal    | Circular import or unresolvable path                    |
| `fatal/layout`      | fatal    | Struct field misaligned without explicit pad            |
| `fatal/namespace`   | fatal    | Two files resolve to the same namespace name            |
| `fatal/arena`       | fatal    | No scratch register available for arena bump pointer    |
| `warn/dead`         | warn     | Write to register or alias never subsequently read      |
| `warn/unreachable`  | warn     | Instruction follows ret or unconditional jmp            |
| `warn/clobber`      | warn     | Live register may be stomped at call site               |
| `hint/noret`        | hint     | Function has no ret on some paths                       |
| `hint/breakpoint`   | hint     | breakpoint present in non-debug build                   |

### 18.2 Annotated Source Output

```
program.ostn:8:5
  6 │  fn bad_example {
  7 │      mov(u64) rax, rbx
  8 │      mov(u64) eax, rbx   ← fatal/width: eax is 32-bit; instruction width is u64
  |                               Correction: mov(u32) eax, ebx
  9 │      ret
 10 │  }
```

### 18.3 JSON Error Output

```json
{
  "file": "program.ostn",
  "line": 8,
  "col": 5,
  "code": "fatal/width",
  "message": "eax is 32-bit; instruction width is u64",
  "correction": "mov(u32) eax, ebx",
  "alias": null,
  "context": {
    "before": ["mov(u64) rax, rbx"],
    "offending": "mov(u64) eax, rbx",
    "after": ["ret"]
  }
}
```

The `alias` field is populated when the offending operand has a register alias:

```json
{
  "code": "warn/dead",
  "message": "write to arr (rdi) never read before ret",
  "alias": { "name": "arr", "register": "rdi" }
}
```

---

## 19. Static Analysis Passes

| Pass | Name                  | Errors Produced                    |
|------|-----------------------|------------------------------------|
| 1    | Syntax validation     | `fatal/syntax`                     |
| 2    | Import resolution     | `fatal/import`, `fatal/undef`      |
| 3    | Namespace resolution  | `fatal/namespace`, `fatal/undef`   |
| 4    | Const evaluation      | `fatal/undef`, `fatal/assert`      |
| 5    | Struct layout check   | `fatal/layout`                     |
| 6    | Desugaring            | (transforms AST)                   |
| 7    | Inlining              | (transforms AST)                   |
| 8    | Arena scratch alloc   | `fatal/arena`                      |
| 9    | Width consistency     | `fatal/width`                      |
| 10   | Uninit register reads | `fatal/uninit`                     |
| 11   | Dead instruction      | `warn/dead`                        |
| 12   | Unreachable code      | `warn/unreachable`                 |
| 13   | Clobber analysis      | `warn/clobber`                     |
| 14   | Noret check           | `hint/noret`                       |
| 15   | Breakpoint check      | `hint/breakpoint`                  |

Passes 9–15 run on the fully desugared, fully inlined AST. Analysis always sees actual instructions.

---

## 20. LLM Agent Integration

### Workflow

```
1. LLM receives task + Osteon spec in system prompt
2. LLM emits .ostn source
3. osteon --check --json source.ostn
4. If errors:
     a. Feed JSON + annotated source back to LLM
     b. LLM applies correction field exactly
     c. Return to step 3
5. osteon --dry-run source.ostn
     a. LLM verifies desugared output matches intent
6. osteon source.ostn
```

### System Prompt Snippet

```
You are writing Osteon assembly (version 0.3). Core rules:

SYNTAX:
- Registers: raw — rax, rdi, xmm0
- Memory:    deref(base, offset) or deref(base, index, scale, offset)
- Immediates: imm(value) or imm(CONST_NAME)
- Widths:    mov(u64), add(u32) — must match register width exactly
- Labels:    label name:
- Functions: fn name { ... }
- Namespace: namespace::symbol for cross-file references
- Aliases:   let name = reg (scoped to function)
- Comments:  # text

FEATURES:
- Constants:   const NAME = expr (SIZEOF, ALIGNOF, @offset, @soa_offset, SIZEOF_SOA)
- Structs:     struct Name { field: type } or layout(soa) struct Name { ... }
- Data:        data name: type = value
- Inline:      inline fn name { ... } (pasted, not called)
- Loops:       for reg = start, end, step { } or while cond/jcc { }
- Arena:       arena name = init(buf, size) then alloc(name, size, align) / reset(name)
- Result:      result(type) — rax=value rdx=error two-register convention
- Assert:      assert(cmp, jcc, msg) — runtime, stripped in --release
- Expect:      expect(msg) — checks rdx after call, ud2 on failure
- Intrinsics:  static_assert, unreachable, breakpoint

ERRORS:
- Apply the correction field exactly
- Run --dry-run to verify loop/inline/arena expansion
- fatal/ blocks compilation. warn/ and hint/ do not.

No calling convention is enforced. You manage registers yourself.
```

---

## 21. Object File and Debug Emission

### Windows (Primary)

| Output    | Format  |
|-----------|---------|
| `.obj`    | COFF    |
| `.exe`    | PE32+   |
| `.raddbg` | RADDBG  |

### Linux (Future)

| Output    | Format  |
|-----------|---------|
| `.o`      | ELF64   |
| `.raddbg` | RADDBG  |

### WASM (Future — Stack Dialect)

| Output    | Format |
|-----------|--------|
| `.wasm`   | WASM   |

### Interoperability

```odin
// Odin
foreign import lib "program.obj"

// Zig
exe.addObjectFile(.{ .path = "program.obj" })

// Rust build.rs
println!("cargo:rustc-link-lib=static=program");
```

---

## 22. Grammar (EBNF)

```ebnf
program         := namespace_decl? top_level*

namespace_decl  := 'namespace' identifier

top_level       := import_decl | const_decl | struct_decl
                 | data_decl | extern_decl | fn_decl
                 | inline_fn_decl | assert_stmt

import_decl     := 'import' string_lit ('as' identifier)?
const_decl      := 'const' identifier '=' const_expr
extern_decl     := 'extern' identifier

struct_decl     := layout_mod? 'struct' identifier '{' field_decl* '}'
layout_mod      := 'layout' '(' 'soa' ')'
field_decl      := identifier ':' type ','

data_decl       := 'static'? 'data' identifier ':' type ('[]')? '=' data_value

fn_decl         := 'static'? 'fn' identifier '{' fn_body '}'
inline_fn_decl  := 'inline' 'fn' identifier '{' fn_body '}'

fn_body         := fn_stmt*
fn_stmt         := let_decl | label_decl | arena_decl
                 | instruction | alloc_stmt | reset_stmt
                 | for_loop | while_loop | assert_stmt
                 | expect_stmt | 'breakpoint' | 'unreachable'
                 | inline_call

let_decl        := 'let' identifier '=' register
label_decl      := 'label' identifier ':'
arena_decl      := 'arena' identifier '=' 'init' '(' operand ',' const_expr ')'
alloc_stmt      := 'alloc' '(' identifier ',' const_expr ',' const_expr ')'
reset_stmt      := 'reset' '(' identifier ')'

for_loop        := 'for' ('[' identifier ']')? operand '=' operand ','
                    operand ',' operand '{' fn_body '}'
while_loop      := 'while' instruction '/' jump_cc '{' fn_body '}'

assert_stmt     := 'assert' '(' instruction ',' jump_cc ',' string_lit ')'
                 | 'static_assert' '(' const_expr (',' string_lit)? ')'
expect_stmt     := 'expect' '(' string_lit ')'
inline_call     := identifier

instruction     := opcode type_ann? operand (',' operand)*
type_ann        := '(' type ')'
type            := 'u8'|'u16'|'u32'|'u64'|'f32'|'f64'
operand         := register | alias | deref_expr | imm_expr | qualified_name
deref_expr      := 'deref' '(' operand ',' const_expr
                    (',' operand ',' const_expr ',' const_expr)? ')'
imm_expr        := 'imm' '(' const_expr ')'
qualified_name  := identifier ('::' identifier)?

const_expr      := integer | float | identifier | qualified_name
                 | 'SIZEOF'      '(' identifier ')'
                 | 'ALIGNOF'     '(' identifier ')'
                 | 'SIZEOF_SOA'  '(' identifier ',' const_expr ')'
                 | '@offset'     '(' identifier ',' identifier ')'
                 | '@soa_offset' '(' identifier ',' identifier ',' const_expr ')'
                 | const_expr binop const_expr
                 | unop const_expr
                 | '(' const_expr ')'

binop           := '+'|'-'|'*'|'/'|'%'|'<<'|'>>'|'&'|'|'|'^'
unop            := '-'|'~'
```

---

## 23. Example Programs

### 23.1 SoA Particle Update with Arena

```osteon
namespace particles

import "structs/particle.ostn"

const CAP        = 4096
const BLOCK_SIZE = SIZEOF_SOA(Particle, CAP)

static_assert(BLOCK_SIZE % 64 == 0, "Block size must be cache-line aligned")

fn update_positions {
    let buf = rdi
    let dt  = xmm0     # f32 delta time

    arena pool = init(buf, imm(BLOCK_SIZE))
    alloc(pool, imm(BLOCK_SIZE), imm(ALIGNOF(Particle)))
    let pts = rax

    for rcx = imm(0), imm(CAP), imm(1) {
        imul(u64) rcx, imm(SIZEOF(f32))
        movss(f32) xmm1, deref(pts, @soa_offset(Particle, x,  CAP))
        movss(f32) xmm2, deref(pts, @soa_offset(Particle, vx, CAP))
        mulss(f32) xmm2, dt
        addss(f32) xmm1, xmm2
        movss(f32) deref(pts, @soa_offset(Particle, x, CAP)), xmm1
    }
    ret
}
```

### 23.2 Result + Expect

```osteon
namespace math

fn safe_div {
    let num = rdi
    let den = rsi

    test(u64) den, den
    jnz      ok
    mov(u64) rdx, imm(1)     # err: divide by zero
    xor(u64) rax, rax
    ret

    label ok:
        xor(u64) rdx, rdx
        mov(u64) rax, num
        div(u64) den
        ret
}

fn caller {
    mov(u64) rdi, imm(100)
    mov(u64) rsi, imm(5)
    call math::safe_div
    expect("safe_div failed")
    # rax = 20
    ret
}
```

### 23.3 Cross-Namespace Usage

```osteon
# main.ostn
import "math.ostn"
import "particles.ostn" as pts

fn entry {
    call math::safe_div
    call pts::update_positions
    ret
}
```

### 23.4 DOD + Arena + Assert

```osteon
namespace sim

import "structs/particle.ostn"

const MAX  = 1024
const SIZE = SIZEOF_SOA(Particle, MAX)

static_assert(SIZE % 64 == 0, "SoA block must be cache-line aligned")

fn init_sim {
    let mem = rdi

    arena pool = init(mem, imm(SIZE * 2))
    alloc(pool, imm(SIZE), imm(64))
    assert(cmp(u64) rax, imm(0), jnz, "particle alloc failed")
    let pts = rax

    for rcx = imm(0), imm(MAX), imm(1) {
        imul(u64) rcx, imm(SIZEOF(f32))
        mov(f32) deref(pts, @soa_offset(Particle, x, MAX)), imm(0)
        mov(f32) deref(pts, @soa_offset(Particle, y, MAX)), imm(0)
        mov(f32) deref(pts, @soa_offset(Particle, z, MAX)), imm(0)
    }
    ret
}
```

---

## 24. Compiler Implementation (Odin)

```
compiler/
├── main.odin           # entry point, CLI
├── lexer.odin          # tokenizer
├── parser.odin         # token stream → AST
├── ast.odin            # all AST type definitions
├── import.odin         # import resolution + deduplication
├── namespace.odin      # namespace resolution + symbol mangling
├── const_eval.odin     # compile-time const expression evaluator
├── layout.odin         # AoS and SoA struct layout computation
├── desugar.odin        # for/while/assert/expect/arena → instructions
├── inline.odin         # inline fn expansion
├── analysis.odin       # passes 9–15
├── error.odin          # annotated source, JSON, --explain
├── encoder/
│   ├── encoder.odin    # target dispatch
│   ├── x86_64.odin     # x86-64 encoding
│   ├── arm64.odin      # arm64 (future)
│   └── wasm32.odin     # WASM stack dialect (future)
└── emit/
    ├── coff.odin        # COFF/PE writer
    ├── elf.odin         # ELF writer (future)
    └── raddbg.odin      # RADDBG debug info writer
```

### Core AST Types

```odin
Instr :: struct {
    op:            Opcode,
    width:         Maybe(Width),
    operands:      [4]Operand,
    operand_count: int,
    src_loc:       Src_Loc,
}

Operand :: union {
    Register,
    Alias,          // { name: string, reg: Register }
    Immediate,      // { value: i64 }
    Mem_Ref,        // { base, index, scale, offset }
    Label_Ref,      // { name: string }
    Qual_Ref,       // { namespace, name: string }
}

Const_Expr :: union {
    i64,
    f64,
    Sizeof_Expr,        // { type_name: string }
    Alignof_Expr,       // { type_name: string }
    Sizeof_Soa_Expr,    // { type_name: string, capacity: ^Const_Expr }
    Offset_Expr,        // { type_name, field_name: string }
    Soa_Offset_Expr,    // { type_name, field_name: string, capacity: ^Const_Expr }
    Binop_Expr,         // { op, lhs, rhs: ^Const_Expr }
    Unop_Expr,          // { op, operand: ^Const_Expr }
    Const_Ref,          // { name: string }
}

Struct_Def :: struct {
    name:   string,
    layout: Layout_Kind,   // .aos | .soa
    fields: []Struct_Field,
    size:   int,
    align:  int,
}

Arena_Handle :: struct {
    name:      string,
    base_reg:  Register,
    bump_reg:  Register,   // compiler-assigned scratch
    size:      i64,
    src_loc:   Src_Loc,
}
```

---

## 25. Version History

| Version | Status     | Notes                                                         |
|---------|------------|---------------------------------------------------------------|
| 0.1.0   | Superseded | Core instructions only                                        |
| 0.2.0   | Superseded | Constants, structs, data, inline fns, imports, aliases,       |
|         |            | for/while sugar, intrinsics, full analysis pipeline           |
| 0.3.0   | Draft      | Namespacing (auto + explicit), DOD SoA layout,                |
|         |            | arena allocation, Result convention, runtime assert/expect,   |
|         |            | --release mode, pass 8 arena scratch alloc, WASM planned      |

---

*Osteon — bone-level code.*