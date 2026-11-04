# std/subprocess

Package `subprocess` (`import "mirai:std/subprocess"`). It launches child processes without opening
console windows: `tools/mirai`, `cook/*` and the editor use it for tools, builds and the editor in
the background. Processes that the editor reads every frame without waiting go through
[`platform`](../../mirai-platform/references/platform.md#processes). It depends on no other package.

## API

- `start` is equivalent to `os.process_start` and returns the `os.Process` of `core:os`; `exec` runs
  it to the end and captures stdout and stderr; `detached` launches a process that outlives the
  caller, with its output in a log (`mirai session start` uses it). `subprocess.odin` documents each
  one.
- An invalid input (empty command, a NUL byte, an `env` entry without a name) gives
  `.Invalid_Command` without launching anything.
- `Limits.memory` bounds what each process of the child and its children may commit: Windows applies
  it with a job object before the child runs and Linux with `RLIMIT_DATA` as soon as it runs; macOS
  does not limit the memory of another process.

## Windows

- A console program launched by a process without a console receives a console of its own, and
  Windows shows it unless asked otherwise: `start` and `exec` ask for it to have no window only if
  the process has no console; if it has one, the child shares it and receives Ctrl+C and the
  terminal.
- `detached` gives the child a windowless console of its own and takes it out of the caller's job if
  the job allows it: closing the terminal, Ctrl+C in it or ending the job does not terminate it.
- The child inherits only stdin, stdout and stderr: the pipes of other children launched at the same
  time do not stay open in it. The command line follows the rules of the C runtime, without
  `cmd.exe`.
- Why not `core:os`: [compiler workarounds](../../../../docs/ODIN_WORKAROUNDS.md).

## Verification

- `mirai test std/subprocess`. The test program also acts as the child: with
  `mirai-subprocess-probe` as the first argument it executes an action and ends before the tests.
- On Windows, the tests launch from a process without a console a child that reports whether it has
  a visible window, and require that it does not; the same with `detached`.
- It has no `hostile_test.odin`: launching random programs is not safe. Invalid inputs have their
  own test.
