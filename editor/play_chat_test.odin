package editor

import "core:testing"
import "mirai:core"
import input "mirai:engine/input"
import "mirai:host"
import "mirai:platform"
import "mirai:ui"

@(private="file")
Play_Chat_Input_World :: struct {time:core.Time,input:core.Input,frame:core.Frame_Input,frame_time:core.Frame_Time}

@(test)
play_chat_toggles_before_game_input_and_restores_capture :: proc(t:^testing.T) {
    p,error:=platform.create({headless=true,fixed_dt=1.0/60,pacing=platform.Frame_Pacing{}})
    testing.expect_value(t,error,platform.Error.None)
    if p==nil {return}
    defer platform.destroy(p)
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    storages:=[4]core.Storage_Info{
        {type=core.Time,offset=offset_of(Play_Chat_Input_World,time)},
        {type=core.Input,offset=offset_of(Play_Chat_Input_World,input)},
        {type=core.Frame_Input,offset=offset_of(Play_Chat_Input_World,frame)},
        {type=core.Frame_Time,offset=offset_of(Play_Chat_Input_World,frame_time)},
    }
    info:=core.World_Info{storages=storages[:]}
    app:=host.App{info=&info,platform=p,tick_dt=1.0/60,max_ticks=8,game_input_excluded={.F1,.Tab}}
    defer delete(app.worlds)
    world:Play_Chat_Input_World
    viewport:Viewport
    gui:=Editor_Ui{ctx=&ctx}
    ai:=new(Ai);defer free(ai)
    s:=Session{mode=.Play,app=&app,info=&info,gui=&gui,ai=ai,viewport=&viewport}
    s.runs[0]={world=&world}
    platform.window_set_relative_mouse(p,true)
    platform.input_inject(p,platform.Key_Event{key=.W,down=true})
    platform.input_inject(p,platform.Key_Event{key=.Tab,down=true})
    platform.frame_begin(p)
    app.ui_input=host.ui_input_from_platform(platform.input_frame(p))
    play_input_update(&s)
    testing.expect(t,s.play_chat_open && ai.chat_open && ai.focus)
    testing.expect(t,gui.layout.left_open && gui.layout.library_tab==.Ai)
    testing.expect(t,s.play_input_released && app.game_input_blocked)
    testing.expect(t,!platform.window_relative_mouse(p))
    testing.expect(t,.Tab not_in app.ui_input.keys_repeated)
    game_frame(&s)
    testing.expect_value(t,world.time.tick,u64(1))
    testing.expect(t,world.input.keys_down=={} && world.frame.keys_down=={})
    platform.input_inject(p,platform.Key_Event{key=.Tab,down=false})
    platform.frame_begin(p)
    play_input_update(&s)
    testing.expect(t,s.play_chat_open)
    ctx.edit.id=0x1234
    platform.input_inject(p,platform.Key_Event{key=.Tab,down=true})
    platform.frame_begin(p)
    app.ui_input=host.ui_input_from_platform(platform.input_frame(p))
    play_input_update(&s)
    testing.expect(t,!s.play_chat_open && !ai.chat_open && !gui.layout.left_open)
    testing.expect(t,!s.play_input_released && !app.game_input_blocked && ctx.edit.id==0)
    testing.expect(t,platform.window_relative_mouse(p))
    game_frame(&s)
    testing.expect(t,.W in world.input.keys_down && .W in world.frame.keys_down)
    testing.expect(t,.Tab not_in world.input.keys_down && .Tab not_in world.frame.keys_down)
    shortcuts_run(&s,{.Tab},{})
    testing.expect(t,!gui.layout.left_open)
    play_release_input(&s)
    play_chat_set(&s,true)
    play_chat_set(&s,false)
    testing.expect(t,s.play_input_released && !platform.window_relative_mouse(p))
    s.play_input_released=false
    platform.window_set_relative_mouse(p,true)
    play_pause(&s,true)
    play_chat_set(&s,true)
    play_chat_set(&s,false)
    testing.expect(t,s.mode==.Paused && !s.play_input_released && !platform.window_relative_mouse(p))
    shortcuts_run(&s,{.Tab},{})
    testing.expect(t,!gui.layout.left_open)
    play_pause(&s,false)
    testing.expect(t,s.mode==.Play && platform.window_relative_mouse(p))
}

@(private="file")
Play_Tab_World :: struct {time:core.Time,bindings:input.Input_Map}

// A game that binds Tab gets it while it plays with the input: the chat opens
// with Tab after Eject, and closes with it.
@(test)
a_game_that_binds_tab_gets_it_and_the_chat_waits_for_eject :: proc(t:^testing.T) {
    p,error:=platform.create({headless=true,fixed_dt=1.0/60,pacing=platform.Frame_Pacing{}})
    testing.expect_value(t,error,platform.Error.None)
    if p==nil {return}
    defer platform.destroy(p)
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    storages:=[2]core.Storage_Info{
        {type=core.Time,offset=offset_of(Play_Tab_World,time)},
        {type=input.Input_Map,offset=offset_of(Play_Tab_World,bindings)},
    }
    info:=core.World_Info{storages=storages[:]}
    app:=host.App{info=&info,platform=p,tick_dt=1.0/60}
    world:Play_Tab_World
    viewport:Viewport
    gui:=Editor_Ui{ctx=&ctx}
    ai:=new(Ai);defer free(ai)
    s:=Session{mode=.Play,app=&app,info=&info,gui=&gui,ai=ai,viewport=&viewport}
    s.runs[0]={world=&world}
    press :: proc(s:^Session,p:^platform.Platform,key:core.Key) {
        platform.input_inject(p,platform.Key_Event{key=key,down=true})
        platform.frame_begin(p)
        s.app.ui_input=host.ui_input_from_platform(platform.input_frame(p))
        play_input_update(s)
        platform.input_inject(p,platform.Key_Event{key=key,down=false})
        platform.frame_begin(p)
        play_input_update(s)
    }
    testing.expect(t,!play_tab_to_game(&s),"a game that does not bind Tab leaves it to the chat")
    INVENTORY :: input.Action(3)
    input.input_map_action(&world.bindings,INVENTORY,.Button)
    input.input_map_bind(&world.bindings,INVENTORY,input.binding_key(.Tab))
    testing.expect(t,play_tab_to_game(&s))
    press(&s,p,.Tab)
    testing.expect(t,!s.play_chat_open && !s.play_input_released)
    press(&s,p,.F1)
    testing.expect(t,s.play_input_released && !play_tab_to_game(&s))
    press(&s,p,.Tab)
    testing.expect(t,s.play_chat_open)
    press(&s,p,.Tab)
    testing.expect(t,!s.play_chat_open)
}
