# Marrow — Game Server Unikernel Specification
**Version:** 0.1.0 (Draft)
**Status:** Pre-implementation
**Target:** x86-64, KVM/QEMU hypervisor, VPS deployment
**Language:** Osteon (.ostn) for critical paths, Odin for higher-level logic

---

## 1. Overview

Marrow is a purpose-built unikernel for competitive multiplayer game server hosting.
It is not a general-purpose OS. It boots once, runs one match, exits. It has no shell,
no multi-user support, no dynamic linking, no filesystem beyond an append-only event
log. Every design decision optimizes for three goals:

- **Deterministic simulation** — fixed-point integer arithmetic throughout,
  identical results on every CPU, every run, forever.
- **Robust server-side anticheat** — full event log replay makes cheating
  mathematically provable, not just detectable.
- **Minimal attack surface** — no unnecessary kernel subsystems, no exploitable
  complexity, sealed per-match process model.

### Design Principles

- **Integer only.** No floating point in simulation, physics, or anticheat logic.
  Fixed-point arithmetic everywhere. Floats exist only in the rendering hint
  packets sent to clients.
- **Append-only truth.** The event log is never mutated. History is permanent.
  Server state is a materialized view of the log.
- **Fixed size everything.** No variable-length allocations in hot paths.
  All records are fixed-width. All arenas are pre-sized at boot.
- **One match, one lifetime.** The unikernel boots for one match and exits.
  No state persists between matches except the event log shipped to the
  audit server.
- **Community enforcement.** Anticheat flags suspicious matches for community
  review. No automated bans without human confirmation in the initial model.

---

## 2. Fixed-Point Arithmetic

### 2.1 Scale Factors

All simulation values are integers with defined scale factors.
Clients use linear interpolation (lerp) to smooth between server ticks.

| Quantity      | Type | Unit              | Range                     | Notes                        |
|---------------|------|-------------------|---------------------------|------------------------------|
| Position X/Y/Z| i32  | centimeters       | ±21,474,836 cm (~214 km)  | Sufficient for any game map  |
| Velocity      | i32  | cm per tick       | ±2,147,483,647            | Bounded by physics validation|
| View yaw      | i32  | binary degrees    | 0 – 4,294,967,295 (u32)   | Full rotation = 2^32 units   |
| View pitch    | i32  | binary degrees    | clamped ±quarter rotation |                              |
| Health        | i32  | centi-health      | 0 – 10,000 (= 100.00 HP)  | Two decimal places of HP     |
| Time          | u64  | microseconds      | ~584,000 years max        | Monotonic since match start  |
| Distance      | i64  | centimeters       | ±9.2 × 10^18 cm           | For range calculations       |
| Damage        | i32  | centi-damage      | 0 – 2,147,483,647         |                              |
| Economy       | i64  | integer currency  | 0 – 9,223,372,036,854,775,807 | No fractional currency   |

### 2.2 Fixed-Point Multiplication

All fixed-point multiply/divide uses explicit scale correction:

```ostn
# multiply two cm values, result in cm
# (a_cm * b_cm) >> SCALE_SHIFT = result_cm
const SCALE_SHIFT = 16
const SCALE       = 1 << SCALE_SHIFT

inline fn fpmul {
    let a = rdi    # i32 operand a
    let b = rsi    # i32 operand b
    imul(i64) rax, a, b
    sar(i64)  rax, imm(SCALE_SHIFT)
    ret
}
```

### 2.3 No Float Rule

The simulation core, physics validation, anticheat logic, and event log contain
zero floating-point operations. Violations are caught by:

```ostn
static_assert(SIZEOF(PlayerState) % 8 == 0, "PlayerState must be 8-byte aligned")
# All fields in PlayerState are integer types — enforced at struct definition
```

The compiler's `fatal/width` pass catches accidental f32/f64 use in simulation
functions annotated with `# @nofloat`.

---

## 3. Event Log

The event log is Marrow's source of truth. It is append-only, fixed-width,
written to a VirtIO block device, and shipped to the audit server at match end.

### 3.1 Record Format

Every event is exactly **64 bytes** — one cache line.

```
Offset  Size  Type    Field               Description
──────────────────────────────────────────────────────────────────────────
0       8     u64     sequence_number     Global monotonic, never resets
8       8     u64     match_id            Unique per match instance (UUID as u128 split)
16      8     u64     timestamp_us        Microseconds since match start
24      4     u32     player_id           0–63 for 64-player match
28      4     u32     tick                Server tick number
32      1     u8      event_type          See event type table below
33      1     u8      flags               Anticheat flags (see section 7)
34      2     u16     _pad                Reserved, must be zero
36      4     u32     checksum            CRC32C of bytes 0–35
40      24    u8[24]  payload             Event-type-specific data (see below)
──────────────────────────────────────────────────────────────────────────
Total:  64 bytes
```

### 3.2 Event Types

| Value | Name                  | Description                              |
|-------|-----------------------|------------------------------------------|
| 0x01  | INPUT_MOVEMENT        | Player movement input this tick          |
| 0x02  | INPUT_ACTION          | Fire, reload, interact, ability          |
| 0x03  | PLAYER_CONNECT        | Player joined the match                  |
| 0x04  | PLAYER_DISCONNECT     | Player left or was dropped               |
| 0x05  | PLAYER_SPAWN          | Player spawned at position               |
| 0x06  | PLAYER_DEATH          | Player died, killer, weapon, position    |
| 0x07  | HIT_REGISTERED        | Server confirmed a hit registration      |
| 0x08  | HIT_REJECTED          | Server rejected a hit (anticheat)        |
| 0x09  | STATE_SNAPSHOT        | Periodic full state checkpoint           |
| 0x0A  | ROUND_START           | Round began                              |
| 0x0B  | ROUND_END             | Round ended, outcome                     |
| 0x0C  | ECONOMY_CHANGE        | Currency/inventory delta                 |
| 0x0D  | ANTICHEAT_FLAG        | Anomaly detected, severity, type         |
| 0x0E  | MATCH_START           | Match parameters, map, mode              |
| 0x0F  | MATCH_END             | Final scores, match summary              |
| 0xFF  | INVALID               | Must never appear in valid log           |

### 3.3 Payload Layouts

**INPUT_MOVEMENT (0x01):**
```
Offset  Size  Type  Field
0       4     i32   delta_x        cm per tick, clamped to max velocity
4       4     i32   delta_z        horizontal plane movement
8       4     i32   view_yaw       binary degrees
12      4     i32   view_pitch     binary degrees, clamped
16      1     u8    buttons        bit0=jump bit1=crouch bit2=sprint bit3=walk
17      7     u8[7] _pad
```

**PLAYER_DEATH (0x06):**
```
Offset  Size  Type  Field
0       4     u32   killer_id
4       4     u32   weapon_id
8       4     i32   position_x     cm
12      4     i32   position_y     cm
16      4     i32   position_z     cm
20      4     u32   _pad
```

**ANTICHEAT_FLAG (0x0D):**
```
Offset  Size  Type  Field
0       4     u32   flag_type      see anticheat flag types
4       4     u32   severity       0=low 1=medium 2=high 3=critical
8       8     u64   evidence_seq   sequence_number of the triggering event
16      8     u8[8] _pad
```

### 3.4 Append-Only Guarantee

The event log is opened with O_APPEND|O_CREAT on the VirtIO block device.
The unikernel never seeks backward. Never overwrites. Never deletes.

Seeking to event N: `base_address + N * 64` — O(1), no parsing required.

The log is memory-mapped read-only for the replay engine and
post-match analysis. Writes go through the append path only.

### 3.5 Log Size Estimation

```
64 players × 64 ticks/second × 1800 seconds × 64 bytes = 450 MB worst case
Typical match (30 min, avg 48 active players):           ~340 MB
Compressed (LZ4 after match end):                        ~40-80 MB
```

---

## 4. Game State

### 4.1 Player State — SoA Layout

All player state is stored as Struct of Arrays for cache-optimal tick processing.

```ostn
layout(soa) struct PlayerState {
    # Position (cm, fixed point)
    pos_x:          i32,
    pos_y:          i32,
    pos_z:          i32,

    # Velocity (cm per tick)
    vel_x:          i32,
    vel_y:          i32,
    vel_z:          i32,

    # View angles (binary degrees)
    view_yaw:       i32,
    view_pitch:     i32,

    # Status
    health:         i32,    # centi-health (10000 = 100.00 HP)
    armor:          i32,
    alive:          u32,    # 0 = dead, 1 = alive

    # Timing
    last_input_us:  u64,    # timestamp of last received input
    spawn_tick:     u32,

    # Identity
    player_id:      u32,
    team_id:        u32,

    # Economy
    currency:       i64,

    # Anticheat state
    ac_flags:       u32,    # accumulated anticheat flags this match
    ac_score:       i32,    # suspicion score, increases with flags
    _pad:           u32,
}

static_assert(SIZEOF(PlayerState) == 80,  "PlayerState layout changed")
static_assert(SIZEOF_SOA(PlayerState, 64) == 5120, "PlayerState SoA block changed")
```

### 4.2 World State

```ostn
struct WorldState {
    tick:           u32,
    round:          u32,
    round_tick:     u32,
    match_id_lo:    u64,
    match_id_hi:    u64,
    timestamp_us:   u64,
    player_count:   u32,
    active_players: u64,   # bitmask, bit N = player N is alive and connected
    round_state:    u32,   # 0=warmup 1=live 2=round_end 3=match_end
    _pad:           u32,
}

static_assert(SIZEOF(WorldState) == 56, "WorldState layout changed")
```

### 4.3 Memory Layout

All game state lives in a single pre-allocated arena sized at boot.
No dynamic allocation during match execution.

```
Arena layout (total ~2MB):
  [0x000000]  PlayerState SoA block    5,120 bytes   (64 players)
  [0x001400]  WorldState               56 bytes
  [0x001438]  History ring buffer      See section 5
  [0x100000]  Network receive buffers  See section 6
  [0x180000]  Event log write buffer   512 KB
  [0x200000]  (end)
```

```ostn
const ARENA_SIZE        = 0x200000    # 2MB total
const PLAYER_SOA_OFF    = 0x000000
const WORLD_STATE_OFF   = 0x001400
const HISTORY_OFF       = 0x001438
const NET_BUFFERS_OFF   = 0x100000
const EVENTLOG_BUF_OFF  = 0x180000

static_assert(ARENA_SIZE <= 0x200000, "Arena exceeds 2MB")
```

---

## 5. Lag Compensation and History

### 5.1 History Ring Buffer

The server keeps the last 128 ticks of player state for lag compensation.
At 64 ticks/second this is 2 seconds of history — sufficient for
up to 200ms of player latency with margin.

```ostn
const HISTORY_TICKS     = 128
const HISTORY_TICK_SIZE = SIZEOF_SOA(PlayerState, 64)   # 5120 bytes per tick
const HISTORY_SIZE      = HISTORY_TICKS * HISTORY_TICK_SIZE  # 655,360 bytes

static_assert(HISTORY_SIZE == 655360, "History buffer size changed")
```

The ring buffer is indexed by `tick % HISTORY_TICKS`.
Rewinding to tick T: `history_base + (T % HISTORY_TICKS) * HISTORY_TICK_SIZE`.

### 5.2 Hit Registration with Lag Compensation

```ostn
fn validate_hit {
    let shooter_id   = rdi    # u32
    let target_id    = rsi    # u32
    let claimed_tick = rdx    # u32 — tick the client claims the shot was fired
    let current_tick = rcx    # u32

    # validate claimed_tick is within lag compensation window
    let age = rax
    mov(u32)  age, current_tick
    sub(u32)  age, claimed_tick
    cmp(u32)  age, imm(HISTORY_TICKS)
    ja        reject_hit_stale    # too old, reject

    # rewind to claimed_tick and check hitbox
    # ... rewind logic using history ring buffer ...
    ret

    label reject_hit_stale:
        mov(u32) rax, imm(0)    # rejected
        ret
}
```

### 5.3 Client Lerp

Clients receive authoritative position snapshots every tick.
They lerp between the last two received positions for smooth rendering.
The server never sends rendering hints — only authoritative integer state.
The client is responsible for all visual smoothing.

---

## 6. Network Stack

### 6.1 UDP Packet Format

All game traffic uses raw UDP. No QUIC, no DTLS, no additional framing.

**Client → Server (Input Packet):**
```
Offset  Size  Field
0       4     magic: u32          0x4D524F57 ("MROW")
4       4     match_id_lo: u32    lower 32 bits of match ID
8       4     sequence: u32       client-side monotonic sequence
12      4     ack: u32            last server sequence acknowledged
16      4     player_id: u32
20      4     tick: u32           client's current tick estimate
24      24    input_payload       same layout as INPUT_MOVEMENT payload
48      4     checksum: u32       CRC32C of bytes 0–47
──────────────────────────────────────────────────────
Total:  52 bytes
```

**Server → Client (State Packet):**
```
Offset  Size  Field
0       4     magic: u32          0x4D524F57
4       4     match_id_lo: u32
8       4     server_tick: u32
12      4     sequence: u32       server-side monotonic
16      4     ack: u32            last client sequence acknowledged
20      N     delta_state         per-player delta from last acked state
```

State packets use delta compression — only changed fields are sent.
The delta format is fixed-width per player: 32 bytes per active player.

### 6.2 Reliability

Reliability for critical events (deaths, economy changes, round state)
is implemented as explicit retransmission with sequence numbers.
Movement inputs are unreliable — dropped packets are acceptable,
the server uses the last known input.

### 6.3 Receive Path

```ostn
fn process_packet {
    let buf  = rdi    provenance(extern)    # raw UDP payload
    let len  = rsi                          # payload length in bytes
    let from = rdx    provenance(extern)    # source IP:port as u64

    # validate minimum length
    cmp(u64)  len, imm(52)
    jb        drop_packet

    # validate magic
    mov(u32)  rax, deref(buf, 0)
    cmp(u32)  rax, imm(0x4D524F57)
    jne       drop_packet

    # validate checksum
    # ... CRC32C of bytes 0-47 vs bytes 48-51 ...

    # validate player_id
    mov(u32)  rax, deref(buf, 16)
    cmp(u32)  rax, imm(64)
    jae       drop_packet

    # dispatch to input handler
    call handle_input
    ret

    label drop_packet:
        ret
}
```

---

## 7. Server-Side Anticheat

### 7.1 Philosophy

Server-side anticheat in Marrow is fundamentally different from
client-side kernel anticheat. Client-side anticheat is an arms race —
it detects cheats by scanning for known signatures. Marrow's anticheat
works by making impossible states mathematically provable.

Because the simulation is deterministic fixed-point arithmetic,
"impossible" has a precise definition:
**any state that cannot be reached by any valid sequence of inputs
given the physics constraints.**

A cheat is not just detectable — it is permanently recorded in the
append-only event log and can be replayed and demonstrated to anyone.

### 7.2 Real-Time Validation Layer

Every input event is validated before being applied to game state.

**Movement validation:**
```ostn
fn validate_movement {
    let pid    = rdi    # player_id
    let dx     = rsi    # i32 delta_x in cm
    let dz     = rdx    # i32 delta_z in cm

    # compute movement distance squared (avoid sqrt — integer only)
    let dx64   = rax
    let dz64   = rcx
    movsx(i64) dx64, esi
    movsx(i64) dz64, edx
    imul(i64)  dx64, dx64
    imul(i64)  dz64, dz64
    add(i64)   dx64, dz64

    # compare against max_speed² per tick
    # max_speed = 1000 cm/tick = 10 m/tick at 64 tick/s ≈ 640 m/s
    # max_speed² = 1,000,000
    cmp(i64)   dx64, imm(MAX_SPEED_SQ)
    jg         flag_speed_hack

    ret

    label flag_speed_hack:
        call emit_anticheat_flag    # rdi=pid, rsi=FLAG_SPEED, rdx=SEVERITY_HIGH
        ret
}
```

**Teleport detection:**
```ostn
const MAX_POSITION_DELTA_CM = 200    # max 2 meters per tick
const MAX_POSITION_DELTA_SQ = MAX_POSITION_DELTA_CM * MAX_POSITION_DELTA_CM

fn validate_position_delta {
    # compare new position against last known position
    # if delta > max possible movement given velocity: flag
}
```

**Timing validation:**
```ostn
fn validate_input_timing {
    # inputs arriving faster than tick rate: flag
    # inputs with future timestamps: flag
    # inputs with sequence gaps suggesting dropped/injected: flag
}
```

### 7.3 Anticheat Flag Types

| Value  | Name                    | Severity | Description                            |
|--------|-------------------------|----------|----------------------------------------|
| 0x0001 | AC_SPEED_HACK           | HIGH     | Movement exceeds physics maximum       |
| 0x0002 | AC_TELEPORT             | CRITICAL | Position delta impossible in one tick  |
| 0x0003 | AC_INVALID_HIT          | HIGH     | Hit registered outside valid hitbox    |
| 0x0004 | AC_STALE_HIT            | MEDIUM   | Hit claimed for tick outside lag window|
| 0x0005 | AC_INPUT_RATE           | MEDIUM   | Inputs arriving faster than tick rate  |
| 0x0006 | AC_FUTURE_TIMESTAMP     | HIGH     | Input timestamp ahead of server time   |
| 0x0007 | AC_SEQUENCE_ANOMALY     | MEDIUM   | Input sequence gap or repeat           |
| 0x0008 | AC_INVENTORY_INVALID    | CRITICAL | Inventory state physically impossible  |
| 0x0009 | AC_ECONOMY_INVALID      | CRITICAL | Economy delta without valid source     |
| 0x000A | AC_RESPAWN_INVALID      | HIGH     | Respawn before death or cooldown       |
| 0x000B | AC_AIM_SNAP             | MEDIUM   | View angle delta exceeds human maximum |

### 7.4 Real-Time Enforcement

Real-time flags accumulate in `PlayerState.ac_score`.
Thresholds are configurable at boot via kernel cmdline parameters.

```
ac_score >= WARN_THRESHOLD:   log warning, increase monitoring
ac_score >= KICK_THRESHOLD:   disconnect player, flag account for review
ac_score >= BAN_THRESHOLD:    immediate disconnect, auto-submit for review
```

**No automated permanent bans.** All permanent actions require community review.

### 7.5 Post-Match Analysis

At match end, the complete event log is shipped to the audit server via TCP.
The audit server runs deep analysis unavailable during real-time play:

- Full deterministic replay to verify server state was never corrupted
- Statistical analysis of aim patterns across all flagged players
- Cross-player correlation (synchronized inputs suggesting botting)
- Comparison against population behavioral baseline
- ML anomaly detection on the complete 30-minute arc

The audit server is outside the unikernel — it runs on a standard OS
with access to the ML models from the Osteon ML spec.

### 7.6 Community Review System (Overwatch Model)

Matches with accumulated anticheat flags above a review threshold
are submitted to the community review queue.

**Review process:**
1. Flagged match submitted with relevant event log segments
2. Experienced players (reviewers) assigned based on hours played, accuracy history
3. Reviewers watch the replay (reconstructed from event log on client)
4. Reviewers vote: Guilty / Innocent / Insufficient Evidence
5. Majority verdict after minimum N reviewers (configurable)
6. Guilty verdict triggers account action (warning, suspension, ban)
7. All verdicts logged permanently — reviewer accuracy tracked

**Why community review is robust:**
- A human watching a replay of deterministically replayed events
  cannot be fooled by timestamp manipulation or injection
- The replay IS the ground truth — it's the event log replayed
- A cheater cannot fake innocence in replay because the replay
  is byte-for-byte deterministic from the server's event log
- False positives are caught by the community before action is taken

---

## 8. Unikernel Architecture

### 8.1 Boot Sequence

Target: complete boot and ready to accept players in **< 100ms**.

```
0ms    UEFI/multiboot2 handoff
5ms    GDT setup (3 entries: null, code64, data64)
6ms    IDT setup (interrupt handlers for timer, NIC, page fault)
8ms    Physical memory map from multiboot info
10ms   Identity-map first 4GB (sufficient for unikernel)
12ms   Enable SSE (required for any SIMD, even if not used in sim)
14ms   VirtIO-net device probe and init
20ms   VirtIO-blk device probe and init (for event log)
25ms   Pre-allocate game state arena (2MB, zero-initialized)
30ms   Open/create event log file on blk device
35ms   Parse match config from kernel cmdline
40ms   Initialize player SoA to default state
45ms   Write MATCH_START event to log
50ms   Bind UDP socket (game traffic port)
55ms   Bind TCP socket (audit server push port)
60ms   Send "ready" UDP beacon to matchmaker IP (from cmdline)
60ms+  Main game loop
```

### 8.2 Kernel Command Line Parameters

All match configuration is passed via kernel cmdline at boot.
No config files. No shell. No runtime reconfiguration.

```
match_id=<u64>              Unique match identifier
map_id=<u32>                Map identifier (physics bounds come from this)
max_players=<u8>            1-64
tick_rate=<u8>              Ticks per second (default 64)
matchmaker_ip=<ip>          IP to send ready beacon to
matchmaker_port=<u16>       Port for ready beacon
audit_ip=<ip>               Audit server IP for log delivery
audit_port=<u16>            Audit server TCP port
ac_warn_threshold=<u32>     Anticheat score for warning
ac_kick_threshold=<u32>     Anticheat score for kick
ac_ban_threshold=<u32>      Anticheat score for review submit
max_match_ticks=<u32>       Hard limit on match length (safety valve)
```

### 8.3 Main Game Loop

```ostn
fn game_loop {
    label tick_loop:
        # 1. receive and validate all pending UDP packets
        call drain_udp_recv_buffer

        # 2. apply validated inputs to game state
        call apply_inputs

        # 3. run physics tick (integer only)
        call simulate_tick

        # 4. run anticheat validation pass
        call validate_state

        # 5. write events to log buffer
        call flush_event_buffer

        # 6. send state updates to all connected players
        call send_state_updates

        # 7. check match end conditions
        call check_match_end
        test(u32) rax, rax
        jnz      match_end

        # 8. sleep until next tick
        call wait_next_tick

        jmp tick_loop

    label match_end:
        call write_match_end_event
        call flush_event_log_to_disk
        call ship_log_to_audit_server    # TCP push
        call write_match_summary
        hlt
}
```

### 8.4 Memory Map

```
Physical address space:
  0x0000_0000 – 0x0000_FFFF   Real mode legacy, unused
  0x0001_0000 – 0x001F_FFFF   Unikernel binary (~2MB)
  0x0020_0000 – 0x003F_FFFF   Game state arena (2MB)
  0x0040_0000 – 0x005F_FFFF   Network buffers (2MB)
  0x0060_0000 – 0x009F_FFFF   Event log write buffer (4MB)
  0x00A0_0000 – 0x00FF_FFFF   Stack (6MB)
  0x0100_0000 – 0x3FFF_FFFF   Available for future expansion
  0x4000_0000+                MMIO (VirtIO device registers)

Total RAM requirement: 64MB minimum, 128MB recommended
```

### 8.5 Interrupt Handlers

All written in Osteon. No hidden register saves.

```ostn
# Timer interrupt — fires every tick_interval_us
fn isr_timer {
    push(u64) rax
    push(u64) rcx
    push(u64) rdx
    push(u64) rsi
    push(u64) rdi
    push(u64) r8
    push(u64) r9
    push(u64) r10
    push(u64) r11

    call tick_handler    # advance tick counter, wake game loop

    # send EOI to APIC
    mov(u64) rax, imm(APIC_BASE)
    mov(u32) deref(rax, APIC_EOI_OFF), imm(0)

    pop(u64) r11
    pop(u64) r10
    pop(u64) r9
    pop(u64) r8
    pop(u64) rdi
    pop(u64) rsi
    pop(u64) rdx
    pop(u64) rcx
    pop(u64) rax
    iretq
}

# NIC interrupt — new UDP packet available
fn isr_nic {
    push(u64) rax
    push(u64) rcx
    push(u64) rdx
    push(u64) rsi
    push(u64) rdi

    call virtio_net_recv_handler

    mov(u64) rax, imm(APIC_BASE)
    mov(u32) deref(rax, APIC_EOI_OFF), imm(0)

    pop(u64) rdi
    pop(u64) rsi
    pop(u64) rdx
    pop(u64) rcx
    pop(u64) rax
    iretq
}
```

---

## 9. VirtIO Drivers

### 9.1 VirtIO-Net (UDP)

Marrow implements only the subset of VirtIO-Net required for UDP:
- Virtqueue initialization (receive + transmit)
- Descriptor ring management
- UDP packet receive and transmit
- No TCP offload, no checksum offload, no scatter-gather beyond single buffer

Packet buffers are fixed-size: 1500 bytes (standard MTU).
The receive ring holds 256 descriptors. The transmit ring holds 256 descriptors.

### 9.2 VirtIO-Blk (Event Log)

VirtIO-Blk is used exclusively for the append-only event log.
- Sequential writes only (append)
- No seek-backward ever
- 512-byte sector alignment (event log records are padded to sector boundary at flush)
- Write buffer flushed every N ticks (configurable, default every tick)

### 9.3 VirtIO-Console (Logging)

Serial console output for boot messages and critical errors only.
No interactive shell. Output is one-way.

---

## 10. Context Switch — There Is None

Marrow has no processes, no threads, no context switching.
The game loop runs on a single core. Everything is cooperative.

Network receive is interrupt-driven — the NIC interrupt fires,
the handler enqueues the packet, returns immediately.
The game loop processes the queue at the start of each tick.

Timer interrupt fires at tick_rate Hz. The game loop sleeps
(halts the CPU with `hlt` in a polling loop) until the timer fires.

This design is correct for the workload:
- 64 players × 64 ticks/second = 4,096 inputs to process per second
- Each input is validated in ~100 instructions
- Each tick simulation is ~10,000 instructions
- A modern CPU does ~3 billion instructions/second
- CPU utilization at 64 players 64Hz is approximately **0.3%**

The server is not CPU-bound. It is network-bound and latency-bound.
A single-core single-threaded design is correct and sufficient.

---

## 11. Audit Server Interface

### 11.1 TCP Push Protocol

At match end, the unikernel opens a TCP connection to the audit server
and pushes the complete event log. Simple, reliable, one-way.

**Protocol:**
```
Client (unikernel) → Server (audit):
  [4 bytes]  magic: 0x4D524F57
  [8 bytes]  match_id: u64
  [8 bytes]  log_size: u64         total bytes to follow
  [4 bytes]  record_count: u32
  [4 bytes]  checksum: u32         CRC32C of header bytes 0-19
  [N bytes]  event_log             raw event log bytes

Server → Client:
  [4 bytes]  ack: u32              0x00000001 = received OK
                                   0x00000000 = rejected (checksum fail)
```

The unikernel closes the TCP connection after receiving the ack and halts.
If no ack is received within 30 seconds, the unikernel retries once then halts.

### 11.2 Match Summary Push

After the event log, the unikernel pushes a compact match summary:

```
[4 bytes]  magic: 0x53554D4D
[8 bytes]  match_id: u64
[4 bytes]  duration_ticks: u32
[4 bytes]  player_count: u32
[64×4 bytes] per_player_ac_scores   u32 per player
[64×4 bytes] per_player_flags       u32 bitmask per player
[4 bytes]  total_ac_flags: u32
[4 bytes]  checksum: u32
```

The audit server uses this to decide whether the match needs deep analysis.
Matches with zero anticheat flags skip the ML analysis queue.

---

## 12. Implementation Roadmap

```
Phase 0 — Osteon foundation (prerequisite)
  Osteon compiler with x86-64 COFF emit working
  Fixed-point arithmetic test suite passing
  SoA struct layout verified by static_assert

Phase 1 — Minimal boot (4-6 weeks)
  Multiboot2 handoff
  GDT + IDT setup in Osteon
  Identity paging
  Serial console output
  Halt

Phase 2 — Memory and VirtIO (4-6 weeks)
  Physical memory allocator
  Arena allocator (pre-sized)
  VirtIO-Net basic init
  VirtIO-Blk basic init
  UDP send/receive loopback test

Phase 3 — Game loop skeleton (4-6 weeks)
  Tick timer via APIC
  UDP packet receive path
  Input validation (movement, timing)
  Game state arena initialized
  Event log write path
  Match start/end events

Phase 4 — Simulation and anticheat (6-8 weeks)
  Fixed-point physics tick
  Lag compensation history buffer
  Hit registration with rewind
  Full real-time anticheat validation suite
  Anticheat flag emission to event log

Phase 5 — Audit and community review (4-6 weeks)
  TCP event log push to audit server
  Match summary push
  Audit server (separate service, standard OS)
  Community review queue backend
  Replay reconstruction from event log

Phase 6 — Hardening and performance (ongoing)
  PGO profiling of game loop hot paths
  SIMD for multi-player state update
  Fuzz testing of packet receive path
  Sanitizer testing of all pointer dereferences
  Load testing at 64 players 64Hz
```

---

## 13. Kernel Cmdline Boot Example

```
marrow.elf
  match_id=9821034567
  map_id=3
  max_players=64
  tick_rate=64
  matchmaker_ip=10.0.0.1
  matchmaker_port=7000
  audit_ip=10.0.0.2
  audit_port=7001
  ac_warn_threshold=10
  ac_kick_threshold=50
  ac_ban_threshold=100
  max_match_ticks=115200
```

`max_match_ticks=115200` = 64 ticks/sec × 60 sec × 30 min = 30 minute hard limit.

---

## 14. Security Properties

| Property                         | Mechanism                                   |
|----------------------------------|---------------------------------------------|
| No remote code execution surface | No shell, no scripting, no dynamic loading  |
| No privilege escalation          | Single ring 0 process, no user/kernel split |
| No persistent state between matches | Unikernel exits after every match        |
| Cheat evidence is irrefutable    | Append-only deterministic event log         |
| No false ban without review      | Community review required for permanent action |
| Minimal attack surface           | UDP + TCP only, fixed packet formats, magic validation |
| No third-party kernel driver     | Server-side — player installs nothing       |
| Memory isolation between matches | Each match is a fresh VM instance           |

---

## 15. Why This is Comparable to Kernel-Level Client Anticheat

Client-side kernel anticheat (Vanguard, EAC kernel mode):
- Scans for known cheat signatures → arms race, always behind
- Hooks kernel calls → bypassed by new injection methods
- Requires trusting a third-party ring-0 driver → security/privacy risk
- Detects cheats probabilistically → false positives
- Evidence is forensic → lawyers argue about it

Marrow server-side anticheat:
- Validates against mathematical impossibility → no arms race
- Requires no client installation → no privacy risk
- Evidence is the deterministic replay → irrefutable, replayable by anyone
- False positives caught by community review before action
- A cheater cannot retroactively alter their event log
- Works even if the client is fully compromised

The fundamental advantage: **Marrow doesn't care what software runs on
the client. It only validates what the server received.** A wallhack that
shows enemies through walls is invisible to Marrow. A speedhack that moves
the player faster than physics allows is caught on the first tick it occurs
and permanently recorded.

---

## Version History

| Version | Notes                                                    |
|---------|----------------------------------------------------------|
| 0.1.0   | Initial spec. UDP-only, 64 players, 64Hz, fixed-point,   |
|         | append-only event log, community review anticheat,       |
|         | serverless deployment model, single-core single-threaded |

---

*Marrow — the server is the truth.*