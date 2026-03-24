package compiler

import "core:fmt"
import "core:os"

// Constant: PE32_PLUS_MAGIC
// The PE32+ magic number (0x20B) identifying a 64-bit portable executable.
PE32_PLUS_MAGIC          :: u16(0x20B)

// Constant: IMAGE_BASE
// Default preferred base address (0x140000000) at which the PE32+ image is loaded.
IMAGE_BASE               :: u64(0x140000000)

// Constant: SECTION_ALIGNMENT
// Section alignment in memory (4 KiB). Each section starts on this boundary.
SECTION_ALIGNMENT        :: u32(0x1000)

// Constant: FILE_ALIGNMENT
// Section alignment on disk (512 bytes). Raw data is padded to this boundary.
FILE_ALIGNMENT           :: u32(0x200)

// Constant: SUBSYSTEM_CONSOLE
// Windows subsystem value (3) indicating a console application.
SUBSYSTEM_CONSOLE        :: u16(3)

// Constant: MAGIC_DOS
// DOS stub magic number (0x5A4D, "MZ") placed at the start of the file.
MAGIC_DOS                :: u16(0x5A4D)

// Function: emit_pe32_exe
// Emits a PE32+ executable to output_path. Iterates over packages, encodes
// all function bodies into machine code, builds a small x86-64 entry stub
// that calls the first function found, and writes PE headers with .text and
// .data sections.
emit_pe32_exe :: proc(output_path: string, packages: [dynamic]^Package, is_debug: bool) {
	ctx: Encoder_Context
	init_encoder(&ctx)
	entry_fn_name := ""

	for pkg in packages {
		for stmt in pkg.program.stmts {
			#partial switch s in stmt {
			case ^Fn_Decl:
				mangled := fmt.tprintf("%s__%s", pkg.name, s.name)
				if entry_fn_name == "" {
					entry_fn_name = mangled
				}
				ctx.current_fn = mangled
				define_label(&ctx, s.name)
				for body_stmt in s.body {
					#partial switch bs in body_stmt {
					case ^Instr:
						encode_instr(&ctx, bs)
					case ^Label_Decl:
						define_label(&ctx, bs.name)
					}
				}
			}
		}
	}

	unresolved := make([dynamic]Patch_Entry)
	resolve_patches(&ctx, &unresolved)

	if entry_fn_name == "" {
		fmt.printf("Error: no function found for entry point\n")
		return
	}

	// PE32+ with entry stub + user code + import table for ExitProcess
	user_code := ctx.buf[:]
	user_code_size := len(user_code)

	STUB_SIZE :: 14
	// stub (14 bytes): sub rsp,0x28; call main; add rsp,0x28; ret
	stub := make([]u8, STUB_SIZE)
	stub[0]=0x48; stub[1]=0x83; stub[2]=0xEC; stub[3]=0x28
	stub[4]=0xE8 // call rel32
	stub[9]=0x48; stub[10]=0x83; stub[11]=0xC4; stub[12]=0x28
	stub[13]=0xC3

	headers_size := u32(0x200)
	text_raw_size := align_up(u32(STUB_SIZE + user_code_size), FILE_ALIGNMENT)
	text_virt_size := align_up(u32(STUB_SIZE + user_code_size), SECTION_ALIGNMENT)
	data_raw_size := FILE_ALIGNMENT
	data_virt_size := SECTION_ALIGNMENT
	text_rva := SECTION_ALIGNMENT
	data_rva := text_rva + text_virt_size
	size_of_image := data_rva + data_virt_size
	text_file_off := headers_size
	data_file_off := text_file_off + text_raw_size

	// Build .text (stub + user code)
	text_buf := make([]u8, text_raw_size)
	copy(text_buf[:], stub[:])
	text_buf[5] = 5 // call displacement = 14 - 9 = 5
	copy(text_buf[STUB_SIZE:], user_code)

	// PE headers (2 sections: .text + .data)
	pe := make([]u8, headers_size)
	w_u16(&pe, 0, MAGIC_DOS)
	w_u16(&pe, 2, 0x90); w_u16(&pe, 4, 3); w_u16(&pe, 18, 0xFFFF); w_u16(&pe, 20, 0xB8)
	w_u32(&pe, 60, 0x80)
	pe[128] = 0x50; pe[129] = 0x45
	w_u16(&pe, 132, 0x8664)
	w_u16(&pe, 134, 2)
	w_u16(&pe, 148, 240); w_u16(&pe, 150, 0x0022); w_u16(&pe, 152, 0x20B)
	pe[154] = 14
	w_u32(&pe, 156, text_raw_size)
	w_u32(&pe, 160, data_raw_size)
	w_u32(&pe, 168, text_rva)
	w_u64(&pe, 176, IMAGE_BASE)
	w_u32(&pe, 184, SECTION_ALIGNMENT); w_u32(&pe, 188, FILE_ALIGNMENT)
	w_u16(&pe, 192, 6); w_u16(&pe, 200, 6)
	w_u32(&pe, 208, size_of_image); w_u32(&pe, 212, headers_size)
	w_u16(&pe, 220, SUBSYSTEM_CONSOLE); w_u16(&pe, 222, 0x8160)
	w_u64(&pe, 224, 0x100000); w_u64(&pe, 232, 0x1000)
	w_u64(&pe, 240, 0x100000); w_u64(&pe, 248, 0x1000)
	w_u32(&pe, 260, 0)
	write_sec_hdr(&pe, 392, ".text", text_virt_size, text_rva, text_raw_size, text_file_off, 0x60000020)
	write_sec_hdr(&pe, 432, ".data", data_virt_size, data_rva, data_raw_size, data_file_off, 0xC0000040)

	// Write file
	f, err := os.open(output_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
	if err != os.ERROR_NONE {
		fmt.printf("Error: %v\n", err); return
	}
	defer os.close(f)
	os.write(f, pe[:])
	write_zeros(f, text_file_off - headers_size)
	os.write(f, text_buf[:])
	write_zeros(f, data_raw_size)
	fmt.printf("PE32+: %s (%d .text, entry=%s)\n", output_path, text_raw_size, entry_fn_name)
}

// Function: align_up
// Rounds val up to the nearest multiple of alignment. Both values must be
// powers of two. Returns the aligned result.
align_up :: proc(val: u32, alignment: u32) -> u32 {
	return (val + alignment - 1) & ~(alignment - 1)
}

// Function: w_u16
// Writes a little-endian u16 value into buf at byte offset off.
w_u16 :: proc(buf: ^[]u8, off: int, val: u16) {
	buf[off] = u8(val); buf[off+1] = u8(val >> 8)
}

// Function: w_u32
// Writes a little-endian u32 value into buf at byte offset off.
w_u32 :: proc(buf: ^[]u8, off: int, val: u32) {
	buf[off] = u8(val); buf[off+1] = u8(val >> 8); buf[off+2] = u8(val >> 16); buf[off+3] = u8(val >> 24)
}

// Function: w_u64
// Writes a little-endian u64 value into buf at byte offset off.
w_u64 :: proc(buf: ^[]u8, off: int, val: u64) {
	buf[off] = u8(val); buf[off+1] = u8(val >> 8); buf[off+2] = u8(val >> 16); buf[off+3] = u8(val >> 24)
	buf[off+4] = u8(val >> 32); buf[off+5] = u8(val >> 40); buf[off+6] = u8(val >> 48); buf[off+7] = u8(val >> 56)
}

// Function: write_zeros
// Writes count zero bytes to file f, flushing in 256-byte chunks.
write_zeros :: proc(f: ^os.File, count: u32) {
	zeros := [256]u8{}
	remaining := int(count)
	for remaining > 0 {
		chunk := remaining
		if chunk > 256 { chunk = 256 }
		os.write(f, zeros[:chunk])
		remaining -= chunk
	}
}

// Function: write_sec_hdr
// Writes a COFF-style section header into buf at offset off. Fields include
// the section name (up to 8 bytes), virtual size/address, raw data
// size/pointer, and characteristics flags.
write_sec_hdr :: proc(buf: ^[]u8, off: int, name: string, vsize: u32, vaddr: u32, rsize: u32, rptr: u32, chars: u32) {
	for i := 0; i < 8; i += 1 {
		if i < len(name) { buf[off+i] = u8(name[i]) } else { buf[off+i] = 0 }
	}
	w_u32(buf, off+8, vsize); w_u32(buf, off+12, vaddr)
	w_u32(buf, off+16, rsize); w_u32(buf, off+20, rptr)
	w_u32(buf, off+36, chars)
}
