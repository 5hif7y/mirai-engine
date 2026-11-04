package spawn_editor

import "mirai:core"
import "mirai:editor"
import spawn "plugins:spawn/runtime"

// Spawn points in Create, and the icon of what has one.
@(storage)
Spawn_Cards :: struct {provider:editor.Card_Provider}

spawn_cards_default :: proc() -> (cards:Spawn_Cards) {
    cards.provider.count=1
    cards.provider.cards[0]={label="Spawn",group="Logic",icon=.Spawn,color={120,214,140,255},component=spawn.Spawn_Point,make=spawn_make}
    return
}

spawn_make :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity) {
    if t:=core.world_table_of(w,spawn.Spawn_Point);t!=nil {core.add(t,e,spawn.Spawn_Point{})}
}
