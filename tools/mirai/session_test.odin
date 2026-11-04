package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"
import "mirai:project"

// start and restart take the mode, the flags of their own and, for the
// editor, everything else in order.
@(test)
session_options_take_their_flags_and_leave_the_rest_to_the_editor :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    options,problem:=session_options({"--dev","--discard","--timeout","30","--frames","5","--dev"})
    testing.expect_value(t,problem,"")
    testing.expect_value(t,options.mode,Build_Mode.Dev)
    testing.expect(t,options.discard && !options.no_build && !options.orphans)
    testing.expect_value(t,options.timeout,30)
    testing.expect(t,slice.equal(options.editor_args,[]string{"--frames","5"}))
    options,problem=session_options({})
    testing.expect_value(t,problem,"")
    testing.expect_value(t,options.mode,Build_Mode.Keep)
    testing.expect_value(t,options.timeout,180)
    testing.expect_value(t,len(options.editor_args),0)
}

@(test)
session_options_refuse_both_modes_and_a_timeout_that_is_no_number :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for args in ([][]string{{"--dev","--release"},{"--timeout"},{"--timeout","0"},{"--timeout","x"}}) {
        _,problem:=session_options(args)
        testing.expectf(t,problem!="","%v is refused",args)
    }
}

// Unsaved changes go alone only when every one is of a copy under
// .mirai/tmp/ of the project: a scene outside the assets folder is named by
// its file, and the rest relative to the assets folder or to the project.
@(test)
only_unsaved_copies_under_mirai_tmp_go_without_discard :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:="C:/proyectos/demo" when ODIN_OS==.Windows else "/proyectos/demo"
    copy:=fmt.tprintf("%s/.mirai/tmp/prueba.scene",folder)
    testing.expect(t,session_discardable(folder,{}))
    testing.expect(t,session_discardable(folder,{copy,".mirai/tmp/shaders/x.slang"}))
    testing.expect(t,!session_discardable(folder,{copy,"scenes/main.scene"}),"a scene of the assets")
    testing.expect(t,!session_discardable(folder,{copy,"materials/rock.mat"}),"an asset")
    testing.expect(t,!session_discardable(folder,{""}),"a scene never saved")
    testing.expect(t,!session_discardable(folder,{fmt.tprintf("%s/.mirai/tmp/../../assets/x.scene",folder)}),"out of tmp by ..")
    testing.expect(t,!session_discardable(folder,{fmt.tprintf("%s/.mirai/tmpx/a.scene",folder)}),"a folder that starts like tmp")
    testing.expect(t,!session_discardable(folder,{"C:/otro/.mirai/tmp/a.scene" when ODIN_OS==.Windows else "/otro/.mirai/tmp/a.scene"}),"tmp of another project")
    when ODIN_OS==.Windows {
        testing.expect(t,session_discardable(folder,{`c:\PROYECTOS\demo\.mirai\tmp\b.scene`}),"backslashes and another case")
    }
}

@(test)
the_unsaved_paths_are_the_dirty_scenes_and_the_unsaved_assets :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    documents:=`{"active":0,"documents":[{"index":0,"path":"C:/p/.mirai/tmp/a.scene","dirty":true,"preview_sun":false},{"index":1,"path":"scenes/main.scene","dirty":false,"preview_sun":false},{"index":2,"path":"","dirty":true,"preview_sun":false}],"asset":-1,"assets":[{"index":0,"path":"materials/rock.mat","kind":"material","dirty":true,"undo":1,"redo":0}]}`
    assets:=`{"assets":[{"path":"materials/rock.mat","removed":false,"asset":"00112233445566778899aabbccddeeff","kind":"material"},{"path":"shaders/water.slang","removed":false,"kind":"program"}],"scene":["materials/rock.mat"]}`
    paths,ok:=session_unsaved_parse(documents,assets)
    testing.expect(t,ok)
    testing.expect(t,slice.equal(paths,[]string{"C:/p/.mirai/tmp/a.scene","","materials/rock.mat","shaders/water.slang"}),"dirty scenes, then assets once")
    paths,ok=session_unsaved_parse(`{"documents":[]}`,`{"assets":[]}`)
    testing.expect(t,ok && len(paths)==0)
    _,ok=session_unsaved_parse("not json",assets)
    testing.expect(t,!ok)
}

// The project comes from --project, relative to where the program runs when
// it is not absolute; --headless says it has no window. The first argument
// may be the program or not, as each system gives them.
@(test)
an_engine_program_names_its_project_and_whether_it_has_a_window :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:="C:/m" when ODIN_OS==.Windows else "/m"
    folder,headless:=engine_arguments({"mirai-editor","--project",fmt.tprintf("%s/demo/",root),"--headless","--frames","3"},"")
    testing.expect_value(t,folder,fmt.tprintf("%s/demo",root))
    testing.expect(t,headless)
    folder,headless=engine_arguments({"--project","demo"},root)
    testing.expect_value(t,folder,fmt.tprintf("%s/demo",root))
    testing.expect(t,!headless)
    folder,headless=engine_arguments({"mirai-editor","--launcher","--project"},root)
    testing.expect_value(t,folder,"")
    testing.expect(t,!headless)
}

// A session is a headless editor that the port file and the record of its
// project name; one the port file names otherwise is reachable, and an
// editor it does not name is an orphan, with a window or without.
@(test)
an_engine_program_is_told_by_the_files_of_its_project :: proc(t:^testing.T) {
    editor:="C:/m/.mirai/engine/dev/mirai-editor.exe" when ODIN_OS==.Windows else "/m/.mirai/engine/dev/mirai-editor"
    player:="C:/m/.mirai/engine/dev/mirai-player.exe" when ODIN_OS==.Windows else "/m/.mirai/engine/dev/mirai-player"
    headless:=Engine_Process{pid=10,program=editor,project="/p",headless=true,read=true}
    window:=Engine_Process{pid=20,program=editor,project="/p",read=true}
    testing.expect_value(t,engine_role(headless,10,10),Engine_Role.Session)
    testing.expect_value(t,engine_role(headless,10,0),Engine_Role.Reachable)
    testing.expect_value(t,engine_role(headless,10,99),Engine_Role.Reachable)
    testing.expect_value(t,engine_role(window,20,20),Engine_Role.Reachable)
    testing.expect_value(t,engine_role(headless,11,10),Engine_Role.Orphan)
    testing.expect_value(t,engine_role(window,0,0),Engine_Role.Orphan)
    testing.expect_value(t,engine_role({pid=30,program=player,project="/p",read=true},0,0),Engine_Role.Program)
    testing.expect_value(t,engine_role({pid=40,program=editor},40,40),Engine_Role.Unknown)
}

// The role reads <project>/.mirai/api.json and session.json; the record
// keeps the mode and the arguments restart repeats.
@(test)
the_role_and_the_record_come_from_the_files_of_the_project :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder,error:=os.make_directory_temp("","mirai-session-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    defer os.remove_all(folder)
    folder=project.path_absolute(folder)
    testing.expect(t,os.make_directory_all(project.path(folder,".mirai"))==nil)
    pid:=os.get_pid()
    testing.expect(t,os.write_entire_file(project.path(folder,".mirai","api.json"),fmt.tprintf(`{{"port":7999,"pid":%d,"manual":true}}`,pid))==nil)
    editor:=Engine_Process{pid=pid,program="mirai-editor",project=folder,headless=true,read=true}
    testing.expect_value(t,engine_process_role(editor),Engine_Role.Reachable)
    testing.expect(t,os.write_entire_file(project.path(folder,".mirai",SESSION_FILE),fmt.tprintf(`{{"pid":%d,"mode":"dev","args":["--frames","2"]}}`,pid))==nil)
    testing.expect_value(t,engine_process_role(editor),Engine_Role.Session)
    other:=editor
    other.pid=pid+1
    testing.expect_value(t,engine_process_role(other),Engine_Role.Orphan)
    record,found:=session_record(folder)
    testing.expect(t,found)
    testing.expect_value(t,session_record_mode(record),Build_Mode.Dev)
    testing.expect(t,slice.equal(record.args,[]string{"--frames","2"}))
    file,alive:=session_find(folder)
    testing.expect(t,alive && file.port==7999 && file.manual,"this process is the one the port file names")
}

@(test)
a_path_is_inside_a_folder_only_past_a_separator :: proc(t:^testing.T) {
    testing.expect(t,path_inside("/a/b/c","/a/b"))
    testing.expect(t,path_inside("/a/b/c","/a/b/"))
    testing.expect(t,!path_inside("/a/b","/a/b"))
    testing.expect(t,!path_inside("/a/bc","/a/b"))
    testing.expect(t,!path_inside("/a/b/c",""))
    when ODIN_OS==.Windows {
        testing.expect(t,path_inside(`C:\M\.mirai\engine\dev\mirai-editor.exe`,"c:/m/.mirai/engine"))
    }
}
