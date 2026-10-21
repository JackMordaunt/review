package mcp
import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(test)
lifecycle_and_ids :: proc(t: ^testing.T) {
	s: Session
	testing.expect(
		t,
		strings.contains(
			process(&s, `{"jsonrpc":"2.0","id":"modern","method":"server/discover"}`),
			`"code":-32601`,
		),
	)
	testing.expect(
		t,
		strings.contains(
			process(&s, `{"jsonrpc":"2.0","id":42,"method":"tools/list"}`),
			`"code":-32000`,
		),
	)
	r := process(
		&s,
		`{"jsonrpc":"2.0","id":"hello","method":"initialize","params":{"protocolVersion":"2099-01-01"}}`,
	)
	testing.expect(t, strings.contains(r, `"id":"hello"`))
	testing.expect(t, strings.contains(r, VERSION))
	testing.expect(t, process(&s, `{"jsonrpc":"2.0","method":"notifications/initialized"}`) == "")
	testing.expect(t, s.ready)
	testing.expect(
		t,
		strings.contains(process(&s, `{"jsonrpc":"2.0","id":7,"method":"ping"}`), `"id":7`),
	)
	testing.expect(
		t,
		strings.contains(
			process(&s, `{"jsonrpc":"2.0","id":8,"method":"server/discover"}`),
			`-32601`,
		),
	)
	testing.expect(t, process(&s, `{"jsonrpc":"2.0","method":"unknown"}`) == "")
}
@(test)
malformed_envelopes :: proc(t: ^testing.T) {
	s: Session
	for input in ([]string{`[]`, `{"jsonrpc":"2.0","id":null,"method":"ping"}`, `{"jsonrpc":"2.0","id":true,"method":"ping"}`, `{"jsonrpc":"2.0","id":1.5,"method":"ping"}`, `{"jsonrpc":"1.0","id":1,"method":"ping"}`}) {
		testing.expect(t, strings.contains(process(&s, input), `-32600`), input)
	}
	for input in ([]string{`{`, `// comment`, `{"jsonrpc":"2.0",}`, `{"jsonrpc":"2.0"} trailing`, `{"x":1,"x":2}`}) {testing.expect(t, strings.contains(process(&s, input), `-32700`), input)}
}

@(test)
frame_bound_and_cancel :: proc(t: ^testing.T) {
	s := Session {
		initialized = true,
		ready       = true,
	}
	data := make([]byte, MAX_FRAME + 1, context.temp_allocator)
	testing.expect(t, strings.contains(process(&s, string(data)), "frame exceeds"))
	// Cancellation is scoped to the exact in-flight ID and never replies.
	w := Worker {
		busy = true,
		id   = `"current"`,
	}
	route(
		&s,
		&w,
		`{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"other"}}`,
	)
	testing.expect(t, !w.cancelled)
	route(
		&s,
		&w,
		`{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"current"}}`,
	)
	testing.expect(t, w.cancelled)
	testing.expect(
		t,
		strings.contains(process(&s, `{"jsonrpc":"2.0","id":9,"method":"ping"}`), `"id":9`),
	)
}

slow_handler :: proc(
	name: string,
	args: json.Object,
	allocator: mem.Allocator,
) -> (
	json.Value,
	string,
) {
	time.sleep(50 * time.Millisecond)
	return nil, "cancelled test result"
}
@(test)
cancel_inflight_worker :: proc(t: ^testing.T) {
	s := Session {
		initialized = true,
		ready       = true,
		handler     = slow_handler,
	}
	w: Worker
	route(
		&s,
		&w,
		`{"jsonrpc":"2.0","id":"slow","method":"tools/call","params":{"name":"review_prepare","arguments":{}}}`,
	)
	// The same reader handles ping while the engine worker sleeps.
	ping := process(&s, `{"jsonrpc":"2.0","id":"ping","method":"ping"}`)
	testing.expect(
		t,
		strings.contains(ping, `"id":"ping"`) && strings.contains(ping, `"result":{}`),
	)
	route(
		&s,
		&w,
		`{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"slow"}}`,
	)
	finished := false
	for _ in 0 ..< 1000 {
		sync.mutex_lock(&w.mutex)
		finished = !w.busy
		sync.mutex_unlock(&w.mutex)
		if finished {break}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, finished)
	testing.expect(t, w.cancelled)
	if w.task != nil {thread.join(w.task); thread.destroy(w.task)}
}

@(test)
invalid_tool_arguments_are_protocol_errors :: proc(t: ^testing.T) {
	s := Session {
		initialized = true,
		ready       = true,
	}
	for input in ([]string{`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"unknown","arguments":{}}}`, `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"review_prepare","arguments":{"repo":"/tmp"}}}`, `{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"review_report","arguments":{}}}`, `{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"review_submit","arguments":{"version":true}}}`}) {testing.expect(t, strings.contains(process(&s, input), `"code":-32602`), input)}
}
