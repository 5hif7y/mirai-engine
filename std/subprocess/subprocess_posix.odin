#+build !windows
#+private
package subprocess

import "core:c"
import "core:os"

when ODIN_OS==.Darwin {
    foreign import libc "system:System"
} else {
    foreign import libc "system:c"
}

// core:sys/posix does not declare these.
foreign libc {
    getpriority :: proc(which:c.int,who:u32) -> c.int ---
    setpriority :: proc(which:c.int,who:u32,priority:c.int) -> c.int ---
}

PRIO_PROCESS :: 0
LOW_NICENESS :: 10
NICENESS_MOST :: 19

_start :: proc(desc:os.Process_Desc,limits:Limits) -> (process:os.Process,error:os.Error) {
    process=os.process_start(desc) or_return
    if limits.memory>0 {memory_limit(process.pid,limits.memory)}
    if limits.priority==.Low {
        _=setpriority(PRIO_PROCESS,u32(process.pid),min(getpriority(PRIO_PROCESS,0)+LOW_NICENESS,NICENESS_MOST))
    }
    return
}

_detached :: proc(command:[]string,log:^os.File,working_dir:string) -> (process:os.Process,error:os.Error) {
    return os.process_start({working_dir=working_dir,command=command,stdout=log,stderr=log})
}

// How high this process runs, comparable between processes: higher runs first.
priority_rank :: proc() -> int {
    return -int(getpriority(PRIO_PROCESS,0))
}
