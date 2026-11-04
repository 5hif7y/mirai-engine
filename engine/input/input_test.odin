package input

import "core:strings"
import "core:testing"
import "mirai:core"

@(private="file") MOVE :: Action(0)
@(private="file") JUMP :: Action(2)
@(private="file") HIT :: Action(40)

@(private="file")
Test_Defaults :: struct {
    count:int,
    defaults:[2]Action_Default,
}

@(private="file")
test_defaults :: proc(dst:rawptr) {
    (cast(^Test_Defaults)dst)^={defaults={
        action_default(MOVE,.Axis2,binding_keys(.A,.D,.S,.W),binding_gamepad_stick(.Left)),
        action_default(JUMP,.Button,binding_key(.Space)),
    }}
}


@(private="file")
TEST_NAMES :: [3]core.Name_Info{
    {type=Action,value=0,name="move",file="plugins/test/move.odin",line=3},
    {type=Action,value=2,name="jump",file="plugins/test/move.odin",line=4},
    {type=Action,value=40,name="hit",file="game/game.odin",line=7,project=true},
}

// The defaults the code gives its actions are in the map without a step that
// declares them; input.mirai replaces those of the actions it names.
@(test)
the_defaults_of_the_code_need_no_step :: proc(t:^testing.T) {
    names:=TEST_NAMES
    storages:=[]core.Storage_Info{{name="Test_Defaults",type=Test_Defaults,info=type_info_of(Test_Defaults),default=test_defaults}}
    info:=core.World_Info{names=names[:],storages=storages}
    problems:core.Problems
    m:Input_Map
    input_map_make(&m,&info,"input.mirai",`{"actions":[{"name":"hit","kind":"Button","bindings":[{"mouse_button":"Left"}]},{"name":"jump","kind":"Button","bindings":[{"key":"J"}]}]}`,&problems)
    testing.expect(t,m.built && input_map_has(&m,MOVE,.Axis2) && input_map_has(&m,JUMP,.Button) && input_map_has(&m,HIT,.Button))
    testing.expect_value(t,m.binding_count,u32(4))
    testing.expect_value(t,problems.count,0)

    device:=core.Input{keys_down={.W,.J,.Space},keys_pressed={.W,.J,.Space},mouse_down={.Left},mouse_pressed={.Left}}
    actions:Actions
    actions_update(&actions,&m,&device)
    testing.expect(t,action_vector(&actions,MOVE)==[2]f32{0,1})
    testing.expect(t,action_pressed(&actions,JUMP),"input.mirai binds jump to J")
    testing.expect(t,action_pressed(&actions,HIT))
    testing.expect_value(t,actions.count,u32(41))

    device={keys_down={.Space},keys_pressed={.Space}}
    actions_update(&actions,&m,&device)
    testing.expect(t,!action_down(&actions,JUMP),"Space is no longer a binding of jump")
    testing.expect(t,action_released(&actions,HIT))
    testing.expect(t,action(&actions,Action(50))=={},"a value the map does not have is released")
}

// A name in input.mirai that the code does not declare is a problem that
// says which, in which file and how to fix it; the file is not read and the
// defaults stay. An action with neither a default nor an entry is one too.
@(test)
what_the_code_does_not_declare_is_a_problem :: proc(t:^testing.T) {
    names:=TEST_NAMES
    storages:=[]core.Storage_Info{{name="Test_Defaults",type=Test_Defaults,info=type_info_of(Test_Defaults),default=test_defaults}}
    info:=core.World_Info{names=names[:],storages=storages}
    problems:core.Problems
    m:Input_Map
    input_map_make(&m,&info,"demo/input.mirai",`{"actions":[{"name":"jump","kind":"Button","bindings":[{"key":"J"}]},{"name":"fire","kind":"Button","bindings":[{"key":"F"}]}]}`,&problems)
    unknown:=core.problem_find(&problems,core.NONE,"input.unknown_action")
    if testing.expect(t,unknown!=nil) {
        text:=core.problem_text(unknown)
        for want in ([]string{`demo/input.mirai names the action "fire"`,"move, jump, hit","FIRE :: input.Action("}) {
            testing.expectf(t,strings.contains(text,want),"%q is not in %q",want,text)
        }
    }
    testing.expect(t,input_map_has(&m,JUMP,.Button) && m.bindings[m.binding_count-1].codes[0]=={.Key,u8(core.Key.Space)},"the file was not read")
    unbound:=core.problem_find(&problems,core.NONE,"input.action_unbound")
    testing.expect(t,unbound!=nil && strings.contains(core.problem_text(unbound),`"hit" (game/game.odin:7)`))
    testing.expect(t,input_map_has(&m,HIT,.Button),"an action without bindings is still read, released")

    problems={}
    error,at:=input_map_parse(&m,&info,`{"actions":[{"name":"jump","kind":"Trigger"}]}`)
    testing.expect(t,error==.Unknown_Kind && at=="jump")
}

// What the player rebinds goes to its options as the actions that differ from
// the code and the project, and read over them gives the same map.
@(test)
the_bindings_the_player_changed_come_back_over_those_of_the_project :: proc(t:^testing.T) {
    names:=TEST_NAMES
    storages:=[]core.Storage_Info{{name="Test_Defaults",type=Test_Defaults,info=type_info_of(Test_Defaults),default=test_defaults}}
    info:=core.World_Info{names=names[:],storages=storages}
    problems:core.Problems
    PROJECT :: `{"actions":[{"name":"hit","kind":"Button","bindings":[{"mouse_button":"Left"}]}]}`
    below,m:Input_Map
    input_map_make(&below,&info,"input.mirai",PROJECT,&problems)
    m=below
    text,ok:=input_map_text(&m,&below,&info)
    testing.expect(t,ok && text=="","an untouched map writes nothing")

    input_map_unbind(&m,JUMP)
    testing.expect(t,input_map_bind(&m,JUMP,binding_key(.J)) && input_map_bind(&m,JUMP,binding_gamepad_button(.South,1)))
    m.hold_ticks=40
    text,ok=input_map_text(&m,&below,&info)
    testing.expect(t,ok && strings.contains(text,`"jump"`) && !strings.contains(text,`"move"`) && !strings.contains(text,`"hit"`),text)

    again:Input_Map
    input_map_make(&again,&info,"input.mirai",PROJECT,&problems,"options/input.mirai",text)
    testing.expect_value(t,problems.count,0)
    testing.expect_value(t,again.hold_ticks,u32(40))
    actions:Actions
    device:=core.Input{keys_down={.J},keys_pressed={.J}}
    actions_update(&actions,&again,&device)
    testing.expect(t,action_pressed(&actions,JUMP),"the options bind jump to J")
    device={keys_down={.Space},keys_pressed={.Space}}
    actions_update(&actions,&again,&device)
    testing.expect(t,!action_down(&actions,JUMP),"Space is the binding of the project, which the options replaced")
    same:=again
    unchanged,_:=input_map_text(&same,&again,&info)
    testing.expect_value(t,unchanged,"")
}
