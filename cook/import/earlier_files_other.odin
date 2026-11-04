#+build !windows
package importer

import "core:os"
import "core:strings"
import "core:time"

// The files of folder as os.walker gives them, but those under a folder
// whose name starts with a dot.
@(private)
earlier_files :: proc(folder:string) -> []Found_File {
    found:=make([dynamic]Found_File,context.temp_allocator)
    walker:=os.walker_create(folder)
    defer os.walker_destroy(&walker)
    for info in os.walker_walk(&walker) {
        if strings.has_prefix(info.name,".") {
            if info.type==.Directory {os.walker_skip_dir(&walker)}
            continue
        }
        if info.type!=.Regular {continue}
        path:=strings.clone(info.fullpath,context.temp_allocator)
        append(&found,Found_File{path=path,name=path[len(path)-len(info.name):],size=info.size,
            created=time.time_to_unix_nano(info.creation_time),changed=time.time_to_unix_nano(info.modification_time)})
    }
    return found[:]
}
