# 272NPU-MAC-HUB

A SystemVerilog implementation of a Multiply-Accumulate (MAC) engine hub for a Neural Processing Unit (NPU), developed as part of a 272 SoC Design course project.

## Overview

This project implements a ring-bus-based NPU accelerator architecture consisting of two modules:

- **`hub.sv`** — Central routing hub connecting a testbench interface to multiple ring buses, each carrying MAC compute engines.
- **`mulacc.sv`** — A configurable MAC engine that fetches data and coefficients from memory via the ring bus, computes 42-element dot products using a custom 12-bit floating-point format, and returns results.

The design supports up to 8 independent MAC engines (device IDs 8–15) spread across 4 ring buses.

## Architecture

```
                        ┌───────────┐
                        │    Hub    │
          Testbench ───>│           │<─── Ring 0 (Engines 8, 9)
                        │  (hub.sv) │<─── Ring 1 (Engines 10, 11)
          Testbench <───│           │<─── Ring 2 (Engines 12, 13)
                        └───────────┘<─── Ring 3 (Engines 14, 15)

          Each ring:  [Engine N] ──> [Engine N+1] ──> (loopback)
                      (mulacc.sv)    (mulacc.sv)
```

### Ring Bus Protocol

Communication uses a packet-based ring bus (`RBUS` struct) with a token-passing mechanism. Packet types include:

| Opcode       | Description                              |
|--------------|------------------------------------------|
| `EMPTY`      | No payload, may carry the token          |
| `IDLE`       | Engine idle heartbeat                    |
| `WRITE_REQ`  | Config write to a specific engine        |
| `READ_REQ`   | Memory read request (data/coefficients)  |
| `READ_RESP`  | Memory read response                     |

Each packet carries: `Opcode`, `Source`, `Destination`, `Token`, and `Data`.

## Modules

### `hub.sv`

The hub serves as the central interconnect between the testbench and the four ring buses.

**Ports:**

| Port    | Direction | Description              |
|---------|-----------|--------------------------|
| `clk`   | Input     | System clock             |
| `reset` | Input     | Synchronous reset        |
| `tbin`  | Input     | Testbench → Hub packet   |
| `tbout` | Output    | Hub → Testbench packet   |
| `R0in`  | Input     | Ring 0 incoming          |
| `R0out` | Output    | Ring 0 outgoing          |
| `R1in`  | Input     | Ring 1 incoming          |
| `R1out` | Output    | Ring 1 outgoing          |
| `R2in`  | Input     | Ring 2 incoming          |
| `R2out` | Output    | Ring 2 outgoing          |
| `R3in`  | Input     | Ring 3 incoming          |
| `R3out` | Output    | Ring 3 outgoing          |

**Routing logic:**

- Testbench packets are forwarded to the appropriate ring based on destination device ID:
  - IDs 8–9 → Ring 0
  - IDs 10–11 → Ring 1
  - IDs 12–13 → Ring 2
  - IDs 14–15 → Ring 3
- Ring packets addressed to destination `0` are forwarded to the testbench using a round-robin priority arbiter across the four rings.
- All other ring packets are recirculated on their respective ring.

### `mulacc.sv`

Each MAC engine is an independent compute node on a ring bus. It is configured via `WRITE_REQ` packets and autonomously fetches operands, computes dot products, and streams results.

**Ports:**

| Port        | Direction | Description                          |
|-------------|-----------|--------------------------------------|
| `clk`       | Input     | System clock                         |
| `reset`     | Input     | Synchronous reset                    |
| `bin`       | Input     | Ring bus input                       |
| `bout`      | Output    | Ring bus output                      |
| `resout`    | Output    | Computation result output            |
| `f1wadr/f1wdata/f1write/f1radr/f1rdata` | I/O | FIFO 1 (data) interface |
| `f2wadr/f2wdata/f2write/f2radr/f2rdata` | I/O | FIFO 2 (coefficients) interface |
| `device_id` | Input     | 4-bit unique engine ID               |

**State machine:**

```
STATE_IDLE → WAIT_TOKEN → SEND_DATA_REQ → WAIT_DATA_RESP
           → SEND_COEF_REQ → WAIT_COEF_RESP → PREP_READ
           → FIFO_LATENCY → FEED_DATAPATH → COMPUTING
           → (loop for NumGroups iterations)
```

**Configuration registers (set via `WRITE_REQ`):**

| Field          | Description                                |
|----------------|--------------------------------------------|
| `DataAddress`  | 48-bit base address for input data         |
| `CoefAddress`  | 48-bit base address for coefficients       |
| `NumGroups`    | Number of compute groups to process        |
| `ChainAddress` | Address for chained/cascaded results       |

**Compute datapath:**

Each compute cycle processes **42 elements** from two FIFOs (data + coefficients), in two passes (lower and upper halves of the 1008-bit FIFO word). Each element is encoded in a **custom 12-bit floating-point format**:

```
[ sign (1) | exponent (5, 2's complement) | mantissa (6) ]
```

The MAC operation is:

```
result = Σ (data[i] × coef[i])   for i in 0..41  (per pass)
```

Zero is encoded as `0x7FF` (all-ones exponent/mantissa) or `0x000`.

## File Structure

```
272NPU-MAC-HUB/
├── hub.sv       # Central hub: testbench ↔ ring bus routing
└── mulacc.sv    # MAC compute engine: ring bus node with FIFO-based datapath
```

## Requirements

- SystemVerilog-compatible simulator (e.g., ModelSim, VCS, Questa, Xcelium)
- The design uses custom structs (`RBUS`, `RESULT`, `REGS`, `FifoAddr`, `FifoData`) and enums (`EMPTY`, `IDLE`, `WRITE_REQ`, etc.) that must be defined in a shared package or included header file.

## Usage

1. Define the shared types (`RBUS`, `RESULT`, `FifoAddr`, `FifoData`, `REGS`, and opcode enums) in a package file.
2. Instantiate `hub` as the top-level interconnect.
3. Instantiate one `mulacc` per engine and connect each to the appropriate ring bus output of the hub.
4. Use `WRITE_REQ` packets from the testbench to configure each engine's `DataAddress`, `CoefAddress`, `NumGroups`, and `ChainAddress`.
5. After configuration, each engine autonomously fetches data and coefficients and computes results.

## Course Context

This project was developed for **CMPE/ECE 272 – SoC Design**, exploring ring-bus-based NPU microarchitectures, custom floating-point representations, and hardware–software co-design principles.
