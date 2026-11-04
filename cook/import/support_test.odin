package importer

import "core:fmt"
import "core:os"
import "core:sync"
import "mirai:asset"
import mm "mirai:std/math"

BENCH :: #config(COOK_BENCH,false)

// A fresh folder in the temp directory.
temp_folder :: proc(name:string) -> string {
    directory,_:=os.temp_directory(context.temp_allocator)
    // Of the thread too: tests that run at once with one name do not share it.
    path:=fmt.tprintf("%s/mirai-import-%d-%d-%s",directory,os.get_pid(),sync.current_thread_id(),name)
    os.remove_all(path)
    os.make_directory_all(path)
    return path
}

// A white vertex whose second set of texture coordinates is its first.
test_vertex :: proc(position,normal:[3]f32,uv:[2]f32) -> asset.Vertex {
    return {position=position,normal=mm.normal_pack(normal),uv=uv,color=0xffffffff,uv1=uv}
}
