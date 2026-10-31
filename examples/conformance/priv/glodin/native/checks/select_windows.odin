package checks

import "core:sync"
import win32 "core:sys/windows"
import g "glodin:glodin"
import sys "glodin:sys"

close_selectable :: proc(value: ^Selectable) {
	sync.mutex_lock(&value.lock)
	defer sync.mutex_unlock(&value.lock)
	if value.read_event != nil {
		win32.CloseHandle(value.read_event)
		value.read_event = nil
	}
}

@(glodin_nif)
select_start :: proc(env: ^g.Env) -> g.Resource(Selectable) {
	pid, found := g.self(env)
	assert(found)
	event := win32.CreateEventW(nil, false, false, nil)
	assert(event != nil)
	resource, ok := g.resource_new(Selectable{read_event = event, recipient = pid})
	assert(ok)
	assert(sys.select(env, event, 1, resource.handle, &pid, g.make_reference(env)) >= 0)
	assert(win32.SetEvent(event))
	return resource
}
