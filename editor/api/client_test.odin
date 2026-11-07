package api

import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

@(private="file")
Silent_Editor :: struct {listener:net.TCP_Socket, close:bool}

// Accepts one connection and reads the request. It never answers: it closes
// the connection when close is set, or keeps it open until the client leaves.
@(private="file")
silent_editor_run :: proc(t:^thread.Thread) {
    editor:=(^Silent_Editor)(t.data)
    socket,_,accept_error:=net.accept_tcp(editor.listener)
    if accept_error!=nil {return}
    defer net.close(socket)
    chunk:[4096]u8
    for {
        n,err:=net.recv_tcp(socket,chunk[:])
        if err!=nil || n==0 {return}
        if editor.close && strings.contains(string(chunk[:n]),"\r\n\r\n") {return}
    }
}

@(private="file")
silent_post :: proc(t:^testing.T,close:bool,timeout_ms:int) -> (error:Error,elapsed:time.Duration,ok:bool) {
    listener,listen_error:=net.listen_tcp({address=net.IP4_Loopback,port=0},1)
    if !testing.expect(t,listen_error==nil) {return}
    defer net.close(listener)
    endpoint,endpoint_error:=net.bound_endpoint(listener)
    if !testing.expect(t,endpoint_error==nil) {return}
    editor:=Silent_Editor{listener,close}
    worker:=thread.create(silent_editor_run)
    worker.data=&editor
    thread.start(worker)
    defer thread.destroy(worker)
    started:=time.tick_now()
    status,response,post_error:=client_post(endpoint.port,"/rpc",`{}`,timeout_ms,context.temp_allocator)
    elapsed=time.tick_since(started)
    thread.join(worker)
    testing.expect_value(t,status,0)
    testing.expect(t,response==nil)
    return post_error,elapsed,true
}

@(test)
an_editor_that_does_not_answer_in_time_is_a_timeout_and_one_that_closes_is_not :: proc(t:^testing.T) {
    silent,elapsed,ok:=silent_post(t,false,200)
    if !ok {return}
    testing.expect_value(t,silent.code,TIMEOUT)
    testing.expectf(t,strings.contains(silent.message,"did not answer in 200 ms"),"%s",silent.message)
    testing.expectf(t,elapsed>=150*time.Millisecond && elapsed<5*time.Second,"the timeout ends the wait: %v",elapsed)
    closed,closed_elapsed,closed_ok:=silent_post(t,true,5000)
    if !closed_ok {return}
    testing.expect_value(t,closed.code,CLOSED)
    testing.expectf(t,strings.contains(closed.message,"closed the connection without answering"),"%s",closed.message)
    testing.expectf(t,closed_elapsed<4*time.Second,"a closed connection does not wait for the timeout: %v",closed_elapsed)
}
