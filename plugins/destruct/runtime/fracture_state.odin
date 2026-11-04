package destruct

import "mirai:core"
import fr "plugins:destruct/runtime/fracture"
import sim "plugins:physics/runtime/sim"

// Capacities of the fracture of a world, read when it is made; zero takes the default. Changing one
// afterwards has no effect.
@(storage,setting)
Destruct_Settings :: struct {
    destructibles,pieces,connections:i32 `mirai:"advanced"`,
    events:i32 `mirai:"advanced"`, // fracture events per tick
}

// The fracture model over the simulation of physics: the destructibles of its world, whose pieces are
// shapes and bodies of it. Copied, swapped and reset whenever Physics_State is.
@(storage,copy="fracture_state_copy",swap="fracture_state_swap",free="fracture_state_destroy",shared,reset="fracture_state_reset")
Fracture_State :: struct {
    ready:bool,
    fracture:fr.Fracture,
}

@(private)
fracture_state_make :: proc(state:^Fracture_State,settings:^Destruct_Settings,w:^sim.World,problems:^core.Problems) -> bool {
    if state.ready && state.fracture.desc.bodies==w.desc.body_capacity {return true}
    fracture_state_reset(state)
    desc:=fr.desc_default()
    desc.bodies=w.desc.body_capacity
    if settings!=nil {
        if settings.destructibles>0 {desc.destructibles=int(settings.destructibles)}
        if settings.pieces>0 {desc.pieces=int(settings.pieces)}
        if settings.connections>0 {desc.connections=int(settings.connections)}
        if settings.events>0 {desc.events=int(settings.events)}
    }
    if !fr.fracture_init(&state.fracture,desc) {
        core.report(problems,core.NONE,"destruct.fracture","the fracture of this world was not made: out of memory for the capacities of Destruct_Settings (%d destructibles, %d pieces, %d connections); lower them, or free memory",desc.destructibles,desc.pieces,desc.connections)
        return false
    }
    state.ready=true
    return true
}

fracture_state_copy :: proc(dst,src:^Fracture_State) -> bool {
    if dst==src {return true}
    if !src.ready {
        fracture_state_reset(dst)
        return true
    }
    if dst.ready && !fr.desc_equal(dst.fracture.desc,src.fracture.desc) {fracture_state_reset(dst)}
    if !dst.ready {
        desc:=src.fracture.desc
        desc.allocator=context.allocator
        if !fr.fracture_init(&dst.fracture,desc) {return false}
        dst.ready=true
    }
    return fr.fracture_copy(&dst.fracture,&src.fracture)
}

fracture_state_swap :: proc(a,b:^Fracture_State) {a^,b^=b^,a^}

fracture_state_destroy :: proc(state:^Fracture_State) {fracture_state_reset(state)}

// Forgets the fracture of a world whose simulation is made again.
fracture_state_reset :: proc(state:^Fracture_State) {
    if state.ready {fr.fracture_destroy(&state.fracture)}
    state^={}
}
