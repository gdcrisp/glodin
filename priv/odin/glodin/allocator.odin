package glodin

import "../sys"
import "core:mem"

// Owned allocations use enif_alloc, making their bytes visible to BEAM accounting.
beam_allocator :: proc() -> mem.Allocator {
	return mem.Allocator{procedure = beam_allocator_proc}
}

@(private)
beam_allocator_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old: rawptr,
	old_size: int,
	location := #caller_location,
) -> (
	[]u8,
	mem.Allocator_Error,
) {
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		align := max(alignment, align_of(rawptr))
		if size < 0 || align <= 0 || size > max(int) - align - size_of(rawptr) {
			return nil, .Invalid_Argument
		}
		base := sys.alloc(uint(size + align - 1 + size_of(rawptr)))
		if base == nil {
			return nil, .Out_Of_Memory
		}
		ptr := mem.align_forward(rawptr(uintptr(base) + uintptr(size_of(rawptr))), uintptr(align))
		([^]rawptr)(ptr)[-1] = base
		if mode == .Alloc || mode == .Resize {
			mem.zero(ptr, size)
		}
		if old != nil {
			mem.copy(ptr, old, min(old_size, size))
			sys.free(([^]rawptr)(old)[-1])
		}
		return mem.slice_ptr((^u8)(ptr), size), nil
	case .Free:
		if old != nil {
			sys.free(([^]rawptr)(old)[-1])
		}
		return nil, nil
	case .Query_Features:
		if old != nil {
			(^mem.Allocator_Mode_Set)(old)^ = {
				.Alloc,
				.Alloc_Non_Zeroed,
				.Resize,
				.Resize_Non_Zeroed,
				.Free,
				.Query_Features,
			}
		}
		return nil, nil
	case .Free_All, .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, .Mode_Not_Implemented
}
