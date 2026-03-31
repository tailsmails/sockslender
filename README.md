# Sockslender

A lightweight, blazing-fast SOCKS5 proxy failover tool written in [V](https://vlang.io/).

Focused on one core objective: taking multiple SOCKS5/HTTP/... upstream proxies and exposing a single, highly available local proxy. It dynamically monitors the health of all upstreams and seamlessly routes your SOCKS5 traffic through the active, healthy node.

## Quick start (copy - paste - enter)
```sh
apt update -y && apt install -y git clang make && if ! command -v v >/dev/null 2>&1; then git clone --depth=1 https://github.com/vlang/v && cd v && make && ./v symlink && cd ..; fi && git clone --depth=1 https://github.com/tailsmails/sockslender && cd sockslender && v -enable-globals -prod sockslender.v -o sockslender && ln -sf $(pwd)/sockslender $PREFIX/bin/sockslender && sockslender
```

---

## Build

To compile the binary from source:

```bash
v .
```

---

## Protocol Support

- Listeners: SOCKS5, HTTP, SNI, DNS
- Upstreams: SOCKS5, HTTP, DNS

---

## Core Usage Examples

### Basic Proxy Chaining
Start a SOCKS5 listener that tunnels through an HTTP proxy.
```bash
./sockslender -l 127.0.0.1:1080 -u http://user:pass@1.2.3.4:8080
```

### Multi-Hop Tunneling
Chain multiple SOCKS5 proxies together.
```bash
./sockslender -l 127.0.0.1:1080 -u socks5://1.1.1.1:1080+socks5://2.2.2.2:1080+socks5://3.3.3.3:1080
```

### Port Overloading (Failover and Load Balancing)
Map a single local port to multiple upstream paths. The program automatically selects the healthiest and fastest path.
```bash
./sockslender \
  -u socks5://primary_server:1080+-x 127.0.0.1:1111 \
  -u socks5://backup_server:1080+-x 127.0.0.1:1111
```

### Snapshot Macros
Define complex chains once and reuse them as named snapshots (uppercase names) to avoid redundant port usage or typing.

Define a base path and extend it:
```bash
./sockslender \
  -u 1.1.1.1:1080+2.2.2.2:1080+-x MY_CORE_PATH \
  -u MY_CORE_PATH+3.3.3.3:1080 \
  -l 127.0.0.1:8080
```

Multiple entry points using the same snapshot:
```bash
./sockslender \
  -u socks5://proxy_provider:1080+-x DISGUISE \
  -u DISGUISE+target_a:1080+-x 127.0.0.1:2001 \
  -u DISGUISE+target_b:1080+-x 127.0.0.1:2002
```

### SNI Proxying
Transparently route HTTPS traffic based on Server Name Indication.
```bash
./sockslender -l sni://0.0.0.0:443 -u http://1.2.3.4:8080
```

### DNS Load Balancing
Run a local DNS server that queries multiple upstream DNS servers simultaneously and returns the fastest response.
```bash
./sockslender -l dns://127.0.0.1:53 -u dns://8.8.8.8:53+dns://1.1.1.1:53
```

---

## Advanced Logic

### Global vs Isolated Routing
- If a chain ends with `-x [address]`, the listener on that address only uses the upstream(s) it is specifically attached to.
- If a listener is defined with `-l [address]`, it acts as a global entry point and can load balance across all global `-u` chains based on real-time latency checks.

### Health Checks
The engine performs background health checks every 20 seconds. If an upstream fails, it is temporarily deprioritized. Traffic is automatically rerouted to the next available hop in the overloaded group or global pool.

## Command Line Arguments

- `-l`: Define a global listener (Protocol, Address, Auth).
- `-u`: Define an upstream chain. Use `+` to chain nodes and `-x` to bind the current chain to a specific port or snapshot name.

## Examples of -x Routing

Route port 1111 to either server A or server B (Fastest wins):
```bash
./sockslender -u server_a:1080+-x 127.0.0.1:1111 -u server_b:1080+-x 127.0.0.1:1111
```

Define a named group and use it later:
```bash
./sockslender -u provider1:1080+-x GROUP_A -u provider2:1080+-x GROUP_A -u GROUP_A+final_hop:1080 -l 127.0.0.1:1080
```
---

### 1. Mini-Scripting Language for Raw Traffic Modification (`?...?`)

SocksLender features a high-performance, **In-place Binary Scripting Language** that allows you to scan, filter, and modify raw network traffic in real-time. It operates directly on the data buffer without changing the packet length, ensuring maximum compatibility with established protocols.

**Core Syntax:**
*   Scripts are enclosed between two question marks `?` at the end of a node URI.
*   Multiple rules are separated by a comma `,`.
*   All values must be provided in **Hexadecimal** format.

**Operational Modes:**

| Mode | Syntax | Description |
| :--- | :--- | :--- |
| **Fixed Offset** | `Start-End=Hex` | Modifies bytes at a specific location in the packet. |
| **AOB Search** | `PatternifStart-End=Hex` | Scans the entire packet for an **Array of Bytes (AOB)** and applies the action **relative** to the match. |

**Advanced Features:**
*   **Wildcards:** Use `__` or `??` in AOB patterns to match any byte (e.g., `AABB__CC`).
*   **Conditionals:** Supports `if` (Match) and `el` (Else) logic for offsets.
*   **Flexible Ranges:** Supports both `0-4` and `0..4` syntax.

**Examples:**
*   `?0-4=FFFFFFFF?`: Unconditionally overwrites the first 4 bytes with `FFFFFFFF`.
*   `?0-2=0000if0-2=FFFF?`: If the first 2 bytes are `FFFF`, they are nullified to `0000`.
*   `?AABB__CCif0..2=DDFF?`: Searches the packet for `AABB[any]CC` and changes the first 2 bytes of every found occurrence to `DDFF`.

---

### 2. Named Inputs & Snapshots (`-i` and `-x`)

This system allows you to define complex routing chains, name them using Snapshots, and reuse them across different upstreams without occupying additional local ports.

**The Difference Between `-i` and `-u`:**
*   **`-u` (Upstream):** Defines a chain that is globally available for general listeners (`-l`).
*   **`-i` (Input/Internal):** Defines an internal chain or snapshot that is **hidden** from the global routing table. It is used exclusively for macro definitions and modular routing.

**Naming with `-x`:**
If the address following the `-x` flag consists of uppercase letters and underscores, it is treated as a **Snapshot Name** (Macro) instead of a physical listener.

**Example Usage:**
```bash
# Define a core route internally without opening a port
-i 1.1.1.1:8080+2.2.2.2:9090+-xCORE_ROUTE

# Reuse the macro in a public upstream
-u CORE_ROUTE+3.3.3.3:4444
```
*This setup routes traffic through three servers while only managing the logic as a reusable module.*

---

### 3. Global Outbound Enforcement (`-o`)

The `-o` (Outbound) flag is used to define a mandatory final hop for all traffic passing through the application, regardless of the selected upstream.

**Key Features:**
*   **Automatic Appending:** The nodes defined in `-o` are automatically attached to the end of every chain defined via `-u` or `-i`.
*   **Macro Support:** You can use a Snapshot name (defined via `-x`) as your outbound target.
*   **Centralized Control:** Ideal for forcing all traffic through a final security layer or a specific exit node.

**Example:**
```bash
# Force every connection to exit through 9.9.9.9 after its initial path
-l 127.0.0.1:1080 -u 1.1.1.1:8080 -u 2.2.2.2:8080 -o 9.9.9.9:443
```

---

### 4. Verbose Logging & Reverse Engineering (`-v`)

The `-v` (Verbose) flag provides deep visibility into the raw data flowing through your tunnels and the performance of your scripts.

**Operational Logic:**
*   **Passive Logging:** If no script (`?...?`) is defined, `-v` logs the raw hexadecimal representation of every incoming packet. This is highly effective for reverse-engineering unknown protocols.
*   **Active Debugging:** If a script is active, the application logs every time a pattern (AOB) or condition (IF) is matched and modified, showing the relative offsets and applied actions.

**Example Output:**
```text
[-] Traffic In (12 bytes): 48656c6c6f20576f726c6421
  [+] AOB MATCHED at relative offset 0! Applying action.
[+] Traffic Out (12 bytes): 4675636b6f20576f726c6421
```

*Use this mode to fine-tune your traffic-thinning scripts and ensure patterns are matching as expected.*

---

## License
![License](https://img.shields.io/badge/License-MIT-blue.svg)