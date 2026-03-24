# Package Import Loading

*Source: src/compiler/import.odin*

Loads and resolves imported packages.

---

## Functions

### `load_all_packages` {#load_all_packages}

Function: load_all_packages Entry point for package loading. Initializes namespace resolution and recursively loads the main file and all its transitive imports. Returns all loaded packages collected from the global registry.

---

### `load_package_recursive` {#load_package_recursive}

Function: load_package_recursive Performs a DFS load of a source file and all its imports. Uses the call stack for circular import detection and a visited map for diamond import deduplication. Reads, lexes, parses the file, resolves its namespace, and recurses into imports.

---

### `resolve_import_path` {#resolve_import_path}

Function: resolve_import_path Resolves an import path relative to the directory of the importing file. Returns the absolute path to the imported source file.

---
