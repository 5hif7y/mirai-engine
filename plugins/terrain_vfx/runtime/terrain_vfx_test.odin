package terrain_vfx

import "core:testing"
import "mirai:core"
import terrain "plugins:terrain/runtime"
import vfx "plugins:vfx/runtime"

@(test)
a_dig_raises_dust_of_each_layer_it_took_on_its_channel :: proc(t:^testing.T) {
    es:core.Entities
    core.entities_init(&es)
    defer core.entities_destroy(&es)
    dusts:core.Table(Terrain_Dust)
    core.table_init(&dusts,"Terrain_Dust")
    defer core.table_destroy(&dusts)
    dusty,bare:=core.create(&es),core.create(&es)
    dust:=TERRAIN_DUST_DEFAULT
    dust.layers[1]={channel=vfx.Particle_Channel_Name(20),color={1,0,0,1}}
    dust.layers[3].channel=vfx.CHANNEL_NONE
    core.add(&dusts,dusty,dust)
    core.table_settle(&dusts,&es)
    digs:terrain.Terrain_Digs
    defer delete(digs.digs.items)
    core.push(&digs.digs,terrain.Terrain_Dig{owner=dusty,center={1,2,3},volume=1,layers={0.5,0.25,0,0.25}})
    core.push(&digs.digs,terrain.Terrain_Dig{owner=bare,volume=1,layers={1,0,0,0}})
    channels:vfx.Particle_Channels
    defer delete(channels.queue.items)
    terrain_dust(core.ref(&digs),core.read(&dusts),&channels)
    pushes:=channels.queue.items[:]
    testing.expect_value(t,len(pushes),2)
    if len(pushes)!=2 {return}
    testing.expect(t,pushes[0].channel==CHANNEL_DUST && pushes[0].birth.count==20 && pushes[0].birth.position==[3]f32{1,2,3})
    testing.expect(t,pushes[1].channel==vfx.Particle_Channel_Name(20) && pushes[1].birth.count==10 && pushes[1].birth.color==[4]f32{1,0,0,1})
}
