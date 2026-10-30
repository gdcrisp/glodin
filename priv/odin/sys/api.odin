package sys

// Signature must be the exact proc "c" signature from the selected OTP header.
// Opaque C structures must be allocated through C, not reproduced as Odin layouts.
api :: proc(name: cstring, $Signature: typeid) -> (Signature, bool) {
	ptr := api_lookup(transmute(^u8)name)
	return transmute(Signature)ptr, ptr != nil
}
