# SockSlender & Anyside
Advanced Proxy Routing, DPI Evasion, and Transport-Agnostic Tunneling Suite

This repository contains two highly specialized, independently compiled networking tools written in V. Together, they provide a complete stack for bypassing Deep Packet Inspection (DPI), managing proxy chains, and tunneling traffic over esoteric covert channels.

---

# Part 1: SockSlender
Lightweight, multi-protocol proxy router & chain manager with DPI desync

SockSlender is a programmable proxy multiplexer. It combines multiple proxy servers into intelligent routing chains with built-in anti-censorship, automatic failover, and smart server selection. It intercepts connections, applies network-layer manipulations to defeat DPI, and routes traffic through the optimal path.

## Quick Install

```sh
apt update -y && apt install -y git clang make && if ! command -v v >/dev/null 2>&1; then git clone --depth=1 https://github.com/vlang/v && cd v && make && ./v symlink && cd ..; fi && git clone --depth=1 https://github.com/tailsmails/sockslender && cd sockslender && v -enable-globals -prod sockslender.v -o sockslender && ln -sf $(pwd)/sockslender $PREFIX/bin/sockslender
```

## Core Capabilities

*   **Multi-Protocol:** SOCKS5 (Full TCP & UDP Associate support), HTTP CONNECT, SNI/TLS Passthrough, DNS (UDP Forwarding).
*   **Authentication:** Username/Password support for both local listeners and upstream proxies.
*   **Chain Architecture:** Connect unlimited proxies sequentially using `+`.
*   **Macros & Mid-Chain Listeners:** Save chain segments as variables (`-xNAME`), or spawn listeners mid-chain (`-x`).
*   **Multi-Box Routing:** Run completely isolated proxy instances inside a single process using `::`.
*   **Zero Dependencies:** Single static binary. Auto-tunes File Descriptor (FD) limits on Linux/macOS.

## Smart Routing & Circuit Breaker

SockSlender does not just round-robin; it actively evaluates upstream health:
*   **Scoring Formula:** `Score = Reliability^2 * Speed` (Speed = `1,000,000 / (EMA_latency + 100)`).
*   **Circuit Breaker:** If a node fails 3 consecutive times, it is disabled for 30 seconds. A single probe is sent after the cooldown to verify recovery.

## Process Watchdog & Tunneling

SockSlender manages third-party tools (Tor, Xray, WireGuard) as background processes.
*   `-r?CMD?`: Run a simple background task.
*   `-rr?CMD,EP?`: Run with an auto-restart Watchdog. It monitors the Endpoint (EP) handshake. Differentiates between process CRASH (dead PID) and FREEZE (alive PID but failed handshake). Uses exponential backoff (30s to 300s) for restarts.
*   `-rrr?CMD,EP?`: Tunnels the background task via `proxychains4` through the preceding chain nodes before hitting the Endpoint.

## CLI Reference

| Flag | Function | Example |
|---|---|---|
| `-l URI` | Add listener | `-l socks5://user:pass@0.0.0.0:1080` |
| `-u CHAIN` | Add global upstream | `-u socks5://a:1010+socks5://b:2020` |
| `-i CHAIN` | Add isolated chain | `-i proxy:1010+-xsocks5://0.0.0.0:2020` |
| `-o CHAIN` | Append to all chains | `-o socks5://exit:9050` |
| `::` | Isolate Boxes | `-l ... -u ... :: -l ... -u ...` |

## Script Engine (L7 / L3 / L3R)

Rules are injected directly into the URI between `?` markers (e.g., `sni://proxy:443?L3R:fake=3?`).

### L7: Payload Byte Patching (Cross-Platform)
Modify payload bytes unconditionally, conditionally (`if/el`), or via AOB pattern matching.
*   `?0-1=0505?` (Unconditional patch)
*   `?3-3=01 if 0-1=0500 el 7-7=FF?` (If/Else patch)
*   `?1603__01 if 2-2=03?` (AOB pattern match with wildcards `__`)

### L3: Network Layer (Linux/macOS)
Control IP/TCP header behaviors.
*   **No Root:** `ttl`, `tos` (DSCP/QoS), `df` (Don't Fragment), `nodelay`, `keepalive`, `delay`.
*   **Root Required:** `mark` (iptables fwmark), `bind` (force interface, e.g., `tun0`), `tproxy`.

### L3R: TCP Raw Socket DPI Desync (Linux)
Requires `root` or `CAP_NET_RAW` + `CAP_NET_ADMIN`.

| Rule | Root | Description |
|---|---|---|
| `split=N` / `seg=N` | No | Split first packet at byte N, or segment entire payload. |
| `splitsni` / `splithttp` | No | Auto-detect and split exactly at SNI or HTTP Host boundary. |
| `oob=HEX` | No | Send TCP Out-of-Band (urgent) data. |
| `fake=TTL` / `fakets=TTL` | Yes | Fake packet (with/without TCP timestamp) with low TTL. |
| `hoax=TTL` / `overlap=TTL`| Yes | Fake HTTP GET payload, or overlapping fake payload. |
| `rst=TTL` / `faketeardown` | Yes | Fake TCP RST or FIN packet with low TTL. |
| `disorder=N` | Yes | Send second half of the packet before the first half. |
| `ipfrag=N` / `revfrag=N` | Yes | Fragment fake packet at IP level (forward or reverse order). |
| `spoof=IP` / `spoofrst=IP` | Yes | Inject fake payload or RST using a forged source IP (`random`). |
| `spooffrag=IP:N` | Yes | IP spoofing combined with IP fragmentation (`random:16`). |
| `multifake=N` | Yes | Flood N fake packets with varying low TTLs (1-4). |
| `synfake=TTL` | Yes | Send a SYN packet (Seq-1) carrying payload data. |
| `badcsum` | Yes | Send fake payload with an intentionally invalid TCP checksum. |

### L3R: UDP Raw Socket DPI Desync (Linux)
Unique UDP-specific bypass techniques for protocols like QUIC or DNS.

| Rule | Description |
|---|---|
| `udpfake=TTL` | Send fake UDP payload with low TTL. |
| `udpbadcsum=TTL` | Send fake UDP payload with invalid checksum. |
| `udpzerocsum=TTL` | Send UDP packet with zeroed checksum. |
| `udpbadlength=TTL` | Send UDP packet with intentionally corrupt length header. |
| `udpspoof=IP` | Forged UDP source IP injection. |
| `udpipfrag=N` / `udprevfrag=N` | Fragment UDP payload at IP level (forward/reverse). |
| `udpmultifake=N` | Flood N fake UDP packets with varying low TTLs. |
| `udptail=N` | Extract and fragment the tail of the real UDP packet. |

## Processing Pipeline

1. TCP Connect
2. L2/L3: Apply `setsockopt` (TTL, TOS, MARK, BIND, NODELAY)
3. Protocol Handshake (SOCKS5/HTTP)
4. First Data Packet Interception:
   * Execute L3R Rules (Fake, RST, Spoof, Frag via Raw Sockets)
   * Execute Desync Writes (Split, Disorder, Seg)
5. Relay Loop: Apply L7 byte patches/AOB matching on every subsequent packet.

---

# Part 2: Anyside
Transport-Agnostic Covert Tunneling Protocol

While SockSlender handles L3/L4 routing and DPI evasion, Anyside completely detaches standard networking from the underlying transport medium. It accepts standard TCP/SOCKS5 connections, multiplexes them, wraps the payloads in CRC-verified Base64 frames, and delegates the physical transmission to user-defined external adapters.

If you can move a string of text from point A to point B (via Telegram bots, DNS TXT records, audio FSK, or writing to a USB drive), Anyside can tunnel a full TCP connection over it.

## Quick Start

Build the binary:
```bash
v -prod -cc gcc anyside.v
```

Run Server (Target Environment):
```bash
./anyside -m server -e "python3 adapter.py" -c 8192 -d 50
```

Run Client (Local Environment):
```bash
./anyside -m client -l 127.0.0.1:1080 -e "python3 adapter.py" -c 8192 -d 50
```

## The Adapter Contract

Anyside does not know how data reaches the other side. It communicates with your transport mechanism via standard OS process execution. Your adapter (written in Python, Bash, etc.) must handle two commands:

1.  **Transmission (TX):** `adapter_cmd tx <base64_string>`
    Your script must take the Base64 string and deliver it to the remote destination. Exit code `0` indicates success.
2.  **Reception (RX):** `adapter_cmd rx`
    Executed continuously based on the polling delay (`-d`). Your script must fetch pending data and print the Base64 strings to `stdout` separated by newlines. Exit code `0` with empty output means no new data.

## Protocol Mechanics

*   **Multiplexing:** Supports concurrent connections over a single adapter channel via `conn_id`.
*   **Framing:** 7-byte binary header (Magic Bytes, Command, Conn ID, Sequence, Length).
*   **Integrity:** 4-byte CRC32 checksums drop corrupted frames (vital for unstable physical mediums like RF or Audio).
*   **Gateway:** The client mode acts as a transparent SOCKS5 server for easy integration.

---

# Synergy: Combining Both Tools

SockSlender and Anyside are designed to be composable. 

1.  **SockSlender** provides the brain: Smart routing, DNS handling, process watchdogs, protocol multiplexing, and L3/L4 DPI desync.
2.  **Anyside** provides the covert pipe: Bypassing strict firewall whitelists by disguising the transport medium entirely.

**Architecture Flow:**
`Browser` -> `SockSlender (DPI Desync / Routing)` -> `Anyside Client (SOCKS5)` -> `[Your Custom Text Adapter]` -> `Covert Medium` -> `Anyside Server` -> `Internet`.