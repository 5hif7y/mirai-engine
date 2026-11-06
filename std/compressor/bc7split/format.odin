package bc7split

// BC7Split: a lossless rearrangement of BC7 blocks into per-mode streams that a byte LZ
// compresses better. Modes 0-7 are the BC7 modes, 8 is a block sent raw (no valid mode) and 9 a
// solid color, restored as its canonical mode 5 block.

MODE_COUNT :: 10
// Low bits of the stamp make data that is not BC7Split fail fast.
HEADER_VERSION :: 0x7BC
MAX_BLOCKS :: 1<<27

FLAG_SPLIT0 :: 1 // mode 0 is split; mode i is FLAG_SPLIT0<<i
FLAG_ALL_SPLIT :: (FLAG_SPLIT0<<MODE_COUNT)-FLAG_SPLIT0
FLAG_SWITCH_COLORSPACE :: 1<<16
FLAGS_ASSIGNED :: FLAG_ALL_SPLIT|FLAG_SWITCH_COLORSPACE

// Bytes of one block of each mode in the payload.
MODE_SIZES :: [MODE_COUNT]int{16,16,16,16,16,16,16,16,16,4}
// Where a split mode cuts its blocks: the first parts of every block go before all the second
// parts. 0 never splits.
MODE_SPLITS :: [MODE_COUNT]int{8,8,12,12,6,8,8,12,0,0}

// Same layout as the reference header.
Header :: struct {
    version:u32,
    flags:u32,
    mode_counts:[MODE_COUNT]u32,
}

Error :: enum u8 {
    None,
    Header_Corrupt,   // wrong version, unknown flags or more than MAX_BLOCKS
    Input_Too_Small,  // the payload is shorter than the header says
    Output_Too_Small, // dst holds fewer than 16 bytes per block
    Payload_Corrupt,  // a mode nibble above 9 or a mode with more blocks than its count
    Missing_Decoder,  // decode without its scratch
}

// Blocks of the stream and bytes its payload must have: the per-mode streams, then one mode
// nibble per block.
header_read :: proc "contextless" (header:Header) -> (blocks:int,payload_size:int,err:Error) {
    if header.version!=HEADER_VERSION || header.flags&~u32(FLAGS_ASSIGNED)!=0 {
        return 0,0,.Header_Corrupt
    }
    sizes:=MODE_SIZES
    for count,i in header.mode_counts {
        if int(count)>MAX_BLOCKS-blocks {return 0,0,.Header_Corrupt}
        blocks+=int(count)
        payload_size+=int(count)*sizes[i]
    }
    payload_size+=(blocks+1)/2
    return blocks,payload_size,.None
}
