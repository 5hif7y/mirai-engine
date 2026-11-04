package camera

import "core:testing"
import "mirai:core"
import input "mirai:engine/input"
import render "mirai:engine/render"

// The body of the player has to go past the margin into the box for the
// trigger to ask for its sky and sun, once, and past it out to leave.
@(test)
a_trigger_turns_its_sky_on_once_the_body_is_well_inside :: proc(t:^testing.T) {
    es:core.Entities;core.entities_init(&es);defer core.entities_destroy(&es)
    triggers:core.Table(Environment_Trigger);core.table_init(&triggers,"Environment_Trigger");defer core.table_destroy(&triggers)
    worlds:core.Table(core.World_Transform);core.table_init(&worlds,"World_Transform");defer core.table_destroy(&worlds)
    seats:core.Table(input.Seat);core.table_init(&seats,"Seat");defer core.table_destroy(&seats)
    drivables:core.Table(input.Drivable);core.table_init(&drivables,"Drivable");defer core.table_destroy(&drivables)
    requests:render.Environment_Requests;defer delete(requests.queue.items)
    state:=input.Seats{local_count=1}

    seat,body,box,sky:=core.create(&es),core.create(&es),core.create(&es),core.create(&es)
    core.add(&seats,seat,input.Seat{})
    core.add(&drivables,body,input.Drivable{seat=seat})
    core.add(&triggers,box,Environment_Trigger{sky=sky,extents={2,2,2},seconds=1})
    core.add(&worlds,box,core.World_Transform{transform={rotation=1,scale=1}})
    core.add(&worlds,body,core.World_Transform{transform={position={1.9,0,0},rotation=1,scale=1}})
    core.table_settle(&seats,&es);core.table_settle(&drivables,&es);core.table_settle(&triggers,&es);core.table_settle(&worlds,&es)
    step :: proc(triggers:^core.Table(Environment_Trigger),worlds:^core.Table(core.World_Transform),state:^input.Seats,seats:^core.Table(input.Seat),drivables:^core.Table(input.Drivable),requests:^render.Environment_Requests,x:f32,es:^core.Entities) {
        core.get(worlds,core.entity_at(core.read(worlds),1)).position.x=x
        environment_triggers(triggers,core.read(worlds),core.ref(state),core.read(seats),core.read(drivables),requests)
        core.table_settle(triggers,es)
    }

    step(&triggers,&worlds,&state,&seats,&drivables,&requests,1.9,&es)
    testing.expect_value(t,len(requests.queue.items),0)
    step(&triggers,&worlds,&state,&seats,&drivables,&requests,1.5,&es)
    testing.expect_value(t,len(requests.queue.items),1)
    testing.expect_value(t,requests.queue.items[0].sky,sky)
    step(&triggers,&worlds,&state,&seats,&drivables,&requests,2.1,&es)
    step(&triggers,&worlds,&state,&seats,&drivables,&requests,1.5,&es)
    testing.expect_value(t,len(requests.queue.items),1)
    step(&triggers,&worlds,&state,&seats,&drivables,&requests,2.4,&es)
    step(&triggers,&worlds,&state,&seats,&drivables,&requests,1.5,&es)
    testing.expect_value(t,len(requests.queue.items),2)
}
