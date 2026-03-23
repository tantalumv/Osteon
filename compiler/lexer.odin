#+feature dynamic-literals
package compiler

import "core:fmt"
import "core:unicode/utf8"
import "core:strings"
import "core:strconv"

Lexer :: struct {
	file:      string,
	source:    string,
	offset:    int,
	line:      int,
	col:       int,
	curr_char: rune,
}

init_lexer :: proc(file: string, source: string) -> Lexer {
	l := Lexer {
		file   = file,
		source = source,
		line   = 1,
		col    = 1,
	}
	advance_char(&l)
	return l
}

advance_char :: proc(l: ^Lexer) {
	if l.offset < len(l.source) {
		r, size := utf8.decode_rune_in_string(l.source[l.offset:])
		l.curr_char = r
		l.offset += size
		if r == '\n' {
			l.line += 1
			l.col = 1
		} else {
			l.col += 1
		}
	} else {
		l.curr_char = 0 // EOF
	}
}

peek_char :: proc(l: Lexer) -> rune {
	if l.offset < len(l.source) {
		r, _ := utf8.decode_rune_in_string(l.source[l.offset:])
		return r
	}
	return 0
}

next_token :: proc(l: ^Lexer) -> Token {
	skip_whitespace_and_comments(l)

	start_loc := Src_Loc{l.file, l.line, l.col}

	if l.curr_char == 0 {
		return Token{.EOF, "", start_loc}
	}

	char := l.curr_char

	// Symbols
	switch char {
	case ':':
		advance_char(l)
		if l.curr_char == ':' {
			advance_char(l)
			return Token{.Double_Colon, "::", start_loc}
		}
		return Token{.Colon, ":", start_loc}
	case ';': advance_char(l); return Token{.Semicolon, ";", start_loc}
	case ',': advance_char(l); return Token{.Comma, ",", start_loc}
	case '.': advance_char(l); return Token{.Dot, ".", start_loc}
	case '(': advance_char(l); return Token{.Paren_Open, "(", start_loc}
	case ')': advance_char(l); return Token{.Paren_Close, ")", start_loc}
	case '{': advance_char(l); return Token{.Brace_Open, "{", start_loc}
	case '}': advance_char(l); return Token{.Brace_Close, "}", start_loc}
	case '[': advance_char(l); return Token{.Bracket_Open, "[", start_loc}
	case ']': advance_char(l); return Token{.Bracket_Close, "]", start_loc}
	case '=':
		advance_char(l)
		if l.curr_char == '=' {
			advance_char(l)
			return Token{.Eq_Eq, "==", start_loc}
		}
		return Token{.Eq, "=", start_loc}
	case '!':
		advance_char(l)
		if l.curr_char == '=' {
			advance_char(l)
			return Token{.Not_Eq, "!=", start_loc}
		}
		return Token{.Invalid, "!", start_loc}
	case '+': advance_char(l); return Token{.Plus, "+", start_loc}
	case '-': advance_char(l); return Token{.Minus, "-", start_loc}
	case '*': advance_char(l); return Token{.Star, "*", start_loc}
	case '/': advance_char(l); return Token{.Slash, "/", start_loc}
	case '%': advance_char(l); return Token{.Percent, "%", start_loc}
	case '<':
		advance_char(l)
		if l.curr_char == '<' {
			advance_char(l)
			return Token{.Shl, "<<", start_loc}
		}
		if l.curr_char == '=' {
			advance_char(l)
			return Token{.Lt_Eq, "<=", start_loc}
		}
		return Token{.Lt, "<", start_loc}
	case '>':
		advance_char(l)
		if l.curr_char == '>' {
			advance_char(l)
			return Token{.Shr, ">>", start_loc}
		}
		if l.curr_char == '=' {
			advance_char(l)
			return Token{.Gt_Eq, ">=", start_loc}
		}
		return Token{.Gt, ">", start_loc}
	case '&': advance_char(l); return Token{.Amp, "&", start_loc}
	case '|': advance_char(l); return Token{.Pipe, "|", start_loc}
	case '^': advance_char(l); return Token{.Hat, "^", start_loc}
	case '~': advance_char(l); return Token{.Tilde, "~", start_loc}
	case '"':
		return lex_string(l)
	}

	if is_digit(char) {
		return lex_number(l)
	}

	if is_alpha(char) || char == '_' {
		return lex_identifier_or_keyword(l)
	}

	// Unknown character
	tok := Token{.Invalid, fmt.tprintf("%c", char), start_loc}
	advance_char(l)
	return tok
}

skip_whitespace_and_comments :: proc(l: ^Lexer) {
	for {
		if is_whitespace(l.curr_char) {
			advance_char(l)
		} else if l.curr_char == '#' {
			for l.curr_char != '\n' && l.curr_char != 0 {
				advance_char(l)
			}
		} else {
			break
		}
	}
}

lex_identifier_or_keyword :: proc(l: ^Lexer) -> Token {
	start_offset := l.offset - utf8.rune_size(l.curr_char)
	start_loc := Src_Loc{l.file, l.line, l.col}

	for is_alnum(l.curr_char) || l.curr_char == '_' {
		advance_char(l)
	}

	text := l.source[start_offset : l.offset - (l.curr_char == 0 ? 0 : utf8.rune_size(l.curr_char))]
	
	// Keywords
	if kind, is_keyword := keywords[text]; is_keyword {
		return Token{kind, text, start_loc}
	}

	// Registers
	if is_register(text) {
		return Token{.Register, text, start_loc}
	}

	return Token{.Identifier, text, start_loc}
}

lex_number :: proc(l: ^Lexer) -> Token {
	start_offset := l.offset - utf8.rune_size(l.curr_char)
	start_loc := Src_Loc{l.file, l.line, l.col}

	// Leading '0' — check for 0x, 0b, 0o prefixes
	if l.curr_char == '0' {
		advance_char(l)
		peek := l.curr_char

		if peek == 'x' || peek == 'X' {
			advance_char(l) // skip 'x'
			hex_start := l.offset - utf8.rune_size(l.curr_char)
			for is_hex_digit(l.curr_char) {
				advance_char(l)
			}
			hex_end := l.offset - (l.curr_char == 0 ? 0 : utf8.rune_size(l.curr_char))
			return Token{.Integer, fmt.tprintf("0x%s", l.source[hex_start : hex_end]), start_loc}
		}

		if peek == 'b' || peek == 'B' {
			advance_char(l) // skip 'b'
			bin_start := l.offset - utf8.rune_size(l.curr_char)
			for l.curr_char == '0' || l.curr_char == '1' {
				advance_char(l)
			}
			bin_end := l.offset - (l.curr_char == 0 ? 0 : utf8.rune_size(l.curr_char))
			return Token{.Integer, fmt.tprintf("0b%s", l.source[bin_start : bin_end]), start_loc}
		}

		if peek == 'o' || peek == 'O' {
			advance_char(l) // skip 'o'
			oct_start := l.offset - utf8.rune_size(l.curr_char)
			for l.curr_char >= '0' && l.curr_char <= '7' {
				advance_char(l)
			}
			oct_end := l.offset - (l.curr_char == 0 ? 0 : utf8.rune_size(l.curr_char))
			return Token{.Integer, fmt.tprintf("0o%s", l.source[oct_start : oct_end]), start_loc}
		}

		// Just '0' — fall through to decimal/float scanning
	}

	// Decimal digits
	for is_digit(l.curr_char) {
		advance_char(l)
	}

	// Float: decimal point followed by digits
	if l.curr_char == '.' && is_digit(peek_char(l^)) {
		advance_char(l) // skip '.'
		for is_digit(l.curr_char) {
			advance_char(l)
		}
		// Scientific notation: e/E followed by optional +/- and digits
		if l.curr_char == 'e' || l.curr_char == 'E' {
			advance_char(l)
			if l.curr_char == '+' || l.curr_char == '-' {
				advance_char(l)
			}
			for is_digit(l.curr_char) {
				advance_char(l)
			}
		}
		end := l.offset - (l.curr_char == 0 ? 0 : utf8.rune_size(l.curr_char))
		text := l.source[start_offset : end]
		return Token{.Float, text, start_loc}
	}

	end := l.offset - (l.curr_char == 0 ? 0 : utf8.rune_size(l.curr_char))
	text := l.source[start_offset : end]
	return Token{.Integer, text, start_loc}
}

lex_string :: proc(l: ^Lexer) -> Token {
	start_loc := Src_Loc{l.file, l.line, l.col}
	advance_char(l) // skip "
	
	start_offset := l.offset - utf8.rune_size(l.curr_char)
	
	for l.curr_char != '"' && l.curr_char != 0 {
		if l.curr_char == '\\' {
			advance_char(l)
		}
		advance_char(l)
	}
	
	text := l.source[start_offset : l.offset - (l.curr_char == 0 ? 0 : utf8.rune_size(l.curr_char))]
	
	if l.curr_char == '"' {
		advance_char(l)
	} else {
		report_error(.Fatal_Syntax, start_loc, "Unterminated string literal")
	}
	
	return Token{.String, text, start_loc}
}

is_whitespace :: proc(r: rune) -> bool {
	return r == ' ' || r == '\t' || r == '\r' || r == '\n'
}

is_digit :: proc(r: rune) -> bool {
	return r >= '0' && r <= '9'
}

is_hex_digit :: proc(r: rune) -> bool {
	return (r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F')
}

is_alpha :: proc(r: rune) -> bool {
	return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')
}

is_alnum :: proc(r: rune) -> bool {
	return is_alpha(r) || is_digit(r)
}

keywords := map[string]Token_Kind {
	"fn"            = .Fn,
	"inline"        = .Inline,
	"label"         = .Label,
	"extern"        = .Extern,
	"import"        = .Import,
	"as"            = .As,
	"namespace"     = .Namespace,
	"section"       = .Section,
	"static"        = .Static,
	"global"        = .Global,
	"const"         = .Const,
	"struct"        = .Struct,
	"layout"        = .Layout,
	"data"          = .Data,
	"let"           = .Let,
	"for"           = .For,
	"while"         = .While,
	"arena"         = .Arena,
	"alloc"         = .Alloc,
	"reset"         = .Reset,
	"unreachable"   = .Unreachable,
	"breakpoint"    = .Breakpoint,
	"assert"        = .Assert,
	"static_assert" = .Static_Assert,
	"expect"        = .Expect,
	"result"        = .Result,
	"lock"          = .Lock,
	"likely"        = .Likely,
	"unlikely"      = .Unlikely,
	"canary"        = .Canary,
	"check_canary"  = .Check_Canary,
}

is_register :: proc(text: string) -> bool {
	// x86-64 GPRs
	gprs := []string{
		"rax", "eax", "ax", "al",
		"rbx", "ebx", "bx", "bl",
		"rcx", "ecx", "cx", "cl",
		"rdx", "edx", "dx", "dl",
		"rsi", "esi", "si", "sil",
		"rdi", "edi", "di", "dil",
		"rsp", "esp", "sp", "spl",
		"rbp", "ebp", "bp", "bpl",
		"r8",  "r8d",  "r8w",  "r8b",
		"r9",  "r9d",  "r9w",  "r9b",
		"r10", "r10d", "r10w", "r10b",
		"r11", "r11d", "r11w", "r11b",
		"r12", "r12d", "r12w", "r12b",
		"r13", "r13d", "r13w", "r13b",
		"r14", "r14d", "r14w", "r14b",
		"r15", "r15d", "r15w", "r15b",
		"rip", "rflags",
	}

	for r in gprs {
		if text == r do return true
	}

	// SIMD
	if strings.has_prefix(text, "xmm") || strings.has_prefix(text, "ymm") || strings.has_prefix(text, "zmm") {
		num_str := text[3:]
		val, ok := strconv.parse_int(num_str)
		if ok && val >= 0 && val <= 31 do return true
	}

	return false
}
