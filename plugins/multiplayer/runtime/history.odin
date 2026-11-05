package multiplayer

import "core:mem"
import "mirai:core"
import input "mirai:engine/input"
import wire "mirai:net"

@(private)
Authoritative :: struct {
    object:Object,
    tick:u32,
    mask,available:u64,
    checked:bool,
}

@(private)
authority_at :: proc(s:^Net_Session,r:^Replica,index:int) -> (^Authoritative,[]u32) {
    at:=int(r.slot)*s.client.history+index
    return &s.client.authoritative[at],s.client.authoritative_words[at*s.client.words_per:][:s.client.words_per]
}

@(private)
authoritative_capture :: proc(s:^Net_Session,r:^Replica,command:^wire.Command) {
    if r.mode!=.Predicted || r.slot<0 {return}
    for index in 0..<r.authority_count {
        record,words:=authority_at(s,r,index)
        if record.object==r.object && record.tick==command.tick {
            record.mask|=command.mask
            record.available=r.available
            record.checked=false
            copy(words,command.words)
            return
        }
    }
    record,words:=authority_at(s,r,r.authority_next)
    record^={object=r.object,tick=command.tick,mask=command.mask,available=r.available}
    copy(words,command.words)
    r.authority_next=(r.authority_next+1)%s.client.history
    r.authority_count=min(r.authority_count+1,s.client.history)
}

@(private)
authoritative_command :: proc(s:^Net_Session,r:^Replica,tick:u32,exact:bool) -> (command:wire.Command,found:bool) {
    if r.slot<0 {return}
    distance:=max(u32)
    for index in 0..<r.authority_count {
        record,words:=authority_at(s,r,index)
        if record.object!=r.object || i32(tick-record.tick)<0 || exact && record.tick!=tick {continue}
        behind:=u32(tick-record.tick)
        if found && behind>=distance {continue}
        distance=behind
        command={kind=.Object_Updated,object=r.object,type=r.type,tick=record.tick,mask=record.available,words=words}
        found=true
    }
    return
}

@(private)
components_mask :: proc(s:^Net_Session,t:^Net_Type) -> (mask:u64) {
    for k in 0..<t.count {mask|=wire.type_fragment_mask(&s.protocol,t.type,t.first+k)}
    return
}

@(private)
record_components :: proc(s:^Net_Session,w:core.World_Ref,r:^Replica,tick:u32) {
    at:=(int(tick)%s.client.history)*s.desc.predicted_capacity+int(r.slot)
    words:=s.client.record_words[at*s.client.words_per:][:s.client.words_per]
    record:=&s.client.records[at]
    record.bindings=wire.object_binding_revision(&s.host)
    previous:=record_of(&s.client,&s.desc,r,tick-1) or_else nil
    if previous!=nil {
        old:=(int(tick-1)%s.client.history)*s.desc.predicted_capacity+int(r.slot)
        copy(words,s.client.record_words[old*s.client.words_per:][:s.client.words_per])
    } else {mem.zero_slice(words)}
    t:=net_type(s,r.type)
    for k in 0..<t.count {
        info:=&w.info.tables[t.tables[k]]
        table:=core.world_table_at(w,info)
        fragment:=t.first+k
        record.stamps[fragment],record.layouts[fragment]=row_stamp(table,r.entity),table.layout
        if previous!=nil && previous.stamps[fragment]==record.stamps[fragment] && previous.layouts[fragment]==record.layouts[fragment] && (t.references&(1<<wire.Fragment_Mask(fragment))==0 || previous.bindings==record.bindings) {continue}
        source:=core.raw_find(table,info.info,r.entity)
        if source!=nil {wire.object_pack(&s.host,t.type,fragment,source,words)}
        else {
            for leaf in s.protocol.types[t.type].leaves {
                if int(leaf.fragment)==fragment {mem.zero_slice(words[leaf.word:][:leaf.words])}
            }
        }
    }
}

@(private)
record_components_differ :: proc(s:^Net_Session,r:^Replica,tick:u32,command:^wire.Command) -> bool {
    t:=net_type(s,r.type)
    mask:=components_mask(s,t)&command.mask
    if mask==0 {return false}
    at:=(int(tick)%s.client.history)*s.desc.predicted_capacity+int(r.slot)
    words:=s.client.record_words[at*s.client.words_per:][:s.client.words_per]
    for leaf in s.protocol.types[t.type].leaves {
        if mask&u64(1<<uint(leaf.bit))==0 {continue}
        for index in int(leaf.word)..<int(leaf.word)+int(leaf.words) {
            if words[index]!=command.words[index] {return true}
        }
    }
    return false
}

@(private)
authoritative_apply :: proc(s:^Net_Session,w:core.World_Ref,tick:u32,baseline:bool) {
    es:=core.world_entities(w)
    for &r in s.client.replicas[:s.client.replica_high] {
        if r.object==0 || !core.alive(es,r.entity) || r.mode!=.Predicted {continue}
        command,found:=authoritative_command(s,&r,tick,!baseline)
        if !found {continue}
        t:=net_type(s,r.type)
        components_apply(s,w,r.entity,t,&command,command.mask)
        if command.tick==tick || baseline && replica_known(&s.client,&r,tick) {
            pose:Pose
            motion:Motion_State
            wire.object_read(&s.host,&command,0,&pose,max(u64))
            if t.motion>=0 {wire.object_read(&s.host,&command,t.motion,&motion,max(u64))}
            pose_apply(s,w,r.entity,t,pose,motion,false)
            if command.tick==r.tick {r.exact=true}
        }
    }
    core.world_settle(w)
}

@(private)
references_refresh :: proc(s:^Net_Session,w:core.World_Ref) {
    revision:=wire.object_binding_revision(&s.host)
    if revision==s.client.bindings {return}
    s.client.bindings=revision
    es:=core.world_entities(w)
    for &r in s.client.replicas[:s.client.replica_high] {
        if r.object==0 || !core.alive(es,r.entity) {continue}
        t:=net_type(s,r.type)
        if t.references==0 {continue}
        command:=replica_command(s,&r)
        mask:u64
        for fragment in 0..<wire.MAX_FRAGMENTS {
            if t.references&(1<<wire.Fragment_Mask(fragment))!=0 {mask|=wire.type_fragment_mask(&s.protocol,t.type,fragment)}
        }
        pending:=wire.object_references_pending(&s.host,&command)
        if pending!=0 {s.stats.references_deferred+=1}
        if r.references&~pending!=0 {s.stats.references_resolved+=1}
        r.references=pending
        components_apply(s,w,r.entity,t,&command,mask&r.available)
    }
    core.world_settle(w)
}

@(private)
client_inputs :: proc(s:^Net_Session,w:core.World_Ref,tick:u32) {
    moves:=core.world_table_of(w,input.Move_Input)
    es:=core.world_entities(w)
    for &r in s.client.replicas[:s.client.replica_high] {
        if r.object==0 || r.role==.Predicted || r.role==.Held || !core.alive(es,r.entity) {continue}
        t:=net_type(s,r.type)
        if t.driver<0 {continue}
        command:=replica_command(s,&r)
        if historic,found:=authoritative_command(s,&r,tick,false);found {command=historic}
        driver:Driver_State
        if !wire.object_read(&s.host,&command,t.driver,&driver,max(u64)) {continue}
        if s.client.sync_fed!=nil {
            feed(&s.client,r.object);feed(&s.client,command.tick==tick)
            for leaf in s.protocol.types[t.type].leaves {
                if int(leaf.fragment)==t.driver {feed_bytes(&s.client,mem.slice_to_bytes(command.words[leaf.word:][:leaf.words]))}
            }
        }
        if moves!=nil && driver.has_move {
            old,has:=core.get(core.read(moves),r.entity)
            if !has || old!=driver.move {core.add(moves,r.entity,driver.move)}
        }
    }
    core.world_settle(w)
}
