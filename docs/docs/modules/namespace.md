# Package Namespace Resolution

*Source: src/compiler/namespace.odin*

Resolves package names and detects collisions.

---

## Functions

### `init_namespace_resolution` {#init_namespace_resolution}

Function: init_namespace_resolution Initializes the global_packages map for namespace resolution.

---

### `resolve_package_namespace` {#resolve_package_namespace}

Function: resolve_package_namespace Resolves a package's namespace name. Defaults to the filename stem, then allows an explicit Namespace_Decl to override. Checks for collisions across the global registry and reports Fatal_Namespace on duplicates.

---

### `get_stmt_loc` {#get_stmt_loc}

Function: get_stmt_loc Extracts the source location from any statement AST node. Returns an empty Src_Loc for unrecognized node types.

---

## Types

### `Package` {#package}

Type: Package Represents a loaded source file and its resolved namespace. Tracks the namespace name, source file path, parsed AST, and import alias mappings.

---

## Variables

### `global_packages` {#global_packages}

Variable: global_packages Global registry mapping namespace names to their Package objects. Used for namespace collision detection and cross-package lookups.

---
