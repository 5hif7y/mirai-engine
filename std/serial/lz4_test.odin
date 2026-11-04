package serial

import "core:fmt"
import "core:mem"
import "core:testing"
import "core:time"

@(private="file")
SERIAL_BENCH :: #config(SERIAL_BENCH,false)

@(private="file")
round_trip :: proc(t:^testing.T,input:[]u8,loc:=#caller_location) -> int {
    packed:=make([]u8,lz4_bound(len(input)));defer delete(packed)
    size,ok:=lz4_compress(input,packed)
    testing.expect(t,ok,"compression fits its bound",loc=loc)
    // Canaries on both sides catch a decoder that writes outside its output.
    guarded:=make([]u8,len(input)+64);defer delete(guarded)
    for &b in guarded {b=0xa5}
    out:=guarded[32:][:len(input)]
    count,decoded:=lz4_decompress(packed[:size],out)
    testing.expect(t,decoded && count==len(input),"decompression returns the input size",loc=loc)
    testing.expect(t,mem.compare(out,input)==0,"decompression returns the input",loc=loc)
    for b in guarded[:32] {testing.expect(t,b==0xa5,"nothing written before the output",loc=loc)}
    for b in guarded[32+len(input):] {testing.expect(t,b==0xa5,"nothing written after the output",loc=loc)}
    testing.expect(t,end_rules_hold(packed[:size]),"the block keeps the end rules of the reference decoder",loc=loc)
    return size
}

// The rules a lenient decoder ignores and the reference one (Tracy's server
// among its users) enforces: the block ends with literals only, the last five
// bytes are literals and no match starts within the last twelve.
@(private="file")
end_rules_hold :: proc(block:[]u8) -> bool {
    length :: proc(block:[]u8,ip:^int,nibble:int) -> int {
        total:=nibble
        if nibble==15 {
            for ip^<len(block) {
                extra:=block[ip^];ip^+=1;total+=int(extra)
                if extra!=255 {break}
            }
        }
        return total
    }
    ip,op:=0,0
    last_start,last_end:=-1,-1
    for ip<len(block) {
        token:=block[ip];ip+=1
        literals:=length(block,&ip,int(token>>4))
        ip+=literals;op+=literals
        if ip>=len(block) {
            if token&0xf!=0 {return false}
            break
        }
        ip+=2
        match:=length(block,&ip,int(token&0xf))+4
        last_start=op;op+=match;last_end=op
    }
    return last_start<0 || (last_start<=op-12 && last_end<=op-5)
}

@(private="file")
sample_text :: proc(size:int,seed:u64,allocator:=context.allocator) -> []u8 {
    words:=[?]string{"position","rotation","scale","entity","mesh","material","0.25","1.0","{","}","\n","  ",":",","}
    out:=make([dynamic]u8,0,size,allocator)
    state:=seed
    for len(out)<size {append(&out,words[fuzz_next(&state)%len(words)])}
    resize(&out,size)
    return out[:]
}

@(test)
lz4_round_trips_inputs_of_every_shape :: proc(t:^testing.T) {
    round_trip(t,nil)
    state:=u64(0x1234)
    for size in 1..=80 {
        input:=make([]u8,size);defer delete(input)
        for &b in input {b=u8(fuzz_next(&state)%3)}
        round_trip(t,input)
    }
    zeros:=make([]u8,100000);defer delete(zeros)
    testing.expect(t,round_trip(t,zeros)<500)

    noise:=make([]u8,70000);defer delete(noise)
    for &b in noise {b=u8(fuzz_next(&state))}
    testing.expect(t,round_trip(t,noise)<=lz4_bound(len(noise)))

    text:=sample_text(200000,7);defer delete(text)
    testing.expect(t,round_trip(t,text)<len(text)/2)

    // Matches at every distance up to past the 64 KB window, short and overlapping.
    distances:=[?]int{1,2,3,4,7,8,15,16,17,31,255,256,4095,65535,65536,70000}
    for distance in distances {
        input:=make([]u8,distance*2+300);defer delete(input)
        for &b,i in input {b=i<distance?u8(fuzz_next(&state)):input[i-distance]}
        round_trip(t,input)
    }
    // Literal and match lengths around the 15 and 255 extension steps.
    for run in ([]int{14,15,16,18,19,20,254,255,256,269,270,271,272,273,274,524,525,526,527,528,529,530}) {
        input:=make([]u8,run*2+64);defer delete(input)
        for &b,i in input {b=i<run?u8(fuzz_next(&state)):(i<run*2?7:u8(fuzz_next(&state)))}
        round_trip(t,input)
    }
}

@(test)
lz4_decodes_a_block_laid_out_by_hand_from_the_format :: proc(t:^testing.T) {
    // 3 literals, a match of 21 at offset 3 (length nibble 15 plus 2), then 12 literals.
    block:=[?]u8{0x3f,'a','b','c',0x03,0x00,0x02,0xc0,'0','1','2','3','4','5','6','7','8','9','!','?'}
    out:[36]u8
    size,ok:=lz4_decompress(block[:],out[:])
    testing.expect(t,ok)
    testing.expect_value(t,size,36)
    testing.expect_value(t,string(out[:]),"abcabcabcabcabcabcabcabc0123456789!?")
}

@(test)
lz4_compression_fails_cleanly_when_the_output_is_too_small :: proc(t:^testing.T) {
    text:=sample_text(5000,3);defer delete(text)
    packed:=make([]u8,lz4_bound(len(text)));defer delete(packed)
    full,ok:=lz4_compress(text,packed)
    testing.expect(t,ok)
    for capacity in ([]int{0,1,16,full/2,full-1}) {
        guarded:=make([]u8,capacity+16);defer delete(guarded)
        for &b in guarded {b=0x5a}
        _,fits:=lz4_compress(text,guarded[:capacity])
        testing.expect(t,!fits)
        for b in guarded[capacity:] {testing.expect(t,b==0x5a)}
    }
    exact:=make([]u8,full);defer delete(exact)
    size,exact_ok:=lz4_compress(text,exact)
    testing.expect(t,exact_ok && size==full)
}

@(test)
lz4_decoder_rejects_malformed_blocks :: proc(t:^testing.T) {
    out:[64]u8
    cases:=[?][]u8{
        {},                             // no token
        {0x10},                         // a literal that is not there
        {0xf0},                         // a literal length that is not there
        {0xf0,0xff,0xff,0xff,0xff},     // a literal length that never ends
        {0x10,'a',0x01},                // half an offset
        {0x10,'a',0x00,0x00},           // offset zero
        {0x10,'a',0x02,0x00},           // offset before the output
        {0x1f,'a',0x01,0x00},           // a match length that is not there
        {0x1f,'a',0x01,0x00,0xff,0xff}, // a match longer than the output
        {0x10,'a',0x01,0x00},           // ends on a match
    }
    for block in cases {
        _,ok:=lz4_decompress(block,out[:])
        testing.expect(t,!ok,fmt.tprintf("%v",block))
    }
    text:=sample_text(600,11);defer delete(text)
    packed:=make([]u8,lz4_bound(len(text)));defer delete(packed)
    size,_:=lz4_compress(text,packed)
    small:=make([]u8,len(text)-1);defer delete(small)
    _,fits:=lz4_decompress(packed[:size],small)
    testing.expect(t,!fits)
    for cut in 0..<size {
        whole:=make([]u8,len(text));defer delete(whole)
        count,ok:=lz4_decompress(packed[:cut],whole)
        testing.expect(t,!ok || count<len(text))
    }
}

@(test)
lz4_decoder_survives_random_and_mutated_blocks :: proc(t:^testing.T) {
    state:=u64(0xfeed)
    text:=sample_text(4000,5);defer delete(text)
    packed:=make([]u8,lz4_bound(len(text)));defer delete(packed)
    size,_:=lz4_compress(text,packed)
    guarded:=make([]u8,len(text)+64);defer delete(guarded)
    block:=make([]u8,size+32);defer delete(block)
    for round in 0..<20000 {
        length:=size
        copy(block,packed[:size])
        switch round%4 {
        case 0: // flipped bytes
            for _ in 0..<1+fuzz_next(&state)%4 {block[fuzz_next(&state)%u64(size)]=u8(fuzz_next(&state))}
        case 1: // truncated
            length=int(fuzz_next(&state)%u64(size))
        case 2: // noise
            length=int(fuzz_next(&state)%64)
            for &b in block[:length] {b=u8(fuzz_next(&state))}
        case 3: // long lengths
            at:=int(fuzz_next(&state)%u64(size-8))
            block[at]=0xff
            for &b in block[at+1:][:6] {b=0xff}
        }
        capacity:=int(fuzz_next(&state)%u64(len(text)+1))
        for &b in guarded {b=0xa5}
        out:=guarded[32:][:capacity]
        count,_:=lz4_decompress(block[:length],out)
        testing.expect(t,count<=capacity)
        intact:=true
        for b in guarded[:32] {intact&&=b==0xa5}
        for b in guarded[32+capacity:] {intact&&=b==0xa5}
        if !testing.expect(t,intact,"the decoder wrote outside its output") {return}
    }
}

@(test)
lz4_benchmark :: proc(t:^testing.T) {
    when !SERIAL_BENCH {return}
    else {
        Sample :: struct {name:string,data:[]u8}
        state:=u64(99)
        size:=16<<20
        text:=sample_text(size,1);defer delete(text)
        floats:=make([]u8,size);defer delete(floats)
        values:=mem.slice_data_cast([]f32,floats)
        for &value,i in values {value=f32(i%1024)*0.125+f32(fuzz_next(&state)%16)}
        records:=make([]u8,size);defer delete(records)
        for i:=0;i+88<=size;i+=88 {
            (^u64)(&records[i])^=fuzz_next(&state)
            (^u64)(&records[i+8])^=u64(i/88/7)
            (^u32)(&records[i+16])^=u32(i/88)
            name:=fmt.bprintf(records[i+24:][:64],"Entity_%d",i/88)
            _=name
        }
        noise:=make([]u8,size);defer delete(noise)
        for &b in noise {b=u8(fuzz_next(&state))}
        samples:=[?]Sample{{"text",text},{"f32 columns",floats},{"entity records",records},{"noise",noise}}
        packed:=make([]u8,lz4_bound(size));defer delete(packed)
        out:=make([]u8,size);defer delete(out)
        for sample in samples {
            best_c,best_d:=max(f64),max(f64)
            packed_size:=0
            for _ in 0..<5 {
                start:=time.tick_now()
                packed_size,_=lz4_compress(sample.data,packed)
                best_c=min(best_c,time.duration_seconds(time.tick_since(start)))
                start=time.tick_now()
                count,ok:=lz4_decompress(packed[:packed_size],out)
                best_d=min(best_d,time.duration_seconds(time.tick_since(start)))
                testing.expect(t,ok && count==size)
            }
            megabytes:=f64(size)/(1<<20)
            fmt.printfln("lz4 %-15s ratio %.3f  compress %.0f MB/s  decompress %.0f MB/s",sample.name,f64(size)/f64(packed_size),megabytes/best_c,megabytes/best_d)
        }
    }
}
