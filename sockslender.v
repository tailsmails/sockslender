import net
import os
import time
import sync
import encoding.base64

const check_interval = 30 * time.second
const check_timeout = 5 * time.second
const buf_size = 32768

enum ProxyType {
	socks5
	http
	sni
}

struct Node {
	proto ProxyType
	addr  string
	user  string
	pass  string
}

struct Chain {
	nodes []Node
mut:
	alive bool
}

struct Listener {
	proto ProxyType
	addr  string
}

struct App {
mut:
	listeners []Listener
	chains    []Chain
	active    int
	mu        sync.Mutex
}

@[inline]
fn parse_uri(raw string) Node {
	mut s := raw
	mut proto := ProxyType.socks5
	if s.starts_with('socks5://') {
		s = s[9..]
	} else if s.starts_with('http://') {
		proto = .http
		s = s[7..]
	} else if s.starts_with('sni://') {
		proto = .sni
		s = s[6..]
	}
	mut user := ''
	mut pass := ''
	mut addr := s
	if s.contains('@') {
		at_parts := s.split('@')
		addr = at_parts[1]
		auth := at_parts[0]
		if auth.contains(':') {
			ap := auth.split(':')
			user = ap[0]
			pass = ap[1]
		}
	}
	return Node{
		proto: proto
		addr: addr
		user: user
		pass: pass
	}
}

fn main() {
	mut listeners := []Listener{}
	mut chains := []Chain{}
	mut i := 1
	for i < os.args.len {
		if os.args[i] == '-l' && i + 1 < os.args.len {
			node := parse_uri(os.args[i + 1])
			listeners << Listener{ proto: node.proto, addr: node.addr }
			i += 2
		} else if os.args[i] == '-u' && i + 1 < os.args.len {
			mut nodes := []Node{}
			for p in os.args[i + 1].split('+') {
				nodes << parse_uri(p)
			}
			chains << Chain{ nodes: nodes, alive: true }
			i += 2
		} else {
			i += 1
		}
	}
	if listeners.len == 0 || chains.len == 0 {
		eprintln('Usage: ${os.args[0]} -l [proto://]addr -u [proto://][user:pass@]addr[+chain]')
		eprintln('Proto: socks5 (default), http, sni')
		return
	}
	mut app := &App{
		listeners: listeners
		chains: chains
		active: 0
	}
	spawn health_checker(mut app)
	for li in 0 .. listeners.len {
		spawn start_listener(mut app, li)
	}
	println('[*] ${listeners.len} listener(s), ${chains.len} upstream(s)')
	for {
		time.sleep(1 * time.hour)
	}
}

@[inline]
fn start_listener(mut app App, li int) {
	l := app.listeners[li]
	pname := match l.proto {
		.socks5 { 'SOCKS5' }
		.http { 'HTTP' }
		.sni { 'SNI' }
	}
	mut listener := net.listen_tcp(.ip, l.addr) or {
		eprintln('[!] Cannot listen ${l.addr}: ${err}')
		return
	}
	println('[*] ${pname} on ${l.addr}')
	for {
		mut conn := listener.accept() or { continue }
		proto := l.proto
		spawn handle_conn(mut app, mut conn, proto)
	}
}

@[inline]
fn handle_conn(mut app App, mut client net.TcpConn, proto ProxyType) {
	match proto {
		.socks5 { handle_socks5(mut app, mut client) }
		.http { handle_http(mut app, mut client) }
		.sni { handle_sni(mut app, mut client) }
	}
}

fn health_checker(mut app App) {
	for {
		mut any := false
		for ci in 0 .. app.chains.len {
			alive := check_chain(app.chains[ci])
			app.mu.@lock()
			app.chains[ci].alive = alive
			app.mu.unlock()
			if alive { any = true }
		}
		app.mu.@lock()
		if !any {
			eprintln('[!] All upstreams dead')
		} else if !app.chains[app.active].alive {
			for ci in 0 .. app.chains.len {
				if app.chains[ci].alive {
					println('[*] Switch -> chain#${ci}')
					app.active = ci
					break
				}
			}
		}
		app.mu.unlock()
		time.sleep(check_interval)
	}
}

@[inline]
fn check_chain(c Chain) bool {
	if c.nodes.len == 0 { return false }
	n := c.nodes[0]
	match n.proto {
		.socks5 { return check_socks5_h(n) }
		.http { return check_http_h(n) }
		.sni { return check_tcp_h(n.addr) }
	}
}

@[inline]
fn check_tcp_h(addr string) bool {
	mut c := net.dial_tcp(addr) or { return false }
	c.close() or {}
	return true
}

fn check_socks5_h(n Node) bool {
	mut c := net.dial_tcp(n.addr) or { return false }
	defer { c.close() or {} }
	c.set_read_timeout(check_timeout)
	c.set_write_timeout(check_timeout)
	if n.user != '' {
		c.write([u8(0x05), 0x01, 0x02]) or { return false }
		mut r := []u8{len: 2}
		c.read(mut r) or { return false }
		if r[1] != 0x02 { return false }
		mut a := []u8{cap: 3 + n.user.len + n.pass.len}
		a << 0x01
		a << u8(n.user.len)
		a << n.user.bytes()
		a << u8(n.pass.len)
		a << n.pass.bytes()
		c.write(a) or { return false }
		mut ar := []u8{len: 2}
		c.read(mut ar) or { return false }
		return ar[1] == 0x00
	}
	c.write([u8(0x05), 0x01, 0x00]) or { return false }
	mut r := []u8{len: 2}
	c.read(mut r) or { return false }
	return r[1] == 0x00
}

fn check_http_h(n Node) bool {
	mut c := net.dial_tcp(n.addr) or { return false }
	defer { c.close() or {} }
	c.set_read_timeout(check_timeout)
	c.set_write_timeout(check_timeout)
	mut req := 'CONNECT 1.1.1.1:443 HTTP/1.1\r\nHost: 1.1.1.1:443\r\n'
	if n.user != '' {
		req += 'Proxy-Authorization: Basic ${base64.encode_str('${n.user}:${n.pass}')}\r\n'
	}
	req += '\r\n'
	c.write(req.bytes()) or { return false }
	mut buf := []u8{len: 1024}
	nr := c.read(mut buf) or { return false }
	return buf[..nr].bytestr().contains('200')
}

@[inline]
fn get_active_chain(mut app App) []Node {
	app.mu.@lock()
	nodes := app.chains[app.active].nodes.clone()
	app.mu.unlock()
	return nodes
}

fn connect_chain(chain []Node, host string, port int) !&net.TcpConn {
	if chain.len == 0 { return error('empty chain') }
	mut conn := net.dial_tcp(chain[0].addr) or { return error('dial: ${err}') }
	conn.set_read_timeout(30 * time.second)
	conn.set_write_timeout(30 * time.second)
	for i in 0 .. chain.len {
		mut nh := host
		mut np := port
		if i < chain.len - 1 {
			hp := chain[i + 1].addr.split(':')
			nh = hp[0]
			if hp.len > 1 { np = hp[1].int() }
		}
		match chain[i].proto {
			.socks5 {
				do_socks5_hs(mut conn, chain[i], nh, np) or {
					conn.close() or {}
					return error('socks5 hop${i}: ${err}')
				}
			}
			.http {
				do_http_hs(mut conn, chain[i], nh, np) or {
					conn.close() or {}
					return error('http hop${i}: ${err}')
				}
			}
			.sni {}
		}
	}
	return conn
}

@[inline]
fn do_socks5_hs(mut c net.TcpConn, n Node, host string, port int) ! {
	if n.user != '' {
		c.write([u8(0x05), 0x01, 0x02])!
	} else {
		c.write([u8(0x05), 0x01, 0x00])!
	}
	mut gr := []u8{len: 2}
	read_full(mut c, mut gr, 2)!
	if gr[0] != 0x05 { return error('not socks5') }
	if n.user != '' {
		if gr[1] != 0x02 { return error('auth rejected') }
		mut a := []u8{cap: 3 + n.user.len + n.pass.len}
		a << 0x01
		a << u8(n.user.len)
		a << n.user.bytes()
		a << u8(n.pass.len)
		a << n.pass.bytes()
		c.write(a)!
		mut ar := []u8{len: 2}
		read_full(mut c, mut ar, 2)!
		if ar[1] != 0x00 { return error('auth failed') }
	} else {
		if gr[1] != 0x00 { return error('noauth rejected') }
	}
	mut req := []u8{cap: 7 + host.len}
	req << u8(0x05)
	req << u8(0x01)
	req << u8(0x00)
	req << u8(0x03)
	req << u8(host.len)
	req << host.bytes()
	req << u8(port >> 8)
	req << u8(port & 0xff)
	c.write(req)!
	mut resp := []u8{len: 263}
	mut rn := read_full(mut c, mut resp, 4)!
	if resp[1] != 0x00 { return error('connect fail ${resp[1]}') }
	mut total := 0
	match resp[3] {
		0x01 { total = 10 }
		0x04 { total = 22 }
		0x03 {
			if rn < 5 { rn = read_full(mut c, mut resp, 5)! }
			total = 7 + int(resp[4])
		}
		else { return error('bad atyp') }
	}
	if rn < total { read_full(mut c, mut resp, total)! }
}

@[inline]
fn do_http_hs(mut c net.TcpConn, n Node, host string, port int) ! {
	tgt := '${host}:${port}'
	mut req := 'CONNECT ${tgt} HTTP/1.1\r\nHost: ${tgt}\r\n'
	if n.user != '' {
		req += 'Proxy-Authorization: Basic ${base64.encode_str('${n.user}:${n.pass}')}\r\n'
	}
	req += '\r\n'
	c.write(req.bytes())!
	mut buf := []u8{len: 4096}
	mut acc := []u8{}
	for {
		nr := c.read(mut buf) or { return error('read http resp: ${err}') }
		if nr == 0 { return error('closed') }
		acc << buf[..nr]
		if acc.bytestr().contains('\r\n\r\n') { break }
		if acc.len > 8192 { return error('resp too large') }
	}
	if !acc.bytestr().contains('200') {
		return error('CONNECT rejected')
	}
}

fn handle_socks5(mut app App, mut client net.TcpConn) {
	defer { client.close() or {} }
	client.set_read_timeout(30 * time.second)
	client.set_write_timeout(30 * time.second)

	mut greet := []u8{len: 257}
	mut gn := read_full(mut client, mut greet, 2) or { return }
	if greet[0] != 0x05 { return }
	needed := 2 + int(greet[1])
	if gn < needed { read_full(mut client, mut greet, needed) or { return } }
	client.write([u8(0x05), 0x00]) or { return }

	mut req := []u8{len: 263}
	mut rn := read_full(mut client, mut req, 4) or { return }
	cmd := req[1]
	atyp := req[3]

	mut host := ''
	mut port := 0
	mut rt := 0

	match atyp {
		0x01 {
			rt = 10
			if rn < rt { rn = read_full(mut client, mut req, rt) or { return } }
			host = '${req[4]}.${req[5]}.${req[6]}.${req[7]}'
			port = (u16(req[8]) << 8) | u16(req[9])
		}
		0x03 {
			if rn < 5 { rn = read_full(mut client, mut req, 5) or { return } }
			dl := int(req[4])
			rt = 5 + dl + 2
			if rn < rt { rn = read_full(mut client, mut req, rt) or { return } }
			host = req[5..5 + dl].bytestr()
			port = (u16(req[5 + dl]) << 8) | u16(req[5 + dl + 1])
		}
		0x04 {
			rt = 22
			if rn < rt { rn = read_full(mut client, mut req, rt) or { return } }
			mut hp := []string{}
			for j in 0 .. 8 {
				v := (u16(req[4 + j * 2]) << 8) | u16(req[4 + j * 2 + 1])
				hp << '${v:x}'
			}
			host = hp.join(':')
			port = (u16(req[20]) << 8) | u16(req[21])
		}
		else { return }
	}

	if cmd != 0x01 {
		mut f := []u8{len: 10}
		f[0] = 0x05
		f[1] = 0x07
		client.write(f) or {}
		return
	}

	chain := get_active_chain(mut app)
	mut upstream := connect_chain(chain, host, port) or {
		mut f := []u8{len: 10}
		f[0] = 0x05
		f[1] = 0x04
		client.write(f) or {}
		return
	}
	defer { upstream.close() or {} }

	mut ok := []u8{len: 10}
	ok[0] = 0x05
	ok[3] = 0x01
	client.write(ok) or { return }
	do_relay(mut client, mut upstream)
}

fn handle_http(mut app App, mut client net.TcpConn) {
	defer { client.close() or {} }
	client.set_read_timeout(30 * time.second)
	client.set_write_timeout(30 * time.second)

	mut buf := []u8{len: buf_size}
	mut acc := []u8{}
	for {
		nr := client.read(mut buf) or { return }
		if nr == 0 { return }
		acc << buf[..nr]
		if acc.bytestr().contains('\r\n\r\n') { break }
		if acc.len > buf_size { return }
	}

	hdr := acc.bytestr()
	lines := hdr.split('\r\n')
	if lines.len == 0 { return }
	parts := lines[0].split(' ')
	if parts.len < 3 { return }
	method := parts[0]

	if method == 'CONNECT' {
		hp := parts[1].split(':')
		t_host := hp[0]
		mut t_port := 443
		if hp.len > 1 { t_port = hp[1].int() }

		chain := get_active_chain(mut app)
		mut upstream := connect_chain(chain, t_host, t_port) or {
			client.write('HTTP/1.1 502 Bad Gateway\r\n\r\n'.bytes()) or {}
			return
		}
		defer { upstream.close() or {} }
		client.write('HTTP/1.1 200 Connection Established\r\n\r\n'.bytes()) or { return }
		do_relay(mut client, mut upstream)
	} else {
		mut rest := parts[1]
		if rest.starts_with('http://') { rest = rest[7..] }

		mut host_part := rest
		mut path := '/'
		if rest.contains('/') {
			pos := rest.index('/') or { rest.len }
			host_part = rest[..pos]
			path = rest[pos..]
		}

		mut t_host := host_part
		mut t_port := 80
		if host_part.contains(':') {
			hp := host_part.split(':')
			t_host = hp[0]
			t_port = hp[1].int()
		}

		chain := get_active_chain(mut app)
		mut upstream := connect_chain(chain, t_host, t_port) or {
			client.write('HTTP/1.1 502 Bad Gateway\r\n\r\n'.bytes()) or {}
			return
		}
		defer { upstream.close() or {} }

		mut new_hdr := '${method} ${path} ${parts[2]}\r\n'
		for li in 1 .. lines.len {
			ln := lines[li]
			if ln.to_lower().starts_with('proxy-') { continue }
			new_hdr += '${ln}\r\n'
		}
		upstream.write(new_hdr.bytes()) or { return }

		hdr_end := hdr.index('\r\n\r\n') or { return }
		bs := hdr_end + 4
		if bs < acc.len {
			upstream.write(acc[bs..]) or { return }
		}
		do_relay(mut client, mut upstream)
	}
}

fn handle_sni(mut app App, mut client net.TcpConn) {
	defer { client.close() or {} }
	client.set_read_timeout(30 * time.second)

	mut buf := []u8{len: buf_size}
	nr := client.read(mut buf) or { return }
	if nr == 0 { return }
	initial := buf[..nr].clone()

	hostname := extract_sni(initial)
	if hostname == '' { return }

	chain := get_active_chain(mut app)
	mut upstream := connect_chain(chain, hostname, 443) or { return }
	defer { upstream.close() or {} }

	upstream.write(initial) or { return }
	do_relay(mut client, mut upstream)
}

@[inline]
fn extract_sni(d []u8) string {
	if d.len < 44 || d[0] != 0x16 || d[5] != 0x01 { return '' }
	mut p := 43
	if p >= d.len { return '' }
	p += 1 + int(d[p])
	if p + 2 > d.len { return '' }
	p += 2 + ((u16(d[p]) << 8) | u16(d[p + 1]))
	if p >= d.len { return '' }
	p += 1 + int(d[p])
	if p + 2 > d.len { return '' }
	ext_len := (u16(d[p]) << 8) | u16(d[p + 1])
	p += 2
	ext_end := p + ext_len
	for p + 4 <= ext_end && p + 4 <= d.len {
		et := (u16(d[p]) << 8) | u16(d[p + 1])
		el := (u16(d[p + 2]) << 8) | u16(d[p + 3])
		if et == 0 && el >= 5 && p + 9 <= d.len {
			sn_len := (u16(d[p + 7]) << 8) | u16(d[p + 8])
			if p + 9 + sn_len <= d.len {
				return d[p + 9..p + 9 + sn_len].bytestr()
			}
		}
		p += 4 + el
	}
	return ''
}

@[inline]
fn read_full(mut c net.TcpConn, mut buf []u8, min int) !int {
	mut total := 0
	for total < min {
		n := c.read(mut buf[total..]) or { return err }
		if n == 0 { return error('closed') }
		total += n
	}
	return total
}

@[inline]
fn do_relay(mut a net.TcpConn, mut b net.TcpConn) {
	a.set_read_timeout(5 * time.minute)
	b.set_read_timeout(5 * time.minute)
	done := chan bool{cap: 2}
	spawn relay(mut a, mut b, done)
	spawn relay(mut b, mut a, done)
	_ = <-done
}

@[inline]
fn relay(mut src net.TcpConn, mut dst net.TcpConn, done chan bool) {
	mut b := []u8{len: buf_size}
	for {
		nr := src.read(mut b) or { break }
		if nr == 0 { break }
		dst.write(b[..nr]) or { break }
	}
	done <- true
}