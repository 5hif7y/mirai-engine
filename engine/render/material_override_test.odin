package render

import "core:testing"
import "mirai:std/base"

@(test)
each_writer_of_a_material_override_changes_only_the_names_it_gives :: proc(t:^testing.T) {
    o:Material_Override
    emission,strength,offset:=base.name_hash("emission"),base.name_hash("strength"),base.name_hash("noise_offset")
    // One function owns the emission of slot 1, another the parameters of slot 0.
    testing.expect(t,material_override_value_set(&o,1,emission,{2,2,2,0}))
    testing.expect(t,material_override_value_set(&o,0,strength,{0.5,0,0,0}) && material_override_value_set(&o,0,offset,{0.25,0.75,0,0}))
    testing.expect(t,material_override_value_set(&o,0,strength,{0.1,0,0,0}),"a name set again keeps its place")
    testing.expect_value(t,o.count,u32(3))
    testing.expect_value(t,o.values[material_override_find(&o,1,emission)],[4]f32{2,2,2,0})
    testing.expect_value(t,o.values[material_override_find(&o,0,strength)],[4]f32{0.1,0,0,0})
    testing.expect_value(t,material_override_find(&o,0,emission),-1)
    testing.expect(t,material_override_changes(&o,0) && material_override_changes(&o,1))

    material_override_value_drop(&o,0,strength)
    testing.expect_value(t,material_override_find(&o,0,strength),-1)
    testing.expect_value(t,o.values[material_override_find(&o,1,emission)],[4]f32{2,2,2,0})
    testing.expect_value(t,o.values[material_override_find(&o,0,offset)],[4]f32{0.25,0.75,0,0})
    material_override_value_drop(&o,0,strength)
    testing.expect_value(t,o.count,u32(2))

    // A full override refuses a new name and an invalid slot, and still takes those it has.
    for i in o.count..<MATERIAL_OVERRIDE_CAPACITY {testing.expect(t,material_override_value_set(&o,2,u64(i)+1,{}))}
    testing.expect(t,!material_override_value_set(&o,0,strength,{1,0,0,0}))
    testing.expect(t,material_override_value_set(&o,1,emission,{3,3,3,0}))
    material_override_value_drop(&o,1,emission)
    testing.expect(t,!material_override_value_set(&o,MATERIAL_SLOTS,strength,{}) && !material_override_value_set(&o,-1,strength,{}))
    testing.expect(t,material_override_value_set(&o,0,strength,{1,0,0,0}))
}
