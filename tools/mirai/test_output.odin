package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:std/subprocess"

// What mirai test reads from what a test executable of core:testing says, a
// line at a time: which tests run and since when, which failed, and what of
// it to show. Its log entries are "[LEVEL] --- [time] text", and the lines
// that follow one without a header of their own belong to it.
Test_Output :: struct {
    quiet:bool,         // only failures, warnings and the summary
    states_hidden:bool, // the state changes are mirai test's, not asked by a flag
    running:map[string]time.Tick, // tests that run (package.name), with when they started
    changed:time.Tick,  // when a test started or ended last, or the executable started
    started:bool,       // a test started
    summary:bool,       // the summary of the runner began
    shown:bool,         // the lines of the current entry are shown
    hung:bool,          // the executable hung and was killed
    failed:[dynamic]string, // without their package, once each
    // Procedures whose fatal message came before their test started: the
    // runner orders a batch of messages by when they were made, and makes the
    // one of a start when it reads it.
    stopped:[dynamic]string,
}

// Reads a line of the output: what to print of it and whether to print it.
test_output_line :: proc(out:^Test_Output,raw:string,now:time.Tick) -> (text:string,show:bool) {
    line:=strings.trim_right(raw,"\r")
    if out.summary {
        switch {
        // The runner says how to run the failed ones again by recompiling: mirai test says --failed.
        case line=="",
             strings.has_prefix(line,"To run only the failed test"),
             strings.has_prefix(line,"\t-define:ODIN_TEST_NAMES="),
             strings.has_prefix(line,"If your terminal supports OSC 52"):
            return "",false
        case strings.has_prefix(line," - "):
            tab:=strings.index_byte(line,'\t')
            listed:=strings.trim_space(line[3:tab if tab>=0 else len(line)])
            name:=test_bare(listed)
            test_failed_add(out,name)
        }
        return line,true
    }
    if test_summary_line(line) {
        out.summary=true
        clear(&out.running)
        out.changed=now
        return line,true
    }
    level,body,entry:=test_log_entry(line)
    if !entry {
        // "No tests to run.", "No test found for the name: ..." are the runner's.
        return line,!out.quiet || strings.has_prefix(line,"No test") || (line!="" && (out.shown || strings.contains(line,".odin(")))
    }
    out.shown=!out.quiet || level>=.Warning
    if name,state,changed:=test_state_change(body);changed {
        switch state {
        case "Running":
            out.started=true
            if at,found:=slice.linear_search(out.stopped[:],test_bare(name));found {
                unordered_remove(&out.stopped,at)
            } else {
                out.running[strings.clone(name)]=now
            }
        case "Failed":
            delete_key(&out.running,name)
            test_failed_add(out,test_bare(name))
        case:
            delete_key(&out.running,name)
        }
        out.changed=now
        return line,out.shown && !out.states_hidden
    }
    // A test stopped by a signal ends without a state change: with what the
    // runner says of it, or with the fatal message of the test itself.
    if level==.Fatal {
        if stopped,signalled:=test_signal_stop(body);signalled {
            delete_key(&out.running,stopped)
            test_failed_add(out,test_bare(stopped))
            out.changed=now
        } else if procedure,located:=test_log_procedure(body);located {
            ended:=false
            for running in out.running {
                if test_bare(running)!=procedure {continue}
                delete_key(&out.running,running)
                out.changed=now
                ended=true
                break
            }
            if !ended {append(&out.stopped,strings.clone(procedure))}
        }
    }
    return line,out.shown
}

// Whether the executable hangs: no test started or ended for timeout. Each one
// that runs then has run at least that long, and before the first one or
// after the last one nothing should take it.
test_hung :: proc(out:Test_Output,timeout:time.Duration,now:time.Tick) -> bool {
    return timeout>0 && time.tick_diff(out.changed,now)>=timeout
}

@(private="file")
test_failed_add :: proc(out:^Test_Output,name:string) {
    if !slice.contains(out.failed[:],name) {append(&out.failed,strings.clone(name))}
}

// "Finished 3 tests in 1.2s. ...": the summary of the runner.
@(private="file")
test_summary_line :: proc(line:string) -> bool {
    if !strings.has_prefix(line,"Finished ") {return false}
    rest:=line[len("Finished "):]
    digits:=0
    for digits<len(rest) && rest[digits]>='0' && rest[digits]<='9' {digits+=1}
    return digits>0 && strings.has_prefix(rest[digits:]," test")
}

// The level and the text of a log entry, after its time when it has one.
@(private="file")
test_log_entry :: proc(line:string) -> (level:runtime.Logger_Level,body:string,ok:bool) {
    HEADERS :: [5]struct{text:string,level:runtime.Logger_Level}{
        {"[DEBUG] --- ",.Debug},{"[INFO ] --- ",.Info},{"[WARN ] --- ",.Warning},{"[ERROR] --- ",.Error},{"[FATAL] --- ",.Fatal},
    }
    for header in HEADERS {
        if !strings.has_prefix(line,header.text) {continue}
        body=line[len(header.text):]
        if len(body)>1 && body[0]=='[' && body[1]>='0' && body[1]<='9' {
            if close:=strings.index(body,"] ");close>0 {body=body[close+2:]}
        }
        return header.level,body,true
    }
    return
}

// "Test #3 pkg.name changed state to Running.": the test and its new state.
@(private="file")
test_state_change :: proc(body:string) -> (name,state:string,ok:bool) {
    rest:=strings.trim_prefix(body,"Test #")
    if len(rest)==len(body) {return}
    rest=rest[max(strings.index_byte(rest,' '),0)+1:]
    MARK :: " changed state to "
    at:=strings.index(rest,MARK)
    if at<0 {return}
    return rest[:at],strings.trim_right(rest[at+len(MARK):],"."),true
}

// "Caught signal to stop test #3 pkg.name for: ...": the test it stopped.
@(private="file")
test_signal_stop :: proc(body:string) -> (name:string,ok:bool) {
    rest:=strings.trim_prefix(body,"Caught signal to stop test #")
    if len(rest)==len(body) {return}
    rest=rest[max(strings.index_byte(rest,' '),0)+1:]
    end:=strings.index(rest," for:")
    if end<0 {return}
    return rest[:end],true
}

// "[file.odin:12:procedure()] ...": the procedure an entry comes from.
@(private="file")
test_log_procedure :: proc(body:string) -> (procedure:string,ok:bool) {
    if !strings.has_prefix(body,"[") {return}
    end:=strings.index(body,"()] ")
    if end<0 {return}
    location:=body[1:end]
    return location[strings.last_index_byte(location,':')+1:],true
}

// Runs a test executable with what it says on stdout and stderr read a line
// at a time (test_output_line) and shown on stderr, and kills it when it
// hangs (test_hung), naming the tests that ran. Its exit code; -1 when it
// could not start or was killed.
test_execute :: proc(root,path:string,command:[]string,out:^Test_Output,priority:subprocess.Priority,timeout:time.Duration) -> int {
    reader,writer,pipe_error:=os.pipe()
    if pipe_error!=nil {fmt.eprintfln("mirai test: could not create a pipe: %v",pipe_error);return -1}
    defer os.close(reader)
    process,error:=subprocess.start({working_dir=root,command=command,stdin=os.stdin,stdout=writer,stderr=writer},{priority=priority})
    os.close(writer)
    if error!=nil {fmt.eprintfln("mirai test: could not run %s: %v",command[0],error);return -1}
    out.changed=time.tick_now()
    pending:=make([dynamic]u8,context.temp_allocator)
    buffer:[16384]u8
    state:os.Process_State
    open,exited:=true,false
    for {
        if open {
            ready,ready_error:=os.pipe_has_data(reader)
            if ready_error!=nil {open=false} else if ready {
                count,read_error:=os.read(reader,buffer[:])
                if count>0 {test_output_feed(out,&pending,buffer[:count])}
                if read_error!=nil {open=false}
                continue
            }
        }
        // What it wrote before it ended has been read; a child of it may keep the pipe open.
        if exited {break}
        wait_error:os.Error
        state,wait_error=os.process_wait(process,0 if open else 50*time.Millisecond)
        if wait_error==nil && state.exited {exited=true;continue}
        if wait_error!=nil && wait_error!=os.General_Error.Timeout {
            fmt.eprintfln("mirai test: %s: %v",command[0],wait_error)
            return -1
        }
        if test_hung(out^,timeout,time.tick_now()) {
            _=os.process_kill(process)
            _,_=os.process_wait(process)
            if len(pending)>0 {test_output_feed(out,&pending,{'\n'})}
            test_hung_say(path,out,timeout)
            return -1
        }
        if open {time.sleep(5*time.Millisecond)}
    }
    if len(pending)>0 {test_output_feed(out,&pending,{'\n'})}
    if state.exit_code!=0 && !out.summary {test_crash_say(path,out,state.exit_code)}
    return state.exit_code
}

@(private="file")
test_output_feed :: proc(out:^Test_Output,pending:^[dynamic]u8,data:[]u8) {
    append(pending,..data)
    start:=0
    for i in 0..<len(pending) {
        if pending[i]!='\n' {continue}
        if text,show:=test_output_line(out,string(pending[start:i]),time.tick_now());show {fmt.eprintln(text)}
        start=i+1
    }
    remove_range(pending,0,start)
}

// The tests that run, the oldest first, counted as failed: the executable
// ended without them ending.
@(private="file")
test_running_failed :: proc(out:^Test_Output) -> []string {
    Running :: struct {name:string,since:time.Tick}
    running:=make([dynamic]Running,context.temp_allocator)
    for name,since in out.running {append(&running,Running{name,since})}
    slice.sort_by(running[:],proc(a,b:Running) -> bool {return time.tick_diff(a.since,b.since)>0})
    names:=make([dynamic]string,context.temp_allocator)
    for r in running {
        append(&names,test_bare(r.name))
        test_failed_add(out,test_bare(r.name))
    }
    return names[:]
}

// Says that the executable ended before its summary, with the tests that ran.
@(private="file")
test_crash_say :: proc(path:string,out:^Test_Output,code:int) {
    names:=test_running_failed(out)
    if len(names)>0 {
        fmt.eprintfln("mirai test: %s: the executable crashed (code 0x%X) while %s %s",path,u32(code),len(names)==1?"this one ran:":"these ran:",strings.join(names,", ",context.temp_allocator))
    } else {
        fmt.eprintfln("mirai test: %s: the executable crashed (code 0x%X) before saying which test ran",path,u32(code))
    }
}

// Says why the executable was killed, and counts the tests that ran as failed.
@(private="file")
test_hung_say :: proc(path:string,out:^Test_Output,timeout:time.Duration) {
    out.hung=true
    names:=test_running_failed(out)
    seconds:=time.duration_seconds(timeout)
    switch {
    case len(names)>0:
        fmt.eprintfln("mirai test: %s: %s %s more than %.0f s and no other test started or ended in that time; the executable was killed (--timeout S changes the limit)",
            path,strings.join(names,", ",context.temp_allocator),len(names)==1?"has run for":"have run for",seconds)
    case out.summary:
        fmt.eprintfln("mirai test: %s: the executable kept running %.0f s after its tests ended; it was killed",path,seconds)
    case !out.started:
        fmt.eprintfln("mirai test: %s: the executable started no test in %.0f s; it was killed",path,seconds)
    case:
        fmt.eprintfln("mirai test: %s: no test started or ended in %.0f s; the executable was killed",path,seconds)
    }
}
