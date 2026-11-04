package fog_editor

import "mirai:core"
import "mirai:editor"
import volume "mirai:engine/volume"
import "mirai:ui"
import fog "plugins:fog/runtime"

@(storage)
Fog_Cards :: struct {provider:editor.Card_Provider}

fog_cards_default :: proc() -> (cards:Fog_Cards) {
    // Layers of mist drifting across.
    cards.provider.count=1
    cards.provider.cards[0]={
        label="Fog",group="Logic",color={200,214,240,255},lift=2,scale={8,4,8},component=fog.Fog_Volume,make=fog_make,
        drawing=ui.icon_drawing(
            ui.icon_part(.Line,{{-6.5,-3.5},{-2.5,-4.6},{1.5,-3.5},{5.5,-4.6}}),
            ui.icon_part(.Line,{{-5.5,0.5},{-1.5,-0.6},{2.5,0.5},{6.5,-0.6}}),
            ui.icon_part(.Line,{{-6.5,4.5},{-2.5,3.4},{1.5,4.5},{5.5,3.4}}),
        ),
    }
    return
}

@(private)
fog_make :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity) {
    if t:=core.world_table_of(w,fog.Fog_Volume);t!=nil {core.add(t,e,fog.FOG_VOLUME_DEFAULT)}
    // The box of the entity: its sides are its scale.
    if t:=core.world_table_of(w,volume.Volume);t!=nil {core.add(t,e,volume.Volume{shape=.Box,extents={0.5,0.5,0.5},blend=0.5})}
}
