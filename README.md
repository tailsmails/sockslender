# Sockslender

A lightweight, blazing-fast SOCKS5 proxy failover tool written in [V](https://vlang.io/).

Focused on one core objective: taking multiple SOCKS5/HTTP/... upstream proxies and exposing a single, highly available local proxy. It dynamically monitors the health of all upstreams and seamlessly routes your SOCKS5 traffic through the active, healthy node.

## Quick start (copy - paste - enter)
```sh
apt update -y && apt install -y git clang make && if ! command -v v >/dev/null 2>&1; then git clone --depth=1 https://github.com/vlang/v && cd v && make && ./v symlink && cd ..; fi && git clone --depth=1 https://github.com/tailsmails/sockslender && cd sockslender && v -enable-globals -prod sockslender.v -o sockslender && ln -sf $(pwd)/sockslender $PREFIX/bin/sockslender && sockslender
```

## Build

To compile the binary from source:

```bash
v .
```

## Protocol Support

- Listeners: SOCKS5, HTTP, SNI, DNS
- Upstreams: SOCKS5, HTTP, DNS

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
## License
![License](https://img.shields.io/badge/License-MIT-blue.svg)