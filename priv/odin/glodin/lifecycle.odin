package glodin

import "base:runtime"
import "core:mem"

// Called by generated unload glue after BEAM has released this library instance.
shutdown :: proc() {
	jobs_shutdown()
	for _, descriptor in resource_descriptors {
		delete(descriptor.name)
	}
	for _, callbacks in resource_callbacks {
		mem.free(callbacks)
	}
	delete(resource_callbacks)
	delete(resource_descriptors)
	delete(resource_names)
	for _, codec in codecs {
		if codec.tag != "" {
			delete(codec.tag, runtime.heap_allocator())
		}
	}
	delete(codecs)
	resource_callbacks = nil
	resource_descriptors = nil
	resource_names = nil
	codecs = nil
}
