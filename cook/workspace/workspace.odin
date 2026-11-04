package workspace

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "mirai:project"

// The checkouts of one repository share what is costly to download or to
// build: the dependencies of .deps and the caches under .mirai/cache, kept by
// the main checkout (project.shared_root).

// The .deps of root, or the one of the main checkout when root has none. A
// checkout without either gets its own: that is where installs write.
deps_folder :: proc(root:string,allocator:=context.allocator) -> string {
    own:=join(root,".deps")
    if os.is_dir(own) {return slashes(own,allocator)}
    shared:=join(project.shared_root(root,context.temp_allocator),".deps")
    if os.is_dir(shared) {return slashes(shared,allocator)}
    return slashes(own,allocator)
}

// A cache every checkout of the repository shares: <main>/.mirai/cache/<name>.
cache_folder :: proc(root,name:string,allocator:=context.allocator) -> string {
    return slashes(join(project.shared_root(root,context.temp_allocator),".mirai","cache",name),allocator)
}

// The Odin compiler pinned under the deps of root, when it is there.
deps_compiler :: proc(root:string,allocator:=context.allocator) -> (path:string,found:bool) {
    deps:=deps_folder(root,context.temp_allocator)
    executable:=strings.concatenate({"odin",EXECUTABLE_SUFFIX},context.temp_allocator)
    for folder in ([3]string{"odin/dist","linux-amd64/odin","odin"}) {
        candidate:=join(deps,folder,executable)
        if os.is_file(candidate) {return slashes(candidate,allocator),true}
    }
    return "",false
}

process_alive :: proc(pid:int) -> bool {
    process,error:=os.process_open(pid)
    // Odin workaround (docs/ODIN_WORKAROUNDS.md): on Windows a process that is gone opens without an error and with no handle.
    if error!=nil || process.handle==0 {return false}
    state,_:=os.process_wait(process,0)
    return !state.exited
}

// A lock between processes: who holds it is the only one that runs what it
// guards, whatever checkout it comes from. The system releases it when its
// process ends.
Lock :: struct {
    handle:uintptr,
    owner:string, // file that names who holds it
    held:bool,
}

// Blocks until the lock of path is free and takes it. notice runs once, with
// what the holder wrote, when the lock is busy. what names this holder.
lock_acquire :: proc(path,what:string,notice:proc(holder:string)=nil) -> (lock:Lock,ok:bool) {
    folder:=os.dir(path)
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return}
    owner:=strings.concatenate({path,".owner"},context.allocator)
    noticed:=false
    for {
        handle,taken,failed:=lock_try(path)
        if failed {delete(owner);return}
        if taken {
            lock={handle=handle,owner=owner,held=true}
            _=os.write_entire_file(owner,transmute([]u8)what)
            return lock,true
        }
        if !noticed && notice!=nil {
            holder,_:=os.read_entire_file(owner,context.temp_allocator)
            notice(strings.trim_space(string(holder)))
            noticed=true
        }
        time.sleep(250*time.Millisecond)
    }
}

lock_release :: proc(lock:^Lock) {
    if !lock.held {return}
    _=os.remove(lock.owner)
    lock_close(lock.handle)
    delete(lock.owner)
    lock^={}
}

// Takes the lock of path when it is free. When it is busy, holder is what
// its holder wrote; failed when the lock cannot be made at all.
lock_take :: proc(path,what:string) -> (lock:Lock,taken:bool,holder:string,failed:bool) {
    folder:=os.dir(path)
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return {},false,"",true}
    owner:=strings.concatenate({path,".owner"},context.allocator)
    handle,ok,try_failed:=lock_try(path)
    if !ok {
        delete(owner)
        if try_failed {return {},false,"",true}
        written,_:=os.read_entire_file(strings.concatenate({path,".owner"},context.temp_allocator),context.temp_allocator)
        return {},false,strings.trim_space(string(written)),false
    }
    _=os.write_entire_file(owner,transmute([]u8)what)
    return {handle=handle,owner=owner,held=true},true,"",false
}

// Waits until the lock of path is free, without taking it, for at most limit
// (zero: no limit). notice runs once, with what the holder wrote, when it is
// busy. false when the limit passed first.
lock_wait :: proc(path:string,notice:proc(holder:string)=nil,limit:=time.Duration(0)) -> bool {
    start:=time.tick_now()
    noticed:=false
    for {
        handle,taken,failed:=lock_try(path)
        if failed {return true}
        if taken {lock_close(handle);return true}
        if !noticed && notice!=nil {
            holder,_:=os.read_entire_file(strings.concatenate({path,".owner"},context.temp_allocator),context.temp_allocator)
            notice(strings.trim_space(string(holder)))
            noticed=true
        }
        if limit>0 && time.tick_since(start)>=limit {return false}
        time.sleep(250*time.Millisecond)
    }
}

// The locks every checkout of the repository shares: <main>/.mirai/cache/locks/<name>.
lock_path :: proc(root,name:string,allocator:=context.allocator) -> string {
    return slashes(join(cache_folder(root,"locks",context.temp_allocator),name),allocator)
}

// Compilations of every checkout take turns on BUILD_LOCK, and BUILD_NOTE
// says when one took it last (builds_since). What measures time holds
// MEASURE_LOCK and starts once no compilation runs. Compilations and test runs
// do not wait for it: what they start while it runs runs at low priority
// (measurement_running). A process whose MEASURE_ENV is set is part of a
// measurement (its children): it neither takes MEASURE_LOCK nor waits for it.
BUILD_LOCK :: "build.lock"
BUILD_NOTE :: "build.last"
MEASURE_LOCK :: "measure.lock"
MEASURE_ENV :: "MIRAI_MEASURE"

// Whether this process is part of a measurement that holds MEASURE_LOCK.
measuring :: proc() -> bool {
    value,found:=os.lookup_env(MEASURE_ENV,context.temp_allocator)
    return found && value!=""
}

// Takes BUILD_LOCK like lock_acquire and notes that a compilation starts now:
// BUILD_NOTE holds what, and its modification time is when.
build_acquire :: proc(root,what:string,notice:proc(holder:string)=nil) -> (lock:Lock,ok:bool) {
    lock,ok=lock_acquire(lock_path(root,BUILD_LOCK,context.temp_allocator),what,notice)
    if ok {_=os.write_entire_file(lock_path(root,BUILD_NOTE,context.temp_allocator),transmute([]u8)what)}
    return
}

// Whether a compilation that takes BUILD_LOCK ran at some moment since since:
// one holds it now or took it after since. A measurement starts once no
// compilation runs (measure_try, and the lock_wait of who takes MEASURE_LOCK),
// so one that took it before since ended before the measurement started.
builds_since :: proc(root:string,since:time.Time) -> bool {
    if held,_,_:=lock_holder(lock_path(root,BUILD_LOCK,context.temp_allocator),context.temp_allocator);held {return true}
    info,error:=os.stat(lock_path(root,BUILD_NOTE,context.temp_allocator),context.temp_allocator)
    return error==nil && time.diff(since,info.modification_time)>=0
}

// Whether a measurement this process is not part of holds MEASURE_LOCK, and
// what its holder wrote.
measurement_running :: proc(root:string,allocator:=context.allocator) -> (running:bool,holder:string) {
    if measuring() {return false,""}
    running,holder,_=lock_holder(lock_path(root,MEASURE_LOCK,context.temp_allocator),allocator)
    return
}

// Whether the lock of path is held, what its holder wrote and when it took
// it. Not held when it is free or cannot be made, whatever an owner file left
// by a process that ended says.
lock_holder :: proc(path:string,allocator:=context.allocator) -> (held:bool,holder:string,since:time.Time) {
    handle,taken,failed:=lock_try(path)
    if taken {lock_close(handle)}
    if taken || failed {return}
    owner:=strings.concatenate({path,".owner"},context.temp_allocator)
    written,_:=os.read_entire_file(owner,context.temp_allocator)
    text:=strings.trim_space(string(written))
    if info,error:=os.stat(owner,context.temp_allocator);error==nil {since=info.modification_time}
    return true,strings.clone(text,allocator),since
}

// Starts a measurement that waits at most wait (zero: not at all): takes
// MEASURE_LOCK and then waits for the compilations that run; those that start
// later run at low priority. When the time runs out, holder is who holds the
// measurement, or the compilation when compiling. A lock that cannot be made
// does not stop it, nor does being part of a measurement: lock is then not held.
measure_try :: proc(root,what:string,wait:=time.Duration(0)) -> (lock:Lock,ok:bool,holder:string,compiling:bool) {
    if measuring() {return {},true,"",false}
    start:=time.tick_now()
    measure_path:=lock_path(root,MEASURE_LOCK,context.temp_allocator)
    build_path:=lock_path(root,BUILD_LOCK,context.temp_allocator)
    for {
        taken,failed:bool
        lock,taken,holder,failed=lock_take(measure_path,what)
        if failed {return {},true,"",false}
        if taken {break}
        left:=wait-time.tick_since(start)
        if left<=0 {return {},false,holder,false}
        lock_wait(measure_path,nil,left)
    }
    for {
        build,taken,builder,failed:=lock_take(build_path,what)
        lock_release(&build)
        if taken || failed {return lock,true,"",false}
        left:=wait-time.tick_since(start)
        if left<=0 {
            lock_release(&lock)
            return {},false,builder,true
        }
        lock_wait(build_path,nil,left)
    }
}

@(private)
EXECUTABLE_SUFFIX :: ".exe" when ODIN_OS==.Windows else ""

@(private)
join :: proc(parts:..string) -> string {
    path,_:=os.join_path(parts,context.temp_allocator)
    return path
}

@(private)
slashes :: proc(path:string,allocator:=context.allocator) -> string {
    result,_:=strings.replace_all(path,"\\","/",allocator)
    return strings.clone(result,allocator) if raw_data(result)==raw_data(path) else result
}
