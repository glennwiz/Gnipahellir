// Gnipahellir agent message board.
//
// A tiny localhost HTTP service where AI agent sessions check in with what
// they are working on, leave messages for each other, and request/answer
// information across sessions. Storage is an append-only JSONL log so the
// board survives restarts and stays greppable by hand.
//
//   POST /post              — add a message (status / msg / request / reply)
//   GET  /delta?since=N     — every message with seq > N, plus the latest seq
//   GET  /agents            — last-seen + latest status per agent
//   GET  /                  — plain-text summary for humans
//
// Build: odin build . -out:message_board.exe
// Run:   ./message_board.exe [port]        (default 7666 — Garm guards it)
package message_board

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:time"
import "core:encoding/json"

DEFAULT_PORT :: 7666
LOG_FILE :: "board.jsonl"
MAX_REQUEST :: 1 << 20 // 1 MB — nobody's status update needs more

Message :: struct {
	seq:      int      `json:"seq"`,
	unix:     i64      `json:"unix"`,     // server-side receive time, unix seconds
	agent:    string   `json:"agent"`,    // required: who is speaking
	kind:     string   `json:"kind"`,     // status | msg | request | reply
	text:     string   `json:"text"`,
	files:    []string `json:"files"`,    // files/areas the agent is touching
	to:       string   `json:"to"`,       // optional: addressed agent
	reply_to: int      `json:"reply_to"`, // optional: seq of the request this answers
}

Agent_Info :: struct {
	agent:     string   `json:"agent"`,
	last_seen: i64      `json:"last_seen"`,
	status:    string   `json:"status"`,
	files:     []string `json:"files"`,
}

Board :: struct {
	messages: [dynamic]Message,
	next_seq: int,
	log_fd:   ^os.File,
}

board: Board

board_load :: proc() {
	board.next_seq = 1
	if data, read_err := os.read_entire_file_from_path(LOG_FILE, context.allocator); read_err == nil {
		defer delete(data)
		it := string(data)
		for line in strings.split_lines_iterator(&it) {
			if len(strings.trim_space(line)) == 0 do continue
			m: Message
			if err := json.unmarshal(transmute([]u8)strings.clone(line), &m); err != nil {
				fmt.eprintfln("skipping bad line in %s: %v", LOG_FILE, err)
				continue
			}
			append(&board.messages, m)
			if m.seq >= board.next_seq do board.next_seq = m.seq + 1
		}
	}

	fd, err := os.open(LOG_FILE, {.Write, .Create, .Append})
	if err != nil {
		fmt.eprintfln("cannot open %s for writing: %v", LOG_FILE, err)
		os.exit(1)
	}
	board.log_fd = fd
}

board_post :: proc(m: Message) -> Message {
	stored := m
	stored.seq = board.next_seq
	stored.unix = time.time_to_unix(time.now())
	board.next_seq += 1
	append(&board.messages, stored)

	if line, err := json.marshal(stored, {}, context.temp_allocator); err == nil {
		os.write(board.log_fd, line)
		os.write_string(board.log_fd, "\n")
	}
	return stored
}

// ---------------------------------------------------------------- HTTP layer

send_response :: proc(client: net.TCP_Socket, status: string, content_type: string, body: string) {
	head := fmt.tprintf(
		"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
		status, content_type, len(body),
	)
	send_all(client, head)
	send_all(client, body)
}

send_all :: proc(client: net.TCP_Socket, s: string) {
	data := transmute([]u8)s
	for len(data) > 0 {
		n, err := net.send_tcp(client, data)
		if err != nil || n <= 0 do return
		data = data[n:]
	}
}

parse_content_length :: proc(headers: string) -> int {
	it := headers
	for line in strings.split_lines_iterator(&it) {
		lower := strings.to_lower(line, context.temp_allocator)
		if strings.has_prefix(lower, "content-length:") {
			v := strings.trim_space(line[len("content-length:"):])
			if n, ok := strconv.parse_int(v); ok do return n
		}
	}
	return 0
}

read_request :: proc(client: net.TCP_Socket) -> (data: []u8, header_end: int, ok: bool) {
	buf := make([dynamic]u8, 0, 8192, context.temp_allocator)
	chunk: [4096]u8
	header_end = -1
	body_len := 0
	for {
		if header_end < 0 {
			header_end = strings.index(string(buf[:]), "\r\n\r\n")
			if header_end >= 0 {
				body_len = parse_content_length(string(buf[:header_end]))
			}
		}
		if header_end >= 0 && len(buf) >= header_end + 4 + body_len {
			return buf[:], header_end, true
		}
		n, err := net.recv_tcp(client, chunk[:])
		if err != nil || n <= 0 do return nil, -1, false
		append(&buf, ..chunk[:n])
		if len(buf) > MAX_REQUEST do return nil, -1, false
	}
}

query_param :: proc(query: string, key: string) -> (string, bool) {
	it := query
	for pair in strings.split_iterator(&it, "&") {
		eq := strings.index_byte(pair, '=')
		if eq < 0 do continue
		if pair[:eq] == key do return pair[eq + 1:], true
	}
	return "", false
}

handle_connection :: proc(client: net.TCP_Socket) {
	defer net.close(client)
	defer free_all(context.temp_allocator)

	// The server is single-threaded: an idle client (e.g. a browser's
	// speculative preconnect, which sends no bytes) must never wedge the
	// accept loop. Timed-out sockets fall out of read_request as !ok.
	net.set_option(client, .Receive_Timeout, 2 * time.Second)
	net.set_option(client, .Send_Timeout, 2 * time.Second)

	data, header_end, ok := read_request(client)
	if !ok {
		send_response(client, "400 Bad Request", "text/plain", "malformed request\n")
		return
	}

	head := string(data[:header_end])
	line_end := strings.index(head, "\r\n")
	request_line := head if line_end < 0 else head[:line_end]
	fields := strings.fields(request_line, context.temp_allocator)
	if len(fields) < 2 {
		send_response(client, "400 Bad Request", "text/plain", "malformed request line\n")
		return
	}
	method, target := fields[0], fields[1]

	path, query := target, ""
	if q := strings.index_byte(target, '?'); q >= 0 {
		path, query = target[:q], target[q + 1:]
	}

	body := data[header_end + 4:]

	switch {
	case method == "OPTIONS":
		send_response(client, "204 No Content", "text/plain", "")
	case method == "POST" && path == "/post":
		handle_post(client, body)
	case method == "GET" && (path == "/delta" || path == "/messages"):
		handle_delta(client, query)
	case method == "GET" && path == "/agents":
		handle_agents(client)
	case method == "GET" && path == "/":
		handle_index(client)
	case:
		send_response(client, "404 Not Found", "text/plain", "unknown route — see GET / for the API\n")
	}
}

handle_post :: proc(client: net.TCP_Socket, body: []u8) {
	// Unmarshal with the heap allocator: the stored Message owns these strings.
	incoming: Message
	if err := json.unmarshal(body, &incoming); err != nil {
		send_response(client, "400 Bad Request", "application/json",
			fmt.tprintf(`{{"error":"bad json: %v"}}`, err))
		return
	}
	incoming.agent = strings.trim_space(incoming.agent)
	if incoming.agent == "" {
		send_response(client, "400 Bad Request", "application/json",
			`{"error":"'agent' is required"}`)
		return
	}
	switch incoming.kind {
	case "status", "msg", "request", "reply":
	case "":
		incoming.kind = "msg"
	case:
		send_response(client, "400 Bad Request", "application/json",
			`{"error":"kind must be one of: status, msg, request, reply"}`)
		return
	}

	stored := board_post(incoming)
	send_response(client, "200 OK", "application/json",
		fmt.tprintf(`{{"seq":%d,"unix":%d}}`, stored.seq, stored.unix))
}

handle_delta :: proc(client: net.TCP_Socket, query: string) {
	since := 0
	if v, found := query_param(query, "since"); found {
		if n, ok := strconv.parse_int(v); ok do since = n
	}

	first := len(board.messages)
	for m, i in board.messages {
		if m.seq > since {
			first = i
			break
		}
	}

	Delta :: struct {
		latest:   int       `json:"latest"`,
		count:    int       `json:"count"`,
		messages: []Message `json:"messages"`,
	}
	delta := Delta{
		latest   = board.next_seq - 1,
		count    = len(board.messages) - first,
		messages = board.messages[first:],
	}
	out, err := json.marshal(delta, {}, context.temp_allocator)
	if err != nil {
		send_response(client, "500 Internal Server Error", "application/json", `{"error":"marshal failed"}`)
		return
	}
	send_response(client, "200 OK", "application/json", string(out))
}

handle_agents :: proc(client: net.TCP_Socket) {
	infos := make([dynamic]Agent_Info, context.temp_allocator)
	index := make(map[string]int, context.temp_allocator)
	for m in board.messages {
		i, seen := index[m.agent]
		if !seen {
			i = len(infos)
			index[m.agent] = i
			append(&infos, Agent_Info{agent = m.agent})
		}
		infos[i].last_seen = m.unix
		if m.kind == "status" {
			infos[i].status = m.text
			infos[i].files = m.files
		}
	}
	out, err := json.marshal(infos[:], {}, context.temp_allocator)
	if err != nil {
		send_response(client, "500 Internal Server Error", "application/json", `{"error":"marshal failed"}`)
		return
	}
	send_response(client, "200 OK", "application/json", string(out))
}

handle_index :: proc(client: net.TCP_Socket) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "Gnipahellir agent message board — %d messages, latest seq %d", len(board.messages), board.next_seq - 1)
	fmt.sbprintln(&b, "")
	fmt.sbprintln(&b, "POST /post            body: {\"agent\":\"name\",\"kind\":\"status|msg|request|reply\",\"text\":\"...\",\"files\":[\"...\"],\"to\":\"agent\",\"reply_to\":seq}")
	fmt.sbprintln(&b, "GET  /delta?since=N   messages with seq > N  (start with since=0, then use 'latest' as your next cursor)")
	fmt.sbprintln(&b, "GET  /agents          last-seen + latest status per agent")
	fmt.sbprintln(&b, "")
	fmt.sbprintln(&b, "recent:")
	start := max(0, len(board.messages) - 20)
	for m in board.messages[start:] {
		addressed := "" if m.to == "" else fmt.tprintf(" -> %s", m.to)
		fmt.sbprintfln(&b, "  #%d [%s] %s%s: %s", m.seq, m.agent, m.kind, addressed, m.text)
	}
	send_response(client, "200 OK", "text/plain; charset=utf-8", strings.to_string(b))
}

// ----------------------------------------------------------------------------

main :: proc() {
	port := DEFAULT_PORT
	if len(os.args) > 1 {
		if n, ok := strconv.parse_int(os.args[1]); ok do port = n
	}

	board_load()

	listener, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = port})
	if err != nil {
		fmt.eprintfln("cannot listen on 127.0.0.1:%d: %v", port, err)
		os.exit(1)
	}
	fmt.printfln("gnipahellir message board on http://127.0.0.1:%d  (%d messages loaded from %s)", port, len(board.messages), LOG_FILE)

	for {
		client, _, accept_err := net.accept_tcp(listener)
		if accept_err != nil {
			fmt.eprintfln("accept failed: %v", accept_err)
			continue
		}
		handle_connection(client)
	}
}
