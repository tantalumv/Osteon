# Lexical Analysis

*Source: src/compiler/lexer.odin*

Tokenizes source code into a stream of tokens.

---

## Functions

### `init_lexer` {#init_lexer}

Function: init_lexer Creates and initializes a new Lexer for the given file and source string. Advances to the first character before returning.

---

### `advance_char` {#advance_char}

Function: advance_char Moves the lexer forward by one UTF-8 encoded rune. Updates the line and column counters accordingly. Sets curr_char to 0 when the end of the source is reached.

---

### `peek_char` {#peek_char}

Function: peek_char Returns the next rune in the source without advancing the lexer position. Returns 0 if the end of the source has been reached.

---

### `next_token` {#next_token}

Function: next_token Consumes and returns the next token from the source. Skips whitespace and comments before lexing the token. Recognizes symbols, operators, numbers, strings, identifiers, keywords, and registers. Returns an EOF token when the source is exhausted.

---

### `skip_whitespace_and_comments` {#skip_whitespace_and_comments}

Function: skip_whitespace_and_comments Advances the lexer past any whitespace characters and line comments. Line comments begin with '#' and extend to the end of the line.

---

### `lex_identifier_or_keyword` {#lex_identifier_or_keyword}

Function: lex_identifier_or_keyword Lexes an identifier or keyword token starting from the current position. An identifier consists of alphanumeric characters and underscores, beginning with a letter or underscore. Checks the keyword table and register list before classifying as a plain identifier.

---

### `lex_number` {#lex_number}

Function: lex_number Lexes a numeric literal token starting from the current position. Supports decimal integers, hexadecimal (0x), binary (0b), and octal (0o) prefixed integers, as well as floating-point numbers with optional scientific notation.

---

### `lex_string` {#lex_string}

Function: lex_string Lexes a double-quoted string literal token starting from the current position. Handles escape sequences by skipping the character following a backslash. Reports a fatal syntax error if the string is not terminated before end of source.

---

### `is_whitespace` {#is_whitespace}

Function: is_whitespace Returns true if the given rune is a whitespace character: space, tab, carriage return, or newline.

---

### `is_digit` {#is_digit}

Function: is_digit Returns true if the given rune is an ASCII decimal digit ('0' through '9').

---

### `is_hex_digit` {#is_hex_digit}

Function: is_hex_digit Returns true if the given rune is a valid hexadecimal digit: '0'-'9', 'a'-'f', or 'A'-'F'.

---

### `is_alpha` {#is_alpha}

Function: is_alpha Returns true if the given rune is an ASCII alphabetic character ('a'-'z' or 'A'-'Z').

---

### `is_alnum` {#is_alnum}

Function: is_alnum Returns true if the given rune is an ASCII alphanumeric character. Equivalent to is_alpha(r) || is_digit(r).

---

### `is_register` {#is_register}

Function: is_register Returns true if the given text matches a recognized x86-64 register name. Covers general-purpose registers at all widths (rax/ax/al, etc.), R8-R15, rip, rflags, and SIMD registers (xmm0-xmm31, ymm0-ymm31, zmm0-zmm31).

---

## Types

### `Lexer` {#lexer}

Type: Lexer The lexer state machine that tracks the current position within source text. Maintains file name, source string, byte offset, line/column position, and the current rune being examined.

---

## Constants

### `keywords` {#keywords}

Constant: keywords Map of reserved language keywords to their corresponding Token_Kind values. Includes control flow, declarations, type definitions, memory management, and assertion-related keywords.

---
