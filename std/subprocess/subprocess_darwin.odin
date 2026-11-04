#+build darwin
#+private
package subprocess

// macOS enforces no limit on the memory of another process.
memory_limit :: proc(pid:int,memory:u64) {}
