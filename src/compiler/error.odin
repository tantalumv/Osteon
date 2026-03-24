package compiler

import "core:fmt"
import "core:os"
import "core:strings"
import "core:encoding/json"

// Constant: Error_Code
// Enumerates all diagnostic error codes recognized by the Osteon compiler.
// Codes are grouped by severity prefix (Fatal_, Warn_, Hint_) to make
// classification obvious when reading source.

Error_Code :: enum {
	Fatal_Width,
	Fatal_Uninit,
	Fatal_Syntax,
	Fatal_Undef,
	Fatal_Assert,
	Fatal_Import,
	Fatal_Layout,
	Fatal_Namespace,
	Fatal_Arena,
	Fatal_Synthetic,
	Fatal_Unsupported,
	Warn_Dead,
	Warn_Unreachable,
	Warn_Clobber,
	Warn_Canary_Missing,
	Hint_Noret,
	Hint_Breakpoint,
}

// Constant: Error_Severity
// Represents the severity level of a diagnostic. Fatal errors halt
// compilation, warnings allow continuation, and hints are advisory.

Error_Severity :: enum {
	Fatal,
	Warning,
	Hint,
}

// Constant: error_severity_map
// Lookup table that maps each Error_Code to its corresponding
// Error_Severity. Used by report_error to determine whether
// compilation should abort.

error_severity_map := [Error_Code]Error_Severity {
	.Fatal_Width     = .Fatal,
	.Fatal_Uninit    = .Fatal,
	.Fatal_Syntax    = .Fatal,
	.Fatal_Undef     = .Fatal,
	.Fatal_Assert    = .Fatal,
	.Fatal_Import    = .Fatal,
	.Fatal_Layout    = .Fatal,
	.Fatal_Namespace = .Fatal,
	.Fatal_Arena     = .Fatal,
	.Fatal_Synthetic  = .Fatal,
	.Fatal_Unsupported = .Fatal,
	.Warn_Dead        = .Warning,
	.Warn_Unreachable = .Warning,
	.Warn_Clobber     = .Warning,
	.Warn_Canary_Missing = .Warning,
	.Hint_Noret       = .Hint,
	.Hint_Breakpoint  = .Hint,
}

// Constant: error_code_strings
// Maps each Error_Code to a human-readable slash-separated string
// (e.g. "fatal/syntax"). These strings are emitted in JSON output
// and annotated terminal diagnostics.

error_code_strings := [Error_Code]string {
	.Fatal_Width     = "fatal/width",
	.Fatal_Uninit    = "fatal/uninit",
	.Fatal_Syntax    = "fatal/syntax",
	.Fatal_Undef     = "fatal/undef",
	.Fatal_Assert    = "fatal/assert",
	.Fatal_Import    = "fatal/import",
	.Fatal_Layout    = "fatal/layout",
	.Fatal_Namespace = "fatal/namespace",
	.Fatal_Arena     = "fatal/arena",
	.Fatal_Synthetic  = "fatal/synthetic",
	.Fatal_Unsupported = "fatal/unsupported",
	.Warn_Dead        = "warn/dead",
	.Warn_Unreachable = "warn/unreachable",
	.Warn_Clobber     = "warn/clobber",
	.Warn_Canary_Missing = "warn/canary_missing",
	.Hint_Noret       = "hint/noret",
	.Hint_Breakpoint  = "hint/breakpoint",
}

// Type: Error_Context
// Captures the source lines surrounding an error for annotated output.
// Contains up to two lines before the offending line and up to two
// lines after it, providing visual context in terminal diagnostics.

Error_Context :: struct {
	before:    [dynamic]string,
	offending: string,
	after:     [dynamic]string,
}

// Type: JSON_Error
// A single serializable error record emitted when the compiler is
// running in JSON output mode. Includes source location, error code,
// human-readable message, optional correction hint, and surrounding
// source context.

JSON_Error :: struct {
	file:       string,
	line:       int,
	col:        int,
	code:       string,
	message:    string,
	correction: string,
	// alias:     Maybe(JSON_Alias), // TODO: Alias support later
	error_context: Error_Context,
}

// Type: Error_State
// Global mutable state for the error reporting engine. Tracks whether
// output should be JSON or annotated terminal text, color preference,
// and the accumulated list of errors encountered so far.

Error_State :: struct {
	json_mode: bool,
	no_color:  bool,
	errors:    [dynamic]JSON_Error,
}

// Variable: global_error_state
// The process-wide singleton error state. Initialized by
// init_error_engine and mutated by report_error.

global_error_state: Error_State

// Function: init_error_engine
// Initializes the global error reporting engine. Must be called once
// before any calls to report_error. Sets whether output should be
// JSON or annotated terminal text and whether ANSI colors are disabled.

init_error_engine :: proc(json_mode: bool, no_color: bool) {
	global_error_state.json_mode = json_mode
	global_error_state.no_color = no_color
	global_error_state.errors = make([dynamic]JSON_Error)
}

// Function: report_error
// Reports a compiler diagnostic. Reads the source file at the given
// location to collect surrounding context lines, appends the error
// to global_error_state, and either prints an annotated terminal
// message or queues it for JSON output. If the error severity is
// Fatal, JSON errors are flushed and the process exits immediately.

report_error :: proc(code: Error_Code, loc: Src_Loc, message: string, correction: string = "") {
	severity := error_severity_map[code]
	code_str := error_code_strings[code]

	// Collect context
	ctx: Error_Context
	ctx.before = make([dynamic]string, context.temp_allocator)
	ctx.after = make([dynamic]string, context.temp_allocator)
	data, err := os.read_entire_file_from_path(loc.file, context.temp_allocator)
	if err == 0 {
		content := string(data)
		lines := strings.split(content, "\n", context.temp_allocator)

		line_idx := loc.line - 1
		if line_idx >= 0 && line_idx < len(lines) {
			ctx.offending = strings.trim_right(lines[line_idx], "\r")

			// Get lines before
			for i := max(0, line_idx - 2); i < line_idx; i += 1 {
				append(&ctx.before, strings.trim_right(lines[i], "\r"))
			}

			// Get lines after
			for i := line_idx + 1; i < min(len(lines), line_idx + 3); i += 1 {
				append(&ctx.after, strings.trim_right(lines[i], "\r"))
			}
		}
	}

	err_struct := JSON_Error {
		file          = loc.file,
		line          = loc.line,
		col           = loc.col,
		code          = code_str,
		message       = message,
		correction    = correction,
		error_context = ctx,
	}
	append(&global_error_state.errors, err_struct)

	if !global_error_state.json_mode {
		print_annotated_error(err_struct, severity)
	}

	if severity == .Fatal {
		if global_error_state.json_mode {
			flush_json_errors()
		}
		os.exit(1)
	}
}

// Function: print_annotated_error
// Pretty-prints a single JSON_Error to stderr with line numbers,
// the offending line highlighted, a caret pointing to the column,
// and an optional correction hint.

print_annotated_error :: proc(err: JSON_Error, severity: Error_Severity) {
	fmt.eprintf("%s:%d:%d\n", err.file, err.line, err.col)

	// Print context
	start_line := err.line - len(err.error_context.before)
	for line, i in err.error_context.before {
		fmt.eprintf("%4d | %s\n", start_line + i, line)
	}

	fmt.eprintf("%4d | %s   <- [%s] %s\n", err.line, err.error_context.offending, err.code, err.message)

	// Underline
	fmt.eprintf("     | ")
	for i := 1; i < err.col; i += 1 {
		fmt.eprintf(" ")
	}
	fmt.eprintf("^")
	if err.correction != "" {
		fmt.eprintf("  Correction: %s", err.correction)
	}
	fmt.eprintf("\n")

	for line, i in err.error_context.after {
		fmt.eprintf("%4d | %s\n", err.line + 1 + i, line)
	}

	fmt.eprintln()
}


// Function: flush_json_errors
// Marshals all accumulated errors as pretty-printed JSON and writes
// them to stderr. Called automatically when a Fatal error occurs in
// JSON mode.

flush_json_errors :: proc() {
	if len(global_error_state.errors) > 0 {
		data, _ := json.marshal(global_error_state.errors, {pretty = true})
		fmt.eprintln(string(data))
	}
}
