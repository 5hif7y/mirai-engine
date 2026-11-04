package platform

import "core:os"
import "core:strings"
import "core:testing"

// The tests drive the shell of the system: it is always there and does
// exactly what they need.
when ODIN_OS==.Windows {
    @(private="file") SHELL :: []string{"cmd","/d","/c"}
    @(private="file") SCRIPT_OUTPUT :: "echo out& echo err 1>&2& exit /b 3"
    @(private="file") SCRIPT_MANY_LINES :: "for /L %i in (1,1,6000) do @echo line %i of the output"
    @(private="file") SCRIPT_ENVIRONMENT :: "cd & echo value=%MIRAI_TEST_VALUE%"
    @(private="file") ECHO_STDIN :: []string{"findstr","/r","^"}
    @(private="file") RUN_LONG :: []string{"ping","-n","120","127.0.0.1"}
} else {
    @(private="file") SHELL :: []string{"sh","-c"}
    @(private="file") SCRIPT_OUTPUT :: "echo out; echo err 1>&2; exit 3"
    @(private="file") SCRIPT_MANY_LINES :: "i=1; while [ $i -le 6000 ]; do echo line $i of the output; i=$((i+1)); done"
    @(private="file") SCRIPT_ENVIRONMENT :: "pwd; echo value=$MIRAI_TEST_VALUE"
    @(private="file") ECHO_STDIN :: []string{"cat"}
    @(private="file") RUN_LONG :: []string{"sleep","120"}
}

@(private="file")
shell :: proc(script:string,allocator:=context.temp_allocator) -> []string {
    command:=make([dynamic]string,allocator)
    append(&command,..SHELL)
    append(&command,script)
    return command[:]
}

@(private)
Test_Child :: struct {stdout,stderr:[dynamic]u8,code:int,finished:bool}
@(private)
test_child_destroy :: proc(child:^Test_Child) {delete(child.stdout);delete(child.stderr)}
// Drains a process the way a frame loop does: a little every pass, never waiting on it.
@(private)
test_child_run :: proc(p:^Platform,process:Process,seconds:f64=60,chunk:=4096) -> (child:Test_Child) {
    buffer:=make([]u8,chunk)
    defer delete(buffer)
    deadline:=clock_seconds()+seconds
    out_open,err_open:=true,true
    for clock_seconds()<deadline {
        n:int
        if out_open {
            n,out_open=process_read(p,process,.Stdout,buffer)
            append(&child.stdout,..buffer[:n])
        }
        if err_open {
            n,err_open=process_read(p,process,.Stderr,buffer)
            append(&child.stderr,..buffer[:n])
        }
        exited,code:=process_poll(p,process)
        if exited && !out_open && !err_open {child.code=code;child.finished=true;return}
        sleep_coarse(1_000_000)
    }
    return
}

@(test)
process_output_and_exit_code_arrive_without_waiting :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    process,error:=process_start(p,{command=shell(SCRIPT_OUTPUT)})
    testing.expect_value(t,error,Process_Error.None)
    testing.expect(t,process!=0 && process_id(p,process)>0)
    child:=test_child_run(p,process)
    defer test_child_destroy(&child)
    testing.expect(t,child.finished)
    testing.expect_value(t,strings.trim_space(string(child.stdout[:])),"out")
    testing.expect_value(t,strings.trim_space(string(child.stderr[:])),"err")
    testing.expect_value(t,child.code,3)
    // The exit stays known, and the handle dies with its release.
    exited,code:=process_poll(p,process)
    testing.expect(t,exited && code==3)
    process_release(p,process)
    exited,code=process_poll(p,process)
    testing.expect(t,exited && code==-1)
    buffer:[16]u8
    _,open:=process_read(p,process,.Stdout,buffer[:])
    testing.expect(t,!open)
    testing.expect_value(t,process_write(p,process,buffer[:]),0)
    testing.expect(t,!process_terminate(p,process))
    testing.expect_value(t,process_id(p,process),0)
}

@(test)
process_reads_its_stdin_until_it_is_closed :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    process,error:=process_start(p,{command=ECHO_STDIN})
    testing.expect_value(t,error,Process_Error.None)
    defer process_release(p,process)
    text:="first line\nsecond line\n"
    sent:=0
    for attempt:=0;sent<len(text) && attempt<1000;attempt+=1 {
        written:=process_write(p,process,transmute([]u8)text[sent:])
        sent+=written
        if written==0 {sleep_coarse(1_000_000)}
    }
    testing.expect_value(t,sent,len(text))
    // It is still waiting for more input: nothing says it ended.
    exited,_:=process_poll(p,process)
    testing.expect(t,!exited)
    process_stdin_close(p,process)
    child:=test_child_run(p,process)
    defer test_child_destroy(&child)
    testing.expect(t,child.finished)
    testing.expect_value(t,child.code,0)
    output,_:=strings.replace_all(string(child.stdout[:]),"\r\n","\n",context.temp_allocator)
    testing.expect_value(t,output,text)
    testing.expect_value(t,process_write(p,process,transmute([]u8)text),0)
}

@(test)
process_takes_a_message_larger_than_its_pipe :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    process,error:=process_start(p,{command=ECHO_STDIN})
    testing.expect_value(t,error,Process_Error.None)
    defer process_release(p,process)
    line:=strings.repeat("x",99,context.temp_allocator)
    text:=strings.repeat(strings.concatenate({line,"\n"},context.temp_allocator),200,context.temp_allocator)
    output:[dynamic]u8
    defer delete(output)
    buffer:[4096]u8
    sent:=0
    // findstr only answers once its stdin ends.
    for open,deadline:=true,clock_seconds()+30;open && clock_seconds()<deadline; {
        if sent<len(text) {
            sent+=process_write(p,process,transmute([]u8)text[sent:])
            if sent==len(text) {process_stdin_close(p,process)}
        }
        count:int
        count,open=process_read(p,process,.Stdout,buffer[:])
        for b in buffer[:count] {if b!='\r' {append(&output,b)}}
        if count==0 {sleep_coarse(1_000_000)}
    }
    testing.expect_value(t,sent,len(text))
    testing.expect(t,string(output[:])==text)
}

@(test)
process_that_fills_its_pipe_is_drained_in_small_reads :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    process,error:=process_start(p,{command=shell(SCRIPT_MANY_LINES),merge_stderr=true})
    testing.expect_value(t,error,Process_Error.None)
    defer process_release(p,process)
    // More output than a pipe holds: the process only goes on as it is read.
    child:=test_child_run(p,process,chunk=100)
    defer test_child_destroy(&child)
    testing.expect(t,child.finished)
    testing.expect_value(t,child.code,0)
    testing.expect_value(t,strings.count(string(child.stdout[:]),"\n"),6000)
    testing.expect(t,strings.contains(string(child.stdout[:]),"line 6000 of the output"))
    testing.expect(t,len(child.stdout)>128*1024)
    testing.expect_value(t,len(child.stderr),0)
}

@(test)
process_gets_its_working_directory_and_environment :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    folder,ok:=path_temporary_folder(context.temp_allocator)
    testing.expect(t,ok)
    process,error:=process_start(p,{
        command=shell(SCRIPT_ENVIRONMENT),
        working_directory=folder,
        environment={"MIRAI_TEST_VALUE=from the editor","MIRAI_OTHER=1"},
    })
    testing.expect_value(t,error,Process_Error.None)
    defer process_release(p,process)
    child:=test_child_run(p,process)
    defer test_child_destroy(&child)
    testing.expect(t,child.finished)
    output:=string(child.stdout[:])
    testing.expect(t,strings.contains(output,"value=from the editor"),output)
    // The folder as the system spells it: compare what both resolve to.
    first_line:=strings.trim_space(output[:max(strings.index_byte(output,'\n'),0)])
    reported,reported_error:=os.stat(first_line,context.temp_allocator)
    expected,expected_error:=os.stat(folder,context.temp_allocator)
    testing.expect(t,reported_error==nil && expected_error==nil)
    testing.expect(t,os.same_file(reported,expected),first_line)
    _,bad:=process_start(p,{command=shell(SCRIPT_OUTPUT),environment={"no equals sign"}})
    testing.expect_value(t,bad,Process_Error.Invalid_Command)
}

@(test)
running_process_is_polled_and_terminated :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    process,error:=process_start(p,{command=RUN_LONG})
    testing.expect_value(t,error,Process_Error.None)
    defer process_release(p,process)
    buffer:[256]u8
    start:=clock_ns()
    allocations:=0
    {
        // Polling a process every frame takes nothing from the allocators.
        context.allocator=test_no_allocator(&allocations)
        context.temp_allocator=test_no_allocator(&allocations)
        for _ in 0..<50 {
            _,open:=process_read(p,process,.Stderr,buffer[:])
            testing.expect(t,open)
            _,open=process_read(p,process,.Stdout,buffer[:])
            testing.expect(t,open)
            exited,_:=process_poll(p,process)
            testing.expect(t,!exited)
            testing.expect_value(t,process_write(p,process,nil),0)
        }
    }
    testing.expect_value(t,allocations,0)
    testing.expect(t,clock_ns()-start<500_000_000,"Reading from a process that says nothing must not wait for it")
    testing.expect(t,process_terminate(p,process,force=true))
    exited:=false
    for attempt:=0;!exited && attempt<5000;attempt+=1 {
        exited,_=process_poll(p,process)
        if !exited {sleep_coarse(1_000_000)}
    }
    testing.expect(t,exited)
    testing.expect(t,process_terminate(p,process))
}

@(test)
process_table_refuses_what_it_cannot_start :: proc(t:^testing.T) {
    p:=test_headless(t,{process_capacity=1})
    defer destroy(p)
    none,error:=process_start(p,{})
    testing.expect(t,none==0 && error==.Invalid_Command)
    none,error=process_start(p,{command={"mirai-no-such-program-anywhere"}})
    testing.expect(t,none==0 && error==.Start_Failed)
    first,first_error:=process_start(p,{command=RUN_LONG})
    testing.expect_value(t,first_error,Process_Error.None)
    none,error=process_start(p,{command=RUN_LONG})
    testing.expect(t,none==0 && error==.Capacity_Exhausted)
    testing.expect_value(t,stats(p).processes_exhausted,u64(1))
    // Releasing a running process ends it and frees its place; the old handle stays dead.
    process_release(p,first)
    second,second_error:=process_start(p,{command=shell(SCRIPT_OUTPUT)})
    testing.expect_value(t,second_error,Process_Error.None)
    testing.expect(t,second!=first)
    exited,code:=process_poll(p,first)
    testing.expect(t,exited && code==-1)
    // What is still running when the Platform goes away is ended with it.
}
