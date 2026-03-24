# COFF Object File Emitter

*Source: src/compiler/coff.odin*

Generates COFF object files with symbol tables.

---

## Functions

### `init_string_table` {#init_string_table}

Function: init_string_table Initializes a String_Table, allocating storage and reserving the first 4 bytes for the total-size field.

---

### `string_table_add` {#string_table_add}

Function: string_table_add Appends a null-terminated string to the string table and returns the 1-based offset where it was placed.

---

### `string_table_finalize` {#string_table_finalize}

Function: string_table_finalize Writes the total byte count into the first 4 bytes of the string table, completing the header size field.

---

### `set_symbol_name` {#set_symbol_name}

Function: set_symbol_name Sets the name field of a COFF symbol. Short names (<=8 bytes) are stored inline; long names are added to the string table and referenced by offset.

---

### `emit_coff_obj` {#emit_coff_obj}

Function: emit_coff_obj Emits a COFF object file to file_path. Encodes all functions into a .text section, serializes data declarations into .data, builds the symbol table and relocations, and writes the complete object file.

---

### `serialize_data_value` {#serialize_data_value}

Function: serialize_data_value Serializes a Data_Value into buf according to its type, dispatching to write_integer for integer widths, write_float for floating-point widths, byte copy for strings, and recursive calls for arrays and struct inits.

---

### `write_integer` {#write_integer}

Function: write_integer Appends val as a little-endian integer to buf, using the byte width specified by width. Handles U8, U16, U32, U64, F32, and F64 widths.

---

### `write_float` {#write_float}

Function: write_float Appends val as a little-endian floating-point value to buf. Uses 4 bytes for .F32 width and 8 bytes for .F64 width.

---

### `f32_to_bits` {#f32_to_bits}

Function: f32_to_bits Reinterprets an f32 value as its IEEE 754 bit representation (u32).

---

### `f64_to_bits` {#f64_to_bits}

Function: f64_to_bits Reinterprets an f64 value as its IEEE 754 bit representation (u64).

---

## Types

### `COFF_Header` {#coff_header}

Type: COFF_Header The COFF file header containing machine type, section count, symbol table pointer, and file characteristics.

---

### `COFF_Section_Header` {#coff_section_header}

Type: COFF_Section_Header Describes a single section in a COFF object file, including its name, virtual and raw data sizes, relocation table pointer, and flags.

---

### `COFF_Symbol` {#coff_symbol}

Type: COFF_Symbol A single entry in the COFF symbol table. Holds an 8-byte (or string-table- referenced) name, value, section number, type, and storage class.

---

### `COFF_Relocation` {#coff_relocation}

Type: COFF_Relocation A relocation entry that patches a reference to a symbol at a given virtual address within a section. Fields include the target address, symbol index, and relocation type.

---

### `String_Table` {#string_table}

Type: String_Table Stores symbol names longer than 8 bytes. The first 4 bytes encode the total table size, and strings are appended as null-terminated entries with 1-based offsets.

---

## Constants

### `IMAGE_FILE_MACHINE_AMD64` {#image_file_machine_amd64}

Constant: IMAGE_FILE_MACHINE_AMD64 Machine type constant (0x8664) identifying AMD64 (x86-64) architecture.

---

### `IMAGE_FILE_CHARACTERISTICS_EXECUTABLE_IMAGE` {#image_file_characteristics_executable_image}

Constant: IMAGE_FILE_CHARACTERISTICS_EXECUTABLE_IMAGE COFF characteristics flag (0x0002) indicating the file is an executable.

---

### `IMAGE_SCN_CNT_CODE` {#image_scn_cnt_code}

Constant: IMAGE_SCN_CNT_CODE Section flag (0x00000020) marking the section as containing executable code.

---

### `IMAGE_SCN_CNT_INITIALIZED_DATA` {#image_scn_cnt_initialized_data}

Constant: IMAGE_SCN_CNT_INITIALIZED_DATA Section flag (0x00000040) marking the section as containing initialized data.

---

### `IMAGE_SCN_MEM_EXECUTE` {#image_scn_mem_execute}

Constant: IMAGE_SCN_MEM_EXECUTE Section flag (0x20000000) granting execute permission on the section.

---

### `IMAGE_SCN_MEM_READ` {#image_scn_mem_read}

Constant: IMAGE_SCN_MEM_READ Section flag (0x40000000) granting read permission on the section.

---

### `IMAGE_SCN_MEM_WRITE` {#image_scn_mem_write}

Constant: IMAGE_SCN_MEM_WRITE Section flag (0x80000000) granting write permission on the section.

---
