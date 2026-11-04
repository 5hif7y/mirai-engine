package host

import "core:fmt"
import "core:os"
import "core:slice"
import "mirai:project"

// The libraries of a project mirai-player plays: play, the game alone, or
// editor, the one an editor already loaded, whose game its players run
// without building anything; the World_Info of either makes the same game
// World, as editor packages declare nothing of the World and no step of the
// game loop.
PLAYER_LIBRARIES :: [?]string{"play","editor"}

// mirai-player [--project <folder>] [--library <name>] [options]: plays a
// library of a project built against the binaries of the engine (mirai
// play), whose settings of the machine it reads.
launch :: proc(args:[]string) -> int {
    root:=project_argument(args)
    name,known:=library_argument(args)
    if !known {
        fmt.eprintfln("mirai: --library names play or editor, not %q",name)
        fmt.eprintln(PLAYER_USAGE_TEXT)
        return PLAYER_USAGE
    }
    path:=project.project_library(root,name)
    library,error:=project_library_load(path,0)
    if error!=.None {
        fmt.eprintfln("mirai: %s",library_error_text(error,path))
        return PLAYER_USAGE
    }
    defer project_library_unload(&library)
    return player_run(&library.info,root,project.engine_root_find("",context.temp_allocator),args)
}

// The folder of the project the arguments name with --project; the working
// folder otherwise. Absolute: once told where the libraries a library links
// are, Windows no longer looks for a relative one in the working folder.
project_argument :: proc(args:[]string) -> string {
    for arg,i in args {
        if arg=="--project" && i+1<len(args) {return project.path_absolute(args[i+1])}
    }
    folder,_:=os.get_working_directory(context.allocator)
    return folder
}

// The library --library names, play without it; false when it is none of PLAYER_LIBRARIES.
library_argument :: proc(args:[]string) -> (name:string,known:bool) {
    name="play"
    for arg,i in args {
        if arg=="--library" {name=i+1<len(args)?args[i+1]:""}
    }
    libraries:=PLAYER_LIBRARIES
    return name,slice.contains(libraries[:],name)
}
