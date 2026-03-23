# Osteon

**Osteon** is a structured assembly language with a type-aware, human-readable syntax. It is designed for systems programmers who need assembly-level control without the noise of raw assembly, and for LLM agents that require an unambiguous format to generate correct machine code.

Osteon is "bone-level" code: what you write maps 1:1 to machine instructions. There is no hidden stack management, no garbage collector, and no implicit calling convention.

## Key Features

- **Explicit Machine State:** Every instruction is visible. Sugar (like loops and arenas) desugars transparently via `--dry-run`.
- **DOD-First:** Native support for **SoA (Struct of Arrays)** layouts and **Arena Allocation** with inline bump-pointer arithmetic.
- **LLM-First Design:** Compiler errors provide exact "Correction" fields and JSON output to enable autonomous agent self-correction.
- **Static Analysis Pipeline:** Advanced checks for clobbering, uninitialized register reads, unreachable code, and width inconsistencies.
- **Arch-Agnostic Source:** The same `.ostn` source is valid across targets, with the compiler handling the heavy lifting of encoding (currently targeting x86-64).

## Getting Started

### Prerequisites

- [Odin Compiler](https://odin-lang.org/) (for building the Osteon compiler).
- [Just](https://github.com/casey/just) (optional task runner).

### Installation

```bash
# Clone the repository
git clone https://github.com/your-repo/osteon.git
cd osteon

# Build the compiler
just build
# OR
odin build compiler -out:osteon.exe
```

### Running Your First Program

```bash
# Compile and run an example (Windows x64)
./osteon.exe examples/hello.ostn
./hello.exe
```

## Language at a Glance

### Syntax
```osteon
fn add_nums {
    let a = rcx      # Register aliases
    let b = rdx
    add(u64) a, b    # Explicit width annotations
    mov(u64) rax, a
    ret
}
```

### SoA & Arenas
```osteon
layout(soa) struct Particle {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
}

fn update {
    arena pool = init(rdi, imm(1024))
    alloc(pool, imm(SIZEOF_SOA(Particle, 100)), imm(64))
    let pts = rax
    
    for rcx = imm(0), imm(100), imm(1) {
        # Loop body with transparent desugaring
    }
    ret
}
```

## Compiler CLI

| Flag | Description |
|------|-------------|
| `--check` | Validate syntax and logic without emitting code. |
| `--dry-run` | Show fully desugared/inlined source. |
| `--release` | Strip `assert` and `breakpoint` instructions. |
| `--json` | Output errors in machine-readable JSON format. |
| `--debug` | Emit RADDBG debug information. |
| `--explain <CODE>` | Get a plain-English explanation of an error code. |

## Project Structure

- `compiler/`: The Osteon compiler implementation (Odin).
- `docs/`: Detailed language and performance specifications.
- `examples/`: Sample `.ostn` programs demonstrating features.
- `tests/`: Comprehensive test suite (valid and invalid cases).
- `ml/`: Experimental integration for LLM sidecars and local models.

## Development

Use the provided `justfile` for common development tasks:

```bash
just build    # Build the compiler
just test     # Run the test suite
just clean    # Remove build artifacts
```

## License

[Insert License Information Here]
