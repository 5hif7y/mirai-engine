package editor

import "core:mem"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

Inspector_Default :: struct {
    entity:core.Entity,
    table:^core.Table_Info,
    bytes:[dynamic]u8,
}

inspect_component :: proc(s:^Session,w:core.World_Ref,type:typeid,entities:[]core.Entity) -> (c:Inspect) {
    for &t,index in w.info.tables {
        if t.place!=w.place || t.type!=type {continue}
        c={s=s,w=w,t=&t,index=index,table=core.world_table_at(w,&t),entities=entities,type=type,size=t.info.size,name=t.name}
        if len(entities)>0 {c.value=cast([^]u8)core.raw_find(c.table,t.info,entities[len(entities)-1])}
        return
    }
    return
}

inspector_defaults_sync :: proc(s:^Session) {
    key:=[4]u64{s.selection.serial,s.edits.epoch,u64(s.library_generation),0}
    if p:=prefabs_of(s);p!=nil {key[3]=p.bases_serial}
    ins:=s.inspector
    if ins.defaults_key==key {return}
    for &entry in ins.defaults {delete(entry.bytes)}
    clear(&ins.defaults)
    ins.defaults_key=key
}

// No reset reference for the placement of a prefab root.
inspect_default :: proc(s:^Session,w:core.World_Ref,t:^core.Table_Info,e:core.Entity) -> []u8 {
    inspector_defaults_sync(s)
    for &entry in s.inspector.defaults {
        if entry.entity==e && entry.table==t {return entry.bytes[:]}
    }
    entry:=Inspector_Default{entity=e,table=t}
    id,_:=entity_get(w,e,core.Id)
    link,linked:=prefab_link_of(s,id.value)
    if linked && link.root && t.type==core.Transform {
        append(&s.inspector.defaults,entry)
        return nil
    }
    if resize(&entry.bytes,t.info.size)!=nil {return nil}
    bytes:=entry.bytes[:]
    if t.default!=nil {t.default(raw_data(bytes))} else {component_default(t.type,bytes)}
    if linked {
        if b:=prefab_base_find(prefabs_of(s),link.asset);b!=nil {
            if table,found:=asset.scene_component(b.scene,t.name);found {
                if stored,present:=asset.scene_component_get(b.scene,table,link.source);present {
                    schema:serial.Schema
                    serial.schema_init(&schema,context.temp_allocator)
                    defer serial.schema_destroy(&schema)
                    target,valid:=serial.schema_add_type_info(&schema,t.info)
                    if !valid {delete(entry.bytes);return nil}
                    {
                        migration:serial.Migration
                        defer serial.migration_destroy(&migration)
                        if serial.migration_init(&migration,&b.scene.doc.schema,b.scene.doc.tables[table].columns[1].type,&schema,target,context.temp_allocator)!=.None {
                            delete(entry.bytes)
                            return nil
                        }
                        serial.migration_apply(&migration,bytes,stored,1)
                        for offset in entity_offsets(t.info) {
                            source:=(cast(^base.Entity_Id)&bytes[offset])^
                            resolved:=core.NONE
                            for member in s.document.previous.members {
                                if member.instance!=link.instance || member.source!=source {continue}
                                resolved=core.entity_of(core.world_entities(w),member.entity)
                                break
                            }
                            (cast(^core.Entity)&bytes[offset])^=resolved
                        }
                    }
                }
            }
            if t.type==core.Name {
                if row,found:=asset.scene_entity_find(b.scene,link.source);found {
                    name:=core.Name{asset.scene_names(b.scene)[row]}
                    mem.copy(raw_data(bytes),&name,size_of(core.Name))
                }
            }
        }
    }
    if _,error:=append(&s.inspector.defaults,entry);error!=nil {delete(entry.bytes);return nil}
    return bytes
}

inspect_changed :: proc(c:^Inspect,offset,size:int) -> bool {
    if offset<0 || offset+size>c.size {return false}
    if c.defaults!=nil {return !slice.equal(c.value[offset:][:size],c.defaults[offset:][:size])}
    if c.t==nil {return false}
    for e in c.entities {
        defaults:=inspect_default(c.s,c.w,c.t,e)
        if len(defaults)==0 {continue}
        value:=cast([^]u8)core.raw_find(c.table,c.t.info,e)
        if value!=nil && !slice.equal(value[offset:][:size],defaults[offset:][:size]) {return true}
    }
    return false
}

inspect_reset :: proc(c:^Inspect,offset,size:int) {
    if c.held!=0 && c.panel==nil && c.write==nil {
        if c.defaults!=nil {inspect_write(c,offset,c.defaults[offset:][:size])}
        return
    }
    opened,edit_ready:=edit_open(c.s,"Revert value")
    if !edit_ready {return}
    defer edit_close(c.s,opened)
    if c.defaults!=nil {inspect_write(c,offset,c.defaults[offset:][:size]);return}
    if c.panel!=nil {panel_keep_row(c,offset,size)}
    for e in c.entities {
        defaults:=inspect_default(c.s,c.w,c.t,e)
        if len(defaults)==0 {continue}
        field_write(c.s,c.t,{e},offset,defaults[offset:][:size])
    }
}

REVERT_SIDE :: f32(16)

field_reset_button :: proc(c:^Inspect,offset,size:int) {
    ctx:=c.s.gui.ctx
    key:=base.hash_combine(u64(c.index),u64(offset))
    // While a turn waits for review the arrow is its own: it takes the field
    // back to the value the turn found. Afterwards the usual one returns.
    if task,ok:=inspect_agent(c,offset,size);ok {
        if ui.button(ctx,ui.id(ctx,"revert_agent",int(key&0x7fffffff)),{icon=.Revert,icon_color=ai_agent_color(task),icon_size=12,style=.Ghost,width=REVERT_SIDE,height=REVERT_SIDE}).clicked {
            if _,kept:=ai_review_field_revert(c.s,c.s.ai,c.w,c.t,c.entities,offset,size);kept {notify(c.s,"A newer value was kept")}
        }
        return
    }
    if !inspect_changed(c,offset,size) {ui.spacer(ctx,REVERT_SIDE,1);return}
    if ui.button(ctx,ui.id(ctx,"revert_value",int(key&0x7fffffff)),{icon=.Revert,icon_size=12,icon_color=ctx.theme.text_muted,style=.Ghost,width=REVERT_SIDE,height=REVERT_SIDE}).clicked {inspect_reset(c,offset,size)}
}

// The turn that changed this field of the active entity and still waits.
@(private)
inspect_agent :: proc(c:^Inspect,offset,size:int) -> (task:^Ai_Task,ok:bool) {
    if c.s.ai==nil || c.t==nil || c.storage>0 || len(c.entities)==0 {return}
    task,ok=ai_review_field(c.s,c.s.ai,c.w,c.t,c.entities[len(c.entities)-1],offset,size)
    return
}
