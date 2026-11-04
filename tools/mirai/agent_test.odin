package main

import "core:os"
import "core:testing"

@(test)
agent_publication_keeps_the_previous_install_on_failure_or_cancel :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder,error:=os.make_directory_temp("","mirai-agent-test-*",context.temp_allocator)
    testing.expect(t,error==nil)
    if error!=nil {return}
    defer os.remove_all(folder)
    target,stage,previous:=join(folder,"codex"),join(folder,"stage"),join(folder,"previous")
    os.make_directory(target);os.make_directory(stage)
    testing.expect(t,os.write_entire_file(join(target,"installation.json"),"previous")==nil)
    testing.expect(t,os.write_entire_file(join(stage,"installation.json"),"replacement")==nil)
    cancel:=join(folder,"cancel")
    testing.expect(t,os.write_entire_file(cancel,"")==nil)
    operation:=Agent_Operation{cancel_file=cancel,parent=os.get_ppid()}
    testing.expect(t,!agent_publish(&operation,stage,target,previous))
    bytes,_:=os.read_entire_file(join(target,"installation.json"),context.temp_allocator)
    testing.expect_value(t,string(bytes),"previous")
    testing.expect(t,os.is_dir(stage) && !os.exists(previous))
    os.remove(cancel)
    operation.cancelled=false
    testing.expect(t,!agent_publish(&operation,join(folder,"missing"),target,previous))
    bytes,_=os.read_entire_file(join(target,"installation.json"),context.temp_allocator)
    testing.expect_value(t,string(bytes),"previous")
    testing.expect(t,!os.exists(previous))
    testing.expect(t,agent_publish(&operation,stage,target,previous))
    bytes,_=os.read_entire_file(join(target,"installation.json"),context.temp_allocator)
    testing.expect_value(t,string(bytes),"replacement")
    testing.expect(t,!os.exists(stage) && !os.exists(previous))
}

@(test)
agent_versions_cannot_be_paths_or_package_selectors :: proc(t:^testing.T) {
    for value in ([5]string{"2.2.2","0.89.1","1.0.0-beta.2","1","1.2.3-rc1"}) {testing.expect(t,agent_version_valid(value))}
    for value in ([8]string{"","../2.2.2","latest","2.2.2/","@next","2.2.2;command","2.2.2 --flag","2.2.2\n"}) {testing.expect(t,!agent_version_valid(value))}
}
