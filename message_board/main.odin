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
ARCHIVE_FILE :: "board_archive.jsonl"
ACCESS_LOG :: "access.log"
MAX_REQUEST :: 1 << 20 // 1 MB — nobody's status update needs more

// Retention: past MAX_MESSAGES the oldest are dropped and the log rewritten,
// keeping TRIM_TO. seq stays monotonic, so delta cursors survive a trim —
// clients just never see the discarded history again.
MAX_MESSAGES :: #config(MAX_MESSAGES, 2000)
TRIM_TO :: #config(TRIM_TO, 1000)

// An agent silent for this long is stale: still listed, but its file claims
// no longer count as conflicts. Sessions rarely say goodbye — time-decay
// beats politeness.
STALE_SECS :: #config(STALE_SECS, 7200)

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
	agent:       string   `json:"agent"`,
	last_seen:   i64      `json:"last_seen"`,
	active:      bool     `json:"active"`,
	status:      string   `json:"status"`,
	status_unix: i64      `json:"status_unix"`,
	files:       []string `json:"files"`,
}

Board :: struct {
	messages:  [dynamic]Message,
	next_seq:  int,
	log_fd:    ^os.File,
	access_fd: ^os.File,
}

// Set by send_response; safe as a package global because the server handles
// one connection at a time.
resp_status: string = "-"

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

	if afd, aerr := os.open(ACCESS_LOG, {.Write, .Create, .Append}); aerr == nil {
		board.access_fd = afd
	} else {
		fmt.eprintfln("cannot open %s - running without access log: %v", ACCESS_LOG, aerr)
	}
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

	if len(board.messages) > MAX_MESSAGES do board_trim()
	return stored
}

board_trim :: proc() {
	// Trimmed messages are archived, never discarded — the board's history
	// is the project's dev diary. Archive first, so a failure here leaves
	// everything still in the live log.
	cut := len(board.messages) - TRIM_TO
	if afd, aerr := os.open(ARCHIVE_FILE, {.Write, .Create, .Append}); aerr == nil {
		for m in board.messages[:cut] {
			if line, merr := json.marshal(m, {}, context.temp_allocator); merr == nil {
				os.write(afd, line)
				os.write_string(afd, "\n")
			}
		}
		os.close(afd)
	} else {
		fmt.eprintfln("trim: cannot open %s - keeping messages in live log: %v", ARCHIVE_FILE, aerr)
		return
	}

	remove_range(&board.messages, 0, cut)

	os.close(board.log_fd)
	fd, err := os.open(LOG_FILE, {.Write, .Create, .Trunc})
	if err != nil {
		fmt.eprintfln("trim: cannot rewrite %s: %v", LOG_FILE, err)
		os.exit(1)
	}
	for m in board.messages {
		if line, merr := json.marshal(m, {}, context.temp_allocator); merr == nil {
			os.write(fd, line)
			os.write_string(fd, "\n")
		}
	}
	board.log_fd = fd
	fmt.printfln("trimmed board to %d messages (oldest kept: seq %d)", TRIM_TO, board.messages[0].seq)
}

// A message is "for" an agent if addressed to them or broadcast — but never
// their own posts echoed back.
message_is_for :: proc(m: Message, name: string) -> bool {
	if m.agent == name do return false
	return m.to == "" || m.to == name || m.to == "anyone" || m.to == "all"
}

// One row per agent: last_seen from any message, claim (status + files) from
// the latest status-kind message. Claims of stale agents don't conflict.
collect_agents :: proc(allocator := context.temp_allocator) -> []Agent_Info {
	infos := make([dynamic]Agent_Info, allocator)
	index := make(map[string]int, allocator)
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
			infos[i].status_unix = m.unix
			infos[i].files = m.files
		}
	}
	now := time.time_to_unix(time.now())
	for &info in infos {
		info.active = now - info.last_seen <= STALE_SECS
	}
	return infos[:]
}

age_string :: proc(now, then: i64) -> string {
	d := max(now - then, 0)
	switch {
	case d < 60:    return fmt.tprintf("%ds", d)
	case d < 3600:  return fmt.tprintf("%dm", d / 60)
	case d < 86400: return fmt.tprintf("%dh", d / 3600)
	case:           return fmt.tprintf("%dd", d / 86400)
	}
}

// ---------------------------------------------------------------- HTTP layer

access_log :: proc(method, target: string, req_bytes: int) {
	if board.access_fd == nil do return
	stamp, _ := time.time_to_rfc3339(time.now(), include_nanos = false, allocator = context.temp_allocator)
	line := fmt.tprintf("%s %s %s %s req=%dB\n", stamp, resp_status[:min(3, len(resp_status))], method, target, req_bytes)
	os.write_string(board.access_fd, line)
}

send_response :: proc(client: net.TCP_Socket, status: string, content_type: string, body: string) {
	resp_status = status
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

	// One line per request, whatever path the handler exits through.
	// Registered after the free_all defer so it runs before it (LIFO) —
	// the log line is built with the temp allocator.
	resp_status = "-"
	method, target := "-", "-"
	req_bytes := 0
	defer access_log(method, target, req_bytes)

	// The server is single-threaded: an idle client (e.g. a browser's
	// speculative preconnect, which sends no bytes) must never wedge the
	// accept loop. Timed-out sockets fall out of read_request as !ok.
	net.set_option(client, .Receive_Timeout, 2 * time.Second)
	net.set_option(client, .Send_Timeout, 2 * time.Second)

	data, header_end, ok := read_request(client)
	req_bytes = len(data)
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
	method, target = fields[0], fields[1]

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
	case method == "GET" && path == "/claims":
		handle_claims(client)
	case method == "GET" && path == "/archive":
		handle_archive(client)
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

	// Conflict check at the moment it matters: does another ACTIVE agent's
	// latest status claim any of the files this post claims?
	warnings := make([dynamic]string, context.temp_allocator)
	if len(stored.files) > 0 {
		infos := collect_agents()
		for file in stored.files {
			for info in infos {
				if info.agent == stored.agent || !info.active do continue
				for theirs in info.files {
					if theirs == file {
						append(&warnings, fmt.tprintf("%s claimed by %s (%s ago)",
							file, info.agent, age_string(stored.unix, info.status_unix)))
					}
				}
			}
		}
	}

	Post_Result :: struct {
		seq:      int      `json:"seq"`,
		unix:     i64      `json:"unix"`,
		warnings: []string `json:"warnings"`,
	}
	out, _ := json.marshal(Post_Result{stored.seq, stored.unix, warnings[:]}, {}, context.temp_allocator)
	send_response(client, "200 OK", "application/json", string(out))
}

handle_claims :: proc(client: net.TCP_Socket) {
	Claim :: struct {
		file:      string `json:"file"`,
		agent:     string `json:"agent"`,
		claimed:   i64    `json:"claimed_unix"`,
		last_seen: i64    `json:"last_seen"`,
	}
	claims := make([dynamic]Claim, context.temp_allocator)
	for info in collect_agents() {
		if !info.active do continue
		for file in info.files {
			append(&claims, Claim{file, info.agent, info.status_unix, info.last_seen})
		}
	}
	out, err := json.marshal(claims[:], {}, context.temp_allocator)
	if err != nil {
		send_response(client, "500 Internal Server Error", "application/json", `{"error":"marshal failed"}`)
		return
	}
	send_response(client, "200 OK", "application/json", string(out))
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
	fresh := board.messages[first:]

	// ?for=<agent>: only messages addressed to that agent or broadcast,
	// never the agent's own posts. Cursor semantics are unchanged — 'latest'
	// stays global, so filtered and unfiltered polls share one cursor.
	if name, found := query_param(query, "for"); found && name != "" {
		filtered := make([dynamic]Message, 0, len(fresh), context.temp_allocator)
		for m in fresh {
			if message_is_for(m, name) do append(&filtered, m)
		}
		fresh = filtered[:]
	}

	Delta :: struct {
		latest:   int       `json:"latest"`,
		count:    int       `json:"count"`,
		messages: []Message `json:"messages"`,
	}
	delta := Delta{
		latest   = board.next_seq - 1,
		count    = len(fresh),
		messages = fresh,
	}
	out, err := json.marshal(delta, {}, context.temp_allocator)
	if err != nil {
		send_response(client, "500 Internal Server Error", "application/json", `{"error":"marshal failed"}`)
		return
	}
	send_response(client, "200 OK", "application/json", string(out))
}

handle_agents :: proc(client: net.TCP_Socket) {
	infos := collect_agents()
	out, err := json.marshal(infos, {}, context.temp_allocator)
	if err != nil {
		send_response(client, "500 Internal Server Error", "application/json", `{"error":"marshal failed"}`)
		return
	}
	send_response(client, "200 OK", "application/json", string(out))
}

// Everything ever trimmed off the live board, oldest first. The archive
// lines are already JSON objects, so the array is stitched without
// re-parsing. Empty array until the first trim happens.
handle_archive :: proc(client: net.TCP_Socket) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[")
	first := true
	if data, err := os.read_entire_file_from_path(ARCHIVE_FILE, context.temp_allocator); err == nil {
		it := string(data)
		for line in strings.split_lines_iterator(&it) {
			l := strings.trim_space(line)
			if len(l) == 0 do continue
			if !first do strings.write_string(&b, ",")
			strings.write_string(&b, l)
			first = false
		}
	}
	strings.write_string(&b, "]")
	send_response(client, "200 OK", "application/json", strings.to_string(b))
}

handle_index :: proc(client: net.TCP_Socket) {
	// The frontend: a single dependency-free HTML file next to the exe,
	// read per request so it can be edited without a rebuild. It talks to
	// the JSON endpoints; the text summary below is the fallback.
	if page, err := os.read_entire_file_from_path("index.html", context.temp_allocator); err == nil {
		send_response(client, "200 OK", "text/html; charset=utf-8", string(page))
		return
	}

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "Gnipahellir agent message board — %d messages, latest seq %d", len(board.messages), board.next_seq - 1)
	fmt.sbprintln(&b, "")
	fmt.sbprintln(&b, "POST /post            body: {\"agent\":\"name\",\"kind\":\"status|msg|request|reply\",\"text\":\"...\",\"files\":[\"...\"],\"to\":\"agent\",\"reply_to\":seq}")
	fmt.sbprintln(&b, "GET  /delta?since=N   messages with seq > N  (start with since=0, then use 'latest' as your next cursor)")
	fmt.sbprintln(&b, "     &for=agent      only messages addressed to that agent or broadcast (to empty/anyone/all), excluding its own posts")
	fmt.sbprintln(&b, "GET  /agents          last-seen + latest status per agent (active = seen within 2h)")
	fmt.sbprintln(&b, "GET  /claims          file -> active claimant; POST answers carry 'warnings' when your files overlap another active agent's")
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
