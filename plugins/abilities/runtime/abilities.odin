package abilities

import "mirai:core"
import inp "mirai:engine/input"
import "mirai:std/base"
import phys "plugins:physics/runtime"

// Abilities: what a character does on top of its locomotion (an attack, a dash, a block, a hit
// reaction) as rows of game data. An Ability is a sheet: the input that starts it, what it
// requires and costs, how long it lasts and a timeline of windows relative to its start (a
// hitbox, a dash, cancel windows that say which abilities may follow, statuses it grants, cues
// for presentation). There is no graph of transitions: an ability starts over the running one
// only while an open cancel window accepts one of its tags (or its kit lets those tags interrupt
// anything), and among the valid candidates the one of highest priority wins.
//
// The state of an Ability_User is which ability runs and the tick it started; the phase, the
// open windows and the statuses they grant are derived each tick from the tick against the
// immutable sheet, so an interruption or a rollback leaves nothing behind. Attributes are bases
// that effects change through Ability_Requests, plus modifiers recomputed every tick.

ABILITY_WINDOWS :: 16
ABILITY_CONDITIONS :: 4
ABILITY_COSTS :: 4
ABILITY_NAME :: 64
KIT_ABILITIES :: 32
ATTRIBUTE_ENTRIES :: 8
USER_HITS :: 16
USER_BUFFER :: 4
USER_COOLDOWNS :: 8
USER_TIMERS :: 8
REQUEST_CAPACITY :: 1024
EVENT_CAPACITY :: 1024
HITBOX_RESULTS :: 32
// The layered moves of the windows of an ability use these ids, plus the window index.
MOVE_ID :: u32(0x4142_0000)
// The knockback of an effect, as a layered move of its target.
KNOCKBACK_ID :: u32(0x4142_ffff)

// A state an entity is in (stunned, invulnerable, armed): the game declares its values
// (STATUS_STUNNED :: abilities.Ability_Status(1)) and the data names them.
@(names="STATUS_")
Ability_Status :: distinct u8

@(name_bits="Ability_Status")
Ability_Statuses :: distinct u64

// What kind of ability it is for the cancel windows (light, heavy, dash, reaction): the game
// declares its values.
@(names="TAG_")
Ability_Tag :: distinct u8

@(name_bits="Ability_Tag")
Ability_Tags :: distinct u64

// A quantity of an entity (health, charges, durability): the game declares its values; 0 is
// none.
@(names="ATTRIBUTE_")
Ability_Attribute :: distinct u8
@(name="none") ATTRIBUTE_NONE :: Ability_Attribute(0)

// What a window tells presentation (a slash trail, a sound, a camera shake): the game declares
// its values and plays them from Ability_Events; 0 is none.
@(names="CUE_")
Ability_Cue :: distinct u16
@(name="none") CUE_NONE :: Ability_Cue(0)

// Locomotion modes of the physics Character an ability may start in.
@(name_bits="phys.Locomotion_Mode")
Ability_Modes :: distinct u32

Ability_Trigger :: enum u8 {
    None,     // only Ability_Requests, a kit's next or an effect start it
    Pressed,  // the tick the action goes down
    Released, // the tick it is let go, after being held at least hold seconds
    Held,     // the tick it has been held hold seconds
    Down,     // every tick it is held
}

Ability_Input :: struct {
    action:inp.Action, // of the seat that drives the entity
    on:Ability_Trigger,
    hold:f32 `mirai:"min=0,unit=s"`,
}

Ability_Condition :: struct {
    attribute:Ability_Attribute,
    at_least:f32,
    at_most:f32, // 0: no limit
}

Ability_Cost :: struct {
    attribute:Ability_Attribute,
    amount:f32 `mirai:"min=0"`, // taken from its base when the ability starts; it cannot start with less
}

// value = (base + add) * (1 + more), summed over the modifiers in force.
Ability_Modifier :: struct {
    attribute:Ability_Attribute,
    add:f32,
    more:f32, // 0.5: half as much more; -0.5: half
}

// What an ability does to what it hits, or what a game asks for through Ability_Requests.
Ability_Effect :: struct {
    attribute:Ability_Attribute,
    amount:f32, // added to the base of the attribute of the target: -35 health
    statuses:Ability_Statuses,  // the target is in them for seconds
    modify:Ability_Modifier,    // of the target for seconds
    seconds:f32 `mirai:"min=0,unit=s"`,
    knockback:[3]f32 `mirai:"unit=m/s"`, // in the axes of the source: a velocity its Character takes
    knockback_seconds:f32 `mirai:"min=0,unit=s"`,
    use:core.Record(Ability), // the target starts it: a hit reaction
}

Hitbox_Shape :: enum u8 {None,Box,Sphere,Capsule}

Ability_Hitbox :: struct {
    shape:Hitbox_Shape,
    center:[3]f32 `mirai:"unit=m"`, // in the axes of the user
    size:[3]f32 `mirai:"min=0,unit=m"`, // box: half extents; sphere: x is the radius; capsule: x radius, y half height along its y
    effect:Ability_Effect, // on each entity it touches, once per window
}

Ability_Move :: struct {
    velocity:[3]f32 `mirai:"unit=m/s"`, // in the axes of the user when the window opens; zero: no move
    mix:phys.Move_Mix,
}

// A span of the timeline of an ability, in seconds from its start; it is open while
// from <= time < to. A window with to at 0 is not used.
Ability_Window :: struct {
    from,to:f32 `mirai:"min=0,unit=s"`,
    cancel_into:Ability_Tags,   // abilities with one of these tags may start over this one
    statuses:Ability_Statuses,  // the user is in them
    modify:Ability_Modifier,    // of the user
    hitbox:Ability_Hitbox,
    move:Ability_Move, // a layered move of the user's Character for the whole window
    cue:Ability_Cue,   // carried by the events of its opening and closing
}

@(record,description="An ability: the input that starts it, what it requires and costs, how long it lasts, what it plays and a timeline of windows from its start (hitboxes, dashes, cancel windows, statuses, cues). It starts over the running one only inside a window of that one that accepts one of its tags.")
Ability :: struct {
    input:Ability_Input,
    priority:i16, // among the candidates of a tick, the highest starts
    tags:Ability_Tags,
    requires:Ability_Statuses, // all of them
    blocked_by:Ability_Statuses, // any of them
    modes:Ability_Modes, // of the user's Character; none: any
    conditions:[ABILITY_CONDITIONS]Ability_Condition,
    costs:[ABILITY_COSTS]Ability_Cost,
    cooldown:f32 `mirai:"min=0,unit=s"`,
    duration:f32 `mirai:"min=0,unit=s"`,
    hold:bool, // it ends when its input is let go
    action:[ABILITY_NAME]u8 `mirai:"text"`, // an action of the user's Animation (a layer over locomotion)
    clip:[ABILITY_NAME]u8 `mirai:"text"`,   // a clip of its .match played over the whole body (match_play)
    windows:[ABILITY_WINDOWS]Ability_Window,
    next:core.Record(Ability), // asked for when it completes
}
ABILITY_DEFAULT :: Ability{input={on=.Pressed},duration=0.5}

@(record,description="The abilities an Ability_User may start by input, in order of preference on equal priority: those of a weapon or a character.")
Ability_Kit :: struct {
    abilities:[KIT_ABILITIES]core.Record(Ability),
    buffer:f32 `mirai:"min=0,unit=s"`, // an input that cannot start its ability yet waits this long
    interrupts:Ability_Tags,           // abilities with these tags start over any other: reactions, death
}
ABILITY_KIT_DEFAULT :: Ability_Kit{buffer=0.2}

Ability_Attribute_Entry :: struct {
    attribute:Ability_Attribute,
    base:f32 `mirai:"min=0"`, // costs and effects change it; it stays in 0..max
    max:f32 `mirai:"min=0"`,  // 0: no limit
    regen:f32 `mirai:"unit=1/s"`, // added to base every second
}

Ability_Hit :: struct {target:core.Entity,window:u8}
Ability_Buffered :: struct {ability:core.Record(Ability),tick:u64}
Ability_Cooldown :: struct {ability:core.Record(Ability),until:u64}
Ability_Timer :: struct {
    statuses:Ability_Statuses,
    modify:Ability_Modifier,
    until:u64, // tick it ends at
}

@(component,replicated,description="Uses abilities: those of its kit by the input of the seat that drives it, and those asked through Ability_Requests. Holds its attributes, which costs and effects change.")
Ability_User :: struct {
    kit:core.Record(Ability_Kit),
    attributes:[ATTRIBUTE_ENTRIES]Ability_Attribute_Entry,
    ability:core.Record(Ability) `mirai:"readonly"`, // the one running; none: idle
    start:u64 `mirai:"readonly,hidden"`,             // tick it started at
    hits:[USER_HITS]Ability_Hit `mirai:"readonly,hidden"`, // of the one running
    hit_count:u8 `mirai:"readonly,hidden"`,
    buffer:[USER_BUFFER]Ability_Buffered `mirai:"readonly,hidden"`,
    cooldowns:[USER_COOLDOWNS]Ability_Cooldown `mirai:"readonly,hidden"`,
    timers:[USER_TIMERS]Ability_Timer `mirai:"readonly,hidden"`,
    statuses:Ability_Statuses `mirai:"transient,readonly"`, // of its timers and of the open windows
    values:[ATTRIBUTE_ENTRIES]f32 `mirai:"transient,readonly"`, // of its attributes, with the modifiers
}

Ability_Request_Kind :: enum u8 {Use,Cancel,Effect,Kit}

Ability_Request :: struct {
    kind:Ability_Request_Kind,
    entity:core.Entity, // who uses, cancels or receives
    source:core.Entity, // of an effect: whose axes its knockback is in
    ability:core.Record(Ability),
    effect:Ability_Effect,
    kit:core.Record(Ability_Kit),
}

// Many push; abilities_step takes them at the start of the next tick.
@(storage,queue)
Ability_Requests :: struct {queue:core.Queue(Ability_Request)}

Ability_Event_Kind :: enum u8 {
    Started,
    Completed,   // it ran its duration, or its input was let go
    Interrupted, // another ability started over it
    Canceled,    // by a request, a missing sheet or the loss of its user
    Window_Begin,
    Window_End,
    Hit,      // its window's hitbox touched target
    Depleted, // the base of attribute fell to 0
}

Ability_Event :: struct {
    kind:Ability_Event_Kind,
    entity:core.Entity,
    ability:core.Record(Ability),
    window:i8, // -1: none
    cue:Ability_Cue,
    target:core.Entity,
    attribute:Ability_Attribute,
}

// What the abilities did this tick; abilities_step clears and fills it.
@(storage,events)
Ability_Events :: struct {queue:core.Queue(Ability_Event)}

// Asks entity to start ability as if its input fired: it waits the buffer of its kit for a
// moment it is valid. False when the queue is full or the request names nothing.
ability_use :: proc(requests:^Ability_Requests,entity:core.Entity,ability:core.Record(Ability)) -> bool {
    if ability=={} {return false}
    return request_push(requests,{kind=.Use,entity=entity,ability=ability})
}

// Ends the ability entity runs (Canceled).
ability_cancel :: proc(requests:^Ability_Requests,entity:core.Entity) -> bool {
    return request_push(requests,{kind=.Cancel,entity=entity})
}

// Applies effect to target on the next tick, where this end decides target (core.owned).
ability_effect :: proc(requests:^Ability_Requests,target:core.Entity,effect:Ability_Effect,source:=core.NONE) -> bool {
    return request_push(requests,{kind=.Effect,entity=target,source=source,effect=effect})
}

// Gives entity another kit (a weapon it takes); the running ability goes on.
ability_kit_set :: proc(requests:^Ability_Requests,entity:core.Entity,kit:core.Record(Ability_Kit)) -> bool {
    return request_push(requests,{kind=.Kit,entity=entity,kit=kit})
}

@(private)
request_push :: proc(requests:^Ability_Requests,request:Ability_Request) -> bool {
    if requests==nil || request.entity==core.NONE || len(requests.queue.items)>=REQUEST_CAPACITY {return false}
    if cap(requests.queue.items)==0 {
        if reserve(&requests.queue.items,REQUEST_CAPACITY)!=nil {return false}
    }
    core.push(&requests.queue,request)
    return true
}

// The current value of an attribute of a user and whether it has it.
ability_value :: proc "contextless" (user:Ability_User,attribute:Ability_Attribute) -> (value:f32,found:bool) {
    if attribute==ATTRIBUTE_NONE {return}
    for entry,i in user.attributes {
        if entry.attribute==attribute {return user.values[i],true}
    }
    return
}

ability_has :: #force_inline proc "contextless" (user:Ability_User,status:Ability_Status) -> bool {
    return u64(status)<64 && user.statuses&Ability_Statuses(u64(1)<<u64(status))!=0
}

status_bit :: #force_inline proc "contextless" (status:Ability_Status) -> Ability_Statuses {
    return u64(status)<64?Ability_Statuses(u64(1)<<u64(status)):0
}

tag_bit :: #force_inline proc "contextless" (tag:Ability_Tag) -> Ability_Tags {
    return u64(tag)<64?Ability_Tags(u64(1)<<u64(tag)):0
}

// The sheet a reference names, read in place; nil without it.
ability_sheet :: proc "contextless" (rows:core.Records(Ability),ref:core.Record(Ability)) -> ^Ability {
    if ref=={} {return nil}
    at:=core.record_index(rows.set,ref.table,ref.row,size_of(Ability))
    if at<0 {return nil}
    return cast(^Ability)&rows.set.values[at*size_of(Ability)]
}

kit_sheet :: proc "contextless" (rows:core.Records(Ability_Kit),ref:core.Record(Ability_Kit)) -> ^Ability_Kit {
    if ref=={} {return nil}
    at:=core.record_index(rows.set,ref.table,ref.row,size_of(Ability_Kit))
    if at<0 {return nil}
    return cast(^Ability_Kit)&rows.set.values[at*size_of(Ability_Kit)]
}

ability_name_text :: proc "contextless" (name:^[ABILITY_NAME]u8) -> string {return base.text_get(name[:])}
