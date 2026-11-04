package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:editor/api"
import "mirai:project"

@(test)
capture_paths_take_git_bash_drives_and_are_relative_to_the_project :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:="C:/games/demo" when ODIN_OS==.Windows else "/games/demo"
    resolved :: proc(t:^testing.T,root,path,expected:string,loc:=#caller_location) {
        file,problem:=api_output_path(root,path)
        testing.expectf(t,problem=="" && file==expected,"%s: %s %s",path,file,problem,loc=loc)
    }
    resolved(t,root,"shots/a.png",fmt.tprintf("%s/shots/a.png",root))
    resolved(t,root,"shots/../a.png",fmt.tprintf("%s/a.png",root))
    when ODIN_OS==.Windows {
        resolved(t,root,"/c/Users/me/shots/a.png","C:/Users/me/shots/a.png")
        resolved(t,root,"D:\\shots\\b.png","D:/shots/b.png")
        _,rooted:=api_output_path(root,"/tmp/a.png")
        testing.expect(t,strings.contains(rooted,"C:/...") && strings.contains(rooted,"the folder of the project, C:/games/demo"),rooted)
    } else {
        resolved(t,root,"/tmp/a.png","/tmp/a.png")
    }
    _,problem:=api_output_path(root,"")
    testing.expect(t,strings.contains(problem,"path is required"),problem)
}

@(test)
a_capture_makes_its_folder_and_says_why_it_cannot_write :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=project.path_absolute(fmt.tprintf(".mirai/test-capture-output-%d",os.get_pid()))
    defer os.remove_all(folder)
    file:=fmt.tprintf("%s/new/deeper/a.png",folder)
    problem,_:=api_output_prepare(file)
    testing.expect_value(t,problem,"")
    testing.expect(t,os.is_dir(fmt.tprintf("%s/new/deeper",folder)),"the folder is made")
    testing.expect(t,!os.exists(file),"nothing is left where the image goes")
    code:int
    problem,code=api_output_prepare(fmt.tprintf("%s/new",folder))
    testing.expect(t,code==api.INVALID_PARAMS && strings.contains(problem,"is a folder"),problem)
    blocker:=fmt.tprintf("%s/blocker",folder)
    testing.expect(t,os.write_entire_file(blocker,"x")==nil)
    problem,code=api_output_prepare(fmt.tprintf("%s/inside/a.png",blocker))
    testing.expectf(t,code==api.SERVER_ERROR && strings.contains(problem,"could not be made: "),"a file where a folder goes: %s",problem)
}
