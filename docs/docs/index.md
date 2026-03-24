# Osteon Compiler

A register-based, low-level programming language compiler targeting x86-64 PE32+ and COFF.

## Architecture

The compiler pipeline consists of the following phases:

```
Source (.ostn)
    |
    v
Lexer (lexer.odin)
    |
    v
Parser (parser.odin) --> AST (ast.odin)
    |
    v
Const Eval (const_eval.odin)
    |
    v
Layout (layout.odin)
    |
    v
Desugar (desugar.odin)
    |
    v
x86-64 Encoder (x86_64.odin)
    |
    +---> PE32+ Executable (pe32.odin)
    +---> COFF Object (coff.odin)
```

## Modules

> **199** documented API items across **15** source files

| Module | Description | Items |
|--------|-------------|-------|
| [Main](modules/main.md) | Main entry point, compilation passes, and CLI handling. | 0 |
| [Lexer](modules/lexer.md) | Tokenizes source code into a stream of tokens. | 16 |
| [Parser](modules/parser.md) | Parses token streams into an Abstract Syntax Tree. | 29 |
| [AST](modules/ast.md) | All AST node types, enums, unions, and structs. | 42 |
| [Errors](modules/error.md) | Error codes, severity levels, and diagnostic output. | 12 |
| [x86_64](modules/x86_64.md) | Encodes AST into x86-64 machine code bytes. | 5 |
| [PE32+](modules/pe32.md) | Generates PE32+ Windows executable files. | 13 |
| [COFF](modules/coff.md) | Generates COFF object files with symbol tables. | 22 |
| [Desugar](modules/desugar.md) | Transforms structured control flow into raw instructions. | 17 |
| [Const Eval](modules/const_eval.md) | Evaluates constant expressions at compile time. | 12 |
| [Layout](modules/layout.md) | Computes struct field offsets and AoS/SoA layouts. | 6 |
| [Width](modules/width.md) | Validates instruction width consistency. | 10 |
| [ModR/M](modules/modrm.md) | Encodes ModR/M, SIB, and REX prefix bytes. | 6 |
| [Namespace](modules/namespace.md) | Resolves package names and detects collisions. | 5 |
| [Import](modules/import.md) | Loads and resolves imported packages. | 3 |
| [Docs](modules/docs.md) | Index of all public API items in the compiler. | 1 |

## Repository

[GitHub](https://github.com/tantalumv/Osteon)