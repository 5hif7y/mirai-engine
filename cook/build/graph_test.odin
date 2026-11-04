package build

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "mirai:project"

@(private="file")
graph_generate :: proc(t:^testing.T,core_source,game_source:string) -> (text:string,ok:bool) {
    folder,error:=os.make_directory_temp("","mirai-graph-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    defer os.remove_all(folder)
    engine:=project.path(folder,"engine",allocator=context.temp_allocator)
    game:=project.path(folder,"project",allocator=context.temp_allocator)
    for path in ([]string{project.path(engine,"core",allocator=context.temp_allocator),project.path(game,"game",allocator=context.temp_allocator)}) {
        if !testing.expect(t,os.make_directory_all(path)==nil) {return}
    }
    if !testing.expect(t,os.write_entire_file(project.path(engine,"core","data.odin",allocator=context.temp_allocator),core_source)==nil) {return}
    if !testing.expect(t,os.write_entire_file(project.path(game,"game","game.odin",allocator=context.temp_allocator),game_source)==nil) {return}
    p:=project.Project{root=game,engine_root=engine}
    output:=world_generate(&p,context.temp_allocator)
    if !testing.expectf(t,len(output.errors)==0,"%v",output.errors) {return}
    return output.game_world,true
}

// The edges of a loop and phase of the generated world, as "first>then" by
// the names of the steps.
@(private="file")
graph_edges :: proc(text,loop_phase:string) -> (edges:map[string]bool,steps:[]string) {
    edges=make(map[string]bool,context.temp_allocator)
    calls:=make([dynamic]string,context.temp_allocator)
    at:=strings.index(text,strings.concatenate({loop_phase," :: proc("},context.temp_allocator))
    if at<0 {return}
    body:=text[at:]
    body=body[:strings.index(body,"\n}")]
    for line in strings.split_lines(body,context.temp_allocator) {
        trimmed:=strings.trim_space(line)
        if strings.has_prefix(trimmed,"call_") {append(&calls,trimmed[len("call_"):strings.index_byte(trimmed,'(')])}
    }
    steps=calls[:]
    prefix:=strings.concatenate({"@(rodata) edges_",loop_phase,":="},context.temp_allocator)
    start:=strings.index(text,prefix)
    if start<0 {return}
    list:=text[start:]
    list=list[strings.index(list,"Step_Edge{")+len("Step_Edge{"):]
    list=list[:strings.index(list,"}}")+1]
    for pair in strings.split(list,"},",context.temp_allocator) {
        numbers:=strings.split(strings.trim(pair,"{}"),",",context.temp_allocator)
        first,_:=strconv.parse_int(numbers[0])
        then,_:=strconv.parse_int(numbers[1])
        edges[fmt.tprintf("%s>%s",steps[first],steps[then])]=true
    }
    return
}

@(private="file")
edges_are :: proc(t:^testing.T,edges:map[string]bool,expected:..string,loc:=#caller_location) {
    testing.expectf(t,len(edges)==len(expected),"edges %v, expected %v",edges,expected,loc=loc)
    for e in expected {testing.expectf(t,edges[e],"edges %v lack %s",edges,e,loc=loc)}
}

// Two steps wait for each other only when one writes what the other reads or
// writes; readers of a same table, and writers of different ones, run at once.
@(test)
steps_that_touch_nothing_in_common_have_no_edge :: proc(t:^testing.T) {
    core_source:=`package core
@(component) Position :: struct {x:f32}
@(component) Speed :: struct {x:f32}
@(component) Health :: struct {value:f32}
@(storage) Clock :: struct {tick:u64}
@(storage,queue) Hits :: struct {count:int}
`
    game_source:=`package game
import "mirai:core"
@(step="fixed") speeds_read :: proc(speeds:core.Read(core.Speed),clock:core.Clock) {}
@(step="fixed") speeds_read_too :: proc(speeds:core.Read(core.Speed),clock:core.Ref(core.Clock)) {}
@(step="fixed") healths_write :: proc(healths:^core.Table(core.Health)) {}
@(step="fixed") positions_move :: proc(positions:^core.Table(core.Position),speeds:core.Read(core.Speed)) {}
@(step="fixed") positions_look :: proc(positions:core.Read(core.Position)) {}
@(step="fixed") hits_push :: proc(hits:^core.Hits) {}
@(step="fixed") hits_push_too :: proc(hits:^core.Hits,healths:core.Read(core.Health)) {}
@(step="fixed") clock_tick :: proc(clock:^core.Clock) {}
`
    text,ok:=graph_generate(t,core_source,game_source)
    if !ok {return}
    edges,steps:=graph_edges(text,"game_fixed")
    testing.expect_value(t,len(steps),8)
    // hits_push_too after healths_write (it reads what that writes) and after
    // hits_push (both push to one queue); the clock is read by value and by
    // reference before it is written.
    edges_are(t,edges,"positions_move>positions_look","hits_push>hits_push_too","healths_write>hits_push_too","speeds_read>clock_tick","speeds_read_too>clock_tick")
    testing.expect(t,strings.contains(text,"info.edges[.Game][.Fixed]=edges_game_fixed[:]"),text)
    testing.expect(t,strings.contains(text,"info.parallel=true"),text)
}

// What creates or destroys entities, or works on the whole World, waits for
// everything before it and everything after it waits for it; a later stage
// waits for the earlier, and so do after and before inside a stage, without
// the edges that other edges already imply.
@(test)
barriers_stages_and_after_and_before_are_edges :: proc(t:^testing.T) {
    core_source:=`package core
@(component) Position :: struct {x:f32}
@(component) Speed :: struct {x:f32}
@(component) Health :: struct {value:f32}
@(component) Kind :: struct {value:u8}
`
    game_source:=`package game
import "mirai:core"
@(step="fixed") positions_write :: proc(positions:^core.Table(core.Position)) {}
@(step="fixed") speeds_write :: proc(speeds:^core.Table(core.Speed)) {}
@(step="fixed") things_spawn :: proc(entities:^core.Entities) {}
@(step="fixed") healths_write :: proc(healths:^core.Table(core.Health)) {}
@(step="fixed",before="healths_write") kinds_write :: proc(kinds:^core.Table(core.Kind)) {}
@(step="fixed",stage="react") speeds_look :: proc(speeds:core.Read(core.Speed)) {}
@(step="fixed",stage="react",after="speeds_look") positions_look :: proc(positions:core.Read(core.Position)) {}
`
    text,ok:=graph_generate(t,core_source,game_source)
    if !ok {return}
    edges,steps:=graph_edges(text,"game_fixed")
    testing.expect_value(t,len(steps),7)
    edges_are(t,edges,
        "positions_write>things_spawn","speeds_write>things_spawn",
        "things_spawn>kinds_write","kinds_write>healths_write",
        "healths_write>speeds_look","speeds_look>positions_look")
}

// A table that locks rows of another writes them; a function of the
// application runs on the thread of the loop and waits for every other one,
// and so does a storage of the application, which also waits for those of
// the same storage.
@(test)
locks_and_the_application_are_conflicts :: proc(t:^testing.T) {
    core_source:=`package core
@(component,shared) Transform :: struct {x:f32}
@(component,locks="Transform") Body :: struct {mass:f32}
@(component) Speed :: struct {x:f32}
@(storage,host) Scene :: struct {count:int}
@(storage,host) Mixer :: struct {count:int}
`
    game_source:=`package game
import "mirai:core"
import "mirai:host"
@(step="frame") bodies_write :: proc(bodies:^core.Table(core.Body)) {}
@(step="frame") transforms_look :: proc(transforms:core.Read(core.Transform)) {}
@(step="frame") speeds_write :: proc(speeds:^core.Table(core.Speed)) {}
@(step="frame") scene_look :: proc(scene:core.Ref(core.Scene)) {}
@(step="frame") mixer_write :: proc(mixer:^core.Mixer) {}
@(step="frame") app_use :: proc(app:^host.App) {}
@(step="frame") scene_write :: proc(scene:^core.Scene) {}
`
    text,ok:=graph_generate(t,core_source,game_source)
    if !ok {return}
    edges,_:=graph_edges(text,"game_frame")
    edges_are(t,edges,"bodies_write>transforms_look","scene_look>app_use","mixer_write>app_use","app_use>scene_write")
    Main :: struct {name:string,main:bool}
    for c in ([]Main{{"bodies_write",false},{"speeds_write",false},{"scene_look",true},{"mixer_write",true},{"app_use",true}}) {
        testing.expectf(t,strings.contains(text,fmt.tprintf("call_%s,%v}}",c.name,c.main)),"%s should have main %v",c.name,c.main)
    }
}

// Steps that all conflict wait in a chain: the order of the loop, with an
// edge only to the next one.
@(test)
a_chain_of_conflicts_keeps_only_the_edges_to_the_next :: proc(t:^testing.T) {
    core_source:=`package core
@(component,shared) Position :: struct {x:f32}
`
    game_source:=`package game
import "mirai:core"
@(step="late") first_write :: proc(positions:^core.Table(core.Position)) {}
@(step="late") second_write :: proc(positions:^core.Table(core.Position)) {}
@(step="late") third_write :: proc(positions:^core.Table(core.Position)) {}
`
    text,ok:=graph_generate(t,core_source,game_source)
    if !ok {return}
    edges,_:=graph_edges(text,"game_late")
    edges_are(t,edges,"first_write>second_write","second_write>third_write")
}
