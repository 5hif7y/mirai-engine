package editor

import "mirai:platform"

@(private)
view_editor_input_join :: proc(held,next:^platform.Input_Frame) {
    held.keys_down,held.mouse_down=next.keys_down,next.mouse_down
    held.keys_pressed+=next.keys_pressed
    held.keys_released+=next.keys_released
    held.keys_repeated+=next.keys_repeated
    held.mouse_pressed+=next.mouse_pressed
    held.mouse_released+=next.mouse_released
    for clicks,b in next.mouse_clicks {held.mouse_clicks[b]=max(held.mouse_clicks[b],clicks)}
    held.mouse_position,held.mouse_inside=next.mouse_position,next.mouse_inside
    held.mouse_delta+=next.mouse_delta
    held.wheel+=next.wheel
    held.text_count+=copy(held.text[held.text_count:],next.text[:next.text_count])
}

@(private)
view_editor_input :: proc(p:^platform.Platform,frame:^platform.Input_Frame) {
    for key in platform.Key {
        if key in frame.keys_released && key in frame.keys_down {platform.input_inject(p,platform.Key_Event{key=key,down=false})}
        if key in frame.keys_pressed {platform.input_inject(p,platform.Key_Event{key=key,down=true})}
        if key in frame.keys_released && key not_in frame.keys_down {platform.input_inject(p,platform.Key_Event{key=key,down=false})}
        if key in frame.keys_repeated && key not_in frame.keys_pressed {platform.input_inject(p,platform.Key_Event{key=key,down=true,repeat=true})}
    }
    platform.input_inject(p,platform.Window_Event{kind=frame.mouse_inside?.Mouse_Entered:.Mouse_Left})
    platform.input_inject(p,platform.Mouse_Motion_Event{position=frame.mouse_position,delta=frame.mouse_delta})
    for button in platform.Mouse_Button {
        if button in frame.mouse_released && button in frame.mouse_down {platform.input_inject(p,platform.Mouse_Button_Event{button=button,down=false,position=frame.mouse_position})}
        if button in frame.mouse_pressed {platform.input_inject(p,platform.Mouse_Button_Event{button=button,down=true,clicks=max(frame.mouse_clicks[button],1),position=frame.mouse_position})}
        if button in frame.mouse_released && button not_in frame.mouse_down {platform.input_inject(p,platform.Mouse_Button_Event{button=button,down=false,position=frame.mouse_position})}
    }
    if frame.wheel!={} {platform.input_inject(p,platform.Mouse_Wheel_Event{delta=frame.wheel})}
    for codepoint in frame.text[:frame.text_count] {platform.input_inject(p,platform.Text_Event{codepoint})}
}
