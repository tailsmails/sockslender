## Quick start (copy - paste - enter)
```sh
apt update -y && apt install -y git clang make && if ! command -v v >/dev/null 2>&1; then git clone --depth=1 https://github.com/vlang/v && cd v && make && ./v symlink && cd ..; fi && git clone --depth=1 https://github.com/tailsmails/sockslender && cd sockslender && v -enable-globals -prod sockslender.v -o sockslender && ln -sf $(pwd)/sockslender $PREFIX/bin/sockslender && sockslender
```

---

<p align="center">
  <h1 align="center">SockSlender</h1>
  <p align="center">
    <b>Lightweight, multi-protocol proxy router & chain manager</b>
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

SockSlender is a **proxy chain router** that lets you combine multiple proxy servers into
intelligent routing chains. It supports **SOCKS5, HTTP CONNECT, SNI (TLS), and DNS** protocols,
with automatic failover, health monitoring, and smart server selection.

Think of it as a **programmable proxy multiplexer** — receive connections on one side,
route them through chains of proxies on the other side, with automatic health checking
and the fastest server always selected first.

```
              ┌─────────────┐
 Client ────→│ SockSlender   │ ──→ Proxy A ──→ Proxy B ──→ Internet
 		      │              │ ──→ Proxy C ──→ Internet (failover)
 Client ────→│  SOCKS5       │ ──→ Proxy D ──→ Internet (fastest)
 Client ────→│  HTTP         │
 Client ────→│  SNI          │
 DNS    ────→│  DNS          │ ──→ DNS Server 1 / DNS Server 2
              └─────────────┘
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

# SNI listener → direct upstream
./sockslender -l sni://0.0.0.0:443 -u sni://backend:443

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
- [Script Engine](#-script-engine)
- [Process Management](#-process-management)
- [Multi-Box Architecture](#-multi-box-architecture)
- [Advanced Examples](#-advanced-examples)
- [Platform Notes](#-platform-notes)

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
| **Script Engine** | Modify packets on-the-fly (byte patching) |
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
# Listen as SOCKS5, forward to SOCKS5 upstream
./sockslender -l socks5://0.0.0.0:1080 -u socks5://upstream:1234

# With authentication on both sides
./sockslender -l socks5://admin:secret@0.0.0.0:1080 -u socks5://user:pass@upstream:1234
```

### HTTP CONNECT

HTTP proxy with CONNECT method support and Basic authentication.

```bash
# Listen as HTTP proxy
./sockslender -l http://0.0.0.0:8080 -u socks5://upstream:1234

# With auth
./sockslender -l http://user:pass@0.0.0.0:8080 -u http://user:pass@upstream:8080
```

### SNI (TLS Passthrough)

Extracts hostname from TLS ClientHello SNI extension and routes accordingly.
No TLS termination — traffic passes through encrypted.

```bash
# SNI-based routing
./sockslender -l sni://0.0.0.0:443 -u sni://backend:443
```

### DNS (UDP)

DNS query forwarding over UDP with automatic failover between DNS servers.

```bash
# DNS forwarder with failover
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
| `-rrr?CMD,EP?` | Run via proxychains tunnel | `-rrr?tor,127.0.0.1:9050?` |
| `::` | Separator between independent Boxes | `... :: ...` |

---

## Chain Syntax

Chains are built by connecting nodes with `+`:

```
PROTOCOL://[USER:PASS@]HOST:PORT[?SCRIPT?]
```

### Simple Chain

```bash
# Single hop
-u socks5://proxy:1234

# Two hops
-u socks5://first:1010+socks5://second:2020

# Three hops with mixed protocols
-u socks5://entry:1010+http://middle:8080+socks5://exit:9050
```

### Chain with Macros (Snapshots)

Save and reuse chain segments using uppercase names:

```bash
# Save segment as "ENTRY", then use it
-u socks5://a:1010+socks5://b:2020+-xENTRY \
-u ENTRY+socks5://c:3030 \
-u ENTRY+socks5://d:4040
```

This creates:
```
Chain 0: a:1010 → b:2020  (saved as ENTRY)
Chain 1: a:1010 → b:2020 → c:3030
Chain 2: a:1010 → b:2020 → d:4040
```

### Mid-Chain Listener (`-x`)

Split a chain and create a listener at any point:

```bash
-i socks5://a:1010+socks5://b:2020+-xsocks5://0.0.0.0:4040+socks5://c:3030
```

This creates:
```
Listener on :4040 → Chain [a:1010, b:2020]     (only nodes before -x)
Upstream chain   → [a:1010, b:2020, c:3030]     (full chain)
```

### Outbound Append (`-o`)

Append nodes to ALL existing chains:

```bash
-u socks5://a:1010 \
-u socks5://b:2020 \
-o socks5://exit:9050

# Result:
# Chain 0: a:1010 → exit:9050
# Chain 1: b:2020 → exit:9050
```

---

## Routing Modes

### Global Upstream (`-u`)

All listeners share these chains. Best chain is auto-selected.

```bash
./sockslender \
  -l socks5://0.0.0.0:1080 \
  -l http://0.0.0.0:8080 \
  -u socks5://fast-server:1010 \
  -u socks5://backup-server:2020
```

Both listeners use the same pool of upstreams with smart selection.

### Dedicated Routing (`-i` with `-x`)

Bind specific chains to specific listeners:

```bash
./sockslender \
  -l socks5://0.0.0.0:1080 \
  -u socks5://default-proxy:1010 \
  -i socks5://special-proxy:2020+-xhttp://0.0.0.0:8080
```

- `:1080` (SOCKS5) → uses `default-proxy:1010`
- `:8080` (HTTP) → uses `special-proxy:2020` only

### Multiple Upstreams (Failover + Load Balancing)

```bash
./sockslender \
  -l socks5://0.0.0.0:1080 \
  -u socks5://server-us:1010 \
  -u socks5://server-eu:2020 \
  -u socks5://server-asia:3030
```

SockSlender automatically:
1. Health-checks all servers every 20 seconds
2. Measures latency with EMA (Exponential Moving Average)
3. Tracks success/failure rates
4. Routes to the best server first
5. Falls back to others if the best fails

---

## Authentication

### Listener Authentication

Require clients to authenticate:

```bash
# SOCKS5 with auth
-l socks5://admin:secret123@0.0.0.0:1080

# HTTP with Basic auth
-l http://user:pass@0.0.0.0:8080
```

### Upstream Authentication

Authenticate to upstream proxies:

```bash
-u socks5://myuser:mypass@proxy:1234
-u http://user:pass@httpproxy:8080
```

### Combined

```bash
./sockslender \
  -l socks5://admin:local-pass@0.0.0.0:1080 \
  -u socks5://remote-user:remote-pass@proxy:1234
```

---

## Smart Chain Selection

SockSlender uses an intelligent algorithm to always pick the best upstream:

### Scoring Formula

```
Score = Reliability² × Speed
```

Where:
- **Reliability** = `success_count / total_count` (0.0 to 1.0)
- **Speed** = `1,000,000 / (EMA_latency + 100)`
- **EMA Latency** = `0.7 × previous + 0.3 × current` (smoothed)

### Circuit Breaker

After **3 consecutive failures**, a chain is temporarily disabled:

```
Failure 1-2:  Still tried (with penalty)
Failure 3+:   Disabled for 30 seconds
After 30s:    One probe attempt allowed
Probe OK:     Fully restored (counter reset)
Probe FAIL:   Disabled again for 30s
```

### Example Scoring

```
Server A: 95% reliable, 50ms latency  → Score: 17.0  ★ Selected
Server B: 70% reliable, 100ms latency → Score:  4.6
Server C: 3 consecutive failures       → Score:  0.001 (disabled)
```

### Recovery

When a connection succeeds through a chain:
- Success counter incremented
- Consecutive failure counter reset to 0
- EMA latency updated with actual measurement

When a connection fails:
- Failure counter incremented
- Consecutive failure counter incremented
- EMA latency penalized (×1.5 + 50ms)

---

## Script Engine

Modify packets on-the-fly using byte-level scripts. Scripts are embedded in URIs between `?` markers:

```
socks5://proxy:1234?SCRIPT?
```

### Unconditional Byte Patch

```
?START-END=HEX?
```

Replace bytes at offset range:

```bash
# Set bytes 0-1 to 0x0505
-u 'socks5://proxy:1234?0-1=0505?'
```

### Conditional Patch (if/else)

```
?ACTION if CONDITION?
?ACTION if CONDITION el ELSE_ACTION?
```

```bash
# If byte at offset 0 is 0x16 (TLS), set byte 5 to 0x01
-u 'sni://proxy:443?5-5=01 if 0-0=16?'

# If bytes 0-1 are 0x0500, patch offset 3; else patch offset 7
-u 'socks5://proxy:1234?3-3=01 if 0-1=0500 el 7-7=FF?'
```

### AOB Pattern Matching (Array of Bytes)

```
?PATTERN if ACTION?
```

Use `__` or `??` as wildcards:

```bash
# Find pattern 0x16__01 anywhere and patch relative offset +2
-u 'sni://proxy:443?1603__01 if 2-2=03?'
```

### Multiple Rules

Separate rules with `,`:

```bash
-u 'socks5://proxy:1234?0-0=05, 3-3=01 if 0-0=16?'
```

### Verbose Mode

Use `-v` to see all packet modifications:

```bash
./sockslender -v -l socks5://0.0.0.0:1080 -u 'socks5://proxy:1234?0-0=05?'

# Output:
# [-] Traffic In (42 bytes): 050100...
# [+] Unconditional action applied at offset 0.
# [+] Traffic Out (42 bytes): 050100...
```

---

## Process Management

### Simple Background Task (`-r`)

Launch a command when SockSlender starts. Killed on exit.

```bash
-r?COMMAND?

# Examples:
-r?tor --SocksPort 9050?
-r?ssh -D 1080 user@server?
-r?openvpn --config vpn.conf?

# Multiple commands:
-r?tor --SocksPort 9050, sslocal -c ss.json?
```

### Auto-Restart Watchdog (`-rr`)

Launch + monitor + auto-restart on crash or freeze.

```bash
-rr?COMMAND,ENDPOINT?

# Monitor tor via SOCKS5 handshake
-rr?tor --SocksPort 9050,socks5://127.0.0.1:9050?

# Monitor SSH tunnel via TCP check
-rr?ssh -D 1080 user@server,127.0.0.1:1080?

# Monitor HTTP proxy
-rr?squid,http://127.0.0.1:3128?
```

**Watchdog behavior:**
- Checks every 15 seconds
- Exponential backoff: 30s → 60s → 120s → 240s → 300s (max)
- Distinguishes CRASH (process dead) vs FREEZE (alive but not responding)
- Resets backoff counter when service recovers

```
[!] [Watchdog] CRASH DETECTED: "tor" is dead (restart #1)
    -> Restarted (PID: 12345). Next check in 60s.

[!] [Watchdog] FREEZE DETECTED: "tor" alive but SOCKS5 handshake failed (restart #2)
    -> Restarted (PID: 12346). Next check in 120s.
```

### ProxyChains Tunnel (`-rrr`) — Linux/Android Only

Launch a command tunneled through the chain nodes **before** its endpoint.

```bash
-rrr?COMMAND,ENDPOINT_IN_CHAIN?
```

**Example:**

```bash
./sockslender \
  -l socks5://0.0.0.0:1080 \
  -u 'socks5://proxy1:1010+socks5://proxy2:2020+socks5://127.0.0.1:9050+socks5://exit:3030' \
  '-rrr?tor --SocksPort 9050,127.0.0.1:9050?'
```

**What happens:**

```
1. SockSlender finds 127.0.0.1:9050 in the chain
2. Extracts nodes BEFORE it: [proxy1:1010, proxy2:2020]
3. Generates proxychains config file
4. Launches: proxychains4 -q -f config.conf tor --SocksPort 9050
5. Tor's traffic is tunneled through proxy1 → proxy2
6. Full chain: client → proxy1 → proxy2 → tor → exit

Auto-generated config (sockslender_pc_1_0.conf):
┌──────────────────────────────────┐
│ strict_chain                           │
│ quiet_mode                       	  │
│ proxy_dns                              │
│ tcp_read_time_out 15000                │
│ tcp_connect_time_out 8000              │
│                                        │
│ [ProxyList]                            │
│ socks5  127.0.0.1  1010                │
│ socks5  127.0.0.1  2020                │
└──────────────────────────────────┘
```

> **Requires:** `proxychains4` installed (`apt install proxychains4`)

---

## Multi-Box Architecture

Run completely independent proxy instances in a single process using `::`:

```bash
./sockslender \
  -l socks5://0.0.0.0:1080 -u socks5://proxy-a:1010 \
  :: \
  -l http://0.0.0.0:8080 -u socks5://proxy-b:2020 \
  :: \
  -l dns://0.0.0.0:5353 -u dns://8.8.8.8:53
```

```
┌─── Box 1 ──────────────────────┐
│ SOCKS5 :1080 → proxy-a:1010.       │
└───────────────────────────────┘
┌─── Box 2 ──────────────────────┐
│ HTTP   :8080 → proxy-b:2020        │
└───────────────────────────────┘
┌─── Box 3 ──────────────────────┐
│ DNS    :5353 → 8.8.8.8:53          │
└───────────────────────────────┘
```

Each Box has:
- Independent listeners
- Independent chain pools
- Independent health checking
- Independent chain scoring

---

## Advanced Examples

### Full-Featured Setup

```bash
./sockslender \
  -v \
  -r?tor --SocksPort 9050? \
  -rr?ssh -D 1080 user@server,127.0.0.1:1080? \
  -l socks5://admin:pass@0.0.0.0:1080 \
  -l http://admin:pass@0.0.0.0:8080 \
  -l dns://0.0.0.0:53 \
  -u socks5://server1:1010 \
  -u socks5://server2:2020 \
  -u dns://8.8.8.8:53 \
  -u dns://1.1.1.1:53
```

### Chain with Tor Tunnel

```bash
./sockslender \
  -l socks5://0.0.0.0:1080 \
  -u 'socks5://entry:1010+socks5://127.0.0.1:9050+socks5://exit:3030' \
  '-rrr?tor --SocksPort 9050,127.0.0.1:9050?'
```

### Macro-Based Multi-Path Routing

```bash
./sockslender \
  -l socks5://0.0.0.0:1080 \
  -i 'socks5://us-east:1010+socks5://us-west:2020+-xUS_PATH' \
  -i 'socks5://eu-north:3030+socks5://eu-south:4040+-xEU_PATH' \
  -u US_PATH+socks5://final-us:9090 \
  -u EU_PATH+socks5://final-eu:9090 \
  -i US_PATH+-xsocks5://0.0.0.0:2080 \
  -i EU_PATH+-xsocks5://0.0.0.0:3080
```

Result:
```
:1080 → best of [us-east→us-west→final-us, eu-north→eu-south→final-eu]
:2080 → us-east → us-west (US only)
:3080 → eu-north → eu-south (EU only)
```

### SNI Proxy with Packet Modification

```bash
./sockslender \
  -l sni://0.0.0.0:443 \
  -u 'sni://backend:443?1603__01 if 2-2=03?'
```

### Isolated DNS + SOCKS5 Boxes

```bash
./sockslender \
  -l socks5://0.0.0.0:1080 \
  -u socks5://proxy:1234 \
  :: \
  -l dns://0.0.0.0:53 \
  -u dns://8.8.8.8:53 \
  -u dns://8.8.4.4:53 \
  -u dns://1.1.1.1:53
```

---

## Platform Notes

### Linux / Android

- **FD Limits:** Automatically raised on startup (soft → hard, up to 65536)
- **`-rrr`:** Fully supported (requires `proxychains4`)
- **Recommended:** `apt install proxychains4` for `-rrr` feature

### macOS

- **FD Limits:** Automatically raised on startup
- **`-rrr`:** Supported (install via `brew install proxychains-ng`)

### Windows

- **FD Limits:** Not applicable (Windows uses handles)
- **`-rrr`:** Not available (proxychains is Linux/macOS only)
- **All other features:** Fully supported

---

## Startup Output Example

```
[*] FD limits: soft=1024, hard=1048576
[*] FD soft limit raised: 1024 -> 65536
[*] FD limit OK: 65536
[*] [Box 1] -rrr: "tor --SocksPort 9050" tunneled via:
    socks5://127.0.0.1:1010 -> socks5://127.0.0.1:2020 -> 127.0.0.1:9050
    PID: 54321 | proxychains: /usr/bin/proxychains4 | config: sockslender_pc_1_0.conf
[*] [Box 1] Parsed successfully. 3 listener(s), 4 routing chain(s).
    -> VERBOSE mode enabled for this Box.
[*] Starting 1 independent Box(es)...
[+] [Box 1] SOCKS5 on 0.0.0.0:1080 (TCP)
[+] [Box 1] HTTP on 0.0.0.0:8080 (TCP)
[+] [Box 1] DNS on 0.0.0.0:53 (UDP)
```

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                      SockSlender                                    │
│                                                                     │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐         │
│  │ SOCKS5    │  │  HTTP    │  │   SNI     │  │   DNS     │        │
│  │Listener   │  │Listener  │  │Listener   │  │Listener   │        │
│  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘         │
│       │              │              │              │               │
│       └────────────┴─────┬──────┴────────────┘              │
│                          │                                         │
│                 ┌────────▼────────┐                            │
│                 │  Chain Selector     │                            │
│                 │  (Score-based)      │                            │
│                 └────────┬────────┘                             │
│                            │                                       │
│          ┌──────────────┼───────────────┐                    │
│          │                 │                 │                    │
│   ┌──────▼──────┐ ┌──────▼──────┐ ┌──────▼──────┐        │
│   │  Chain A       │ │  Chain B       │ │  Chain C       │        │
│   │ Score: 17.0    │ │ Score: 4.6     │ │ Score: 0.01    │        │
│   │  ★ Best       │ │  Fallback      │ │  Disabled      │         │
│   └──────┬──────┘ └──────┬──────┘  └─────────────┘         │
│           │                  │                                     │
│     ┌────▼────┐     ┌────▼────┐                               │
│     │ Node 1    │     │ Node 1    │                               │
│     │ Node 2    │     │ Node 2    │                               │
│     │ Node 3    │     └─────────┘                               │
│     └─────────┘                                                  │
│                                                                    │
│  ┌──────────────┐  ┌──────────────┐                          │
│  │Health Checker   │  │  Watchdog      │                          │
│  │  (20s loop)     │  │ (15s loop)     │                          │
│  └──────────────┘  └──────────────┘                          │
└──────────────────────────────────────────────────────────┘
```

---

## License

MIT - use it however you want.

---

<p align="center">
  <b>SockSlender</b> — Route smarter, not harder.
</p>