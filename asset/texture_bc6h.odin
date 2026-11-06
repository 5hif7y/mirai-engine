package asset

// BC6H without sign (BC6H_UF16): 4x4 texels of rgb half floats in 16 bytes,
// in one of 14 modes (D3D11 functional specification, 19.5.8). A mode has one
// subset or two (those of the first 32 partitions of BC7), endpoints of 6 to
// 16 bits, and the endpoints after the first may be deltas from it. Every
// mode keeps most endpoint bits where mode 11 keeps its six fields of 10
// bits; the rest of them are moved into place from there. An index
// interpolates in the 16-bit range the endpoints unquantize to, and that
// value times 31/64 is the bits of its half float. A reserved mode decodes to
// black.

@(private="file")
Bc6h_Mode :: struct {
    subsets:u32,
    endpoint_bits:u32,
    delta_bits:u32,  // 0: the endpoints are not deltas from the first
    wide_delta:int,  // the channel whose deltas have one more bit; 3: none
    index_bits:u32,
}

// By the value of the mode bits, 2 for the first two and 5 for the others,
// in the order of the specification: modes 1 to 10, then 11 to 14.
@(rodata)
@(private="file")
BC6H_MODES := [14]Bc6h_Mode{
    {2,10,5,3,3},{2,7,6,3,3},{2,11,4,0,3},{2,11,4,1,3},{2,11,4,2,3},
    {2,9,5,3,3},{2,8,5,0,3},{2,8,5,1,3},{2,8,5,2,3},{2,6,0,3,3},
    {1,10,0,3,4},{1,11,9,3,4},{1,12,8,3,4},{1,16,4,3,4},
}

// The half floats of a block, in rows from the top.
texture_bc6h_block_decode :: proc "contextless" (block:[16]u8) -> (texels:[16][3]u16) {
    bits:=transmute(u128)block
    at:uint
    read :: proc "contextless" (bits:u128,at:^uint,count:uint) -> i32 {
        value:=i32((bits>>at^)&(u128(1)<<count-1))
        at^+=count
        return value
    }
    mode:=read(bits,&at,2)
    if mode>=2 {
        mode=2+(mode-2)*8+read(bits,&at,3)
        if mode>=14 {return}
    }
    m:=BC6H_MODES[mode]
    extra:i32 // the three bits after the mode of modes 1 and 2
    if mode<=1 {extra=read(bits,&at,3)}
    // e[channel][endpoint]: endpoints w, x, y and z of the specification.
    e:[3][4]i32
    for i in 0..<2 {for c in 0..<3 {e[c][i]=read(bits,&at,10)}}
    if m.subsets==2 {
        e[0][2]=read(bits,&at,6)
        e[0][3]=read(bits,&at,6)
        e[1][2]=e[0][1]>>6
        e[1][3]=e[1][1]>>6
        e[2][2]=e[2][1]>>6
    }
    switch mode {
    case 0:
        e[1][2]|=(extra&1)<<4
        e[1][3]|=(e[0][1]&0x20)>>1
        e[2][2]|=(extra&2)<<3
        e[2][3]=(e[1][1]&0x20)>>5|(e[2][1]&0x20)>>4|(e[0][2]&0x20)>>3|(e[0][3]&0x20)>>2|(extra&4)<<2
    case 1:
        e[1][2]|=(e[1][0]&0x200)>>5|(extra&1)<<5
        e[1][3]|=(extra&6)<<3
        e[2][2]|=(e[0][0]&0x200)>>5|(e[1][0]&0x80)>>2
        e[2][3]=(e[0][0]&0x180)>>7|(e[1][0]&0x100)>>6|(e[2][0]&0x80)>>4|(e[2][0]&0x100)>>3|(e[2][0]&0x200)>>5
    case 2:
        e[0][0]|=(e[0][1]&0x20)<<5
        e[1][0]|=(e[1][1]&0x10)<<6
        e[2][0]|=(e[2][1]&0x10)<<6
        e[2][3]=(e[1][1]&0x20)>>5|(e[2][1]&0x20)>>4|(e[0][2]&0x20)>>3|(e[0][3]&0x20)>>2
    case 3:
        e[0][0]|=(e[0][1]&0x10)<<6
        e[1][0]|=(e[1][1]&0x20)<<5
        e[2][0]|=(e[2][1]&0x10)<<6
        e[1][2]|=e[0][3]&0x10
        e[1][3]|=(e[0][1]&0x20)>>1
        e[2][3]=(e[0][2]&0x10)>>4|(e[2][1]&0x20)>>4|(e[0][2]&0x20)>>3|(e[0][3]&0x20)>>2
    case 4:
        e[0][0]|=(e[0][1]&0x10)<<6
        e[1][0]|=(e[1][1]&0x10)<<6
        e[2][0]|=(e[2][1]&0x20)<<5
        e[2][2]|=(e[0][1]&0x20)>>1
        e[2][3]=(e[1][1]&0x20)>>5|(e[0][2]&0x30)>>3|(e[0][3]&0x20)>>2|e[0][3]&0x10
    case 5:
        e[1][2]|=(e[1][0]&0x200)>>5
        e[1][3]|=(e[0][1]&0x20)>>1
        e[2][2]|=(e[0][0]&0x200)>>5
        e[2][3]=(e[1][1]&0x20)>>5|(e[2][1]&0x20)>>4|(e[0][2]&0x20)>>3|(e[0][3]&0x20)>>2|(e[2][0]&0x200)>>5
    case 6:
        e[1][2]|=(e[1][0]&0x200)>>5
        e[1][3]|=(e[0][0]&0x100)>>4
        e[2][2]|=(e[0][0]&0x200)>>5
        e[2][3]=(e[1][1]&0x20)>>5|(e[2][1]&0x20)>>4|(e[1][0]&0x100)>>6|(e[2][0]&0x300)>>5
    case 7:
        e[1][2]|=(e[1][0]&0x200)>>5|(e[1][0]&0x100)>>3
        e[1][3]|=(e[0][1]&0x20)>>1|(e[2][0]&0x100)>>3
        e[2][2]|=(e[0][0]&0x200)>>5
        e[2][3]=(e[0][0]&0x100)>>8|(e[2][1]&0x20)>>4|(e[0][2]&0x20)>>3|(e[0][3]&0x20)>>2|(e[2][0]&0x200)>>5
    case 8:
        e[1][2]|=(e[1][0]&0x200)>>5
        e[1][3]|=(e[0][1]&0x20)>>1
        e[2][2]|=(e[0][0]&0x200)>>5|(e[1][0]&0x100)>>3
        e[2][3]=(e[1][1]&0x20)>>5|(e[0][0]&0x100)>>7|(e[0][2]&0x20)>>3|(e[0][3]&0x20)>>2|(e[2][0]&0x200)>>5|(e[2][0]&0x100)>>3
    case 9:
        e[1][2]|=(e[1][0]&0x200)>>5|(e[1][0]&0x40)>>1
        e[1][3]|=(e[0][0]&0x40)>>2|(e[2][0]&0x40)>>1
        e[2][2]|=(e[0][0]&0x200)>>5|(e[1][0]&0x80)>>2
        e[2][3]=(e[0][0]&0x180)>>7|(e[1][0]&0x100)>>6|(e[2][0]&0x80)>>4|(e[2][0]&0x100)>>3|(e[2][0]&0x200)>>5
    case 11,12,13:
        // The high bits of the first endpoint follow the deltas, reversed.
        for c in 0..<3 {
            high:=(e[c][1]>>4)&63
            reversed:i32
            for b in 0..<6 {reversed|=((high>>uint(b))&1)<<uint(5-b)}
            e[c][0]|=reversed<<10
        }
    }
    endpoints:=int(m.subsets)*2
    if m.delta_bits>0 {
        for c in 0..<3 {
            sign:=i32(1)<<(m.delta_bits-1+u32(c==m.wide_delta))
            for i in 1..<endpoints {e[c][i]=e[c][0]+(e[c][i]&(sign-1))-(e[c][i]&sign)}
        }
    }
    top:=i32(1)<<m.endpoint_bits-1
    for c in 0..<3 {
        for i in 0..<endpoints {
            v:=e[c][i]&top
            switch {
            case m.endpoint_bits>=16:
            case v==0:
            case v==top: v=0xffff
            case: v=((v<<16)+0x8000)>>m.endpoint_bits
            }
            e[c][i]=v
        }
    }
    partition:=u32(read(bits,&at,5)) if m.subsets==2 else 0
    for i in 0..<16 {
        anchor:=i==0 || m.subsets==2 && i==int(BC7_ANCHORS_2[partition])
        index:=read(bits,&at,uint(m.index_bits)-uint(anchor))
        weight:=i32(BC7_WEIGHTS_3[index] if m.index_bits==3 else BC7_WEIGHTS_4[index])
        s:=int(BC7_PARTITIONS_2[partition][i])*2 if m.subsets==2 else 0
        for c in 0..<3 {
            value:=((64-weight)*e[c][s]+weight*e[c][s+1]+32)>>6
            texels[i][c]=u16((value*31)>>6)
        }
    }
    return
}
