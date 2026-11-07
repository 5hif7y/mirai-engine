package abilities

import "core:math"
import "core:mem"
import "mirai:core"
import inp "mirai:engine/input"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import phys "plugins:physics/runtime"

// What abilities_step reads of the rest of the world and asks of it.
@(params)
Ability_World :: struct {
    time:core.Time,
    seats:core.Read(inp.Seat),
    drivables:core.Read(inp.Drivable),
    characters:core.Read(phys.Character),
    worlds:core.Read(core.World_Transform),
    remotes:core.Read(core.Remote),
    physics:core.Ref(phys.Physics_State),
    moves:^phys.Locomotion_Requests,
    actions:^anim.Action_Requests,
    animations:^anim.Animation_Requests,
    problems:^core.Problems,
}

// The entities a hitbox at pose touches, written into results.
Hitbox_Overlap :: #type proc(w:^Ability_World,hitbox:Ability_Hitbox,pose:mm.Transform,results:[]core.Entity) -> int

// Every tick: applies the effects asked in the tick before, runs the timers, cooldowns and
// regeneration, takes the inputs of each user into its buffer, advances the running ability
// along its timeline and starts the best valid candidate. Only the end that decides a user
// (core.owned) starts, ends or hits with its abilities; a replica derives its statuses and the
// events of its windows from what the network gives it.
@(step="fixed")
abilities_step :: proc(users:^core.Table(Ability_User),abilities:core.Records(Ability),kits:core.Records(Ability_Kit),requests:^Ability_Requests,events:^Ability_Events,w:Ability_World) {
    w:=w
    abilities_tick(users,abilities,kits,requests,events,&w,physics_overlap)
}

physics_overlap :: proc(w:^Ability_World,hitbox:Ability_Hitbox,pose:mm.Transform,results:[]core.Entity) -> int {
    center:=pose.position+mm.quat_rotate(pose.rotation,hitbox.center)
    count:int
    switch hitbox.shape {
    case .None:
    case .Box: count,_=phys.overlap_box(w.physics,center,hitbox.size,pose.rotation,results)
    case .Sphere: count,_=phys.overlap_sphere(w.physics,center,hitbox.size.x,results)
    case .Capsule: count,_=phys.overlap_capsule(w.physics,center,hitbox.size.x,hitbox.size.y,pose.rotation,results)
    }
    return count
}

@(private)
Tick :: struct {
    users:^core.Table(Ability_User),
    abilities:core.Records(Ability),
    kits:core.Records(Ability_Kit),
    requests:^Ability_Requests,
    events:^Ability_Events,
    w:^Ability_World,
    overlap:Hitbox_Overlap,
    tick:u64,
    dt:f32,
    text:[512]u8,
}

abilities_tick :: proc(users:^core.Table(Ability_User),abilities:core.Records(Ability),kits:core.Records(Ability_Kit),requests:^Ability_Requests,events:^Ability_Events,w:^Ability_World,overlap:Hitbox_Overlap) {
    if events!=nil {core.queue_clear(&events.queue)}
    if users==nil || w==nil || !(w.time.dt>0) || !finite(w.time.dt) {return}
    t:=Tick{users=users,abilities=abilities,kits=kits,requests=requests,events=events,w=w,overlap=overlap,tick=w.time.tick,dt=w.time.dt}
    if requests!=nil {
        for r in requests.queue.items {request_apply(&t,r)}
        core.queue_clear(&requests.queue)
    }
    for row in 0..<core.count(users) {
        e:=core.entity_at(users,row)
        u:=users.values[row]
        if core.owned(w.remotes,e) {user_tick(&t,e,&u)} else {replica_tick(&t,e,&u)}
        if mem.compare_ptrs(&u,&users.values[row],size_of(Ability_User))!=0 {core.at(users,row)^=u}
    }
}

@(private)
request_apply :: proc(t:^Tick,r:Ability_Request) {
    if r.entity==core.NONE || !core.owned(t.w.remotes,r.entity) {return}
    switch r.kind {
    case .Use:
        if u:=core.get(t.users,r.entity);u!=nil {buffer_add(u,r.ability,t.tick)}
    case .Cancel:
        u:=core.get(t.users,r.entity)
        if u==nil || u.ability=={} {return}
        local:=i64(t.tick-u.start) if t.tick>=u.start else 0
        ability_end(t,r.entity,u,ability_sheet(t.abilities,u.ability),local,.Canceled,nil)
    case .Effect:
        effect_apply(t,r.entity,r.source,r.effect)
    case .Kit:
        if u:=core.get(t.users,r.entity);u!=nil {u.kit,u.buffer=r.kit,{}}
    }
}

@(private)
effect_apply :: proc(t:^Tick,target,source:core.Entity,effect:Ability_Effect) {
    if text:=effect_check(effect,t.text[:]);text!="" {
        core.report(t.w.problems,target,"abilities.effect","an effect asked for it %s",text)
        return
    }
    if u:=core.get(t.users,target);u!=nil {
        if effect.attribute!=ATTRIBUTE_NONE && effect.amount!=0 {
            for &entry in u.attributes {
                if entry.attribute==effect.attribute {base_add(t,target,&entry,effect.amount)}
            }
        }
        if effect.seconds>0 && (effect.statuses!=0 || effect.modify.attribute!=ATTRIBUTE_NONE) {
            timer:=Ability_Timer{statuses=effect.statuses,modify=effect.modify,until=t.tick+max(ticks_of(effect.seconds,t.dt),1)}
            slot:=0
            for other,i in u.timers {
                if other.until==0 {slot=i;break}
                if other.until<u.timers[slot].until {slot=i}
            }
            u.timers[slot]=timer
        }
        if effect.use!={} {buffer_add(u,effect.use,t.tick)}
    }
    if effect.knockback!={} && core.has(t.w.characters,target) {
        velocity:=effect.knockback
        if pose,found:=core.get(t.w.worlds,source);found && source!=core.NONE {velocity=mm.quat_rotate(pose.rotation,velocity)}
        phys.add_move(t.w.moves,target,{velocity=velocity,ticks=u32(max(ticks_of(effect.knockback_seconds,t.dt),1)),mix=.Override,id=KNOCKBACK_ID})
    }
}

@(private)
base_add :: proc(t:^Tick,e:core.Entity,entry:^Ability_Attribute_Entry,amount:f32) {
    before:=entry.base
    entry.base=clamp_base(entry^,entry.base+amount)
    if before>0 && entry.base<=0 {event_push(t,{kind=.Depleted,entity=e,window=-1,attribute=entry.attribute})}
}

@(private)
clamp_base :: #force_inline proc "contextless" (entry:Ability_Attribute_Entry,value:f32) -> f32 {
    v:=max(value,0)
    return min(v,entry.max) if entry.max>0 else v
}

@(private)
buffer_add :: proc "contextless" (u:^Ability_User,ability:core.Record(Ability),tick:u64) {
    if ability=={} {return}
    slot:=-1
    for b,i in u.buffer {
        if b.ability==ability {slot=i;break}
    }
    if slot<0 {
        slot=0
        for b,i in u.buffer {
            if b.ability=={} {slot=i;break}
            if b.tick<u.buffer[slot].tick {slot=i}
        }
    }
    u.buffer[slot]={ability,tick}
}

@(private)
ticks_of :: #force_inline proc "contextless" (seconds,dt:f32) -> u64 {
    if !(seconds>0) || !(dt>0) {return 0}
    return u64(math.round(f64(seconds)/f64(dt)))
}

// The ticks of a window from the start of its ability: open while from<=local<to.
@(private)
window_ticks :: #force_inline proc "contextless" (w:Ability_Window,dt:f32) -> (from,to:i64) {
    from=i64(ticks_of(w.from,dt))
    to=max(i64(ticks_of(w.to,dt)),from+1)
    return
}

ability_window_open :: #force_inline proc "contextless" (w:Ability_Window,dt:f32,local:i64) -> bool {
    if w.to==0 {return false}
    from,to:=window_ticks(w,dt)
    return local>=from && local<to
}

ability_ticks :: #force_inline proc "contextless" (a:^Ability,dt:f32) -> i64 {return max(i64(ticks_of(a.duration,dt)),1)}

@(private)
user_tick :: proc(t:^Tick,e:core.Entity,u:^Ability_User) {
    if text:=attributes_check(u,t.text[:]);text!="" {
        core.report(t.w.problems,e,"abilities.attributes","%s",text)
        return
    }
    kit:=kit_sheet(t.kits,u.kit)
    if kit==nil && u.kit!={} {core.record_missing(t.kits.set,u.kit.table,u.kit.row,"Ability_Kit",t.w.problems,e)}
    if kit!=nil {
        if text:=kit_check(kit,t.text[:]);text!="" {
            core.report(t.w.problems,e,"abilities.kit","its kit %s %s",core.record_name(t.kits,u.kit),text)
            kit=nil
        }
    }
    for &timer in u.timers {if timer.until!=0 && timer.until<=t.tick {timer={}}}
    for &c in u.cooldowns {if c.until!=0 && c.until<=t.tick {c={}}}
    buffer:=ticks_of(kit.buffer,t.dt) if kit!=nil else 0
    for &b in u.buffer {if b.ability!={} && b.tick+buffer<t.tick {b={}}}
    for &entry in u.attributes {
        if entry.attribute!=ATTRIBUTE_NONE && entry.regen!=0 {base_add(t,e,&entry,entry.regen*t.dt)}
    }
    // The running ability advances to this tick.
    next:core.Record(Ability)
    local:i64
    active:=sheet_valid(t,e,u.ability)
    if u.ability!={} && active==nil {ability_end(t,e,u,nil,0,.Canceled,nil)}
    if active!=nil {
        local=i64(t.tick-u.start) if t.tick>=u.start else 0
        windows_advance(t,e,u,active,local)
        if local>=ability_ticks(active,t.dt) {
            next=active.next
            ability_end(t,e,u,active,local,.Completed,nil)
            active=nil
        } else if active.hold && active.input.on!=.None && !input_down(t,e,active.input) {
            ability_end(t,e,u,active,local,.Completed,nil)
            active=nil
        }
    }
    if kit!=nil {
        for ref in kit.abilities {
            a:=ability_sheet(t.abilities,ref)
            if a!=nil && a.input.on>max(Ability_Trigger) {a=sheet_valid(t,e,ref)}
            if a!=nil && input_fired(t,e,a.input) {buffer_add(u,ref,t.tick)}
        }
    }
    derive(t,u,active,local)
    // The best valid candidate starts.
    best:=-1
    best_ref:=next
    best_sheet:=sheet_valid(t,e,next) if next!={} else nil
    if best_sheet!=nil && !can_start(t,e,u,kit,active,local,best_sheet,next) {best_sheet=nil}
    for b,i in u.buffer {
        if b.ability=={} {continue}
        a:=sheet_valid(t,e,b.ability)
        if a==nil {u.buffer[i]={};continue}
        if !can_start(t,e,u,kit,active,local,a,b.ability) {continue}
        if best_sheet==nil || a.priority>best_sheet.priority || a.priority==best_sheet.priority && best>=0 && b.tick<u.buffer[best].tick {
            best,best_ref,best_sheet=i,b.ability,a
        }
    }
    if best_sheet!=nil {
        if active!=nil {ability_end(t,e,u,active,local,.Interrupted,best_sheet)}
        ability_start(t,e,u,best_ref,best_sheet)
        active,local=best_sheet,0
        windows_advance(t,e,u,active,0)
    }
    if active!=nil {hitboxes(t,e,u,active,local)}
    derive(t,u,active,local)
}

// A replica follows the ability its owner runs: its statuses and the events of its windows.
@(private)
replica_tick :: proc(t:^Tick,e:core.Entity,u:^Ability_User) {
    active:=ability_sheet(t.abilities,u.ability)
    local:i64
    if active!=nil {
        local=i64(t.tick-u.start) if t.tick>=u.start else 0
        if local<ability_ticks(active,t.dt) {
            for &w,i in active.windows {
                was,is:=ability_window_open(w,t.dt,local-1),ability_window_open(w,t.dt,local)
                if is && !was {event_push(t,{kind=.Window_Begin,entity=e,ability=u.ability,window=i8(i),cue=w.cue})}
                if was && !is {event_push(t,{kind=.Window_End,entity=e,ability=u.ability,window=i8(i),cue=w.cue})}
            }
        } else {active=nil}
    }
    derive(t,u,active,local)
}

// The sheet of a reference when it is there and valid; a missing or invalid one is a problem.
@(private)
sheet_valid :: proc(t:^Tick,e:core.Entity,ref:core.Record(Ability)) -> ^Ability {
    if ref=={} {return nil}
    a:=ability_sheet(t.abilities,ref)
    if a==nil {
        core.record_missing(t.abilities.set,ref.table,ref.row,"Ability",t.w.problems,e)
        return nil
    }
    if text:=ability_check(a,t.text[:]);text!="" {
        core.report(t.w.problems,e,"abilities.invalid","the ability %s does not run: %s",core.record_name(t.abilities,ref),text)
        return nil
    }
    return a
}

@(private)
input_state :: proc(t:^Tick,e:core.Entity,input:Ability_Input) -> inp.Action_State {
    return inp.body_action({t.w.seats,t.w.drivables},e,input.action)
}

@(private)
input_down :: proc(t:^Tick,e:core.Entity,input:Ability_Input) -> bool {
    return input.on!=.None && input_state(t,e,input).down
}

@(private)
input_fired :: proc(t:^Tick,e:core.Entity,input:Ability_Input) -> bool {
    if input.on==.None {return false}
    s:=input_state(t,e,input)
    hold:=u32(ticks_of(input.hold,t.dt))
    switch input.on {
    case .None: return false
    case .Pressed: return s.pressed
    case .Released: return s.released && s.released_held>=hold
    case .Held: return hold==0?s.pressed:s.down && s.held_ticks==hold
    case .Down: return s.down
    }
    return false
}

// Why a candidate cannot start now; .None when it can.
Ability_Block :: enum u8 {
    None,
    Status_Missing, // it requires a status the user is not in
    Status_Blocked, // the user is in a status that blocks it
    Mode,           // the user's Character is not in one of its modes
    Condition,      // an attribute is out of a condition
    Cost,           // an attribute has less than a cost
    Cooldown,
    No_Cancel,      // the running ability has no open window that accepts its tags
}

@(private)
can_start :: proc(t:^Tick,e:core.Entity,u:^Ability_User,kit:^Ability_Kit,active:^Ability,local:i64,a:^Ability,ref:core.Record(Ability)) -> bool {
    return start_block(t.w,t.tick,t.dt,e,u,kit,active,local,a,ref)==.None
}

// Why ability a cannot start for user u at tick, with active running at local.
start_block :: proc(w:^Ability_World,tick:u64,dt:f32,e:core.Entity,u:^Ability_User,kit:^Ability_Kit,active:^Ability,local:i64,a:^Ability,ref:core.Record(Ability)) -> Ability_Block {
    if u.statuses&a.requires!=a.requires {return .Status_Missing}
    if u.statuses&a.blocked_by!=0 {return .Status_Blocked}
    if a.modes!=0 {
        if w.characters.table==nil {return .Mode}
        c,found:=core.get(w.characters,e)
        if !found || u32(c.mode)>=32 || a.modes&Ability_Modes(u32(1)<<u32(c.mode))==0 {return .Mode}
    }
    for c in a.conditions {
        if c.attribute==ATTRIBUTE_NONE {continue}
        value,found:=ability_value(u^,c.attribute)
        if !found || value<c.at_least || c.at_most>0 && value>c.at_most {return .Condition}
    }
    for c in a.costs {
        if c.attribute==ATTRIBUTE_NONE || c.amount==0 {continue}
        value,found:=ability_value(u^,c.attribute)
        if !found || value<c.amount {return .Cost}
    }
    for c in u.cooldowns {
        if c.ability==ref && c.until>tick {return .Cooldown}
    }
    if active!=nil {
        accepted:=kit.interrupts if kit!=nil else 0
        for &w in active.windows {
            if ability_window_open(w,dt,local) {accepted|=w.cancel_into}
        }
        if accepted&a.tags==0 {return .No_Cancel}
    }
    return .None
}

@(private)
ability_start :: proc(t:^Tick,e:core.Entity,u:^Ability_User,ref:core.Record(Ability),a:^Ability) {
    for c in a.costs {
        if c.attribute==ATTRIBUTE_NONE || c.amount==0 {continue}
        for &entry in u.attributes {
            if entry.attribute==c.attribute {base_add(t,e,&entry,-c.amount)}
        }
    }
    if a.cooldown>0 {
        slot:=0
        for c,i in u.cooldowns {
            if c.ability==ref || c.until==0 {slot=i;break}
            if c.until<u.cooldowns[slot].until {slot=i}
        }
        u.cooldowns[slot]={ref,t.tick+max(ticks_of(a.cooldown,t.dt),1)}
    }
    for &b in u.buffer {if b.ability==ref {b={}}}
    u.ability,u.start,u.hits,u.hit_count=ref,t.tick,{},0
    event_push(t,{kind=.Started,entity=e,ability=ref,window=-1})
    if name:=ability_name_text(&a.action);name!="" {
        if !anim.action_fire(t.w.actions,e,name) {core.report(t.w.problems,e,"abilities.animation","the action %q of the ability %s did not fit in the animation requests: fewer abilities should start in one tick",name,core.record_name(t.abilities,ref))}
    } else if name:=ability_name_text(&a.clip);name!="" {
        mode:u16
        if c,found:=core.get(t.w.characters,e);found {mode=u16(c.mode)}
        if !anim.match_play(t.w.animations,e,name,mode) {core.report(t.w.problems,e,"abilities.animation","the clip %q of the ability %s did not fit in the animation requests: fewer abilities should start in one tick",name,core.record_name(t.abilities,ref))}
    }
}

// Ends the running ability at local: its open windows close, their moves stop and its animation
// stops unless next plays one of the same kind.
@(private)
ability_end :: proc(t:^Tick,e:core.Entity,u:^Ability_User,a:^Ability,local:i64,kind:Ability_Event_Kind,next:^Ability) {
    ref:=u.ability
    if a!=nil {
        for &w,i in a.windows {
            if !ability_window_open(w,t.dt,local) {continue}
            event_push(t,{kind=.Window_End,entity=e,ability=ref,window=i8(i),cue=w.cue})
            if w.move.velocity!={} {phys.remove_moves(t.w.moves,e,MOVE_ID+u32(i))}
        }
        if kind!=.Completed || a.hold {
            if name:=ability_name_text(&a.action);name!="" && (next==nil || ability_name_text(&next.action)=="") {anim.action_cancel(t.w.actions,e,name)}
            if ability_name_text(&a.clip)!="" && (next==nil || ability_name_text(&next.clip)=="") {anim.match_stop(t.w.animations,e)}
        }
    }
    u.ability,u.start,u.hits,u.hit_count={},0,{},0
    event_push(t,{kind=kind,entity=e,ability=ref,window=-1})
}

// The windows that open or close at local, against the tick before.
@(private)
windows_advance :: proc(t:^Tick,e:core.Entity,u:^Ability_User,a:^Ability,local:i64) {
    for &w,i in a.windows {
        was,is:=ability_window_open(w,t.dt,local-1),ability_window_open(w,t.dt,local)
        if is && !was {
            event_push(t,{kind=.Window_Begin,entity=e,ability=u.ability,window=i8(i),cue=w.cue})
            if w.move.velocity!={} {
                velocity:=w.move.velocity
                if pose,found:=core.get(t.w.worlds,e);found {velocity=mm.quat_rotate(pose.rotation,velocity)}
                from,to:=window_ticks(w,t.dt)
                phys.add_move(t.w.moves,e,{velocity=velocity,ticks=u32(to-from),mix=w.move.mix,id=MOVE_ID+u32(i)})
            }
        }
        if was && !is {event_push(t,{kind=.Window_End,entity=e,ability=u.ability,window=i8(i),cue=w.cue})}
    }
}

// Each open hitbox touches each entity once: a Hit and the effect of the window, on the tick after.
@(private)
hitboxes :: proc(t:^Tick,e:core.Entity,u:^Ability_User,a:^Ability,local:i64) {
    pose,found:=core.get(t.w.worlds,e)
    if !found {pose.rotation=1}
    for &w,i in a.windows {
        if w.hitbox.shape==.None || !ability_window_open(w,t.dt,local) || t.overlap==nil {continue}
        results:[HITBOX_RESULTS]core.Entity
        count:=clamp(t.overlap(t.w,w.hitbox,pose.transform,results[:]),0,HITBOX_RESULTS)
        each: for target in results[:count] {
            if target==e || target==core.NONE {continue}
            for h in u.hits[:u.hit_count] {
                if h.target==target && int(h.window)==i {continue each}
            }
            if int(u.hit_count)>=USER_HITS {
                core.report(t.w.problems,e,"abilities.hits","the ability %s touched more than %d entities: smaller hitboxes, or fewer windows with hitboxes",core.record_name(t.abilities,u.ability),USER_HITS)
                return
            }
            u.hits[u.hit_count]={target,u8(i)}
            u.hit_count+=1
            event_push(t,{kind=.Hit,entity=e,ability=u.ability,window=i8(i),cue=w.cue,target=target})
            if w.hitbox.effect!={} {
                if !ability_effect(t.requests,target,w.hitbox.effect,e) {core.report(t.w.problems,e,"abilities.requests","the requests of abilities are full (%d): fewer hits or effects in one tick",REQUEST_CAPACITY)}
            }
        }
    }
}

// The statuses and current values of a user: those of its timers and of the windows open at local.
@(private)
derive :: proc(t:^Tick,u:^Ability_User,active:^Ability,local:i64) {
    statuses:Ability_Statuses
    add,more:[ATTRIBUTE_ENTRIES]f32
    modify :: proc(u:^Ability_User,m:Ability_Modifier,add,more:^[ATTRIBUTE_ENTRIES]f32) {
        if m.attribute==ATTRIBUTE_NONE {return}
        for entry,i in u.attributes {
            if entry.attribute==m.attribute {add[i]+=m.add;more[i]+=m.more}
        }
    }
    for timer in u.timers {
        if timer.until==0 {continue}
        statuses|=timer.statuses
        modify(u,timer.modify,&add,&more)
    }
    if active!=nil {
        for &w in active.windows {
            if !ability_window_open(w,t.dt,local) {continue}
            statuses|=w.statuses
            modify(u,w.modify,&add,&more)
        }
    }
    u.statuses=statuses
    for entry,i in u.attributes {
        u.values[i]=0 if entry.attribute==ATTRIBUTE_NONE else max((entry.base+add[i])*max(1+more[i],0),0)
    }
}

@(private)
event_push :: proc(t:^Tick,event:Ability_Event) {
    if t.events==nil {return}
    if cap(t.events.queue.items)==0 {
        if reserve(&t.events.queue.items,EVENT_CAPACITY)!=nil {return}
    }
    if len(t.events.queue.items)>=EVENT_CAPACITY {
        core.report(t.w.problems,core.NONE,"abilities.events","more than %d ability events in one tick: the rest were dropped",EVENT_CAPACITY)
        return
    }
    core.push(&t.events.queue,event)
}
