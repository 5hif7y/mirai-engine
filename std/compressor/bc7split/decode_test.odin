package bc7split

import "core:math/rand"
import "core:mem"
import "core:testing"

// The last levels of a demo texture, encoded and decoded by the reference library: header then payload,
// and the blocks the library restores.
@(private="file") FIXTURE_STREAM :: #load("testdata/vase_tail.bc7split")
@(private="file") FIXTURE_BLOCKS :: #load("testdata/vase_tail.decoded.bc7")

@(private="file")
fixture :: proc() -> (header:Header,payload:[]u8) {
    stream:=FIXTURE_STREAM
    header=(^Header)(raw_data(stream))^
    return header,stream[size_of(Header):]
}

@(test)
decode_restores_the_library_blocks :: proc(t:^testing.T) {
    header,payload:=fixture()
    d:=new(Decoder);defer free(d)
    dst:=make([]u8,len(FIXTURE_BLOCKS));defer delete(dst)
    for cached in ([2]bool{false,true}) {
        written,err:=decode(d,header,payload,dst,cached)
        testing.expect_value(t,err,Error.None)
        testing.expect_value(t,written,len(FIXTURE_BLOCKS))
        testing.expect(t,string(dst)==string(FIXTURE_BLOCKS))
    }
    when ODIN_ARCH==.amd64 {
        // The path without AVX2 restores the same blocks on a machine that has it.
        blocks,_,_:=header_read(header)
        for &b in dst {b=0}
        err:=decode_base(d,header,raw_data(payload),raw_data(dst),blocks,false)
        testing.expect_value(t,err,Error.None)
        testing.expect(t,string(dst)==string(FIXTURE_BLOCKS))
    }
}

// Mode 8 (raw blocks) and both color spaces of mode 9, which the fixture does not use.
@(test)
decode_raw_and_solid_blocks :: proc(t:^testing.T) {
    raw:=[16]u8{0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15}
    payload:=make([]u8,16+4*3+2);defer delete(payload)
    copy(payload,raw[:])
    solid:=payload[16:]
    solid[0],solid[1],solid[2],solid[3]=10,20,30,40
    solid[4],solid[5],solid[6],solid[7]=10,20,30,40
    solid[8],solid[9],solid[10],solid[11]=200,100,0,255
    payload[28],payload[29]=0x98,0x99 // modes 8 9 9 9
    header:=Header{version=HEADER_VERSION}
    header.mode_counts[8],header.mode_counts[9]=1,3
    d:=new(Decoder);defer free(d)
    dst:[4*16]u8
    _,err:=decode(d,header,payload,dst[:])
    testing.expect_value(t,err,Error.None)
    testing.expect(t,string(dst[:16])==string(raw[:]))
    testing.expect(t,string(dst[16:32])==string(dst[32:48]))
    // Mode 5, rotation 0, the color in endpoint 0 and all indices 0.
    testing.expect_value(t,dst[16],0x20)
    HIGH :: [8]u8{0xac,0xaa,0xaa,0xaa,0,0,0,0}
    testing.expect(t,(^[8]u8)(&dst[24])^==HIGH)
    // (G, R-G, B-G) of the same colors gives the same blocks.
    plain:=dst
    header.flags=FLAG_SWITCH_COLORSPACE
    for i in 0..<3 {
        c:=solid[i*4:]
        c[0],c[1],c[2]=c[1],c[0]-c[1],c[2]-c[1]
    }
    _,err=decode(d,header,payload,dst[:])
    testing.expect_value(t,err,Error.None)
    testing.expect(t,dst==plain)
}

@(test)
decode_rejects_hostile_input :: proc(t:^testing.T) {
    header,payload:=fixture()
    blocks,payload_size,_:=header_read(header)
    d:=new(Decoder);defer free(d)
    dst:=make([]u8,blocks*16);defer delete(dst)
    Case :: struct {name:string,header:Header,payload_size,dst_size:int,want:Error}
    wrong_version,unknown_flag,too_many,short_count:=header,header,header,header
    wrong_version.version+=1
    unknown_flag.flags|=1<<20
    too_many.mode_counts[0]=MAX_BLOCKS
    short_count.mode_counts[6]-=1
    cases:=[?]Case{
        {"wrong version",wrong_version,payload_size,len(dst),.Header_Corrupt},
        {"unknown flag",unknown_flag,payload_size,len(dst),.Header_Corrupt},
        {"more than MAX_BLOCKS",too_many,payload_size,len(dst),.Header_Corrupt},
        {"truncated payload",header,payload_size-1,len(dst),.Input_Too_Small},
        {"empty payload",header,0,len(dst),.Input_Too_Small},
        {"short output",header,payload_size,len(dst)-1,.Output_Too_Small},
        // One block less in mode 6: the nibbles ask for more mode 6 blocks than it has.
        {"count below the nibbles",short_count,payload_size,len(dst),.Payload_Corrupt},
    }
    for c in cases {
        written,err:=decode(d,c.header,payload[:c.payload_size],dst[:c.dst_size])
        testing.expectf(t,err==c.want && written==0,"%s: %v, %d bytes",c.name,err,written)
    }
    _,err:=decode(nil,header,payload,dst)
    testing.expect_value(t,err,Error.Missing_Decoder)

    // A mode nibble above 9, in the vector part and in the tail of the chunk.
    mutated:=make([]u8,len(payload));defer delete(mutated)
    nibbles:=payload_size-(blocks+1)/2
    for at in ([2]int{nibbles,payload_size-1}) {
        copy(mutated,payload)
        mutated[at]=mutated[at]&0xf0|0xa
        _,err=decode(d,header,mutated,dst)
        testing.expect_value(t,err,Error.Payload_Corrupt)
    }

    // Random mutations of the payload and of the counts never read or write outside the slices;
    // dst gets a guard that must stay untouched.
    guard:=make([]u8,(blocks+MODE_COUNT*64)*16+64);defer delete(guard)
    state:=rand.create(7)
    gen:=rand.default_random_generator(&state)
    for _ in 0..<400 {
        copy(mutated,payload)
        h:=header
        for _ in 0..<1+rand.int_max(8,gen) {
            mutated[rand.int_max(len(mutated),gen)]=u8(rand.uint32(gen))
        }
        if rand.int_max(2,gen)==0 {
            m:=rand.int_max(MODE_COUNT,gen)
            h.mode_counts[m]=u32(rand.int_max(int(h.mode_counts[m])+64,gen))
            h.flags=rand.uint32(gen)&FLAGS_ASSIGNED
        }
        n,_,herr:=header_read(h)
        if herr!=.None {continue}
        for &b in guard {b=0xcd}
        written,_:=decode(d,h,mutated,guard[:n*16])
        testing.expect(t,written==0 || written==n*16)
        for b in guard[n*16:] {if b!=0xcd {testing.fail_now(t,"decode wrote past dst")}}
    }
}

@(test)
decode_does_not_allocate :: proc(t:^testing.T) {
    header,payload:=fixture()
    d:=new(Decoder);defer free(d)
    dst:=make([]u8,len(FIXTURE_BLOCKS));defer delete(dst)
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,context.allocator)
    defer mem.tracking_allocator_destroy(&tracking)
    {
        context.allocator=mem.tracking_allocator(&tracking)
        context.temp_allocator=mem.tracking_allocator(&tracking)
        _,err:=decode(d,header,payload,dst)
        testing.expect_value(t,err,Error.None)
    }
    testing.expect_value(t,tracking.total_allocation_count,0)
}
