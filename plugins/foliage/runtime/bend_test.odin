package foliage

import "core:testing"
import "mirai:core"
import mm "mirai:std/math"

// The benders nearest the view bend the foliage, BENDERS at most, nearest
// first, with where each was the frame before; one without radius or lean
// bends nothing, and lean and radius are held to their limits.
@(test)
the_benders_nearest_the_view_bend_the_foliage :: proc(t: ^testing.T) {
	entities: core.Entities
	core.entities_init(&entities)
	defer core.entities_destroy(&entities)
	benders: core.Table(Foliage_Bender)
	worlds: core.Table(core.World_Transform)
	core.table_init(&benders, "Foliage_Bender");core.table_init(&worlds, "World_Transform")
	defer {core.table_destroy(&benders);core.table_destroy(&worlds)}
	placed: [BENDERS + 2]core.Entity
	for &e, i in placed {
		e = core.create(&entities)
		place := mm.TRANSFORM_IDENTITY
		place.position = {f32(len(placed) - i), 0, 0}
		core.add(&benders, e, Foliage_Bender{radius = 9, lean = 3})
		core.add(&worlds, e, core.World_Transform{place, place})
	}
	idle := core.create(&entities)
	core.add(&benders, idle, Foliage_Bender{radius = 0, lean = 1})
	core.add(&worlds, idle, core.World_Transform{mm.TRANSFORM_IDENTITY, mm.TRANSFORM_IDENTITY})
	core.table_settle(&benders, &entities);core.table_settle(&worlds, &entities);core.entities_settle(&entities)
	resident: Foliage_Resident
	benders_gather(&resident, core.read(&benders), core.read(&worlds), core.FRAME_TIME_DEFAULT, {})
	if !testing.expect_value(t, resident.bender_count, BENDERS) {return}
	for i in 1 ..< resident.bender_count {
		testing.expect(t, resident.benders[i - 1].position.x <= resident.benders[i].position.x, "nearest first")
	}
	testing.expect_value(t, resident.benders[0].position.x, 1)
	testing.expect(t, resident.benders[0].radius == BEND_RADIUS_MAX && resident.benders[0].lean == BEND_LEAN_MAX, "held to the limits")
	testing.expect(t, resident.benders[0].previous == resident.benders[0].position, "a new bender was where it is")
	moved := mm.TRANSFORM_IDENTITY
	moved.position = {0.5, 0, 0}
	core.free(&worlds, placed[len(placed) - 1])^ = core.World_Transform{moved, moved}
	benders_gather(&resident, core.read(&benders), core.read(&worlds), core.FRAME_TIME_DEFAULT, {})
	testing.expect(t, resident.benders[0].position.x == 0.5 && resident.benders[0].previous.x == 1, "it was where the frame before had it")
}
