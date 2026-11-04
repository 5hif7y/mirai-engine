package mirai_net

import "core:testing"

// A client that keeps its tick as the engine does: each frame adds its time,
// faster or slower by the dilation the clock asked for, and the clock jumps
// it when it says so. The server is at tick 1000 at time 0.
@(private="file")
Follower :: struct {
    h:^Host,
    local:f64,
    dilation:f64,
    last:i64,          // the last tick simulated
    shown:f64,         // server tick shown in the state of the last tick simulated
    backward:int,      // calls that moved the tick back once it was placed
    display_back:int,  // ticks shown at an older server tick than the one before
    largest_dilation:f64,
}

@(private="file")
follower_init :: proc(f:^Follower) {
    f^={h=new(Host)}
    f.h.front.clock={rate=60,lead=2,delay=2.5,display_jump=CLOCK_JUMP_TICKS,display_max=CLOCK_MAX_DILATION}
}

@(private="file")
follower_frame :: proc(f:^Follower,now,dt,rtt,jitter:f64) {
    clock_sync(&f.h.front.clock,{valid=true,server_tick=u32(1000+(now-rtt*0.5)*60),rtt=rtt,jitter=jitter,time=now})
    f.local+=dt*60*max(1+f.dilation,0)
    placed:=f.h.front.clock.placed
    shift,dilation:=clock_advance(f.h,now,f.local)
    if placed && shift<0 {f.backward+=1}
    f.local+=f64(shift)
    f.last+=shift
    f.dilation=dilation
    if !placed {return}
    f.largest_dilation=max(f.largest_dilation,abs(dilation))
    for f.last<i64(f.local) {
        f.last+=1
        shown:=clock_interpolation_tick(f.h,u32(f.last))
        if shown<f.shown {f.display_back+=1}
        f.shown=shown
    }
}

// The round trip and the jitter the connection measures rise with a spike and
// fall after it, an eighth and a sixteenth a sample.
@(test)
the_tick_of_the_client_never_goes_back_when_a_jitter_spike_ends :: proc(t:^testing.T) {
    f:Follower
    follower_init(&f);defer free(f.h)
    rtt,jitter:=0.1,0.004
    for frame in 0..<2400 {
        spike:=frame>=300 && frame<900
        rtt+=((spike?0.3:0.1)-rtt)*0.125
        jitter+=((spike?0.3:0.004)-jitter)*0.0625
        follower_frame(&f,f64(frame)/60,1.0/60,rtt,jitter)
    }
    c:=clock_state(f.h)
    testing.expect_value(t,f.backward,0)
    testing.expect_value(t,f.display_back,0)
    // The lead the spike asks for rises faster than running faster follows, and the display catches
    // up with its end the same way: a jump forward each.
    testing.expect(t,c.jumps<=2)
    testing.expect(t,f.largest_dilation<=CLOCK_MAX_DILATION)
    // Settled again: ahead of the server by half the trip, twice the jitter and the lead.
    lead:=f64(f.last)-(1000+2399)
    testing.expectf(t,lead>=4 && lead<=7,"lead %v",lead)
    behind:=c.server-c.display
    testing.expectf(t,behind>=5 && behind<=7,"remote objects shown %v ticks behind the server",behind)
}

// The frames stop for a second: the client is far behind, and goes on from
// where it should be in one jump forward.
@(test)
a_client_far_behind_jumps_forward_and_never_back :: proc(t:^testing.T) {
    f:Follower
    follower_init(&f);defer free(f.h)
    for frame in 0..<600 {follower_frame(&f,f64(frame)/60,1.0/60,0.1,0.004)}
    before:=f.last
    for frame in 600..<660 {
        now:=f64(frame)/60
        clock_sync(&f.h.front.clock,{valid=true,server_tick=u32(1000+(now-0.05)*60),rtt=0.1,jitter=0.004,time=now})
    }
    for frame in 660..<1200 {follower_frame(&f,f64(frame)/60,1.0/60,0.1,0.004)}
    c:=clock_state(f.h)
    testing.expect_value(t,f.backward,0)
    testing.expect_value(t,f.display_back,0)
    testing.expect(t,c.jumps>=1 && c.jumps<=2)
    testing.expect(t,f.last-before>=595)
    lead:=f64(f.last)-(1000+1199)
    testing.expectf(t,lead>=4 && lead<=7,"lead %v",lead)
}

// While the jitter rises the display falls behind slower than real time, and
// it catches up faster when the jitter falls, without going back.
@(test)
remote_objects_are_shown_further_behind_with_more_jitter :: proc(t:^testing.T) {
    f:Follower
    follower_init(&f);defer free(f.h)
    jitter:=0.004
    deepest:=0.0
    for frame in 0..<2400 {
        jitter+=((frame>=600 && frame<1500?0.04:0.004)-jitter)*0.0625
        follower_frame(&f,f64(frame)/60,1.0/60,0.1,jitter)
        if frame==1499 {deepest=clock_state(f.h).server-clock_state(f.h).display}
    }
    c:=clock_state(f.h)
    testing.expect_value(t,f.display_back,0)
    testing.expectf(t,deepest>=9 && deepest<=11,"with 40 ms of jitter, %v ticks behind",deepest)
    testing.expectf(t,c.server-c.display<=7,"%v ticks behind once the jitter fell",c.server-c.display)
}

// The server pauses, then runs at half speed: its tick as the client estimates
// it stands still while paused and goes at the server's pace after, and so
// does the tick the client should be at.
@(test)
the_estimate_of_the_server_stands_still_while_it_pauses_and_follows_its_scale :: proc(t:^testing.T) {
    h:=new(Host);defer free(h)
    h.front.clock={rate=60,lead=2,delay=2.5,scale=1}
    rtt:=0.1
    server,local,dilation:=1000.0,0.0,0.0
    frame :: proc(h:^Host,now,server,rtt:f64,local,dilation:^f64,paused:bool,scale:f32) {
        pace:=paused?0:60*f64(scale)
        clock_sync(&h.front.clock,{valid=true,server_tick=u32(server-rtt*0.5*pace),rtt=rtt,jitter=0.002,time=now,paused=paused,scale=scale})
        local^+=pace/60*max(1+dilation^,0)
        shift,next:=clock_advance(h,now,local^)
        local^+=f64(shift)
        dilation^=next
    }
    now:=0.0
    for _ in 0..<300 {
        now+=1.0/60
        server+=1
        frame(h,now,server,rtt,&local,&dilation,false,1)
    }
    paused_at:=server
    wanted:=clock_target(&h.front.clock)
    for _ in 0..<120 {
        now+=1.0/60
        frame(h,now,server,rtt,&local,&dilation,true,1)
        testing.expectf(t,h.front.clock.server<=paused_at+1,"the server stands at %v and is estimated at %v",paused_at,h.front.clock.server)
        testing.expect(t,clock_target(&h.front.clock)<=wanted+0.5,"the tick the client should be at does not run ahead")
    }
    for _ in 0..<240 {
        now+=1.0/60
        server+=0.5
        frame(h,now,server,rtt,&local,&dilation,false,0.5)
    }
    testing.expectf(t,abs(h.front.clock.server-server)<1,"at half speed the server is at %v and estimated at %v",server,h.front.clock.server)
    testing.expect(t,!h.front.clock.paused && h.front.clock.scale==0.5)
}

// A display that fell behind jumps at display_jump instead of 30 ticks, and
// catches up at display_dilation instead of a tenth.
@(test)
the_display_jumps_and_dilates_as_the_replication_asks :: proc(t:^testing.T) {
    h:=new(Host)
    defer free(h)
    h.desc.tick_rate=128
    h.desc.replication.input_lead=5
    h.desc.replication.interpolation_delay=2.5
    h.desc.replication.display_jump=0.15
    h.desc.replication.display_dilation=0.2
    clock_init(&h.front.clock,h)
    c:=&h.front.clock
    testing.expect(t,abs(c.display_jump-19.2)<1e-4 && abs(c.display_max-0.2)<1e-6)
    clock_sync(c,{valid=true,server_tick=1000,rtt=0.1,jitter=0,time=0})
    // The client's tick where the clock puts it, then still.
    shift,_:=clock_advance(h,0,0)
    local:=f64(shift)
    clock_advance(h,0.001,local)
    // 25 ticks behind: under the default 30, over these 19.2.
    c.display-=25
    jumps:=c.jumps
    clock_advance(h,0.002,local)
    testing.expect(t,c.jumps==jumps+1)
    c.display-=10
    clock_advance(h,0.003,local)
    testing.expectf(t,abs(c.display_dilation-0.2)<1e-6,"dilation %v",c.display_dilation)
}
