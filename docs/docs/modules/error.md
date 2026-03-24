# Error Reporting Engine

*Source: src/compiler/error.odin*

Error codes, severity levels, and diagnostic output.

---

## Functions

### `init_error_engine` {#init_error_engine}

Function: init_error_engine Initializes the global error reporting engine. Must be called once before any calls to report_error. Sets whether output should be JSON or annotated terminal text and whether ANSI colors are disabled.

---

### `report_error` {#report_error}

Function: report_error Reports a compiler diagnostic. Reads the source file at the given location to collect surrounding context lines, appends the error to global_error_state, and either prints an annotated terminal message or queues it for JSON output. If the error severity is Fatal, JSON errors are flushed and the process exits immediately.

---

### `print_annotated_error` {#print_annotated_error}

Function: print_annotated_error Pretty-prints a single JSON_Error to stderr with line numbers, the offending line highlighted, a caret pointing to the column, and an optional correction hint.

---

### `flush_json_errors` {#flush_json_errors}

Function: flush_json_errors Marshals all accumulated errors as pretty-printed JSON and writes them to stderr. Called automatically when a Fatal error occurs in JSON mode.

---

## Types

### `Error_Context` {#error_context}

Type: Error_Context Captures the source lines surrounding an error for annotated output. Contains up to two lines before the offending line and up to two lines after it, providing visual context in terminal diagnostics.

---

### `JSON_Error` {#json_error}

Type: JSON_Error A single serializable error record emitted when the compiler is running in JSON output mode. Includes source location, error code, human-readable message, optional correction hint, and surrounding source context.

---

### `Error_State` {#error_state}

Type: Error_State Global mutable state for the error reporting engine. Tracks whether output should be JSON or annotated terminal text, color preference, and the accumulated list of errors encountered so far.

---

## Constants

### `Error_Code` {#error_code}

Constant: Error_Code Enumerates all diagnostic error codes recognized by the Osteon compiler. Codes are grouped by severity prefix (Fatal_, Warn_, Hint_) to make classification obvious when reading source.

---

### `Error_Severity` {#error_severity}

Constant: Error_Severity Represents the severity level of a diagnostic. Fatal errors halt compilation, warnings allow continuation, and hints are advisory.

---

### `error_severity_map` {#error_severity_map}

Constant: error_severity_map Lookup table that maps each Error_Code to its corresponding Error_Severity. Used by report_error to determine whether compilation should abort.

---

### `error_code_strings` {#error_code_strings}

Constant: error_code_strings Maps each Error_Code to a human-readable slash-separated string (e.g. "fatal/syntax"). These strings are emitted in JSON output and annotated terminal diagnostics.

---

## Variables

### `global_error_state` {#global_error_state}

Variable: global_error_state The process-wide singleton error state. Initialized by init_error_engine and mutated by report_error.

---
