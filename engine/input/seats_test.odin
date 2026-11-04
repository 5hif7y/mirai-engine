package input

import "core:fmt"
import "core:strings"
import "core:testing"
import "mirai:core"

@(private="file") TEST_MOVE :: Action(0)
@(private="file") TEST_JUMP :: Action(2)

@(private="file")
test_bindings :: proc() -> (bindings:Input_Map) {
    input_map_action(&bindings,TEST_JUMP,.Button)
    input_map_bind(&bindings,TEST_JUMP,binding_key(.Space))
    input_map_bind(&bindings,TEST_JUMP,binding_gamepad_button(.South))
    input_map_action(&bindings,TEST_MOVE,.Axis2)
    input_map_bind(&bindings,TEST_MOVE,binding_keys(.A,.D,.S,.W))
    return
}

@(test)
devices_reach_each_local_player :: proc(t:^testing.T) {
    device:=core.Input{keys_down={.Space},keys_pressed={.Space}}
    device.gamepads[1]={connected=true,down={.South},pressed={.South}}
    testing.expect(t,slot_input(device,0,2,0).keys_down=={.Space})
    testing.expect(t,slot_input(device,1,2,0).keys_down=={})
    testing.expect(t,!slot_input(device,0,2,0).gamepads[1].connected)
    testing.expect(t,slot_input(device,1,2,0).gamepads[1].connected)
    testing.expect(t,slot_input(device,0,1,0).gamepads[1].connected)

    bindings:=test_bindings()
    first,second:Seat
    own:=slot_input(device,0,2,0)
    seat_feed(&first,&own,&bindings,false)
    own=slot_input(device,1,2,0)
    seat_feed(&second,&own,&bindings,false)
    testing.expect(t,action_pressed(&first.actions,TEST_JUMP))
    testing.expect(t,action_pressed(&second.actions,TEST_JUMP))
}

@(test)
focus_and_driving_wait_for_held_buttons :: proc(t:^testing.T) {
    es:core.Entities
    core.entities_init(&es)
    defer core.entities_destroy(&es)
    first,second,body:=core.create(&es),core.create(&es),core.create(&es)
    bindings:=test_bindings()
    drivables:core.Table(Drivable)
    core.table_init(&drivables,"Drivable")
    seats:core.Table(Seat)
    core.table_init(&seats,"Seat")
    defer core.table_destroy(&seats)
    core.add(&seats,first,Seat{})
    core.add(&seats,second,Seat{slot=1})
    core.table_settle(&seats,&es)
    defer core.table_destroy(&drivables)
    core.add(&drivables,body,Drivable{})
    core.table_settle(&drivables,&es)
    state:Seats
    problems:core.Problems
    a:=Apply{es=&es,state=&state,drivables=&drivables,seats=&seats,problems=&problems}
    read:=core.read(&seats)

    // Space and W held while the keyboard is with the first player.
    device:=core.Input{keys_down={.Space,.W},keys_pressed={.Space,.W}}
    tick :: proc(seats:^core.Table(Seat),first,second:core.Entity,device:core.Input,focus:int,bindings:^Input_Map,moved:=false) {
        for e,slot in ([2]core.Entity{first,second}) {
            own:=slot_input(device,slot,2,focus)
            seat_feed(core.get(seats,e),&own,bindings,moved && slot==focus)
        }
    }
    tick(&seats,first,second,device,0,&bindings)
    testing.expect(t,seat_pressed(read,first,TEST_JUMP))
    testing.expect(t,!seat_down(read,second,TEST_JUMP))

    // The keyboard moves to the second player: the first sees the release,
    // the second waits for it; the axis moves on at once.
    device.keys_pressed={}
    tick(&seats,first,second,device,1,&bindings,true)
    testing.expect(t,seat_released(read,first,TEST_JUMP))
    testing.expect(t,!seat_down(read,second,TEST_JUMP))
    testing.expect(t,seat_vector(read,second,TEST_MOVE)==[2]f32{0,1})

    device={keys_released={.Space,.W}}
    tick(&seats,first,second,device,1,&bindings)
    device={keys_down={.Space},keys_pressed={.Space}}
    tick(&seats,first,second,device,1,&bindings)
    testing.expect(t,seat_pressed(read,second,TEST_JUMP))

    // Driving a body while jump is held: it waits for its release.
    device.keys_pressed={}
    tick(&seats,first,second,device,1,&bindings)
    request_apply(&a,{kind=.Drive,seat=second,entity=body})
    testing.expect(t,seat_of(core.read(&drivables),body)==second)
    testing.expect(t,!seat_down(read,second,TEST_JUMP))
    device={keys_released={.Space}}
    tick(&seats,first,second,device,1,&bindings)
    device={keys_down={.Space},keys_pressed={.Space}}
    tick(&seats,first,second,device,1,&bindings)
    testing.expect(t,seat_pressed(read,second,TEST_JUMP))

    // A block takes the action; once given back, the held button waits for its release.
    request_apply(&a,{kind=.Block_Add,owner=body,seat=second,mask=ALL_ACTIONS})
    blocks_apply(&seats,&state)
    testing.expect(t,!seat_down(read,second,TEST_JUMP))
    testing.expect(t,!pressed(Players{read,core.read(&drivables)},body,TEST_JUMP))
    request_apply(&a,{kind=.Block_Remove,owner=body})
    blocks_apply(&seats,&state)
    testing.expect(t,!seat_down(read,second,TEST_JUMP))
    device={keys_released={.Space}}
    tick(&seats,first,second,device,1,&bindings)
    device={keys_down={.Space},keys_pressed={.Space}}
    tick(&seats,first,second,device,1,&bindings)
    testing.expect(t,pressed(Players{read,core.read(&drivables)},body,TEST_JUMP))
    testing.expect_value(t,problems.count,0)
}

@(test)
a_block_of_no_seat_takes_every_local_seat :: proc(t:^testing.T) {
    es:core.Entities
    core.entities_init(&es)
    defer core.entities_destroy(&es)
    first,second,remote,menu:=core.create(&es),core.create(&es),core.create(&es),core.create(&es)
    bindings:=test_bindings()
    drivables:core.Table(Drivable)
    core.table_init(&drivables,"Drivable")
    defer core.table_destroy(&drivables)
    seats:core.Table(Seat)
    core.table_init(&seats,"Seat")
    defer core.table_destroy(&seats)
    core.add(&seats,first,Seat{})
    core.add(&seats,second,Seat{slot=1})
    core.add(&seats,remote,Seat{peer=7})
    core.table_settle(&seats,&es)
    state:Seats
    problems:core.Problems
    a:=Apply{es=&es,state=&state,drivables=&drivables,seats=&seats,problems=&problems}
    read:=core.read(&seats)
    blocked :: proc(seats:^core.Table(Seat),e:core.Entity) -> Action_Mask {return seats.values[core.row_of(seats,e)].blocked}
    device:=core.Input{keys_down={.Space},keys_pressed={.Space}}
    seat_feed(core.get(&seats,first),&device,&bindings,false)
    request_apply(&a,{kind=.Block_Add,owner=menu,mask=ALL_ACTIONS})
    blocks_apply(&seats,&state)
    testing.expect(t,blocking(&state,menu))
    testing.expect(t,blocked(&seats,first)==ALL_ACTIONS && blocked(&seats,second)==ALL_ACTIONS)
    testing.expect_value(t,blocked(&seats,remote),Action_Mask(0))
    testing.expect(t,!seat_down(read,first,TEST_JUMP))
    // Given back, the button held through the block waits for its release.
    request_apply(&a,{kind=.Block_Remove,owner=menu})
    blocks_apply(&seats,&state)
    testing.expect(t,blocked(&seats,first)==0 && !seat_down(read,first,TEST_JUMP))
    // The owner goes: so does its block.
    request_apply(&a,{kind=.Block_Add,owner=menu,mask=ALL_ACTIONS})
    core.destroy(&es,menu)
    upkeep(&a)
    blocks_apply(&seats,&state)
    testing.expect(t,!blocking(&state,menu) && blocked(&seats,second)==0)
    testing.expect_value(t,problems.count,0)
}

@(test)
refused_drives_report_the_seat_and_how_to_fix_them :: proc(t:^testing.T) {
    es:core.Entities
    core.entities_init(&es)
    defer core.entities_destroy(&es)
    first,second,body,prop:=core.create(&es),core.create(&es),core.create(&es),core.create(&es)
    drivables:core.Table(Drivable)
    core.table_init(&drivables,"Drivable")
    seats:core.Table(Seat)
    core.table_init(&seats,"Seat")
    defer core.table_destroy(&seats)
    core.add(&seats,first,Seat{})
    core.add(&seats,second,Seat{slot=1})
    core.table_settle(&seats,&es)
    defer core.table_destroy(&drivables)
    core.add(&drivables,body,Drivable{})
    core.table_settle(&drivables,&es)
    state:Seats
    problems:core.Problems
    a:=Apply{es=&es,state=&state,drivables=&drivables,seats=&seats,problems=&problems}

    request_apply(&a,{kind=.Drive,seat=first,entity=body})
    request_apply(&a,{kind=.Drive,seat=second,entity=body})
    request_apply(&a,{kind=.Drive,seat=second,entity=body})
    request_apply(&a,{kind=.Drive,seat=second,entity=prop})
    testing.expect_value(t,seat_of(core.read(&drivables),body),first)
    testing.expect_value(t,problems.count,2)
    taken:=core.problem_find(&problems,second,"input.body_taken")
    if testing.expect(t,taken!=nil) {
        testing.expect_value(t,taken.count,u64(2))
        testing.expect(t,strings.contains(core.problem_text(taken),fmt.tprintf("0x%016x",u64(body))))
        testing.expect(t,strings.contains(core.problem_text(taken),"release it first"))
    }
    missing:=core.problem_find(&problems,second,"input.not_drivable")
    testing.expect(t,missing!=nil && strings.contains(core.problem_text(missing),"add one to the body"))
}


// A client takes only the bodies it owns, and lets go of one the server gave
// someone else (it became core.Remote) to drive the one it got instead.
@(test)
a_client_lets_go_of_what_the_server_took_and_takes_only_what_it_owns :: proc(t:^testing.T) {
    es:core.Entities
    core.entities_init(&es)
    defer core.entities_destroy(&es)
    seat,person,dog:=core.create(&es),core.create(&es),core.create(&es)
    drivables:core.Table(Drivable)
    seats:core.Table(Seat)
    remotes:core.Table(core.Remote)
    core.table_init(&drivables,"Drivable")
    core.table_init(&seats,"Seat")
    core.table_init(&remotes,"Remote")
    defer core.table_destroy(&drivables)
    defer core.table_destroy(&seats)
    defer core.table_destroy(&remotes)
    core.add(&seats,seat,Seat{})
    core.add(&drivables,person,Drivable{seat=seat})
    core.add(&drivables,dog,Drivable{})
    core.add(&remotes,dog,core.Remote{})
    core.table_settle(&seats,&es)
    core.table_settle(&drivables,&es)
    core.table_settle(&remotes,&es)
    state:Seats
    problems:core.Problems
    a:=Apply{es=&es,state=&state,drivables=&drivables,seats=&seats,role=.Client,elsewhere=core.read(&remotes),problems=&problems}

    request_apply(&a,{kind=.Drive,seat=seat,entity=dog})
    testing.expect_value(t,body_of(core.read(&drivables),seat),person)
    testing.expect(t,core.problem_find(&problems,seat,"input.server_decides")!=nil)

    // The server gives the dog to this client and the person to someone else.
    core.remove(&remotes,dog)
    core.add(&remotes,person,core.Remote{})
    core.table_settle(&remotes,&es)
    a.elsewhere=core.read(&remotes)
    count:=problems.count
    request_apply(&a,{kind=.Release,seat=seat})
    request_apply(&a,{kind=.Drive,seat=seat,entity=dog})
    testing.expect_value(t,body_of(core.read(&drivables),seat),dog)
    testing.expect_value(t,seat_of(core.read(&drivables),person),core.NONE)
    testing.expect_value(t,problems.count,count)
}
