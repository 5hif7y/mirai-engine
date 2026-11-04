package editor

import "base:runtime"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:std/base"

@(private="file")
Prefab_Migration_Failure :: struct {owner:runtime.Allocator,remaining:int}

@(private="file")
prefab_migration_failure_allocator :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    state:=(^Prefab_Migration_Failure)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        if state.remaining==0 {return nil,.Out_Of_Memory}
        state.remaining-=1
    }
    return state.owner.procedure(state.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

@(test)
prefab_value_migration_failure_preserves_the_destination_and_retries :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    cap,prefab:asset.Scene
    if !testing.expect_value(t,asset.scene_init(&cap,&types,asset.KIND_SCENE,{1,2}),asset.Error.None) {return}
    defer asset.scene_destroy(&cap)
    if !testing.expect_value(t,asset.scene_init(&prefab,&types,asset.KIND_PREFAB,{3,4}),asset.Error.None) {return}
    defer asset.scene_destroy(&prefab)
    asset.scene_entity_add(&cap,1,0,"Source")
    asset.scene_entity_add(&prefab,2,0,"Destination")
    before:=core.Transform{{1,2,3},1,{1,1,1}}
    wanted:=core.Transform{{9,8,7},1,{2,3,4}}
    testing.expect_value(t,asset.scene_set(&prefab,2,"Transform",&before),asset.Error.None)
    testing.expect_value(t,asset.scene_set(&cap,1,"Transform",&wanted),asset.Error.None)
    cap_table,_:=asset.scene_component(&cap,"Transform")
    base_table,_:=asset.scene_component(&prefab,"Transform")
    pair:=Prefab_Pair{cap_table=cap_table,base_table=base_table}
    inverse:=make(map[base.Entity_Id]base.Entity_Id,context.temp_allocator)
    for allowed in 0..<4 {
        failure:=Prefab_Migration_Failure{owner=context.temp_allocator,remaining=allowed}
        error:Prefab_Error
        {
            context.temp_allocator={prefab_migration_failure_allocator,&failure}
            error=prefab_value_apply(&pair,&cap,&prefab,1,2,"",inverse)
        }
        testing.expect_value(t,error,Prefab_Error.Out_Of_Memory)
        actual,found:=asset.scene_get(&prefab,2,"Transform",core.Transform)
        testing.expect(t,found)
        testing.expect_value(t,actual,before)
    }
    testing.expect_value(t,prefab_value_apply(&pair,&cap,&prefab,1,2,"",inverse),Prefab_Error.None)
    actual,found:=asset.scene_get(&prefab,2,"Transform",core.Transform)
    testing.expect(t,found)
    testing.expect_value(t,actual,wanted)
}
