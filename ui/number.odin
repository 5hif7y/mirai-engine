package ui

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

// Number fields: a drag scrubs the value, a click types it with all of it
// selected and a double click puts the caret where it lands. While it is typed
// a drag selects part of it. Vectors and colors are rows of them with a
// colored mark per axis.

@(private)
Scrub :: struct {
    id:Id,
    origin:f64, // the value when the button went down: every step starts from it
    moved:bool, // the pointer left the click tolerance, so it is a scrub
}

SCRUB_TOLERANCE :: f32(3)
// Decimals of the text a number is typed from.
NUMBER_EDIT_DECIMALS :: 5

Number_Field :: struct {
    width:Size,      // GROW when unset
    height:f32,      // the row of the theme when 0
    size:f32,        // text size; font_small when 0
    label:string,    // short text inside the field, before its value
    icon:Icon,       // an icon there instead of the label
    strip:Color,     // axis color on its left edge
    unit:string,     // at the right end of the field: °, ms, Hz
    decimals:int,    // shown; 0 means 3
    integer:bool,    // whole values, shown without decimals
    speed:f64,       // value per unit dragged; 0 means 0.01
    min,max:f64,     // limits, applied when has_min and has_max
    has_min,has_max:bool,
    mixed:bool,      // several objects with different values: shows "Multiple"
    typed_only:bool, // a press types; dragging does nothing
    bare:bool,       // a slider: its track alone, without the field that types the value
    disabled:bool,
}
Number_Result :: struct {
    changed:bool,   // value^ changed this frame
    editing:bool,
    scrubbing:bool,
    began:bool,     // a scrub or an edit began this frame: the last moment before the value changes
    ended:bool,     // the scrub or the edit ended this frame
    cancelled:bool, // Escape: value^ is back to what it was when it began
    invalid:bool,   // the typed text is not a number; value^ keeps its value
    tab:int,        // 1 or -1 when Tab or Shift+Tab ended the edit
}

// Shortest readable form of a number with at most `decimals` decimals, kept
// until the frame is drawn.
number_text :: proc(ctx:^Context,value:f64,decimals:int=3) -> string {
    buffer:=text_reserve(ctx,48)
    if buffer==nil {return ""}
    return text_commit(ctx,number_format(buffer,value,decimals))
}
number_format :: proc(buffer:[]u8,value:f64,decimals:int=3) -> string {
    if math.is_nan(value) {return fmt.bprintf(buffer,"nan")}
    if math.is_inf(value) {return fmt.bprintf(buffer,"inf" if value>0 else "-inf")}
    text:=fmt.bprintf(buffer,"%.*f",clamp(decimals,0,9),value)
    if strings.contains_rune(text,'.') {text=strings.trim_right(strings.trim_right(text,"0"),".")}
    if text=="-0" {return "0"}
    return text
}

@(private)
number_limit :: proc(field:Number_Field,value:f64) -> f64 {
    v:=value
    if field.integer {v=math.round(v)}
    if field.has_min {v=max(v,field.min)}
    if field.has_max {v=min(v,field.max)}
    return v
}

number_field :: proc(ctx:^Context,id:Id,value:^f64,field:Number_Field={}) -> (result:Number_Result) {
    field:=field
    field.disabled|=ctx.disabled_depth>0
    th:=&ctx.theme
    e:=&ctx.edit
    s:=&ctx.scrub
    if field.disabled {
        if e.id==id && id!=0 {e^={};result.ended,result.cancelled=true,true}
        if s.id==id && id!=0 {s^={};result.ended,result.cancelled=true,true}
    }
    size:=field.size if field.size>0 else th.font_small
    decimals:=0 if field.integer else (field.decimals if field.decimals>0 else 3)
    it:=interact(ctx,id,{.Focusable}+({.Disabled} if field.disabled else {}))
    begin_edit:=false
    if e.id==id && id!=0 {
        event,tab:=field_edit_update(ctx,id,it,size,field.label,false,field.strip[3]>0,icon=field.icon)
        #partial switch event {
        case .Commit:
            text:=strings.trim_space(text_edit_value(e))
            if e.modified {
                number,ok:=strconv.parse_f64(text)
                if ok && !math.is_nan(number) && !math.is_inf(number) {
                    if limited:=number_limit(field,number);limited!=value^ {value^=limited;result.changed=true}
                } else if text!="" {result.invalid=true}
            }
            e^={}
            result.ended=true;result.tab=tab
            if tab!=0 && ctx.navigation {
                if next:=focus_peek(ctx,id,tab);next!=0 {ctx.focus=next;ctx.focus_ring=true;edit_request(ctx,next)}
            }
        case .Cancel:
            e^={}
            result.cancelled=true;result.ended=true
            ctx.escape_used=true
        }
    } else if !field.disabled && id!=0 {
        if it.pressed {
            if field.typed_only {begin_edit=true} else {s^={id=id,origin=value^}}
        } else if ctx.activate==id || ctx.edit_request==id {begin_edit=true}
        if s.id==id {
            delta:=ctx.pointer.x-ctx.press.x
            if !s.moved && abs(delta)>SCRUB_TOLERANCE {s.moved=true;result.began=true}
            if s.moved {
                // Always from the value the scrub began with, so it never drifts.
                speed:=(field.speed if field.speed>0 else 0.01)*(0.1 if .Shift in ctx.input.modifiers else 1)
                if next:=number_limit(field,s.origin+f64(delta)*speed);next!=value^ {value^=next;result.changed=true}
                if .Escape in ctx.input.keys_pressed {
                    if value^!=s.origin {value^=s.origin;result.changed=true}
                    result.cancelled=true;result.ended=true
                    s^={}
                    ctx.escape_used=true
                    if ctx.active==id {ctx.active=0}
                }
            }
            if s.id==id && (it.released || !it.active) {
                // A click without dragging types the value instead.
                if s.moved {result.ended=true} else if it.released {begin_edit=true}
                s^={}
            }
        }
        if begin_edit {
            buffer:[48]u8
            field_edit_begin(ctx,id,number_format(buffer[:],value^,0 if field.integer else NUMBER_EDIT_DECIMALS),.Number,TEXT_EDIT_CAPACITY,true)
            result.began=true
        }
        if it.hot || s.id==id {ctx.cursor=.Text if e.id==id || field.typed_only else .Resize_Horizontal}
    }
    result.editing=e.id==id && id!=0
    result.scrubbing=s.id==id && s.moved && id!=0
    text:="Multiple" if field.mixed else number_text(ctx,value^,decimals)
    paint:=field_paint(ctx,id,it,text,size,field.label,field.strip,"",s.id==id && id!=0,field.disabled,field.icon)
    if paint!=nil {paint.detail=field.unit}
    element_leaf(ctx,{id=id,layout={width=(field.width if field.width!={} else GROW),height=fixed(field.height if field.height>0 else th.row)},custom=paint})
    return
}

slider_field :: proc(ctx:^Context,id:Id,value:^f64,field:Number_Field={}) -> (result:Number_Result) {
    span:=field.max-field.min
    if !field.has_min || !field.has_max || field.max<=field.min || math.is_nan(span) || math.is_inf(span) || math.is_nan(value^) || math.is_inf(value^) {
        return number_field(ctx,id,value,field)
    }
    th:=&ctx.theme
    disabled:=field.disabled || ctx.disabled_depth>0
    track:=id_derive(ctx,id,"track")
    s:=&ctx.scrub
    if disabled && s.id==track {
        s^={}
        result.ended,result.cancelled=true,true
    }
    if box(ctx,{width=field.width if field.width!={} else GROW,height=fixed(field.height if field.height>0 else th.row),gap=5,align_y=.Center}) {
        it:=interact(ctx,track,{.Focusable}+({.Disabled} if disabled else {}))
        if it.pressed && !disabled {
            s^={id=track,origin=value^,moved=true}
            result.began=true
        }
        if s.id==track && !disabled {
            if r,found:=widget_rect(ctx,track);found && r.w>12 {
                fraction:=clamp(f64((ctx.pointer.x-r.x-6)/(r.w-12)),0,1)
                next:=number_limit(field,field.min+fraction*span)
                if next!=value^ {value^=next;result.changed=true}
            }
            result.scrubbing=true
            if .Escape in ctx.input.keys_pressed {
                if value^!=s.origin {value^=s.origin;result.changed=true}
                result.cancelled,result.ended=true,true
                s^={}
                ctx.escape_used=true
                if ctx.active==track {ctx.active=0}
            } else if it.released || !it.active {
                result.ended=true
                s^={}
            }
        } else if !disabled && it.focused && ctx.edit.id==0 {
            direction:=0
            if .Left in ctx.input.keys_repeated {direction=-1}
            if .Right in ctx.input.keys_repeated {direction=1}
            if direction!=0 {
                step:=field.speed if field.speed>0 else span/100
                if .Shift in ctx.input.modifiers {step*=0.1}
                if field.integer {step=max(step,1)}
                next:=number_limit(field,value^+f64(direction)*step)
                if next!=value^ {value^=next;result.changed=true;result.began=true;result.ended=true}
            }
        }
        color:=th.text_faint if disabled else th.text
        paint:=paint_add(ctx,{kind=.Slider,fill=th.rule,fill2=th.accent_soft if disabled else th.accent,stroke=color,value=f32(clamp((value^-field.min)/span,0,1)),center=it.hot || it.active})
        element_leaf(ctx,{id=track,layout={width=GROW,height=fixed(field.height if field.height>0 else th.row)},custom=paint})
        if !field.bare {
            number:=field
            number.width,number.typed_only=fixed(46+(text_width(&ctx.font,field.unit,FIELD_UNIT)+4 if field.unit!="" else 0)),true
            typed:=number_field(ctx,id_derive(ctx,id,"number"),value,number)
            result.changed|=typed.changed
            result.began|=typed.began
            result.ended|=typed.ended
            result.cancelled|=typed.cancelled
            result.editing,result.invalid,result.tab=typed.editing,typed.invalid,typed.tab
        }
    }
    return
}

Vector_Field :: struct {
    using number:Number_Field, // what every axis shares; the strip comes from the axis
    channels:bool,   // R, G, B, A with the channel colors instead of X, Y, Z, W
    mixed_axes:[4]bool,
}

// One number field per value, to be placed in a row. axis: the one the result
// is about, or -1 when nothing happened.
vector_field :: proc(ctx:^Context,id:Id,values:[]f64,field:Vector_Field={}) -> (result:Number_Result,axis:int) {
    th:=&ctx.theme
    axis=-1
    count:=min(len(values),4)
    id_push(ctx,id)
    defer id_pop(ctx)
    for i in 0..<count {
        one:=field.number
        one.strip=th.channel[i] if field.channels else th.axis[i]
        one.mixed=field.mixed_axes[i] || field.number.mixed
        r:=number_field(ctx,ui_axis_id(ctx,i),&values[i],one)
        // Tab moves to the next component of the same property.
        if r.tab>0 && i+1<count {edit_request(ctx,ui_axis_id(ctx,i+1))}
        if r.tab<0 && i>0 {edit_request(ctx,ui_axis_id(ctx,i-1))}
        if r!={} && (axis<0 || r.changed || r.began || r.ended) {result,axis=r,i}
    }
    return
}
@(private)
ui_axis_id :: proc(ctx:^Context,axis:int) -> Id {return id(ctx,"axis",axis+1)}
