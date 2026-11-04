package editor

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:core"
import input "mirai:engine/input"
import "mirai:project"

// Renaming an input action that the project declared puts its new name on
// the constant and in input.mirai, and leaves the rest of the file as it was.
@(test)
renaming_an_action_renames_it_in_input_mirai :: proc(t:^testing.T) {
    folder,error:=os.make_directory_temp("","mirai-names-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    defer os.remove_all(folder)
    game:=project.path(folder,"game",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(game)==nil)
    code:=project.path(game,"game.odin",allocator=context.temp_allocator)
    bindings:=project.path(folder,project.INPUT_FILE,allocator=context.temp_allocator)
    testing.expect(t,os.write_entire_file(code,"package game\nimport inp \"mirai:engine/input\"\nHIT :: inp.Action(16)\n")==nil)
    testing.expect(t,os.write_entire_file(bindings,`{"actions": [
    {"name": "hit", "kind": "Button", "bindings": [{"mouse_button": "Left"}]},
    {"name":"hitter", "kind": "Button", "bindings": []}
]}`)==nil)

    names:=[]core.Name_Info{
        {type=input.Action,value=16,name="hit",library="game",file="game/game.odin",line=3,project=true},
        {type=input.Action,value=17,name="hitter",library="game",file="game/game.odin",line=4,project=true},
    }
    types:=[]core.Named_Type_Info{{type=input.Action,name="Action",path="mirai:engine/input"}}
    info:=core.World_Info{names=names,named_types=types}
    build:Build_State
    s:=Session{build=&build,has_project=true,project_root=folder}

    testing.expect_value(t,names_rename(&s,&info,input.Action,"hit","strike"),Names_Error.None)
    written,_:=os.read_entire_file(code,context.temp_allocator)
    testing.expect(t,strings.contains(string(written),`@(name="strike") HIT :: inp.Action(16)`))
    renamed,_:=os.read_entire_file(bindings,context.temp_allocator)
    testing.expect_value(t,string(renamed),`{"actions": [
    {"name": "strike", "kind": "Button", "bindings": [{"mouse_button": "Left"}]},
    {"name":"hitter", "kind": "Button", "bindings": []}
]}`)
    testing.expect_value(t,input_file_rename(string(renamed),"hit","x"),"")
}

// A new value follows the highest, skips those taken and leaves out the last
// value of the type, which a sentinel with a name may hold.
@(test)
a_new_name_takes_the_value_after_the_highest_below_the_last :: proc(t:^testing.T) {
    profiles:=[]core.Name_Info{{value=0},{value=1},{value=255}}
    testing.expect_value(t,names_free(profiles,256),i64(2))
    testing.expect_value(t,names_free(nil,32),i64(0))
    full:=[]core.Name_Info{{value=0},{value=1},{value=2},{value=3}}
    testing.expect_value(t,names_free(full,4),i64(4))
    ends:=[]core.Name_Info{{value=0},{value=3}}
    testing.expect_value(t,names_free(ends,4),i64(1))
}
