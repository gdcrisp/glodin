// Optional arithmetic adapter for core:math/big. Returned allocations use the caller's allocator.
package bigint

import g "../glodin"
import "core:math/big"

to_core :: proc(value: g.Big_Int) -> (result: big.Int, ok: bool) {
	bytes := make([]u8, len(value.digits) + 1)
	defer delete(bytes)
	copy(bytes, value.digits)
	bytes[len(bytes) - 1] = 1 if value.negative else 0
	ok = big.int_from_bytes_little(&result, bytes, signed = true) == .None
	return
}

from_core :: proc(value: ^big.Int) -> (g.Big_Int, bool) {
	count, error := big.int_to_bytes_size(value)
	if error != .None {
		return {}, false
	}
	bytes := make([]u8, count)
	if big.int_to_bytes_little(value, bytes) != .None {
		return {}, false
	}
	return g.Big_Int{negative = value.sign == .Negative, digits = bytes}, true
}
