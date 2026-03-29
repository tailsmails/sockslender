# Sockslender

A lightweight, blazing-fast SOCKS5 proxy failover tool written in [V](https://vlang.io/).

Focused on one core objective: taking multiple SOCKS5 upstream proxies and exposing a single, highly available local SOCKS5 proxy. It dynamically monitors the health of all upstreams and seamlessly routes your SOCKS5 traffic through the active, healthy node.

## Features

- High Performance: Written in V, resulting in a tiny, native, and fast binary with minimal memory footprint.
- Active Health Checks: Continuously monitors all upstream proxies in the background (every 30 seconds).
- Automatic Failover: If the active proxy drops its internet connection, it instantly switches to the next available healthy proxy.
- Full SOCKS5 Compliance: Supports IPv4, IPv6, and FQDN (Domain Name) routing natively.
- Authentication Support: Seamlessly forwards Username/Password (Method 0x02) authentication to upstreams.
- Robust Connection Handling: Prevents zombie connections, handles partial TCP reads, and enforces strict timeouts.

## Quick start (copy - paste - enter)
```sh
apt update -y && apt install -y git clang make && if ! command -v v >/dev/null 2>&1; then git clone --depth=1 https://github.com/vlang/v && cd v && make && ./v symlink && cd ..; fi && git clone --depth=1 https://github.com/tailsmails/sockslender && cd sockslender && v -enable-globals -prod sockslender.v -o sockslender && ln -sf $(pwd)/sockslender $PREFIX/bin/sockslender && sockslender
```

## Installation

First, ensure you have the [V Compiler](https://github.com/vlang/v) installed.

Clone the repository and compile the binary with production optimizations:

```bash
git clone https://github.com/tailsmails/sockslender
cd sockslender
v -prod sockslender.v -o sockslender
```

## Usage

The tool requires one listen address (`-l`) and one or more upstream proxies (`-u`).

Basic syntax:
```bash
./sockslender -l <listen_addr> -u <upstream_1> [-u <upstream_2> ...]
```

Example:
Listen locally on port `1080` and enable failover between 3 remote proxies:
```bash
./sockslender -l 127.0.0.1:1080 -u 10.0.0.1:2080 -u 10.0.0.2:3080 -u 10.0.0.3:4080
```

### Testing the connection
You can point your browser or `curl` to the local listen address:
```bash
curl --socks5 127.0.0.1:1080 https://api.ipify.org
```

## How it Works

1. Health Checker Thread: A background worker pings every upstream proxy with a standard SOCKS5 handshake to verify connectivity. 
2. State Management: Mutex locks are used to safely update the state of each upstream. If the currently active proxy fails, the tool automatically selects the next healthy one from the pool.
3. Smart Relay: When a client connects, the proxy parses the SOCKS5 greeting, dynamically calculates the required payload lengths (for IPs, Domains, and Auth), and streams the traffic bidirectionally.

## Edge Cases Handled

Network programming is messy. This tool is built to handle edge cases without crashing or leaking memory:

| Scenario | How it's handled |
| :--- | :--- |
| Partial TCP Reads | Implements a custom `read_full` function to ensure fragmented packets (Greetings, Connect requests) are fully reconstructed before processing. |
| All upstreams are dead | Logs a warning, keeps accepting local connections, and continuously retries until a node comes back online. |
| Client is not using SOCKS5 | Immediately detects non-SOCKS5 greetings (`greet[0] != 0x05`) and terminates the connection cleanly. |
| Upstream Rejections | If an upstream rejects a connection (e.g., Target Unreachable), the error is transparently forwarded to the client before closing. |
| Hanging Connections | Implements strict Read/Write timeouts (30s for handshake, 5m for relay). Uses `defer` to ensure both ends of a socket are closed, preventing orphaned threads. |

## License
![License](https://img.shields.io/badge/License-MIT-blue.svg)