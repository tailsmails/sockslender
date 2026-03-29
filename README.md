# Sockslender

A lightweight, blazing-fast SOCKS5 proxy failover tool written in [V](https://vlang.io/).

Focused on one core objective: taking multiple SOCKS5 upstream proxies and exposing a single, highly available local SOCKS5 proxy. It dynamically monitors the health of all upstreams and seamlessly routes your SOCKS5 traffic through the active, healthy node.

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

sockslender is a lightweight, multi-protocol network proxy relayer and load balancer. It allows you to create local proxy listeners that forward traffic through one or multiple upstream proxies, with support for proxy chaining, round-robin load balancing, and automated health checks.

## How It Works

At its core, sockslender acts as a middleman between your applications and remote proxy servers. 

### Supported Protocols
The application can handle both incoming (listening) and outgoing (upstream) connections using the following protocols:
*   `socks5` (Default)
*   `http`
*   `sni`

### Core Concepts

1.  **Listeners (`-l`)**: These are local ports that sockslender opens on your machine. Your local applications will connect to these listeners. Traffic entering any general listener is distributed across all available upstream proxies using a round-robin algorithm.
2.  **Upstreams (`-u`)**: These are the remote proxy servers you want to route your traffic through. You can specify one or multiple upstreams.
3.  **Health Checking**: sockslender automatically tests the connection to all defined upstreams every 30 seconds. If an upstream dies or times out, it is temporarily removed from the load-balancing rotation until it becomes responsive again.
4.  **Chaining**: You can chain multiple proxies together. Traffic will be routed from the listener to Proxy A, then from Proxy A to Proxy B, and finally to the destination.
5.  **Exported Listeners (`-x`)**: Unlike general listeners (`-l`), an exported listener routes traffic *strictly* to the specific upstream defined immediately before it in the command line. This allows you to expose specific remote proxies on specific local ports, bypassing the load balancer. Exported listeners also support setting up local authentication.

## Command Line Usage

### General Syntax
```bash
sockslender [-l [proto://]addr]... -u [proto://][user[:pass]@]addr[+chain] [-x [proto://][user[:pass]@]addr]...
```

### URI Format
Whenever you define a listener or an upstream, you use the following format:
`[protocol://][username:password@]host:port`

*   **protocol**: `socks5://`, `http://`, or `sni://`. If omitted, `socks5://` is used by default.
*   **auth**: `username:password@`. Optional. Used for authenticating with an upstream proxy, or requiring authentication on an exported listener.
*   **address**: `host:port` (e.g., `127.0.0.1:1080` or `[::1]:1080` for IPv6).

---

## Examples

### 1. Basic Proxy Forwarding
Listen locally on port 1080 (SOCKS5) and forward all traffic to a remote SOCKS5 proxy at 192.168.1.50:1080.
```bash
sockslender -l 127.0.0.1:1080 -u 192.168.1.50:1080
```

### 2. Protocol Translation (HTTP to SOCKS5)
Listen locally as an HTTP proxy, but forward the traffic through an upstream SOCKS5 proxy that requires authentication.
```bash
sockslender -l http://127.0.0.1:8080 -u socks5://user:secret@192.168.1.50:1080
```

### 3. Load Balancing (Round-Robin)
Open one local SOCKS5 port, and distribute the incoming traffic evenly across three different upstream SOCKS5 proxies. sockslender will actively monitor their health.
```bash
sockslender -l 127.0.0.1:1080 -u 10.0.0.1:1080 -u 10.0.0.2:1080 -u 10.0.0.3:1080
```

### 4. Proxy Chaining
Route traffic through multiple proxies sequentially. Use the `+` symbol to define the chain. Traffic will go from the local listener -> 10.0.0.1 -> 10.0.0.2 -> Final Destination.
```bash
sockslender -l 127.0.0.1:1080 -u 10.0.0.1:1080+10.0.0.2:1080
```

### 5. Using Exported Listeners
If you want to expose specific upstreams to specific local ports without mixing them in a load balancer, use the `-x` flag. The `-x` flag always attaches itself to the `-u` flag defined right before it.

In this example:
*   Local port 1081 routes strictly to 10.0.0.1.
*   Local port 1082 routes strictly to 10.0.0.2.
```bash
sockslender -u 10.0.0.1:1080 -x 127.0.0.1:1081 -u 10.0.0.2:1080 -x 127.0.0.1:1082
```

### 6. Exported Listener with Local Authentication
You can require users to authenticate when connecting to your local exported listener before their traffic is sent to the upstream.
```bash
sockslender -u 192.168.1.50:1080 -x socks5://localuser:localpass@127.0.0.1:1080
```

### 7. Complex Mixed Usage
You can combine general listeners, round-robin upstreams, and exported listeners in a single command.

```bash
sockslender -l 127.0.0.1:9000 -u 10.0.0.1:1080 -u 10.0.0.2:1080 -x 127.0.0.1:9002
```
In this scenario:
*   Local port 9000 (`-l`) will load balance between `10.0.0.1` and `10.0.0.2`.
*   Local port 9002 (`-x`) is tied only to `10.0.0.2` (because it was declared immediately after it).

## License
![License](https://img.shields.io/badge/License-MIT-blue.svg)