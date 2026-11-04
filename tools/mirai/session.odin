package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:cook/build"
import "mirai:editor/api"
import "mirai:cook/workspace"
import "mirai:project"
import "mirai:std/subprocess"

SESSION_USAGE :: "session start|restart|stop|status [project] [--dev|--release] [--no-build] [--discard] [--orphans] [--timeout S] [editor arguments]"

// <proyecto>/.mirai/session.json: the editor mirai session opened last in the
// project, with the mode of its binaries and its arguments, which restart
// repeats. An editor that it and the port file name was opened by mirai session.
SESSION_FILE :: "session.json"
Session_Record :: struct {
    pid:int,
    mode:string, // "dev" or "release"
    args:[]string,
}

// mirai session: an editor of a project, headless and in manual mode, that
// stays open between commands for mirai rpc, capture and mcp to drive.
//   start    builds the project (unless --no-build), opens the editor in the
//            background and returns once its API answers, with its port, its
//            process and its log; one that already answers is reused
//   restart  closes it, builds and opens it again, with the mode and the
//            arguments of the last one unless others are given
//   stop     asks it to quit and ends it if it does not. Unsaved changes go
//            alone when they are all of copies under .mirai/tmp/, and with
//            --discard otherwise. --orphans ends instead the headless editors
//            of this checkout that no port file names
//   status   says whether one answers, and which editors of this checkout no
//            port file names
// The editor names its port in <proyecto>/.mirai/api.json (api.PORT_FILE). An
// editor with a window is never reused, replaced nor closed.
cmd_session :: proc(root:string,args:[]string) -> int {
    if len(args)==0 {fmt.eprintfln("Usage: mirai %s",SESSION_USAGE);return 2}
    verb:=args[0]
    rest:=args[1:]
    folder:="."
    named:=len(rest)>0 && !strings.has_prefix(rest[0],"-")
    if named {folder,rest=rest[0],rest[1:]}
    // What is of the checkout needs no project: status and the orphans.
    checkout:=verb=="status" || (verb=="stop" && slice.contains(rest,"--orphans"))
    if os.is_file(project.path(folder,project.PROJECT_FILE,allocator=context.temp_allocator)) {
        folder=project.path_absolute(folder)
    } else if named || !checkout {
        fmt.eprintfln("mirai session: %s is not a project (%s is missing); pass the project folder",folder,project.PROJECT_FILE)
        return 2
    } else {
        folder=""
    }
    switch verb {
    case "start":   return session_start(root,folder,rest)
    case "restart": return session_restart(root,folder,rest)
    case "stop":    return session_stop(root,folder,rest)
    case "status":  return session_status(root,folder)
    }
    fmt.eprintfln("Usage: mirai %s",SESSION_USAGE)
    return 2
}

// What start and restart take; what is not theirs goes to the editor.
Session_Options :: struct {
    mode:Build_Mode,
    no_build,discard,orphans:bool,
    timeout:int, // seconds for the API to answer
    editor_args:[]string,
}

// problem says what is wrong with args; "" when nothing is.
session_options :: proc(args:[]string) -> (options:Session_Options,problem:string) {
    options.timeout=180
    editor_args:=make([dynamic]string,context.temp_allocator)
    for i:=0;i<len(args);i+=1 {
        switch args[i] {
        case "--dev","--release":
            mode:=args[i]=="--dev"?Build_Mode.Dev:Build_Mode.Release
            if options.mode!=.Keep && options.mode!=mode {return {},"--dev and --release do not go together"}
            options.mode=mode
        case "--no-build": options.no_build=true
        case "--discard":  options.discard=true
        case "--orphans":  options.orphans=true
        case "--timeout":
            value,valid:=0,false
            if i+1<len(args) {value,valid=strconv.parse_int(args[i+1],10)}
            if !valid || value<=0 {return {},"--timeout is a number of seconds"}
            options.timeout=value
            i+=1
        case: append(&editor_args,args[i])
        }
    }
    options.editor_args=editor_args[:]
    return options,""
}

// The port file of the editor of the project at folder, when its process is alive.
session_find :: proc(folder:string) -> (file:api.Port_File,alive:bool) {
    path:=project.path(folder,".mirai",api.PORT_FILE,allocator=context.temp_allocator)
    data,error:=os.read_entire_file(path,context.temp_allocator)
    if error!=nil {return}
    if json.unmarshal(data,&file,allocator=context.temp_allocator)!=nil || file.port<=0 || file.pid<=0 {return}
    return file,workspace.process_alive(file.pid)
}

// Waits up to wait for a process to end, and ends it when it does not.
process_end :: proc(pid:int,wait:time.Duration) {
    start:=time.tick_now()
    for workspace.process_alive(pid) {
        if time.tick_since(start)>=wait {
            process_kill_pid(pid)
            return
        }
        time.sleep(250*time.Millisecond)
    }
}

session_answers :: proc(port:int) -> bool {
    _,_,called:=api.rpc_call(port,"engine.status","{}",1,5000,context.temp_allocator)
    return called
}

session_record :: proc(folder:string) -> (record:Session_Record,found:bool) {
    data,error:=os.read_entire_file(project.path(folder,".mirai",SESSION_FILE,allocator=context.temp_allocator),context.temp_allocator)
    if error!=nil || json.unmarshal(data,&record,allocator=context.temp_allocator)!=nil || record.pid<=0 {return {},false}
    return record,true
}

// The mode of the binaries a record names; Keep when it names none.
session_record_mode :: proc(record:Session_Record) -> Build_Mode {
    switch record.mode {
    case "dev":     return .Dev
    case "release": return .Release
    }
    return .Keep
}

@(private="file")
session_record_write :: proc(folder:string,record:Session_Record) {
    data,error:=json.marshal(record,{pretty=true},context.temp_allocator)
    if error!=nil {return}
    _=os.write_entire_file(project.path(folder,".mirai",SESSION_FILE,allocator=context.temp_allocator),data)
}

// Only the port file of pid: another editor of the project may have written its own.
@(private="file")
session_port_remove :: proc(folder:string,pid:int) {
    if file,_:=session_find(folder);file.pid==pid || file.pid==0 {
        _=os.remove(project.path(folder,".mirai",api.PORT_FILE,allocator=context.temp_allocator))
    }
}

@(private="file")
session_print :: proc(folder:string,file:api.Port_File) {
    log:=project.path(folder,".mirai","session.log",allocator=context.temp_allocator)
    fmt.printfln(`{{"project": %q, "port": %d, "pid": %d, "log": %q}}`,folder,file.port,file.pid,log)
}

@(private="file")
session_start :: proc(root,folder:string,args:[]string) -> int {
    options,problem:=session_options(args)
    if problem=="" && (options.discard || options.orphans) {problem="--discard belongs to stop and restart, and --orphans to stop"}
    if problem!="" {fmt.eprintfln("mirai session: %s. Usage: mirai %s",problem,SESSION_USAGE);return 2}
    file,code:=session_open(root,folder,options.mode,options.no_build,options.timeout,options.editor_args)
    if code!=0 {return code}
    session_print(folder,file)
    return 0
}

@(private="file")
session_restart :: proc(root,folder:string,args:[]string) -> int {
    options,problem:=session_options(args)
    if problem=="" && options.orphans {problem="--orphans belongs to stop"}
    if problem!="" {fmt.eprintfln("mirai session restart: %s. Usage: mirai %s",problem,SESSION_USAGE);return 2}
    mode,editor_args:=options.mode,options.editor_args
    if record,recorded:=session_record(folder);recorded {
        if mode==.Keep {mode=session_record_mode(record)}
        if len(editor_args)==0 {editor_args=record.args}
    }
    closed:=false
    if file,alive:=session_find(folder);alive {
        if !file.manual {
            fmt.eprintfln("mirai session restart: the project is open in a windowed editor (pid %d), which is not a session; close it from its window",file.pid)
            return 1
        }
        discarded:int
        if closed,discarded=session_close(folder,file,options.discard,"session restart");!closed {return 1}
        if discarded>0 {fmt.eprintfln("mirai session restart: discarded %d unsaved changes of copies in .mirai/tmp/",discarded)}
    }
    file,code:=session_open(root,folder,mode,options.no_build,options.timeout,editor_args)
    if code!=0 {
        if closed {fmt.eprintln("mirai session restart: the previous session closed and no other is open")}
        return code
    }
    session_print(folder,file)
    return 0
}

// The editor of the project that answers, or a new one built and opened in
// the background; code is not 0 after saying why it could not.
session_open :: proc(root,folder:string,mode:Build_Mode,no_build:bool,timeout:int,editor_args:[]string) -> (file:api.Port_File,code:int) {
    // The editor already open, if any; found is false without one.
    open :: proc(root,folder:string,mode:Build_Mode) -> (file:api.Port_File,code:int,found:bool) {
        file,found=session_find(folder)
        if !found {return}
        // Another editor would take its port file and leave it out of reach.
        if !session_answers(file.port) {
            if file.manual {fmt.eprintfln("mirai session: the headless editor of the project (pid %d) does not answer: it is busy or hung; mirai session stop %s --discard closes it",file.pid,folder)}
            else {fmt.eprintfln("mirai session: the project is open in a windowed editor (pid %d) that does not answer; close it",file.pid)}
            return {},1,true
        }
        if !session_reusable(root,folder,mode,file,"session") {return {},1,true}
        return file,0,true
    }
    if found_file,found_code,found:=open(root,folder,mode);found {return found_file,found_code}
    // The build can close and open the session of the project itself, so it
    // goes before the lock; what is opened meanwhile is found under it.
    if !no_build {
        if built,_,_:=build_project(root,.Editor,{folder},mode);built!=0 {return {},built}
    }
    // Two at once would open two editors: the second waits and finds the first.
    lock,_:=workspace.lock_acquire(project.path(folder,".mirai","session.lock",allocator=context.temp_allocator),fmt.tprintf("pid %d, mirai session in %s",os.get_pid(),folder),proc(holder:string) {
        fmt.eprintfln("mirai session: waiting for another session of the project to open (%s)",holder!=""?holder:"another process")
    })
    defer workspace.lock_release(&lock)
    if found_file,found_code,found:=open(root,folder,mode);found {return found_file,found_code}
    _=os.remove(project.path(folder,".mirai",api.PORT_FILE,allocator=context.temp_allocator))
    layers_isolate(root)
    log:=project.path(folder,".mirai","session.log",allocator=context.temp_allocator)
    engine:=build.engine_mode_resolve(root,mode)
    command:=make([dynamic]string)
    append(&command,build.engine_paths(root,engine).editor_program,"--project",folder,"--headless")
    append(&command,..editor_args)
    process,error:=subprocess.detached(command[:],log,root)
    if error!=nil {fmt.eprintfln("mirai session: could not open %s: %v",command[0],error);return {},1}
    session_record_write(folder,{process.pid,engine==.Dev?"dev":"release",editor_args})
    deadline:=time.tick_now()
    for time.duration_seconds(time.tick_since(deadline))<f64(timeout) {
        if found,alive:=session_find(folder);alive && session_answers(found.port) {return found,0}
        if state,_:=os.process_wait(process,0);state.exited {
            fmt.eprintfln("mirai session: the editor exited before opening the API (exit code %d); its log:",state.exit_code)
            session_log_tail(log)
            return {},1
        }
        time.sleep(250*time.Millisecond)
    }
    // Left open, it would run out of reach, holding the binaries of the engine.
    process_kill_pid(process.pid)
    fmt.eprintfln("mirai session: the API did not answer in %d s and the editor was closed (pid %d); its log:",timeout,process.pid)
    session_log_tail(log)
    return {},1
}

// Whether an editor of the project that answers can serve a headless session
// in mode. One with a window is the user's: it is not driven frame by frame,
// and a second editor would take its port file. One that runs binaries older
// than those of now is reused with a warning on stderr: it keeps what it
// loaded until it is opened again. command names who asks.
session_reusable :: proc(root,folder:string,mode:Build_Mode,file:api.Port_File,command:string) -> bool {
    if file.engine=="" {
        fmt.eprintfln("mirai %s: the open session (pid %d) does not say which binaries it runs; mirai session restart opens it again",command,file.pid)
        return true
    }
    if !file.manual {
        fmt.eprintfln("mirai %s: the project is open in a windowed editor (pid %d); close it, or drive it with mirai rpc --project %s",command,file.pid,folder)
        return false
    }
    engine:=build.engine_mode_resolve(root,mode)
    paths:=build.engine_paths(root,engine,context.temp_allocator)
    stale:string
    switch {
    case !path_same(file.engine,paths.folder): stale=fmt.tprintf("runs the binaries of %s, not those of %s",file.engine,paths.folder)
    case file.stamp!=build.engine_stamp_of(paths.folder,context.temp_allocator): stale="runs engine binaries older than the last build"
    case !build.engine_current(root,engine): stale="runs an engine whose sources changed afterwards"
    case file.library!=build.target_stamp_of(folder,.Editor,context.temp_allocator): stale="runs a project library older than the last one built"
    case:
        p,error:=project.open(folder,root,context.temp_allocator)
        if error.code==.None && build.target_state(&p,.Editor,"",mode==.Dev,engine)!=.Current {stale="runs a project library whose sources changed afterwards"}
        if error.code==.None {project.close(&p)}
    }
    if stale!="" {fmt.eprintfln("mirai %s: the open session (pid %d) %s; mirai session restart opens it with the current build",command,file.pid,stale)}
    return true
}

// Asks the editor to quit and ends it when it does not. Unsaved changes go
// with discard, or alone when they are all of copies under .mirai/tmp/
// (discarded counts those); otherwise it says what they are and how to go on,
// and closed is false. command names who asks; retry, what discards them.
session_close :: proc(folder:string,file:api.Port_File,discard:bool,command:="session stop",retry:="") -> (closed:bool,discarded:int) {
    retry:=retry!=""?retry:fmt.tprintf("mirai %s %s --discard",command,folder)
    params:=`{"discard":true}`
    if !discard {
        unsaved,listed:=session_unsaved(file.port)
        if listed && len(unsaved)>0 && !session_discardable(folder,unsaved) {
            fmt.eprintfln("mirai %s: the editor (pid %d) has unsaved changes outside .mirai/tmp/:",command,file.pid)
            for path in unsaved {fmt.eprintfln("  %s",path!=""?path:"a scene that was never saved")}
            fmt.eprintfln("mirai %s: `%s` discards them; scene.save and asset.save save them",command,retry)
            return false,0
        }
        if listed {discarded=len(unsaved)}
        if discarded==0 {params="{}"}
    }
    _,err,called:=api.rpc_call(file.port,"engine.shutdown",params,1,10000,context.temp_allocator)
    if !called && !discard {
        fmt.eprintfln("mirai %s: the editor (pid %d) did not close: %s; `%s` closes it anyway and loses what it did not save",command,file.pid,api.error_text(err,context.temp_allocator),retry)
        return false,0
    }
    process_end(file.pid,20*time.Second)
    session_port_remove(folder,file.pid)
    return true,discarded
}

// What the editor holds unsaved: the scenes of its documents (relative to
// the assets folder inside it; "" for one never saved) and the assets
// (relative to the assets folder, or to the project outside it). listed is
// false when it could not tell.
session_unsaved :: proc(port:int) -> (paths:[]string,listed:bool) {
    documents,_,documents_called:=api.rpc_call(port,"editor.documents","{}",1,5000,context.temp_allocator)
    if !documents_called {return}
    assets,_,assets_called:=api.rpc_call(port,"asset.unsaved","{}",2,5000,context.temp_allocator)
    if !assets_called {return}
    return session_unsaved_parse(documents,assets)
}

// The unsaved paths in the results of editor.documents and asset.unsaved.
session_unsaved_parse :: proc(documents,assets:string) -> (paths:[]string,ok:bool) {
    Documents :: struct {documents:[]struct {path:string,dirty:bool}}
    Assets :: struct {assets:[]struct {path:string}}
    d:Documents
    a:Assets
    if json.unmarshal_string(documents,&d,allocator=context.temp_allocator)!=nil {return}
    if json.unmarshal_string(assets,&a,allocator=context.temp_allocator)!=nil {return}
    list:=make([dynamic]string,context.temp_allocator)
    for document in d.documents {
        if document.dirty {append(&list,document.path)}
    }
    for held in a.assets {append(&list,held.path)}
    return list[:],true
}

// Whether every unsaved path is of a copy under .mirai/tmp/ of the project
// at folder, where agents keep what they try: those go without --discard.
session_discardable :: proc(folder:string,paths:[]string) -> bool {
    temporary:=project.path(folder,".mirai","tmp",allocator=context.temp_allocator)
    for path in paths {
        if path=="" {return false}
        file:=os.is_absolute_path(path)?path:project.path(folder,path,allocator=context.temp_allocator)
        clean,_:=os.clean_path(file,context.temp_allocator)
        if !path_inside(clean,temporary) {return false}
    }
    return true
}

// Whether path is inside folder, with either slash.
path_inside :: proc(path,folder:string) -> bool {
    p,_:=strings.replace_all(path,"\\","/",context.temp_allocator)
    f,_:=strings.replace_all(strings.trim_right(folder,"/\\"),"\\","/",context.temp_allocator)
    return len(f)>0 && len(p)>len(f) && p[len(f)]=='/' && path_same(p[:len(f)],f)
}

@(private="file")
session_log_tail :: proc(log:string) {
    data,_:=os.read_entire_file(log,context.temp_allocator)
    text:=string(data)
    lines:=strings.split_lines(text,context.temp_allocator)
    for line in lines[max(len(lines)-30,0):] {fmt.eprintln(line)}
}

@(private="file")
session_stop :: proc(root,folder:string,args:[]string) -> int {
    discard,orphans:=false,false
    for arg in args {
        switch arg {
        case "--discard": discard=true
        case "--orphans": orphans=true
        case: fmt.eprintfln("Usage: mirai %s",SESSION_USAGE);return 2
        }
    }
    if orphans {return session_stop_orphans(root,folder)}
    file,alive:=session_find(folder)
    if !alive {
        _=os.remove(project.path(folder,".mirai",api.PORT_FILE,allocator=context.temp_allocator))
        fmt.println("There is no open session.")
        return 0
    }
    if !file.manual {
        fmt.eprintfln("mirai session stop: the project is open in a windowed editor (pid %d), which is not a session; close it from its window",file.pid)
        return 1
    }
    closed,discarded:=session_close(folder,file,discard)
    if !closed {return 1}
    if discarded>0 {fmt.printfln("Session closed; discarded %d unsaved changes of copies in .mirai/tmp/.",discarded)}
    else {fmt.println("Session closed.")}
    return 0
}

@(private="file")
session_status :: proc(root,folder:string) -> int {
    code:=0
    if folder!="" {
        code=1
        file,alive:=session_find(folder)
        switch {
        case !alive: fmt.println("There is no open session.")
        case !session_answers(file.port): fmt.printfln("The editor of the project (pid %d) does not answer: it is busy or hung.",file.pid)
        case:
            session_print(folder,file)
            code=0
        }
    }
    listed:=0
    for p in engine_processes(engine_folder(root)) {
        if !program_is_editor(p.program) {continue}
        role:=engine_process_role(p)
        if role!=.Orphan && role!=.Unknown {continue}
        if listed==0 {fmt.eprintln("mirai session: editors of this checkout that no api.json names (rpc and session do not see them):")}
        listed+=1
        fmt.eprintfln("  %s",engine_process_text(p,role))
    }
    if folder=="" && listed==0 {fmt.println("There are no orphan editors in this checkout.")}
    return code
}

// Ends the headless orphans of the checkout, of the project at folder when
// it is not "". One with a window is only named.
@(private="file")
session_stop_orphans :: proc(root,folder:string) -> int {
    closed,kept,failed:=0,0,0
    for p in engine_processes(engine_folder(root)) {
        if !program_is_editor(p.program) || engine_process_role(p)!=.Orphan {continue}
        if folder!="" && !path_same(p.project,folder) {continue}
        if !p.headless {
            kept+=1
            fmt.eprintfln("mirai session: not closing %s",engine_process_text(p,.Orphan))
            continue
        }
        if !process_kill_pid(p.pid) {
            failed+=1
            fmt.eprintfln("mirai session: could not close the orphan editor pid %d",p.pid)
            continue
        }
        closed+=1
        fmt.printfln("Orphan editor closed: pid %d, %s.",p.pid,p.project)
    }
    if closed+kept+failed==0 {fmt.println("There are no orphan editors.")}
    return failed>0?1:0
}

// A program of the engine of a checkout that runs: an editor, a player or the importer.
Engine_Process :: struct {
    pid,parent:int,
    program:string, // its executable, with forward slashes
    project:string, // the absolute folder its --project names; "" when it names none
    headless:bool,
    read:bool,      // its arguments could be read: without them project and headless are unknown
}

// What a program of the engine is to mirai session.
Engine_Role :: enum u8 {
    Session,   // a headless editor mirai session opened: the port file and the record of its project name it
    Reachable, // an editor the port file of its project names, opened otherwise (mirai edit)
    Orphan,    // an editor no port file names: rpc, mcp and session do not reach it
    Program,   // a player or the importer
    Unknown,   // its arguments could not be read
}

// The folder of the binaries of every mode of the engine of the checkout.
engine_folder :: proc(root:string) -> string {
    return filepath.dir(build.engine_paths(root,.Release,context.temp_allocator).folder)
}

program_is_editor :: proc(program:string) -> bool {
    return strings.equal_fold(filepath.stem(program),"mirai-editor")
}

// The programs that run from folder or a folder inside it, but this one.
engine_processes :: proc(folder:string) -> []Engine_Process {
    pids,error:=os.process_list(context.temp_allocator)
    if error!=nil {return nil}
    found:=make([dynamic]Engine_Process,context.temp_allocator)
    for pid in pids {
        if pid==os.get_pid() {continue}
        info,info_error:=os.process_info_by_pid(pid,{.Executable_Path},context.temp_allocator)
        if info_error!=nil || !path_inside(info.executable_path,folder) {continue}
        p:=Engine_Process{pid=pid}
        p.program,_=strings.replace_all(info.executable_path,"\\","/",context.temp_allocator)
        full,_:=os.process_info_by_pid(pid,{.PPid,.Command_Args,.Working_Dir},context.temp_allocator)
        if .PPid in full.fields {p.parent=full.ppid}
        if .Command_Args in full.fields {
            p.read=true
            p.project,p.headless=engine_arguments(full.command_args,full.working_dir)
        }
        append(&found,p)
    }
    return found[:]
}

// The project a program of the engine opens and whether it runs without a
// window, from its arguments; a relative project is of working.
engine_arguments :: proc(args:[]string,working:string) -> (folder:string,headless:bool) {
    for arg,i in args {
        if arg=="--headless" {headless=true}
        if arg=="--project" && i+1<len(args) {folder=args[i+1]}
    }
    if folder=="" {return}
    if !os.is_absolute_path(folder) && working!="" {folder=project.path(working,folder,allocator=context.temp_allocator)}
    folder,_=os.clean_path(folder,context.temp_allocator)
    folder,_=strings.replace_all(folder,"\\","/",context.temp_allocator)
    return
}

// What a program of the engine is, by the pids the port file (port) and the
// record (recorded) of its project name: 0 when they name none.
engine_role :: proc(p:Engine_Process,port,recorded:int) -> Engine_Role {
    switch {
    case !p.read:                         return .Unknown
    case !program_is_editor(p.program):   return .Program
    case port!=p.pid:                     return .Orphan
    case recorded==p.pid && p.headless:   return .Session
    }
    return .Reachable
}

engine_process_role :: proc(p:Engine_Process) -> Engine_Role {
    port,recorded:=0,0
    if p.project!="" {
        file,_:=session_find(p.project)
        record,_:=session_record(p.project)
        port,recorded=file.pid,record.pid
    }
    return engine_role(p,port,recorded)
}

// A program of the engine, whether it has a window and what to do so that
// it lets go of its binaries.
engine_process_text :: proc(p:Engine_Process,role:Engine_Role) -> string {
    name:=filepath.base(p.program)
    window:=p.headless?"headless":"windowed"
    switch role {
    case .Unknown:   return fmt.tprintf("pid %d, %s, its arguments unread (its project and whether it has a window are unknown): close it",p.pid,p.program)
    case .Program:   return fmt.tprintf("pid %d, %s %s of %s: close it",p.pid,name,window,p.project!=""?p.project:"no project")
    case .Session:   return fmt.tprintf("pid %d, %s headless: the mirai session of %s; mirai session stop %s closes it and mirai build editor %s restarts it by itself",p.pid,name,p.project,p.project,p.project)
    case .Orphan:
        if p.headless {return fmt.tprintf("pid %d, %s headless of %s, orphan (without the api.json of its project): mirai session stop --orphans closes it",p.pid,name,p.project)}
        return fmt.tprintf("pid %d, %s windowed of %s, without the api.json of its project: close it from its window",p.pid,name,p.project)
    case .Reachable:
        if p.headless {return fmt.tprintf("pid %d, %s headless of %s, opened outside mirai session: mirai rpc engine.shutdown --project %s closes it",p.pid,name,p.project,p.project)}
        return fmt.tprintf("pid %d, %s windowed of %s: the editor of a person (mirai edit); close it from its window",p.pid,name,p.project)
    }
    return ""
}

// Frees the binaries of the engine of a mode before a build replaces them:
// Windows does not replace what a program loaded. The session mirai session
// opened for the project at folder closes, and session_reopen opens it again
// after the build; anything else that runs them stops the build, each one
// said with what to do, and ok is false. folder "" closes no session.
engine_release :: proc(root,folder:string,mode:Build_Mode,command:string) -> (closed:Session_Record,discarded:int,ok:bool) {
    binaries:=build.engine_paths(root,mode,context.temp_allocator).folder
    running:=engine_processes(binaries)
    roles:=make([]Engine_Role,len(running),context.temp_allocator)
    session:=0
    for p,i in running {
        roles[i]=engine_process_role(p)
        if roles[i]==.Session && folder!="" && path_same(p.project,folder) {session=p.pid}
    }
    blocking:=0
    for p,i in running {
        // What the session started, as its players, ends with it.
        if session!=0 && (p.pid==session || p.parent==session) {continue}
        if blocking==0 {fmt.eprintfln("mirai %s: the engine binaries of %s cannot be replaced while they run:",command,binaries)}
        blocking+=1
        fmt.eprintfln("  %s",engine_process_text(p,roles[i]))
    }
    if blocking>0 {
        fmt.eprintfln("mirai %s: close them, or build in a worktree (mirai worktree new <name>), which has binaries of its own",command)
        return {},0,false
    }
    if session==0 {return {},0,true}
    file,_:=session_find(folder)
    closed,_=session_record(folder)
    shut:bool
    if shut,discarded=session_close(folder,file,false,command,fmt.tprintf("mirai session restart %s --discard",folder));!shut {return {},0,false}
    for p in running {
        if p.parent==session {process_end(p.pid,5*time.Second)}
    }
    return closed,discarded,true
}

// Opens again, with its arguments and without building, the session
// engine_release closed; says so in a line.
session_reopen :: proc(root,folder:string,closed:Session_Record,discarded:int,mode:Build_Mode,engine_built:bool,command:string) {
    copies:=discarded>0?fmt.tprintf(", discarding %d unsaved changes of copies in .mirai/tmp/,",discarded):""
    if !engine_built {
        fmt.eprintfln("mirai %s: closed the session of %s (pid %d)%s because it ran the binaries to replace, and the engine did not build: mirai session start opens it",command,folder,closed.pid,copies)
        return
    }
    file,code:=session_open(root,folder,mode,true,180,closed.args)
    if code!=0 {
        fmt.eprintfln("mirai %s: closed the session of %s (pid %d)%s because it ran the binaries to replace, and could not open it again",command,folder,closed.pid,copies)
        return
    }
    fmt.printfln("Session of %s closed (pid %d)%s because it ran the binaries to replace, and opened again with this build (pid %d).",folder,closed.pid,copies,file.pid)
}
