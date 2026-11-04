#+build linux, darwin, freebsd, openbsd, netbsd
package api

import "core:c"
import "core:net"
import "core:time"
import "core:sys/posix"

// The children of the editor (the compiler of a Build) do not inherit the
// sockets of the server: a connection would stay open until the child ends.
@(private)
socket_private :: proc(socket:net.TCP_Socket) {
    posix.fcntl(posix.FD(socket),.SETFD,c.int(posix.FD_CLOEXEC))
}

@(private)
sockets_wait :: proc(sockets:[]net.TCP_Socket,timeout:time.Duration) {
    fds:[WAIT_SOCKETS]posix.pollfd
    for socket,i in sockets {fds[i]={fd=posix.FD(socket),events={.IN}}}
    posix.poll(&fds[0],posix.nfds_t(len(sockets)),c.int(time.duration_milliseconds(timeout)))
}
