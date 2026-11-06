package entropy

import "base:runtime"
import "core:mem"

// Scratch memory of the encoder. An allocation that fails returns nil and sets `failed`; the
// caller returns its failure value and the top-level encoder reports out of memory.
Arena :: struct {allocator:mem.Allocator, failed:bool}

ARENA_ALIGNMENT :: 16

arena_make :: proc(allocator:mem.Allocator) -> Arena {return Arena{allocator=allocator}}

// Uninitialized memory for n values of T; nil when n<0 or out of memory.
arena_alloc :: proc(a:^Arena, $T:typeid, n:int) -> []T {
    if n<0 || n>max(int)/size_of(T) {a.failed=true;return nil}
    if n==0 {return nil}
    bytes,err:=mem.alloc_bytes_non_zeroed(n*size_of(T),max(ARENA_ALIGNMENT,align_of(T)),a.allocator)
    if err!=nil || bytes==nil {a.failed=true;return nil}
    return ([^]T)(raw_data(bytes))[:n]
}

// Zeroed memory for n values of T; nil when n<0 or out of memory.
arena_alloc_zeroed :: proc(a:^Arena, $T:typeid, n:int) -> []T {
    s:=arena_alloc(a,T,n)
    if s!=nil {runtime.mem_zero(raw_data(s),len(s)*size_of(T))}
    return s
}

arena_free :: proc(a:^Arena, s:[]$T) {
    if s!=nil {_=mem.free(raw_data(s),a.allocator)}
}
