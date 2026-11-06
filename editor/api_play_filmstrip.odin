package editor

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import img "mirai:cook/image"
import "mirai:core"
import "mirai:editor/api"
import gpu "mirai:render"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// A filmstrip of play.capture: the game stepped as play.step steps it and
// drawn before the first tick and every some ticks, a cell of each drawing
// (around where an entity shows, a fixed region or the whole image) put in
// one grid with its tick in its corner.

@(private)
Api_Filmstrip_Cell :: struct {
    tick:u64,
    at:[2]f32, // where the followed entity shows, in window points
    seen:bool, // the entity was in front of the camera
}

@(private)
Api_Filmstrip :: struct {
    run:Api_Step_Run,
    frames,count,columns:int,
    follow:core.Entity, // NONE: the region, or the whole image without one
    size:[2]f32,        // of a cell around follow, in window points
    region:[4]f32,      // in window points; no width: the whole image
    sheet:img.Sheet,
    cells:[]Api_Filmstrip_Cell,
    taken:int,
}

// The filmstrip play.capture asks for, checked; nil when it asks for one image.
@(private)
api_filmstrip_read :: proc(s:^Session,call:^api.Call,r:^Run,own:bool,p:^Api_Play_Capture_Params) -> (strip:^Api_Filmstrip,ok:bool) {
    keys:=[?]string{"every","count","columns","segments","follow","follow_id","follow_entity","size","region"}
    values:[len(keys)]string
    api.object_values(call.allocator,call.raw,keys[:],values[:])
    if p.every==0 {
        for value,i in values[1:] {
            if value!="" {api.call_failf(call,api.INVALID_PARAMS,"%s is of a filmstrip: give it with every (the ticks between two cells) and count, or leave it out",keys[i+1]);return}
        }
        return nil,true
    }
    if p.count==0 {api.call_fail(call,api.INVALID_PARAMS,"count: give the cells of the filmstrip with every; 1 to 64");return}
    total:=p.every*(p.count-1)
    if total>API_STEP_LIMIT {
        api.call_failf(call,api.INVALID_PARAMS,"the filmstrip runs every times count less one ticks (%d) and a call runs at most %d: lower every or count",total,API_STEP_LIMIT)
        return
    }
    if !own {api_play_refused(call);return}
    w:=run_ref(s,r)
    strip=new(Api_Filmstrip,call.allocator)
    strip^={frames=p.frames,count=p.count,columns=p.columns,size=p.size}
    named:=int(values[4]!="")+int(p.follow_id!=0)+int(values[6]!="")
    switch {
    case named>1:
        api.call_fail(call,api.INVALID_PARAMS,"name the entity to follow once: by follow or follow_id or follow_entity");return
    case named==1 && values[8]!="":
        api.call_fail(call,api.INVALID_PARAMS,"give an entity to follow or a region, not both");return
    case named==0 && values[7]!="":
        api.call_fail(call,api.INVALID_PARAMS,"size is the cell around a followed entity: give follow (or follow_id or follow_entity) too, or region in its place");return
    }
    if name:=base.text_get(p.follow[:]);name!="" {
        for e in api_entities_ordered(w) {
            if entity_name(w,e)==name {strip.follow=e;break}
        }
        if strip.follow==core.NONE {api.call_failf(call,api.INVALID_PARAMS,"follow %q names no entity of the game: play.inspect lists them",name);return}
    } else if named==1 {
        problem:string
        if strip.follow,problem=api_play_entity(w,base.text_get(p.follow_entity[:]),p.follow_id,"follow_entity");problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    }
    if values[8]!="" {
        q:=p.region
        if !rpc_finite(q.x) || !rpc_finite(q.y) || !(q.z>=1 && q.z<=4096) || !(q.w>=1 && q.w<=4096) || abs(q.x)>4096 || abs(q.y)>4096 {
            api.call_fail(call,api.INVALID_PARAMS,"region takes x y width height in window points: finite with x and y within 4096 of the corner and a width and a height from 1 to 4096")
            return
        }
        strip.region=q
    }
    steps:[]Api_Step_Input
    if values[3]!="" {steps=api_segments_read(call,p.segments[:],values[3]) or_return}
    given:=api_timeline_ticks(steps)
    if given>total {
        api.call_failf(call,api.INVALID_PARAMS,"segments run %d ticks and the filmstrip %d (every times count less one): shorten them or raise every or count",given,total)
        return
    }
    timeline:=make([]Api_Step_Input,len(steps)+1,call.allocator)
    copy(timeline,steps)
    timeline[len(steps)]={ticks=total-given}
    if total==given {timeline=timeline[:len(steps)]}
    if r.owner==0 && simulating(s) && api_timeline_input(timeline) {api.call_fail(call,api.INVALID_PARAMS,"A simulation takes no player input");return}
    strip.run={owner=r.owner,player=p.player,timeline=timeline,sampler={every=p.every,take=api_filmstrip_take,data=strip}}
    strip.cells=make([]Api_Filmstrip_Cell,p.count,call.allocator)
    return strip,true
}

// Steps the game, takes the cells and writes the filmstrip at path.
@(private)
api_filmstrip_run :: proc(s:^Session,call:^api.Call,strip:^Api_Filmstrip,path:string) {
    defer img.sheet_destroy(&strip.sheet)
    r:=run_player(s,strip.run.owner,strip.run.player)
    if r==nil {api.call_fail(call,api.SERVER_ERROR,"No game is playing; play.start first");return}
    if strip.run.owner==0 && !play_paused(s) {play_pause(s,true,stepped=true)}
    if problem:=api_filmstrip_take(s,strip,run_ref(s,r),0);problem!="" {api.call_fail(call,api.SERVER_ERROR,problem);return}
    if _,_,problem:=api_step_run(s,&strip.run,api_step_frame);problem!="" {
        api.call_failf(call,api.SERVER_ERROR,"%s, after %d cells",problem,strip.taken)
        return
    }
    sheet:=strip.sheet
    // The write takes the pixels.
    strip.sheet={}
    if !api_png_write(s,path,sheet.image.pixels,sheet.image.width,sheet.image.height) {api.call_fail(call,api.SERVER_ERROR,"The filmstrip could not be written");return}
    api_png_content(call,path,api_filmstrip_result(path,sheet,strip.cells[:strip.taken],strip.follow!=core.NONE,call.allocator))
}

// What a filmstrip answers besides its image: where it is, its grid and the tick of each cell.
@(private)
api_filmstrip_result :: proc(path:string,sheet:img.Sheet,cells:[]Api_Filmstrip_Cell,followed:bool,allocator:mem.Allocator) -> string {
    out:serial.Writer
    serial.writer_init(&out,1024,allocator)
    serial.text_write_raw(&out,`{"path":`);serial.text_write_string(&out,path)
    api.write_int(&out,"width",i64(sheet.image.width));api.write_int(&out,"height",i64(sheet.image.height))
    api.write_int(&out,"columns",i64(sheet.columns));api.write_int(&out,"rows",i64(sheet.rows))
    api.write_key(&out,"cell");serial.write_u8(&out,'[')
    serial.text_write_int(&out,i64(sheet.tile.x));serial.write_u8(&out,',');serial.text_write_int(&out,i64(sheet.tile.y))
    serial.write_u8(&out,']')
    api.write_key(&out,"cells");serial.write_u8(&out,'[')
    for &cell,i in cells {
        if i>0 {serial.write_u8(&out,',')}
        serial.text_write_raw(&out,`{"tick":`);serial.text_write_uint(&out,cell.tick)
        if followed {
            api.write_key(&out,"at")
            if cell.seen {api.write_list(&out,cell.at[:])} else {serial.text_write_raw(&out,"null")}
        }
        serial.write_u8(&out,'}')
    }
    serial.text_write_raw(&out,"]}")
    return string(serial.writer_bytes(&out))
}

// A cell of the filmstrip: the game drawn now, the part of it it shows put
// in the grid with the tick in its corner.
@(private)
api_filmstrip_take :: proc(s:^Session,data:rawptr,_:core.World_Ref,ran:int) -> string {
    strip:=cast(^Api_Filmstrip)data
    if strip.taken>=strip.count {return ""}
    r:=run_player(s,strip.run.owner,strip.run.player)
    if r==nil {return "The game ended"}
    pixels,width,height,drawn:=api_play_pixels(s,r,strip.frames)
    if !drawn {return "The game could not be drawn"}
    defer delete(pixels,s.app.allocator)
    w:=run_ref(s,r)
    density:=s.app.ui_input.scale>0?s.app.ui_input.scale:1
    view:=[4]f32{0,0,f32(width),f32(height)}
    if r.owner==0 && s.viewport.size.x>0 && s.viewport.size.y>0 {view={s.viewport.origin.x*density,s.viewport.origin.y*density,s.viewport.size.x*density,s.viewport.size.y*density}}
    cell:=&strip.cells[strip.taken]
    if t:=core.world_storage_of(w,core.Time);t!=nil {cell.tick=t.tick}
    region:img.Region
    switch {
    case strip.follow!=core.NONE:
        center:=view.xy+view.zw*0.5
        if core.alive(core.world_entities(w),strip.follow) {
            // Not its origin, at the feet of a character: the center of mass of a body, or the
            // middle of what hangs from it. The box of a skinned mesh is that of its bind pose.
            placed:=entity_world(w,strip.follow)
            low,high:=placed.position,placed.position
            it:=scene_items(s,w)
            for item in scene_item_next(&it) {
                if !entity_under(w,item.entity,strip.follow) {continue}
                low,high=linalg.min(low,item.world.position),linalg.max(high,item.world.position)
            }
            point:=(low+high)*0.5
            if motions:=core.world_table_of(w,core.Motion);motions!=nil {
                if motion,moves:=core.get(core.read(motions),strip.follow);moves {point=placed.position+mm.quat_rotate(placed.rotation,motion.center)}
            }
            if at,seen:=api_view_project(s.app.camera,view,point);seen {
                center,cell.at,cell.seen=at,at/density,true
            }
        }
        region=api_filmstrip_region(center,strip.size*density,{width,height})
    case strip.region.z>0:
        q:=strip.region*density
        region={int(math.round(q.x)),int(math.round(q.y)),max(int(math.round(q.z)),1),max(int(math.round(q.w)),1)}
    case:
        region={0,0,width,height}
    }
    if strip.sheet.count==0 {
        sheet,error:=img.sheet_make(strip.count,region.w,region.h,s.app.allocator,strip.columns)
        if error!=.None {return fmt.tprintf("No filmstrip of %d cells of %dx%d pixels: %s",strip.count,region.w,region.h,img.error_message(error))}
        strip.sheet=sheet
    }
    if error:=img.sheet_put_region(&strip.sheet,strip.taken,{pixels=pixels,width=width,height=height},region,cell.tick);error!=.None {
        return fmt.tprintf("cell %d: %s",strip.taken,img.error_message(error))
    }
    strip.taken+=1
    return ""
}

// Where a world point shows in pixels of an image whose view (x y width
// height in pixels) the camera draws; false behind the camera.
@(private)
api_view_project :: proc(camera:gpu.Camera,view:[4]f32,point:[3]f32) -> (at:[2]f32,seen:bool) {
    if !(view.z>0) || !(view.w>0) || linalg.length(camera.forward)<1e-6 {return}
    aspect:=view.z/view.w
    near:=max(camera.near,1e-3)
    far:=max(camera.far,near+1)
    projection:mm.Mat4
    if camera.projection==.Orthographic && camera.height>0 {
        half:=camera.height*0.5
        projection=mm.orthographic_off_center(-half*aspect,half*aspect,-half,half,near,far)
    } else {
        projection=mm.perspective(camera.fov_y*mm.RAD_PER_DEG,aspect,near,far)
    }
    // From the eye: far from the centre of the world a matrix with the place would round it.
    screen,_,ok:=mm.world_to_screen(point-camera.position,view.zw,projection*mm.look_at({},camera.forward,camera.up))
    if !ok || !rpc_finite(screen.x) || !rpc_finite(screen.y) {return}
    return view.xy+screen,true
}

// The cell of size pixels centered on center in an image of image pixels;
// a center far off the image gives a cell beside it.
@(private)
api_filmstrip_region :: proc(center,size:[2]f32,image:[2]int) -> img.Region {
    w,h:=max(int(size.x+0.5),1),max(int(size.y+0.5),1)
    c:=center
    if !rpc_finite(c.x) || !rpc_finite(c.y) {c={f32(image.x),f32(image.y)}*0.5}
    c.x=clamp(c.x,-f32(w),f32(image.x+w))
    c.y=clamp(c.y,-f32(h),f32(image.y+h))
    return {int(math.round(c.x))-w/2,int(math.round(c.y))-h/2,w,h}
}
