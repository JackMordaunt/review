#+feature dynamic-literals
// Package mcp serves the initialization-based 2025-11-25 stdio protocol.
package mcp

import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:unicode/utf8"


VERSION :: "2025-11-25"
MAX_FRAME :: 16 * 1024 * 1024
//review:ignore noun-for-type Handler is a noun naming the request callback role.
Handler :: #type proc(
	name: string,
	arguments: json.Object,
	allocator: mem.Allocator,
) -> (
	json.Value,
	string,
)
Session :: struct {
	initialized, ready: bool,
	handler:            Handler,
	tools:              json.Value,
}

encode :: proc(v: $T, allocator := context.temp_allocator) -> string {
	b, _ := json.marshal(v, allocator = allocator)
	return string(b)
}
error_response :: proc(
	id: json.Value,
	code: int,
	message: string,
	allocator := context.temp_allocator,
) -> string {
	context.allocator = allocator
	return encode(struct {
			jsonrpc: string,
			id:      json.Value,
			error:   struct {
				code:    int,
				message: string,
			},
		}{"2.0", id, {code, message}}, allocator = allocator)
}
result_response :: proc(id, result: json.Value, allocator := context.temp_allocator) -> string {
	context.allocator = allocator
	return encode(struct {
			jsonrpc:    string,
			id, result: json.Value,
		}{"2.0", id, result}, allocator = allocator)
}
parse :: proc(s: string, allocator := context.temp_allocator) -> (v: json.Value, ok: bool) {
	if !utf8.valid_string(s) || trailing_comma(s) {return v, false}
	parser := json.make_parser(s, .JSON, true, allocator)
	err: json.Error
	v, err = json.parse_value(&parser)
	ok = err == .None && parser.curr_token.kind == .EOF
	return
}
str :: proc(v: json.Value) -> string {s, _ := v.(string); return s}
obj :: proc(v: json.Value) -> (json.Object, bool) {o, ok := v.(json.Object); return o, ok}

is_valid_id :: proc(id: json.Value) -> bool {
	#partial switch _ in id {
	case string, i64:
		return true
	}
	return false
}

// process returns no response for notifications. It owns no transport state.
process :: proc(s: ^Session, line: string, allocator := context.temp_allocator) -> string {
	context.allocator = allocator
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) !=
	   nil {return error_response(json.Null(nil), -32603, "Out of memory", allocator = allocator)}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	null: json.Value = json.Null(nil)
	if len(line) >
	   MAX_FRAME {return error_response(null, -32700, "frame exceeds 16 MiB", allocator = allocator)}
	v, valid := parse(line)
	if !valid {return error_response(null, -32700, "Parse error", allocator = allocator)}
	o, object_ok := obj(v)
	if !object_ok {return error_response(null, -32600, "Invalid Request", allocator = allocator)}
	id, has_id := o["id"]
	if has_id &&
	   !is_valid_id(
			   id,
		   ) {return error_response(null, -32600, "Invalid request ID", allocator = allocator)}
	method, method_ok := o["method"].(string)
	if str(o["jsonrpc"]) != "2.0" ||
	   !method_ok {return error_response(null, -32600, "Invalid Request", allocator = allocator)}
	if !has_id {
		if method == "notifications/initialized" && s.initialized {s.ready = true}
		// Serialized engine operations finish atomically. Cancellation notifications
		// for completed/unknown IDs require no response and have no state effects.
		return ""
	}
	if method == "ping" {return result_response(id, json.Object{}, allocator = allocator)}
	params, params_ok := obj(o["params"])
	if method == "initialize" {
		if s.initialized {return error_response(id, -32600, "Already initialized", allocator = allocator)}
		if !params_ok ||
		   str(params["protocolVersion"]) ==
			   "" {return error_response(id, -32602, "protocolVersion required", allocator = allocator)}
		s.initialized = true
		r, _ := parse(
			`{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"review","version":"1"},"instructions":"Use review_prepare, answer each pending job with its exact schema, then review_submit. Repeat for verification jobs. Only review_report states completion."}`,
		)
		return result_response(id, r, allocator = allocator)
	}
	if method ==
	   "server/discover" {return error_response(id, -32601, "Method not found", allocator = allocator)}
	if !s.ready {return error_response(id, -32000, "Initialize and send notifications/initialized first", allocator = allocator)}
	switch method {
	case "tools/list":
		if _, present := o["params"];
		   present &&
		   (!params_ok ||
				   param_count(params) !=
					   0) {return error_response(id, -32602, "Expected empty params", allocator = allocator)}
		return result_response(id, json.Object{"tools" = s.tools}, allocator = allocator)
	case "tools/call":
		if !params_ok ||
		   param_count(params) !=
			   2 {return error_response(id, -32602, "Expected name and arguments", allocator = allocator)}
		name, name_ok := params["name"].(string)
		args, args_ok := obj(params["arguments"])
		if !name_ok ||
		   !args_ok {return error_response(id, -32602, "Expected name and object arguments", allocator = allocator)}
		if invalid := validate_call(name, args);
		   invalid != "" {return error_response(id, -32602, invalid, allocator = allocator)}
		result, err := s.handler(name, args, context.allocator)
		if err != "" {
			result = json.Object {
				"content" = json.Array{json.Object{"type" = string("text"), "text" = err}},
				"isError" = true,
			}
		} else {
			result = json.Object {
				"content"           = json.Array {
					json.Object{"type" = string("text"), "text" = encode(result)},
				},
				"structuredContent" = result,
				"isError"           = false,
			}
		}
		return result_response(id, result, allocator = allocator)
	}
	return error_response(id, -32601, "Method not found", allocator = allocator)
}

// param_count counts the parameters a request carries for the server. `_meta` is
// reserved to the protocol, and grok 1.0.62 sends it with a progress token
// on tools/list, so it is not a parameter the caller chose.
param_count :: proc(params: json.Object) -> int {
	_, has_meta := params["_meta"]
	return len(params) - 1 if has_meta else len(params)
}

// One worker bounds queued mutations to one request. Reader continues servicing
// ping/cancel while engine work runs; EOF returns without an unbounded join.
Worker :: struct {
	task:                    ^thread.Thread,
	allocator:               mem.Allocator,
	mutex:                   sync.Mutex,
	busy, cancelled, closed: bool,
	id, line:                string,
	session:                 Session,
}
run_worker :: proc(t: ^thread.Thread) {
	w := cast(^Worker)t.data
	response := process(&w.session, w.line)
	sync.mutex_lock(&w.mutex)
	if !w.cancelled && !w.closed && response != "" {fmt.println(response)}
	delete(w.line, w.allocator); delete(w.id, w.allocator)
	w.busy = false
	sync.mutex_unlock(&w.mutex)
}
route :: proc(s: ^Session, w: ^Worker, line: string, allocator := context.allocator) {
	context.allocator = allocator
	v, ok := parse(line); o, _ := obj(v)
	id, has_id := o["id"]
	method := str(o["method"])
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
	if ok && str(o["jsonrpc"]) == "2.0" && method == "notifications/cancelled" && !has_id {
		p, _ := obj(o["params"])
		if w.busy && encode(p["requestId"]) == w.id {w.cancelled = true}
		return
	}
	if ok &&
	   str(o["jsonrpc"]) == "2.0" &&
	   method == "tools/call" &&
	   has_id &&
	   is_valid_id(id) &&
	   s.ready {
		if w.busy {fmt.println(error_response(id, -32000, "Another tool call is running")); return}
		w.busy = true; w.cancelled = false; w.allocator = allocator
		w.line = strings.clone(line); w.id = strings.clone(encode(id)); w.session = s^
		if w.task != nil {thread.join(w.task); thread.destroy(w.task)}
		w.task = thread.create(run_worker); w.task.data = w
		thread.start(w.task)
		return
	}
	response := process(s, line)
	if response != "" {fmt.println(response)}
}
serve :: proc(s: ^Session, allocator := context.allocator) -> int {
	context.allocator = allocator
	// Heap ownership survives the main reader's return on EOF. Process shutdown
	// may terminate a running check; external state commits remain atomic.
	w := new(Worker)
	defer {
		sync.mutex_lock(&w.mutex); w.closed = true; idle := !w.busy; sync.mutex_unlock(&w.mutex)
		if idle {if w.task != nil {thread.join(w.task); thread.destroy(w.task)}; free(w)}
	}
	r: bufio.Reader
	bufio.reader_init(&r, os.to_reader(os.stdin)); defer bufio.reader_destroy(&r)
	line := make([dynamic]byte); defer delete(line)
	for {
		b, err := bufio.reader_read_byte(&r)
		if err != nil {return 0}
		if b == '\n' {
			route(s, w, string(line[:]))
			clear(&line)
			free_all(context.temp_allocator)
		} else {
			if len(line) >= MAX_FRAME {
				sync.mutex_lock(&w.mutex)
				fmt.println(error_response(json.Null(nil), -32700, "frame exceeds 16 MiB"))
				sync.mutex_unlock(&w.mutex)
				return 1
			}
			append(&line, b)
		}
	}
}

// Reject trailing commas and excessive nesting outside strings before parsing.
trailing_comma :: proc(s: string) -> bool {
	quoted, escaped := false, false
	previous: rune
	depth := 0
	for b in s {
		if quoted {if escaped {escaped = false} else if b == '\\' {escaped = true} else if b == '"' {quoted = false}; continue}
		if b == '"' {quoted = true; previous = b; continue}
		if b == ' ' || b == '\n' || b == '\r' || b == '\t' {continue}
		if b == '{' || b == '[' {depth += 1}
		if b == '}' || b == ']' {depth -= 1}
		if depth > 64 || depth < 0 {return true}
		if (b == '}' || b == ']') && previous == ',' {return true}
		previous = b
	}
	return false
}
