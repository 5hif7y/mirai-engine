package platform

import "core:c"
import "core:strings"
import sdl "vendor:sdl3"
import "mirai:std/base"

// Child processes with piped stdin, stdout and stderr. Nothing here waits:
// reads return what has arrived, writes take what fits in the pipe, and the
// exit is polled. A process that fills a pipe nobody reads stops until it is
// read, so its output has to be drained every frame.

Process :: distinct base.Handle

Process_Desc :: struct {
    command:[]string, // the program, found through PATH when it has no folder, and its arguments
    working_directory:string, // the one of this process when empty
    environment:[]string, // "NAME=VALUE" entries set over the environment of this process
    merge_stderr:bool, // stderr arrives through stdout, in the order it was written
}
Process_Error :: enum u8 {None,Capacity_Exhausted,Invalid_Command,Start_Failed}
Process_Stream :: enum u8 {Stdout,Stderr}

// SDL is never asked for less than this at once. With reads of 512 bytes
// its pipe stream on Windows lost part of the output (6000 lines written,
// 5987 read); with reads this large it reads straight from the pipe.
@(private)
PROCESS_READ_BYTES :: 2048
@(private)
Process_Output :: struct {
    stream:^sdl.IOStream,
    held:[PROCESS_READ_BYTES]u8,start,end:int, // read from the pipe, not yet handed out
    ended:bool,
}
@(private)
Process_Slot :: struct {
    generation:u32,
    process:^sdl.Process,
    stdin:^sdl.IOStream,
    outputs:[Process_Stream]Process_Output,
    exited:bool,
    exit_code:c.int,
}
@(private)
Process_Table :: struct {slots:[]Process_Slot}

@(private)
process_table_init :: proc(p:^Platform,capacity:int) -> bool {
    slots,error:=make([]Process_Slot,capacity,p.allocator)
    if error!=nil {return false}
    for &slot in slots {slot.generation=1}
    p.processes.slots=slots
    return true
}
@(private)
process_table_destroy :: proc(p:^Platform) {
    for &slot in p.processes.slots {
        if slot.process!=nil {process_slot_release(&slot)}
    }
    delete(p.processes.slots,p.allocator)
    p.processes.slots=nil
}
@(private)
process_slot :: proc(p:^Platform,process:Process) -> ^Process_Slot {
    index:=base.handle_index(base.Handle(process))
    if process==0 || int(index)>=len(p.processes.slots) {return nil}
    slot:=&p.processes.slots[index]
    if slot.process==nil || slot.generation!=base.handle_generation(base.Handle(process)) {return nil}
    return slot
}

process_start :: proc(p:^Platform,desc:Process_Desc) -> (process:Process,error:Process_Error) {
    if len(desc.command)==0 || desc.command[0]=="" {return 0,.Invalid_Command}
    index:=-1
    for slot,i in p.processes.slots {
        if slot.process==nil {index=i;break}
    }
    if index<0 {p.stats.processes_exhausted+=1;return 0,.Capacity_Exhausted}
    scratch:=context.temp_allocator
    args:=make([]cstring,len(desc.command)+1,scratch)
    for argument,i in desc.command {args[i]=strings.clone_to_cstring(argument,scratch)}
    props:=sdl.CreateProperties()
    if props==0 {return 0,.Start_Failed}
    defer sdl.DestroyProperties(props)
    _=sdl.SetPointerProperty(props,sdl.PROP_PROCESS_CREATE_ARGS_POINTER,raw_data(args))
    _=sdl.SetNumberProperty(props,sdl.PROP_PROCESS_CREATE_STDIN_NUMBER,i64(sdl.ProcessIO.STDIO_APP))
    _=sdl.SetNumberProperty(props,sdl.PROP_PROCESS_CREATE_STDOUT_NUMBER,i64(sdl.ProcessIO.STDIO_APP))
    if desc.merge_stderr {
        _=sdl.SetBooleanProperty(props,sdl.PROP_PROCESS_CREATE_STDERR_TO_STDOUT_BOOLEAN,true)
    } else {
        _=sdl.SetNumberProperty(props,sdl.PROP_PROCESS_CREATE_STDERR_NUMBER,i64(sdl.ProcessIO.STDIO_APP))
    }
    if desc.working_directory!="" {
        _=sdl.SetStringProperty(props,sdl.PROP_PROCESS_CREATE_WORKING_DIRECTORY_STRING,strings.clone_to_cstring(desc.working_directory,scratch))
    }
    environment:^sdl.Environment
    defer if environment!=nil {sdl.DestroyEnvironment(environment)}
    if len(desc.environment)>0 {
        environment=sdl.CreateEnvironment(true)
        if environment==nil {return 0,.Start_Failed}
        for entry in desc.environment {
            split:=strings.index_byte(entry,'=')
            if split<=0 {return 0,.Invalid_Command}
            name:=strings.clone_to_cstring(entry[:split],scratch)
            value:=strings.clone_to_cstring(entry[split+1:],scratch)
            _=sdl.SetEnvironmentVariable(environment,name,value,true)
        }
        _=sdl.SetPointerProperty(props,sdl.PROP_PROCESS_CREATE_ENVIRONMENT_POINTER,environment)
    }
    handle:=sdl.CreateProcessWithProperties(props)
    if handle==nil {return 0,.Start_Failed}
    slot:=&p.processes.slots[index]
    slot.process=handle
    slot.exited=false;slot.exit_code=0
    streams:=sdl.GetProcessProperties(handle)
    slot.stdin=cast(^sdl.IOStream)sdl.GetPointerProperty(streams,sdl.PROP_PROCESS_STDIN_POINTER,nil)
    slot.outputs[.Stdout]={stream=cast(^sdl.IOStream)sdl.GetPointerProperty(streams,sdl.PROP_PROCESS_STDOUT_POINTER,nil)}
    slot.outputs[.Stderr]={stream=cast(^sdl.IOStream)sdl.GetPointerProperty(streams,sdl.PROP_PROCESS_STDERR_POINTER,nil)}
    return Process(base.handle_make(u32(index),slot.generation)),.None
}

// Reads what the process has written so far, up to len(buffer). open is
// false once the stream has ended and everything was read.
process_read :: proc(p:^Platform,process:Process,stream:Process_Stream,buffer:[]u8) -> (count:int,open:bool) {
    slot:=process_slot(p,process)
    if slot==nil {return 0,false}
    output:=&slot.outputs[stream]
    if output.stream==nil {return 0,false}
    for count<len(buffer) {
        if output.start<output.end {
            taken:=copy(buffer[count:],output.held[output.start:output.end])
            output.start+=taken;count+=taken
            continue
        }
        if output.ended {break}
        // Straight into the caller's buffer when it is large enough to ask for.
        direct:=len(buffer)-count>=PROCESS_READ_BYTES
        target:=buffer[count:] if direct else output.held[:]
        read:=int(sdl.ReadIO(output.stream,raw_data(target),uint(len(target))))
        if read<=0 {
            output.ended=sdl.GetIOStatus(output.stream)!=.NOT_READY
            break
        }
        if direct {count+=read} else {output.start=0;output.end=read}
    }
    return count,count>0 || !output.ended || output.start<output.end
}
// SDL never gets more than this in one write. Its stdin pipe on Windows is
// nonblocking with a 4 KB buffer, and a larger write took 0 bytes every time.
@(private)
PROCESS_WRITE_BYTES :: 4096
// Writes to the stdin of the process and returns how much of data the pipe
// took; the rest has to be sent again later.
process_write :: proc(p:^Platform,process:Process,data:[]u8) -> int {
    slot:=process_slot(p,process)
    if slot==nil || slot.stdin==nil {return 0}
    sent:=0
    for sent<len(data) {
        size:=min(len(data)-sent,PROCESS_WRITE_BYTES)
        written:=int(sdl.WriteIO(slot.stdin,raw_data(data[sent:]),uint(size)))
        sent+=written
        if written<size {break}
    }
    return sent
}
// The process reads end of file on its stdin.
process_stdin_close :: proc(p:^Platform,process:Process) {
    slot:=process_slot(p,process)
    if slot==nil || slot.stdin==nil {return}
    _=sdl.CloseIO(slot.stdin)
    slot.stdin=nil
}
// exited stays true, with the same code, from the moment the process ends.
process_poll :: proc(p:^Platform,process:Process) -> (exited:bool,exit_code:int) {
    slot:=process_slot(p,process)
    if slot==nil {return true,-1}
    if !slot.exited {slot.exited=sdl.WaitProcess(slot.process,false,&slot.exit_code)}
    return slot.exited,int(slot.exit_code)
}
// Asks the process to end, or ends it at once when force is set. It only
// ends that process: what it started itself keeps running.
process_terminate :: proc(p:^Platform,process:Process,force:=false) -> bool {
    slot:=process_slot(p,process)
    if slot==nil {return false}
    if slot.exited {return true}
    return sdl.KillProcess(slot.process,force)
}
process_id :: proc(p:^Platform,process:Process) -> int {
    slot:=process_slot(p,process)
    if slot==nil {return 0}
    return int(sdl.GetNumberProperty(sdl.GetProcessProperties(slot.process),sdl.PROP_PROCESS_PID_NUMBER,0))
}
// Frees the handle. A process that is still running is ended first.
process_release :: proc(p:^Platform,process:Process) {
    if slot:=process_slot(p,process);slot!=nil {process_slot_release(slot)}
}
@(private)
process_slot_release :: proc(slot:^Process_Slot) {
    if !slot.exited && !sdl.WaitProcess(slot.process,false,nil) {
        if sdl.KillProcess(slot.process,true) {_=sdl.WaitProcess(slot.process,true,nil)}
    }
    sdl.DestroyProcess(slot.process)
    slot^={generation=slot.generation+1}
}
