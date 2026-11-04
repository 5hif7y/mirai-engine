package core

import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file")
Indexed_World :: struct {
    es:Entities,
    parents:Table(Parent),
    worlds:Table(World_Transform),
    jumps:Jumps,
    id:World_Id,
}

@(private="file")
Progress :: struct {level:f32}

@(test)
an_indexed_world_info_finds_what_its_lists_hold_and_describes_its_values_once :: proc(t:^testing.T) {
    w:Indexed_World
    tables:=[]Table_Info{
        {name="Parent",type=Parent,info=type_info_of(Parent),offset=offset_of(Indexed_World,parents)},
        {name="World_Transform",type=World_Transform,info=type_info_of(World_Transform),offset=offset_of(Indexed_World,worlds)},
        {name="Editor_Only",type=Name,info=type_info_of(Name),place=.Editor},
    }
    storages:=[]Storage_Info{
        {name="Jumps",type=Jumps,info=type_info_of(Jumps),offset=offset_of(Indexed_World,jumps)},
        {name="World_Id",type=World_Id,info=type_info_of(World_Id),offset=offset_of(Indexed_World,id),by_world=true},
        {name="Progress",type=Progress,info=type_info_of(Progress),persist=true},
    }
    listed:=World_Info{entities=offset_of(Indexed_World,es),tables=tables,storages=storages}
    indexed:=listed
    world_info_index(&indexed,context.temp_allocator)
    testing.expect(t,indexed.tables_by_type!=nil && indexed.storages_by_type!=nil && indexed.schema!=nil)

    for info in ([]^World_Info{&listed,&indexed}) {
        ref:=world_ref(&w,info)
        testing.expect(t,world_table_of(ref,Parent)==&w.parents)
        testing.expect(t,world_table_of(ref,World_Transform)==&w.worlds)
        testing.expect(t,world_table_of(ref,Name)==nil,"a table of another place is not one of this world")
        testing.expect(t,world_table_of(ref,Transform)==nil)
        testing.expect(t,world_storage_of(ref,Jumps)==&w.jumps)
        testing.expect(t,world_storage_of(ref,World_Id)==nil,"a by_world storage is found through its application")
        at,found:=world_table_index_of_hash(ref,base.name_hash("World_Transform"))
        testing.expect(t,found && at==1)
        _,found=world_table_index_of_hash(ref,base.name_hash("Editor_Only"))
        testing.expect(t,!found,"a table of another place is not one of this world")
        _,found=world_table_index_of_hash(ref,base.name_hash("Transform"))
        testing.expect(t,!found)
        at,found=world_table_index_of_hash(world_ref(&w,info,.Editor),base.name_hash("Editor_Only"))
        testing.expect(t,found && at==2)
    }

    schema:=indexed.schema
    parent:=schema.tables[0]
    testing.expect(t,parent.type!=serial.TYPE_NONE && len(parent.entities)==1 && parent.entities[0]==u32(offset_of(Parent,entity)))
    testing.expect_value(t,parent.hash,serial.schema_layout_hash(&schema.schema,parent.type))
    world:=schema.tables[1]
    testing.expect(t,world.type!=serial.TYPE_NONE && len(world.layout.runs)==0,"a world transform is transient: nothing of it is saved")
    testing.expect(t,schema.storages[0].type==serial.TYPE_NONE,"only the storages of the scene are described")
    testing.expect(t,schema.storages[2].type!=serial.TYPE_NONE && schema.storages[2].layout.dense)
}
