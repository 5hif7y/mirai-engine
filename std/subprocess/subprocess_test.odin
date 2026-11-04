package subprocess

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

// The test program is also the child of the tests: started with PROBE as its
// first argument, it does what the second one says and ends before the tests run.
PROBE :: "mirai-subprocess-probe"

@(init)
probe_run :: proc "contextless" () {
    if len(os.args)<3 || os.args[1]!=PROBE {return}
    context=runtime.default_context()
    code:=0
    switch os.args[2] {
    case "args":
        for argument in os.args[3:] {
            os.write_string(os.stdout,argument)
            os.write_byte(os.stdout,0)
        }
    case "streams":
        os.write_string(os.stdout,"out")
        os.write_string(os.stderr,"err")
        code=3
    case "env":
        value,found:=os.lookup_env(os.args[3],context.temp_allocator)
        os.write_string(os.stdout,value if found else "<unset>")
    case "cwd":
        folder,_:=os.get_working_directory(context.temp_allocator)
        os.write_string(os.stdout,folder)
    case "sleep":
        time.sleep(3*time.Second)
    case "allocate":
        // Linux bounds the child once it runs: it waits for that first.
        time.sleep(300*time.Millisecond)
        megabytes,_:=strconv.parse_int(os.args[3])
        _,refused:=make([]byte,megabytes<<20)
        os.write_string(os.stdout,"refused" if refused!=nil else "allocated")
    case "priority":
        os.write_string(os.stdout,fmt.tprintf("%d",priority_rank()))
    case "stdin":
        buffer:[64]byte
        for {
            count,error:=os.read(os.stdin,buffer[:])
            if error!=nil || count==0 {break}
        }
    case:
        when ODIN_OS==.Windows {code=probe_windows(os.args[2:])} else {code=2}
    }
    os.exit(code)
}

probe_program :: proc() -> string {
    exe,_:=os.get_executable_path(context.temp_allocator)
    return exe
}

probe_command :: proc(action:string,rest:..string) -> []string {
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,probe_program(),PROBE,action)
    append(&command,..rest)
    return command[:]
}

@(test)
exec_returns_stdout_stderr_and_the_exit_code :: proc(t:^testing.T) {
    state,stdout,stderr,error:=exec({command=probe_command("streams")},context.temp_allocator)
    testing.expectf(t,error==nil,"exec: %v",error)
    testing.expect(t,state.exited)
    testing.expect_value(t,state.exit_code,3)
    testing.expect_value(t,string(stdout),"out")
    testing.expect_value(t,string(stderr),"err")
}

// A child bounded in memory cannot allocate past the bound; without it, it can.
@(test)
a_memory_limit_bounds_what_the_child_allocates :: proc(t:^testing.T) {
    when ODIN_OS==.Darwin {return}
    _,stdout,_,error:=exec({command=probe_command("allocate","512")},context.temp_allocator,{memory=128<<20})
    testing.expectf(t,error==nil,"exec: %v",error)
    testing.expect_value(t,string(stdout),"refused")
    _,stdout,_,error=exec({command=probe_command("allocate","512")},context.temp_allocator)
    testing.expectf(t,error==nil,"exec: %v",error)
    testing.expect_value(t,string(stdout),"allocated")
}

// A low child runs below a child started without a priority, which runs as
// this process; unless that one is already as low as a low child gets.
@(test)
a_low_priority_child_runs_below_one_without_priority :: proc(t:^testing.T) {
    _,stdout,_,error:=exec({command=probe_command("priority")},context.temp_allocator)
    testing.expectf(t,error==nil,"exec: %v",error)
    normal,_:=strconv.parse_int(string(stdout))
    _,stdout,_,error=exec({command=probe_command("priority")},context.temp_allocator,{priority=.Low})
    testing.expectf(t,error==nil,"exec: %v",error)
    low,_:=strconv.parse_int(string(stdout))
    when ODIN_OS==.Windows {lowest:=2} else {lowest:=-NICENESS_MOST}
    testing.expectf(t,low<normal || normal<=lowest,"low child %d, child without priority %d",low,normal)
}

@(test)
arguments_reach_the_child_as_they_were_given :: proc(t:^testing.T) {
    arguments:=[]string{"plain","with space","","quote\"inside",`trailing\`,`two\\`,`back\"quote`,`\\server\share\`,"tab\there","ñandú 字"}
    _,stdout,_,error:=exec({command=probe_command("args",..arguments)},context.temp_allocator)
    testing.expectf(t,error==nil,"exec: %v",error)
    received:=strings.split(string(stdout),"\x00",context.temp_allocator)
    testing.expect_value(t,len(received),len(arguments)+1)
    for argument,i in arguments {
        if i<len(received) {testing.expect_value(t,received[i],argument)}
    }
}

@(test)
the_environment_given_replaces_the_one_of_this_process :: proc(t:^testing.T) {
    env:=[]string{"MIRAI_SUBPROCESS_VALUE=first","PATH=","MIRAI_SUBPROCESS_VALUE=second"}
    _,stdout,_,error:=exec({command=probe_command("env","MIRAI_SUBPROCESS_VALUE"),env=env},context.temp_allocator)
    testing.expectf(t,error==nil,"exec: %v",error)
    testing.expect_value(t,string(stdout),"second")
}

@(test)
the_child_starts_in_the_working_directory_given :: proc(t:^testing.T) {
    folder:=filepath.dir(probe_program())
    _,stdout,_,error:=exec({command=probe_command("cwd"),working_dir=folder},context.temp_allocator)
    testing.expectf(t,error==nil,"exec: %v",error)
    received:=strings.trim_right(string(stdout),`\/`)
    testing.expectf(t,strings.equal_fold(received,strings.trim_right(folder,`\/`)),"%q is not %q",received,folder)
}

@(test)
an_invalid_description_starts_nothing :: proc(t:^testing.T) {
    commands:=[][]string{nil,{""},{probe_program(),"a\x00b"}}
    for command in commands {
        _,error:=start({command=command})
        testing.expect_value(t,error,os.Error(.Invalid_Command))
        _,_,_,exec_error:=exec({command=command},context.temp_allocator)
        testing.expect_value(t,exec_error,os.Error(.Invalid_Command))
        _,detached_error:=detached(command,"unused.log","")
        testing.expect_value(t,detached_error,os.Error(.Invalid_Command))
    }
    for entry in ([]string{"NO_VALUE","=","","A=\x00"}) {
        _,error:=start({command=probe_command("streams"),env={entry}})
        testing.expect_value(t,error,os.Error(.Invalid_Command))
    }
}

@(test)
a_missing_program_is_an_error :: proc(t:^testing.T) {
    _,error:=start({command={"mirai-no-such-program-anywhere"}})
    testing.expect(t,error!=nil)
}

@(test)
a_detached_child_writes_its_output_to_the_log :: proc(t:^testing.T) {
    log:=strings.concatenate({probe_program(),".detached.log"},context.temp_allocator)
    defer os.remove(log)
    process,error:=detached(probe_command("streams"),log,"")
    testing.expectf(t,error==nil,"detached: %v",error)
    if error!=nil {return}
    state,_:=os.process_wait(process)
    testing.expect_value(t,state.exit_code,3)
    written,_:=os.read_entire_file(log,context.temp_allocator)
    testing.expect_value(t,string(written),"outerr")
}

// A child that held the write end of a pipe of this process would keep its
// reader open. The check does not block: the started child waits on a stdin
// of its own that the test holds, and the detached one sleeps, so both are
// alive when the reader is polled.
@(test)
children_hold_no_pipe_of_this_process :: proc(t:^testing.T) {
    log:=strings.concatenate({probe_program(),".held.log"},context.temp_allocator)
    defer os.remove(log)
    for kind in ([]string{"start","detached"}) {
        reader,writer,pipe_error:=os.pipe()
        testing.expect(t,pipe_error==nil)
        if pipe_error!=nil {return}
        child_in,child_in_writer,in_error:=os.pipe()
        testing.expect(t,in_error==nil)
        if in_error!=nil {os.close(reader);os.close(writer);return}
        process:os.Process
        error:os.Error
        if kind=="start" {process,error=start({command=probe_command("stdin"),stdin=child_in})} else {process,error=detached(probe_command("sleep"),log,"")}
        os.close(child_in)
        os.close(writer)
        testing.expectf(t,error==nil,"%s: %v",kind,error)
        if error==nil {
            ready,poll_error:=os.pipe_has_data(reader)
            testing.expectf(t,poll_error==.Broken_Pipe && !ready,"%s: a child holds the write end (%v)",kind,poll_error)
        }
        os.close(reader)
        os.close(child_in_writer)
        if error!=nil {continue}
        if state,_:=os.process_wait(process,0);!state.exited {
            _=os.process_kill(process)
            _,_=os.process_wait(process)
        }
    }
}
