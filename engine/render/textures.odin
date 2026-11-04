package render

import "mirai:core"
import scene "mirai:engine/scene"
import "mirai:host"
import gpu "mirai:render"

// The levels each texture holds follow the distance of what shows it from
// the views the renderer draws and from the streaming sources of the world
// drawn, each also where it goes (scene.Streaming_Sources): the sources reach
// the renderer here, and the reads of the levels run between frames
// (host.app_textures_stream).
@(step="render",loops="game editor")
render_texture_sources :: proc(sources:core.Ref(scene.Streaming_Sources),app:^host.App) {
    if app.renderer==nil || app.ui_only {return}
    places:[2*scene.SOURCES_MAX][3]f32
    count:=0
    if sources.ptr!=nil {
        for source in sources.items[:sources.count] {
            places[count]=source.position
            count+=1
            if source.ahead==source.position {continue}
            places[count]=source.ahead
            count+=1
        }
    }
    gpu.texture_sources(app.renderer,places[:count])
}
