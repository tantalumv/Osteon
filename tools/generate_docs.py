#!/usr/bin/env python3
"""
Generate MkDocs markdown documentation from Natural Docs comments in .odin files.

Scans src/compiler/*.odin for comments in the format:
  // Keyword: Name
  // Description line
  //
  // Parameters:
  //   param - description
  //
  // Returns: description

Produces markdown files suitable for MkDocs + Material theme.
"""

import os
import re
import sys
from pathlib import Path
from collections import defaultdict

SRC_DIR = Path("src/compiler")
OUT_DIR = Path("docs")
MKDOCS_OUT = OUT_DIR / "docs"

# Map source files to nice section titles
FILE_SECTIONS = {
    "main.odin": (
        "Main",
        "Entry Point and Compilation Pipeline",
        "Main entry point, compilation passes, and CLI handling.",
    ),
    "lexer.odin": (
        "Lexer",
        "Lexical Analysis",
        "Tokenizes source code into a stream of tokens.",
    ),
    "parser.odin": (
        "Parser",
        "Syntax Analysis",
        "Parses token streams into an Abstract Syntax Tree.",
    ),
    "ast.odin": (
        "AST",
        "Abstract Syntax Tree Types",
        "All AST node types, enums, unions, and structs.",
    ),
    "error.odin": (
        "Errors",
        "Error Reporting Engine",
        "Error codes, severity levels, and diagnostic output.",
    ),
    "x86_64.odin": (
        "x86_64",
        "x86-64 Machine Code Encoder",
        "Encodes AST into x86-64 machine code bytes.",
    ),
    "pe32.odin": (
        "PE32+",
        "PE32+ Executable Emitter",
        "Generates PE32+ Windows executable files.",
    ),
    "coff.odin": (
        "COFF",
        "COFF Object File Emitter",
        "Generates COFF object files with symbol tables.",
    ),
    "desugar.odin": (
        "Desugar",
        "Desugaring Pass",
        "Transforms structured control flow into raw instructions.",
    ),
    "const_eval.odin": (
        "Const Eval",
        "Compile-Time Evaluation",
        "Evaluates constant expressions at compile time.",
    ),
    "layout.odin": (
        "Layout",
        "Struct Layout Resolution",
        "Computes struct field offsets and AoS/SoA layouts.",
    ),
    "width.odin": (
        "Width",
        "Width Consistency Checking",
        "Validates instruction width consistency.",
    ),
    "modrm.odin": (
        "ModR/M",
        "ModR/M and REX Encoding",
        "Encodes ModR/M, SIB, and REX prefix bytes.",
    ),
    "namespace.odin": (
        "Namespace",
        "Package Namespace Resolution",
        "Resolves package names and detects collisions.",
    ),
    "import.odin": (
        "Import",
        "Package Import Loading",
        "Loads and resolves imported packages.",
    ),
    "docs.odin": (
        "Docs",
        "API Reference Index",
        "Index of all public API items in the compiler.",
    ),
}


def parse_comments(filepath):
    """Parse Natural Docs comments from an .odin file."""
    with open(filepath, "r", encoding="utf-8") as f:
        lines = f.readlines()

    comments = []
    i = 0
    while i < len(lines):
        line = lines[i].rstrip()

        # Check if this line starts a Natural Docs comment
        m = re.match(
            r"^\s*//\s*(Function|Type|Constant|Variable|Namespace):\s*(.+)", line
        )
        if m:
            keyword = m.group(1)
            name = m.group(2).strip()
            raw_lines = [line]

            # Collect continuation lines (all following lines starting with //)
            j = i + 1
            while j < len(lines):
                next_line = lines[j].rstrip()
                if re.match(r"^\s*//", next_line):
                    raw_lines.append(next_line)
                    j += 1
                elif next_line.strip() == "":
                    # Check if next non-empty line is still a comment
                    k = j + 1
                    while k < len(lines) and lines[k].strip() == "":
                        k += 1
                    if k < len(lines) and re.match(r"^\s*//", lines[k]):
                        # Blank line within comment block
                        raw_lines.append("//")
                        j = k
                    else:
                        break
                else:
                    break

            comment = parse_comment_body(keyword, name, raw_lines)
            comment["file"] = filepath.name
            comments.append(comment)
            i = j
        else:
            i += 1

    return comments


def parse_comment_body(keyword, name, raw_lines):
    """Parse the body of a Natural Docs comment into structured data."""
    desc_lines = []
    params = []
    returns = ""
    in_params = False

    for raw_line in raw_lines:
        # Strip the // prefix
        stripped = re.sub(r"^\s*//\s?", "", raw_line)
        stripped = stripped.rstrip()

        if stripped == "":
            continue

        if stripped.lower().startswith("parameters:") or stripped.lower().startswith(
            "params:"
        ):
            in_params = True
            continue

        if stripped.lower().startswith("returns:"):
            in_params = False
            returns = stripped[len("Returns:") :].strip()
            continue

        if stripped.lower().startswith("fields:"):
            in_params = True
            continue

        if stripped.lower().startswith("variants:"):
            in_params = False
            continue

        if in_params:
            # Parse "param_name - description" or "  param_name - description"
            pm = re.match(r"^\s*(\S+)\s*-\s*(.*)", stripped)
            if pm:
                params.append((pm.group(1), pm.group(2)))
            else:
                # Continuation of previous param
                if params:
                    params[-1] = (params[-1][0], params[-1][1] + " " + stripped)
        else:
            desc_lines.append(stripped)

    return {
        "keyword": keyword,
        "name": name,
        "description": " ".join(desc_lines),
        "params": params,
        "returns": returns,
    }


def generate_markdown(comments_by_file, filename, title, subtitle, description):
    """Generate a markdown file for a section."""
    lines = []
    lines.append(f"# {title}")
    lines.append("")
    lines.append(f"*{subtitle}*")
    lines.append("")
    lines.append(description)
    lines.append("")
    lines.append("---")
    lines.append("")

    comments = comments_by_file.get(filename, [])

    # Group by keyword type
    groups = defaultdict(list)
    for c in comments:
        groups[c["keyword"]].append(c)

    keyword_order = ["Function", "Type", "Constant", "Variable", "Namespace"]
    keyword_labels = {
        "Function": "Functions",
        "Type": "Types",
        "Constant": "Constants",
        "Variable": "Variables",
        "Namespace": "Namespaces",
    }

    for kw in keyword_order:
        items = groups.get(kw, [])
        if not items:
            continue

        lines.append(f"## {keyword_labels[kw]}")
        lines.append("")

        for item in items:
            anchor = item["name"].replace(" ", "-").replace("::", "").lower()
            lines.append(f"### `{item['name']}` {{#{anchor}}}")
            lines.append("")

            if item["description"]:
                lines.append(item["description"])
                lines.append("")

            if item["params"]:
                lines.append("| Parameter | Description |")
                lines.append("|-----------|-------------|")
                for pname, pdesc in item["params"]:
                    lines.append(f"| `{pname}` | {pdesc} |")
                lines.append("")

            if item["returns"]:
                lines.append(f"**Returns:** {item['returns']}")
                lines.append("")

            lines.append("---")
            lines.append("")

    return "\n".join(lines)


def generate_index(all_comments):
    """Generate the main index page."""
    lines = []
    lines.append("# Osteon Compiler")
    lines.append("")
    lines.append(
        "A register-based, low-level programming language compiler targeting x86-64 PE32+ and COFF."
    )
    lines.append("")
    lines.append("## Architecture")
    lines.append("")
    lines.append("The compiler pipeline consists of the following phases:")
    lines.append("")
    lines.append("```")
    lines.append("Source (.ostn)")
    lines.append("    |")
    lines.append("    v")
    lines.append("Lexer (lexer.odin)")
    lines.append("    |")
    lines.append("    v")
    lines.append("Parser (parser.odin) --> AST (ast.odin)")
    lines.append("    |")
    lines.append("    v")
    lines.append("Const Eval (const_eval.odin)")
    lines.append("    |")
    lines.append("    v")
    lines.append("Layout (layout.odin)")
    lines.append("    |")
    lines.append("    v")
    lines.append("Desugar (desugar.odin)")
    lines.append("    |")
    lines.append("    v")
    lines.append("x86-64 Encoder (x86_64.odin)")
    lines.append("    |")
    lines.append("    +---> PE32+ Executable (pe32.odin)")
    lines.append("    +---> COFF Object (coff.odin)")
    lines.append("```")
    lines.append("")
    lines.append("## Modules")
    lines.append("")

    # Stats
    total_items = 0
    for fname, items in all_comments.items():
        total_items += len(items)
    lines.append(
        f"> **{total_items}** documented API items across **{len(all_comments)}** source files"
    )
    lines.append("")

    lines.append("| Module | Description | Items |")
    lines.append("|--------|-------------|-------|")

    for filename, (short, title, desc) in FILE_SECTIONS.items():
        count = len(all_comments.get(filename, []))
        link = f"[{short}](modules/{filename.replace('.odin', '')}.md)"
        lines.append(f"| {link} | {desc} | {count} |")

    lines.append("")
    lines.append("## Repository")
    lines.append("")
    lines.append("[GitHub](https://github.com/tantalumv/Osteon)")

    return "\n".join(lines)


def main():
    # Parse all .odin files
    all_comments = {}
    for filepath in sorted(SRC_DIR.glob("*.odin")):
        comments = parse_comments(filepath)
        if comments:
            all_comments[filepath.name] = comments

    print(
        f"Parsed {sum(len(v) for v in all_comments.values())} comments from {len(all_comments)} files"
    )

    # Create output directories
    modules_dir = MKDOCS_OUT / "modules"
    modules_dir.mkdir(parents=True, exist_ok=True)

    # Generate index
    index_md = generate_index(all_comments)
    with open(MKDOCS_OUT / "index.md", "w", encoding="utf-8") as f:
        f.write(index_md)
    print("Generated index.md")

    # Generate per-file pages
    for filename, (short, title, desc) in FILE_SECTIONS.items():
        md = generate_markdown(
            all_comments, filename, title, f"Source: src/compiler/{filename}", desc
        )
        out_name = filename.replace(".odin", ".md")
        with open(modules_dir / out_name, "w", encoding="utf-8") as f:
            f.write(md)
        count = len(all_comments.get(filename, []))
        print(f"  Generated {out_name} ({count} items)")

    print("Done!")


if __name__ == "__main__":
    main()
