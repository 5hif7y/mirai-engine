package cache

import "core:fmt"
import "core:os"
import "core:slice"
import "core:time"
import "mirai:asset"
import "mirai:std/base"

// What an import or a cook built, kept by what it was made from in a folder
// of the caches of a project (project.cache_path), so that building it again
// reads it instead. A file of the cache is an asset whose id is its key and
// the version of what built it: a builder that gives other bytes misses every
// earlier file. A file that does not read back whole is a miss too. A read
// marks the file used; a write that leaves the folder above its budget
// removes the files used longest ago, down to three quarters of it. Deleting
// the folder costs only the time of building again.

// The id of the file of key, built by version.
id :: proc "contextless" (key,version:u64) -> base.Asset_Id {return {key,version}}

// Where the file of key goes, in the temp allocator.
file_path :: proc(folder:string,key:u64,extension:string) -> string {
    return fmt.tprintf("%s/%016x%s",folder,key,extension)
}

// The file of key built by version, open in file for the caller to close and
// marked used. False without one, or with one that does not read back whole.
load :: proc(folder:string,key,version:u64,extension:string,file:^asset.Asset,allocator:=context.allocator) -> bool {
    if folder=="" {return false}
    path:=file_path(folder,key,extension)
    if asset.asset_load(file,path,allocator)!=.None {return false}
    if file.blob.header.id!=id(key,version) || !asset.blob_verify_hash(&file.blob) {
        asset.asset_close(file)
        return false
    }
    now:=time.now()
    _=os.change_times(path,now,now)
    return true
}

// Whether a file can be written into folder, which is made when missing.
ready :: proc(folder:string) -> bool {
    if folder=="" {return false}
    return os.is_dir(folder) || os.make_directory_all(folder)==nil
}

// Keeps folder within budget bytes: above it, the files used longest ago go
// until three quarters of it are left. How many went.
trim :: proc(folder:string,budget:i64) -> (removed:int) {
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return}
    total:=i64(0)
    for entry in entries {total+=entry.size}
    if total<=budget {return}
    slice.sort_by(entries,proc(a,b:os.File_Info) -> bool {return time.diff(a.modification_time,b.modification_time)>0})
    for entry in entries {
        if total<=budget/4*3 {break}
        if entry.type==.Regular && os.remove(entry.fullpath)==nil {
            total-=entry.size
            removed+=1
        }
    }
    return
}
