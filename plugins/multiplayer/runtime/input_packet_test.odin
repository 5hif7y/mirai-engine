package multiplayer

import "core:testing"
import wire "mirai:net"
import "mirai:std/serial"

// The actions a client sends fit an input of the protocol, every axis slot
// and mask included.
@(test)
input_packet_fits_the_input_of_the_protocol :: proc(t:^testing.T) {
    schema:serial.Schema
    serial.schema_init(&schema)
    defer serial.schema_destroy(&schema)
    protocol:wire.Protocol
    wire.protocol_init(&protocol)
    defer wire.protocol_destroy(&protocol)
    type,added:=serial.schema_add(&schema,Input_Packet)
    testing.expect(t,added)
    if !added {return}
    testing.expect(t,wire.input_register(&protocol,&schema,type))
}

// The server takes the view a client says it saw unless it is farther than
// the tolerance from the one its latency gives.
@(test)
a_claimed_view_far_from_the_latency_takes_the_expected_one :: proc(t:^testing.T) {
    h:wire.Host
    h.desc.tick_rate=128
    h.desc.replication.input_lead=5
    h.desc.replication.interpolation_delay=2.5
    expected:=expected_behind(&h,{rtt=0.15,jitter=0.003})
    tolerance:=0.2*128.0
    behind,corrected:=view_checked(expected+3,expected,tolerance)
    testing.expect(t,behind==expected+3 && !corrected)
    behind,corrected=view_checked(expected+tolerance+1,expected,tolerance)
    testing.expect(t,behind==expected && corrected)
    behind,corrected=view_checked(0,expected,tolerance)
    testing.expect(t,behind==expected && corrected)
}
