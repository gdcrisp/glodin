#+build !windows
package checks

import "core:sync"
import "core:sys/posix"
import g "glodin:glodin"
import sys "glodin:sys"

close_selectable :: proc(value: ^Selectable) {
	sync.mutex_lock(&value.lock)
	defer sync.mutex_unlock(&value.lock)
	if value.read_event >= 0 {
		posix.close(posix.FD(value.read_event))
		value.read_event = -1
	}
	if value.write_event >= 0 {
		posix.close(posix.FD(value.write_event))
		value.write_event = -1
	}
}

@(glodin_nif)
select_start :: proc(env: ^g.Env) -> g.Resource(Selectable) {
	fds: [2]posix.FD
	assert(posix.pipe(&fds) == .OK)
	pid, found := g.self(env)
	assert(found)
	resource, ok := g.resource_new(Selectable{read_event = g.Event(fds[0]), write_event = g.Event(fds[1]), recipient = pid})
	assert(ok)
	assert(sys.select(env, g.Event(fds[0]), 1, resource.handle, &pid, g.make_reference(env)) >= 0)
	byte: u8 = 1
	assert(posix.write(fds[1], &byte, 1) == 1)
	return resource
}
