package editor

import "core:fmt"
import "mirai:core"
import "mirai:editor/api"
import wire "mirai:net"
import "mirai:std/base"

// What another editor of the session has selected is theirs until they
// select something else: this end, its agents included, does not edit it,
// and sees it outlined in their color. A Play edits a copy, which is nobody's.

// The other editor that has e of the document selected.
@(private)
collab_holder :: proc(s:^Session,e:core.Entity) -> (peer:int,held:bool) {
    st:=collab_state(s)
    if st==nil || st.phase!=.Joined || s.edit_world==nil || shown_world(s).data!=s.edit_world {return}
    id:=api_entity_id(edited_world(s),e)
    if id==0 {return}
    now:=wire.host_time(&st.host)
    for &other,i in st.peers {
        if !collab_peer_live(st,i,now) {continue}
        for selected in other.selection[:other.selection_count] {
            if selected==id {return i,true}
        }
    }
    return
}

// Another editor that is in the session now and edits the document.
@(private)
collab_peer_live :: proc(st:^Collab_State,i:int,now:f64) -> bool {
    peer:=&st.peers[i]
    return i!=int(st.self) && peer.used && peer.has_pose && !peer.playing && now-peer.seen<=COLLAB_PRESENCE_SEEN
}

// True, with a notice and the reason a call of the API that tried fails
// with, when another editor holds one of the entities.
edit_held :: proc(s:^Session,entities:..core.Entity) -> bool {
    for e in entities {
        peer,held:=collab_holder(s,e)
        if !held {continue}
        c:=collab_of(s)
        st:=c.state
        name:=string(st.peers[peer].name[:st.peers[peer].name_length])
        text:=fmt.bprintf(c.held[:],"%s has %s selected: it can be edited once they select something else",name,entity_label(edited_world(s),e))
        c.held_length=len(text)
        notify(s,text)
        return true
    }
    return false
}

// A notice of why an edit did not happen and, for a call of the API that
// tried it, the reason the call fails with.
edit_refusal :: proc(s:^Session,text,reason:string) {
    notify(s,text)
    if c:=collab_of(s);c!=nil {c.held_length=len(fmt.bprintf(c.held[:],"%s",reason))}
}

// Some of the selection is held by another editor: Details reads it and the gizmo is off.
@(private)
selection_held :: proc(s:^Session) -> bool {
    st:=collab_state(s)
    if st==nil || st.phase!=.Joined || s.selection==nil {return false}
    for e in s.selection.entities {
        if _,held:=collab_holder(s,e);held {return true}
    }
    return false
}

// The call of the API whose edits another editor held fails, saying who,
// also when the method failed by itself because its edit did not happen.
@(private)
collab_held_begin :: proc(s:^Session) {
    if c:=collab_of(s);c!=nil {c.held_length=0}
}

@(private)
collab_held_end :: proc(s:^Session,call:^api.Call) {
    c:=collab_of(s)
    if c==nil || c.held_length==0 {return}
    api.call_fail(call,api.INVALID_PARAMS,string(c.held[:c.held_length]))
}

// The selections of the others, outlined in their colors.
@(private)
collab_highlights :: proc(s:^Session,w:core.World_Ref,levels:[]u8) {
    st:=collab_state(s)
    if st==nil || st.phase!=.Joined || w.data!=s.edit_world || s.mode!=.Edit {return}
    es:=core.world_entities(w)
    now:=wire.host_time(&st.host)
    for &peer,i in st.peers {
        if !collab_peer_live(st,i,now) {continue}
        for id in peer.selection[:peer.selection_count] {
            e:=api_entity(w,id)
            if e==core.NONE || !core.alive(es,e) {continue}
            // Their color wins over the selection of this end, which cannot edit it.
            if at:=core.entity_index(e);at<len(levels) && (levels[at]==0 || levels[at]==HIGHLIGHT_SELECTED || levels[at]==HIGHLIGHT_DESCENDANT) {levels[at]=agent_level(i)}
        }
    }
    collab_agents_highlights(s,st,w,levels,now)
}

// What the outlines of the others depend on: who is in and what they select.
@(private)
collab_highlights_key :: proc(s:^Session) -> u64 {
    st:=collab_state(s)
    if st==nil || st.phase!=.Joined {return 0}
    now:=wire.host_time(&st.host)
    key:=u64(1)
    for &peer,i in st.peers {
        if !collab_peer_live(st,i,now) {continue}
        key=base.hash_combine(key,u64(i+1))
        for id in peer.selection[:peer.selection_count] {key=base.hash_combine(key,u64(id))}
    }
    return base.hash_combine(key,collab_agents_key(s,st,now))
}
