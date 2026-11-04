package ui

import "base:runtime"
import "core:math"
import "core:mem"
import "core:testing"

// Shared by the tests of the package.

TEST_SMALL :: Context_Desc{max_elements=1024,max_vertices=65536,max_widgets=512,max_text=16384,no_font=true}
TEST_FONT :: Context_Desc{max_elements=1024,max_vertices=65536,max_widgets=512,max_text=16384}

Test_Build :: #type proc(ctx:^Context,user:rawptr)

test_input :: proc(width:f32=800,height:f32=600) -> Input {
    return {size={width,height},dt=1.0/60,pointer={-100,-100}}
}
// One frame: the input as it is, then its edges are forgotten.
test_frame :: proc(ctx:^Context,input:^Input,build:Test_Build,user:rawptr=nil) -> Frame {
    frame_begin(ctx,input^)
    if build!=nil {build(ctx,user)}
    frame:=frame_end(ctx)
    input_next_frame(input)
    return frame
}
test_rect :: proc(t:^testing.T,ctx:^Context,id:Id,loc:=#caller_location) -> Rect {
    rect,found:=widget_rect(ctx,id)
    testing.expectf(t,found,"element %v was laid out",id,loc=loc)
    return rect
}
test_near :: proc(a,b:f32,tolerance:f32=0.01) -> bool {return abs(a-b)<=tolerance}
test_rect_near :: proc(a,b:Rect,tolerance:f32=0.01) -> bool {
    return test_near(a.x,b.x,tolerance)&&test_near(a.y,b.y,tolerance)&&test_near(a.w,b.w,tolerance)&&test_near(a.h,b.h,tolerance)
}
// Moves the pointer onto a rectangle and presses or releases the left button.
test_point :: proc(input:^Input,rect:Rect) {input.pointer={rect.x+rect.w*0.5,rect.y+rect.h*0.5}}
test_press :: proc(input:^Input,clicks:u8=1) {input_button(input,.Left,true,clicks)}
test_release :: proc(input:^Input) {input_button(input,.Left,false)}
test_key :: proc(input:^Input,key:Key) {
    input.keys_pressed+={key};input.keys_repeated+={key}
}
test_type :: proc(input:^Input,text:string) {for c in text {input_text(input,c)}}

// Counts every request an allocator gets.
Test_Counter :: struct {backing:runtime.Allocator,requests:int}
test_counter_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,location:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    counter:=cast(^Test_Counter)data
    #partial switch mode {
    case .Alloc,.Alloc_Non_Zeroed,.Resize,.Resize_Non_Zeroed:counter.requests+=1
    }
    return counter.backing.procedure(counter.backing.data,mode,size,alignment,old_memory,old_size,location)
}
test_counter :: proc(counter:^Test_Counter,backing:runtime.Allocator) -> runtime.Allocator {
    counter^={backing=backing}
    return {procedure=test_counter_proc,data=counter}
}

@(test)
context_is_created_with_the_capacities_of_its_desc :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,{max_elements=512,max_text_words=1024,max_clips=12,max_widgets=64,max_paints=128,max_vertices=1000,max_commands=8,max_text=256,max_scopes=4,max_panels=2,no_font=true}))
    defer context_destroy(&ctx)
    testing.expect_value(t,len(ctx.widgets),64)
    testing.expect_value(t,len(ctx.paints),128)
    testing.expect_value(t,len(ctx.draw.vertices),1000)
    testing.expect_value(t,len(ctx.draw.commands),8)
    testing.expect_value(t,len(ctx.text),256)
    testing.expect_value(t,len(ctx.scopes),4)
    testing.expect_value(t,len(ctx.panels),2)
    testing.expect_value(t,len(ctx.clips),13)
    testing.expect_value(t,len(ctx.layout.nodes),513)
    testing.expect_value(t,len(ctx.layout.measures[0].words),1024)
    testing.expect_value(t,len(ctx.layout.measures[1].chars),256)
    testing.expect_value(t,ctx.theme,THEME_EDITOR)
}

@(test)
context_creation_fails_without_memory_and_leaves_nothing :: proc(t:^testing.T) {
    // An allocator that refuses everything after a few requests.
    Limited :: struct {backing:runtime.Allocator,left:int}
    limited_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,location:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        limited:=cast(^Limited)data
        #partial switch mode {
        case .Alloc,.Alloc_Non_Zeroed:
            if limited.left<=0 {return nil,.Out_Of_Memory}
            limited.left-=1
        }
        return limited.backing.procedure(limited.backing.data,mode,size,alignment,old_memory,old_size,location)
    }
    // Every request refused in turn, until there are enough to succeed.
    created:=false
    for allowed in 0..<64 {
        limited:=Limited{context.allocator,allowed}
        ctx:Context
        desc:=TEST_SMALL
        desc.allocator={procedure=limited_proc,data=&limited}
        if context_init(&ctx,desc) {context_destroy(&ctx);created=true;break}
        testing.expect_value(t,len(ctx.layout.nodes),0)
        testing.expect_value(t,len(ctx.widgets),0)
    }
    testing.expect(t,created)
}

@(test)
ids_depend_on_name_index_and_scope_and_are_never_zero :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    a,b,c:=id(&ctx,"row"),id(&ctx,"row",1),id(&ctx,"column")
    testing.expect(t,a!=b && a!=c && b!=c)
    testing.expect_value(t,id(&ctx,"row"),a)
    id_push(&ctx,id(&ctx,"list"))
    inner:=id(&ctx,"row")
    testing.expect(t,inner!=a,"A scope changes the ids made inside it")
    testing.expect_value(t,id_derive(&ctx,id(&ctx,"x"),"y"),id_derive(&ctx,id(&ctx,"x"),"y"))
    id_pop(&ctx)
    testing.expect_value(t,id_derive(&ctx,id(&ctx,"list"),"row"),inner)
    testing.expect(t,id(&ctx,"")!=0)
}

@(test)
frame_text_outlives_the_buffer_it_came_from_and_counts_what_does_not_fit :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_SMALL
    desc.max_text=16
    testing.expect(t,context_init(&ctx,desc))
    defer context_destroy(&ctx)
    input:=test_input()
    frame_begin(&ctx,input)
    buffer:=[8]u8{'a','b','c','d','e','f','g','h'}
    stored:=text_store(&ctx,string(buffer[:]))
    buffer={}
    testing.expect_value(t,stored,"abcdefgh")
    testing.expect_value(t,text_store(&ctx,"12345678"),"12345678")
    testing.expect_value(t,text_store(&ctx,"x"),"")
    testing.expect_value(t,ctx.stats.dropped_text,u32(1))
    frame:=frame_end(&ctx)
    testing.expect(t,frame.overflow)
    frame_begin(&ctx,input)
    testing.expect_value(t,text_store(&ctx,"again"),"again")
    testing.expect(t,!frame_end(&ctx).overflow,"Overflow is of one frame; the counters add up")
    testing.expect_value(t,ctx.stats.dropped_text,u32(1))
}

@(test)
boxes_are_laid_out_in_rows_and_columns :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input(800,600)
    test_frame(&ctx,&input,proc(ctx:^Context,user:rawptr) {
        if box(ctx,{id=id(ctx,"root"),width=fixed(400),height=fixed(300),direction=.Column,padding={10,20,30,40},gap=5,track=true}) {
            if box(ctx,{id=id(ctx,"top"),width=GROW,height=fixed(50),gap=10,track=true}) {
                box_begin(ctx,{id=id(ctx,"a"),width=fixed(100),height=GROW,track=true});box_end(ctx,{id=id(ctx,"a")})
                box_begin(ctx,{id=id(ctx,"b"),width=GROW,height=GROW,track=true});box_end(ctx,{id=id(ctx,"b")})
            }
            if box(ctx,{id=id(ctx,"rest"),width=percent(0.5),height=GROW,align_x=.End,align_y=.Center,track=true}) {
                box_begin(ctx,{id=id(ctx,"c"),width=fixed(20),height=fixed(20),track=true});box_end(ctx,{id=id(ctx,"c")})
            }
        }
    })
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"root")),{0,0,400,300}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"top")),{10,20,360,50}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"a")),{10,20,100,50}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"b")),{120,20,250,50}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"rest")),{10,75,180,185}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"c")),{170,157.5,20,20}))
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
}

@(test)
floating_boxes_hang_from_the_surface_and_from_its_safe_area :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input(800,600)
    input.safe={40,10,20,30}
    test_frame(&ctx,&input,proc(ctx:^Context,user:rawptr) {
        box_begin(ctx,{id=id(ctx,"corner"),width=fixed(100),height=fixed(50),float={to=.Surface,anchor=.Bottom_Right,pivot=.Bottom_Right,offset={-10,-10},layer=LAYER_PANEL},track=true})
        box_end(ctx,{id=id(ctx,"corner"),float={to=.Surface}})
        if anchored(ctx,id(ctx,"hud"),.Top_Left,{5,5},{width=fixed(60),height=fixed(20)}) {spacer_tracked(ctx,"hud_in")}
        if anchored(ctx,id(ctx,"ammo"),.Bottom_Right,{0,0},{width=fixed(60),height=fixed(20)}) {spacer_tracked(ctx,"ammo_in")}
        if anchored(ctx,id(ctx,"title"),.Center,{0,0},{width=fixed(100),height=fixed(40)}) {spacer_tracked(ctx,"title_in")}
        if anchored(ctx,id(ctx,"raw"),.Top_Left,{5,5},{width=fixed(60),height=fixed(20)},0,false) {spacer_tracked(ctx,"raw_in")}
    })
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"corner")),{690,540,100,50}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"hud_in")),{45,15,60,20}),"Anchored elements stay inside the safe area")
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"ammo_in")),{720,550,60,20}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"title_in")),{360,270,100,40}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,id(&ctx,"raw_in")),{5,5,60,20}))
}

@(test)
elements_beyond_the_capacity_are_refused_and_counted :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_SMALL
    desc.max_elements=64
    testing.expect(t,context_init(&ctx,desc))
    defer context_destroy(&ctx)
    input:=test_input()
    frame:=test_frame(&ctx,&input,proc(ctx:^Context,user:rawptr) {
        if box(ctx,{id=id(ctx,"column"),width=fixed(200),direction=.Column,track=true}) {
            for i in 0..<100 {
                // Containers and what they hold are skipped together.
                if box(ctx,{id=id(ctx,"row",i+1),width=GROW,height=fixed(10),track=true}) {label(ctx,"text")}
            }
        }
    })
    testing.expect(t,frame.overflow)
    testing.expect(t,ctx.stats.dropped_elements>0)
    testing.expect(t,int(ctx.stats.elements)<64)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
    first:=test_rect(t,&ctx,id(&ctx,"row",1))
    testing.expect(t,test_rect_near(first,{0,0,200,10}),"What fits is laid out")
    // A frame that fits follows without trace of the overflow.
    frame=test_frame(&ctx,&input,proc(ctx:^Context,user:rawptr) {label(ctx,"fits")})
    testing.expect(t,!frame.overflow)
    _=math.PI;_=mem.Byte
}

// An element that fills its parent and keeps its rectangle.
spacer_tracked :: proc(ctx:^Context,name:string) {
    box_begin(ctx,{id=id(ctx,name),width=GROW,height=GROW,track=true})
    box_end(ctx,{id=id(ctx,name)})
}

mem_nil_allocator :: proc() -> runtime.Allocator {
    refuse :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,location:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        #partial switch mode {
        case .Alloc,.Alloc_Non_Zeroed,.Resize,.Resize_Non_Zeroed:return nil,.Out_Of_Memory
        }
        return nil,nil
    }
    return {procedure=refuse}
}
