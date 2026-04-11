import net
import os
import time
import sync
import encoding.base64
import encoding.hex

$if !windows {
	#include <sys/resource.h>
	#include <netinet/tcp.h>
}

struct C.rlimit {
mut:
	rlim_cur u64
	rlim_max u64
}

fn C.syscall(int, ...int) i64
fn C.getrlimit(int, &C.rlimit) int
fn C.setrlimit(int, &C.rlimit) int
fn C.socket(int, int, int) int

const check_interval = 10 * time.second
const check_timeout = 5 * time.second
const buf_size = 65536
const dns_sma_lim = 512

struct SocketMonitor {
mut:
	active_count u32
	peak_count u32
	total_opened u64
	total_closed u64
	mu sync.Mutex
	max_allowed u32 = 1000
	warning_threshold u32 = 800
	last_warning time.Time
}

@[heap]
struct ManagedConnection {
mut:
	conn &net.TcpConn
	created_at time.Time
	last_activity time.Time
	purpose string // 'client', 'upstream', 'relay'
	closed bool
}

fn (mut mon SocketMonitor) can_open() bool {
	mon.mu.@lock()
	defer { mon.mu.unlock() }
	
	if mon.active_count >= mon.max_allowed {
		return false
	}
	
	if mon.active_count >= mon.warning_threshold {
		now := time.now()
		if now - mon.last_warning > 5 * time.second {
			mon.last_warning = now
			eprintln('[!] Socket warning: ${mon.active_count}/${mon.max_allowed} active')
		}
	}
	
	return true
}

fn (mut mon SocketMonitor) register_open() bool {
	mon.mu.@lock()
	defer { mon.mu.unlock() }
	
	if mon.active_count >= mon.max_allowed {
		return false
	}
	
	mon.active_count++
	mon.total_opened++
	
	if mon.active_count > mon.peak_count {
		mon.peak_count = mon.active_count
	}
	
	return true
}

fn (mut mon SocketMonitor) register_close() {
	mon.mu.@lock()
	defer { mon.mu.unlock() }
	
	if mon.active_count > 0 {
		mon.active_count--
	}
	mon.total_closed++
}

fn (mut mon SocketMonitor) get_stats() (u32, u32, u64, u64) {
	mon.mu.@lock()
	defer { mon.mu.unlock() }
	return mon.active_count, mon.peak_count, mon.total_opened, mon.total_closed
}

fn (mut app App) register_connection(mut conn net.TcpConn, purpose string) bool {
	if !app.sock_mon.can_open() {
		if app.verbose {
			eprintln('[!] Socket limit reached, rejecting connection')
		}
		conn.close() or {}
		return false
	}
	
	if !app.sock_mon.register_open() {
		conn.close() or {}
		return false
	}
	
	handle := conn.sock.handle
	
	app.mu.@lock()
	app.active_conns[handle] = &ManagedConnection{
		conn: conn
		created_at: time.now()
		last_activity: time.now()
		purpose: purpose
		closed: false
	}
	app.mu.unlock()
	
	return true
}

fn (mut app App) unregister_connection(mut conn net.TcpConn) {
	handle := conn.sock.handle
	
	app.mu.@lock()
	if handle in app.active_conns {
		managed := app.active_conns[handle] or { 
			app.mu.unlock()
			conn.close() or {}
			return 
		}
		
		if !managed.closed {
			mut m := unsafe { managed }
			m.closed = true
			app.active_conns.delete(handle)
			app.sock_mon.register_close()
		}
	}
	app.mu.unlock()
	
	conn.close() or {}
}

fn (mut app App) safe_close(mut conn net.TcpConn) {
	app.unregister_connection(mut conn)
}

fn socket_janitor(mut app App) {
	for {
		time.sleep(30 * time.second)
		
		now := time.now()
		mut to_close := []int{}
		
		app.mu.@lock()
		for handle, managed in app.active_conns {
			if managed.closed {
				to_close << handle
				continue
			}
			
			if now - managed.last_activity > 10 * time.minute {
				to_close << handle
				if app.verbose {
					println('[Janitor] Closing stale connection: ${managed.purpose} (idle ${now - managed.last_activity})')
				}
			}
			
			if now - managed.created_at > 1 * time.hour {
				to_close << handle
				if app.verbose {
					println('[Janitor] Closing old connection: ${managed.purpose} (age ${now - managed.created_at})')
				}
			}
		}
		
		for handle in to_close {
			if handle in app.active_conns {
				managed := app.active_conns[handle] or { continue }
				mut m := unsafe { managed }
				m.closed = true
				m.conn.close() or {}
				app.active_conns.delete(handle)
				app.sock_mon.register_close()
			}
		}
		app.mu.unlock()
		
		if to_close.len > 0 {
			println('[Janitor] Cleaned ${to_close.len} stale sockets')
		}
		
		active, peak, opened, closed := app.sock_mon.get_stats()
		if app.verbose || active > 500 {
			leaked := opened - closed - u64(active)
			println('[Stats] Active: ${active}, Peak: ${peak}, Opened: ${opened}, Closed: ${closed}, Leaked: ${leaked}')
		}
	}
}

fn (mut app App) emergency_cleanup() {
	println('[!] EMERGENCY: Force closing old connections')
	
	now := time.now()
	mut closed_count := 0
	
	app.mu.@lock()
	
	app.req_queue.mu.@lock()
	mut survivors := []PendingRequest{}
	for mut req in app.req_queue.queue {
		if now - req.queued_at > 30 * time.second {
			req.client.close() or {}
			closed_count++
		} else {
			survivors << req
		}
	}
	app.req_queue.queue = survivors
	app.req_queue.mu.unlock()
	
	for handle, managed in app.active_conns {
		if now - managed.last_activity > 2 * time.minute {
			mut m := unsafe { managed }
			m.conn.close() or {}
			app.active_conns.delete(handle)
			app.sock_mon.register_close()
			closed_count++
		}
	}
	
	app.mu.unlock()
	
	println('[!] Emergency cleanup: ${closed_count} connections force-closed')
}

fn emergency_monitor(mut app App) {
	for {
		time.sleep(10 * time.second)
		
		active, _, _, _ := app.sock_mon.get_stats()
		
		if active >= app.sock_mon.max_allowed * 9 / 10 {
			println('[!] Socket usage critical: ${active}/${app.sock_mon.max_allowed}')
			app.emergency_cleanup()
		}
		
		app.req_queue.mu.@lock()
		queue_len := app.req_queue.queue.len
		app.req_queue.mu.unlock()
		
		if queue_len > 500 {
			println('[!] Queue critical: ${queue_len} pending requests')
		}
	}
}

struct ManagedProcess {
	cmd        string
	args       []string
	check_node Node
	conf_path  string
mut:
	proc          &os.Process
	last_restart  time.Time
	restart_count u32
}

struct Watchdog {
mut:
	procs []ManagedProcess
	mu    sync.Mutex
}

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
	l3_key       string
	l3_val       string
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
	nodes       []Node
	alive       bool
	latency     i64
	global      bool
	ema_lat     f64
	succ        u32
	fail        u32
	consec_fail u32
	last_fail   time.Time
}

struct Listener {
	proto ProxyType
	addr  string
	user  string
	pass  string
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
	dns_sma    u32
	req_queue  RequestQueue
	freeze_mode bool
	hedge_delay time.Duration
	sock_mon   SocketMonitor
	active_conns map[int]&ManagedConnection
}

struct HedgeResult {
	mut:
	chain_idx int
	conn &net.TcpConn = unsafe { nil }
	script []Rule
	latency i64
	success bool
}

fn hedge_connect(mut app App, ci int, host string, port int, result_chan chan HedgeResult, delay time.Duration) {
	if delay > 0 {
		time.sleep(delay)
	}
	
	app.mu.@lock()
	nodes := app.chains[ci].nodes.clone()
	app.mu.unlock()
	
	t0 := time.now()
	mut conn := connect_chain(nodes, host, port, app.verbose, mut app) or {
		app.mu.@lock()
		record_failure(mut app.chains[ci])
		app.mu.unlock()
		
		result_chan <- HedgeResult{
			chain_idx: ci
			success: false
		}
		return
	}
	
	lat := i64(time.now() - t0) / 1000
	
	result_chan <- HedgeResult{
		chain_idx: ci
		conn: conn
		script: nodes[0].script
		latency: lat
		success: true
	}
}

struct PendingRequest {
mut:
	client &net.TcpConn
	host string
	port int
	data []u8
	listener Listener
	attempts u32
	queued_at time.Time
	req_type string  // 'socks5', 'http', 'sni'
}

struct RequestQueue {
mut:
	queue []PendingRequest
	mu sync.Mutex
	max_size int = 1000
	max_wait time.Duration = 60 * time.second
}

fn check_fd_limits() {
	$if !windows {
		mut rl := C.rlimit{}
		if C.getrlimit(7, &rl) != 0 {
			eprintln('[!] Cannot read FD limits')
			return
		}
		soft := rl.rlim_cur
		hard := rl.rlim_max
		println('[*] FD limits: soft=${soft}, hard=${hard}')
		if soft < 4096 && soft < hard {
			mut target := if hard > 65536 { u64(65536) } else { hard }
			rl.rlim_cur = target
			if C.setrlimit(7, &rl) == 0 {
				println('[*] FD soft limit raised: ${soft} -> ${target}')
			} else {
				target = if hard > 4096 { u64(4096) } else { hard }
				rl.rlim_cur = target
				if C.setrlimit(7, &rl) == 0 {
					println('[*] FD soft limit raised: ${soft} -> ${target}')
				} else {
					eprintln('[!] WARNING: Cannot raise FD limit (stuck at ${soft})')
					eprintln('    Run: ulimit -n 65536')
				}
			}
		}
		mut rl2 := C.rlimit{}
		C.getrlimit(7, &rl2)
		fl := rl2.rlim_cur
		if fl < 1024 {
			eprintln('[!] CRITICAL: FD limit is only ${fl}. Will crash under load!')
			eprintln('    Minimum: 1024, recommended: 4096+')
		} else if fl < 4096 {
			eprintln('[!] WARNING: FD limit is ${fl}. Heavy traffic may exhaust FDs.')
		} else {
			println('[*] FD limit OK: ${fl}')
		}
	}
}

fn calc_chain_score(c Chain) f64 {
	if c.consec_fail >= 3 {
		elapsed := time.now() - c.last_fail
		if elapsed < 30 * time.second {
			return 0.001
		}
		return 0.01
	}
	total := f64(c.succ + c.fail)
	reliability := if total > 0 { f64(c.succ) / total } else { f64(0.5) }
	lat_score := if c.ema_lat > 1.0 { 1000000.0 / (c.ema_lat + 100.0) } else { f64(10.0) }
	return reliability * reliability * lat_score
}

fn record_success(mut c Chain, latency_us i64) {
	c.consec_fail = 0
	c.succ++
	if c.ema_lat < 1.0 {
		c.ema_lat = f64(latency_us)
	} else {
		c.ema_lat = c.ema_lat * 0.7 + f64(latency_us) * 0.3
	}
	if c.succ + c.fail > 200 {
		c.succ = c.succ * 3 / 4
		c.fail = c.fail * 3 / 4
	}
}

fn record_failure(mut c Chain) {
	c.consec_fail++
	c.fail++
	c.last_fail = time.now()
	c.ema_lat = c.ema_lat * 1.5 + 50000.0
	if c.succ + c.fail > 200 {
		c.succ = c.succ * 3 / 4
		c.fail = c.fail * 3 / 4
	}
}

fn find_proxychains_bin() string {
	for name in ['proxychains4', 'proxychains'] {
		result := os.execute('which ${name}')
		if result.exit_code == 0 {
			found := result.output.trim_space()
			if found.len > 0 {
				return found
			}
		}
	}
	return ''
}

fn find_prior_nodes(chains []Chain, endpoint_addr string) []Node {
	for c in chains {
		for i, n in c.nodes {
			if n.addr == endpoint_addr && i > 0 {
				return c.nodes[..i].clone()
			}
		}
	}
	return []Node{}
}

fn parse_host_port(addr string) (string, string) {
	if addr.starts_with('[') {
		close_bracket := addr.index(']') or { return '', '' }
		host := addr[1..close_bracket]
		if close_bracket + 1 < addr.len && addr[close_bracket + 1] == `:` {
			port := addr[close_bracket + 2..]
			return host, port
		}
		return host, ''
	}
	last_colon := addr.last_index(':') or { return addr, '' }
	return addr[..last_colon], addr[last_colon + 1..]
}

fn gen_proxychains_conf(nodes []Node, box_id int, idx int) string {
	path := 'sockslender_pc_${box_id}_${idx}.conf'
	mut lines := []string{}
	lines << 'strict_chain'
	lines << 'quiet_mode'
	lines << 'proxy_dns'
	lines << 'tcp_read_time_out 15000'
	lines << 'tcp_connect_time_out 8000'
	lines << ''
	lines << '[ProxyList]'
	for n in nodes {
		host, port := parse_host_port(n.addr)
		if host == '' || port == '' {
			continue
		}
		ptype := match n.proto {
			.socks5 { 'socks5' }
			.http { 'http' }
			else { '' }
		}
		if ptype == '' {
			continue
		}
		if n.user != '' {
			lines << '${ptype}\t${host}\t${port}\t${n.user}\t${n.pass}'
		} else {
			lines << '${ptype}\t${host}\t${port}'
		}
	}
	os.write_file(path, lines.join('\n') + '\n') or { return '' }
	return path
}

fn is_snapshot_name(s string) bool {
	if s == '' {
		return false
	}
	for c in s {
		if !((c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`) || c == `_`) {
			return false
		}
	}
	return true
}

fn parse_op(s string) !(int, int, []u8) {
	parts := s.split('=')
	if parts.len != 2 {
		return error('invalid op (missing =): ${s}')
	}
	mut range_str := parts[0].trim_space()
	range_parts := range_str.split('-')
	if range_parts.len != 2 {
		return error('invalid range (missing -): ${parts[0]}')
	}
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
	if clean.len % 2 != 0 {
		return error('AOB pattern length must be even: ${clean}')
	}
	for i := 0; i < clean.len; i += 2 {
		chunk := clean[i..i + 2]
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
	if raw.trim_space() == '' {
		return rules
	}

	parts := smart_split_comma(raw)

	for p in parts {
		mut s := p.trim_space()
		if s == '' {
			continue
		}
		mut rule := Rule{}
		lower_s := s.to_lower()

		if lower_s.starts_with('l3r:') {
			kv := s[4..].trim_space()
			eq_idx := kv.index('=') or { return error('L3R: missing = in "${s}"') }
			rule.mode = 'l3r'
			rule.l3_key = kv[..eq_idx].trim_space().to_lower()
			rule.l3_val = kv[eq_idx + 1..].trim_space()
			rules << rule
			continue
		}

		if lower_s.starts_with('l3:') {
			kv := s[3..].trim_space()
			eq_idx := kv.index('=') or { return error('L3: missing = in "${s}"') }
			rule.mode = 'l3'
			rule.l3_key = kv[..eq_idx].trim_space().to_lower()
			rule.l3_val = kv[eq_idx + 1..].trim_space()
			rules << rule
			continue
		}

		s = s.replace('..', '-')

		if s.contains('if') {
			action_cond := s.split('if')
			if action_cond.len != 2 {
				return error('invalid if syntax')
			}
			left := action_cond[0].trim_space()
			right := action_cond[1].trim_space()
			if left.contains('=') {
				rule.mode = 'offset'
				rule.has_cond = true
				a_start, a_end, a_hex := parse_op(left)!
				rule.action_start = a_start
				rule.action_end = a_end
				rule.action_hex = a_hex
				cond_else := right.split('el')
				c_start, c_end, c_hex := parse_op(cond_else[0])!
				rule.cond_start = c_start
				rule.cond_end = c_end
				rule.cond_hex = c_hex
				if cond_else.len == 2 {
					rule.has_else = true
					e_start, e_end, e_hex := parse_op(cond_else[1])!
					rule.else_start = e_start
					rule.else_end = e_end
					rule.else_hex = e_hex
				}
			} else {
				rule.mode = 'aob'
				rule.aob_pattern = parse_aob(left)!
				a_start, a_end, a_hex := parse_op(right)!
				rule.action_start = a_start
				rule.action_end = a_end
				rule.action_hex = a_hex
			}
		} else {
			rule.mode = 'offset'
			a_start, a_end, a_hex := parse_op(s)!
			rule.action_start = a_start
			rule.action_end = a_end
			rule.action_hex = a_hex
		}
		rules << rule
	}
	return rules
}

fn is_rule_start(s string) bool {
	if s.len == 0 {
		return false
	}
	if s[0] >= `0` && s[0] <= `9` {
		return true
	}
	for c in s {
		if c == `=` {
			return true
		}
		if c == `,` {
			break
		}
	}
	return false
}

fn smart_split_comma(raw string) []string {
	mut result := []string{}
	mut current := []u8{}
	mut in_l3 := false
	bytes := raw.bytes()

	for idx := 0; idx < bytes.len; idx++ {
		ch := bytes[idx]

		if ch == u8(`,`) {
			if in_l3 {
				peek := raw[idx + 1..].trim_space().to_lower()
				if peek.starts_with('l3:') || peek.starts_with('l3r:')
					|| peek.len == 0 || is_rule_start(peek) {
					result << current.bytestr()
					current.clear()
					in_l3 = false
					continue
				}
				current << ch
				continue
			}
			result << current.bytestr()
			current.clear()
			continue
		}

		current << ch

		if !in_l3 && current.len >= 3 {
			prefix := current.bytestr().trim_space().to_lower()
			if prefix == 'l3:' || prefix == 'l3r:' {
				in_l3 = true
			}
		}
	}

	if current.len > 0 {
		result << current.bytestr()
	}
	return result
}

fn parse_uri(raw string) !Node {
	if raw.trim_space() == '' {
		return error('URI is empty')
	}
	mut s := raw.trim_space()
	mut script := []Rule{}
	if s.count('?') >= 2 {
		first_q := s.index('?') or { -1 }
		last_q := s.last_index('?') or { -1 }
		if first_q != -1 && last_q != -1 && last_q > first_q {
			script_str := s[first_q + 1..last_q]
			s = s[..first_q] + s[last_q + 1..]
			script = parse_script(script_str) or { return error('Script error: ${err}') }
		}
	}
	mut proto := ProxyType.socks5
	if s.contains('://') {
		parts := s.split('://')
		if parts.len > 2 {
			return error('Invalid URI format')
		}
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
	mut user := ''
	mut pass := ''
	mut addr := s
	if s.contains('@') {
		at_parts := s.split('@')
		if at_parts.len > 2 {
			return error('Invalid URI format')
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
		return error('Missing address')
	}
	if proto != .dns && !addr.contains(':') {
		return error('Missing port')
	}
	if proto == .dns && !addr.contains(':') {
		addr += ':53'
	}
	return Node{
		proto: proto
		addr: addr
		user: user
		pass: pass
		script: script
	}
}

fn parse_int_or_hex(s string) int {
	if s.starts_with('0x') || s.starts_with('0X') {
		bytes := hex.decode(s[2..]) or { return 0 }
		mut val := u32(0)
		for b in bytes {
			val = (val << 8) | u32(b)
		}
		return int(val)
	}
	return s.int()
}

fn apply_l3(fd int, rules []Rule, verbose bool) {
	$if !windows {
		for rule in rules {
			if rule.mode != 'l3' {
				continue
			}
			match rule.l3_key {
				'ttl' {
					mut val := parse_int_or_hex(rule.l3_val)
					res := C.setsockopt(fd, 0, 2, &val, u32(4))
					if verbose {
						println('  [L3] TTL=${val} ${if res == 0 { 'OK' } else { 'FAIL' }}')
					}
				}
				'tos' {
					mut val := parse_int_or_hex(rule.l3_val)
					res := C.setsockopt(fd, 0, 1, &val, u32(4))
					if verbose {
						println('  [L3] TOS=0x${val:02x} ${if res == 0 { 'OK' } else { 'FAIL' }}')
					}
				}
				'mark' {
					mut val := parse_int_or_hex(rule.l3_val)
					res := C.setsockopt(fd, 1, 36, &val, u32(4))
					if verbose {
						println('  [L3] MARK=${val} ${if res == 0 { 'OK' } else { 'FAIL(root?)' }}')
					}
				}
				'bind' {
					dev := rule.l3_val
					res := C.setsockopt(fd, 1, 25, dev.str, u32(dev.len + 1))
					if verbose {
						println('  [L3] BIND=${dev} ${if res == 0 { 'OK' } else { 'FAIL(root?)' }}')
					}
				}
				'df' {
					mut val := parse_int_or_hex(rule.l3_val)
					res := C.setsockopt(fd, 0, 10, &val, u32(4))
					if verbose {
						println('  [L3] DF=${val} ${if res == 0 { 'OK' } else { 'FAIL' }}')
					}
				}
				'tproxy' {
					mut val := parse_int_or_hex(rule.l3_val)
					res := C.setsockopt(fd, 0, 19, &val, u32(4))
					if verbose {
						println('  [L3] TPROXY=${val} ${if res == 0 { 'OK' } else { 'FAIL(root?)' }}')
					}
				}
				'keepalive' {
					mut val := parse_int_or_hex(rule.l3_val)
					res := C.setsockopt(fd, 1, 9, &val, u32(4))
					if verbose {
						println('  [L3] KEEPALIVE=${val} ${if res == 0 { 'OK' } else { 'FAIL' }}')
					}
				}
				'nodelay' {
					mut val := parse_int_or_hex(rule.l3_val)
					res := C.setsockopt(fd, 6, 1, &val, u32(4))
					if verbose {
						println('  [L3] NODELAY=${val} ${if res == 0 { 'OK' } else { 'FAIL' }}')
					}
				}
				'delay' {
					val := parse_int_or_hex(rule.l3_val)
					time.sleep(val * time.millisecond)
					if verbose {
						println('  [G] DELAY=${val} OK')
					}
				}
				else {
					if verbose {
						println('  [L3] Unknown: ${rule.l3_key}')
					}
				}
			}
		}
	}
}

fn ip_checksum(data []u8) u16 {
	mut sum := u32(0)
	mut i := 0
	for i + 1 < data.len {
		sum += u32((u16(data[i]) << 8) | u16(data[i + 1]))
		i += 2
	}
	if i < data.len {
		sum += u32(u16(data[i]) << 8)
	}
	for (sum >> 16) > 0 {
		sum = (sum & 0xFFFF) + (sum >> 16)
	}
	return u16(~sum & 0xFFFF)
}

fn tcp_checksum(src_ip []u8, dst_ip []u8, tcp_data []u8) u16 {
	tl := tcp_data.len
	mut pseudo := []u8{len: 12 + tl}
	for i in 0 .. 4 {
		pseudo[i] = src_ip[i]
		pseudo[4 + i] = dst_ip[i]
	}
	pseudo[8] = 0
	pseudo[9] = 6
	pseudo[10] = u8(tl >> 8)
	pseudo[11] = u8(tl & 0xFF)
	for i in 0 .. tl {
		pseudo[12 + i] = tcp_data[i]
	}
	return ip_checksum(pseudo)
}

fn get_sock_info(fd int) ([]u8, u16, []u8, u16) {
	$if !windows {
		mut local_buf := [16]u8{}
		mut remote_buf := [16]u8{}
		mut alen := u32(16)
		unsafe {
			C.getsockname(fd, voidptr(&local_buf), &alen)
			alen = u32(16)
			C.getpeername(fd, voidptr(&remote_buf), &alen)
		}
		src_ip := [local_buf[4], local_buf[5], local_buf[6], local_buf[7]]
		src_port := (u16(local_buf[2]) << 8) | u16(local_buf[3])
		dst_ip := [remote_buf[4], remote_buf[5], remote_buf[6], remote_buf[7]]
		dst_port := (u16(remote_buf[2]) << 8) | u16(remote_buf[3])
		return src_ip, src_port, dst_ip, dst_port
	}
	return [u8(0), 0, 0, 0], u16(0), [u8(0), 0, 0, 0], u16(0)
}

fn get_tcp_seq(fd int) (u32, bool) {
	$if !windows {
		mut one := int(1)
		mut zero := int(0)
		if C.setsockopt(fd, 6, 19, &one, u32(4)) != 0 {
			return u32(0), false
		}
		C.setsockopt(fd, 6, 20, &zero, u32(4))
		mut seq := u32(0)
		mut slen := u32(4)
		C.getsockopt(fd, 6, 21, &seq, &slen)
		C.setsockopt(fd, 6, 19, &zero, u32(4))
		return seq, true
	}
	return u32(0), false
}

fn build_raw_tcp(src_ip []u8, dst_ip []u8, src_port u16, dst_port u16, seq u32, ack u32, flags u8, ttl u8, payload []u8) []u8 {
	total := 40 + payload.len
	mut pkt := []u8{len: total}
	pkt[0] = 0x45
	pkt[2] = u8(total >> 8)
	pkt[3] = u8(total & 0xFF)
	pkt[4] = 0xDE
	pkt[5] = 0xAD
	pkt[6] = 0x40
	pkt[8] = ttl
	pkt[9] = 6
	for i in 0 .. 4 {
		pkt[12 + i] = src_ip[i]
		pkt[16 + i] = dst_ip[i]
	}
	ck := ip_checksum(pkt[..20])
	pkt[10] = u8(ck >> 8)
	pkt[11] = u8(ck & 0xFF)
	pkt[20] = u8(src_port >> 8)
	pkt[21] = u8(src_port & 0xFF)
	pkt[22] = u8(dst_port >> 8)
	pkt[23] = u8(dst_port & 0xFF)
	pkt[24] = u8(seq >> 24)
	pkt[25] = u8((seq >> 16) & 0xFF)
	pkt[26] = u8((seq >> 8) & 0xFF)
	pkt[27] = u8(seq & 0xFF)
	pkt[28] = u8(ack >> 24)
	pkt[29] = u8((ack >> 16) & 0xFF)
	pkt[30] = u8((ack >> 8) & 0xFF)
	pkt[31] = u8(ack & 0xFF)
	pkt[32] = 0x50
	pkt[33] = flags
	pkt[34] = 0xFF
	pkt[35] = 0xFF
	for i in 0 .. payload.len {
		pkt[40 + i] = payload[i]
	}
	tc := tcp_checksum(pkt[12..16], pkt[16..20], pkt[20..])
	pkt[36] = u8(tc >> 8)
	pkt[37] = u8(tc & 0xFF)
	return pkt
}

fn send_raw_packet(dst_ip []u8, dst_port u16, pkt []u8) bool {
	$if !windows {
		raw_fd := unsafe { C.socket(net.AddrFamily(2), net.SocketType(3), 255) }
		if raw_fd < 0 {
			return false
		}
		mut one := int(1)
		C.setsockopt(raw_fd, 0, 3, &one, u32(4))
		mut dest := [16]u8{}
		dest[0] = 2
		dest[2] = u8(dst_port >> 8)
		dest[3] = u8(dst_port & 0xFF)
		dest[4] = dst_ip[0]
		dest[5] = dst_ip[1]
		dest[6] = dst_ip[2]
		dest[7] = dst_ip[3]
		unsafe {
			C.sendto(raw_fd, voidptr(pkt.data), pkt.len, 0, voidptr(&dest), u32(16))
		}
		C.close(raw_fd)
		return true
	}
	return false
}

fn has_l3r_rules(script []Rule) bool {
	for r in script {
		if r.mode == 'l3r' {
			return true
		}
	}
	return false
}

fn desync_write(mut conn net.TcpConn, data []u8, script []Rule, verbose bool) bool {
	fd := conn.sock.handle
	
	for rule in script {
		if rule.mode != 'l3r' {
			continue
		}
		match rule.l3_key {
			'fake' {
				$if !windows {
					ttl := parse_int_or_hex(rule.l3_val)
					src_ip, src_port, dst_ip, dst_port := get_sock_info(fd)
					seq, seq_ok := get_tcp_seq(fd)
					if !seq_ok {
						if verbose {
							println('  [L3R] FAKE skipped: TCP_REPAIR failed')
						}
						continue
					}
					fake_payload := gen_fake_payload(data.len, 0)
					pkt := build_raw_tcp(src_ip, dst_ip, src_port, dst_port, seq, 0,
						0x18, u8(ttl), fake_payload)
					ok := send_raw_packet(dst_ip, dst_port, pkt)
					if verbose {
						println('  [L3R] FAKE TTL=${ttl} ${if ok { 'OK' } else { 'FAIL' }}')
					}
					time.sleep(1 * time.millisecond)
				}
			}
			'fakets' {
				$if !windows {
					ttl := parse_int_or_hex(rule.l3_val)
					src_ip, src_port, dst_ip, dst_port := get_sock_info(fd)
					seq, seq_ok := get_tcp_seq(fd)
					if !seq_ok {
						if verbose {
							println('  [L3R] FAKETS skipped: TCP_REPAIR failed')
						}
						continue
					}
					fake_payload := gen_fake_payload(data.len, 7)
					pkt := build_raw_tcp_ex(src_ip, dst_ip, src_port, dst_port, seq,
						0, 0x18, u8(ttl), fake_payload, true)
					ok := send_raw_packet(dst_ip, dst_port, pkt)
					if verbose {
						println('  [L3R] FAKETS TTL=${ttl} (with TCP timestamp) ${if ok { 'OK' } else { 'FAIL' }}')
					}
					time.sleep(1 * time.millisecond)
				}
			}
			'rst' {
				$if !windows {
					ttl := parse_int_or_hex(rule.l3_val)
					src_ip, src_port, dst_ip, dst_port := get_sock_info(fd)
					seq, seq_ok := get_tcp_seq(fd)
					if !seq_ok {
						if verbose {
							println('  [L3R] RST skipped: TCP_REPAIR failed')
						}
						continue
					}
					pkt := build_raw_tcp(src_ip, dst_ip, src_port, dst_port, seq, 0,
						0x04, u8(ttl), []u8{})
					ok := send_raw_packet(dst_ip, dst_port, pkt)
					if verbose {
						println('  [L3R] RST TTL=${ttl} ${if ok { 'OK' } else { 'FAIL' }}')
					}
					time.sleep(1 * time.millisecond)
				}
			}
			'oob' {
				$if !windows {
					oob_data := hex.decode(rule.l3_val) or { continue }
					if oob_data.len > 0 {
						res := unsafe {
							C.send(fd, voidptr(oob_data.data), oob_data.len, 1)
						}
						if verbose {
							println('  [L3R] OOB ${if res > 0 { 'OK' } else { 'FAIL' }}')
						}
						time.sleep(1 * time.millisecond)
					}
				}
			}
			'spoof' {
				$if !windows {
					spoof_ip := parse_spoof_ip(rule.l3_val)
					_, src_port, dst_ip, dst_port := get_sock_info(fd)
					seq, seq_ok := get_tcp_seq(fd)
					if !seq_ok {
						if verbose {
							println('  [L3R] SPOOF skipped: TCP_REPAIR failed')
						}
						continue
					}
					fake_payload := gen_fake_payload(data.len, 13)
					pkt := build_raw_tcp(spoof_ip, dst_ip, src_port, dst_port, seq, 0,
						0x18, 64, fake_payload)
					ok := send_raw_packet(dst_ip, dst_port, pkt)
					if verbose {
						println('  [L3R] SPOOF src=${spoof_ip[0]}.${spoof_ip[1]}.${spoof_ip[2]}.${spoof_ip[3]} ${if ok { 'OK' } else { 'FAIL' }}')
					}
					time.sleep(1 * time.millisecond)
				}
			}
			'spoofrst' {
				$if !windows {
					spoof_ip := parse_spoof_ip(rule.l3_val)
					_, src_port, dst_ip, dst_port := get_sock_info(fd)
					seq, seq_ok := get_tcp_seq(fd)
					if !seq_ok {
						continue
					}
					pkt := build_raw_tcp(spoof_ip, dst_ip, src_port, dst_port, seq, 0,
						0x04, 64, []u8{})
					ok := send_raw_packet(dst_ip, dst_port, pkt)
					if verbose {
						println('  [L3R] SPOOFED RST from ${spoof_ip[0]}.${spoof_ip[1]}.${spoof_ip[2]}.${spoof_ip[3]} ${if ok { 'OK' } else { 'FAIL' }}')
					}
					time.sleep(1 * time.millisecond)
				}
			}
			'ipfrag' {
				$if !windows {
					frag_size := parse_int_or_hex(rule.l3_val)
					src_ip, src_port, dst_ip, dst_port := get_sock_info(fd)
					seq, seq_ok := get_tcp_seq(fd)
					if !seq_ok {
						if verbose {
							println('  [L3R] IPFRAG skipped: TCP_REPAIR failed')
						}
						continue
					}
					fake_payload := gen_fake_payload(data.len, 3)
					full_pkt := build_raw_tcp(src_ip, dst_ip, src_port, dst_port, seq,
						0, 0x18, 3, fake_payload)
					fragments := build_ip_fragments(full_pkt, frag_size)
					mut sent := 0
					for frag in fragments {
						if send_raw_packet(dst_ip, dst_port, frag) {
							sent++
						}
					}
					if verbose {
						println('  [L3R] IPFRAG: ${fragments.len} frags (${frag_size}B), sent=${sent}')
					}
					time.sleep(1 * time.millisecond)
				}
			}
			'revfrag' {
				$if !windows {
					frag_size := parse_int_or_hex(rule.l3_val)
					src_ip, src_port, dst_ip, dst_port := get_sock_info(fd)
					seq, seq_ok := get_tcp_seq(fd)
					if !seq_ok {
						continue
					}
					fake_payload := gen_fake_payload(data.len, 5)
					full_pkt := build_raw_tcp(src_ip, dst_ip, src_port, dst_port, seq,
						0, 0x18, 3, fake_payload)
					fragments := build_reversed_fragments(full_pkt, frag_size)
					mut sent := 0
					for frag in fragments {
						if send_raw_packet(dst_ip, dst_port, frag) {
							sent++
						}
						time.sleep(500 * time.microsecond)
					}
					if verbose {
						println('  [L3R] REVFRAG: ${fragments.len} reversed frags, sent=${sent}')
					}
					time.sleep(1 * time.millisecond)
				}
			}
			'multifake' {
				$if !windows {
					count := parse_int_or_hex(rule.l3_val)
					src_ip, src_port, dst_ip, dst_port := get_sock_info(fd)
					seq, seq_ok := get_tcp_seq(fd)
					if !seq_ok {
						if verbose {
							println('  [L3R] MULTIFAKE skipped: TCP_REPAIR failed')
						}
						continue
					}
					mut sent := 0
					t := u64(time.now().unix_milli())
					for fi in 0 .. count {
						ttl := u8((t + u64(fi)) % 4 + 1)
						fake_payload := gen_fake_payload(data.len, fi)
						pkt := build_raw_tcp(src_ip, dst_ip, src_port, dst_port, seq,
							0, 0x18, ttl, fake_payload)
						if send_raw_packet(dst_ip, dst_port, pkt) {
							sent++
						}
					}
					if verbose {
						println('  [L3R] MULTIFAKE: ${sent}/${count} sent')
					}
					time.sleep(1 * time.millisecond)
				}
			}
			'spooffrag' {
				$if !windows {
					parts := rule.l3_val.split(':')
					if parts.len != 2 {
						if verbose {
							println('  [L3R] SPOOFFRAG syntax: spooffrag=IP:fragsize')
						}
						continue
					}
					spoof_ip := parse_spoof_ip(parts[0])
					frag_size := parse_int_or_hex(parts[1])
					_, src_port, dst_ip, dst_port := get_sock_info(fd)
					seq, seq_ok := get_tcp_seq(fd)
					if !seq_ok {
						continue
					}
					fake_payload := gen_fake_payload(data.len, 9)
					full_pkt := build_raw_tcp(spoof_ip, dst_ip, src_port, dst_port, seq,
						0, 0x18, 64, fake_payload)
					fragments := build_ip_fragments(full_pkt, frag_size)
					mut sent := 0
					for frag in fragments {
						if send_raw_packet(dst_ip, dst_port, frag) {
							sent++
						}
					}
					if verbose {
						println('  [L3R] SPOOFFRAG: ${fragments.len} frags from ${spoof_ip[0]}.${spoof_ip[1]}.${spoof_ip[2]}.${spoof_ip[3]}, sent=${sent}')
					}
					time.sleep(1 * time.millisecond)
				}
			}
			'synfake' {
				$if !windows {
					ttl := parse_int_or_hex(rule.l3_val)
					src_ip, src_port, dst_ip, dst_port := get_sock_info(fd)
					seq, seq_ok := get_tcp_seq(fd)
					if !seq_ok {
						continue
					}
					fake_payload := gen_fake_payload(if data.len > 64 {
						64
					} else {
						data.len
					}, 11)
					pkt := build_raw_tcp(src_ip, dst_ip, src_port, dst_port, seq - 1,
						0, 0x02, u8(ttl), fake_payload)
					ok := send_raw_packet(dst_ip, dst_port, pkt)
					if verbose {
						println('  [L3R] SYNFAKE TTL=${ttl} ${if ok { 'OK' } else { 'FAIL' }}')
					}
					time.sleep(1 * time.millisecond)
				}
			}
			'disorder' {
				$if !windows {
					pos := parse_int_or_hex(rule.l3_val)
					if pos > 0 && pos < data.len {
						src_ip, src_port, dst_ip, dst_port := get_sock_info(fd)
						seq, seq_ok := get_tcp_seq(fd)
						if !seq_ok {
							if verbose {
								println('  [L3R] DISORDER skipped')
							}
							continue
						}
						pkt2 := build_raw_tcp(src_ip, dst_ip, src_port, dst_port,
							seq + u32(pos), 0, 0x18, 64, data[pos..])
						send_raw_packet(dst_ip, dst_port, pkt2)
						time.sleep(1 * time.millisecond)
						conn.write(data[..pos]) or { return false }
						conn.write(data[pos..]) or { return false }
						if verbose {
							println('  [L3R] DISORDER at ${pos}')
						}
						return true
					}
				}
			}
			'badcsum' {
				$if !windows {
					src_ip, src_port, dst_ip, dst_port := get_sock_info(fd)
					seq, seq_ok := get_tcp_seq(fd)
					if !seq_ok {
						if verbose {
							println('  [L3R] BADCSUM skipped: TCP_REPAIR failed')
						}
						continue
					}
					fake_payload := gen_fake_payload(data.len, 15)
					mut pkt := build_raw_tcp(src_ip, dst_ip, src_port, dst_port, seq, 0, 0x18, 64, fake_payload)
					pkt[36] = ~pkt[36]
					pkt[37] = ~pkt[37]
					
					ok := send_raw_packet(dst_ip, dst_port, pkt)
					if verbose {
						println('  [L3R] BADCSUM sent ${if ok { 'OK' } else { 'FAIL' }}')
					}
					time.sleep(1 * time.millisecond)
				}
			}
			'faketeardown' {
				$if !windows {
					src_ip, src_port, dst_ip, dst_port := get_sock_info(fd)
					seq, seq_ok := get_tcp_seq(fd)
					if !seq_ok { continue }
					
					mut pkt := build_raw_tcp(src_ip, dst_ip, src_port, dst_port, seq, 0, 0x11, 64, []u8{})
					pkt[36] = ~pkt[36]
					pkt[37] = ~pkt[37]
					
					ok := send_raw_packet(dst_ip, dst_port, pkt)
					if verbose {
						println('  [L3R] FAKE TEARDOWN (FIN) sent ${if ok { 'OK' } else { 'FAIL' }}')
					}
					time.sleep(1 * time.millisecond)
				}
			}
			'udpfake' {
				$if !windows {
					ttl := parse_int_or_hex(rule.l3_val)
					src_ip, src_port, dst_ip, dst_port := get_sock_info(fd)
					
					fake_payload := gen_fake_payload(data.len, 0)
					pkt := build_raw_udp(src_ip, dst_ip, src_port, dst_port, u8(ttl), fake_payload)
					ok := send_raw_packet(dst_ip, dst_port, pkt)
					
					if verbose {
						println('  [L3R] UDP FAKE TTL=${ttl} ${if ok { 'OK' } else { 'FAIL' }}')
					}
					time.sleep(1 * time.millisecond)
				}
			}
			'udpbadcsum' {
				$if !windows {
					ttl := parse_int_or_hex(rule.l3_val)
					src_ip, src_port, dst_ip, dst_port := get_sock_info(fd)
					
					fake_payload := gen_fake_payload(data.len, 15)
					mut pkt := build_raw_udp(src_ip, dst_ip, src_port, dst_port, u8(ttl), fake_payload)
					
					pkt[26] = ~pkt[26]
					pkt[27] = ~pkt[27]
					
					ok := send_raw_packet(dst_ip, dst_port, pkt)
					if verbose {
						println('  [L3R] UDP BADCSUM TTL=${ttl} sent ${if ok { 'OK' } else { 'FAIL' }}')
					}
					time.sleep(1 * time.millisecond)
				}
			}
			'udpzerocsum' {
				$if !windows {
					ttl := parse_int_or_hex(rule.l3_val)
					src_ip, src_port, dst_ip, dst_port := get_sock_info(fd)
					
					fake_payload := gen_fake_payload(data.len, 16)
					mut pkt := build_raw_udp(src_ip, dst_ip, src_port, dst_port, u8(ttl), fake_payload)
					
					pkt[26] = 0x00
					pkt[27] = 0x00
					
					ok := send_raw_packet(dst_ip, dst_port, pkt)
					if verbose {
						println('  [L3R] UDP ZEROCSUM TTL=${ttl} ${if ok { 'OK' } else { 'FAIL' }}')
					}
					time.sleep(1 * time.millisecond)
				}
			}
			'udpspoof' {
				$if !windows {
					spoof_ip := parse_spoof_ip(rule.l3_val)
					_, src_port, dst_ip, dst_port := get_sock_info(fd)
					
					fake_payload := gen_fake_payload(data.len, 13)
					pkt := build_raw_udp(spoof_ip, dst_ip, src_port, dst_port, 64, fake_payload)
					ok := send_raw_packet(dst_ip, dst_port, pkt)
					
					if verbose {
						println('  [L3R] UDP SPOOF src=${spoof_ip[0]}.${spoof_ip[1]}.${spoof_ip[2]}.${spoof_ip[3]} ${if ok { 'OK' } else { 'FAIL' }}')
					}
					time.sleep(1 * time.millisecond)
				}
			}
			'udpipfrag' {
				$if !windows {
					frag_size := parse_int_or_hex(rule.l3_val)
					src_ip, src_port, dst_ip, dst_port := get_sock_info(fd)
					
					fake_payload := gen_fake_payload(data.len, 3)
					full_pkt := build_raw_udp(src_ip, dst_ip, src_port, dst_port, 3, fake_payload)
					fragments := build_ip_fragments(full_pkt, frag_size)
					
					mut sent := 0
					for frag in fragments {
						if send_raw_packet(dst_ip, dst_port, frag) {
							sent++
						}
					}
					if verbose {
						println('  [L3R] UDP IPFRAG: ${fragments.len} frags (${frag_size}B), sent=${sent}')
					}
					time.sleep(1 * time.millisecond)
				}
			}
			'udprevfrag' {
				$if !windows {
					frag_size := parse_int_or_hex(rule.l3_val)
					src_ip, src_port, dst_ip, dst_port := get_sock_info(fd)
					
					fake_payload := gen_fake_payload(data.len, 5)
					full_pkt := build_raw_udp(src_ip, dst_ip, src_port, dst_port, 3, fake_payload)
					fragments := build_reversed_fragments(full_pkt, frag_size)
					
					mut sent := 0
					for frag in fragments {
						if send_raw_packet(dst_ip, dst_port, frag) {
							sent++
						}
						time.sleep(500 * time.microsecond)
					}
					if verbose {
						println('  [L3R] UDP REVFRAG: ${fragments.len} reversed frags, sent=${sent}')
					}
					time.sleep(1 * time.millisecond)
				}
			}
			'udpmultifake' {
				$if !windows {
					count := parse_int_or_hex(rule.l3_val)
					src_ip, src_port, dst_ip, dst_port := get_sock_info(fd)
					
					mut sent := 0
					t := u64(time.now().unix_milli())
					for fi in 0 .. count {
						ttl := u8((t + u64(fi)) % 4 + 1)
						fake_payload := gen_fake_payload(data.len, fi)
						
						pkt := build_raw_udp(src_ip, dst_ip, src_port, dst_port, ttl, fake_payload)
						if send_raw_packet(dst_ip, dst_port, pkt) {
							sent++
						}
					}
					if verbose {
						println('  [L3R] UDP MULTIFAKE: ${sent}/${count} sent')
					}
					time.sleep(1 * time.millisecond)
				}
			}
			'udpspooffrag' {
				$if !windows {
					parts := rule.l3_val.split(':')
					if parts.len != 2 {
						if verbose {
							println('  [L3R] UDP SPOOFFRAG syntax: spooffrag=IP:fragsize')
						}
						continue
					}
					spoof_ip := parse_spoof_ip(parts[0])
					frag_size := parse_int_or_hex(parts[1])
					_, src_port, dst_ip, dst_port := get_sock_info(fd)
					
					fake_payload := gen_fake_payload(data.len, 9)
					full_pkt := build_raw_udp(spoof_ip, dst_ip, src_port, dst_port, 64, fake_payload)
					fragments := build_ip_fragments(full_pkt, frag_size)
					
					mut sent := 0
					for frag in fragments {
						if send_raw_packet(dst_ip, dst_port, frag) {
							sent++
						}
					}
					if verbose {
						println('  [L3R] UDP SPOOFFRAG: ${fragments.len} frags from ${spoof_ip[0]}.${spoof_ip[1]}.${spoof_ip[2]}.${spoof_ip[3]}, sent=${sent}')
					}
					time.sleep(1 * time.millisecond)
				}
			}
			'udpbadlength' {
				$if !windows {
					ttl := parse_int_or_hex(rule.l3_val)
					src_ip, src_port, dst_ip, dst_port := get_sock_info(fd)
					
					fake_payload := gen_fake_payload(data.len, 17)
					mut pkt := build_raw_udp(src_ip, dst_ip, src_port, dst_port, u8(ttl), fake_payload)
					
					bad_len := u16(9999) 
					pkt[24] = u8(bad_len >> 8)
					pkt[25] = u8(bad_len & 0xFF)
					
					ok := send_raw_packet(dst_ip, dst_port, pkt)
					if verbose {
						println('  [L3R] UDP BADLENGTH TTL=${ttl} ${if ok { 'OK' } else { 'FAIL' }}')
					}
					time.sleep(1 * time.millisecond)
				}
			}
			else {}
		}
	}
	
	for rule in script {
		if rule.mode != 'l3r' {
			continue
		}
		match rule.l3_key {
			'split' {
				pos := parse_int_or_hex(rule.l3_val)
				if pos > 0 && pos < data.len {
					conn.write(data[..pos]) or { return false }
					time.sleep(1 * time.millisecond)
					conn.write(data[pos..]) or { return false }
					if verbose {
						println('  [L3R] SPLIT at ${pos}: ${pos}+${data.len - pos}')
					}
					return true
				}
			}
			'seg' {
				seg_size := parse_int_or_hex(rule.l3_val)
				if seg_size > 0 && seg_size < data.len {
					mut offset := 0
					for offset < data.len {
						mut end := offset + seg_size
						if end > data.len {
							end = data.len
						}
						conn.write(data[offset..end]) or { return false }
						offset = end
						if offset < data.len {
							time.sleep(1 * time.millisecond)
						}
					}
					if verbose {
						println('  [L3R] SEG: ${seg_size}-byte chunks')
					}
					return true
				}
			}
			'udptail' {
				$if !windows {
					pos := parse_int_or_hex(rule.l3_val)
					if pos > 0 && pos < data.len {
						src_ip, src_port, dst_ip, dst_port := get_sock_info(fd)
						
						full_pkt := build_raw_udp(src_ip, dst_ip, src_port, dst_port, 64, data)
						fragments := build_ip_fragments(full_pkt, pos) 
						
						for frag in fragments {
							send_raw_packet(dst_ip, dst_port, frag)
							time.sleep(500 * time.microsecond)
						}
						
						if verbose {
							println('  [L3R] UDP TAIL/FRAG at ${pos}: ${pos}+${data.len - pos}')
						}
						return true 
					}
				}
			}
			else {}
		}
	}

	conn.write(data) or { return false }
	return true
}

fn main() {
	check_fd_limits()
	check_raw_socket_cap()

	mut child_procs := []&os.Process{}
	mut wd := &Watchdog{}
	defer {
		mut total_killed := 0
		for mut p in child_procs {
			if p.is_alive() {
				p.signal_kill()
				p.wait()
				p.close()
				total_killed++
			}
		}
		wd.mu.@lock()
		for mut mp in wd.procs {
			if mp.proc.is_alive() {
				mp.proc.signal_kill()
				mp.proc.wait()
				mp.proc.close()
				total_killed++
			}
			if mp.conf_path != '' {
				os.rm(mp.conf_path) or {}
			}
		}
		wd.mu.unlock()
		if total_killed > 0 {
			println('\n[*] Shut down complete. Terminated ${total_killed} background task(s).')
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
		mut hedge_delay_ms := 0
		mut rrr_entries := [][]string{}
		mut i := 0

		for i < box_args.len {
			arg := box_args[i]
			
			if arg == '--hedge' && i + 1 < box_args.len {
				hedge_delay_ms = box_args[i + 1].int()
				if hedge_delay_ms < 50 {
					hedge_delay_ms = 250
				}
				i += 2
				continue
			} else if arg == '-v' {
				verbose = true
				i++
				continue
			} else if arg.starts_with('-r?') && arg.ends_with('?') {
				raw_cmds := arg[3..arg.len - 1]
				cmds := raw_cmds.split(',')
				for c in cmds {
					cmd_clean := c.trim_space()
					if cmd_clean == '' {
						continue
					}
					parts := cmd_clean.split(' ').filter(it != '')
					if parts.len > 0 {
						mut p := os.new_process(parts[0])
						if parts.len > 1 {
							p.set_args(parts[1..])
						}
						p.run()
						child_procs << p
						println('[*] [Global] Started background task: ${parts[0]} (PID: ${p.pid})')
					}
				}
				i++
				continue
			} else if arg.starts_with('-rrr?') && arg.ends_with('?') {
				raw_content := arg[5..arg.len - 1]
				comma_pos := raw_content.last_index(',') or { -1 }
				if comma_pos <= 0 {
					eprintln('[!] -rrr syntax: -rrr?command,endpoint_addr:port?')
					exit(1)
				}
				rrr_cmd := raw_content[..comma_pos].trim_space()
				rrr_ep := raw_content[comma_pos + 1..].trim_space()
				if rrr_cmd == '' || rrr_ep == '' {
					eprintln('[!] -rrr: empty command or endpoint')
					exit(1)
				}
				rrr_entries << [rrr_cmd, rrr_ep]
				i++
				continue
			} else if arg.starts_with('-rr?') && arg.ends_with('?') {
				raw_cmds := arg[4..arg.len - 1]
				parts := raw_cmds.split(',')
				if parts.len % 2 != 0 {
					eprintln('[!] -rr syntax error: must be pairs of (command, endpoint)')
					exit(1)
				}
				wd.mu.@lock()
				for j := 0; j < parts.len; j += 2 {
					cmd_clean := parts[j].trim_space()
					endpoint := parts[j + 1].trim_space()
					if cmd_clean == '' || endpoint == '' {
						continue
					}
					mut check_node := parse_uri(endpoint) or {
						parse_uri('sni://' + endpoint) or {
							eprintln('[!] [Watchdog] Invalid endpoint format: ${endpoint}')
							continue
						}
					}
					cmd_parts := cmd_clean.split(' ').filter(it != '')
					if cmd_parts.len > 0 {
						mut p := os.new_process(cmd_parts[0])
						if cmd_parts.len > 1 {
							p.set_args(cmd_parts[1..])
						}
						p.run()
						wd.procs << ManagedProcess{
							cmd: cmd_parts[0]
							args: cmd_parts[1..]
							check_node: check_node
							conf_path: ''
							proc: p
							last_restart: time.now()
						}
						pname := match check_node.proto {
							.socks5 { 'SOCKS5' }
							.http { 'HTTP' }
							else { 'TCP' }
						}
						println('[*] [Watchdog] Auto-restarting task added: "${cmd_parts[0]}" -> monitoring ${check_node.addr} via ${pname} handshake')
					}
				}
				wd.mu.unlock()
				i++
				continue
			} else if arg == '-l' && i + 1 < box_args.len {
				raw_uri := box_args[i + 1]
				node := parse_uri(raw_uri) or {
					eprintln('[!] [Box ${box_idx + 1}] Listener Error: ${err}')
					exit(1)
				}
				mut existing_idx := -1
				for j in 0 .. listeners.len {
					if listeners[j].addr == node.addr && listeners[j].proto == node.proto {
						existing_idx = j
						break
					}
				}
				if existing_idx >= 0 {
					listeners[existing_idx].is_global = true
				} else {
					listeners << Listener{
						proto: node.proto
						addr: node.addr
						user: node.user
						pass: node.pass
						chain_idxs: []
						is_global: true
					}
				}
				i += 2
			} else if (arg == '-u' || arg == '-i') && i + 1 < box_args.len {
				is_upstream := arg == '-u'
				chain_parts := box_args[i + 1].split('+')
				mut current_paths := [][]Node{}
				current_paths << []Node{}
				for p in chain_parts {
					part := p.trim_space()
					if part == '' {
						continue
					}
					if part.starts_with('-x') {
						name := part[2..].trim_space()
						if name == '' || current_paths[0].len == 0 {
							exit(1)
						}
						if is_snapshot_name(name) {
							if name !in macros {
								macros[name] = [][]Node{}
							}
							for path in current_paths {
								if path.len > 0 {
									macros[name] << path.clone()
								}
							}
						} else {
							node := parse_uri(name) or { eprintln('[!] Error parsing node: ${err}'); exit(1) }
							mut new_chain_idxs := []int{}
							for path in current_paths {
								if path.len > 0 {
									chains << Chain{
										nodes: path.clone()
										alive: true
										global: false
									}
									new_chain_idxs << (chains.len - 1)
								}
							}
							mut existing_idx := -1
							for j in 0 .. listeners.len {
								if listeners[j].addr == node.addr
									&& listeners[j].proto == node.proto {
									existing_idx = j
									break
								}
							}
							if existing_idx >= 0 {
								for cidx in new_chain_idxs {
									if cidx !in listeners[existing_idx].chain_idxs {
										listeners[existing_idx].chain_idxs << cidx
									}
								}
							} else {
								listeners << Listener{
									proto: node.proto
									addr: node.addr
									user: node.user
									pass: node.pass
									chain_idxs: new_chain_idxs
									is_global: false
								}
							}
						}
					} else {
						if is_snapshot_name(part) {
							if part in macros {
								mut next_paths := [][]Node{}
								for path in current_paths {
									for macro_path in macros[part] {
										mut new_path := path.clone()
										for n in macro_path {
											new_path << n
										}
										next_paths << new_path
									}
								}
								current_paths = next_paths.clone()
							} else {
								exit(1)
							}
						} else {
							node := parse_uri(part) or { eprintln('[!] Error parsing node: ${err}'); exit(1) }
							for mut path in current_paths {
								path << node
							}
						}
					}
				}
				if is_upstream {
					for path in current_paths {
						if path.len > 0 {
							chains << Chain{
								nodes: path.clone()
								alive: true
								global: true
							}
						}
					}
				}
				i += 2
			} else if arg == '-o' && i + 1 < box_args.len {
				global_outbound_str = box_args[i + 1]
				i += 2
			} else {
				eprintln('[!] [Box ${box_idx + 1}] Unknown argument: ${box_args[i]}')
				exit(1)
			}
		}

		if global_outbound_str != '' {
			mut out_paths := [][]Node{}
			out_paths << []Node{}
			for p in global_outbound_str.split('+') {
				part := p.trim_space()
				if part == '' {
					continue
				}
				if is_snapshot_name(part) {
					if part in macros {
						mut next_paths := [][]Node{}
						for path in out_paths {
							for macro_path in macros[part] {
								mut np := path.clone()
								for n in macro_path {
									np << n
								}
								next_paths << np
							}
						}
						out_paths = next_paths.clone()
					} else {
						exit(1)
					}
				} else {
					node := parse_uri(part) or { eprintln('[!] Error parsing node: ${err}'); exit(1) }
					for mut path in out_paths {
						path << node
					}
				}
			}
			if out_paths.len > 0 && out_paths[0].len > 0 {
				single_out := out_paths[0]
				for mut c in chains {
					for n in single_out {
						c.nodes << n
					}
				}
			}
		}

		if rrr_entries.len > 0 {
			pc_bin := find_proxychains_bin()
			if pc_bin == '' {
				eprintln('[!] proxychains4 not found! Install: apt install proxychains4')
				eprintln('    -rrr entries will be skipped.')
			} else {
				for rrr_idx, entry in rrr_entries {
					rrr_cmd_str := entry[0]
					rrr_endpoint := entry[1]
					mut ep_addr := rrr_endpoint
					if !ep_addr.contains(':') {
						eprintln('[!] [Box ${box_idx + 1}] -rrr: invalid endpoint (missing port): ${rrr_endpoint}')
						continue
					}
					mut prior := find_prior_nodes(chains, ep_addr)
					if prior.len == 0 {
						for proto_prefix in ['socks5://', 'http://'] {
							ep_node := parse_uri(proto_prefix + rrr_endpoint) or { eprintln('[!] Error parsing node: ${err}'); exit(1) }
							prior = find_prior_nodes(chains, ep_node.addr)
							if prior.len > 0 {
								break
							}
						}
					}
					if prior.len == 0 {
						eprintln('[!] [Box ${box_idx + 1}] -rrr: "${ep_addr}" not found in any chain, or is the first node')
						eprintln('    Available chain nodes:')
						for ci, c in chains {
							mut addrs := []string{}
							for n in c.nodes {
								addrs << n.addr
							}
							eprintln('      Chain ${ci}: ${addrs.join(' -> ')}')
						}
						continue
					}
					conf_path := gen_proxychains_conf(prior, box_idx + 1, rrr_idx)
					if conf_path == '' {
						eprintln('[!] -rrr: failed to write proxychains config')
						continue
					}
					cmd_parts := rrr_cmd_str.split(' ').filter(it != '')
					if cmd_parts.len == 0 {
						continue
					}
					mut pc_args := ['-q', '-f', conf_path]
					for cp in cmd_parts {
						pc_args << cp
					}
					mut p := os.new_process(pc_bin)
					p.set_args(pc_args)
					p.run()
					check_node := parse_uri(rrr_endpoint) or {
						parse_uri('socks5://' + rrr_endpoint) or {
							eprintln('[!] -rrr: cannot parse endpoint for monitoring')
							continue
						}
					}
					wd.mu.@lock()
					wd.procs << ManagedProcess{
						cmd: pc_bin
						args: pc_args.clone()
						check_node: check_node
						conf_path: conf_path
						proc: p
						last_restart: time.now()
					}
					wd.mu.unlock()
					mut chain_desc := []string{}
					for n in prior {
						pt := match n.proto {
							.socks5 { 'socks5' }
							.http { 'http' }
							else { 'tcp' }
						}
						chain_desc << '${pt}://${n.addr}'
					}
					println('[*] [Box ${box_idx + 1}] -rrr: "${rrr_cmd_str}" tunneled via:')
					println('    ${chain_desc.join(' -> ')} -> ${ep_addr}')
					println('    PID: ${p.pid} | proxychains: ${pc_bin} | config: ${conf_path}')
				}
			}
		}

		if listeners.len == 0 {
			eprintln('[!] [Box ${box_idx + 1}] Skipped: No listeners defined.')
			continue
		}

		mut app := &App{
			id: box_idx + 1
			listeners: listeners
			chains: chains
			rr_counter: 0
			udp_port: u32(40000 + (box_idx * 1000))
			verbose: verbose
			dns_sma: u32(0)
			hedge_delay: time.Duration(hedge_delay_ms * time.millisecond)
		}
		apps << app
		println('[*] [Box ${app.id}] Parsed successfully. ${listeners.len} listener(s), ${chains.len} routing chain(s).')
		if verbose {
			println('    -> VERBOSE mode enabled for this Box.')
		}
		if hedge_delay_ms > 0 {
			println('    -> HEDGE MODE: ${hedge_delay_ms}ms delay')
		}
	}

	if apps.len == 0 {
		eprintln('[!] No valid boxes found to start.')
		return
	}
	println('[*] Starting ${apps.len} independent Box(es)...')

	spawn watchdog_loop(mut wd)
	
	for mut app in apps {
		app.sock_mon = SocketMonitor{
			max_allowed: 1000
			warning_threshold: 800
			last_warning: time.now()
		}
		
		app.req_queue = RequestQueue{
			max_size: 1000
			max_wait: 60 * time.second
		}
		
		spawn health_checker(mut app)
		spawn queue_processor(mut app)
		spawn socket_janitor(mut app)
		spawn emergency_monitor(mut app)
		
		for li in 0 .. app.listeners.len {
			spawn start_listener(mut app, li)
		}
	}
	for {
		time.sleep(1 * time.hour)
	}
}

fn apply_action(mut buf []u8, nr int, start int, hx []u8) {
	for i in 0 .. hx.len {
		if start + i < nr {
			buf[start + i] = hx[i]
		}
	}
}

fn apply_script(mut buf []u8, nr int, script []Rule, verbose bool) {
	for rule in script {
		if rule.mode == 'l3' || rule.mode == 'l3r' {
			continue
		}
		if rule.mode == 'aob' {
			mut indices := []int{}
			pat_len := rule.aob_pattern.len
			if pat_len <= nr {
				for i := 0; i <= nr - pat_len; i++ {
					mut matched := true
					for j := 0; j < pat_len; j++ {
						if !rule.aob_pattern[j].wildcard && buf[i + j] != rule.aob_pattern[j].val {
							matched = false
							break
						}
					}
					if matched {
						indices << i
					}
				}
			}
			for idx in indices {
				if verbose {
					println('  [+] AOB MATCHED at relative offset ${idx}! Applying action.')
				}
				apply_action(mut buf, nr, idx + rule.action_start, rule.action_hex)
			}
		} else {
			if rule.has_cond {
				c_len := rule.cond_hex.len
				if rule.cond_start >= 0 && rule.cond_start + c_len <= nr {
					mut matched := true
					for i in 0 .. c_len {
						if buf[rule.cond_start + i] != rule.cond_hex[i] {
							matched = false
							break
						}
					}
					if matched {
						if verbose {
							println('  [+] IF MATCHED at offset ${rule.cond_start}. Applying action.')
						}
						apply_action(mut buf, nr, rule.action_start, rule.action_hex)
					} else if rule.has_else {
						apply_action(mut buf, nr, rule.else_start, rule.else_hex)
					}
				} else if rule.has_else {
					apply_action(mut buf, nr, rule.else_start, rule.else_hex)
				}
			} else {
				if verbose {
					println('  [+] Unconditional action applied at offset ${rule.action_start}.')
				}
				apply_action(mut buf, nr, rule.action_start, rule.action_hex)
			}
		}
	}
}

fn relay(mut src net.TcpConn, mut dst net.TcpConn, done chan bool, script []Rule, verbose bool, mut app App) {
	mut b := []u8{len: buf_size}
	mut is_first := has_l3r_rules(script)
	
	src_handle := src.sock.handle
	dst_handle := dst.sock.handle
	
	for {
		nr := src.read(mut b) or { break }
		if nr == 0 {
			break
		}
		
		app.mu.@lock()
		if src_handle in app.active_conns {
			if src_managed := app.active_conns[src_handle] {
				mut sm := unsafe { src_managed }
				sm.last_activity = time.now()
			}
		}
		if dst_handle in app.active_conns {
			if dst_managed := app.active_conns[dst_handle] {
				mut dm := unsafe { dst_managed }
				dm.last_activity = time.now()
			}
		}
		app.mu.unlock()
		
		if verbose {
			println('\n[-] Traffic In (${nr} bytes): ${hex.encode(b[..nr])}')
		}
		mut data := b[..nr].clone()
		if script.len > 0 {
			apply_script(mut data, data.len, script, verbose)
			if verbose {
				println('[+] Traffic Out (${data.len} bytes): ${hex.encode(data)}')
			}
		}
		if is_first {
			is_first = false
			if !desync_write(mut dst, data, script, verbose) {
				break
			}
		} else {
			dst.write(data) or { break }
		}
	}
	done <- true
}

fn do_relay(mut a net.TcpConn, mut b net.TcpConn, script []Rule, verbose bool, mut app App) {
	a.set_read_timeout(5 * time.minute)
	b.set_read_timeout(5 * time.minute)
	done := chan bool{cap: 2}
	spawn relay(mut a, mut b, done, script, verbose, mut app)
	spawn relay(mut b, mut a, done, []Rule{}, false, mut app)
	_ = <-done
	app.safe_close(mut a)
	app.safe_close(mut b)
	_ = <-done
}

fn start_listener(mut app App, li int) {
	l := app.listeners[li]
	pname := match l.proto {
		.socks5 { 'SOCKS5' }
		.http { 'HTTP' }
		.sni { 'SNI' }
		.dns { 'DNS' }
	}
	if l.proto == .dns {
		mut listener := net.listen_udp(l.addr) or { return }
		println('[+] [Box ${app.id}] ${pname} on ${l.addr} (UDP)')
		for {
			mut buf := []u8{len: 2048}
			mut n, mut addr := listener.read(mut buf) or { continue }
			if n > 0 {
				spawn handle_dns_request(mut app, mut listener, addr, buf[..n].clone(), l)
			}
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

fn handle_conn(mut app App, mut client net.TcpConn, li int) {
	if !app.register_connection(mut client, 'client') {
		return
	}
	
	defer {
		app.safe_close(mut client)
	}
	
	l := app.listeners[li]
	match l.proto {
		.socks5 { handle_socks5(mut app, mut client, l) }
		.http { handle_http(mut app, mut client, l) }
		.sni { handle_sni(mut app, mut client, l) }
		.dns {}
	}
}

fn handle_dns_request(mut app App, mut listener net.UdpConn, client_addr net.Addr, req []u8, l Listener) {
	if req.len < 12 {
		return
	}
	if app.dns_sma > dns_sma_lim {
		//println("[*] dns_sma is reached the limit")
		return
	}
	mut order := if l.is_global {
		pick_chain_order(mut app)
	} else {
		pick_best_from_list(mut app, l.chain_idxs)
	}
	if order.len == 0 {
		return
	}
	for ci in order {
		app.mu.@lock()
		nodes := app.chains[ci].nodes.clone()
		app.mu.unlock()
		if nodes.len == 0 || nodes[0].proto != .dns {
			continue
		}
		up_addrs := net.resolve_addrs(nodes[0].addr, .ip, .udp) or { continue }
		if up_addrs.len == 0 {
			continue
		}
		mut out_conn := net.listen_udp('0.0.0.0:0') or { continue }
		out_conn.set_read_timeout(100)
		if app.dns_sma > dns_sma_lim { return }
		defer {
			out_conn.close() or {}
			app.dns_sma--
		}
		app.dns_sma++
		if app.dns_sma > dns_sma_lim {
			//out_conn.close() or {}
			return
		}
		if nodes[0].script.len > 0 {
			apply_l3(out_conn.sock.handle, nodes[0].script, app.verbose)
		}
		t0 := time.now()
		out_conn.write_to(up_addrs[0], req) or {
			//out_conn.close() or {}
			app.mu.@lock()
			record_failure(mut app.chains[ci])
			app.mu.unlock()
			continue
		}
		mut resp_buf := []u8{len: 2048}
		rn, _ := out_conn.read(mut resp_buf) or {
			//out_conn.close() or {}
			app.mu.@lock()
			record_failure(mut app.chains[ci])
			app.mu.unlock()
			continue
		}
		if rn > 0 {
			lat := i64(time.now() - t0) / 1000
			app.mu.@lock()
			record_success(mut app.chains[ci], lat)
			app.mu.unlock()
			listener.write_to(client_addr, resp_buf[..rn]) or {}
			//out_conn.close() or {}
			return
		}
	}
}

fn health_checker(mut app App) {
	for {
		for ci in 0 .. app.chains.len {
			t0 := time.now()
			alive := check_chain(app.chains[ci], mut app)
			d := time.now() - t0
			lat_us := i64(d) / 1000
			app.mu.@lock()
			app.chains[ci].alive = alive
			if alive {
				app.chains[ci].latency = lat_us
				if app.chains[ci].consec_fail > 0 {
					app.chains[ci].consec_fail = 0
				}
				if app.chains[ci].ema_lat < 1.0 {
					app.chains[ci].ema_lat = f64(lat_us)
				} else {
					app.chains[ci].ema_lat = app.chains[ci].ema_lat * 0.85 + f64(lat_us) * 0.15
				}
			}
			app.mu.unlock()
		}
		time.sleep(check_interval)
	}
}

fn check_chain(c Chain, mut app App) bool {
	if c.nodes.len == 0 {
		return false
	}
	
	if c.nodes.len == 1 {
		n := c.nodes[0]
		match n.proto {
			.socks5 { return check_socks5_h(n) }
			.http { return check_http_h(n) }
			.sni { return check_tcp_h(n.addr) }
			.dns { return check_dns_h(n) }
		}
	}
	
	mut conn := connect_chain(c.nodes, '1.1.1.1', 443, false, mut app) or {
		return false
	}
	
	app.safe_close(mut conn)
	return true
}

fn check_tcp_h(addr string) bool {
	mut c := net.dial_tcp(addr) or { return false }
	c.close() or {}
	return true
}

fn check_dns_h(n Node) bool {
	mut c := net.listen_udp('0.0.0.0:0') or { return false }
	defer {
		c.close() or {}
	}
	c.set_read_timeout(check_timeout)
	addrs := net.resolve_addrs(n.addr, .ip, .udp) or { return false }
	if addrs.len == 0 {
		return false
	}
	query := [u8(0x12), 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x06, 0x67, 0x6f, 0x6f, 0x67, 0x6c, 0x65, 0x03, 0x63, 0x6f, 0x6d, 0x00, 0x00, 0x01,
		0x00, 0x01]
	c.write_to(addrs[0], query) or { return false }
	mut buf := []u8{len: 512}
	n_read, _ := c.read(mut buf) or { return false }
	return n_read >= 12 && buf[0] == 0x12 && buf[1] == 0x34 && (buf[2] & 0x80) != 0
}

fn check_socks5_h(n Node) bool {
	mut c := net.dial_tcp(n.addr) or { return false }
	defer {
		c.close() or {}
	}
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
	defer {
		c.close() or {}
	}
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

fn pick_chain_order(mut app App) []int {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
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
	mut scores := []f64{len: idxs.len}
	for i, ci in idxs {
		scores[i] = calc_chain_score(app.chains[ci])
	}
	for i in 1 .. idxs.len {
		mut j := i
		for j > 0 && scores[j] > scores[j - 1] {
			tmp_i := idxs[j]
			idxs[j] = idxs[j - 1]
			idxs[j - 1] = tmp_i
			tmp_s := scores[j]
			scores[j] = scores[j - 1]
			scores[j - 1] = tmp_s
			j--
		}
	}
	return idxs
}

fn pick_best_from_list(mut app App, allowed_idxs []int) []int {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	mut alive_idxs := []int{cap: allowed_idxs.len}
	for ci in allowed_idxs {
		if ci < app.chains.len && app.chains[ci].alive {
			alive_idxs << ci
		}
	}
	if alive_idxs.len == 0 {
		return allowed_idxs.clone()
	}
	if alive_idxs.len == 1 {
		return alive_idxs
	}
	mut scores := []f64{len: alive_idxs.len}
	for i, ci in alive_idxs {
		scores[i] = calc_chain_score(app.chains[ci])
	}
	for i in 1 .. alive_idxs.len {
		mut j := i
		for j > 0 && scores[j] > scores[j - 1] {
			tmp_i := alive_idxs[j]
			alive_idxs[j] = alive_idxs[j - 1]
			alive_idxs[j - 1] = tmp_i
			tmp_s := scores[j]
			scores[j] = scores[j - 1]
			scores[j - 1] = tmp_s
			j--
		}
	}
	return alive_idxs
}

fn connect_retry(mut app App, host string, port int, l Listener) !(&net.TcpConn, []Rule) {
	mut order := if l.is_global {
		pick_chain_order(mut app)
	} else {
		pick_best_from_list(mut app, l.chain_idxs)
	}
	if order.len == 0 {
		return error('no chains available')
	}
	for ci in order {
		app.mu.@lock()
		nodes := app.chains[ci].nodes.clone()
		app.mu.unlock()
		t0 := time.now()
		mut conn := connect_chain(nodes, host, port, app.verbose, mut app) or {
			app.mu.@lock()
			record_failure(mut app.chains[ci])
			app.mu.unlock()
			continue
		}
		lat := i64(time.now() - t0) / 1000
		app.mu.@lock()
		record_success(mut app.chains[ci], lat)
		app.mu.unlock()
		return conn, nodes[0].script
	}
	return error('all chains failed')
}

fn connect_chain(chain []Node, host string, port int, verbose bool, mut app App) !&net.TcpConn {
	if chain.len == 0 {
		return error('empty chain')
	}
	
	if !app.sock_mon.can_open() {
		return error('socket limit reached')
	}
	
	mut conn := net.dial_tcp(chain[0].addr) or { 
		return error('dial failed to first node') 
	}
	
	if !app.register_connection(mut conn, 'upstream') {
		return error('socket registration failed')
	}
	
	if chain[0].script.len > 0 {
		apply_l3(conn.sock.handle, chain[0].script, verbose)
	}
	
	for i := 1; i < chain.len; i++ {
		prev_node := chain[i - 1]
		next_node := chain[i]
		
		next_host, next_port_str := parse_host_port(next_node.addr)
		next_port := next_port_str.int()
		if next_port == 0 {
			app.safe_close(mut conn)
			return error('invalid port in chain node: ${next_node.addr}')
		}

		if verbose {
			println('  [Chain] Tunneling through ${prev_node.addr} to reach ${next_node.addr}...')
		}
		
		match prev_node.proto {
			.socks5 {
				do_socks5_hs(mut conn, prev_node, next_host, next_port) or {
					app.safe_close(mut conn)
					return error('chain broken at ${prev_node.addr} -> ${next_node.addr}')
				}
			}
			.http {
				do_http_hs(mut conn, prev_node, next_host, next_port) or {
					app.safe_close(mut conn)
					return error('chain broken at ${prev_node.addr} -> ${next_node.addr}')
				}
			}
			else {
				app.safe_close(mut conn)
				return error('unsupported protocol for chaining at ${prev_node.addr}')
			}
		}
	}
	
	last_node := chain.last()
	
	if verbose {
		println('  [Chain] Final node ${last_node.addr} connecting to target ${host}:${port}...')
	}

	match last_node.proto {
		.socks5 {
			do_socks5_hs(mut conn, last_node, host, port) or {
				app.safe_close(mut conn)
				return err
			}
		}
		.http {
			do_http_hs(mut conn, last_node, host, port) or {
				app.safe_close(mut conn)
				return err
			}
		}
		.sni {}
		.dns {}
	}

	return conn
}

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
		a << u8(0x01)
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
	} else if gr[1] != 0x00 {
		return error('noauth rejected')
	}

	if host.len > 255 {
		return error('host too long')
	}

	mut req := []u8{cap: 7 + host.len}
	req << u8(0x05)
	req << u8(0x01)
	req << u8(0x00)
	req << u8(0x03)
	req << u8(host.len)
	req << host.bytes()
	req << u8((port >> 8) & 0xff)
	req << u8(port & 0xff)
	c.write(req)!

	mut hdr := []u8{len: 4}
	read_full(mut c, mut hdr, 4)!

	if hdr[0] != 0x05 {
		return error('bad version')
	}
	if hdr[1] != 0x00 {
		return error('connect fail')
	}

	match hdr[3] {
		0x01 {
			mut rest := []u8{len: 6} // ipv4(4) + port(2)
			read_full(mut c, mut rest, 6)!
		}
		0x04 {
			mut rest := []u8{len: 18} // ipv6(16) + port(2)
			read_full(mut c, mut rest, 18)!
		}
		0x03 {
			mut lb := []u8{len: 1}
			read_full(mut c, mut lb, 1)!
			ln := int(lb[0])
			mut rest := []u8{len: ln + 2} // domain + port
			read_full(mut c, mut rest, ln + 2)!
		}
		else {
			return error('bad atyp')
		}
	}
}

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
		nr := c.read(mut buf) or { return error('read fail') }
		if nr == 0 {
			return error('closed')
		}
		acc << buf[..nr]
		if acc.len > 8192 {
			return error('resp too large')
		}
		resp_s := acc.bytestr()
		if resp_s.contains('\r\n\r\n') {
			if !resp_s.starts_with('HTTP/1.1 200') && !resp_s.starts_with('HTTP/1.0 200') {
				return error('CONNECT rejected')
			}
			break
		}
	}
}

fn handle_socks5(mut app App, mut client net.TcpConn, l Listener) {
	client.set_read_timeout(30 * time.second)
	client.set_write_timeout(30 * time.second)
	mut greet := []u8{len: 257}
	mut gn := read_full(mut client, mut greet, 2) or { 
		client.close() or {}
		return 
	}
	if greet[0] != 0x05 {
		client.close() or {}
		return
	}
	needed := 2 + int(greet[1])
	if gn < needed {
		for gn < needed {
			n := client.read(mut greet[gn..]) or { 
				client.close() or {}
				return 
			}
			if n == 0 {
				client.close() or {}
				return
			}
			gn += n
		}
	}
	if l.user != '' {
		client.write([u8(0x05), 0x02]) or { 
			client.close() or {}
			return 
		}
		mut auth := []u8{len: 513}
		mut an := read_full(mut client, mut auth, 2) or { 
			client.close() or {}
			return 
		}
		if auth[0] != 0x01 {
			client.write([u8(0x01), 0x01]) or {}
			client.close() or {}
			return
		}
		ulen := int(auth[1])
		if an < 2 + ulen + 1 {
			for an < 2 + ulen + 1 {
				n := client.read(mut auth[an..]) or { 
					client.close() or {}
					return 
				}
				if n == 0 {
					client.close() or {}
					return
				}
				an += n
			}
		}
		plen := int(auth[2 + ulen])
		if an < 2 + ulen + 1 + plen {
			for an < 2 + ulen + 1 + plen {
				n := client.read(mut auth[an..]) or { 
					client.close() or {}
					return 
				}
				if n == 0 {
					client.close() or {}
					return
				}
				an += n
			}
		}
		if auth[2..2 + ulen].bytestr() != l.user
			|| auth[3 + ulen..3 + ulen + plen].bytestr() != l.pass {
			client.write([u8(0x01), 0x01]) or {}
			client.close() or {}
			return
		}
		client.write([u8(0x01), 0x00]) or { 
			client.close() or {}
			return 
		}
	} else {
		client.write([u8(0x05), 0x00]) or { 
			client.close() or {}
			return 
		}
	}
	mut req := []u8{len: 263}
	mut rn := read_full(mut client, mut req, 4) or { 
		client.close() or {}
		return 
	}
	cmd := req[1]
	atyp := req[3]
	mut host := ''
	mut port := 0
	match atyp {
		0x01 {
			if rn < 10 {
				for rn < 10 {
					n := client.read(mut req[rn..]) or { 
						client.close() or {}
						return 
					}
					if n == 0 {
						client.close() or {}
						return
					}
					rn += n
				}
			}
			host = '${req[4]}.${req[5]}.${req[6]}.${req[7]}'
			port = (u16(req[8]) << 8) | u16(req[9])
		}
		0x03 {
			if rn < 5 {
				for rn < 5 {
					n := client.read(mut req[rn..]) or { 
						client.close() or {}
						return 
					}
					if n == 0 {
						client.close() or {}
						return
					}
					rn += n
				}
			}
			dl := int(req[4])
			if rn < 5 + dl + 2 {
				for rn < 5 + dl + 2 {
					n := client.read(mut req[rn..]) or { 
						client.close() or {}
						return 
					}
					if n == 0 {
						client.close() or {}
						return
					}
					rn += n
				}
			}
			host = req[5..5 + dl].bytestr()
			port = (u16(req[5 + dl]) << 8) | u16(req[5 + dl + 1])
		}
		0x04 {
			if rn < 22 {
				for rn < 22 {
					n := client.read(mut req[rn..]) or { 
						client.close() or {}
						return 
					}
					if n == 0 {
						client.close() or {}
						return
					}
					rn += n
				}
			}
			mut hp := []string{}
			for j in 0 .. 8 {
				hp << '${(u16(req[4 + j * 2]) << 8) | u16(req[4 + j * 2 + 1]):x}'
			}
			host = hp.join(':')
			port = (u16(req[20]) << 8) | u16(req[21])
		}
		else { 
			client.close() or {}
			return 
		}
	}
	if cmd == 0x03 {
		handle_udp_associate(mut app, mut client)
		return
	}
	if cmd != 0x01 {
		client.write([u8(0x05), 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]) or {}
		client.close() or {}
		return
	}
	
	mut upstream, script := connect_retry_with_queue(mut app, host, port, l, mut client, []u8{}, 'socks5') or {
		if err.msg().starts_with('queued') {
			return
		}
		client.write([u8(0x05), 0x04, 0x00, 0x01, 0, 0, 0, 0, 0, 0]) or {}
		client.close() or {}
		return
	}
	
	mut ok := []u8{len: 10}
	ok[0] = 0x05
	ok[3] = 0x01
	client.write(ok) or { 
		upstream.close() or {}
		client.close() or {}
		return 
	}
	do_relay(mut client, mut upstream, script, app.verbose, mut app)
}

fn handle_http(mut app App, mut client net.TcpConn, l Listener) {
	client.set_read_timeout(30 * time.second)
	client.set_write_timeout(30 * time.second)
	mut buf := []u8{len: buf_size}
	mut acc := []u8{}
	for {
		nr := client.read(mut buf) or { 
			client.close() or {}
			return 
		}
		if nr == 0 {
			client.close() or {}
			return
		}
		acc << buf[..nr]
		if acc.bytestr().contains('\r\n\r\n') {
			break
		}
		if acc.len > buf_size {
			client.close() or {}
			return
		}
	}
	hdr := acc.bytestr()
	if l.user != '' {
		expected := base64.encode_str('${l.user}:${l.pass}')
		mut authed := false
		for line in hdr.split('\r\n') {
			if line.to_lower().starts_with('proxy-authorization: basic ') {
				if line[27..].trim_space() == expected {
					authed = true
				}
				break
			}
		}
		if !authed {
			client.write('HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="proxy"\r\n\r\n'.bytes()) or {}
			client.close() or {}
			return
		}
	}
	lines := hdr.split('\r\n')
	if lines.len == 0 {
		client.close() or {}
		return
	}
	parts := lines[0].split(' ')
	if parts.len < 3 {
		client.close() or {}
		return
	}
	method := parts[0]
	if method == 'CONNECT' {
		hp := parts[1].split(':')
		mut t_port := 443
		if hp.len > 1 {
			t_port = hp[1].int()
		}
		
		mut upstream, script := connect_retry_with_queue(mut app, hp[0], t_port, l, mut client, []u8{}, 'http') or {
			if err.msg().starts_with('queued') {
				return
			}
			client.write('HTTP/1.1 502 Bad Gateway\r\n\r\n'.bytes()) or {}
			client.close() or {}
			return
		}
		
		client.write('HTTP/1.1 200 Connection Established\r\n\r\n'.bytes()) or { 
			upstream.close() or {}
			client.close() or {}
			return 
		}
		do_relay(mut client, mut upstream, script, app.verbose, mut app)
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
		
		mut upstream, script := connect_retry_with_queue(mut app, t_host, t_port, l, mut client, []u8{}, 'http') or {
			if err.msg().starts_with('queued') {
				return
			}
			client.write('HTTP/1.1 502 Bad Gateway\r\n\r\n'.bytes()) or {}
			client.close() or {}
			return
		}
		
		mut new_hdr := '${method} ${path} ${parts[2]}\r\n'
		for li2 in 1 .. lines.len {
			ln := lines[li2]
			if ln.to_lower().starts_with('proxy-') {
				continue
			}
			new_hdr += '${ln}\r\n'
		}
		upstream.write(new_hdr.bytes()) or { 
			upstream.close() or {}
			client.close() or {}
			return 
		}
		hdr_end := hdr.index('\r\n\r\n') or { 
			upstream.close() or {}
			client.close() or {}
			return 
		}
		if hdr_end + 4 < acc.len {
			upstream.write(acc[hdr_end + 4..]) or { 
				upstream.close() or {}
				client.close() or {}
				return 
			}
		}
		do_relay(mut client, mut upstream, script, app.verbose, mut app)
	}
}

fn handle_sni(mut app App, mut client net.TcpConn, l Listener) {
	client.set_read_timeout(30 * time.second)
	mut buf := []u8{len: buf_size}
	nr := client.read(mut buf) or { 
		client.close() or {}
		return 
	}
	if nr == 0 {
		client.close() or {}
		return
	}
	initial := buf[..nr].clone()
	hostname := extract_sni(initial)
	if hostname == '' {
		client.close() or {}
		return
	}
	
	mut upstream, script := connect_retry_with_queue(mut app, hostname, 443, l, mut client, initial, 'sni') or { 
		if err.msg().starts_with('queued') {
			return
		}
		client.close() or {}
		return 
	}
	
	mut payload := initial.clone()
	if script.len > 0 {
		apply_script(mut payload, payload.len, script, app.verbose)
	}
	if has_l3r_rules(script) {
		if !desync_write(mut upstream, payload, script, app.verbose) {
			upstream.close() or {}
			client.close() or {}
			return
		}
	} else {
		upstream.write(payload) or { 
			upstream.close() or {}
			client.close() or {}
			return 
		}
	}
	do_relay(mut client, mut upstream, []Rule{}, app.verbose, mut app)
}

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

fn read_full(mut c net.TcpConn, mut buf []u8, min int) !int {
	if min > buf.len {
		return error('min exceeds buffer')
	}
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

fn handle_udp_associate(mut app App, mut client net.TcpConn) {
	app.mu.@lock()
	port := int(app.udp_port)
	app.udp_port++
	if app.udp_port > 50000 {
		app.udp_port = 40000
	}
	app.mu.unlock()
	mut relay_conn := net.listen_udp('0.0.0.0:${port}') or {
		client.write([u8(0x05), 0x01, 0, 0, 0, 0, 0, 0, 0, 0]) or {}
		return
	}
	mut out := net.listen_udp('0.0.0.0:0') or {
		relay_conn.close() or {}
		client.write([u8(0x05), 0x01, 0, 0, 0, 0, 0, 0, 0, 0]) or {}
		return
	}
	mut resp := []u8{len: 10}
	resp[0] = 0x05
	resp[3] = 0x01
	resp[8] = u8(u32(port) >> 8)
	resp[9] = u8(u32(port) & 0xff)
	client.write(resp) or {
		relay_conn.close() or {}
		out.close() or {}
		return
	}
	spawn tcp_udp_monitor(mut client, mut relay_conn, mut out)
	relay_conn.set_read_timeout(2 * time.minute)
	out.set_read_timeout(10 * time.second)
	mut buf := []u8{len: buf_size}
	mut rbuf := []u8{len: buf_size}
	for {
		n, from := relay_conn.read(mut buf) or { break }
		if n < 7 || buf[2] != 0x00 {
			continue
		}
		hdr_len, dest_host, dest_port := parse_udp_socks(buf[..n].clone()) or { continue }
		addrs := net.resolve_addrs('${dest_host}:${dest_port}', .ip, .udp) or { continue }
		if addrs.len == 0 {
			continue
		}
		out.write_to(addrs[0], buf[hdr_len..n].clone()) or { continue }
		rn, _ := out.read(mut rbuf) or { continue }
		if rn == 0 {
			continue
		}
		mut pkt := []u8{cap: hdr_len + rn}
		pkt << buf[..hdr_len].clone()
		pkt << rbuf[..rn].clone()
		relay_conn.write_to(from, pkt) or { continue }
	}
}

fn parse_udp_socks(d []u8) !(int, string, int) {
	if d.len < 7 {
		return error('short')
	}
	match d[3] {
		0x01 {
			if d.len < 10 {
				return error('s')
			}
			return 10, '${d[4]}.${d[5]}.${d[6]}.${d[7]}', int((u32(d[8]) << 8) | u32(d[9]))
		}
		0x03 {
			dl := int(d[4])
			if d.len < 5 + dl + 2 {
				return error('s')
			}
			return 5 + dl + 2, d[5..5 + dl].bytestr(), int((u32(d[5 + dl]) << 8) | u32(d[5 + dl + 1]))
		}
		0x04 {
			if d.len < 22 {
				return error('s')
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

fn tcp_udp_monitor(mut client net.TcpConn, mut relay_conn net.UdpConn, mut out net.UdpConn) {
	mut b := []u8{len: 1}
	for {
		client.read(mut b) or { break }
	}
	relay_conn.close() or {}
	out.close() or {}
}

fn watchdog_loop(mut wd Watchdog) {
	for {
		time.sleep(15 * time.second)
		wd.mu.@lock()
		count := wd.procs.len
		wd.mu.unlock()
		for idx in 0 .. count {
			wd.mu.@lock()
			if idx >= wd.procs.len {
				wd.mu.unlock()
				break
			}
			cmd := wd.procs[idx].cmd
			args := wd.procs[idx].args.clone()
			check_node := wd.procs[idx].check_node
			last_restart := wd.procs[idx].last_restart
			rc := wd.procs[idx].restart_count
			proc_alive := wd.procs[idx].proc.is_alive()
			conf_path := wd.procs[idx].conf_path
			wd.mu.unlock()

			mut cooldown_secs := i64(30)
			for _ in 0 .. rc {
				cooldown_secs *= 2
				if cooldown_secs > 300 {
					cooldown_secs = 300
					break
				}
			}
			if time.now() - last_restart < cooldown_secs * time.second {
				continue
			}

			mut alive := true
			if !proc_alive {
				alive = false
			} else {
				temp_chain := Chain{
					nodes: [check_node]
					alive: true
				}
				if temp_chain.nodes.len > 0 {
					n := temp_chain.nodes[0]
					match n.proto {
						.socks5 { alive = check_socks5_h(n) }
						.http { alive = check_http_h(n) }
						.sni { alive = check_tcp_h(n.addr) }
						.dns { alive = check_dns_h(n) }
					}
				} else {
					alive = false
				}
			}

			if alive {
				if rc > 0 {
					wd.mu.@lock()
					if idx < wd.procs.len {
						wd.procs[idx].restart_count = 0
					}
					wd.mu.unlock()
				}
				continue
			}

			wd.mu.@lock()
			if idx >= wd.procs.len {
				wd.mu.unlock()
				break
			}
			new_rc := wd.procs[idx].restart_count + 1
			pname := match check_node.proto {
				.socks5 { 'SOCKS5' }
				.http { 'HTTP' }
				.dns { 'DNS' }
				.sni { 'TCP' }
			}
			if proc_alive {
				println('\n[!] [Watchdog] FREEZE DETECTED: "${cmd}" alive but ${pname} handshake failed at ${check_node.addr} (restart #${new_rc})')
			} else {
				println('\n[!] [Watchdog] CRASH DETECTED: "${cmd}" is dead (restart #${new_rc})')
			}
			if wd.procs[idx].proc.is_alive() {
				wd.procs[idx].proc.signal_kill()
			}
			wd.procs[idx].proc.wait()
			wd.procs[idx].proc.close()

			mut new_p := os.new_process(cmd)
			new_args := args.clone()
			if new_args.len > 0 {
				new_p.set_args(new_args)
			}
			new_p.run()
			wd.procs[idx].proc = new_p
			wd.procs[idx].last_restart = time.now()
			wd.procs[idx].restart_count = new_rc

			mut next_cd := i64(30)
			for _ in 0 .. new_rc {
				next_cd *= 2
				if next_cd > 120 {
					next_cd = 120
					break
				}
			}
			if conf_path != '' {
				println('    -> Restarted via proxychains (PID: ${new_p.pid}). Next check in ${next_cd}s.')
			} else {
				println('    -> Restarted (PID: ${new_p.pid}). Next check in ${next_cd}s.')
			}
			if new_rc >= 5 {
				println('    [!] WARNING: "${cmd}" restarted ${new_rc} times!')
			}
			wd.mu.unlock()
		}
	}
}

fn check_raw_socket_cap() {
	$if !windows {
		test_fd := unsafe { C.socket(net.AddrFamily(2), net.SocketType(3), 255) }
		if test_fd < 0 {
			eprintln('[!] WARNING: Cannot create raw sockets. L3R rules (fake/rst/disorder) will NOT work!')
			eprintln('    Fix: run as root, or: sudo setcap cap_net_raw,cap_net_admin+ep <binary>')
		} else {
			C.close(test_fd)
			mut one := int(1)
			dummy_fd := unsafe { C.socket(net.AddrFamily(2), net.SocketType(1), 6) }
			if dummy_fd >= 0 {
				res := C.setsockopt(dummy_fd, 6, 19, &one, u32(4))
				C.close(dummy_fd)
				if res != 0 {
					eprintln('[!] WARNING: TCP_REPAIR unavailable. fake/rst/disorder seq numbers will be wrong!')
					eprintln('    Fix: sudo setcap cap_net_raw,cap_net_admin+ep <binary>')
				} else {
					println('[*] Raw socket + TCP_REPAIR: OK')
				}
			}
		}
	}
}

fn parse_spoof_ip(val string) []u8 {
	clean := val.trim_space()
	if clean == 'random' || clean == 'rand' {
		t := u64(time.now().unix_milli())
		return [u8(((t >> 24) % 223) + 1), u8((t >> 16) & 0xFF), u8((t >> 8) & 0xFF),
			u8((t & 0xFE) + 1)]
	}
	parts := clean.split('.')
	if parts.len == 4 {
		return [u8(parts[0].int()), u8(parts[1].int()), u8(parts[2].int()), u8(parts[3].int())]
	}
	return [u8(10), 0, 0, 1]
}

fn rand_ip_id() (u8, u8) {
	t := u64(time.now().unix_milli())
	return u8((t >> 8) & 0xFF), u8(t & 0xFF)
}

fn build_raw_tcp_ex(src_ip []u8, dst_ip []u8, src_port u16, dst_port u16, seq u32, ack u32, flags u8, ttl u8, payload []u8, with_ts bool) []u8 {
	tcp_hdr_len := if with_ts { 32 } else { 20 }
	total := 20 + tcp_hdr_len + payload.len
	mut pkt := []u8{len: total}

	pkt[0] = 0x45
	pkt[2] = u8(total >> 8)
	pkt[3] = u8(total & 0xFF)
	id_hi, id_lo := rand_ip_id()
	pkt[4] = id_hi
	pkt[5] = id_lo
	pkt[6] = 0x40
	pkt[8] = ttl
	pkt[9] = 6
	for i in 0 .. 4 {
		pkt[12 + i] = src_ip[i]
		pkt[16 + i] = dst_ip[i]
	}
	ck := ip_checksum(pkt[..20])
	pkt[10] = u8(ck >> 8)
	pkt[11] = u8(ck & 0xFF)

	t_off := 20
	pkt[t_off] = u8(src_port >> 8)
	pkt[t_off + 1] = u8(src_port & 0xFF)
	pkt[t_off + 2] = u8(dst_port >> 8)
	pkt[t_off + 3] = u8(dst_port & 0xFF)
	pkt[t_off + 4] = u8(seq >> 24)
	pkt[t_off + 5] = u8((seq >> 16) & 0xFF)
	pkt[t_off + 6] = u8((seq >> 8) & 0xFF)
	pkt[t_off + 7] = u8(seq & 0xFF)
	pkt[t_off + 8] = u8(ack >> 24)
	pkt[t_off + 9] = u8((ack >> 16) & 0xFF)
	pkt[t_off + 10] = u8((ack >> 8) & 0xFF)
	pkt[t_off + 11] = u8(ack & 0xFF)

	if with_ts {
		pkt[t_off + 12] = 0x80
		pkt[t_off + 13] = flags
		pkt[t_off + 14] = 0xFF
		pkt[t_off + 15] = 0xFF
		pkt[t_off + 20] = 0x08
		pkt[t_off + 21] = 0x0A
		pkt[t_off + 22] = 0x00
		pkt[t_off + 23] = 0x0A
		ts := u32(time.now().unix_milli() & 0xFFFFFFFF)
		pkt[t_off + 24] = u8(ts >> 24)
		pkt[t_off + 25] = u8((ts >> 16) & 0xFF)
		pkt[t_off + 26] = u8((ts >> 8) & 0xFF)
		pkt[t_off + 27] = u8(ts & 0xFF)
		pkt[t_off + 28] = 0x00
		pkt[t_off + 29] = 0x00
		pkt[t_off + 30] = 0x00
		pkt[t_off + 31] = 0x00
	} else {
		pkt[t_off + 12] = 0x50
		pkt[t_off + 13] = flags
		pkt[t_off + 14] = 0xFF
		pkt[t_off + 15] = 0xFF
	}

	for i in 0 .. payload.len {
		pkt[20 + tcp_hdr_len + i] = payload[i]
	}
	tc := tcp_checksum(pkt[12..16], pkt[16..20], pkt[20..])
	pkt[t_off + 16] = u8(tc >> 8)
	pkt[t_off + 17] = u8(tc & 0xFF)
	return pkt
}

fn build_ip_fragments(full_pkt []u8, frag_size int) [][]u8 {
	if full_pkt.len <= 20 {
		return [full_pkt.clone()]
	}
	ip_payload := full_pkt[20..]
	mut fs := frag_size
	if fs % 8 != 0 {
		fs = (fs / 8) * 8
	}
	if fs < 8 {
		fs = 8
	}
	mut fragments := [][]u8{}
	mut offset := 0
	for offset < ip_payload.len {
		mut end := offset + fs
		is_last := end >= ip_payload.len
		if is_last {
			end = ip_payload.len
		}
		chunk := ip_payload[offset..end]
		total_len := 20 + chunk.len
		mut frag := []u8{len: total_len}
		for i in 0 .. 20 {
			frag[i] = full_pkt[i]
		}
		frag[2] = u8(total_len >> 8)
		frag[3] = u8(total_len & 0xFF)
		frag_off_units := u16(offset / 8)
		if is_last {
			frag[6] = u8(frag_off_units >> 8)
			frag[7] = u8(frag_off_units & 0xFF)
		} else {
			frag[6] = u8(0x20 | u8(frag_off_units >> 8))
			frag[7] = u8(frag_off_units & 0xFF)
		}
		for i in 0 .. chunk.len {
			frag[20 + i] = chunk[i]
		}
		frag[10] = 0
		frag[11] = 0
		ck := ip_checksum(frag[..20])
		frag[10] = u8(ck >> 8)
		frag[11] = u8(ck & 0xFF)
		fragments << frag
		offset += fs
	}
	return fragments
}

fn build_reversed_fragments(full_pkt []u8, frag_size int) [][]u8 {
	frags := build_ip_fragments(full_pkt, frag_size)
	mut reversed := [][]u8{cap: frags.len}
	for i := frags.len - 1; i >= 0; i-- {
		reversed << frags[i]
	}
	return reversed
}

fn gen_fake_payload(data_len int, seed int) []u8 {
	mut payload := []u8{len: data_len}
	for i in 0 .. data_len {
		payload[i] = u8((0x41 + ((i + seed) % 26)))
	}
	return payload
}

fn build_raw_udp(src_ip []u8, dst_ip []u8, src_port u16, dst_port u16, ttl u8, payload []u8) []u8 {
	assert src_ip.len == 4
	assert dst_ip.len == 4

	udp_len := 8 + payload.len
	total_len := 20 + udp_len

	mut pkt := []u8{len: total_len}

	// IPv4 header
	pkt[0] = 0x45
	pkt[1] = 0x00
	pkt[2] = u8((total_len >> 8) & 0xff)
	pkt[3] = u8(total_len & 0xff)
	pkt[4] = 0xDE
	pkt[5] = 0xAD
	pkt[6] = 0x40
	pkt[7] = 0x00
	pkt[8] = ttl
	pkt[9] = 17 // UDP

	for i in 0 .. 4 {
		pkt[12 + i] = src_ip[i]
		pkt[16 + i] = dst_ip[i]
	}

	ip_ck := ip_checksum(pkt[..20])
	pkt[10] = u8((ip_ck >> 8) & 0xff)
	pkt[11] = u8(ip_ck & 0xff)

	// UDP header
	pkt[20] = u8((src_port >> 8) & 0xff)
	pkt[21] = u8(src_port & 0xff)
	pkt[22] = u8((dst_port >> 8) & 0xff)
	pkt[23] = u8(dst_port & 0xff)
	pkt[24] = u8((udp_len >> 8) & 0xff)
	pkt[25] = u8(udp_len & 0xff)
	pkt[26] = 0
	pkt[27] = 0

	for i in 0 .. payload.len {
		pkt[28 + i] = payload[i]
	}

	udp_ck := udp_checksum(src_ip, dst_ip, pkt[20..])
	pkt[26] = u8((udp_ck >> 8) & 0xff)
	pkt[27] = u8(udp_ck & 0xff)

	return pkt
}

fn udp_checksum(src_ip []u8, dst_ip []u8, udp_packet []u8) u16 {
	assert src_ip.len == 4
	assert dst_ip.len == 4
	mut sum := u32(0)
	sum += (u32(src_ip[0]) << 8) | u32(src_ip[1])
	sum += (u32(src_ip[2]) << 8) | u32(src_ip[3])
	sum += (u32(dst_ip[0]) << 8) | u32(dst_ip[1])
	sum += (u32(dst_ip[2]) << 8) | u32(dst_ip[3])
	sum += 0x0011 // zero + protocol(17)
	sum += u32(udp_packet.len)
	mut i := 0
	for i + 1 < udp_packet.len {
		sum += (u32(udp_packet[i]) << 8) | u32(udp_packet[i + 1])
		i += 2
	}
	if i < udp_packet.len {
		sum += u32(udp_packet[i]) << 8
	}

	for (sum >> 16) != 0 {
		sum = (sum & 0xffff) + (sum >> 16)
	}

	mut ans := u16(~sum & 0xffff)
	if ans == 0 {
		ans = 0xffff
	}
	return ans
}

fn (mut app App) enqueue_request(mut client net.TcpConn, host string, port int, data []u8, l Listener, req_type string) bool {
	app.req_queue.mu.@lock()
	defer { app.req_queue.mu.unlock() }
	
	if app.req_queue.queue.len >= app.req_queue.max_size {
		mut oldest_idx := -1
		mut oldest_time := time.now()
		for i, req in app.req_queue.queue {
			if req.queued_at < oldest_time {
				oldest_time = req.queued_at
				oldest_idx = i
			}
		}
		if oldest_idx >= 0 {
			app.req_queue.queue[oldest_idx].client.close() or {}
			app.req_queue.queue.delete(oldest_idx)
			if app.verbose {
				println('[!] [Box ${app.id}] Queue full - dropped oldest request')
			}
		}
	}
	
	app.req_queue.queue << PendingRequest{
		client: client
		host: host
		port: port
		data: data.clone()
		listener: l
		attempts: 0
		queued_at: time.now()
		req_type: req_type
	}
	
	if app.verbose {
		println('[*] [Box ${app.id}] Request queued: ${host}:${port} [${req_type}] (queue: ${app.req_queue.queue.len})')
	}
	
	return true
}

fn queue_processor(mut app App) {
	for {
		time.sleep(300 * time.millisecond)
		
		app.req_queue.mu.@lock()
		queue_size := app.req_queue.queue.len
		app.req_queue.mu.unlock()
		
		if queue_size == 0 {
			app.mu.@lock()
			if app.freeze_mode {
				app.freeze_mode = false
				if app.verbose {
					println('[*] [Box ${app.id}] Exiting freeze mode - connections restored')
				}
			}
			app.mu.unlock()
			continue
		}
		
		app.mu.@lock()
		mut has_alive := false
		for c in app.chains {
			if c.alive {
				has_alive = true
				break
			}
		}
		
		if !has_alive {
			if !app.freeze_mode {
				app.freeze_mode = true
				println('[!] [Box ${app.id}] FREEZE MODE: All chains dead - holding ${queue_size} requests')
			}
			app.mu.unlock()
			continue
		}
		
		if app.freeze_mode {
			app.freeze_mode = false
			println('[*] [Box ${app.id}] ✓ Unfreezing - processing ${queue_size} queued requests')
		}
		app.mu.unlock()
		
		app.req_queue.mu.@lock()
		if app.req_queue.queue.len == 0 {
			app.req_queue.mu.unlock()
			continue
		}
		
		mut req := app.req_queue.queue[0]
		app.req_queue.queue.delete(0)
		app.req_queue.mu.unlock()
		
		if time.now() - req.queued_at > app.req_queue.max_wait {
			if app.verbose {
				println('[!] [Box ${app.id}] Request timeout: ${req.host}:${req.port} (waited ${time.now() - req.queued_at})')
			}
			req.client.close() or {}
			continue
		}
		
		req.attempts++
		mut upstream, script := connect_retry(mut app, req.host, req.port, req.listener) or {
			if req.attempts < 15 {
				app.req_queue.mu.@lock()
				app.req_queue.queue << req
				app.req_queue.mu.unlock()
				
				if app.verbose {
					println('[!] [Box ${app.id}] Re-queuing: ${req.host}:${req.port} (attempt ${req.attempts}/${15})')
				}
			} else {
				if app.verbose {
					println('[!] [Box ${app.id}] ✗ Giving up: ${req.host}:${req.port} after ${req.attempts} attempts')
				}
				req.client.close() or {}
			}
			continue
		}
		
		if app.verbose {
			println('[+] [Box ${app.id}] ✓ Connected queued request: ${req.host}:${req.port} (attempt ${req.attempts}, waited ${time.now() - req.queued_at})')
		}
		
		match req.req_type {
			'socks5' {
				mut ok := []u8{len: 10}
				ok[0] = 0x05
				ok[3] = 0x01
				req.client.write(ok) or {
					upstream.close() or {}
					req.client.close() or {}
					continue
				}
			}
			'http' {
				req.client.write('HTTP/1.1 200 Connection Established\r\n\r\n'.bytes()) or {
					upstream.close() or {}
					req.client.close() or {}
					continue
				}
			}
			'sni' {
				if req.data.len > 0 {
					mut payload := req.data.clone()
					if script.len > 0 {
						apply_script(mut payload, payload.len, script, app.verbose)
					}
					if has_l3r_rules(script) {
						if !desync_write(mut upstream, payload, script, app.verbose) {
							upstream.close() or {}
							req.client.close() or {}
							continue
						}
					} else {
						upstream.write(payload) or {
							upstream.close() or {}
							req.client.close() or {}
							continue
						}
					}
				}
			}
			else {}
		}
		
		spawn do_relay(mut req.client, mut upstream, script, app.verbose, mut app)
	}
}

fn connect_retry_with_queue(mut app App, host string, port int, l Listener, mut client net.TcpConn, initial_data []u8, req_type string) !(&net.TcpConn, []Rule) {
	mut order := if l.is_global {
		pick_chain_order(mut app)
	} else {
		pick_best_from_list(mut app, l.chain_idxs)
	}
	
	if order.len == 0 {
		app.enqueue_request(mut client, host, port, initial_data, l, req_type)
		return error('queued_no_chains')
	}
	
	if app.hedge_delay == 0 {
		mut all_failed := true
		
				for ci in order {
			app.mu.@lock()
			nodes := app.chains[ci].nodes.clone()
			is_alive := app.chains[ci].alive
			app.mu.unlock()
			
			if !is_alive {
				continue
			}
			
			t0 := time.now()
			mut conn := connect_chain(nodes, host, port, app.verbose, mut app) or {
				app.mu.@lock()
				record_failure(mut app.chains[ci])
				app.mu.unlock()
				continue
			}
			
			all_failed = false
			lat := i64(time.now() - t0) / 1000
			app.mu.@lock()
			record_success(mut app.chains[ci], lat)
			app.mu.unlock()
			
			return conn, nodes[0].script
		}
		
		if all_failed {
			app.enqueue_request(mut client, host, port, initial_data, l, req_type)
			return error('queued_all_failed')
		}
		
		return error('connection_failed')
	}
	
	
	mut hedge_count := if order.len > 3 { 3 } else { order.len }
	result_chan := chan HedgeResult{cap: hedge_count}
	
	spawn hedge_connect(mut app, order[0], host, port, result_chan, 0)
	
	if app.verbose {
		println('[HEDGE] Starting chain #${order[0]} immediately')
	}
	
	for i in 1 .. hedge_count {
		ci := order[i]
		delay := app.hedge_delay * i
		spawn hedge_connect(mut app, ci, host, port, result_chan, delay)
		
		if app.verbose {
			println('[HEDGE] Scheduled chain #${ci} after ${delay}')
		}
	}
	
	mut received := 0
	mut first_success := true
	mut winners := []int{cap: hedge_count}
	
	for received < hedge_count {
		mut result := <-result_chan
		received++
		
		if result.success && first_success {
			first_success = false
			
			app.mu.@lock()
			record_success(mut app.chains[result.chain_idx], result.latency)
			app.mu.unlock()
			
			if app.verbose {
				println('[HEDGE] ✓ Winner: Chain #${result.chain_idx} (${result.latency}μs, ${received}/${hedge_count} started)')
			}
			return result.conn, result.script
		}
		if result.success {
			winners << result.chain_idx
			result.conn.close() or {}
			
			if app.verbose {
				println('[HEDGE] Late winner chain #${result.chain_idx} closed (${result.latency}μs)')
			}
		}
	}
	
	if app.verbose {
		println('[HEDGE] ✗ All ${hedge_count} chains failed')
	}
	
	app.enqueue_request(mut client, host, port, initial_data, l, req_type)
	return error('queued_hedge_failed')
}