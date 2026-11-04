package build

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"

@(test)
generated_world_copy_reports_failure_and_publication_keeps_local_storage :: proc(t:^testing.T) {
    folder,error:=os.make_directory_temp("","mirai-copy-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    defer os.remove_all(folder)
    engine:=project.path(folder,"engine",allocator=context.temp_allocator)
    game:=project.path(folder,"project",allocator=context.temp_allocator)
    for path in ([]string{project.path(engine,"core",allocator=context.temp_allocator),project.path(game,"game",allocator=context.temp_allocator)}) {
        if !testing.expect(t,os.make_directory_all(path)==nil) {return}
    }
    source:=`package core
@(component,shared)
Transform :: struct {value:f32}
@(component,locks="Transform")
Owner :: struct {}
@(component)
Id :: struct {value:u64}
@(storage,copy=false,free="local_free")
Local :: struct {socket:rawptr}
@(storage,copy="state_copy",copy_kept="state_copy_kept",swap="state_swap")
State :: struct {value:i32}
@(storage)
Plain :: struct {values:[512]f32}
`
    testing.expect(t,os.write_entire_file(project.path(engine,"core","data.odin",allocator=context.temp_allocator),source)==nil)
    p:=project.Project{root=game,engine_root=engine}
    output:=world_generate(&p,context.temp_allocator)
    if !testing.expect_value(t,len(output.errors),0) {return}
    for text in ([]string{output.game_world,output.editor_world}) {
        testing.expect(t,strings.contains(text,"init_World :: proc(data:rawptr,allocator:runtime.Allocator) -> bool"))
        testing.expect(t,strings.contains(text,"if error!=nil || raw_data(locks)==nil {return false}"))
        testing.expect(t,strings.contains(text,"w.owner.locks[0]={p_core.lock_offset(&w.owner,&w.transform),1,LOCK_NAMES[:],\"Transform\"}"))
        testing.expect(t,strings.contains(text,"if !p_core.entities_copy("))
        // The index of the entities by Id goes on following the table of Id that comes with it.
        testing.expect(t,strings.contains(text,"synced:=p_core.ids_synced(&src.entities,p_core.read(&src.id))"),text)
        testing.expect(t,strings.contains(text,"p_core.ids_moved(&dst.entities,p_core.read(&dst.id),synced)"))
        testing.expect(t,strings.contains(text,"p_core.ids_moved(&a.entities,p_core.read(&a.id),b_synced)"))
        // The copy a history keeps takes the copy_kept of the storage; the others its copy.
        whole,_,changed:=strings.partition(text,"copy_changed_world :: proc")
        testing.expect(t,strings.contains(whole,"if !p_core.state_copy(&dst.state,&src.state)") && !strings.contains(whole,"state_copy_kept"))
        testing.expect(t,strings.contains(changed,"if !p_core.state_copy_kept(&dst.state,&src.state)"))
        testing.expect(t,strings.contains(text,"p_core.state_swap("))
        testing.expect(t,strings.contains(text,"p_core.table_swap("))
        // A multiple assignment of storages keeps LLVM optimizing for a minute (odin-lang/Odin#7937).
        testing.expect(t,strings.contains(text,"gen_slice.ptr_swap_non_overlapping(&a.plain,&b.plain,size_of(a.plain))"),text)
        testing.expect(t,strings.contains(text,"gen_slice.ptr_swap_non_overlapping(&a.entities,&b.entities,size_of(a.entities))"))
        testing.expect(t,!strings.contains(text,"a.plain,b.plain=") && !strings.contains(text,"a.entities,b.entities="))
        testing.expect(t,strings.contains(text,"local:p_core.Local"))
        testing.expect(t,!strings.contains(text,"&dst.local") && !strings.contains(text,"a.local,b.local="))
        testing.expect(t,strings.contains(text,"p_core.local_free(&w.local)"))
        testing.expect(t,strings.contains(text,"info.swap=swap_world"))
    }
}
