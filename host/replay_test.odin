package host

import "core:testing"
import "mirai:core"

@(private) Replay_World :: struct {time:core.Time,frame:core.Frame_Time,problems:core.Problems,corrected:bool}

@(private)
replay_world_fixed :: proc(world,shared,editor,app_data:rawptr) {
    w:=cast(^Replay_World)world
    core.report(&w.problems,core.NONE,"test.always","every tick fails")
    if w.corrected {core.report(&w.problems,core.NONE,"test.corrected","only the corrected ticks fail")}
}

@(test)
a_resimulated_tick_counts_a_known_problem_once_and_keeps_a_new_one :: proc(t:^testing.T) {
    storages:=[3]core.Storage_Info{
        {type=core.Time,info=type_info_of(core.Time),offset=offset_of(Replay_World,time)},
        {type=core.Frame_Time,info=type_info_of(core.Frame_Time),offset=offset_of(Replay_World,frame)},
        {type=core.Problems,info=type_info_of(core.Problems),offset=offset_of(Replay_World,problems)},
    }
    info:core.World_Info
    info.storages=storages[:]
    info.loops[.Game][.Fixed]=replay_world_fixed
    app:=App{info=&info,allocator=context.allocator}
    world:Replay_World
    for _ in 0..<3 {app_tick_replay(&app,&world,0)}
    always:=core.problem_find(&world.problems,core.NONE,"test.always")
    if !testing.expect(t,always!=nil) {return}
    testing.expect_value(t,always.count,u64(3))
    serial:=world.problems.serial
    // A correction runs ticks 1 and 2 again, and the corrected state fails in a new way.
    world.time.tick,world.time.resimulating,world.corrected=1,true,true
    for _ in 0..<2 {app_tick_replay(&app,&world,0)}
    testing.expect_value(t,always.count,u64(3))
    testing.expect_value(t,always.last,serial)
    corrected:=core.problem_find(&world.problems,core.NONE,"test.corrected")
    testing.expect(t,corrected!=nil && corrected.count==1,"a problem only the corrected ticks have is new")
    testing.expect(t,!world.problems.resimulating && world.time.tick==3)
    world.time.resimulating=false
    app_tick_replay(&app,&world,0)
    testing.expect_value(t,always.count,u64(4))
    testing.expect_value(t,corrected.count,u64(2))
}
