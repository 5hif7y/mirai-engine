#+build windows
package importer

import "core:strings"
import win32 "core:sys/windows"

// The files of folder as os.walker gives them, breadth first in the order the
// system lists each folder, from what the listing says of each: os.walker
// opens every file it lists, which costs more than listing it.
@(private)
earlier_files :: proc(folder:string) -> []Found_File {
    found:=make([dynamic]Found_File,context.temp_allocator)
    todo:=make([dynamic]string,context.temp_allocator)
    append(&todo,folder)
    for at:=0;at<len(todo);at+=1 {
        dir:=todo[at]
        separator:=strings.has_suffix(dir,"\\") || strings.has_suffix(dir,"/")?"":"\\"
        data:win32.WIN32_FIND_DATAW
        handle:=win32.FindFirstFileW(win32.utf8_to_wstring(strings.concatenate({dir,separator,"*"},context.temp_allocator)),&data)
        if handle==win32.INVALID_HANDLE_VALUE {continue}
        for {
            name,_:=win32.wstring_to_utf8(win32.wstring(raw_data(data.cFileName[:])),-1,context.temp_allocator)
            attributes:=data.dwFileAttributes
            link:=attributes&win32.FILE_ATTRIBUTE_REPARSE_POINT!=0 && (data.dwReserved0==win32.IO_REPARSE_TAG_SYMLINK || data.dwReserved0==win32.IO_REPARSE_TAG_MOUNT_POINT)
            if name!="" && !strings.has_prefix(name,".") && !link {
                path:=strings.concatenate({dir,separator,name},context.temp_allocator)
                if attributes&win32.FILE_ATTRIBUTE_DIRECTORY!=0 {
                    append(&todo,path)
                } else {
                    append(&found,Found_File{
                        path=path,name=name,
                        size=i64(data.nFileSizeHigh)<<32+i64(data.nFileSizeLow),
                        created=win32.FILETIME_as_unix_nanoseconds(data.ftCreationTime),
                        changed=win32.FILETIME_as_unix_nanoseconds(data.ftLastWriteTime),
                    })
                }
            }
            if !win32.FindNextFileW(handle,&data) {break}
        }
        win32.FindClose(handle)
    }
    return found[:]
}
