package asset

// BC7 (BPTC): 4x4 texels in 16 bytes, in one of eight modes that trade
// subsets (pieces of the block, each with its two endpoints), endpoint
// precision and index bits, with alpha in the endpoints or apart. What a
// block decodes to follows the Khronos Data Format Specification; the
// encoder is cook/textures (bc7.odin), and the tables below serve both.

Bc7_Mode_Info :: struct {
    subsets:u32,        // 1 to 3, by a partition of the block
    partition_bits:u32,
    rotation_bits:u32,  // modes 4 and 5: the color channel alpha swaps with
    selector_bit:u32,   // mode 4: which of the two index sets is the color's
    color_bits:u32,     // per endpoint and channel, before a p-bit
    alpha_bits:u32,     // 0: alpha is 255
    endpoint_pbits:bool,// a low bit of its own for each endpoint
    shared_pbits:bool,  // a low bit shared by the two endpoints of a subset
    index_bits:u32,
    index_bits2:u32,    // of the second index set of modes 4 and 5
}

@(rodata)
BC7_MODES := [8]Bc7_Mode_Info{
    {subsets=3,partition_bits=4,color_bits=4,endpoint_pbits=true,index_bits=3},
    {subsets=2,partition_bits=6,color_bits=6,shared_pbits=true,index_bits=3},
    {subsets=3,partition_bits=6,color_bits=5,index_bits=2},
    {subsets=2,partition_bits=6,color_bits=7,endpoint_pbits=true,index_bits=2},
    {subsets=1,rotation_bits=2,selector_bit=1,color_bits=5,alpha_bits=6,index_bits=2,index_bits2=3},
    {subsets=1,rotation_bits=2,color_bits=7,alpha_bits=8,index_bits=2,index_bits2=2},
    {subsets=1,color_bits=7,alpha_bits=7,endpoint_pbits=true,index_bits=4},
    {subsets=2,partition_bits=6,color_bits=5,alpha_bits=5,endpoint_pbits=true,index_bits=2},
}

// The weight of the second endpoint, out of 64, for each index of 2, 3 and 4 bits.
@(rodata)
BC7_WEIGHTS_2 := [4]u32{0,21,43,64}
@(rodata)
BC7_WEIGHTS_3 := [8]u32{0,9,18,27,37,46,55,64}
@(rodata)
BC7_WEIGHTS_4 := [16]u32{0,4,9,13,17,21,26,30,34,38,43,47,51,55,60,64}

// The subset of each texel, row by row, for the 64 partitions of two and of
// three subsets.
@(rodata)
BC7_PARTITIONS_2 := [64][16]u8{
    {0,0,1,1,0,0,1,1,0,0,1,1,0,0,1,1},
    {0,0,0,1,0,0,0,1,0,0,0,1,0,0,0,1},
    {0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1},
    {0,0,0,1,0,0,1,1,0,0,1,1,0,1,1,1},
    {0,0,0,0,0,0,0,1,0,0,0,1,0,0,1,1},
    {0,0,1,1,0,1,1,1,0,1,1,1,1,1,1,1},
    {0,0,0,1,0,0,1,1,0,1,1,1,1,1,1,1},
    {0,0,0,0,0,0,0,1,0,0,1,1,0,1,1,1},
    {0,0,0,0,0,0,0,0,0,0,0,1,0,0,1,1},
    {0,0,1,1,0,1,1,1,1,1,1,1,1,1,1,1},
    {0,0,0,0,0,0,0,1,0,1,1,1,1,1,1,1},
    {0,0,0,0,0,0,0,0,0,0,0,1,0,1,1,1},
    {0,0,0,1,0,1,1,1,1,1,1,1,1,1,1,1},
    {0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1},
    {0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1},
    {0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1},
    {0,0,0,0,1,0,0,0,1,1,1,0,1,1,1,1},
    {0,1,1,1,0,0,0,1,0,0,0,0,0,0,0,0},
    {0,0,0,0,0,0,0,0,1,0,0,0,1,1,1,0},
    {0,1,1,1,0,0,1,1,0,0,0,1,0,0,0,0},
    {0,0,1,1,0,0,0,1,0,0,0,0,0,0,0,0},
    {0,0,0,0,1,0,0,0,1,1,0,0,1,1,1,0},
    {0,0,0,0,0,0,0,0,1,0,0,0,1,1,0,0},
    {0,1,1,1,0,0,1,1,0,0,1,1,0,0,0,1},
    {0,0,1,1,0,0,0,1,0,0,0,1,0,0,0,0},
    {0,0,0,0,1,0,0,0,1,0,0,0,1,1,0,0},
    {0,1,1,0,0,1,1,0,0,1,1,0,0,1,1,0},
    {0,0,1,1,0,1,1,0,0,1,1,0,1,1,0,0},
    {0,0,0,1,0,1,1,1,1,1,1,0,1,0,0,0},
    {0,0,0,0,1,1,1,1,1,1,1,1,0,0,0,0},
    {0,1,1,1,0,0,0,1,1,0,0,0,1,1,1,0},
    {0,0,1,1,1,0,0,1,1,0,0,1,1,1,0,0},
    {0,1,0,1,0,1,0,1,0,1,0,1,0,1,0,1},
    {0,0,0,0,1,1,1,1,0,0,0,0,1,1,1,1},
    {0,1,0,1,1,0,1,0,0,1,0,1,1,0,1,0},
    {0,0,1,1,0,0,1,1,1,1,0,0,1,1,0,0},
    {0,0,1,1,1,1,0,0,0,0,1,1,1,1,0,0},
    {0,1,0,1,0,1,0,1,1,0,1,0,1,0,1,0},
    {0,1,1,0,1,0,0,1,0,1,1,0,1,0,0,1},
    {0,1,0,1,1,0,1,0,1,0,1,0,0,1,0,1},
    {0,1,1,1,0,0,1,1,1,1,0,0,1,1,1,0},
    {0,0,0,1,0,0,1,1,1,1,0,0,1,0,0,0},
    {0,0,1,1,0,0,1,0,0,1,0,0,1,1,0,0},
    {0,0,1,1,1,0,1,1,1,1,0,1,1,1,0,0},
    {0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0},
    {0,0,1,1,1,1,0,0,1,1,0,0,0,0,1,1},
    {0,1,1,0,0,1,1,0,1,0,0,1,1,0,0,1},
    {0,0,0,0,0,1,1,0,0,1,1,0,0,0,0,0},
    {0,1,0,0,1,1,1,0,0,1,0,0,0,0,0,0},
    {0,0,1,0,0,1,1,1,0,0,1,0,0,0,0,0},
    {0,0,0,0,0,0,1,0,0,1,1,1,0,0,1,0},
    {0,0,0,0,0,1,0,0,1,1,1,0,0,1,0,0},
    {0,1,1,0,1,1,0,0,1,0,0,1,0,0,1,1},
    {0,0,1,1,0,1,1,0,1,1,0,0,1,0,0,1},
    {0,1,1,0,0,0,1,1,1,0,0,1,1,1,0,0},
    {0,0,1,1,1,0,0,1,1,1,0,0,0,1,1,0},
    {0,1,1,0,1,1,0,0,1,1,0,0,1,0,0,1},
    {0,1,1,0,0,0,1,1,0,0,1,1,1,0,0,1},
    {0,1,1,1,1,1,1,0,1,0,0,0,0,0,0,1},
    {0,0,0,1,1,0,0,0,1,1,1,0,0,1,1,1},
    {0,0,0,0,1,1,1,1,0,0,1,1,0,0,1,1},
    {0,0,1,1,0,0,1,1,1,1,1,1,0,0,0,0},
    {0,0,1,0,0,0,1,0,1,1,1,0,1,1,1,0},
    {0,1,0,0,0,1,0,0,0,1,1,1,0,1,1,1},
}

@(rodata)
BC7_PARTITIONS_3 := [64][16]u8{
    {0,0,1,1,0,0,1,1,0,2,2,1,2,2,2,2},
    {0,0,0,1,0,0,1,1,2,2,1,1,2,2,2,1},
    {0,0,0,0,2,0,0,1,2,2,1,1,2,2,1,1},
    {0,2,2,2,0,0,2,2,0,0,1,1,0,1,1,1},
    {0,0,0,0,0,0,0,0,1,1,2,2,1,1,2,2},
    {0,0,1,1,0,0,1,1,0,0,2,2,0,0,2,2},
    {0,0,2,2,0,0,2,2,1,1,1,1,1,1,1,1},
    {0,0,1,1,0,0,1,1,2,2,1,1,2,2,1,1},
    {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2},
    {0,0,0,0,1,1,1,1,1,1,1,1,2,2,2,2},
    {0,0,0,0,1,1,1,1,2,2,2,2,2,2,2,2},
    {0,0,1,2,0,0,1,2,0,0,1,2,0,0,1,2},
    {0,1,1,2,0,1,1,2,0,1,1,2,0,1,1,2},
    {0,1,2,2,0,1,2,2,0,1,2,2,0,1,2,2},
    {0,0,1,1,0,1,1,2,1,1,2,2,1,2,2,2},
    {0,0,1,1,2,0,0,1,2,2,0,0,2,2,2,0},
    {0,0,0,1,0,0,1,1,0,1,1,2,1,1,2,2},
    {0,1,1,1,0,0,1,1,2,0,0,1,2,2,0,0},
    {0,0,0,0,1,1,2,2,1,1,2,2,1,1,2,2},
    {0,0,2,2,0,0,2,2,0,0,2,2,1,1,1,1},
    {0,1,1,1,0,1,1,1,0,2,2,2,0,2,2,2},
    {0,0,0,1,0,0,0,1,2,2,2,1,2,2,2,1},
    {0,0,0,0,0,0,1,1,0,1,2,2,0,1,2,2},
    {0,0,0,0,1,1,0,0,2,2,1,0,2,2,1,0},
    {0,1,2,2,0,1,2,2,0,0,1,1,0,0,0,0},
    {0,0,1,2,0,0,1,2,1,1,2,2,2,2,2,2},
    {0,1,1,0,1,2,2,1,1,2,2,1,0,1,1,0},
    {0,0,0,0,0,1,1,0,1,2,2,1,1,2,2,1},
    {0,0,2,2,1,1,0,2,1,1,0,2,0,0,2,2},
    {0,1,1,0,0,1,1,0,2,0,0,2,2,2,2,2},
    {0,0,1,1,0,1,2,2,0,1,2,2,0,0,1,1},
    {0,0,0,0,2,0,0,0,2,2,1,1,2,2,2,1},
    {0,0,0,0,0,0,0,2,1,1,2,2,1,2,2,2},
    {0,2,2,2,0,0,2,2,0,0,1,2,0,0,1,1},
    {0,0,1,1,0,0,1,2,0,0,2,2,0,2,2,2},
    {0,1,2,0,0,1,2,0,0,1,2,0,0,1,2,0},
    {0,0,0,0,1,1,1,1,2,2,2,2,0,0,0,0},
    {0,1,2,0,1,2,0,1,2,0,1,2,0,1,2,0},
    {0,1,2,0,2,0,1,2,1,2,0,1,0,1,2,0},
    {0,0,1,1,2,2,0,0,1,1,2,2,0,0,1,1},
    {0,0,1,1,1,1,2,2,2,2,0,0,0,0,1,1},
    {0,1,0,1,0,1,0,1,2,2,2,2,2,2,2,2},
    {0,0,0,0,0,0,0,0,2,1,2,1,2,1,2,1},
    {0,0,2,2,1,1,2,2,0,0,2,2,1,1,2,2},
    {0,0,2,2,0,0,1,1,0,0,2,2,0,0,1,1},
    {0,2,2,0,1,2,2,1,0,2,2,0,1,2,2,1},
    {0,1,0,1,2,2,2,2,2,2,2,2,0,1,0,1},
    {0,0,0,0,2,1,2,1,2,1,2,1,2,1,2,1},
    {0,1,0,1,0,1,0,1,0,1,0,1,2,2,2,2},
    {0,2,2,2,0,1,1,1,0,2,2,2,0,1,1,1},
    {0,0,0,2,1,1,1,2,0,0,0,2,1,1,1,2},
    {0,0,0,0,2,1,1,2,2,1,1,2,2,1,1,2},
    {0,2,2,2,0,1,1,1,0,1,1,1,0,2,2,2},
    {0,0,0,2,1,1,1,2,1,1,1,2,0,0,0,2},
    {0,1,1,0,0,1,1,0,0,1,1,0,2,2,2,2},
    {0,0,0,0,0,0,0,0,2,1,1,2,2,1,1,2},
    {0,1,1,0,0,1,1,0,2,2,2,2,2,2,2,2},
    {0,0,2,2,0,0,1,1,0,0,1,1,0,0,2,2},
    {0,0,2,2,1,1,2,2,1,1,2,2,0,0,2,2},
    {0,0,0,0,0,0,0,0,0,0,0,0,2,1,1,2},
    {0,0,0,2,0,0,0,1,0,0,0,2,0,0,0,1},
    {0,2,2,2,1,2,2,2,0,2,2,2,1,2,2,2},
    {0,1,0,1,2,2,2,2,2,2,2,2,2,2,2,2},
    {0,1,1,1,2,0,1,1,2,2,0,1,2,2,2,0},
}


// The texel of each subset after the first whose index is stored a bit
// shorter, its top bit being zero: of the second subset of a partition in
// two, and of the second and third of a partition in three. The first
// subset has it at texel 0.
@(rodata)
BC7_ANCHORS_2 := [64]u8{
    15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,
    15,2,8,2,2,8,8,15,2,8,2,2,8,8,2,2,
    15,15,6,8,2,8,15,15,2,8,2,2,2,15,15,6,
    6,2,6,8,15,15,2,2,15,15,15,15,15,2,2,15,
}

@(rodata)
BC7_ANCHORS_3 := [64][2]u8{
    {3,15},{3,8},{15,8},{15,3},{8,15},{3,15},{15,3},{15,8},
    {8,15},{8,15},{6,15},{6,15},{6,15},{5,15},{3,15},{3,8},
    {3,15},{3,8},{8,15},{15,3},{3,15},{3,8},{6,15},{10,8},
    {5,3},{8,15},{8,6},{6,10},{8,15},{5,15},{15,10},{15,8},
    {8,15},{15,3},{3,15},{5,10},{6,10},{10,8},{8,9},{15,10},
    {15,6},{3,15},{15,8},{5,15},{15,3},{15,6},{15,6},{15,8},
    {3,15},{15,3},{5,15},{5,15},{5,15},{8,15},{5,15},{10,15},
    {5,15},{10,15},{8,15},{13,15},{15,3},{12,15},{3,15},{3,8},
}

// A value between two endpoints, as every BC7 decoder interpolates it.
bc7_interpolate :: proc "contextless" (e0,e1,weight:u32) -> u32 {
    return (e0*(64-weight)+e1*weight+32)>>6
}

// Texels of a BC7 block, row by row. A block of no mode (its first byte
// zero) decodes as transparent black, as the specification asks.
texture_bc7_block_decode :: proc "contextless" (block:[16]u8) -> (texels:[16][4]u8) {
    bits:=transmute(u128)block
    at:uint
    read :: proc "contextless" (bits:u128,at:^uint,count:u32) -> u32 {
        value:=u32((bits>>at^)&(u128(1)<<count-1))
        at^+=uint(count)
        return value
    }
    mode:=0
    for mode<8 && (block[0]>>uint(mode))&1==0 {mode+=1}
    if mode==8 {return}
    m:=BC7_MODES[mode]
    at=uint(mode)+1
    partition:=read(bits,&at,m.partition_bits)
    rotation:=read(bits,&at,m.rotation_bits)
    selector:=read(bits,&at,m.selector_bit)
    endpoints:[3][2][4]u32 // subset, endpoint, channel
    for c in 0..<3 {
        for s in 0..<m.subsets {for e in 0..<2 {endpoints[s][e][c]=read(bits,&at,m.color_bits)}}
    }
    if m.alpha_bits>0 {
        for s in 0..<m.subsets {for e in 0..<2 {endpoints[s][e][3]=read(bits,&at,m.alpha_bits)}}
    }
    color_bits,alpha_bits:=m.color_bits,m.alpha_bits
    if m.endpoint_pbits || m.shared_pbits {
        for s in 0..<m.subsets {
            shared:=read(bits,&at,1) if m.shared_pbits else 0
            for e in 0..<2 {
                p:=read(bits,&at,1) if m.endpoint_pbits else shared
                for &v in endpoints[s][e] {v=v<<1|p}
            }
        }
        color_bits+=1
        if alpha_bits>0 {alpha_bits+=1}
    }
    for s in 0..<m.subsets {
        for e in 0..<2 {
            for &v,c in endpoints[s][e] {
                n:=color_bits if c<3 else alpha_bits
                v=v<<(8-n)|v>>(2*n-8) if n>0 else 255
            }
        }
    }
    anchored :: proc "contextless" (subsets,partition:u32,i:int) -> bool {
        switch subsets {
        case 2: return i==int(BC7_ANCHORS_2[partition])
        case 3: return i==int(BC7_ANCHORS_3[partition][0]) || i==int(BC7_ANCHORS_3[partition][1])
        }
        return false
    }
    indices,indices2:[16]u32
    for i in 0..<16 {
        anchor:=i==0 || anchored(m.subsets,partition,i)
        indices[i]=read(bits,&at,m.index_bits-u32(anchor))
    }
    if m.index_bits2>0 {
        for i in 0..<16 {indices2[i]=read(bits,&at,m.index_bits2-u32(i==0))}
    }
    weight :: proc "contextless" (index_bits,index:u32) -> u32 {
        switch index_bits {
        case 2: return BC7_WEIGHTS_2[index]
        case 3: return BC7_WEIGHTS_3[index]
        }
        return BC7_WEIGHTS_4[index]
    }
    for i in 0..<16 {
        s:=u32(0)
        switch m.subsets {
        case 2: s=u32(BC7_PARTITIONS_2[partition][i])
        case 3: s=u32(BC7_PARTITIONS_3[partition][i])
        }
        color,color_bits_index:=indices[i],m.index_bits
        alpha,alpha_bits_index:=color,color_bits_index
        if m.index_bits2>0 {
            alpha,alpha_bits_index=indices2[i],m.index_bits2
            if selector==1 {color,color_bits_index,alpha,alpha_bits_index=alpha,alpha_bits_index,color,color_bits_index}
        }
        e0,e1:=endpoints[s][0],endpoints[s][1]
        texel:[4]u32
        for c in 0..<3 {texel[c]=bc7_interpolate(e0[c],e1[c],weight(color_bits_index,color))}
        texel[3]=bc7_interpolate(e0[3],e1[3],weight(alpha_bits_index,alpha))
        if rotation>0 {texel[3],texel[rotation-1]=texel[rotation-1],texel[3]}
        texels[i]={u8(texel[0]),u8(texel[1]),u8(texel[2]),u8(texel[3])}
    }
    return
}
