package rhi

import "core:testing"

// Ranges fill a block from its start, aligned; given back they join their
// neighbours, so the block ends whole and empty, and a structure larger than
// a block takes one of its own.
@(test)
accel_arena_takes_aligned_ranges_and_joins_what_comes_back :: proc(t: ^testing.T) {
	arena := Accel_Arena{allocator = context.allocator}
	defer accel_arena_destroy(&arena)
	_, _, ok := accel_arena_take(&arena, 1000, ACCEL_ALIGNMENT)
	testing.expect(t, !ok, "an arena without blocks has no room")
	block := accel_arena_add(&arena, accel_block_size(1000))
	testing.expect_value(t, arena.blocks[block].size, ACCEL_BLOCK_BYTES)
	sizes := [4]u64{1000, 256, 4096, 300}
	offsets: [4]u64
	for size, i in sizes {
		at, offset, taken := accel_arena_take(&arena, align_up(size, ACCEL_ALIGNMENT), ACCEL_ALIGNMENT)
		testing.expect(t, taken && at == block && offset % ACCEL_ALIGNMENT == 0)
		offsets[i] = offset
	}
	testing.expect(t, offsets[0] == 0 && offsets[1] == 1024 && offsets[2] == 1280 && offsets[3] == 5376, "first fit, in order")
	// A hole in the middle takes what fits there.
	testing.expect(t, !accel_arena_give(&arena, block, offsets[1], 256))
	at, offset, taken := accel_arena_take(&arena, 256, ACCEL_ALIGNMENT)
	testing.expect(t, taken && at == block && offset == offsets[1])
	// Given back in any order, the ranges join into the whole block.
	testing.expect(t, !accel_arena_give(&arena, block, offsets[2], 4096))
	testing.expect(t, !accel_arena_give(&arena, block, offsets[0], 1024))
	testing.expect(t, !accel_arena_give(&arena, block, offsets[3], 512))
	testing.expect(t, accel_arena_give(&arena, block, offsets[1], 256), "the last range leaves the block empty")
	testing.expect(t, len(arena.blocks[block].free) == 1 && arena.blocks[block].free[0] == Arena_Free{0, ACCEL_BLOCK_BYTES})
	// Larger than a block: a block of its own, in the slot an empty one left.
	accel_arena_drop(&arena, block)
	huge := ACCEL_BLOCK_BYTES * 3 + 1
	again := accel_arena_add(&arena, accel_block_size(huge))
	testing.expect_value(t, again, block)
	at, offset, taken = accel_arena_take(&arena, align_up(huge, ACCEL_ALIGNMENT), ACCEL_ALIGNMENT)
	testing.expect(t, taken && at == again && offset == 0)
}
