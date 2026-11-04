package serial

import "core:testing"
import "mirai:std/base"

@(private="file")
Shape :: enum u8 {Box,Sphere=4}
@(private="file")
Layer :: enum u8 {Static,Dynamic,Debris}
@(private="file")
Inner :: struct {offset:[3]f32,shape:Shape}
@(private="file")
Sample :: struct {
    target:base.Entity,
    mesh:base.Asset_Id,
    speed:f32 `mirai:"min=0,max=20,step=0.5,unit=m/s,precision=0.01"`,
    rotation:quaternion128,
    layers:bit_set[Layer;u8],
    parts:[2]Inner,
    label:[32]u8 `mirai:"text,label=Display name"`,
    cache:u32 `mirai:"transient,local"`,
    enabled:bool,
}
@(private="file")
Not_Plain :: struct {count:int,inner:struct {names:[]string}}

@(test)
schema_describes_plain_structs_with_nested_types_and_tags :: proc(t:^testing.T) {
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    root,ok:=schema_add(&s,Sample)
    testing.expect(t,ok,s.error)
    testing.expect_value(t,schema_type(&s,root).name,"Sample")
    testing.expect_value(t,schema_type(&s,root).size,u32(size_of(Sample)))
    fields:=schema_fields(&s,root)
    testing.expect_value(t,len(fields),9)
    testing.expect_value(t,schema_type(&s,fields[0].type).kind,Type_Kind.Entity)
    testing.expect_value(t,schema_type(&s,fields[1].type).kind,Type_Kind.Asset)
    speed:=schema_field(&s,root,base.name_hash("speed"))
    testing.expect(t,speed!=nil && speed.has_min && speed.has_max)
    testing.expect_value(t,speed.max,20.0)
    testing.expect_value(t,speed.step,0.5)
    testing.expect_value(t,speed.unit,"m/s")
    testing.expect_value(t,speed.precision,f32(0.01))
    testing.expect_value(t,speed.offset,u32(offset_of(Sample,speed)))
    rotation:=schema_field(&s,root,base.name_hash("rotation"))
    testing.expect(t,.Rotation in rotation.flags)
    testing.expect_value(t,schema_type(&s,rotation.type).count,u32(4))
    layers:=schema_choices(&s,schema_field(&s,root,base.name_hash("layers")).type)
    testing.expect_value(t,len(layers),3)
    testing.expect_value(t,layers[2].name,"Debris")
    testing.expect_value(t,layers[2].value,i64(2))
    parts:=schema_type(&s,schema_field(&s,root,base.name_hash("parts")).type)
    testing.expect_value(t,parts.kind,Type_Kind.Array)
    testing.expect_value(t,parts.count,u32(2))
    inner:=schema_fields(&s,parts.elem)
    testing.expect_value(t,len(inner),2)
    shape:=schema_choices(&s,inner[1].type)
    testing.expect_value(t,shape[1].value,i64(4))
    label:=schema_field(&s,root,base.name_hash("label"))
    testing.expect(t,.Text in label.flags)
    testing.expect_value(t,label.label,"Display name")
    cache:=schema_field(&s,root,base.name_hash("cache"))
    testing.expect(t,cache.flags==Field_Flags{.Transient,.Local})
    found,found_ok:=schema_find(&s,base.name_hash("Sample"))
    testing.expect(t,found_ok && found==root)
}

@(test)
schema_rejects_types_that_are_not_plain_data :: proc(t:^testing.T) {
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    _,ok:=schema_add(&s,Not_Plain)
    testing.expect(t,!ok)
    testing.expect_value(t,s.error,"inner.names: []string is not plain data")
}

@(test)
schema_layout_hash_follows_the_layout :: proc(t:^testing.T) {
    A :: struct {x:f32,y:u16}
    B :: struct {x:f32,y:u32}
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    a,_:=schema_add(&s,A)
    b,_:=schema_add(&s,B)
    again:Schema;schema_init(&again);defer schema_destroy(&again)
    a_again,_:=schema_add(&again,A)
    testing.expect(t,schema_layout_hash(&s,a)!=schema_layout_hash(&s,b))
    testing.expect_value(t,schema_layout_hash(&again,a_again),schema_layout_hash(&s,a))
}
