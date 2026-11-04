package api

import "core:net"
import "core:time"
import win "core:sys/windows"

// The children of the editor (the compiler of a Build) do not inherit the
// sockets of the server: a connection would stay open until the child ends.
@(private)
socket_private :: proc(socket:net.TCP_Socket) {
    win.SetHandleInformation(win.HANDLE(uintptr(socket)),win.HANDLE_FLAG_INHERIT,0)
}

@(private)
sockets_wait :: proc(sockets:[]net.TCP_Socket,timeout:time.Duration) {
    fds:[WAIT_SOCKETS]win.WSA_POLLFD
    for socket,i in sockets {fds[i]={fd=win.SOCKET(socket),events=win.POLLRDNORM}}
    win.WSAPoll(&fds[0],win.c_ulong(len(sockets)),win.c_int(time.duration_milliseconds(timeout)))
}
