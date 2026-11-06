package compressor

// The LZ stream format. A stream is a run of
// blocks of BLOCK_LEN raw bytes; each block has a 2-byte header and one large
// quantum whose 3-byte header gives its compressed size. A quantum is split into
// chunks of CHUNK_LEN raw bytes, each with a 3-byte big-endian header. Matches
// may reach back to the last block that set the reset flag.

// Compressor id of the block header.
COMPRESSOR_LZ :: 8

// Compression levels.
LEVEL_HYPER_FAST4 :: -4
LEVEL_HYPER_FAST3 :: -3
LEVEL_HYPER_FAST2 :: -2
LEVEL_HYPER_FAST1 :: -1
LEVEL_NONE :: 0
LEVEL_SUPER_FAST :: 1
LEVEL_VERY_FAST :: 2
LEVEL_FAST :: 3
LEVEL_NORMAL :: 4
LEVEL_OPTIMAL1 :: 5
LEVEL_OPTIMAL2 :: 6
LEVEL_OPTIMAL3 :: 7
LEVEL_OPTIMAL4 :: 8
LEVEL_OPTIMAL5 :: 9

// Decode types in the block header: the one of LZ, of the DECODE_TYPE_COUNT the format numbers.
DECODE_TYPE_LZ :: 6
DECODE_TYPE_COUNT :: 13

BLOCK_LEN :: 1<<18

// Block header: byte 0 is VERSION_NIBBLE in bits 0-3 (version 4, bits 4-5 zero),
// MEMCPY in bit 6 and RESET in bit 7; byte 1 is the decode type in bits 0-6 and
// CRC (quantum headers carry a 24-bit check) in bit 7.
BLOCK_HEADER_SIZE :: 2
BLOCK_HEADER_VERSION_NIBBLE :: 0xC
BLOCK_HEADER_VERSION_MASK :: 0x3F
BLOCK_HEADER_MEMCPY :: 0x40
BLOCK_HEADER_RESET :: 0x80
BLOCK_HEADER_CRC :: 0x80
BLOCK_HEADER_TYPE_MASK :: 0x7F

// Large quantum header: 24-bit big-endian word. The low QUANTUM_FLAG_SHIFT bits
// are comp_len-1, or QUANTUM_COMP_LEN_MASK for a special quantum named by the
// bits above. A normal quantum has HUFF and EXTRA flags above the length and is
// followed by a 24-bit big-endian check when the block has CRC.
QUANTUM_HEADER_SIZE :: 3
QUANTUM_HEADER_MAX_SIZE :: 16
QUANTUM_FLAG_SHIFT :: 18
QUANTUM_COMP_LEN_MASK :: (1<<QUANTUM_FLAG_SHIFT)-1
QUANTUM_HUFF_FLAG :: 1<<QUANTUM_FLAG_SHIFT
QUANTUM_EXTRA_FLAG :: 2<<QUANTUM_FLAG_SHIFT
QUANTUM_SPECIAL_WHOLE_MATCH :: 0 // followed by offset-1 as a 16-bit series (15 then 7 bits)
QUANTUM_SPECIAL_MEMSET :: 1 // followed by the byte
QUANTUM_SPECIAL_MEMCPY :: 2 // followed by the check when the block has CRC, then raw bytes
WHOLE_MATCH_BITS1 :: 15
WHOLE_MATCH_BITS2 :: 7

// Chunk header: 24-bit big-endian word. Without CHUNK_COMPRESSED it is the whole
// chunk as one entropy array (literals only). With it, bits 19-22 are the chunk
// type and bits 0-18 the compressed size; a size equal to the chunk's raw size
// is a stored chunk of type 0.
CHUNK_LEN :: 128*1024
CHUNK_HEADER_SIZE :: 3
CHUNK_COMPRESSED :: 1<<23
CHUNK_TYPE_SHIFT :: 19
CHUNK_TYPE_MASK :: 0xF
CHUNK_COMP_LEN_MASK :: (1<<CHUNK_TYPE_SHIFT)-1
MIN_CHUNK_LEN :: 128
CHUNK_LITERALS_SUB :: 0 // literals are deltas from the byte at the last offset
CHUNK_LITERALS_RAW :: 1
// The first chunk after a reset starts with MIN_OFFSET raw bytes.
MIN_OFFSET :: 8

// Entropy arrays. A header byte below 0x80 starts a 3-byte uncompressed header
// (18-bit size) or a 5-byte compressed one (type in bits 36-38, raw size-1 and
// comp size in 18 bits each). A byte of 0x80 or more starts a small header:
// 2 bytes uncompressed (12-bit size) or 3 bytes compressed (10-bit comp size,
// 10-bit raw size minus comp size minus 1).
ARRAY_TYPE_UNCOMPRESSED :: 0
ARRAY_TYPE_TANS :: 1
ARRAY_TYPE_HUFF :: 2
ARRAY_TYPE_RLE :: 3
ARRAY_TYPE_HUFF6 :: 4
ARRAY_TYPE_SPLIT :: 5
ARRAY_TYPE_COUNT :: 6
ARRAY_SIZE_BITS :: 18
ARRAY_SIZE_MASK :: (1<<ARRAY_SIZE_BITS)-1
ARRAY_SMALL_SIZE_BITS :: 10
ARRAY_SMALL_SIZE_MASK :: (1<<ARRAY_SMALL_SIZE_BITS)-1
ARRAY_SMALL_FLAG :: 0x80
ARRAY_INTERNAL_MAX_SCRATCH :: 48*1024
HUFF_ARRAY_MIN_SIZE :: 32
HUFF_CODELEN_LIMIT :: 11
TANS_L_BITS_MIN :: 8
TANS_L_BITS_MAX :: 11
MULTIARRAY_MAX_ARRAYS :: 63

// Packed Huffman code lengths are Rice-coded deltas from a prediction: the state
// starts at 4*log2 of the alphabet size and tracks 4 times a running average.
hufflen_pred_get :: #force_inline proc "contextless" (state:int) -> int {return (state+2)>>2}
hufflen_pred_update :: #force_inline proc "contextless" (state,val:int) -> int {
    return ((state*3+2)>>2)+val
}

// LZ packets: bits 0-1 literal run (3 = excess), bits 2-5 match length-2
// (15 = excess), bits 6-7 last offset index (3 = new offset).
LZ_LRL_MAX :: 3
LZ_ML_MAX :: 15
LZ_LOMML :: 2
LZ_NUM_LAST_OFFSETS :: 3
LZ_NO_MATCH_ZONE :: 16 // no match starts in the last bytes of a chunk
LZ_MATCH_END_PAD :: 8 // matches end this far before the end of a chunk
LZ_EXCESS_HEADER :: 0x80 // excess stream size follows (6 bits, 5 more in a byte)
LZ_ALT_OFFSETS :: 0x80 // offsets byte: modulo-1 in the low 7 bits
OFFSET_RAW_BITS :: 4
OFFSET_ALT_UNDER_BITS :: 3
ESCAPE_OFFSET_BIAS :: ((1<<23)-256)-(1<<16)
MAX_OFFSET_BITS :: 30
MAX_OFFSET :: 1<<MAX_OFFSET_BITS
ALT_OFFSET_MAX_MOD :: 128
EXCESS_EXPGOLOMB_SHIFT :: 6

// Decoder scratch for one chunk of raw_len bytes; a chunk whose arrays do not
// fit in it is corrupt.
scratch_size :: proc "contextless" (raw_len:int) -> int {
    n:=raw_len<=0 ? CHUNK_LEN : min(raw_len,CHUNK_LEN)
    return n*3+32+ARRAY_INTERNAL_MAX_SCRATCH+4096
}
