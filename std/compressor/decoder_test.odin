package compressor

import "core:mem"
import "core:testing"

// Streams of fixture_input at Normal, Fast (with a period), Optimal5 and SuperFast: the bytes of
// the reference encoder.
@(private="file")
Fixture :: struct {name:string,stream:[]u8,size:int,period:int}

@(private="file")
FIXTURES := [?]Fixture{
    {"lz_normal",#load("testdata/lz_normal.bin"),140*1024,0},
    {"lz_blocks",#load("testdata/lz_blocks.bin"),600*1024,100*1024},
    {"lz_optimal5",#load("testdata/lz_optimal5.bin"),140*1024,0},
    {"lz_small",#load("testdata/lz_small.bin"),700,0},
}

// Words, deltas, runs, repeats, small symbols, ramps and noise. The fixture
// streams were checked against the reference encoder with the same procedure.
@(private="file")
fixture_input :: proc(out:[]u8) {
    WORDS :: [?]string{"press ","lz ","stream ","decode ","mirai ","engine ","block ",
        "chunk ","quantum ","huffman ","offset ","literal ","match ","the ","and ","of "}
    words:=WORDS
    state:=u64(0x9E3779B97F4A7C15)
    next :: proc(s:^u64) -> u64 {s^~=s^<<13;s^~=s^>>7;s^~=s^<<17;return s^}
    i:=0
    for i<len(out) {
        LENS :: [7]int{1500,1500,3000,12000,600,3000,150}
        lens:=LENS
        kind:=int(next(&state)%7)
        if i<1024 && kind==3 {kind=5}
        seg:=min(len(out)-i,lens[kind]+int(next(&state)%500))
        switch kind {
        case 0:
            j:=0
            for j<seg {
                w:=words[next(&state)%len(words)]
                for c in transmute([]u8)w {if j<seg {out[i+j]=c;j+=1}}
            }
        case 1:
            v:=u16(next(&state))
            for j:=0;j+1<seg;j+=2 {
                v+=u16(next(&state)%7)
                out[i+j]=u8(v);out[i+j+1]=u8(v>>8)
            }
            if seg&1==1 {out[i+seg-1]=0}
        case 2:
            for j:=0;j<seg; {
                run:=1+int(next(&state)%300)
                b:=u8(next(&state)%4)
                for k:=0;k<run && j<seg;k+=1 {out[i+j]=b;j+=1}
            }
        case 3:
            if i<1024 {for j in 0..<seg {out[i+j]=u8(j)};break}
            for j:=0;j<seg; {
                l:=min(seg-j,20+int(next(&state)%200))
                from:=int(next(&state)%u64(i-l))
                for k in 0..<l {out[i+j+k]=out[from+k]}
                j+=l
            }
        case 4:
            for j in 0..<seg {
                r:=next(&state)
                out[i+j]=u8(r&15)+u8((r>>8)&3)*u8(r>>20&1)
            }
        case 5:
            for j in 0..<seg {out[i+j]=u8(j/8)}
        case 6:
            for j in 0..<seg {out[i+j]=u8(next(&state))}
        }
        i+=seg
    }
}

@(private="file")
fixture_raw :: proc(f:Fixture) -> []u8 {
    raw:=make([]u8,f.size)
    if f.period==0 {
        fixture_input(raw)
    } else {
        fixture_input(raw[:f.period])
        for i in f.period..<len(raw) {raw[i]=raw[i-f.period]}
    }
    return raw
}

@(private="file") GUARD :: 64

// Decodes into the middle of a buffer of canaries and checks nothing outside
// dst was written.
@(private="file")
guarded_decode :: proc(t:^testing.T,d:^Decoder,src:[]u8,size:int,
    loc:=#caller_location) -> (out:[]u8,written:int,err:Error) {
    buf:=make([]u8,size+2*GUARD)
    for &b in buf {b=0xa5}
    out=buf[GUARD:][:size]
    written,err=decompress(d,src,out)
    ok:=true
    for b in buf[:GUARD] {ok&=b==0xa5}
    for b in buf[GUARD+size:] {ok&=b==0xa5}
    testing.expect(t,ok,"nothing written outside dst",loc=loc)
    return
}

@(private="file")
release :: proc(out:[]u8) {
    p:=([^]u8)(raw_data(out))
    delete(p[-GUARD:][:len(out)+2*GUARD])
}

@(test)
library_streams_decode_to_their_input :: proc(t:^testing.T) {
    d:Decoder
    testing.expect_value(t,decoder_init(&d),Error.None)
    defer decoder_destroy(&d)
    for f in FIXTURES {
        raw:=fixture_raw(f);defer delete(raw)
        out,n,err:=guarded_decode(t,&d,f.stream,f.size);defer release(out)
        testing.expectf(t,err==.None && n==f.size,"%s: %v, %d bytes",f.name,err,n)
        testing.expectf(t,string(out)==string(raw),"%s decodes to its input",f.name)
    }
}

@(test)
decompress_does_not_allocate :: proc(t:^testing.T) {
    d:Decoder
    testing.expect_value(t,decoder_init(&d),Error.None)
    defer decoder_destroy(&d)
    out:=make([]u8,FIXTURES[0].size);defer delete(out)
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,
        context.allocator);defer mem.tracking_allocator_destroy(&tracking)
    {
        context.allocator=mem.tracking_allocator(&tracking)
        context.temp_allocator=mem.tracking_allocator(&tracking)
        for f in FIXTURES[:1] {_,_=decompress(&d,f.stream,out)}
    }
    testing.expect_value(t,tracking.total_allocation_count,0)
}

@(test)
an_uninitialized_decoder_fails :: proc(t:^testing.T) {
    d:Decoder
    out:[16]u8
    _,err:=decompress(&d,FIXTURES[3].stream,out[:])
    testing.expect(t,err!=.None)
    _,err=decompress(nil,FIXTURES[3].stream,out[:])
    testing.expect(t,err!=.None)
}

@(test)
truncated_streams_fail :: proc(t:^testing.T) {
    d:Decoder
    testing.expect_value(t,decoder_init(&d),Error.None)
    defer decoder_destroy(&d)
    for f in FIXTURES {
        step:=max(1,len(f.stream)/3000)
        for n:=0;n<len(f.stream);n+=step {
            out,_,err:=guarded_decode(t,&d,f.stream[:n],f.size)
            release(out)
            testing.expectf(t,err!=.None,"%s cut at %d fails",f.name,n)
        }
    }
}

@(test)
a_wrong_output_size_fails :: proc(t:^testing.T) {
    d:Decoder
    testing.expect_value(t,decoder_init(&d),Error.None)
    defer decoder_destroy(&d)
    for f in FIXTURES {
        for size in ([?]int{f.size-1,f.size-200,f.size/2+3,f.size+1,f.size+5000}) {
            if size<=0 {continue}
            out,_,err:=guarded_decode(t,&d,f.stream,size)
            release(out)
            testing.expectf(t,err!=.None,"%s into %d bytes fails",f.name,size)
        }
    }
}

@(private="file")
next_random :: proc(state:^u64) -> u64 {
    state^+=0x9e3779b97f4a7c15
    z:=state^
    z=(z~(z>>30))*0xbf58476d1ce4e5b9
    z=(z~(z>>27))*0x94d049bb133111eb
    return z~(z>>31)
}

@(private="file") MUTATIONS :: #config(COMPRESSOR_MUTATIONS,1500)

// Mutated streams decode to anything or fail, without reading or writing out
// of bounds (run under the sanitizer for the reads).
@(test)
mutated_streams_never_escape_their_buffers :: proc(t:^testing.T) {
    d:Decoder
    testing.expect_value(t,decoder_init(&d),Error.None)
    defer decoder_destroy(&d)
    state:=u64(7)
    for f in FIXTURES {
        work:=make([]u8,len(f.stream));defer delete(work)
        for _ in 0..<MUTATIONS/len(FIXTURES) {
            copy(work,f.stream)
            for _ in 0..<1+int(next_random(&state)%4) {
                at:=int(next_random(&state)%u64(len(work)))
                switch next_random(&state)%3 {
                case 0: work[at]~=u8(1)<<(next_random(&state)%8)
                case 1: work[at]=u8(next_random(&state))
                case 2: work[at]=u8(int(work[at])+int(next_random(&state)%5)-2)
                }
            }
            out,_,_:=guarded_decode(t,&d,work,f.size)
            release(out)
        }
    }
}

@(test)
random_data_fails :: proc(t:^testing.T) {
    d:Decoder
    testing.expect_value(t,decoder_init(&d),Error.None)
    defer decoder_destroy(&d)
    state:=u64(11)
    buf:=make([]u8,64*1024);defer delete(buf)
    for round in 0..<200 {
        n:=1+int(next_random(&state)%u64(len(buf)))
        for i in 0..<n {buf[i]=u8(next_random(&state))}
        // Valid block headers lead the random payload half of the time.
        if round&1==1 && n>=2 {
            buf[0]=BLOCK_HEADER_VERSION_NIBBLE|BLOCK_HEADER_RESET
            buf[1]=u8(round&2==0 ? DECODE_TYPE_LZ : round%DECODE_TYPE_COUNT)
        }
        out,_,err:=guarded_decode(t,&d,buf[:n],1+int(next_random(&state)%300000))
        release(out)
        testing.expect(t,err!=.None,"random data fails")
    }
}

// A stream of two pieces: a stored block that resets, a whole match of it that does not, and the
// lz_blocks fixture, which resets at its first block.
@(private="file")
pieced_stream :: proc() -> (stream:[]u8,size:int) {
    out:=make([dynamic]u8)
    append(&out,BLOCK_HEADER_VERSION_NIBBLE|BLOCK_HEADER_MEMCPY|BLOCK_HEADER_RESET,DECODE_TYPE_LZ)
    stored:=make([]u8,BLOCK_LEN);defer delete(stored)
    fixture_input(stored)
    append(&out,..stored)
    // QUANTUM_SPECIAL_WHOLE_MATCH at offset 4096: the 15-bit form of offset-1.
    word:=(1<<WHOLE_MATCH_BITS1)+4095
    append(&out,BLOCK_HEADER_VERSION_NIBBLE,DECODE_TYPE_LZ,0x03,0xFF,0xFF,u8(word>>8),u8(word))
    append(&out,..FIXTURES[1].stream)
    return out[:],2*BLOCK_LEN+FIXTURES[1].size
}

// Decodes each piece on its own into its part of out; false when one fails.
@(private="file")
pieces_decode :: proc(t:^testing.T,d:^Decoder,src:[]u8,out:[]u8,found:[]Piece) -> bool {
    for piece,i in found {
        src_end,dst_end:=len(src),len(out)
        if i+1<len(found) {src_end,dst_end=found[i+1].src,found[i+1].dst}
        testing.expect(t,piece.src<src_end && piece.dst<dst_end && src_end<=len(src))
        part,written,err:=guarded_decode(t,d,src[piece.src:src_end],dst_end-piece.dst)
        defer release(part)
        if err!=.None || written!=len(part) {return false}
        copy(out[piece.dst:],part)
    }
    return true
}

// Each piece decodes on its own to what the whole stream decodes to, also when the stream is
// mutated: the whole fails exactly when a piece does.
@(test)
pieces_decode_on_their_own_to_the_whole_stream :: proc(t:^testing.T) {
    d:Decoder
    testing.expect_value(t,decoder_init(&d),Error.None)
    defer decoder_destroy(&d)
    stream,size:=pieced_stream();defer delete(stream)
    found:[8]Piece
    count,err:=pieces(stream,size,found[:])
    testing.expect_value(t,err,Error.None)
    testing.expect_value(t,count,2)
    testing.expect(t,found[0]=={0,0} && found[1]=={BLOCK_HEADER_SIZE+BLOCK_LEN+7,2*BLOCK_LEN})
    one:[1]Piece
    count,err=pieces(stream,size,one[:])
    testing.expect(t,count==2 && err==.None && one[0]=={0,0},"count goes past what out holds")
    whole,_,whole_err:=guarded_decode(t,&d,stream,size);defer release(whole)
    testing.expect_value(t,whole_err,Error.None)
    raw:=fixture_raw(FIXTURES[1]);defer delete(raw)
    testing.expect(t,string(whole[2*BLOCK_LEN:])==string(raw))
    testing.expect(t,string(whole[BLOCK_LEN:2*BLOCK_LEN])==string(whole[BLOCK_LEN-4096:2*BLOCK_LEN-4096]))
    apart:=make([]u8,size);defer delete(apart)
    testing.expect(t,pieces_decode(t,&d,stream,apart,found[:count]))
    testing.expect(t,string(apart)==string(whole))
    // A whole match that reaches back past the reset of its piece is corrupt, whole or apart.
    reaching:=make([]u8,len(stream));defer delete(reaching)
    copy(reaching,stream)
    reaching[BLOCK_HEADER_SIZE+BLOCK_LEN]|=BLOCK_HEADER_RESET
    count,err=pieces(reaching,size,found[:])
    testing.expect(t,count==3 && err==.None)
    reached,_,reached_err:=guarded_decode(t,&d,reaching,size);release(reached)
    testing.expect_value(t,reached_err,Error.Corrupt)
    testing.expect(t,!pieces_decode(t,&d,reaching,apart,found[:count]))
    // A stream whose first block does not reset has no pieces.
    reaching[0]&=~u8(BLOCK_HEADER_RESET)
    _,err=pieces(reaching,size,found[:])
    testing.expect_value(t,err,Error.Corrupt)
    work:=make([]u8,len(stream));defer delete(work)
    state:=u64(13)
    for round in 0..<MUTATIONS/4 {
        copy(work,stream)
        // Mostly the headers of the blocks after the first.
        for _ in 0..<1+int(next_random(&state)%3) {
            at:=round%2==0 ? 2+BLOCK_LEN+int(next_random(&state)%40) : int(next_random(&state)%u64(len(work)))
            work[at]~=u8(1)<<(next_random(&state)%8)
        }
        out,written,whole_error:=guarded_decode(t,&d,work,size)
        defer release(out)
        n,scan_error:=pieces(work,size,found[:])
        if whole_error==.None {
            testing.expect(t,written==size && scan_error==.None && n>=1 && n<=len(found))
        }
        if scan_error!=.None || n<1 || n>len(found) {continue}
        ok:=pieces_decode(t,&d,work,apart,found[:n])
        testing.expectf(t,ok==(whole_error==.None),"round %d: pieces %v, whole %v",round,ok,whole_error)
        if ok && whole_error==.None {testing.expect(t,string(apart)==string(out))}
    }
}
