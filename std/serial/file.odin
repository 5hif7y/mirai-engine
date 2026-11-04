package serial

import "core:fmt"
import "core:mem"
import "core:os"

File_Error :: enum u8 {
    None,
    Not_Found,
    Open,
    Read,
    Write,
    Rename,
    Too_Large,
    Out_Of_Memory,
    Invalid_Alignment, // not a power of two
}

// The whole file, in memory of the allocator with the alignment asked for.
file_read :: proc(path:string,allocator:=context.allocator,alignment:=WRITER_ALIGNMENT,limit:=i64(max(int))) -> (data:[]u8,error:File_Error) {
    if alignment<=0 || alignment&(alignment-1)!=0 {return nil,.Invalid_Alignment}
    file,open_error:=os.open(path)
    if open_error!=nil {return nil,file_open_error(open_error)}
    defer os.close(file)
    size,size_error:=os.file_size(file)
    if size_error!=nil {return nil,.Read}
    if size>limit {return nil,.Too_Large}
    if size==0 {return nil,.None}
    bytes,alloc_error:=mem.alloc_bytes_non_zeroed(int(size),alignment,allocator)
    if alloc_error!=nil {return nil,.Out_Of_Memory}
    if !file_read_exact(file,bytes) {
        mem.free_bytes(bytes,allocator)
        return nil,.Read
    }
    return bytes,.None
}

// The first bytes of a file, as many as fit the buffer, and its size.
file_read_head :: proc(path:string,buffer:[]u8) -> (head:[]u8,size:i64,error:File_Error) {
    file,open_error:=os.open(path)
    if open_error!=nil {return nil,0,file_open_error(open_error)}
    defer os.close(file)
    size_error:os.Error
    size,size_error=os.file_size(file)
    if size_error!=nil {return nil,0,.Read}
    head=buffer[:min(i64(len(buffer)),size)]
    if !file_read_exact(file,head) {return nil,size,.Read}
    return head,size,.None
}

// A range of a file. Fails when the file ends before it.
file_read_range :: proc(path:string,offset:i64,out:[]u8) -> File_Error {
    file,open_error:=os.open(path)
    if open_error!=nil {return file_open_error(open_error)}
    defer os.close(file)
    if _,seek_error:=os.seek(file,offset,.Start);seek_error!=nil {return .Read}
    return file_read_exact(file,out)?.None:.Read
}

// Writes a temporary file next to the destination and renames it over it: a
// reader sees the previous file or the new one, never a part of either. sync
// also waits for the device before the rename, which survives a power loss.
file_write_atomic :: proc(path:string,data:[]u8,sync:=false) -> File_Error {
    buffer:[1024]u8
    staging:=len(path)+32<=len(buffer)?fmt.bprintf(buffer[:],"%s.%d.tmp",path,os.get_pid()):fmt.tprintf("%s.%d.tmp",path,os.get_pid())
    file,open_error:=os.open(staging,{.Write,.Create,.Trunc},os.Permissions_Read_All+{.Write_User})
    if open_error!=nil {return .Open}
    written:=0
    for written<len(data) {
        count,write_error:=os.write(file,data[written:])
        if write_error!=nil || count<=0 {
            os.close(file)
            os.remove(staging)
            return .Write
        }
        written+=count
    }
    synced:=!sync || os.sync(file)==nil
    if os.close(file)!=nil || !synced {
        os.remove(staging)
        return .Write
    }
    if os.rename(staging,path)!=nil {
        os.remove(staging)
        return .Rename
    }
    return .None
}

@(private)
file_open_error :: proc(error:os.Error) -> File_Error {
    if general,is_general:=error.(os.General_Error);is_general && general==.Not_Exist {return .Not_Found}
    return .Open
}

@(private)
file_read_exact :: proc(file:^os.File,out:[]u8) -> bool {
    total:=0
    for total<len(out) {
        count,error:=os.read(file,out[total:])
        total+=count
        if error!=nil || count<=0 {break}
    }
    return total==len(out)
}
