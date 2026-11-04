package editor

import "core:strings"
import "mirai:asset"
import "mirai:std/serial"

// The asset files edited in a session travel with it: a material an agent
// changed, a texture painted, a file undone. Each end sends what changed of
// its own, in memory and unsaved like the edit, and the others put it in the
// memory of their registries; the host passes it on. Whoever joins gets the
// unsaved files of the host after the scene. A file over COLLAB_FILE_BYTES
// stays where it was edited.

COLLAB_FILE_BYTES :: 32<<20

// A file of the assets changed here: it goes to the others with the next update.
@(private)
collab_file_changed :: proc(s:^Session,relative:string) {
    st:=collab_state(s)
    if st==nil || st.applying_file || st.phase!=.Joined || relative=="" || relative[0]=='.' {return}
    for known in st.files_out {if known==relative {return}}
    append(&st.files_out,strings.clone(relative))
}

// What a file holds now, for the others: who sent it, its path, whether it is there and its bytes.
@(private)
collab_file_payload :: proc(s:^Session,st:^Collab_State,relative:string) -> (payload:[]u8,ok:bool) {
    r:=files_registry(s)
    if r==nil {return}
    data,present,read:=file_contents(r,asset.registry_file_path(r,relative,context.temp_allocator),context.temp_allocator)
    if !read || len(data)>COLLAB_FILE_BYTES {return}
    w:serial.Writer
    serial.writer_init(&w,len(data)+len(relative)+16,context.temp_allocator)
    serial.write_scalar(&w,st.self)
    serial.write_string(&w,relative)
    serial.write_scalar(&w,u8(present))
    serial.write_bytes(&w,data)
    return serial.writer_bytes(&w),true
}

@(private)
collab_files_send :: proc(s:^Session,st:^Collab_State) {
    for relative in st.files_out {
        if payload,ok:=collab_file_payload(s,st,relative);ok {
            if st.role==.Guest {
                collab_chunks_queue(&st.peers[0],.File,payload)
            } else {
                for &peer,i in st.peers {
                    if i!=0 && peer.used && peer.joined {collab_chunks_queue(&peer,.File,payload)}
                }
            }
        }
        delete(relative)
    }
    clear(&st.files_out)
}

// The files a guest that joins needs besides the scene: those the host changed and did not save.
@(private)
collab_files_join :: proc(s:^Session,st:^Collab_State,peer:^Collab_Peer) {
    r:=files_registry(s)
    if r==nil {return}
    for &held in r.memory {
        if asset.registry_outside(held.path) || len(held.path)==0 || held.path[0]=='.' {continue}
        if payload,ok:=collab_file_payload(s,st,held.path);ok {collab_chunks_queue(peer,.File,payload)}
    }
}

// A chunk of a file from another end; the whole one changes here as there.
@(private)
collab_file_receive :: proc(s:^Session,st:^Collab_State,from:int,r:^serial.Reader) {
    sender:=&st.peers[st.role==.Host?from:0]
    if _,complete:=collab_chunk_take(r,&sender.file_bytes,&sender.file_total);!complete {return}
    payload:=sender.file_bytes[:]
    in_:=serial.reader_init(payload)
    origin:=int(serial.read_u8(&in_))
    relative:=serial.read_string(&in_)
    present:=serial.read_u8(&in_)!=0
    data:=serial.read_bytes(&in_,serial.reader_remaining(&in_))
    if in_.failed || origin>=COLLAB_PEERS || origin==int(st.self) || relative=="" || relative[0]=='.' || asset.registry_outside(relative) || strings.contains(relative,"..") {return}
    if st.role==.Host && origin!=from {return}
    if registry:=files_registry(s);registry!=nil {
        st.applying_file=true
        file_set(s,asset.registry_file_path(registry,relative,context.temp_allocator),data,!present)
        st.applying_file=false
    }
    if st.role==.Host {
        for &peer,i in st.peers {
            if i!=0 && i!=from && peer.used && peer.joined {collab_chunks_queue(&peer,.File,payload)}
        }
    }
}
