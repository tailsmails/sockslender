import net
import os
import time
import sync
import encoding.base64
import encoding.hex

const check_interval = 20 * time.second
const check_timeout = 5 * time.second
const buf_size = 65536

enum ProxyType {
	socks5
	http
	sni
	dns
}

struct PatternByte {
	val      u8
	wildcard bool
}

struct Rule {
mut:
	mode         string
	aob_pattern  []PatternByte

	has_cond     bool
	cond_start   int
	cond_end     int
	cond_hex     []u8
	
	action_start int
	action_end   int
	action_hex   []u8
	
	has_else     bool
	else_start   int
	else_end     int
	else_hex     []u8
}

struct Node {
	proto  ProxyType
	addr   string
	user   string
	pass   string
	script []Rule
}

struct Chain {
	mut:
	nodes []Node
	alive   bool
	latency i64
	global  bool
}

struct Listener {
	proto      ProxyType
	addr       string
	user       string
	pass       string
	mut:
	chain_idxs []int 
	is_global  bool
}

struct App {
mut:
	id         int
	listeners  []Listener
	chains     []Chain
	rr_counter u64
	udp_port   u32
	mu         sync.Mutex
	verbose    bool
}

fn is_snapshot_name(s string) bool {
	if s == '' { return false }
	for c in s {
		if !((c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`) || c == `_`) {
			return false
		}
	}
	return true
}

fn parse_op(s string) !(int, int, []u8) {
	parts := s.split('=')
	if parts.len != 2 { return error('invalid op (missing =): ${s}') }
	
	mut range_str := parts[0].trim_space()
	range_parts := range_str.split('-')
	if range_parts.len != 2 { return error('invalid range (missing -): ${parts[0]}') }
	
	start := range_parts[0].int()
	end := range_parts[1].int()
	
	mut hex_str := parts[1].trim_space()
	if hex_str.len % 2 != 0 {
		hex_str = '0' + hex_str
	}
	hx := hex.decode(hex_str) or { return error('invalid hex: ${hex_str}') }
	
	return start, end, hx
}

fn parse_aob(s string) ![]PatternByte {
	mut res := []PatternByte{}
	clean := s.trim_space()
	if clean.len % 2 != 0 { return error('AOB pattern length must be even: ${clean}') }
	for i := 0; i < clean.len; i += 2 {
		chunk := clean[i..i+2]
		if chunk == '__' || chunk == '??' {
			res << PatternByte{0, true}
		} else {
			hx := hex.decode(chunk) or { return error('Invalid AOB hex: ${chunk}') }
			res << PatternByte{hx[0], false}
		}
	}
	return res
}

fn parse_script(raw string) ![]Rule {
	mut rules := []Rule{}
	if raw.trim_space() == '' { return rules }
	
	parts := raw.split(',')
	for p in parts {
		if p.trim_space() == '' { continue }
		mut rule := Rule{}
		mut s := p.trim_space().replace('..', '-')
		
		if s.contains('if') {
			action_cond := s.split('if')
			if action_cond.len != 2 { return error('invalid if syntax') }
			
			left := action_cond[0].trim_space()
			right := action_cond[1].trim_space()
			
			if left.contains('=') {
				rule.mode = 'offset'
				rule.has_cond = true
				
				a_start, a_end, a_hex := parse_op(left)!
				rule.action_start = a_start; rule.action_end = a_end; rule.action_hex = a_hex
				
				cond_else := right.split('el')
				c_start, c_end, c_hex := parse_op(cond_else[0])!
				rule.cond_start = c_start; rule.cond_end = c_end; rule.cond_hex = c_hex
				
				if cond_else.len == 2 {
					rule.has_else = true
					e_start, e_end, e_hex := parse_op(cond_else[1])!
					rule.else_start = e_start; rule.else_end = e_end; rule.else_hex = e_hex
				}
			} else {
				rule.mode = 'aob'
				rule.aob_pattern = parse_aob(left)!
				
				a_start, a_end, a_hex := parse_op(right)!
				rule.action_start = a_start; rule.action_end = a_end; rule.action_hex = a_hex
			}
		} else {
			rule.mode = 'offset'
			a_start, a_end, a_hex := parse_op(s)!
			rule.action_start = a_start; rule.action_end = a_end; rule.action_hex = a_hex
		}
		rules << rule
	}
	return rules
}

fn parse_uri(raw string) !Node {
	if raw.trim_space() == '' { return error('URI is empty') }

	mut s := raw.trim_space()
	mut script := []Rule{}
	
	if s.count('?') >= 2 {
		first_q := s.index('?') or { -1 }
		last_q := s.last_index('?') or { -1 }
		if first_q != -1 && last_q != -1 && last_q > first_q {
			script_str := s[first_q+1 .. last_q]
			s = s[..first_q] + s[last_q+1..]
			script = parse_script(script_str) or { return error('Script error: ${err}') }
		}
	}

	mut proto := ProxyType.socks5

	if s.contains('://') {
		parts := s.split('://')
		if parts.len > 2 { return error('Invalid URI format') }
		scheme := parts[0].to_lower()
		s = parts[1]
		match scheme {
			'socks5' { proto = .socks5 }
			'http' { proto = .http }
			'sni' { proto = .sni }
			'dns' { proto = .dns }
			else { return error('Unknown protocol') }
		}
	}

	mut user := ''; mut pass := ''; mut addr := s
	if s.contains('@') {
		at_parts := s.split('@')
		if at_parts.len > 2 { return error('Invalid URI format') }
		addr = at_parts[1]; auth := at_parts[0]
		if auth.contains(':') {
			ap := auth.split(':'); user = ap[0]; pass = ap[1]
		} else { user = auth }
	}

	if addr.trim_space() == '' { return error('Missing address') }
	if proto != .dns && !addr.contains(':') { return error('Missing port') }
	if proto == .dns && !addr.contains(':') { addr += ':53' }

	return Node{ proto: proto, addr: addr, user: user, pass: pass, script: script }
}

fn main() {
	mut child_procs := []&os.Process{}
	defer {
		if child_procs.len > 0 {
			println('\n[*] Shutting down... Terminating ${child_procs.len} background task(s).')
			for mut p in child_procs {
				if p.is_alive() {
					p.signal_kill()
					p.wait()
					p.close()
				}
			}
		}
	}
	
	mut raw_args := os.args[1..].clone()
	mut boxes_args := [][]string{}
	mut current_box := []string{}

	for arg in raw_args {
		if arg == '::' {
			if current_box.len > 0 {
				boxes_args << current_box
				current_box = []
			}
		} else {
			current_box << arg
		}
	}
	if current_box.len > 0 {
		boxes_args << current_box
	}

	if boxes_args.len == 0 {
		eprintln('Usage: ${os.args[0]} [-v] -l addr:port -u addr:port [:: -l addr:port ...]')
		return
	}

	mut apps := []&App{}
	
	for box_idx, box_args in boxes_args {
		mut listeners := []Listener{}
		mut chains := []Chain{}
		mut macros := map[string][][]Node{}
		mut global_outbound_str := ''
		mut verbose := false
		mut i := 0

		for i < box_args.len {
			arg := box_args[i]
			
			if arg == '-v' {
				verbose = true
				i++
				continue
			} else if arg.starts_with('-r?') && arg.ends_with('?') {
				raw_cmds := arg[3..arg.len-1]
				cmds := raw_cmds.split(',')
				for c in cmds {
					cmd_clean := c.trim_space()
					if cmd_clean == '' { continue }
					parts := cmd_clean.split(' ').filter(it != '')
					if parts.len > 0 {
						mut p := os.new_process(parts[0])
						if parts.len > 1 { p.set_args(parts[1..]) }
						p.run()
						child_procs << p
						println('[*] [Global] Started background task: ${parts[0]} (PID: ${p.pid})')
					}
				}
				i++
				continue
			} else if arg == '-l' && i + 1 < box_args.len {
				raw_uri := box_args[i + 1]
				node := parse_uri(raw_uri) or { eprintln('[!] [Box ${box_idx+1}] Listener Error: ${err}'); exit(1) }
				
				mut existing_idx := -1
				for j in 0 .. listeners.len {
					if listeners[j].addr == node.addr && listeners[j].proto == node.proto { existing_idx = j; break }
				}
				if existing_idx >= 0 {
					listeners[existing_idx].is_global = true
				} else {
					listeners << Listener{ proto: node.proto, addr: node.addr, user: node.user, pass: node.pass, chain_idxs: [], is_global: true }
				}
				i += 2
			} else if (arg == '-u' || arg == '-i') && i + 1 < box_args.len {
				is_upstream := arg == '-u'
				chain_parts := box_args[i + 1].split('+')
				mut current_paths := [][]Node{}; current_paths << []Node{}
				
				for p in chain_parts {
					part := p.trim_space()
					if part == '' { continue }
					if part.starts_with('-x') {
						name := part[2..].trim_space()
						if name == '' || current_paths[0].len == 0 { exit(1) }
						if is_snapshot_name(name) {
							if name !in macros { macros[name] = [][]Node{} }
							for path in current_paths {
								if path.len > 0 { macros[name] << path.clone() }
							}
						} else {
							node := parse_uri(name) or { exit(1) }
							mut new_chain_idxs := []int{}
							for path in current_paths {
								if path.len > 0 {
									chains << Chain{ nodes: path.clone(), alive: true, global: false }
									new_chain_idxs << (chains.len - 1)
								}
							}
							mut existing_idx := -1
							for j in 0 .. listeners.len {
								if listeners[j].addr == node.addr && listeners[j].proto == node.proto { existing_idx = j; break }
							}
							if existing_idx >= 0 {
								for cidx in new_chain_idxs {
									if cidx !in listeners[existing_idx].chain_idxs { listeners[existing_idx].chain_idxs << cidx }
								}
							} else {
								listeners << Listener{ proto: node.proto, addr: node.addr, user: node.user, pass: node.pass, chain_idxs: new_chain_idxs, is_global: false }
							}
						}
					} else {
						if is_snapshot_name(part) {
							if part in macros {
								mut next_paths := [][]Node{}
								for path in current_paths {
									for macro_path in macros[part] {
										mut new_path := path.clone()
										for n in macro_path { new_path << n }
										next_paths << new_path
									}
								}
								current_paths = next_paths.clone()
							} else { exit(1) }
						} else {
							node := parse_uri(part) or { exit(1) }
							for mut path in current_paths { path << node }
						}
					}
				}
				if is_upstream {
					for path in current_paths {
						if path.len > 0 { chains << Chain{ nodes: path.clone(), alive: true, global: true } }
					}
				}
				i += 2
			} else if arg == '-o' && i + 1 < box_args.len {
				global_outbound_str = box_args[i+1]
				i += 2
			} else {
				eprintln('[!] [Box ${box_idx+1}] Unknown argument: ${box_args[i]}'); exit(1)
			}
		}
		
		if global_outbound_str != '' {
			mut out_paths := [][]Node{}; out_paths << []Node{}
			for p in global_outbound_str.split('+') {
				part := p.trim_space()
				if part == '' { continue }
				if is_snapshot_name(part) {
					if part in macros {
						mut next_paths := [][]Node{}
						for path in out_paths {
							for macro_path in macros[part] {
								mut np := path.clone()
								for n in macro_path { np << n }
								next_paths << np
							}
						}
						out_paths = next_paths.clone()
					} else { exit(1) }
				} else {
					node := parse_uri(part) or { exit(1) }
					for mut path in out_paths { path << node }
				}
			}
			if out_paths.len > 0 && out_paths[0].len > 0 {
				single_out := out_paths[0] 
				for mut c in chains {
					for n in single_out { c.nodes << n }
				}
			}
		}

		if listeners.len == 0 {
			eprintln('[!] [Box ${box_idx+1}] Skipped: No listeners defined.')
			continue
		}
		
		mut app := &App{
			id: box_idx + 1
			listeners: listeners
			chains: chains
			rr_counter: 0
			udp_port: u32(40000 + (box_idx * 1000))
			verbose: verbose
		}
		apps << app

		println('[*] [Box ${app.id}] Parsed successfully. ${listeners.len} listener(s), ${chains.len} routing chain(s).')
		if verbose { println('    -> VERBOSE mode enabled for this Box.') }
	}

	if apps.len == 0 {
		eprintln('[!] No valid boxes found to start.')
		return
	}
	
	println('[*] Starting ${apps.len} independent Box(es)...')
	
	for mut app in apps {
		spawn health_checker(mut app)
		for li in 0 .. app.listeners.len {
			spawn start_listener(mut app, li)
		}
	}
	for { time.sleep(1 * time.hour) }
}

@[inline]
fn apply_action(mut buf []u8, nr int, start int, hx []u8) {
	for i in 0 .. hx.len {
		if start + i < nr { buf[start + i] = hx[i] }
	}
}

@[inline]
fn apply_script(mut buf []u8, nr int, script []Rule, verbose bool) {
	for rule in script {
		if rule.mode == 'aob' {
			mut indices := []int{}
			pat_len := rule.aob_pattern.len
			if pat_len <= nr {
				for i := 0; i <= nr - pat_len; i++ {
					mut matched := true
					for j := 0; j < pat_len; j++ {
						if !rule.aob_pattern[j].wildcard && buf[i+j] != rule.aob_pattern[j].val {
							matched = false
							break
						}
					}
					if matched { indices << i }
				}
			}
			for idx in indices {
				if verbose { println('  [+] AOB MATCHED at relative offset ${idx}! Applying action.') }
				apply_action(mut buf, nr, idx + rule.action_start, rule.action_hex)
			}
		} else {
			if rule.has_cond {
				c_len := rule.cond_hex.len
				if rule.cond_start >= 0 && rule.cond_start + c_len <= nr {
					mut matched := true
					for i in 0 .. c_len {
						if buf[rule.cond_start + i] != rule.cond_hex[i] { matched = false; break }
					}
					if matched {
						if verbose { println('  [+] IF MATCHED at offset ${rule.cond_start}. Applying action.') }
						apply_action(mut buf, nr, rule.action_start, rule.action_hex)
					} else if rule.has_else {
						apply_action(mut buf, nr, rule.else_start, rule.else_hex)
					}
				} else if rule.has_else {
					apply_action(mut buf, nr, rule.else_start, rule.else_hex)
				}
			} else {
				if verbose { println('  [+] Unconditional action applied at offset ${rule.action_start}.') }
				apply_action(mut buf, nr, rule.action_start, rule.action_hex)
			}
		}
	}
}

@[inline]
fn relay(mut src net.TcpConn, mut dst net.TcpConn, done chan bool, script []Rule, verbose bool) {
	mut b := []u8{len: buf_size}
	for {
		nr := src.read(mut b) or { break }
		if nr == 0 { break }
		
		if verbose {
			println('\n[-] Traffic In (${nr} bytes): ${hex.encode(b[..nr])}')
		}
		
		if script.len > 0 {
			apply_script(mut b, nr, script, verbose)
			if verbose {
				println('[+] Traffic Out (${nr} bytes): ${hex.encode(b[..nr])}')
			}
		}
		
		dst.write(b[..nr]) or { break }
	}
	done <- true
}

@[inline]
fn do_relay(mut a net.TcpConn, mut b net.TcpConn, script []Rule, verbose bool) {
	a.set_read_timeout(5 * time.minute)
	b.set_read_timeout(5 * time.minute)
	done := chan bool{cap: 2}
	
	spawn relay(mut a, mut b, done, script, verbose)
	spawn relay(mut b, mut a, done, []Rule{}, false)
	
	_ = <-done
}

@[inline]
fn start_listener(mut app App, li int) {
	l := app.listeners[li]
	pname := match l.proto { .socks5 { 'SOCKS5' } .http { 'HTTP' } .sni { 'SNI' } .dns { 'DNS' } }
	
	if l.proto == .dns {
		mut listener := net.listen_udp(l.addr) or { return }
		println('[+] [Box ${app.id}] ${pname} on ${l.addr} (UDP)')
		for {
			mut buf := []u8{len: 2048}
			n, addr := listener.read(mut buf) or { continue }
			if n > 0 { spawn handle_dns_request(mut app, mut listener, addr, buf[..n].clone(), l) }
		}
		return
	}
	mut listener := net.listen_tcp(.ip, l.addr) or { return }
	println('[+] [Box ${app.id}] ${pname} on ${l.addr} (TCP)')
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
	mut order := if l.is_global { pick_chain_order(mut app) } else { pick_best_from_list(mut app, l.chain_idxs) }
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
			out_conn.write_to(addr, req) or { out_conn.close() or {}; return }
			mut resp_buf := []u8{len: 2048}
			rn, _ := out_conn.read(mut resp_buf) or { out_conn.close() or {}; return }
			if rn > 0 { ans_ch <- resp_buf[..rn].clone() }
			out_conn.close() or {}
		}(up_addrs[0], req, ans_ch)
	}

	if sent == 0 { return }
	select { fastest_response := <-ans_ch { listener.write_to(client_addr, fastest_response) or {} } 2 * time.second {} }
}

fn health_checker(mut app App) {
	for {
		for ci in 0 .. app.chains.len {
			t0 := time.now()
			alive := check_chain(app.chains[ci])
			d := time.now() - t0
			
			app.mu.@lock()
			app.chains[ci].alive = alive
			if alive { app.chains[ci].latency = i64(d) / 1000 }
			app.mu.unlock()
		}
		time.sleep(check_interval)
	}
}

@[inline] fn check_chain(c Chain) bool {
	if c.nodes.len == 0 { return false }
	n := c.nodes[0]
	match n.proto { .socks5 { return check_socks5_h(n) } .http { return check_http_h(n) } .sni { return check_tcp_h(n.addr) } .dns { return check_dns_h(n) } }
}
@[inline] fn check_tcp_h(addr string) bool { mut c := net.dial_tcp(addr) or { return false }; c.close() or {}; return true }
fn check_dns_h(n Node) bool {
	mut c := net.listen_udp('0.0.0.0:0') or { return false }
	defer { c.close() or {} }
	c.set_read_timeout(check_timeout)
	addrs := net.resolve_addrs(n.addr, .ip, .udp) or { return false }
	if addrs.len == 0 { return false }
	query := [u8(0x12), 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x06, 0x67, 0x6f, 0x6f, 0x67, 0x6c, 0x65, 0x03, 0x63, 0x6f, 0x6d, 0x00, 0x00, 0x01, 0x00, 0x01]
	c.write_to(addrs[0], query) or { return false }
	mut buf := []u8{len: 512}
	n_read, _ := c.read(mut buf) or { return false }
	return n_read >= 12 && buf[0] == 0x12 && buf[1] == 0x34 && (buf[2] & 0x80) != 0
}
fn check_socks5_h(n Node) bool {
	mut c := net.dial_tcp(n.addr) or { return false }
	defer { c.close() or {} }
	c.set_read_timeout(check_timeout); c.set_write_timeout(check_timeout)
	if n.user != '' {
		c.write([u8(0x05), 0x01, 0x02]) or { return false }
		mut r := []u8{len: 2}; c.read(mut r) or { return false }
		if r[1] != 0x02 { return false }
		mut a := []u8{cap: 3 + n.user.len + n.pass.len}; a << 0x01; a << u8(n.user.len); a << n.user.bytes(); a << u8(n.pass.len); a << n.pass.bytes()
		c.write(a) or { return false }
		mut ar := []u8{len: 2}; c.read(mut ar) or { return false }
		return ar[1] == 0x00
	}
	c.write([u8(0x05), 0x01, 0x00]) or { return false }
	mut r := []u8{len: 2}; c.read(mut r) or { return false }
	return r[1] == 0x00
}
fn check_http_h(n Node) bool {
	mut c := net.dial_tcp(n.addr) or { return false }
	defer { c.close() or {} }
	c.set_read_timeout(check_timeout); c.set_write_timeout(check_timeout)
	mut req := 'CONNECT 1.1.1.1:443 HTTP/1.1\r\nHost: 1.1.1.1:443\r\n'
	if n.user != '' { req += 'Proxy-Authorization: Basic ${base64.encode_str('${n.user}:${n.pass}')}\r\n' }
	req += '\r\n'
	c.write(req.bytes()) or { return false }
	mut buf := []u8{len: 1024}; nr := c.read(mut buf) or { return false }
	return buf[..nr].bytestr().contains('200')
}

@[inline]
fn pick_best_from_list(mut app App, allowed_idxs []int) []int {
	app.mu.@lock(); defer { app.mu.unlock() }
	mut alive_idxs := []int{cap: allowed_idxs.len}
	for ci in allowed_idxs { if ci < app.chains.len && app.chains[ci].alive { alive_idxs << ci } }
	if alive_idxs.len <= 1 { return if alive_idxs.len == 1 { alive_idxs } else { allowed_idxs.clone() } }
	for i in 1 .. alive_idxs.len {
		mut j := i
		for j > 0 {
			if app.chains[alive_idxs[j]].latency < app.chains[alive_idxs[j - 1]].latency {
				tmp := alive_idxs[j]; alive_idxs[j] = alive_idxs[j - 1]; alive_idxs[j - 1] = tmp; j--
			} else { break }
		}
	}
	return alive_idxs
}

@[inline]
fn pick_chain_order(mut app App) []int {
	app.mu.@lock(); defer { app.mu.unlock() }
	mut idxs := []int{cap: app.chains.len}
	for ci in 0 .. app.chains.len { if app.chains[ci].global && app.chains[ci].alive { idxs << ci } }
	if idxs.len == 0 {
		for ci in 0 .. app.chains.len { if app.chains[ci].global { idxs << ci } }
		return idxs
	}
	if idxs.len == 1 { return idxs }
	for i in 1 .. idxs.len {
		mut j := i
		for j > 0 {
			if app.chains[idxs[j]].latency < app.chains[idxs[j - 1]].latency {
				tmp := idxs[j]; idxs[j] = idxs[j - 1]; idxs[j - 1] = tmp; j--
			} else { break }
		}
	}
	mut weights := []i64{cap: idxs.len}; mut total := i64(0)
	for idx in idxs {
		lat := app.chains[idx].latency; mut w := if lat > 0 { i64(10_000_000) / (lat + 1) } else { i64(1000) }
		if w < 1 { w = 1 }; weights << w; total += w
	}
	if total <= 0 { total = 1 }
	pv := i64(app.rr_counter % u64(total)); app.rr_counter++
	mut first := 0; mut cum := i64(0)
	for i in 0 .. weights.len {
		cum += weights[i]; if pv < cum { first = i; break }
	}
	if first == 0 { return idxs }
	mut result := []int{cap: idxs.len}; result << idxs[first]
	for i in 0 .. idxs.len { if i != first { result << idxs[i] } }
	return result
}

fn connect_retry(mut app App, host string, port int, l Listener) !(&net.TcpConn, []Rule) {
	mut order := if l.is_global { pick_chain_order(mut app) } else { pick_best_from_list(mut app, l.chain_idxs) }
	if order.len == 0 { return error('no chains available') }
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
		if app.chains[ci].latency > 100 { app.chains[ci].latency -= 100 }
		app.mu.unlock()
		
		return conn, nodes[0].script
	}
	return error('all chains failed')
}

fn connect_chain(chain []Node, host string, port int) !&net.TcpConn {
	if chain.len == 0 { return error('empty chain') }
	mut conn := net.dial_tcp(chain[0].addr) or { return error('dial failed') }
	match chain[0].proto {
		.socks5 { do_socks5_hs(mut conn, chain[0], host, port)! }
		.http { do_http_hs(mut conn, chain[0], host, port)! }
		.sni {}
		.dns {}
	}
	return conn
}

@[inline] fn do_socks5_hs(mut c net.TcpConn, n Node, host string, port int) ! {
	if n.user != '' { c.write([u8(0x05), 0x01, 0x02])! } else { c.write([u8(0x05), 0x01, 0x00])! }
	mut gr := []u8{len: 2}; read_full(mut c, mut gr, 2)!
	if gr[0] != 0x05 { return error('not socks5') }
	if n.user != '' {
		if gr[1] != 0x02 { return error('auth rejected') }
		mut a := []u8{cap: 3 + n.user.len + n.pass.len}; a << 0x01; a << u8(n.user.len); a << n.user.bytes(); a << u8(n.pass.len); a << n.pass.bytes()
		c.write(a)!; mut ar := []u8{len: 2}; read_full(mut c, mut ar, 2)!
		if ar[1] != 0x00 { return error('auth failed') }
	} else if gr[1] != 0x00 { return error('noauth rejected') }
	
	mut req := []u8{cap: 7 + host.len}
	req << u8(0x05); req << u8(0x01); req << u8(0x00); req << u8(0x03)
	req << u8(host.len); req << host.bytes(); req << u8(port >> 8); req << u8(port & 0xff)
	c.write(req)!
	mut resp := []u8{len: 263}; mut rn := read_full(mut c, mut resp, 4)!
	if resp[1] != 0x00 { return error('connect fail') }
	mut total := 0
	match resp[3] {
		0x01 { total = 10 }
		0x04 { total = 22 }
		0x03 { if rn < 5 { rn = read_full(mut c, mut resp, 5)! }; total = 7 + int(resp[4]) }
		else { return error('bad atyp') }
	}
	if rn < total { read_full(mut c, mut resp, total)! }
}

@[inline] fn do_http_hs(mut c net.TcpConn, n Node, host string, port int) ! {
	tgt := '${host}:${port}'; mut req := 'CONNECT ${tgt} HTTP/1.1\r\nHost: ${tgt}\r\n'
	if n.user != '' { req += 'Proxy-Authorization: Basic ${base64.encode_str('${n.user}:${n.pass}')}\r\n' }
	req += '\r\n'; c.write(req.bytes())!
	mut buf := []u8{len: 4096}; mut acc := []u8{}
	for {
		nr := c.read(mut buf) or { return error('read fail') }
		if nr == 0 { return error('closed') }
		acc << buf[..nr]
		if acc.bytestr().contains('\r\n\r\n') { break }
		if acc.len > 8192 { return error('resp too large') }
	}
	if !acc.bytestr().contains('200') { return error('CONNECT rejected') }
}

fn handle_socks5(mut app App, mut client net.TcpConn, l Listener) {
	defer { client.close() or {} }
	client.set_read_timeout(30 * time.second); client.set_write_timeout(30 * time.second)
	mut greet := []u8{len: 257}; mut gn := read_full(mut client, mut greet, 2) or { return }
	if greet[0] != 0x05 { return }
	needed := 2 + int(greet[1])
	if gn < needed { read_full(mut client, mut greet, needed) or { return } }
	if l.user != '' {
		client.write([u8(0x05), 0x02]) or { return }
		mut auth := []u8{len: 513}; mut an := read_full(mut client, mut auth, 2) or { return }
		if auth[0] != 0x01 { client.write([u8(0x01), 0x01]) or {}; return }
		ulen := int(auth[1])
		if an < 2 + ulen + 1 { an = read_full(mut client, mut auth, 2 + ulen + 1) or { return } }
		plen := int(auth[2 + ulen])
		if an < 2 + ulen + 1 + plen { read_full(mut client, mut auth, 2 + ulen + 1 + plen) or { return } }
		if auth[2..2 + ulen].bytestr() != l.user || auth[3 + ulen..3 + ulen + plen].bytestr() != l.pass {
			client.write([u8(0x01), 0x01]) or {}; return
		}
		client.write([u8(0x01), 0x00]) or { return }
	} else { client.write([u8(0x05), 0x00]) or { return } }

	mut req := []u8{len: 263}; mut rn := read_full(mut client, mut req, 4) or { return }
	cmd := req[1]; atyp := req[3]
	mut host := ''; mut port := 0
	match atyp {
		0x01 {
			if rn < 10 { rn = read_full(mut client, mut req, 10) or { return } }
			host = '${req[4]}.${req[5]}.${req[6]}.${req[7]}'; port = (u16(req[8]) << 8) | u16(req[9])
		}
		0x03 {
			if rn < 5 { rn = read_full(mut client, mut req, 5) or { return } }
			dl := int(req[4])
			if rn < 5 + dl + 2 { rn = read_full(mut client, mut req, 5 + dl + 2) or { return } }
			host = req[5..5 + dl].bytestr(); port = (u16(req[5 + dl]) << 8) | u16(req[5 + dl + 1])
		}
		0x04 {
			if rn < 22 { rn = read_full(mut client, mut req, 22) or { return } }
			mut hp := []string{}
			for j in 0 .. 8 { hp << '${(u16(req[4 + j * 2]) << 8) | u16(req[4 + j * 2 + 1]):x}' }
			host = hp.join(':'); port = (u16(req[20]) << 8) | u16(req[21])
		}
		else { return }
	}
	
	if cmd == 0x03 { handle_udp_associate(mut app, mut client); return }
	if cmd != 0x01 { client.write([u8(0x05), 0x07, 0x00, 0x01, 0,0,0,0, 0,0]) or {}; return }

	mut upstream, script := connect_retry(mut app, host, port, l) or {
		client.write([u8(0x05), 0x04, 0x00, 0x01, 0,0,0,0, 0,0]) or {}; return
	}
	defer { upstream.close() or {} }
	mut ok := []u8{len: 10}; ok[0] = 0x05; ok[3] = 0x01
	client.write(ok) or { return }
	do_relay(mut client, mut upstream, script, app.verbose)
}

fn handle_http(mut app App, mut client net.TcpConn, l Listener) {
	defer { client.close() or {} }
	client.set_read_timeout(30 * time.second); client.set_write_timeout(30 * time.second)
	mut buf := []u8{len: buf_size}; mut acc := []u8{}
	for {
		nr := client.read(mut buf) or { return }
		if nr == 0 { return }
		acc << buf[..nr]
		if acc.bytestr().contains('\r\n\r\n') { break }
		if acc.len > buf_size { return }
	}
	hdr := acc.bytestr()
	if l.user != '' {
		expected := base64.encode_str('${l.user}:${l.pass}'); mut authed := false
		for line in hdr.split('\r\n') {
			if line.to_lower().starts_with('proxy-authorization: basic ') {
				if line[27..].trim_space() == expected { authed = true }
				break
			}
		}
		if !authed { client.write('HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="proxy"\r\n\r\n'.bytes()) or {}; return }
	}
	lines := hdr.split('\r\n'); if lines.len == 0 { return }; parts := lines[0].split(' '); if parts.len < 3 { return }
	method := parts[0]
	if method == 'CONNECT' {
		hp := parts[1].split(':')
		mut t_port := 443; if hp.len > 1 { t_port = hp[1].int() }
		mut upstream, script := connect_retry(mut app, hp[0], t_port, l) or { client.write('HTTP/1.1 502 Bad Gateway\r\n\r\n'.bytes()) or {}; return }
		defer { upstream.close() or {} }
		client.write('HTTP/1.1 200 Connection Established\r\n\r\n'.bytes()) or { return }
		do_relay(mut client, mut upstream, script, app.verbose)
	} else {
		mut rest := parts[1]; if rest.starts_with('http://') { rest = rest[7..] }
		mut host_part := rest; mut path := '/'
		if rest.contains('/') { pos := rest.index('/') or { rest.len }; host_part = rest[..pos]; path = rest[pos..] }
		mut t_host := host_part; mut t_port := 80
		if host_part.contains(':') { hp := host_part.split(':'); t_host = hp[0]; t_port = hp[1].int() }
		mut upstream, script := connect_retry(mut app, t_host, t_port, l) or { client.write('HTTP/1.1 502 Bad Gateway\r\n\r\n'.bytes()) or {}; return }
		defer { upstream.close() or {} }
		mut new_hdr := '${method} ${path} ${parts[2]}\r\n'
		for li in 1 .. lines.len {
			ln := lines[li]
			if ln.to_lower().starts_with('proxy-') { continue }
			new_hdr += '${ln}\r\n'
		}
		upstream.write(new_hdr.bytes()) or { return }
		hdr_end := hdr.index('\r\n\r\n') or { return }
		if hdr_end + 4 < acc.len { upstream.write(acc[hdr_end + 4..]) or { return } }
		do_relay(mut client, mut upstream, script, app.verbose)
	}
}

fn handle_sni(mut app App, mut client net.TcpConn, l Listener) {
	defer { client.close() or {} }
	client.set_read_timeout(30 * time.second)
	mut buf := []u8{len: buf_size}; nr := client.read(mut buf) or { return }; if nr == 0 { return }
	initial := buf[..nr].clone(); hostname := extract_sni(initial)
	if hostname == '' { return }
	mut upstream, script := connect_retry(mut app, hostname, 443, l) or { return }
	defer { upstream.close() or {} }
	
	mut payload := initial.clone()
	if script.len > 0 { apply_script(mut payload, payload.len, script, app.verbose) }
	upstream.write(payload) or { return }
	do_relay(mut client, mut upstream, script, app.verbose)
}

@[inline]
fn extract_sni(d []u8) string {
	if d.len < 44 || d[0] != 0x16 || d[5] != 0x01 { return '' }
	mut p := 43; if p >= d.len { return '' }
	p += 1 + int(d[p]); if p + 2 > d.len { return '' }
	p += 2 + ((u16(d[p]) << 8) | u16(d[p + 1])); if p >= d.len { return '' }
	p += 1 + int(d[p]); if p + 2 > d.len { return '' }
	ext_len := (u16(d[p]) << 8) | u16(d[p + 1]); p += 2; ext_end := p + ext_len
	for p + 4 <= ext_end && p + 4 <= d.len {
		et := (u16(d[p]) << 8) | u16(d[p + 1]); el := (u16(d[p + 2]) << 8) | u16(d[p + 3])
		if et == 0 && el >= 5 && p + 9 <= d.len {
			sn_len := (u16(d[p + 7]) << 8) | u16(d[p + 8])
			if p + 9 + sn_len <= d.len { return d[p + 9..p + 9 + sn_len].bytestr() }
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
		if n == 0 { return error('closed') }; total += n
	}
	return total
}

fn handle_udp_associate(mut app App, mut client net.TcpConn) {
	app.mu.@lock(); port := int(app.udp_port); app.udp_port++; if app.udp_port > 50000 { app.udp_port = 40000 }; app.mu.unlock()
	mut relay := net.listen_udp('0.0.0.0:${port}') or { client.write([u8(0x05), 0x01,0,0,0,0,0,0,0,0]) or {}; return }
	mut out := net.listen_udp('0.0.0.0:0') or { relay.close() or {}; client.write([u8(0x05), 0x01,0,0,0,0,0,0,0,0]) or {}; return }
	mut resp := []u8{len: 10}; resp[0] = 0x05; resp[3] = 0x01; resp[8] = u8(u32(port) >> 8); resp[9] = u8(u32(port) & 0xff)
	client.write(resp) or { relay.close() or {}; out.close() or {}; return }
	spawn tcp_udp_monitor(mut client, mut relay, mut out)
	relay.set_read_timeout(2 * time.minute); out.set_read_timeout(10 * time.second)
	mut buf := []u8{len: buf_size}; mut rbuf := []u8{len: buf_size}
	for {
		n, from := relay.read(mut buf) or { break }
		if n < 7 || buf[2] != 0x00 { continue }
		hdr_len, dest_host, dest_port := parse_udp_socks(buf[..n].clone()) or { continue }
		addrs := net.resolve_addrs('${dest_host}:${dest_port}', .ip, .udp) or { continue }
		if addrs.len == 0 { continue }
		out.write_to(addrs[0], buf[hdr_len..n].clone()) or { continue }
		rn, _ := out.read(mut rbuf) or { continue }; if rn == 0 { continue }
		mut pkt := []u8{cap: hdr_len + rn}; pkt << buf[..hdr_len].clone(); pkt << rbuf[..rn].clone()
		relay.write_to(from, pkt) or { continue }
	}
}

fn parse_udp_socks(d []u8) !(int, string, int) {
	if d.len < 7 { return error('short') }
	match d[3] {
		0x01 { if d.len < 10 { return error('s') }; return 10, '${d[4]}.${d[5]}.${d[6]}.${d[7]}', int((u32(d[8]) << 8) | u32(d[9])) }
		0x03 { dl := int(d[4]); if d.len < 5 + dl + 2 { return error('s') }; return 5 + dl + 2, d[5..5 + dl].bytestr(), int((u32(d[5 + dl]) << 8) | u32(d[5 + dl + 1])) }
		0x04 { if d.len < 22 { return error('s') }; mut p := []string{cap: 8}; for j in 0 .. 8 { p << '${(u16(d[4 + j * 2]) << 8) | u16(d[4 + j * 2 + 1]):x}' }; return 22, p.join(':'), int((u32(d[20]) << 8) | u32(d[21])) }
		else { return error('atyp') }
	}
}

fn tcp_udp_monitor(mut client net.TcpConn, mut relay net.UdpConn, mut out net.UdpConn) {
	mut b := []u8{len: 1}
	for { client.read(mut b) or { break } }
	relay.close() or {}
	out.close() or {}
}