import net
import os
import time
import flag
import hash.crc32
import encoding.binary
import encoding.base64

const sync_magic_1 = u8(0xDE)
const sync_magic_2 = u8(0xAD)
const header_len   = 7
const crc_len      = 4

const cmd_connect     = u8(0x01)
const cmd_data        = u8(0x02)
const cmd_connect_ok  = u8(0x03)
const cmd_connect_err = u8(0x04)

struct Config {
	mode        string
	listen_addr string
	adapter_cmd string
	chunk_size  int
	poll_delay  int
	verbose     bool
}

struct FrameData {
	cmd     u8
	conn_id u8
	payload []u8
}

struct AppState {
mut:
	next_id      u8 = 1
	conns        map[u8]&net.TcpConn
	conn_ready   map[u8]bool
	conn_failed  map[u8]bool
	seq_out      u8
	byte_pool    []u8
}

fn read_exact(mut conn net.TcpConn, n int) ![]u8 {
	mut buf := []u8{len: n}
	mut total := 0
	for total < n {
		nr := conn.read(mut buf[total..]) or { return error('read failed') }
		if nr == 0 { return error('eof') }
		total += nr
	}
	return buf
}

fn build_frame(cmd u8, conn_id u8, payload []u8, shared state AppState) []u8 {
	mut seq := u8(0)
	lock state {
		seq = state.seq_out
		state.seq_out++
	}
	mut frame := []u8{cap: header_len + payload.len + crc_len}
	frame << sync_magic_1
	frame << sync_magic_2
	frame << cmd
	frame << conn_id
	frame << seq
	mut len_bytes := []u8{len: 2}
	binary.big_endian_put_u16(mut len_bytes, u16(payload.len))
	frame << len_bytes[0]
	frame << len_bytes[1]
	for b in payload { frame << b }
	checksum := crc32.sum(frame)
	mut crc_bytes := []u8{len: 4}
	binary.big_endian_put_u32(mut crc_bytes, checksum)
	for b in crc_bytes { frame << b }
	return frame
}

fn extract_valid_frames(cfg Config, shared state AppState) []FrameData {
	mut valid_frames := []FrameData{}
	lock state {
		for state.byte_pool.len >= header_len + crc_len {
			if state.byte_pool[0] != sync_magic_1 || state.byte_pool[1] != sync_magic_2 {
				state.byte_pool.delete(0)
				continue
			}
			payload_len := int(binary.big_endian_u16(state.byte_pool[5..7]))
			total_frame_len := header_len + payload_len + crc_len
			if state.byte_pool.len < total_frame_len { break }
			frame_without_crc := state.byte_pool[..total_frame_len - crc_len]
			expected_crc := crc32.sum(frame_without_crc)
			received_crc := binary.big_endian_u32(state.byte_pool[total_frame_len - crc_len..total_frame_len])
			if expected_crc == received_crc {
				cmd := state.byte_pool[2]
				conn_id := state.byte_pool[3]
				payload := state.byte_pool[header_len..header_len + payload_len].clone()
				valid_frames << FrameData{cmd: cmd, conn_id: conn_id, payload: payload}
				if cfg.verbose { println('[+] Valid Frame RX -> CMD: ${cmd}, ID: ${conn_id}, LEN: ${payload.len}') }
				state.byte_pool.delete_many(0, total_frame_len)
			} else {
				state.byte_pool.delete(0)
			}
		}
	}
	return valid_frames
}

fn execute_tx(cfg Config, data []u8, shared state AppState) {
	b64_str := base64.encode(data)
	cmd := '${cfg.adapter_cmd} tx ${b64_str}'
	lock state {
		res := os.execute(cmd)
		if res.exit_code != 0 && cfg.verbose { eprintln('[!] TX Failed: ${res.output}') }
	}
}

fn execute_rx(cfg Config, shared state AppState) []u8 {
	cmd := '${cfg.adapter_cmd} rx'
	mut res := os.Result{}
	lock state {
		res = os.execute(cmd)
	}
	mut all_bytes := []u8{}
	if res.exit_code == 0 && res.output.trim_space() != '' {
		lines := res.output.trim_space().split('\n')
		for line in lines {
			if line.trim_space() != '' {
				decoded := base64.decode(line.trim_space())
				for b in decoded { all_bytes << b }
			}
		}
	}
	return all_bytes
}

fn client_worker(cfg Config, mut client net.TcpConn, shared state AppState) {
	client.set_read_timeout(5 * time.minute)
	client.set_write_timeout(5 * time.minute)
	greet := read_exact(mut client, 2) or { return }
	if greet[0] != 0x05 { return }
	nmethods := int(greet[1])
	_ = read_exact(mut client, nmethods) or { return }
	client.write([u8(0x05), 0x00]) or { return }
	req_hdr := read_exact(mut client, 4) or { return }
	if req_hdr[1] != 0x01 { return }
	atyp := req_hdr[3]
	mut host := ''
	mut port := u16(0)
	if atyp == 0x01 {
		ip_port := read_exact(mut client, 6) or { return }
		host = '${ip_port[0]}.${ip_port[1]}.${ip_port[2]}.${ip_port[3]}'
		port = (u16(ip_port[4]) << 8) | u16(ip_port[5])
	} else if atyp == 0x03 {
		dl_buf := read_exact(mut client, 1) or { return }
		dl := int(dl_buf[0])
		dom_port := read_exact(mut client, dl + 2) or { return }
		host = dom_port[..dl].bytestr()
		port = (u16(dom_port[dl]) << 8) | u16(dom_port[dl+1])
	} else {
		return
	}
	mut conn_id := u8(0)
	lock state {
		conn_id = state.next_id
		state.next_id++
		state.conns[conn_id] = client
		state.conn_ready[conn_id] = false
		state.conn_failed[conn_id] = false
	}
	if cfg.verbose { println('[*] Client [ID:${conn_id}] requested: ${host}:${port}') }
	target_str := '${host}:${port}'
	frame := build_frame(cmd_connect, conn_id, target_str.bytes(), shared state)
	execute_tx(cfg, frame, shared state)
	mut is_ready := false
	mut has_failed := false
	for i := 0; i < 300; i++ { 
		lock state {
			is_ready = state.conn_ready[conn_id] or { false }
			has_failed = state.conn_failed[conn_id] or { false }
		}
		if is_ready || has_failed { break }
		time.sleep(100 * time.millisecond)
	}
	if has_failed || !is_ready {
		if cfg.verbose { println('[-] SOCKS [ID:${conn_id}] Upstream connection failed.') }
		client.write([u8(0x05), 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]) or {}
		client.close() or {}
		return
	}
	if cfg.verbose { println('[+] SOCKS [ID:${conn_id}] Upstream OK!') }
	client.write([u8(0x05), 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]) or {}
	mut read_buf := []u8{len: cfg.chunk_size}
	for {
		read_nr := client.read(mut read_buf) or { break }
		if read_nr == 0 { break }
		data_frame := build_frame(cmd_data, conn_id, read_buf[..read_nr].clone(), shared state)
		execute_tx(cfg, data_frame, shared state)
	}
	client.close() or {}
	lock state { state.conns.delete(conn_id) }
	if cfg.verbose { println('[*] Client [ID:${conn_id}] disconnected.') }
}

fn client_rx_loop(cfg Config, shared state AppState) {
	for {
		time.sleep(cfg.poll_delay * time.millisecond)
		raw_bytes := execute_rx(cfg, shared state)
		if raw_bytes.len > 0 {
			lock state {
				for b in raw_bytes { state.byte_pool << b }
			}
		}
		frames := extract_valid_frames(cfg, shared state)
		for frame in frames {
			lock state {
				if frame.cmd == cmd_connect_ok {
					state.conn_ready[frame.conn_id] = true
				} else if frame.cmd == cmd_connect_err {
					state.conn_failed[frame.conn_id] = true
				} else if frame.cmd == cmd_data {
					mut c := state.conns[frame.conn_id] or { continue }
					c.write(frame.payload) or {}
				}
			}
		}
	}
}

fn server_worker(cfg Config, shared state AppState) {
	if cfg.verbose { println('[*] Server listening to Side-Channel...') }
	for {
		time.sleep(cfg.poll_delay * time.millisecond)
		raw_bytes := execute_rx(cfg, shared state)
		if raw_bytes.len > 0 {
			lock state {
				for b in raw_bytes { state.byte_pool << b }
			}
		}
		frames := extract_valid_frames(cfg, shared state)
		for frame in frames {
			if frame.cmd == cmd_connect {
				target := frame.payload.bytestr()
				if cfg.verbose { println('[+] Connect request [ID:${frame.conn_id}] for: ${target}') }
				mut up_conn := net.dial_tcp(target) or {
					if cfg.verbose { eprintln('[-] Dial failed for [ID:${frame.conn_id}]') }
					err_frame := build_frame(cmd_connect_err, frame.conn_id, [], shared state)
					execute_tx(cfg, err_frame, shared state)
					continue
				}
				up_conn.set_read_timeout(5 * time.minute)
				up_conn.set_write_timeout(5 * time.minute)
				lock state { state.conns[frame.conn_id] = up_conn }
				if cfg.verbose { println('[+] Connected upstream for [ID:${frame.conn_id}]') }
				ok_frame := build_frame(cmd_connect_ok, frame.conn_id, [], shared state)
				execute_tx(cfg, ok_frame, shared state)
				spawn server_tx_loop(cfg, frame.conn_id, shared state)
			} else if frame.cmd == cmd_data {
				mut up_conn := &net.TcpConn(unsafe { nil })
				lock state {
					up_conn = state.conns[frame.conn_id] or { unsafe { nil } }
				}
				if up_conn != unsafe { nil } {
					up_conn.write(frame.payload) or {}
				}
			}
		}
	}
}

fn server_tx_loop(cfg Config, conn_id u8, shared state AppState) {
	mut buf := []u8{len: cfg.chunk_size}
	mut upstream := &net.TcpConn(unsafe { nil })
	lock state { 
		upstream = state.conns[conn_id] or { unsafe { nil } }
	}
	if upstream == unsafe { nil } { return }
	for {
		nr := upstream.read(mut buf) or { break }
		if nr == 0 { break }
		frame := build_frame(cmd_data, conn_id, buf[..nr].clone(), shared state)
		execute_tx(cfg, frame, shared state)
	}
	upstream.close() or {}
	lock state { state.conns.delete(conn_id) }
	if cfg.verbose { println('[*] Upstream [ID:${conn_id}] closed.') }
}

fn main() {
	mut fp := flag.new_flag_parser(os.args)
	fp.application('Anyside Protocol')
	mode := fp.string('mode', `m`, 'client', 'client or server')
	addr := fp.string('listen', `l`, '127.0.0.1:1080', 'SOCKS5 Listen')
	cmd  := fp.string('exec', `e`, '', 'Adapter cmd')
	chk  := fp.int('chunk', `c`, 8192, 'Chunk size')
	dly  := fp.int('delay', `d`, 50, 'Polling delay')
	vrb  := fp.bool('verbose', `v`, false, 'Verbose')
	fp.finalize() or { return }
	if cmd == '' { eprintln('Specify adapter with -e'); return }
	cfg := Config{mode, addr, cmd, chk, dly, vrb}
	shared state := AppState{
		conns: map[u8]&net.TcpConn{}
		conn_ready: map[u8]bool{}
		conn_failed: map[u8]bool{}
		byte_pool: []u8{}
		seq_out: 1
	}
	if mode == 'server' {
		server_worker(cfg, shared state)
	} else {
		mut listener := net.listen_tcp(.ip, addr) or { eprintln('Bind error'); return }
		if cfg.verbose { println('[*] Client listening on ${addr}') }
		spawn client_rx_loop(cfg, shared state)
		for {
			mut client := listener.accept() or { continue }
			spawn client_worker(cfg, mut client, shared state)
		}
	}
}