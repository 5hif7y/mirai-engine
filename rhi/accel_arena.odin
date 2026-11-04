package rhi

import "base:runtime"

// Acceleration structures live in ranges of large blocks of GPU memory (a
// buffer on Vulkan, a placement heap on Metal), not in an object of their own
// each: a world of thousands of BLASes would otherwise take as many buffers.
// A block holds ACCEL_BLOCK_BYTES, or one structure larger than that. A range
// freed goes back to its block once the GPU finished the frames that could
// use it (the deferred deletions of the backend); a block left empty goes.
ACCEL_BLOCK_BYTES :: u64(64) << 20
// Every range starts on this many bytes, which both backends take.
ACCEL_ALIGNMENT :: u64(256)

@(private)
Arena_Free :: struct {offset, size: u64}

@(private)
Arena_Block :: struct {
	size: u64, // 0: a slot a block left, for the next one
	used: u64,
	free: [dynamic]Arena_Free, // by offset, none touching
}

@(private)
Accel_Arena :: struct {
	blocks:    [dynamic]Arena_Block,
	allocator: runtime.Allocator,
}

// A range of size bytes aligned to align, first fit. ok false: no block has room.
@(private)
accel_arena_take :: proc(arena: ^Accel_Arena, size, align: u64) -> (block: int, offset: u64, ok: bool) {
	for &b, i in arena.blocks {
		if b.size == 0 || b.size - b.used < size {continue}
		for &f, k in b.free {
			start := align_up(f.offset, align)
			if start + size > f.offset + f.size {continue}
			end := start + size
			tail := Arena_Free{end, f.offset + f.size - end}
			if start > f.offset {
				f.size = start - f.offset
				if tail.size > 0 {inject_at(&b.free, k + 1, tail)}
			} else if tail.size > 0 {
				f = tail
			} else {
				ordered_remove(&b.free, k)
			}
			b.used += size
			return i, start, true
		}
	}
	return
}

// Takes a new block of size bytes, free whole, in the slot an empty one left
// or a new one. Its index.
@(private)
accel_arena_add :: proc(arena: ^Accel_Arena, size: u64) -> int {
	if arena.blocks == nil {arena.blocks = make([dynamic]Arena_Block, arena.allocator)}
	at := -1
	for b, i in arena.blocks {if b.size == 0 {at = i; break}}
	if at < 0 {append(&arena.blocks, Arena_Block{}); at = len(arena.blocks) - 1}
	b := &arena.blocks[at]
	if b.free == nil {b.free = make([dynamic]Arena_Free, arena.allocator)}
	clear(&b.free)
	append(&b.free, Arena_Free{0, size})
	b.size, b.used = size, 0
	return at
}

// Gives a range back to its block, joined with the free ranges beside it.
// True when the block is empty: the backend lets it go (accel_arena_drop).
@(private)
accel_arena_give :: proc(arena: ^Accel_Arena, block: int, offset, size: u64) -> (empty: bool) {
	if block < 0 || block >= len(arena.blocks) || arena.blocks[block].size == 0 {return false}
	b := &arena.blocks[block]
	at := len(b.free)
	for f, k in b.free {if f.offset > offset {at = k; break}}
	inject_at(&b.free, at, Arena_Free{offset, size})
	if at + 1 < len(b.free) && b.free[at].offset + b.free[at].size == b.free[at + 1].offset {
		b.free[at].size += b.free[at + 1].size
		ordered_remove(&b.free, at + 1)
	}
	if at > 0 && b.free[at - 1].offset + b.free[at - 1].size == b.free[at].offset {
		b.free[at - 1].size += b.free[at].size
		ordered_remove(&b.free, at)
	}
	b.used -= min(size, b.used)
	return b.used == 0
}

// Forgets an empty block: its slot takes the next one.
@(private)
accel_arena_drop :: proc(arena: ^Accel_Arena, block: int) {
	if block < 0 || block >= len(arena.blocks) {return}
	b := &arena.blocks[block]
	b.size, b.used = 0, 0
	clear(&b.free)
}

@(private)
accel_arena_destroy :: proc(arena: ^Accel_Arena) {
	for &b in arena.blocks {delete(b.free)}
	delete(arena.blocks)
	arena^ = {}
}

// The size of the block that takes a structure of size bytes.
@(private)
accel_block_size :: proc "contextless" (size: u64) -> u64 {return max(ACCEL_BLOCK_BYTES, align_up(size, ACCEL_ALIGNMENT))}

// The GPU memory of the acceleration structures of a device: the blocks it
// holds and what its structures take of them, in bytes.
accel_memory :: proc(d: ^Device) -> (held, used: u64) {
	for b in d.accel_arena.blocks {held += b.size; used += b.used}
	return
}
