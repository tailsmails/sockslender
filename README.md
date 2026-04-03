## Quick start (copy - paste - enter)
```sh
apt update -y && apt install -y git clang make && if ! command -v v >/dev/null 2>&1; then git clone --depth=1 https://github.com/vlang/v && cd v && make && ./v symlink && cd ..; fi && git clone --depth=1 https://github.com/tailsmails/sockslender && cd sockslender && v -enable-globals -prod sockslender.v -o sockslender && ln -sf $(pwd)/sockslender $PREFIX/bin/sockslender && sockslender
```

<p align="center">
  <h1 align="center">SockSlender</h1>
  <p align="center">
    <b>Lightweight, multi-protocol proxy router & chain manager with DPI desync</b>
  </p>
  <p align="center">
    Written in <a href="https://vlang.io">V</a> — Single binary, zero dependencies, blazing fast
  </p>
  <p align="center">
    <img src="https://img.shields.io/badge/language-V-5D87BF?style=flat-square" />
    <img src="https://img.shields.io/badge/platform-Linux%20%7C%20Android%20%7C%20macOS%20%7C%20Windows-green?style=flat-square" />
    <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" />
    <img src="https://img.shields.io/badge/protocols-SOCKS5%20%7C%20HTTP%20%7C%20SNI%20%7C%20DNS-orange?style=flat-square" />
  </p>
</p>

---

## What is SockSlender?

SockSlender is a **proxy chain router** that combines multiple proxy servers into
intelligent routing chains with **DPI evasion**, automatic failover, health monitoring,
and smart server selection.

Think of it as a **programmable proxy multiplexer with built-in anti-censorship** —
receive connections on one side, route them through chains of proxies on the other side,
while actively defeating Deep Packet Inspection.

```
              ┌─────────────────┐
 Client ────→│   SockSlender     │ ──→ Proxy A ──→ Proxy B ──→ Internet             
               │                  │ ──→ Proxy C ──→ Internet (failover)
 Client ────→ │ Script Engine:  │ ──→ Proxy D ──→ Internet (fastest)
                │  L7: byte patch│
 Client ────→ │  L3: TTL/TOS    │
               │  L3R: DPI desync │
 DNS    ────→│  DNS forwarding   │ ──→ DNS Server 1 / DNS Server 2
              └─────────────────┘
```

---

## Quick Start

### Build

```bash
v -prod -cc gcc sockslender.v
```

### Basic Usage

```bash
# SOCKS5 listener → upstream proxy
./sockslender -l socks5://0.0.0.0:1080 -u socks5://proxy:1234

# HTTP listener → chain of two proxies
./sockslender -l http://0.0.0.0:8080 -u socks5://first:1010+socks5://second:2020

# SNI listener with DPI desync (no root needed)
./sockslender -l sni://0.0.0.0:443 -u 'sni://backend:443?L3R:split=3?'

# SNI listener with full DPI desync (root required)
./sockslender -l sni://0.0.0.0:443 -u 'sni://backend:443?L3R:fake=3,L3R:split=3?'

# DNS forwarder
./sockslender -l dns://0.0.0.0:53 -u dns://8.8.8.8:53
```

---

## Table of Contents

- [Features](#-features)
- [Protocols](#-protocols)
- [Arguments Reference](#-arguments-reference)
- [Chain Syntax](#-chain-syntax)
- [Routing Modes](#-routing-modes)
- [Authentication](#-authentication)
- [Smart Chain Selection](#-smart-chain-selection)
- [Script Engine — L7 (Application Layer)](#-script-engine--l7-application-layer)
- [Script Engine — L3 (Network Layer)](#-script-engine--l3-network-layer)
- [Script Engine — L3R (Raw Socket DPI Desync)](#-script-engine--l3r-raw-socket-dpi-desync)
- [Process Management](#-process-management)
- [Multi-Box Architecture](#-multi-box-architecture)
- [Advanced Examples](#-advanced-examples)
- [Platform Notes](#-platform-notes)
- [Architecture](#-architecture)

---

## Features

| Feature | Description |
|---|---|
| **Multi-Protocol** | SOCKS5, HTTP CONNECT, SNI/TLS, DNS (UDP) |
| **Chain Proxying** | Connect unlimited proxies in sequence with `+` |
| **Smart Routing** | Auto-selects fastest & most reliable server |
| **Health Monitoring** | Continuous health checks with circuit breaker |
| **Failover** | Automatic fallback when upstream dies |
| **Authentication** | Username/password for listeners & upstreams |
| **L7 Script Engine** | Modify payload bytes on-the-fly |
| **L3 Socket Options** | TTL, TOS, MARK, interface binding |
| **L3R DPI Desync** | Raw socket: fake, RST, split, disorder, OOB, segmentation |
| **Process Manager** | Launch, monitor & auto-restart background processes |
| **ProxyChains Tunnel** | Tunnel child processes through chain segments |
| **Multi-Box** | Run independent proxy instances in one process |
| **UDP Associate** | Full SOCKS5 UDP support |
| **FD Auto-Tuning** | Automatically raises file descriptor limits on Linux |
| **Zero Dependencies** | Single static binary, no runtime deps |

---

## Protocols

### SOCKS5

Full SOCKS5 implementation with CONNECT, UDP ASSOCIATE, and username/password authentication.

```bash
./sockslender -l socks5://0.0.0.0:1080 -u socks5://upstream:1234
./sockslender -l socks5://admin:secret@0.0.0.0:1080 -u socks5://user:pass@upstream:1234
```

### HTTP CONNECT

HTTP proxy with CONNECT method support and Basic authentication.

```bash
./sockslender -l http://0.0.0.0:8080 -u socks5://upstream:1234
./sockslender -l http://user:pass@0.0.0.0:8080 -u http://user:pass@upstream:8080
```

### SNI (TLS Passthrough)

Extracts hostname from TLS ClientHello SNI extension and routes accordingly.
No TLS termination — traffic passes through encrypted.

```bash
./sockslender -l sni://0.0.0.0:443 -u sni://backend:443
```

### DNS (UDP)

DNS query forwarding over UDP with automatic failover between DNS servers.

```bash
./sockslender -l dns://0.0.0.0:53 -u dns://8.8.8.8:53 -u dns://1.1.1.1:53
```

---

## Arguments Reference

| Argument | Description | Example |
|---|---|---|
| `-l URI` | Add a listener | `-l socks5://0.0.0.0:1080` |
| `-u CHAIN` | Add global upstream chain | `-u socks5://a:1010+socks5://b:2020` |
| `-i CHAIN` | Add internal chain (with `-x`) | `-i proxy:1010+-xsocks5://0.0.0.0:2020` |
| `-o CHAIN` | Append to all chains (outbound) | `-o socks5://exit:9050` |
| `-v` | Enable verbose/packet dump mode | `-v` |
| `-r?CMD?` | Run background command | `-r?tor --SocksPort 9050?` |
| `-rr?CMD,EP?` | Run + auto-restart on failure | `-rr?tor,127.0.0.1:9050?` |
| `-rrr?CMD,EP?` | Run via proxychains tunnel (Linux) | `-rrr?tor,127.0.0.1:9050?` |
| `::` | Separator between independent Boxes | `... :: ...` |

---

## Chain Syntax

Chains are built by connecting nodes with `+`:

```
PROTOCOL://[USER:PASS@]HOST:PORT[?SCRIPT?]
```

### Simple Chain

```bash
-u socks5://proxy:1234
-u socks5://first:1010+socks5://second:2020
-u socks5://entry:1010+http://middle:8080+socks5://exit:9050
```

### Chain with Macros (Snapshots)

Save and reuse chain segments using uppercase names:

```bash
-u socks5://a:1010+socks5://b:2020+-xENTRY \
-u ENTRY+socks5://c:3030 \
-u ENTRY+socks5://d:4040
```

### Mid-Chain Listener (`-x`)

Split a chain and create a listener at any point:

```bash
-i socks5://a:1010+socks5://b:2020+-xsocks5://0.0.0.0:4040+socks5://c:3030
```

```
Listener on :4040 → Chain [a:1010, b:2020]     (only nodes before -x)
Upstream chain   → [a:1010, b:2020, c:3030]     (full chain)
```

### Outbound Append (`-o`)

Append nodes to ALL existing chains:

```bash
-u socks5://a:1010 -u socks5://b:2020 -o socks5://exit:9050
# Chain 0: a:1010 → exit:9050
# Chain 1: b:2020 → exit:9050
```

---

## Routing Modes

### Global Upstream (`-u`)

All listeners share these chains. Best chain is auto-selected:

```bash
./sockslender \
  -l socks5://0.0.0.0:1080 \
  -l http://0.0.0.0:8080 \
  -u socks5://fast-server:1010 \
  -u socks5://backup-server:2020
```

### Dedicated Routing (`-i` with `-x`)

Bind specific chains to specific listeners:

```bash
./sockslender \
  -l socks5://0.0.0.0:1080 \
  -u socks5://default-proxy:1010 \
  -i socks5://special-proxy:2020+-xhttp://0.0.0.0:8080
```

---

## Authentication

```bash
# Listener auth
-l socks5://admin:secret123@0.0.0.0:1080
-l http://user:pass@0.0.0.0:8080

# Upstream auth
-u socks5://myuser:mypass@proxy:1234

# Combined
./sockslender \
  -l socks5://admin:local@0.0.0.0:1080 \
  -u socks5://remote:pass@proxy:1234
```

---

## Smart Chain Selection

### Scoring Formula

```
Score = Reliability² × Speed

Reliability = success_count / total_count
Speed       = 1,000,000 / (EMA_latency + 100)
EMA         = 0.7 × previous + 0.3 × current
```

### Circuit Breaker

```
Failure 1-2:  Still tried (with penalty)
Failure 3+:   Disabled for 30 seconds
After 30s:    One probe attempt
Probe OK:     Fully restored
Probe FAIL:   Disabled again
```

### Example

```
Server A: 95% reliable, 50ms  → Score: 17.0  ★ Selected
Server B: 70% reliable, 100ms → Score:  4.6
Server C: 3 consecutive fails  → Score:  0.001 (disabled)
```

---

## Script Engine — L7 (Application Layer)

Modify packet payload bytes on-the-fly. Works on **all platforms**.

### Syntax

Scripts are embedded in URIs between `?` markers:

```
socks5://proxy:1234?SCRIPT?
```

### Unconditional Byte Patch

```bash
-u 'socks5://proxy:1234?0-1=0505?'
```

### Conditional Patch (if/else)

```bash
# If byte 0 is 0x16 (TLS), set byte 5 to 0x01
-u 'sni://proxy:443?5-5=01 if 0-0=16?'

# If/else
-u 'socks5://proxy:1234?3-3=01 if 0-1=0500 el 7-7=FF?'
```

### AOB Pattern Matching

```bash
# Find pattern, patch relative offset
-u 'sni://proxy:443?1603__01 if 2-2=03?'
```

### Multiple Rules

```bash
-u 'socks5://proxy:1234?0-0=05, 3-3=01 if 0-0=16?'
```

### Use Cases

| Use Case | Script | Description |
|---|---|---|
| Anti-DPI byte patch | `0-0=17` | Change TLS record type |
| SNI modification | AOB pattern match | Replace hostname bytes |
| Protocol fix | `1-1=00 if 1-1=01` | Fix buggy proxy responses |
| Fingerprint change | `46-47=c02c` | Alter cipher suite order |
| Debug marker | `0-3=DEADBEEF` | Inject Wireshark marker |

---

## Script Engine — L3 (Network Layer)

Control socket and IP header behavior. **Linux/macOS only.**

### Syntax

```
L3:key=value
```

### No Root Required

| Key | Description | Values | Use Case |
|---|---|---|---|
| `ttl` | IP Time-To-Live | `1`-`255` | DPI evasion, hop limiting |
| `tos` | Type of Service / DSCP | `0x00`-`0xFF` | QoS, traffic priority |
| `df` | Don't Fragment | `0`=off, `2`=on | Control fragmentation |
| `nodelay` | TCP Nagle algorithm | `0`=off, `1`=on | Reduce latency |
| `keepalive` | TCP Keep-Alive | `0`=off, `1`=on | Survive NAT timeouts |

### Root Required

| Key | Description | Values | Use Case |
|---|---|---|---|
| `mark` | Packet fwmark | integer | Policy routing with iptables |
| `bind` | Bind to interface | `eth0`, `tun0`... | Force traffic path |
| `tproxy` | Transparent proxy | `0`/`1` | Intercept without redirect |

### Examples

```bash
# Low latency gaming/VoIP
-u 'socks5://proxy:1234?L3:tos=0xB8,L3:nodelay=1,L3:keepalive=1?'

# Policy routing (root)
-u 'socks5://proxy:1234?L3:mark=100?'
# Then: ip rule add fwmark 100 table vpn

# Force VPN interface (root)
-u 'socks5://proxy:1234?L3:bind=tun0?'

# DPI evasion with TTL
-u 'sni://proxy:443?L3:ttl=3?'
```

### TOS/DSCP Quick Reference

| TOS Value | DSCP | Priority | Best For |
|---|---|---|---|
| `0x10` | CS1 | Low delay | Interactive |
| `0x08` | — | High throughput | Bulk transfer |
| `0x28` | AF11 | Assured Forward | Business |
| `0xB8` | EF | Expedited Forward | VoIP, gaming |

---

## Script Engine — L3R (Raw Socket DPI Desync)

Advanced DPI evasion using raw sockets. Similar techniques to **zapret**, **GoodbyeDPI**,
and **ByeDPI**, integrated directly into SockSlender's Script Engine.

### How DPI Desync Works

```
Normal (DPI sees everything):
  Client ──[TLS ClientHello]──→ DPI ──→ Server
                                 ↓
                              BLOCKED!

With Desync (DPI confused):
  Client ──[Fake garbage TTL=3]──→ Router ──→ Router ──→ 💀 (dies)
  Client ──[Real ClientHello]───→ Router ──→ Router ──→ DPI ──→ Server
                                                         ↓
                                              Confused by fake → PASS ✅
```

### Syntax

```
L3R:technique=value
```

### Available Techniques

| Technique | Root? | Description | Effectiveness |
|---|---|---|---|
| `split=N` | ❌ | Split first packet at byte N | ★★★☆☆ Good vs simple DPI |
| `seg=N` | ❌ | Send in N-byte micro-segments | ★★★☆☆ Good but slow |
| `oob=HEX` | ❌ | Send TCP urgent/OOB data | ★★☆☆☆ Some DPI |
| `fake=TTL` | ✅ | Fake packet with low TTL | ★★★★★ Best vs stateful DPI |
| `rst=TTL` | ✅ | Fake TCP RST with low TTL | ★★★★☆ Great vs session DPI |
| `disorder=N` | ✅ | Send part 2 before part 1 | ★★★★☆ Great vs reassembly |

### `L3R:split=N` — No Root Needed

Splits the first packet at byte position N:

```bash
-u 'sni://proxy:443?L3R:split=3?'
```

```
Without split:
  [16 03 01 02 00 01 00 ... hostname ...]
  DPI: "TLS ClientHello to blocked.com" → BLOCK

With split=3:
  Segment 1: [16 03 01]
  Segment 2: [02 00 01 00 ... hostname ...]
  DPI: can't reassemble → PASS ✅
```

### `L3R:seg=N` — No Root Needed

Send in N-byte segments with 1ms delay:

```bash
-u 'sni://proxy:443?L3R:seg=1?'   # 1-byte segments (slow but effective)
-u 'sni://proxy:443?L3R:seg=5?'   # 5-byte segments (balanced)
```

### `L3R:oob=HEX` — No Root Needed

Send TCP Out-of-Band urgent data:

```bash
-u 'sni://proxy:443?L3R:oob=41?'
```

### `L3R:fake=TTL` — Root Required

Send garbage packet with low TTL. DPI sees fake, real passes:

```bash
-u 'sni://proxy:443?L3R:fake=3?'
```

```
Hop 1        Hop 2        Hop 3        Hop 4 (DPI)    Server
[Fake TTL=3] [Fake TTL=2] [Fake TTL=1]  💀 dead
[Real TTL=64][Real TTL=63][Real TTL=62] [Real TTL=61] ✅
                                         DPI confused!
```

### `L3R:rst=TTL` — Root Required

Fake TCP RST. DPI thinks connection closed:

```bash
-u 'sni://proxy:443?L3R:rst=3?'
```

### `L3R:disorder=N` — Root Required

Send second part first via raw socket:

```bash
-u 'sni://proxy:443?L3R:disorder=5?'
```

### Combo Examples

```bash
# Maximum evasion (Root)
-u 'sni://proxy:443?L3R:fake=3,L3R:split=3?'

# Medium evasion (No Root)
-u 'sni://proxy:443?L3R:oob=41,L3R:split=5?'

# Full stack — all layers (Root)
-u 'sni://proxy:443?L3R:fake=4,L3R:rst=3,L3R:split=3,L3:ttl=8,L3:tos=0x10,0-0=17?'

# Anti-censorship Tor (Root)
./sockslender \
  -l sni://0.0.0.0:443 \
  -u 'sni://127.0.0.1:9050?L3R:fake=3,L3R:split=3?' \
  '-rrr?tor --SocksPort 9050,127.0.0.1:9050?'
```

### Processing Order

```
connect_chain():
  1. TCP handshake
  2. apply_l3() → setsockopt (TTL, TOS, MARK, BIND...)

First data packet:
  3. L3R:fake    → raw socket: garbage with low TTL
  4. L3R:rst     → raw socket: fake RST with low TTL
  5. L3R:oob     → TCP urgent byte
  6. L3R:split   → first half, 1ms delay, second half
     OR L3R:disorder → second half raw, first half normal
     OR L3R:seg   → N-byte chunks with 1ms gaps

Subsequent packets:
  7. Normal relay with L7 scripts (offset, aob, if/el)
```

---

## Process Management

### Simple Background Task (`-r`)

```bash
-r?tor --SocksPort 9050?
-r?tor --SocksPort 9050, sslocal -c ss.json?
```

### Auto-Restart Watchdog (`-rr`)

```bash
-rr?tor --SocksPort 9050,socks5://127.0.0.1:9050?
-rr?ssh -D 1080 user@server,127.0.0.1:1080?
```

**Watchdog behavior:**
- Checks every 15 seconds
- Exponential backoff: 30s → 60s → 120s → 240s → 300s (max)
- Distinguishes CRASH vs FREEZE
- Resets backoff when service recovers

### ProxyChains Tunnel (`-rrr`) — Linux/Android

Tunnel a command through chain nodes **before** its endpoint:

```bash
./sockslender \
  -l socks5://0.0.0.0:1080 \
  -u 'socks5://proxy1:1010+socks5://proxy2:2020+socks5://127.0.0.1:9050+socks5://exit:3030' \
  '-rrr?tor --SocksPort 9050,127.0.0.1:9050?'
```

```
Result: tor tunneled via proxy1 → proxy2 → internet
  tor ──proxychains4──→ proxy1:1010 → proxy2:2020 → internet
  Full chain: client → proxy1 → proxy2 → tor → exit:3030
```

### Supported via Process Manager

```
VMess/VLESS:    -rr?v2ray,127.0.0.1:10808?
Trojan:         -rr?trojan-go,127.0.0.1:1080?
Shadowsocks:    -rrr?ss-local,127.0.0.1:1089?
WireGuard:      -r?wg-quick up wg0?
OpenVPN:        -rr?openvpn --config x.ovpn,sni://...?
SSH Tunnel:     -rr?ssh -D 1080 user@host,127.0.0.1:1080?
Tor:            -rrr?tor --SocksPort 9050,127.0.0.1:9050?
Hysteria:       -rr?hysteria client,127.0.0.1:1080?
NaiveProxy:     -rr?naive --listen=...,127.0.0.1:...?
MTProto:        -rr?mtg run ...,127.0.0.1:443?
```

**= Any CLI tool with a listening port can be managed by SockSlender.**

---

## 📦 Multi-Box Architecture

Run independent proxy instances in a single process:

```bash
./sockslender \
  -l socks5://0.0.0.0:1080 -u socks5://proxy-a:1010 \
  :: \
  -l http://0.0.0.0:8080 -u socks5://proxy-b:2020 \
  :: \
  -l dns://0.0.0.0:5353 -u dns://8.8.8.8:53
```

Each Box has independent listeners, chains, health checking, and scoring.

---

## Advanced Examples

### Full Anti-Censorship Setup

```bash
./sockslender \
  -v \
  -l socks5://admin:pass@0.0.0.0:1080 \
  -l sni://0.0.0.0:443 \
  -l dns://0.0.0.0:53 \
  -u 'sni://server1:443?L3R:fake=3,L3R:split=3,L3:nodelay=1?' \
  -u 'sni://server2:443?L3R:fake=4,L3R:split=5?' \
  -u dns://8.8.8.8:53 \
  -u dns://1.1.1.1:53
```

### Tor over Proxychains with DPI Desync

```bash
./sockslender \
  -l socks5://0.0.0.0:1080 \
  -u 'socks5://entry:1010+socks5://127.0.0.1:9050?L3R:fake=3?' \
  '-rrr?tor --SocksPort 9050,127.0.0.1:9050?'
```

### Multi-Path with Macros

```bash
./sockslender \
  -i 'socks5://us:1010+socks5://us2:2020+-xUS' \
  -i 'socks5://eu:3030+socks5://eu2:4040+-xEU' \
  -u US+socks5://final-us:9090 \
  -u EU+socks5://final-eu:9090 \
  -i US+-xsocks5://0.0.0.0:2080 \
  -i EU+-xsocks5://0.0.0.0:3080 \
  -l socks5://0.0.0.0:1080
```

### V2Ray + Chain + Script Fix

```bash
./sockslender \
  -l socks5://0.0.0.0:1080 \
  -u 'socks5://entry:1010+socks5://127.0.0.1:10808?1-1=00 if 1-1=01?' \
  -rr?v2ray run -c config.json,socks5://127.0.0.1:10808?
```

---

## Platform Notes

### Linux / Android

- **FD Limits:** Automatically raised on startup
- **L3 Socket Options:** Fully supported
- **L3R DPI Desync:** Fully supported (root for fake/rst/disorder)
- **`-rrr`:** Supported (requires `proxychains4`)

### macOS

- **FD Limits:** Automatically raised
- **L3 Socket Options:** Partially supported (no MARK/BIND)
- **L3R DPI Desync:** split/seg/oob work, raw socket limited
- **`-rrr`:** Supported via `proxychains-ng`

### Windows

- **FD Limits:** N/A
- **L3/L3R:** Not available
- **L7 Script Engine:** Fully supported
- **All other features:** Fully supported
- **`-rrr`:** Not available

---

### Script Engine Layer Stack

```
Processing order per connection:
─────────────────────────────────────
1. TCP connect
2. L2: SO_BINDTODEVICE         (which NIC)
3. L3: setsockopt TTL/TOS/MARK (IP header behavior)
4. L4: setsockopt NODELAY/KEEPALIVE (TCP behavior)
5. Protocol handshake (SOCKS5/HTTP)
6. First packet:
   a. L3R: fake/rst via raw socket
   b. L3R: split/disorder/seg/oob
7. L7: byte patch, AOB scan    (every packet)
8. Relay
```

---

## License

MIT License — use it however you want.

---

<p align="center">
  <b>SockSlender</b> — Route smarter, not harder.
</p>