package workspace

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

// A compilation counts from when it takes its turn: while it holds it, and
// after it left it for a measurement that started before it took it.
@(test)
a_compilation_counts_from_when_it_takes_its_turn :: proc(t:^testing.T) {
    root,error:=os.make_directory_temp("","mirai-workspace-*",context.temp_allocator)
    if error!=nil {testing.fail_now(t,fmt.tprintf("no temporary folder: %v",error))}
    defer os.remove_all(root)
    before:=time.now()
    testing.expect(t,!builds_since(root,before))
    // File times can lag the precise clock by a tick of the system.
    time.sleep(50*time.Millisecond)
    lock,ok:=build_acquire(root,fmt.tprintf("pid %d, mirai test",os.get_pid()))
    testing.expect(t,ok)
    testing.expect(t,builds_since(root,before))
    lock_release(&lock)
    testing.expect(t,builds_since(root,before))
    time.sleep(50*time.Millisecond)
    testing.expect(t,!builds_since(root,time.now()))
}

// The holder of a lock is what it wrote when it took it, since then; a free
// lock has none.
@(test)
a_held_lock_says_who_holds_it_and_since_when :: proc(t:^testing.T) {
    root,error:=os.make_directory_temp("","mirai-workspace-*",context.temp_allocator)
    if error!=nil {testing.fail_now(t,fmt.tprintf("no temporary folder: %v",error))}
    defer os.remove_all(root)
    path:=lock_path(root,MEASURE_LOCK,context.temp_allocator)
    held,_,_:=lock_holder(path,context.temp_allocator)
    testing.expect(t,!held)
    what:=fmt.tprintf("pid %d, mirai measure in %s",os.get_pid(),root)
    lock,ok:=lock_acquire(path,what)
    testing.expect(t,ok)
    holder:string
    since:time.Time
    held,holder,since=lock_holder(path,context.temp_allocator)
    testing.expect(t,held)
    testing.expect_value(t,holder,what)
    testing.expectf(t,abs(time.diff(since,time.now()))<time.Minute,"taken at %v",since)
    // Part of a measurement, a process sees none.
    if !measuring() {
        running,measurer:=measurement_running(root,context.temp_allocator)
        testing.expect(t,running)
        testing.expect_value(t,measurer,what)
    }
    lock_release(&lock)
    held,_,_=lock_holder(path,context.temp_allocator)
    testing.expect(t,!held)
    // The owner file of a process that ended, whose pid is this one's now, holds nothing.
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s.owner",path),transmute([]u8)what)==nil)
    held,_,_=lock_holder(path,context.temp_allocator)
    testing.expect(t,!held)
}
