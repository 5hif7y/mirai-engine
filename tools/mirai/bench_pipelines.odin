package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "mirai:project"
import "mirai:std/subprocess"

BENCH_PIPELINES_USAGE :: "bench pipelines [project] [--scene S] [--frames N] [--release] [--out file]"

// mirai bench pipelines: what compiling the GPU pipelines costs a start of the
// game, the first after an install or an update against the next. It plays
// the project twice with a window, a cold start and a warm one, and writes the
// table of each: the start, the pipelines the driver compiled and what the
// frames lost to them. Cold is both caches empty: the pipelines the project
// kept (set aside, and put back after) and the driver's own, which the run
// points at an empty folder through the variables each driver reads. A cold
// run is only believed when the kept pipelines were missing and the driver
// wrote into that folder; otherwise the table says the run may not have been
// cold, and why.

BENCH_PIPELINES_FRAMES :: 300
BENCH_PIPELINES_ASIDE :: ".bench-aside" // after the kept pipelines while they are set aside
// The variables that point each driver's cache of compiled shaders at a folder.
BENCH_PIPELINES_DRIVER_PATHS :: [?]string{"AMD_VK_PIPELINE_CACHE_PATH","__GL_SHADER_DISK_CACHE_PATH","MESA_SHADER_CACHE_DIR"}

Bench_Pipelines_Options :: struct {
    folder,scene,out:string,
    frames:int,
    mode:Build_Mode,
}

// What one start of the player says about its pipelines (host/player.odin,
// host/load_profile.odin); found: the summary line was there.
Bench_Pipelines_Run :: struct {
    startup_ms,resident_ms:f64,
    made,kept,late:int,
    driver_ms,longest_ms,waited_ms:f64,
    store:string,
    found:bool,
}

@(private)
bench_pipelines_options :: proc(args:[]string) -> (o:Bench_Pipelines_Options,error:string) {
    o={folder=".",frames=BENCH_PIPELINES_FRAMES}
    mode,rest:=build_mode_take(args)
    o.mode=mode
    named:=false
    for i:=0;i<len(rest);i+=1 {
        if positional(rest[i]) {
            if named {return o,fmt.tprintf("'%s' is one too many: it measures a single project",rest[i])}
            o.folder,named=rest[i],true
            continue
        }
        switch rest[i] {
        case "--scene","--frames","--out":
        case: return o,fmt.tprintf("there is no option %s",rest[i])
        }
        if i+1>=len(rest) || rest[i+1]=="" {return o,fmt.tprintf("%s needs a value",rest[i])}
        option,value:=rest[i],rest[i+1]
        i+=1
        switch option {
        case "--scene": o.scene=value
        case "--out":   o.out=value
        case "--frames":
            number,ok:=strconv.parse_int(value,10)
            if !ok || number<30 || number>36000 {return o,fmt.tprintf("--frames goes from 30 to 36000, not '%s'",value)}
            o.frames=number
        }
    }
    return o,""
}

// The value in line between after and before, as a number; ok false when
// either is missing or it is no number.
@(private="file")
bench_pipelines_between :: proc(line,after,before:string) -> (value:f64,ok:bool) {
    start:=0
    if after!="" {
        at:=strings.index(line,after)
        if at<0 {return 0,false}
        start=at+len(after)
    }
    end:=strings.index(line[start:],before)
    if end<0 {return 0,false}
    text:=strings.trim_space(line[start:][:end])
    if space:=strings.last_index_byte(text,' ');space>=0 {text=text[space+1:]}
    return strconv.parse_f64(text)
}

// Reads what the player printed (stdout and stderr) into a run.
bench_pipelines_parse :: proc(output:string) -> (run:Bench_Pipelines_Run) {
    for line in strings.split_lines(output,context.temp_allocator) {
        switch {
        case strings.has_prefix(line,"mirai: load Scene "):
            run.resident_ms,_=bench_pipelines_between(line,"resident at "," ms")
        case strings.has_prefix(line,"  phases: ") && strings.contains(line," Startup "):
            // The phases go the costliest first: Startup is anywhere in the line.
            run.startup_ms,_=bench_pipelines_between(line," Startup "," ms")
        case strings.has_prefix(line,"  pipelines: ") && strings.contains(line," made ("):
            made,_:=bench_pipelines_between(line,"pipelines: "," made")
            kept,_:=bench_pipelines_between(line,"(", " kept)")
            late,_:=bench_pipelines_between(line,"; "," frames late")
            run.made,run.kept,run.late=int(made),int(kept),int(late)
            run.driver_ms,_=bench_pipelines_between(line,"kept), "," ms in the driver")
            run.longest_ms,_=bench_pipelines_between(line,"longest "," ms")
            run.waited_ms,_=bench_pipelines_between(line,"frames late, "," ms waited")
            if at:=strings.index(line,"store ");at>=0 {
                rest:=line[at+len("store "):]
                if end:=strings.index_byte(rest,';');end>=0 {run.store=strings.clone(rest[:end],context.temp_allocator)}
            }
            run.found=true
        }
    }
    return
}

// Why a cold run may not have been cold; "" when both caches were empty.
bench_pipelines_cold_doubt :: proc(cold:Bench_Pipelines_Run,driver_wrote:bool) -> string {
    switch {
    case !cold.found:          return "the player did not print its pipelines: nothing to say of the run"
    case cold.store!="Missing": return fmt.tprintf("the kept pipelines were %s, not Missing: they were not set aside, and the run read them",cold.store)
    case !driver_wrote:        return "the driver wrote nothing in the folder its variables named: it kept its own cache, which may have served this run, and its times are a floor"
    }
    return ""
}

@(private)
bench_pipelines :: proc(root:string,args:[]string) -> int {
    o,error:=bench_pipelines_options(args)
    if error!="" {fmt.eprintfln("mirai bench: %s\nUsage: mirai %s",error,BENCH_PIPELINES_USAGE);return 2}
    if !os.is_file(project.path(o.folder,project.PROJECT_FILE,allocator=context.temp_allocator)) {
        fmt.eprintfln("mirai bench: %s is not a project (%s is missing); pass the folder of the project",o.folder,project.PROJECT_FILE)
        return 2
    }
    folder:=project.path_absolute(o.folder,context.temp_allocator)
    if file,alive:=session_find(folder);alive {
        fmt.eprintfln("mirai bench: an editor of the project is open (pid %d) and keeps the same pipelines; close it, or run mirai session stop %s",file.pid,o.folder)
        return 1
    }
    user:=project.user_folder(folder,context.temp_allocator)
    if user=="" {fmt.eprintln("mirai bench: the project has no user folder where its pipelines are kept");return 1}
    kept:=filepath.join({user,project.PIPELINES_FILE},context.temp_allocator) or_else ""
    aside:=strings.concatenate({kept,BENCH_PIPELINES_ASIDE},context.temp_allocator)
    if os.exists(aside) {
        fmt.eprintfln("mirai bench: %s is left from a measurement that did not end: rename it back to %s, or delete it",aside,project.PIPELINES_FILE)
        return 1
    }
    if code,_,_:=build_project(root,.Editor,{o.folder},o.mode);code!=0 {return code}
    temporary,temporary_error:=os.temp_directory(context.temp_allocator)
    if temporary_error!=nil {fmt.eprintln("mirai bench: there is no temporary folder for the driver's cache");return 1}
    driver:=filepath.join({temporary,fmt.tprintf("mirai-bench-pipelines-%d",os.get_pid())},context.temp_allocator) or_else ""
    if os.make_directory_all(driver)!=nil {fmt.eprintfln("mirai bench: could not make %s",driver);return 1}
    defer os.remove_all(driver)

    // The kept pipelines go aside for the measurement and come back after it, whatever it gave.
    had:=os.exists(kept)
    if had && os.rename(kept,aside)!=nil {fmt.eprintfln("mirai bench: could not set %s aside: is a game of the project open?",kept);return 1}
    defer {
        os.remove(kept)
        if had && os.rename(aside,kept)!=nil {fmt.eprintfln("mirai bench: could not put %s back: rename %s to it",kept,aside)}
    }

    env:=make([dynamic]string,context.temp_allocator)
    if environ,environ_error:=os.environ(context.temp_allocator);environ_error==nil {append(&env,..environ)}
    for name in BENCH_PIPELINES_DRIVER_PATHS {append(&env,fmt.tprintf("%s=%s",name,driver))}
    append(&env,"AMD_VK_PIPELINE_CACHE_FILENAME=mirai-bench","__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1")
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,project_engine_paths(root,o.folder,o.mode).player_program,"--project",folder,"--frames",fmt.tprint(o.frames),"--show-window")
    if o.scene!="" {append(&command,"--scene",o.scene)}

    runs:[2]Bench_Pipelines_Run
    names:=[2]string{"cold","warm"}
    driver_wrote:=false
    for &run,i in runs {
        fmt.printfln("mirai bench: %s start of %s (%d frames)…",names[i],o.folder,o.frames)
        state,stdout,stderr,run_error:=subprocess.exec({command=command[:],env=env[:],working_dir=root},context.temp_allocator)
        if run_error!=nil || state.exit_code!=0 {
            fmt.eprintfln("mirai bench: the %s start failed (exit %d %v):\n%s",names[i],state.exit_code,run_error,string(stderr))
            return 1
        }
        run=bench_pipelines_parse(strings.concatenate({string(stdout),"\n",string(stderr)},context.temp_allocator))
        if i==0 {
            if entries,read_error:=os.read_all_directory_by_path(driver,context.temp_allocator);read_error==nil {driver_wrote=len(entries)>0}
        }
    }
    table:=bench_pipelines_table(o,runs,bench_pipelines_cold_doubt(runs[0],driver_wrote))
    fmt.print(table)
    if o.out!="" && os.write_entire_file(o.out,transmute([]u8)table)!=nil {
        fmt.eprintfln("mirai bench: could not write %s",o.out)
        return 1
    }
    return 0
}

// The table of the two starts, in Markdown, with what to doubt.
bench_pipelines_table :: proc(o:Bench_Pipelines_Options,runs:[2]Bench_Pipelines_Run,doubt:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    scene:=o.scene if o.scene!="" else "the start scene"
    fmt.sbprintfln(&b,"Pipelines of %s, %s, %d frames:\n",o.folder,scene,o.frames)
    fmt.sbprintln(&b,"| | Cold | Warm |")
    fmt.sbprintln(&b,"| --- | ---: | ---: |")
    cold,warm:=runs[0],runs[1]
    fmt.sbprintfln(&b,"| Start of the renderer, ms | %.0f | %.0f |",cold.startup_ms,warm.startup_ms)
    fmt.sbprintfln(&b,"| Resident, ms after the load began | %.0f | %.0f |",cold.resident_ms,warm.resident_ms)
    fmt.sbprintfln(&b,"| Pipelines made | %d | %d |",cold.made,warm.made)
    fmt.sbprintfln(&b,"| Compiled by the driver | %d | %d |",cold.made-cold.kept,warm.made-warm.kept)
    fmt.sbprintfln(&b,"| Driver time, ms summed | %.0f | %.0f |",cold.driver_ms,warm.driver_ms)
    fmt.sbprintfln(&b,"| Longest pipeline, ms | %.1f | %.1f |",cold.longest_ms,warm.longest_ms)
    fmt.sbprintfln(&b,"| Frames late (materials as rows) | %d | %d |",cold.late,warm.late)
    fmt.sbprintfln(&b,"| Frames waited, ms | %.0f | %.0f |",cold.waited_ms,warm.waited_ms)
    fmt.sbprintfln(&b,"| Kept pipelines found | %s | %s |",cold.store,warm.store)
    if doubt!="" {fmt.sbprintfln(&b,"\nThe cold start may not have been cold: %s.",doubt)}
    if warm.found && warm.made>warm.kept {
        fmt.sbprintfln(&b,"\nThe warm start compiled %d: pipelines the cold one did not keep (speculative ones it had not ended), or keys that change between starts.",warm.made-warm.kept)
    }
    return strings.to_string(b)
}
