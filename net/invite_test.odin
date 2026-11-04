package mirai_net

import "core:log"
import "core:strings"
import "core:testing"

@(test)
invitation_codes_round_trip_and_refuse_typos :: proc(t:^testing.T) {
    address:=address_ip4(203,0,113,7,27500)
    code:=invite_encode(address,0xa1b2c3,context.temp_allocator)
    testing.expect_value(t,len(code),16+3)
    got,token,ok:=invite_decode(code)
    testing.expect(t,ok && got==address && token==0xa1b2c3)
    // Lowercase, spaces and the letters that look like digits are the same code.
    loose,_:=strings.replace_all(strings.to_lower(code,context.temp_allocator),"-"," ",context.temp_allocator)
    loose,_=strings.replace_all(loose,"0","o",context.temp_allocator)
    got,token,ok=invite_decode(loose)
    testing.expect(t,ok && got==address && token==0xa1b2c3)
    // A character changed or left out is no code.
    for i in 0..<len(code) {
        if code[i]=='-' {continue}
        changed:=transmute([]u8)strings.clone(code,context.temp_allocator)
        changed[i]=changed[i]=='Z'?'Y':'Z'
        _,_,wrong:=invite_decode(string(changed))
        testing.expect(t,!wrong)
    }
    _,_,short:=invite_decode(code[:len(code)-1])
    testing.expect(t,!short)
    _,_,empty:=invite_decode("")
    testing.expect(t,!empty)
    testing.expect_value(t,invite_encode(address,0,context.temp_allocator),"")
    testing.expect_value(t,invite_encode(address,1<<INVITE_TOKEN_BITS,context.temp_allocator),"")

    wide:=Address{kind=.IP6,port=7950,ip={0=0x20,1=0x01,2=0x0d,3=0xb8,15=1}}
    long:=invite_encode(wide,7,context.temp_allocator)
    testing.expect_value(t,len(long),36+8)
    got,token,ok=invite_decode(long)
    testing.expect(t,ok && got==wide && token==7)
    for _ in 0..<64 {
        token:=invite_token()
        testing.expect(t,token!=0 && token<1<<INVITE_TOKEN_BITS)
    }
}

@(test)
a_server_with_an_invitation_lets_in_only_who_brings_it :: proc(t:^testing.T) {
    w:Test_World;test_world_init(&w,4);defer test_world_destroy(&w)
    server:=test_host(&w,{mode=.Server,invite=0x123456})
    none:=test_host(&w,{mode=.Client})
    other:=test_host(&w,{mode=.Client,invite=0x654321})
    invited:=test_host(&w,{mode=.Client,invite=0x123456})
    for client in ([2]^Host{none,other}) {
        host_connect(client,address_memory(0))
        denied:=false
        for _ in 0..<120 {
            test_step(&w)
            for command in host_poll(client) {
                denied=command.kind==.Disconnected && command.reason==.Denied_Invite
            }
            if denied {break}
        }
        testing.expect(t,denied)
    }
    on_server,on_client:=test_connect(&w,server,invited)
    testing.expect(t,on_server!=0 && on_client!=0)
}

// The address of this machine on its network is the one of its route to the
// internet, which a test machine with a network has; never a link-local one.
@(test)
the_address_on_the_network_is_the_routed_one :: proc(t:^testing.T) {
    lan:=address_lan(27500)
    testing.expect_value(t,lan.kind,Address_Kind.IP4)
    testing.expect_value(t,lan.port,u16(27500))
    testing.expect(t,!(lan.ip[0]==169 && lan.ip[1]==254))
    routed:=portmap_gateway()
    testing.expect(t,routed.kind==.None || lan.ip[0]!=127,"with a gateway there is an address on the network")
    log.infof("address on the network: %d.%d.%d.%d, gateway %v",lan.ip[0],lan.ip[1],lan.ip[2],lan.ip[3],routed.ip[:4])
}
