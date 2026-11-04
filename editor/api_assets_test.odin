package editor

import "core:mem"
import "core:strings"
import "core:testing"
import "mirai:core"
import mm "mirai:std/math"
import "mirai:std/serial"

@(private="file")
List_Lamp :: struct {
    tint:[3]f32 `mirai:"color"`,
    turn:mm.Quat,
    cone:f32 `mirai:"angle,min=0.1,max=1"`,
    age:f32 `mirai:"unit=s,readonly"`,
}
@(private="file")
List_World :: struct {
    entities:core.Entities,
    lamps:core.Table(List_Lamp),
}
@(private="file") List_Editor :: struct {api:Api}

// component.list says what a field is in what it already reads: a color, a
// rotation, an angle in radians, read only when it is, and the comment of its
// line; no flags nor sizes. A read-only field is refused to the scene API.
@(test)
component_list_fields_say_their_kind_unit_and_description :: proc(t:^testing.T) {
    descriptions:=[1]core.Field_Description{{"cone","from its axis to the edge"}}
    tables:=[1]core.Table_Info{{name="List_Lamp",type=List_Lamp,info=type_info_of(List_Lamp),offset=offset_of(List_World,lamps),fields=descriptions[:]}}
    storages:=[1]core.Storage_Info{{name="Api",type=Api,info=type_info_of(Api),place=.Editor,offset=offset_of(List_Editor,api)}}
    info:=core.World_Info{entities=offset_of(List_World,entities),tables=tables[:],storages=storages[:]}
    state:Api_State
    editor:=List_Editor{api={state=&state}}
    world:List_World
    session:=Session{info=&info,editor_world=&editor,edit_world=&world}
    api_schema_build(&session,&state)
    defer api_schema_free(&state)
    out:serial.Writer;serial.writer_init(&out);defer serial.writer_destroy(&out)
    first:=true
    api_fields_write(&out,&state.schema,state.types[0],"",&first)
    text:=string(serial.writer_bytes(&out))
    for part in ([]string{`{"path":"tint","type":"Color"}`,`{"path":"turn","type":"Quaternion"}`,`"unit":"rad","description":"from its axis to the edge"}`,`"unit":"s","read_only":true}`}) {
        testing.expectf(t,strings.contains(text,part),"%s in %s",part,text)
    }
    testing.expectf(t,!strings.contains(text,"flags") && !strings.contains(text,"size") && strings.count(text,"read_only")==1,"no flags, sizes nor read_only where it is false: %s",text)
    before:=List_Lamp{cone=0.5,age=3}
    after:=before
    after.cone=0.7
    testing.expect_value(t,read_only_written(&state.schema,state.types[0],mem.ptr_to_bytes(&before),mem.ptr_to_bytes(&after),""),"")
    after.age=4
    testing.expect_value(t,read_only_written(&state.schema,state.types[0],mem.ptr_to_bytes(&before),mem.ptr_to_bytes(&after),""),"age")
}
