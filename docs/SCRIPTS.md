# Glacier 1 scripts (`.sdl` → `.ppo`)

The AI, cutscenes and level logic of Hitman: Contracts are `.sdl` scripts compiled to
bytecode (`.ppo`) for a stack VM in `HitmanContracts.exe`. A scene's scripts sit back to back
in `<ID>_MAIN.ZGF` (compressed like the GMS: `u32 size, u32, u8 stored?` then deflate).
`src/glacier/ppo.rs` decodes them; `glacier-dump <ID> --scripts <dir>` writes one listing per
script (for C02-1 into gitignored `data/re/scripts/`).

## Where in the exe (Ghidra, `data/re/ghidra/`)

| What | Address |
|---|---|
| `.ppo` loader (`PPO!` check) & property table | `FUN_00664910` (`0x00664b95`), `FUN_00668c60`, `FUN_006652a0` |
| `IIMV` image loader & post-image signatures | `FUN_00679410` |
| Instance constructor / destructor (sections 6, 7, 9) | `FUN_00678cb0` / `FUN_00678c10` |
| Interpreter (one `switch`, opcodes 0x00–0xA1) | `FUN_0066a2b0` |
| Name lookup up the inheritance chain | `FUN_0067a090` |
| Function-table lookup | `FUN_006788a0` |
| Code address → module | `FUN_00669ff0` |
| State table loader (`0x11223344`) | `FUN_00677f80` |
| State transition, LCA path & state-scoped locals | `FUN_00678420`, `FUN_00678130`, `FUN_00678000` |
| Event table lookup & event handler dispatch | `FUN_006788d0`, `FUN_00678970`, `FUN_006799f0` |
| Signature lookup (post-image & sections 3, 4) | `FUN_00679aa0`, `FUN_00679d60`, `FUN_00679f90` |

Headless Ghidra setup: `~/tools/ghidra_12.1.4_PUBLIC`, JDK 21 in `~/tools/jdk-21*`, export
script `tools/ghidra/ExportAll.java` (decompiled C per 64 KB, `functions.tsv`,
`strings_xrefs.tsv`).

## File layout

`.ppo`: 32-byte header (`"PPO!"`, `0x20`, `f32 1.0`, defaults length, image length, `0x20`,
schema end, image offset), the property schema (`LONG m_iHitpoints=20;…`), the **property
symbol table** (`FUN_00668c60`), then the `IIMV` image:

- **Property symbol table** (immediately after the NUL-terminated `schema` string):
  - `u32 count`, followed by `count` variable-length records:
    - `u32 offset` — byte offset in the instance's `this` buffer (`this + offset`).
    - `u8 kind` (`0x14` primitive, `0x15` script-wrapped property, `0x16` geom ref, `0x24` raw,
      `0x06`/`0x07` 4-byte default, `0x08` string default), `u8 has_default`.
    - Three NUL-terminated strings: `name` (`"m_iHitpoints"`), `raw_type` (`"Int"`, `"Float"`,
      `"STRING"`, `"ZGEOMREF"`), `script_type` (`"Real"`, `"String"`, `"Ref"`, or `""`).
- **`IIMV` header**:
  - `+0x00` `"IIMV"`, `u32` size, `f32` version 1.1, `u32` date, `u32` time, 4×`u16`, 2×16 bytes,
    4×`u32`, `+0x4c` `u32 instance_size` (runtime `+0x44`), `+0x50` `u32 data_base` (runtime `+0x48`).
  - `+0x54` (runtime `+0x64`) eleven `u32` section offsets into the image, `+0x80` image length;
    image at `+0x84`.
- **Image sections**: own source name at 0.

| # | File / Runtime | Content |
|---|---|---|
| 0 | `+0x54` / `+0x64` | parent script's source name (empty for roots) |
| 1 | `+0x58` / `+0x68` | function table: `u32 n`, `n` absolute code addresses (the full inherited dispatch table) |
| 2 | `+0x5c` / `+0x6c` | state machine (`0x11223344`, `FUN_00677f80`): `u32 size`, `u32 state_base`, `u32 n`, `u32 event_table_base`, `u32 d`, `u32 unk`, `u32 locals_len`; followed by `entries[n]`, `state_ev[n]`, `ev_offsets[d]`, `handlers[3n]` (`[on_enter, on_exit, body]`), `names[n]`, `locals_off[n]`, `parents[n]`, `locals_blob[locals_len]`, and `event_tables_blob` |
| 3, 4 | `+0x60..+0x64` / `+0x70..+0x74` | builtin & user type signature maps (`FUN_00679cc0`): `u32 base`, `u32 count`, `(u16 type, u16 sig_idx)[count]` |
| 5 | `+0x68` / `+0x78` | names: `u32 base`, `u32 n`, `n` offsets, NUL-terminated blob |
| 6, 7 | `+0x6c..+0x70` / `+0x7c..+0x80` | member objects (`FUN_00678cb0`): `u32 count`, `(u32 this_offset, u16 type_name)[count]` (`+0x7c` RTE classes like `Scene`, `Hitman`, `Sound`, `System`; `+0x80` script classes) |
| 8 | `+0x74` / `+0x84` | `u32 count`, `u32[count]` |
| 9 | `+0x78` / `+0x88` | initial member data (`FUN_00678cb0`): `u32 len`, `u8[len]` copied into `this + data_base` before member constructors run |
| 10 | `+0x7c` / `+0x8c` | code: `u32 length`, bytecode |

- **Event tables** (in `event_tables_blob` of section 2, `FUN_00678970` / `FUN_006799f0`):
  - `+0x00`: `u32 stub_addr` (the `goto_state` / `goto_state_func` dispatch stub in bytecode).
  - `+0x04`: `u16 count`, followed by `u16 event_names[count]` (`0xffff` = wildcard/default),
    2-byte alignment pad if `count` is even, then `u32 handler_addrs[count]` (exact VM code
    address of each `On <Event>` handler).
- **Post-image signature table** (immediately after the `IIMV` image at `iimv + 0x84 + image_len`,
  `FUN_00679410`):
  - `u32 sig_count`, `u32 sig_base`, followed by `sig_count` records of
    `(u32 flags, u32 n_types, u32 type_name_idx[n_types])`.

## Linking

Scripts derive from one another (`Being → Man → Armed → Guard → Soldier`, …). Name indices,
state indices, event-table indices, signature indices and code addresses are global along a
chain: a script's names start at `name_base`, states at `state_base`, event tables at
`event_table_base`, and its code starts after all its ancestors' code (Being at 0, Man at
0x37ef, …). Jumps and calls use these absolute addresses; `call_func` / `set_state_func` /
`goto_state_func` index the function table.

## The VM

Stack of 8-byte values: `u32` payload + type tag (1 int, 2 float, 3 code address, 4 object
with refcounting). Variable operands are `u16`: bit 15 clear = byte offset into the object's
data (`this+offset`, resolved by `ppo.rs` against `properties` and `members`); set = slot,
bit 14 frame-relative, else global.

Opcodes (mnemonics as `ppo.rs` prints them):

- 0x01/0x02 `inc`/`dec`; 0x03–0x15 logic and arithmetic (int/float pairs); 0x0D `fuzzy_not` =
  `1 − clamp(x)`; 0x89 `fuzzy_clamp`.
- 0x16–0x25 `var op= imm` and `*ref op= imm`; 0x26/0x27 `fmax`/`fmin`; 0x28/0x29
  `fmax_var_imm`/`fmin_var_imm`.
- 0x2A/0x2B push float/int; 0x2C–0x2F loads; 0x30/0x31 `load_float_to_int`/`load_int_to_float`;
  0x32/0x33 stores; 0x34/0x35 `store_float_to_int`/`store_int_to_float`.
- 0x36–0x3F `var op= pop` (`fadd_var`..`fmax_var`); 0x40–0x49 `*ref op= pop`; 0x8B–0x92
  `var op= var`.
- 0x56–0x61 comparisons; 0x62–0x69 ref stores, immediate sets, and var-to-var copies.
- 0x4F jump; 0x50/0x51 conditional (`addr, mode`); 0x76/0x77 flag jumps; 0x6D/0x6E switch tables.
- 0x4A/0x78 call address; 0x4B call function-table entry; 0x4C `call_var`; 0x4D return; 0x93
  frame alloc.
- 0x80 `push_time`; 0x81 `store_obj`; 0x82 `store_ref_obj`; 0x83 `push_var`; 0x84 `push_ref`;
  0x85/0x88 typed default/cast.
- 0x98 `call_native Class::Method`, 0x99 `call_method obj.Method` (u16 class/object, u16 name,
  u16 signature, `u32` arg/ret counts + flags); 0x9A push name; 0x9B `deref`; 0x9C
  `push_event_name`; 0x9D `push_self_name`; 0x9E/0x9F `lock`/`unlock`.
- 0x53–0x55 set state; 0x75 start state; 0x7A/0x7B goto state; 0x79 state end.
- 0x6F/0x70 sleep; 0x71 wait for event; 0x72 wait for named event; 0x7C/0x7D halt/yield.

All 32 C02-1 scripts decode end to end with no unknown opcodes and every jump and handler
landing on an instruction boundary.

## Not yet done

- Naming non-state helper functions (only called by address or function-table index).
- Turning stack code into structured pseudo-source (expressions, `if`/`while`).

