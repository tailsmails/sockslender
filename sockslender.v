import net
import os
import time
import sync
import encoding.base64

const check_interval = 20 * time.second
const check_timeout = 5 * time.second
const buf_size = 65536

enum ProxyType {
	socks5
	http
	sni
	dns
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
	alive   bool
	latency i64
	global  bool
}

struct Listener {
	proto     ProxyType
	addr      string
	user      string
	pass      string
	chain_idx int
}

struct App {
mut:
	listeners  []Listener
	chains     []Chain
	rr_counter u64
	udp_port   u32
	mu         sync.Mutex
}

fn parse_uri(raw string) !Node {
	if raw.trim_space() == '' {
		return error('URI is empty')
	}

	mut s := raw.trim_space()
	mut proto := ProxyType.socks5
	
	if s.contains('://') {
		parts := s.split('://')
		if parts.len > 2 {
			return error('Invalid URI format (multiple "://"): ${raw}')
		}
		scheme := parts[0].to_lower()
		s = parts[1]
		
		match scheme {
			'socks5' { proto = .socks5 }
			'http' { proto = .http }
			'sni' { proto = .sni }
			'dns' { proto = .dns }
			else { return error('Unknown protocol "${scheme}://" in URI: ${raw}') }
		}
	}

	mut user := ''
	mut pass := ''
	mut addr := s
	
	if s.contains('@') {
		at_parts := s.split('@')
		if at_parts.len > 2 {
			return error('Invalid URI format (multiple "@"): ${raw}')
		}
		addr = at_parts[1]
		auth := at_parts[0]
		
		if auth.contains(':') {
			ap := auth.split(':')
			user = ap[0]
			pass = ap[1]
		} else {
			user = auth
		}
	}

	if addr.trim_space() == '' {
		return error('Missing address (IP/Hostname) in URI: ${raw}')
	}
	
	if proto != .dns && !addr.contains(':') {
		return error('Missing port in address (Required for ${proto}): ${addr}')
	}
	
	if proto == .dns && !addr.contains(':') {
		addr += ':53'
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
			raw_uri := os.args[i + 1]
			node := parse_uri(raw_uri) or {
				eprintln('[!] Listener Error: ${err}')
				exit(1)
			}
			listeners << Listener{
				proto: node.proto
				addr: node.addr
				user: node.user
				pass: node.pass
				chain_idx: -1
			}
			i += 2
		} else if os.args[i] == '-u' && i + 1 < os.args.len {
			mut current_nodes := []Node{}
			chain_parts := os.args[i + 1].split('+')
			
			for p in chain_parts {
				part := p.trim_space()
				if part == '' { continue }
				
				if part.starts_with('-x') {
					addr_part := part[2..].trim_space()
					if addr_part == '' {
						eprintln('[!] Upstream Error: Missing address after "-x". Use -x[address] or -x [address]')
						exit(1)
					}
					
					if current_nodes.len == 0 {
						eprintln('[!] Upstream Error: Cannot place "-x ${addr_part}" at the very beginning of a chain.')
						exit(1)
					}
					
					chains << Chain{
						nodes: current_nodes.clone()
						alive: true
						latency: 0
						global: false
					}
					new_chain_idx := chains.len - 1
					
					node := parse_uri(addr_part) or {
						eprintln('[!] "-x" Node Error: ${err}')
						exit(1)
					}
					
					listeners << Listener{
						proto: node.proto
						addr: node.addr
						user: node.user
						pass: node.pass
						chain_idx: new_chain_idx
					}
				} else {
					node := parse_uri(part) or {
						eprintln('[!] Upstream Node Error: ${err}')
						exit(1)
					}
					current_nodes << node
				}
			}
			
			if current_nodes.len > 0 {
				chains << Chain{
					nodes: current_nodes.clone()
					alive: true
					latency: 0
					global: true
				}
			} else {
				eprintln('[!] Upstream Error: Chain is empty after parsing.')
				exit(1)
			}
			i += 2
		} else {
			eprintln('[!] Unknown or incomplete argument: ${os.args[i]}')
			exit(1)
		}
	}
	
	if listeners.len == 0 || chains.len == 0 {
		eprintln('Usage: ${os.args[0]} -l [proto://][user:pass@]addr:port -u [proto://][user:pass@]addr:port[+-x addr:port][+chain]')
		eprintln('Valid Protocols: socks5:// (default), http://, sni://, dns://')
		eprintln('Example: ${os.args[0]} -l 127.0.0.1:1080 -u http://user:pass@1.1.1.1:8080+-x 127.0.0.1:2080+socks5://2.2.2.2:1080')
		return
	}
	
	mut app := &App{
		listeners: listeners
		chains: chains
		rr_counter: 0
		udp_port: 40000
	}
	
	spawn health_checker(mut app)
	for li in 0 .. listeners.len {
		spawn start_listener(mut app, li)
	}
	
	println('[*] Parsed successfully. Starting...')
	println('[*] ${listeners.len} listener(s), ${chains.len} upstream chain(s)')
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
		.dns { 'DNS' }
	}
	auth_tag := if l.user != '' { ' [auth]' } else { '' }
	bind_tag := if l.chain_idx >= 0 { ' [isolated-chain]' } else { ' [global-lb]' }

	if l.proto == .dns {
		mut listener := net.listen_udp(l.addr) or {
			eprintln('[!] Cannot listen UDP ${l.addr}: ${err}')
			return
		}
		println('[+] ${pname} on ${l.addr}${auth_tag}${bind_tag} (UDP)')
		for {
			mut buf := []u8{len: 2048}
			n, addr := listener.read(mut buf) or { continue }
			if n > 0 {
				spawn handle_dns_request(mut app, mut listener, addr, buf[..n].clone(), l)
			}
		}
		return
	}

	mut listener := net.listen_tcp(.ip, l.addr) or {
		eprintln('[!] Cannot listen TCP ${l.addr}: ${err}')
		return
	}
	println('[+] ${pname} on ${l.addr}${auth_tag}${bind_tag} (TCP)')
	for {
		mut conn := listener.accept() or { continue }
		spawn handle_conn(mut app, mut conn, li)
	}
}

@[inline]
fn handle_conn(mut app App, mut client net.TcpConn, li int) {
	l := app.listeners[li]
	match l.proto {
		.socks5 { handle_socks5(mut app, mut client, l) }
		.http { handle_http(mut app, mut client, l) }
		.sni { handle_sni(mut app, mut client, l) }
		.dns {}
	}
}

fn handle_dns_request(mut app App, mut listener net.UdpConn, client_addr net.Addr, req []u8, l Listener) {
	mut order := []int{}
	if l.chain_idx >= 0 {
		order << l.chain_idx
	} else {
		order = pick_chain_order(mut app)
	}

	if order.len == 0 { return }
	
	mut ans_ch := chan []u8{cap: 3}
	mut sent := 0
	
	for ci in order {
		if sent >= 3 { break } 
		
		app.mu.@lock()
		nodes := app.chains[ci].nodes.clone()
		app.mu.unlock()
		
		if nodes.len == 0 || nodes[0].proto != .dns { continue }
		
		up_addrs := net.resolve_addrs(nodes[0].addr, .ip, .udp) or { continue }
		if up_addrs.len == 0 { continue }
		
		sent++
		
		spawn fn (addr net.Addr, req []u8, ans_ch chan []u8) {
			mut out_conn := net.listen_udp('0.0.0.0:0') or { return }
			out_conn.set_read_timeout(2 * time.second)
			
			out_conn.write_to(addr, req) or { 
				out_conn.close() or {}
				return 
			}
			
			mut resp_buf := []u8{len: 2048}
			rn, _ := out_conn.read(mut resp_buf) or { 
				out_conn.close() or {}
				return 
			}
			
			if rn > 0 {
				ans_ch <- resp_buf[..rn].clone()
			}
			out_conn.close() or {}
		}(up_addrs[0], req, ans_ch)
	}

	if sent == 0 { return }

	select {
		fastest_response := <-ans_ch {
			listener.write_to(client_addr, fastest_response) or {}
		}
		2 * time.second {}
	}
}

fn health_checker(mut app App) {
	for {
		mut any := false
		for ci in 0 .. app.chains.len {
			t0 := time.now()
			alive := check_chain(app.chains[ci])
			d := time.now() - t0
			lat := i64(d) / 1000
			app.mu.@lock()
			app.chains[ci].alive = alive
			if alive {
				app.chains[ci].latency = lat
				any = true
			}
			app.mu.unlock()
		}
		if !any {
			// eprintln('[!] All upstreams dead')
		}
		time.sleep(check_interval)
	}
}

@[inline]
fn check_chain(c Chain) bool {
	if c.nodes.len == 0 {
		return false
	}
	n := c.nodes[0]
	match n.proto {
		.socks5 { return check_socks5_h(n) }
		.http { return check_http_h(n) }
		.sni { return check_tcp_h(n.addr) }
		.dns { return check_dns_h(n) }
	}
}

@[inline]
fn check_tcp_h(addr string) bool {
	mut c := net.dial_tcp(addr) or { return false }
	c.close() or {}
	return true
}

fn check_dns_h(n Node) bool {
	mut c := net.listen_udp('0.0.0.0:0') or { return false }
	defer { c.close() or {} }
	c.set_read_timeout(check_timeout)
	
	addrs := net.resolve_addrs(n.addr, .ip, .udp) or { return false }
	if addrs.len == 0 { return false }
	
	query := [u8(0x12), 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			  0x06, 0x67, 0x6f, 0x6f, 0x67, 0x6c, 0x65,
			  0x03, 0x63, 0x6f, 0x6d, 0x00,
			  0x00, 0x01, 0x00, 0x01]
			  
	c.write_to(addrs[0], query) or { return false }
	
	mut buf := []u8{len: 512}
	n_read, _ := c.read(mut buf) or { return false }
	
	if n_read >= 12 && buf[0] == 0x12 && buf[1] == 0x34 {
		if (buf[2] & 0x80) != 0 {
			return true
		}
	}
	return false
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
		if r[1] != 0x02 {
			return false
		}
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
fn pick_chain_order(mut app App) []int {
	app.mu.@lock()
	defer { app.mu.unlock() }

	mut idxs := []int{cap: app.chains.len}
	for ci in 0 .. app.chains.len {
		if app.chains[ci].global && app.chains[ci].alive {
			idxs << ci
		}
	}

	if idxs.len == 0 {
		for ci in 0 .. app.chains.len {
			if app.chains[ci].global {
				idxs << ci
			}
		}
		return idxs
	}

	if idxs.len == 1 {
		return idxs
	}

	for i in 1 .. idxs.len {
		mut j := i
		for j > 0 {
			if app.chains[idxs[j]].latency < app.chains[idxs[j - 1]].latency {
				tmp := idxs[j]
				idxs[j] = idxs[j - 1]
				idxs[j - 1] = tmp
				j--
			} else {
				break
			}
		}
	}

	mut weights := []i64{cap: idxs.len}
	mut total := i64(0)
	for idx in idxs {
		lat := app.chains[idx].latency
		mut w := if lat > 0 { i64(10_000_000) / (lat + 1) } else { i64(1000) }
		if w < 1 {
			w = 1
		}
		weights << w
		total += w
	}

	if total <= 0 {
		total = 1
	}
	pv := i64(app.rr_counter % u64(total))
	app.rr_counter++

	mut first := 0
	mut cum := i64(0)
	for i in 0 .. weights.len {
		cum += weights[i]
		if pv < cum {
			first = i
			break
		}
	}

	if first == 0 {
		return idxs
	}

	mut result := []int{cap: idxs.len}
	result << idxs[first]
	for i in 0 .. idxs.len {
		if i != first {
			result << idxs[i]
		}
	}
	return result
}

fn connect_retry(mut app App, host string, port int, chain_idx int) !&net.TcpConn {
	mut order := []int{}
	if chain_idx >= 0 {
		order << chain_idx
	} else {
		order = pick_chain_order(mut app)
	}

	if order.len == 0 {
		return error('no chains')
	}
	for ci in order {
		app.mu.@lock()
		nodes := app.chains[ci].nodes.clone()
		app.mu.unlock()
		
		conn := connect_chain(nodes, host, port) or { 
			app.mu.@lock()
			app.chains[ci].latency += 10000 
			app.mu.unlock()
			continue 
		}
		
		app.mu.@lock()
		if app.chains[ci].latency > 100 {
			app.chains[ci].latency -= 100
		}
		app.mu.unlock()
		
		return conn
	}
	return error('all chains failed')
}

fn connect_chain(chain []Node, host string, port int) !&net.TcpConn {
	if chain.len == 0 {
		return error('empty chain')
	}
	mut conn := net.dial_tcp(chain[0].addr) or { return error('dial: ${err}') }
	conn.set_read_timeout(30 * time.second)
	conn.set_write_timeout(30 * time.second)
	for i in 0 .. chain.len {
		mut nh := host
		mut np := port
		if i < chain.len - 1 {
			hp := chain[i + 1].addr.split(':')
			nh = hp[0]
			if hp.len > 1 {
				np = hp[1].int()
			}
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
			.dns {}
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
	if gr[0] != 0x05 {
		return error('not socks5')
	}
	if n.user != '' {
		if gr[1] != 0x02 {
			return error('auth rejected')
		}
		mut a := []u8{cap: 3 + n.user.len + n.pass.len}
		a << 0x01
		a << u8(n.user.len)
		a << n.user.bytes()
		a << u8(n.pass.len)
		a << n.pass.bytes()
		c.write(a)!
		mut ar := []u8{len: 2}
		read_full(mut c, mut ar, 2)!
		if ar[1] != 0x00 {
			return error('auth failed')
		}
	} else {
		if gr[1] != 0x00 {
			return error('noauth rejected')
		}
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
	if resp[1] != 0x00 {
		return error('connect fail ${resp[1]}')
	}
	mut total := 0
	match resp[3] {
		0x01 { total = 10 }
		0x04 { total = 22 }
		0x03 {
			if rn < 5 {
				rn = read_full(mut c, mut resp, 5)!
			}
			total = 7 + int(resp[4])
		}
		else {
			return error('bad atyp')
		}
	}
	if rn < total {
		read_full(mut c, mut resp, total)!
	}
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
		if nr == 0 {
			return error('closed')
		}
		acc << buf[..nr]
		if acc.bytestr().contains('\r\n\r\n') {
			break
		}
		if acc.len > 8192 {
			return error('resp too large')
		}
	}
	if !acc.bytestr().contains('200') {
		return error('CONNECT rejected')
	}
}

fn handle_socks5(mut app App, mut client net.TcpConn, l Listener) {
	defer { client.close() or {} }
	client.set_read_timeout(30 * time.second)
	client.set_write_timeout(30 * time.second)

	mut greet := []u8{len: 257}
	mut gn := read_full(mut client, mut greet, 2) or { return }
	if greet[0] != 0x05 {
		return
	}
	needed := 2 + int(greet[1])
	if gn < needed {
		read_full(mut client, mut greet, needed) or { return }
	}

	if l.user != '' {
		client.write([u8(0x05), 0x02]) or { return }

		mut auth := []u8{len: 513}
		mut an := read_full(mut client, mut auth, 2) or { return }
		if auth[0] != 0x01 {
			client.write([u8(0x01), 0x01]) or {}
			return
		}
		ulen := int(auth[1])
		need_u := 2 + ulen + 1
		if an < need_u {
			an = read_full(mut client, mut auth, need_u) or { return }
		}
		plen := int(auth[2 + ulen])
		need_all := 2 + ulen + 1 + plen
		if an < need_all {
			read_full(mut client, mut auth, need_all) or { return }
		}
		got_user := auth[2..2 + ulen].bytestr()
		got_pass := auth[3 + ulen..3 + ulen + plen].bytestr()

		if got_user != l.user || got_pass != l.pass {
			client.write([u8(0x01), 0x01]) or {}
			return
		}
		client.write([u8(0x01), 0x00]) or { return }
	} else {
		client.write([u8(0x05), 0x00]) or { return }
	}

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
			if rn < rt {
				rn = read_full(mut client, mut req, rt) or { return }
			}
			host = '${req[4]}.${req[5]}.${req[6]}.${req[7]}'
			port = (u16(req[8]) << 8) | u16(req[9])
		}
		0x03 {
			if rn < 5 {
				rn = read_full(mut client, mut req, 5) or { return }
			}
			dl := int(req[4])
			rt = 5 + dl + 2
			if rn < rt {
				rn = read_full(mut client, mut req, rt) or { return }
			}
			host = req[5..5 + dl].bytestr()
			port = (u16(req[5 + dl]) << 8) | u16(req[5 + dl + 1])
		}
		0x04 {
			rt = 22
			if rn < rt {
				rn = read_full(mut client, mut req, rt) or { return }
			}
			mut hp := []string{}
			for j in 0 .. 8 {
				v := (u16(req[4 + j * 2]) << 8) | u16(req[4 + j * 2 + 1])
				hp << '${v:x}'
			}
			host = hp.join(':')
			port = (u16(req[20]) << 8) | u16(req[21])
		}
		else {
			return
		}
	}
	if cmd == 0x03 {
		handle_udp_associate(mut app, mut client)
		return
	}
	if cmd != 0x01 {
		mut f := []u8{len: 10}
		f[0] = 0x05
		f[1] = 0x07
		client.write(f) or {}
		return
	}

	mut upstream := connect_retry(mut app, host, port, l.chain_idx) or {
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

fn handle_http(mut app App, mut client net.TcpConn, l Listener) {
	defer { client.close() or {} }
	client.set_read_timeout(30 * time.second)
	client.set_write_timeout(30 * time.second)

	mut buf := []u8{len: buf_size}
	mut acc := []u8{}
	for {
		nr := client.read(mut buf) or { return }
		if nr == 0 {
			return
		}
		acc << buf[..nr]
		if acc.bytestr().contains('\r\n\r\n') {
			break
		}
		if acc.len > buf_size {
			return
		}
	}

	hdr := acc.bytestr()
	
	if l.user != '' {
		expected := base64.encode_str('${l.user}:${l.pass}')
		mut authed := false
		for line in hdr.split('\r\n') {
			low := line.to_lower()
			if low.starts_with('proxy-authorization: basic ') {
				got := line[27..].trim_space()
				if got == expected {
					authed = true
				}
				break
			}
		}
		if !authed {
			client.write('HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="proxy"\r\n\r\n'.bytes()) or {}
			return
		}
	}

	lines := hdr.split('\r\n')
	if lines.len == 0 {
		return
	}
	parts := lines[0].split(' ')
	if parts.len < 3 {
		return
	}
	method := parts[0]

	if method == 'CONNECT' {
		hp := parts[1].split(':')
		t_host := hp[0]
		mut t_port := 443
		if hp.len > 1 {
			t_port = hp[1].int()
		}

		mut upstream := connect_retry(mut app, t_host, t_port, l.chain_idx) or {
			client.write('HTTP/1.1 502 Bad Gateway\r\n\r\n'.bytes()) or {}
			return
		}
		defer { upstream.close() or {} }
		client.write('HTTP/1.1 200 Connection Established\r\n\r\n'.bytes()) or { return }
		do_relay(mut client, mut upstream)
	} else {
		mut rest := parts[1]
		if rest.starts_with('http://') {
			rest = rest[7..]
		}

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

		mut upstream := connect_retry(mut app, t_host, t_port, l.chain_idx) or {
			client.write('HTTP/1.1 502 Bad Gateway\r\n\r\n'.bytes()) or {}
			return
		}
		defer { upstream.close() or {} }

		mut new_hdr := '${method} ${path} ${parts[2]}\r\n'
		for li in 1 .. lines.len {
			ln := lines[li]
			if ln.to_lower().starts_with('proxy-') {
				continue
			}
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

fn handle_sni(mut app App, mut client net.TcpConn, l Listener) {
	defer { client.close() or {} }
	client.set_read_timeout(30 * time.second)

	mut buf := []u8{len: buf_size}
	nr := client.read(mut buf) or { return }
	if nr == 0 {
		return
	}
	initial := buf[..nr].clone()

	hostname := extract_sni(initial)
	if hostname == '' {
		return
	}

	mut upstream := connect_retry(mut app, hostname, 443, l.chain_idx) or { return }
	defer { upstream.close() or {} }

	upstream.write(initial) or { return }
	do_relay(mut client, mut upstream)
}

@[inline]
fn extract_sni(d []u8) string {
	if d.len < 44 || d[0] != 0x16 || d[5] != 0x01 {
		return ''
	}
	mut p := 43
	if p >= d.len {
		return ''
	}
	p += 1 + int(d[p])
	if p + 2 > d.len {
		return ''
	}
	p += 2 + ((u16(d[p]) << 8) | u16(d[p + 1]))
	if p >= d.len {
		return ''
	}
	p += 1 + int(d[p])
	if p + 2 > d.len {
		return ''
	}
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
		if n == 0 {
			return error('closed')
		}
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
		if nr == 0 {
			break
		}
		dst.write(b[..nr]) or { break }
	}
	done <- true
}

fn handle_udp_associate(mut app App, mut client net.TcpConn) {
	app.mu.@lock()
	port := int(app.udp_port)
	app.udp_port++
	if app.udp_port > 50000 {
		app.udp_port = 40000
	}
	app.mu.unlock()

	mut relay := net.listen_udp('0.0.0.0:${port}') or {
		mut f := []u8{len: 10}
		f[0] = 0x05
		f[1] = 0x01
		client.write(f) or {}
		return
	}
	mut out := net.listen_udp('0.0.0.0:0') or {
		relay.close() or {}
		mut f := []u8{len: 10}
		f[0] = 0x05
		f[1] = 0x01
		client.write(f) or {}
		return
	}

	mut resp := []u8{len: 10}
	resp[0] = 0x05
	resp[3] = 0x01
	resp[8] = u8(u32(port) >> 8)
	resp[9] = u8(u32(port) & 0xff)
	client.write(resp) or {
		relay.close() or {}
		out.close() or {}
		return
	}

	spawn tcp_udp_monitor(mut client, mut relay, mut out)

	relay.set_read_timeout(2 * time.minute)
	out.set_read_timeout(10 * time.second)

	mut buf := []u8{len: buf_size}
	mut rbuf := []u8{len: buf_size}

	for {
		n, from := relay.read(mut buf) or { break }
		if n < 7 { continue }
		if buf[2] != 0x00 { continue }

		hdr_len, dest_host, dest_port := parse_udp_socks(buf[..n].clone()) or { continue }

		addrs := net.resolve_addrs('${dest_host}:${dest_port}', net.AddrFamily.ip, net.SocketType.udp) or { continue }
		if addrs.len == 0 { continue }
		out.write_to(addrs[0], buf[hdr_len..n].clone()) or { continue }

		rn, _ := out.read(mut rbuf) or { continue }
		if rn == 0 { continue }

		mut pkt := []u8{cap: hdr_len + rn}
		pkt << buf[..hdr_len].clone()
		pkt << rbuf[..rn].clone()
		relay.write_to(from, pkt) or { continue }
	}
}

fn parse_udp_socks(d []u8) !(int, string, int) {
	if d.len < 7 {
		return error('short')
	}
	match d[3] {
		0x01 {
			if d.len < 10 {
				return error('short4')
			}
			return 10, '${d[4]}.${d[5]}.${d[6]}.${d[7]}', int((u32(d[8]) << 8) | u32(d[9]))
		}
		0x03 {
			dl := int(d[4])
			if d.len < 5 + dl + 2 {
				return error('shortd')
			}
			return 5 + dl + 2, d[5..5 + dl].bytestr(), int((u32(d[5 + dl]) << 8) | u32(d[5 + dl + 1]))
		}
		0x04 {
			if d.len < 22 {
				return error('short6')
			}
			mut p := []string{cap: 8}
			for j in 0 .. 8 {
				p << '${(u16(d[4 + j * 2]) << 8) | u16(d[4 + j * 2 + 1]):x}'
			}
			return 22, p.join(':'), int((u32(d[20]) << 8) | u32(d[21]))
		}
		else {
			return error('atyp')
		}
	}
}

fn tcp_udp_monitor(mut client net.TcpConn, mut relay net.UdpConn, mut out net.UdpConn) {
	mut b := []u8{len: 1}
	for {
		client.read(mut b) or { break }
	}
	relay.close() or {}
	out.close() or {}
}