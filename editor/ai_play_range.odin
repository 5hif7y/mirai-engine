package editor

import "core:fmt"
import "core:math"
import "core:strings"
import "mirai:std/base"
import "mirai:ui"

// The ticks of the paused Play of the user that the next message is about,
// chosen on its timeline: a chip over the composer and, when it is sent, a
// line of the instructions of the turn with the method that reads them. Copy
// range and the turn say the same: the ticks, the run and the scene, never a
// path outside the project.

Ai_Play_Range :: struct {
    from,to:u64,              // ticks; to<=from: none
    run:u64,                  // Run.id
    scene:[AI_PATH_BYTES]u8,  // in the assets of the project; empty for one never saved
}

// What context.json says of the range.
Ai_Context_Ticks :: struct {
    from,to,run:u64,
    scene:string,
}

ai_context_ticks :: proc(r:^Ai_Play_Range) -> Ai_Context_Ticks {
    if r.to<=r.from {return {}}
    return {r.from,r.to,r.run,base.text_get(r.scene[:])}
}

// What Copy range puts on the clipboard, for a chat in the editor or out of it.
play_range_text :: proc(r:^Ai_Play_Range) -> string {
    scene:=base.text_get(r.scene[:])
    return fmt.tprintf("Range: ticks %d to %d\nRun: %d\nScene: %s",r.from,r.to,r.run,
        scene!=""?scene:"unsaved")
}

ai_play_range_set :: proc(s:^Session,r:Ai_Play_Range) {
    m:=s.ai
    if m==nil || r.to<=r.from {return}
    m.play_range=r
    m.focus=true
}

@(private)
ai_play_range_rows :: proc(m:^Ai) -> int {return m!=nil && m.play_range.to>m.play_range.from?1:0}

@(private)
ai_play_range_build :: proc(s:^Session,width:f32,rows:int) {
    m:=s.ai
    if rows<=0 || ai_play_range_rows(m)==0 {return}
    ctx:=s.gui.ctx;th:=&ctx.theme
    buffer:[64]u8
    label:=fmt.bprintf(buffer[:],"Ticks %d to %d",m.play_range.from,m.play_range.to)
    size:=min(width,math.ceil(ui.text_width(&ctx.font,label,th.font_small))+AI_CHIP_ROOM)
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(AI_CHIP_HEIGHT),gap=5,align_y=.Center}) {
        chip:=ui.Box{width=ui.fixed(size),height=ui.fixed(AI_CHIP_HEIGHT),padding={5,0,5,0},gap=4,
            align_y=.Center,fill=th.field,radius=th.radius_control}
        if ui.box(ctx,chip) {
            ui.icon(ctx,timeline_icon(.Range),th.text_muted,12)
            ui.label(ctx,label,th.font_small,th.text_muted,size-40)
            remove:=ui.Button{icon=.Cross,icon_color=th.text_muted,icon_size=10,padding=-1,
                style=.Ghost,width=12,height=12}
            if ui.button(ctx,ui.id(ctx,"remove_play_range"),remove).clicked {m.play_range={}}
        }
    }
}

// The line of the instructions that names them.
@(private)
ai_play_range_prompt :: proc(task:^Ai_Task,b:^strings.Builder) {
    r:=&task.play_range
    if r.to<=r.from {return}
    scene:=base.text_get(r.scene[:])
    fmt.sbprintf(b,"- The user chose ticks %d to %d of run %d, a Play of %s, on its timeline: "+
        "this message is about them. `play.history` with `run` %d, `from` %d and `to` %d reads "+
        "them, also after the user stopped that Play: with `trace`, values of entities at those "+
        "ticks; with `verify`, whether playing them again repeats them.\n",
        r.from,r.to,r.run,scene!=""?scene:"an unsaved scene",r.run,r.from,r.to)
}
