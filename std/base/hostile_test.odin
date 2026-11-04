package base

import "base:runtime"
import "core:mem"
import "core:testing"

// Every public procedure takes whatever it is given and returns: capacities,
// sizes and alignments that are zero, negative or huge, stale, forged and zero
// handles, keys that collide, full and empty containers, and text of any bytes.

@(private="file") HOSTILE_ROUNDS :: #config(BASE_HOSTILE_ROUNDS,400)

@(private="file")
Hostile :: struct {state:u64}

@(private="file")
hostile_next :: proc(h:^Hostile) -> u64 {
    h.state+=0x9e3779b97f4a7c15
    z:=h.state
    z=(z~(z>>30))*0xbf58476d1ce4e5b9
    z=(z~(z>>27))*0x94d049bb133111eb
    return z~(z>>31)
}

@(private="file")
hostile_int :: proc(h:^Hostile,below:int) -> int {return below<=0?0:int(hostile_next(h)%u64(below))}

// A capacity or size: usually small, sometimes empty, negative or beyond any memory.
@(private="file")
hostile_size :: proc(h:^Hostile) -> int {
    switch hostile_int(h,14) {
    case 0: return 0
    case 1: return -1
    case 2: return 1
    case 3: return min(int)
    case 4: return 1<<50
    case 5: return 1<<52
    case 6: return 1<<55
    case 7: return 1<<51
    case 8: return 3
    case 9: return 2
    }
    return hostile_int(h,600)+1
}

@(private="file")
hostile_small :: proc(h:^Hostile) -> int {
    switch hostile_int(h,10) {
    case 0: return 0
    case 1: return -1
    case 2: return 1
    }
    return hostile_int(h,130)
}

@(private="file")
hostile_alignment :: proc(h:^Hostile,wild:bool) -> int {
    if !wild {return 1<<uint(hostile_int(h,hostile_int(h,8)==0?41:13))}
    switch hostile_int(h,14) {
    case 0: return 0
    case 1: return -8
    case 2: return 3
    case 3: return 1<<40
    case 4: return 1
    case 5: return 4096
    case 6: return 1<<20
    case 7: return max(int)
    case 8: return min(int)
    case 9: return 5
    }
    return 1<<uint(hostile_int(h,7))
}

@(private="file")
hostile_key :: proc(h:^Hostile) -> u64 {
    switch hostile_int(h,6) {
    case 0: return 0
    case 1: return max(u64)
    case 2: return u64(hostile_int(h,40))<<32
    }
    return u64(hostile_int(h,40))
}

@(private="file")
hostile_handle :: proc(h:^Hostile,real:[]Handle) -> Handle {
    switch hostile_int(h,8) {
    case 0: return 0
    case 1: return Handle(max(u64))
    case 2: return Handle(hostile_next(h))
    case 3: return handle_make(u32(hostile_int(h,70)),u32(hostile_int(h,6)))
    case 4: return handle_make(max(u32),max(u32))
    }
    if len(real)==0 {return Handle(hostile_next(h))}
    return real[hostile_int(h,len(real))]
}

@(private="file")
hostile_text :: proc(h:^Hostile,buffer:[]u8) -> string {
    n:=len(buffer)
    for &b in buffer[:n] {
        switch hostile_int(h,6) {
        case 0: b=0xff
        case 1: b=0x80+u8(hostile_int(h,64))
        case 2: b=0xe0+u8(hostile_int(h,32))
        case 3: b=u8(hostile_next(h))
        case: b='a'+u8(hostile_int(h,26))
        }
    }
    return string(buffer[:n])
}

@(private="file")
Hostile_Block :: struct {memory:[]byte,size:int}

// Runs the allocator procedure with every mode and with sizes and alignments it may refuse.
@(private="file")
hostile_allocator_use :: proc(h:^Hostile,allocator:runtime.Allocator,ops:int,wild:=false,rough:=true) {
    live:[dynamic]Hostile_Block
    freed:[dynamic]Hostile_Block
    defer {delete(live);delete(freed)}
    stray:[64]byte
    for _ in 0..<ops {
        switch hostile_int(h,9) {
        case 0,1,2:
            size:=hostile_int(h,5)==0?hostile_size(h):hostile_int(h,300)
            if !rough && size<1 {size=1}
            alignment:=hostile_int(h,3)==0?hostile_alignment(h,wild):mem.DEFAULT_ALIGNMENT
            mode:=runtime.Allocator_Mode.Alloc if hostile_int(h,2)==0 else .Alloc_Non_Zeroed
            bytes,error:=allocator.procedure(allocator.data,mode,size,alignment,nil,0)
            if error==nil && bytes!=nil {append(&live,Hostile_Block{bytes,len(bytes)})}
        case 3:
            if !rough {continue}
            if len(live)==0 {continue}
            at:=hostile_int(h,len(live))
            size:=hostile_int(h,5)==0?hostile_size(h):hostile_int(h,300)
            if !rough && size<1 {size=1}
            alignment:=hostile_int(h,3)==0?hostile_alignment(h,wild):mem.DEFAULT_ALIGNMENT
            mode:=runtime.Allocator_Mode.Resize if hostile_int(h,2)==0 else .Resize_Non_Zeroed
            block:=live[at]
            bytes,error:=allocator.procedure(allocator.data,mode,size,alignment,raw_data(block.memory),block.size)
            if error==nil {
                if bytes!=nil {live[at]=Hostile_Block{bytes,len(bytes)}} else {append(&freed,block);unordered_remove(&live,at)}
            }
        case 4:
            if len(live)==0 {continue}
            at:=hostile_int(h,len(live))
            if !rough {at=len(live)-1}
            block:=live[at]
            _,error:=allocator.procedure(allocator.data,.Free,0,0,raw_data(block.memory),block.size)
            if error==nil || error==.Mode_Not_Implemented {append(&freed,block);ordered_remove(&live,at)}
        case 5:
            if !rough {continue}
            if len(freed)==0 {continue}
            block:=freed[hostile_int(h,len(freed))]
            allocator.procedure(allocator.data,.Free,0,0,raw_data(block.memory),block.size)
        case 6:
            if !rough {continue}
            point:=rawptr(&stray[hostile_int(h,64)])
            if hostile_int(h,2)==0 {point=nil}
            allocator.procedure(allocator.data,.Free,0,0,point,hostile_int(h,100))
        case 7:
            if !rough {continue}
            if len(live)>0 {
                block:=live[hostile_int(h,len(live))]
                if len(block.memory)>1 {
                    allocator.procedure(allocator.data,.Free,0,0,raw_data(block.memory[hostile_int(h,len(block.memory)-1)+1:]),0)
                }
            }
        case 8:
            if hostile_int(h,4)==0 {
                allocator.procedure(allocator.data,.Free_All,0,0,nil,0)
                clear(&live)
            } else {
                set:runtime.Allocator_Mode_Set
                allocator.procedure(allocator.data,.Query_Features,0,0,&set,0)
                allocator.procedure(allocator.data,.Query_Info,0,0,nil,0)
            }
        }
    }
}

@(test)
hostile_sizes_through_the_arena_and_stack :: proc(t:^testing.T) {
    h:=Hostile{1}
    wild:=false
    for _ in 0..<HOSTILE_ROUNDS {
        a:Arena
        if arena_init(&a,hostile_size(&h)) {
            for _ in 0..<12 {
                _=arena_alloc(&a,hostile_size(&h),hostile_alignment(&h,wild))
                _=arena_stats(&a)
                if hostile_int(&h,4)==0 {arena_reset(&a)}
            }
            hostile_allocator_use(&h,arena_allocator(&a),30)
            mark:=arena_mark(&a)
            arena_rewind(&a,mark)
            arena_destroy(&a)
        }
        arena_destroy(&a)
        buffer:[96]byte
        arena_init_buffer(&a,buffer[hostile_int(&h,40):][:hostile_int(&h,50)])
        hostile_allocator_use(&h,arena_allocator(&a),30)
        arena_destroy(&a)
        zero:Arena
        _=arena_alloc(&zero,hostile_size(&h),hostile_alignment(&h,wild))
        hostile_allocator_use(&h,arena_allocator(&zero),10)
        arena_reset(&zero);arena_destroy(&zero)

        s:Stack
        if stack_init(&s,hostile_size(&h)) {
            hostile_allocator_use(&h,stack_allocator(&s),40,wild)
            _=stack_stats(&s)
            stack_reset(&s)
            stack_destroy(&s)
        }
        stack_destroy(&s)
        stack_init_buffer(&s,buffer[hostile_int(&h,40):][:hostile_int(&h,50)])
        hostile_allocator_use(&h,stack_allocator(&s),30,wild)
        stack_destroy(&s)
        zero_stack:Stack
        hostile_allocator_use(&h,stack_allocator(&zero_stack),10,wild)
        stack_reset(&zero_stack);stack_destroy(&zero_stack)
    }
}

@(test)
hostile_arena_marks :: proc(t:^testing.T) {
    h:=Hostile{2}
    for _ in 0..<HOSTILE_ROUNDS {
        a:Arena
        if !arena_init(&a,hostile_int(&h,500)+1) {continue}
        _=arena_alloc(&a,hostile_int(&h,100))
        arena_rewind(&a,hostile_int(&h,4)==0?hostile_size(&h):hostile_int(&h,60))
        arena_destroy(&a)
    }
}

@(test)
hostile_sizes_through_the_heap_and_frame :: proc(t:^testing.T) {
    h:=Hostile{3}
    wild:=false
    for _ in 0..<HOSTILE_ROUNDS {
        heap:Heap
        if heap_init(&heap,HEAP_OVERHEAD+max(hostile_size(&h),-HEAP_OVERHEAD)) {
            hostile_allocator_use(&h,heap_allocator(&heap),40)
            _=heap_stats(&heap)
            heap_reset(&heap)
            heap_destroy(&heap)
        }
        heap_destroy(&heap)
        backing:[(HEAP_OVERHEAD+2048)/8]u64
        buffer:=mem.slice_to_bytes(backing[:])
        start:=hostile_int(&h,40)
        ok:=heap_init_buffer(&heap,buffer[start:][:HEAP_OVERHEAD+hostile_int(&h,2000)])
        if ok {hostile_allocator_use(&h,heap_allocator(&heap),40)}
        heap_destroy(&heap)
        zero:Heap
        hostile_allocator_use(&h,heap_allocator(&zero),10)
        heap_reset(&zero);_=heap_stats(&zero);heap_destroy(&zero)

        f:Frame_Allocator
        if frame_init(&f,hostile_size(&h)) {
            for _ in 0..<10 {
                _=frame_alloc(&f,hostile_size(&h),hostile_alignment(&h,wild))
                if hostile_int(&h,3)==0 {frame_swap(&f)}
            }
            hostile_allocator_use(&h,frame_allocator(&f),30)
            _=frame_stats(&f)
            frame_destroy(&f)
        }
        frame_destroy(&f)
        zero_frame:Frame_Allocator
        frame_swap(&zero_frame)
        _=frame_alloc(&zero_frame,hostile_size(&h))
        _=frame_stats(&zero_frame)
        hostile_allocator_use(&h,frame_allocator(&zero_frame),10)
        frame_destroy(&zero_frame)
    }
}

@(test)
hostile_sizes_through_the_block_pool :: proc(t:^testing.T) {
    h:=Hostile{4}
    wild:=false
    for _ in 0..<HOSTILE_ROUNDS {
        p:Block_Pool
        if block_pool_init(&p,hostile_size(&h),hostile_size(&h),hostile_int(&h,3)==0?hostile_alignment(&h,wild):mem.DEFAULT_ALIGNMENT) {
            held:[dynamic][]byte
            for _ in 0..<40 {
                switch hostile_int(&h,6) {
                case 0,1:
                    block,ok:=block_pool_alloc(&p,hostile_int(&h,2)==0)
                    if ok {append(&held,block)}
                case 2:
                    if len(held)>0 {
                        at:=hostile_int(&h,len(held))
                        _=block_pool_free(&p,raw_data(held[at]))
                        unordered_remove(&held,at)
                    }
                case 3:
                    stray:[8]byte
                    _=block_pool_free(&p,&stray[hostile_int(&h,8)])
                    _=block_pool_free(&p,nil)
                    if len(held)>0 {_=block_pool_free(&p,raw_data(held[0][hostile_int(&h,max(len(held[0]),1)):]))}
                case 4:
                    _=block_pool_index(&p,rawptr(uintptr(hostile_next(&h))))
                    _=block_pool_stats(&p)
                case 5:
                    if hostile_int(&h,5)==0 {block_pool_reset(&p);clear(&held)}
                }
            }
            hostile_allocator_use(&h,block_pool_allocator(&p),40)
            delete(held)
            block_pool_destroy(&p)
        }
        block_pool_destroy(&p)
        buffer:[512]byte
        if block_pool_init_buffer(&p,buffer[hostile_int(&h,100):][:hostile_int(&h,400)],hostile_size(&h),hostile_int(&h,3)==0?hostile_alignment(&h,wild):mem.DEFAULT_ALIGNMENT) {
            hostile_allocator_use(&h,block_pool_allocator(&p),40)
        }
        block_pool_destroy(&p)
        zero:Block_Pool
        _,_=block_pool_alloc(&zero)
        _=block_pool_free(&zero,&buffer[0])
        _=block_pool_index(&zero,&buffer[0])
        _=block_pool_stats(&zero)
        block_pool_reset(&zero)
        hostile_allocator_use(&h,block_pool_allocator(&zero),10)
    }
}

@(test)
hostile_block_pool_index :: proc(t:^testing.T) {
    h:=Hostile{5}
    p:Block_Pool
    if !block_pool_init(&p,16,4) {return}
    defer block_pool_destroy(&p)
    for _ in 0..<HOSTILE_ROUNDS {
        _=block_pool_block(&p,hostile_small(&h)-1)
    }
}

@(test)
hostile_handles_through_the_pool :: proc(t:^testing.T) {
    h:=Hostile{6}
    for _ in 0..<HOSTILE_ROUNDS {
        p:Handle_Pool
        if handle_pool_init(&p,hostile_size(&h)) {
            if hostile_int(&h,3)==0 {
                for &g in p.generations {g=u32(0xfffffff0+hostile_int(&h,16))&~u32(0)}
            }
            real:[dynamic]Handle
            for _ in 0..<60 {
                switch hostile_int(&h,7) {
                case 0,1:
                    handle:=handle_pool_alloc(&p)
                    if handle!=0 {append(&real,handle)}
                case 2:
                    _=handle_pool_free(&p,hostile_handle(&h,real[:]))
                case 3:
                    handle:=hostile_handle(&h,real[:])
                    _=handle_pool_valid(&p,handle)
                    _,_=handle_pool_slot(&p,handle)
                case 4:
                    slot:=hostile_small(&h)-1
                    _=handle_pool_alive(&p,slot)
                    _=handle_pool_handle(&p,slot)
                case 5:
                    if hostile_int(&h,6)==0 {handle_pool_clear(&p);clear(&real)}
                case 6:
                    if len(real)>0 {
                        at:=hostile_int(&h,len(real))
                        _=handle_pool_free(&p,real[at])
                        _=handle_pool_free(&p,real[at])
                    }
                }
            }
            delete(real)
            handle_pool_destroy(&p)
        }
        handle_pool_destroy(&p)
        zero:Handle_Pool
        handle:=hostile_handle(&h,nil)
        _=handle_pool_alloc(&zero)
        _=handle_pool_free(&zero,handle)
        _=handle_pool_valid(&zero,handle)
        _,_=handle_pool_slot(&zero,handle)
        _=handle_pool_alive(&zero,hostile_small(&h))
        _=handle_pool_handle(&zero,hostile_small(&h))
        handle_pool_clear(&zero);handle_pool_destroy(&zero)
    }
}

@(test)
hostile_handles_through_the_slot_map :: proc(t:^testing.T) {
    h:=Hostile{7}
    Id :: distinct Handle
    for _ in 0..<HOSTILE_ROUNDS {
        m:Slot_Map(f32,Id)
        if slot_map_init(&m,hostile_size(&h)) {
            real:[dynamic]Id
            for _ in 0..<60 {
                switch hostile_int(&h,7) {
                case 0,1:
                    handle:=slot_map_insert(&m,f32(hostile_int(&h,100)))
                    if handle!=0 {append(&real,handle)}
                case 2:
                    _=slot_map_remove(&m,Id(hostile_handle(&h,transmute([]Handle)real[:])))
                case 3:
                    handle:=Id(hostile_handle(&h,transmute([]Handle)real[:]))
                    _=slot_map_get(&m,handle)
                    _=slot_map_valid(&m,handle)
                case 4:
                    _=slot_map_handle(&m,hostile_small(&h)-1)
                    _=slot_map_len(&m)
                    _=slot_map_values(&m)
                case 5:
                    if hostile_int(&h,6)==0 {slot_map_clear(&m);clear(&real)}
                case 6:
                    if len(real)>0 {
                        at:=hostile_int(&h,len(real))
                        _=slot_map_remove(&m,real[at])
                        _=slot_map_remove(&m,real[at])
                    }
                }
            }
            delete(real)
            slot_map_destroy(&m)
        }
        slot_map_destroy(&m)
        zero:Slot_Map(f32,Id)
        handle:=Id(hostile_handle(&h,nil))
        _=slot_map_insert(&zero,1)
        _=slot_map_remove(&zero,handle)
        _=slot_map_get(&zero,handle)
        _=slot_map_valid(&zero,handle)
        _=slot_map_handle(&zero,hostile_small(&h))
        _=slot_map_len(&zero);_=slot_map_values(&zero)
        slot_map_clear(&zero);slot_map_destroy(&zero)
    }
}

@(test)
hostile_mismatched_handle_pool_buffers :: proc(t:^testing.T) {
    h:=Hostile{8}
    for _ in 0..<HOSTILE_ROUNDS {
        a,b:[8]u32
        pool:Handle_Pool
        handle_pool_init_buffer(&pool,a[:hostile_int(&h,9)],b[:hostile_int(&h,9)])
        _=handle_pool_alloc(&pool)
    }
}

@(test)
hostile_mismatched_priority_queue_buffers :: proc(t:^testing.T) {
    h:=Hostile{81}
    for _ in 0..<HOSTILE_ROUNDS {
        keys:[8]f32
        values:[8]u32
        queue:Priority_Queue(f32,u32)
        priority_queue_init_buffer(&queue,keys[:hostile_int(&h,9)],values[:hostile_int(&h,9)])
        _=priority_queue_push(&queue,1,1)
    }
}

@(private="file")
hostile_bit_index :: proc(h:^Hostile) -> int {return hostile_int(h,3)==0?hostile_size(h):hostile_int(h,300)-20}

@(test)
hostile_index_through_bits_test :: proc(t:^testing.T) {
    h:=Hostile{9}
    words:[4]u64
    for _ in 0..<HOSTILE_ROUNDS {_=bits_test(words[:hostile_int(&h,5)],hostile_bit_index(&h))}
}

@(test)
hostile_index_through_bits_set :: proc(t:^testing.T) {
    h:=Hostile{91}
    words:[4]u64
    for _ in 0..<HOSTILE_ROUNDS {bits_set(words[:hostile_int(&h,5)],hostile_bit_index(&h))}
}

@(test)
hostile_index_through_bits_clear :: proc(t:^testing.T) {
    h:=Hostile{92}
    words:[4]u64
    for _ in 0..<HOSTILE_ROUNDS {bits_clear(words[:hostile_int(&h,5)],hostile_bit_index(&h))}
}

@(test)
hostile_index_through_bits_toggle :: proc(t:^testing.T) {
    h:=Hostile{93}
    words:[4]u64
    for _ in 0..<HOSTILE_ROUNDS {bits_toggle(words[:hostile_int(&h,5)],hostile_bit_index(&h))}
}

@(test)
hostile_index_through_bits_assign :: proc(t:^testing.T) {
    h:=Hostile{94}
    words:[4]u64
    for _ in 0..<HOSTILE_ROUNDS {bits_assign(words[:hostile_int(&h,5)],hostile_bit_index(&h),hostile_int(&h,2)==0)}
}

@(test)
hostile_range_through_bits_set_range :: proc(t:^testing.T) {
    h:=Hostile{95}
    words:[4]u64
    for _ in 0..<HOSTILE_ROUNDS {bits_set_range(words[:hostile_int(&h,5)],hostile_bit_index(&h),hostile_bit_index(&h))}
}

@(test)
hostile_range_through_bits_clear_range :: proc(t:^testing.T) {
    h:=Hostile{96}
    words:[4]u64
    for _ in 0..<HOSTILE_ROUNDS {bits_clear_range(words[:hostile_int(&h,5)],hostile_bit_index(&h),hostile_bit_index(&h))}
}

@(test)
hostile_lengths_through_the_bit_operations :: proc(t:^testing.T) {
    h:=Hostile{10}
    for _ in 0..<HOSTILE_ROUNDS {
        words:[3][6]u64
        for &row in words {for &w in row {w=hostile_next(&h)}}
        bits_and(words[0][:hostile_int(&h,7)],words[1][:hostile_int(&h,7)],words[2][:hostile_int(&h,7)])
        bits_or(words[0][:hostile_int(&h,7)],words[1][:hostile_int(&h,7)],words[2][:hostile_int(&h,7)])
        bits_xor(words[0][:hostile_int(&h,7)],words[1][:hostile_int(&h,7)],words[2][:hostile_int(&h,7)])
        bits_and_not(words[0][:hostile_int(&h,7)],words[1][:hostile_int(&h,7)],words[2][:hostile_int(&h,7)])
    }
}

@(test)
hostile_bit_arrays :: proc(t:^testing.T) {
    h:=Hostile{97}
    for _ in 0..<HOSTILE_ROUNDS {
        words:[3][6]u64
        for &row in words {for &w in row {w=hostile_next(&h)}}
        n:=hostile_int(&h,7)
        dst,a,b:=words[0][:n],words[1][:n],words[2][:n]
        bits_and(dst,a,b);bits_or(dst,a,b);bits_xor(dst,a,b);bits_and_not(dst,a,b)
        _=bits_count(a);_=bits_any(a)
        _,_=bits_next(a,hostile_int(&h,3)==0?hostile_size(&h):hostile_int(&h,500)-20)
        _,_=bits_first(a)
        _,_=bits_first_clear(a,hostile_int(&h,3)==0?hostile_size(&h):hostile_int(&h,500)-20)
        it:=bits_iterator(a)
        for _ in 0..<400 {
            _,ok:=bits_iterate(&it)
            if !ok {break}
        }
        _=bits_words(hostile_size(&h))
        bits_clear_all(dst)
        empty:=bits_iterator(nil)
        _,_=bits_iterate(&empty)
    }
}

@(test)
hostile_bytes_through_hashing_and_ids :: proc(t:^testing.T) {
    h:=Hostile{11}
    buffer:[64]u8
    for _ in 0..<HOSTILE_ROUNDS {
        text:=hostile_text(&h,buffer[:hostile_int(&h,65)])
        data:=transmute([]byte)text
        seed:=hostile_next(&h)
        _=hash64(data,seed);_=hash64(nil,seed)
        _=hash128(data,seed);_=hash128(nil,seed)
        _=hash_u64(seed);_=name_hash(text);_=hash_combine(seed,hostile_next(&h))
        id:=asset_id_from_content(data)
        _=asset_id_from_content(nil)
        out:[40]u8
        _=entity_id_format(Entity_Id(seed),out[:hostile_int(&h,41)])
        _=asset_id_format(id,out[:hostile_int(&h,41)])
        _=hex_format_u64(seed,out[:hostile_int(&h,41)])
        _,_=entity_id_parse(text)
        _,_=asset_id_parse(text)
        _,_=hex_parse_u64(text)
        _,_=hex_parse_u64(string(out[:16]))
        shown:=entity_id_format(Entity_Id(seed),out[:])
        parsed,ok:=entity_id_parse(shown)
        testing.expect(t,ok && parsed==Entity_Id(seed))
        rng:=rng_make(seed,hostile_next(&h))
        _=rng_u32(&rng);_=rng_u64(&rng)
        state:=seed
        _=entity_id_next(&state);_=asset_id_random(&rng)
    }
}

@(test)
hostile_keys_through_the_hash_map :: proc(t:^testing.T) {
    h:=Hostile{12}
    for _ in 0..<HOSTILE_ROUNDS {
        m:Hash_Map(u32)
        if hash_map_init(&m,hostile_size(&h)) {
            for _ in 0..<80 {
                key:=hostile_key(&h)
                switch hostile_int(&h,9) {
                case 0,1,2:
                    value,_:=hash_map_insert(&m,key)
                    if value!=nil {value^=1}
                case 3: _=hash_map_set(&m,key,7)
                case 4: _,_=hash_map_remove(&m,key)
                case 5:
                    _=hash_map_ptr(&m,key);_,_=hash_map_get(&m,key);_=hash_map_contains(&m,key)
                case 6:
                    it:=hash_map_iterator(&m)
                    for {
                        _,_,ok:=hash_map_iterate(&it)
                        if !ok {break}
                    }
                case 7:
                    if hostile_int(&h,4)==0 {_=hash_map_grow(&m,hostile_size(&h))}
                case 8:
                    if hostile_int(&h,6)==0 {hash_map_clear(&m)}
                }
            }
            hash_map_destroy(&m)
        }
        hash_map_destroy(&m)
        zero:Hash_Map(u32)
        key:=hostile_key(&h)
        _,_=hash_map_insert(&zero,key)
        _=hash_map_set(&zero,key,1)
        _,_=hash_map_remove(&zero,key)
        _=hash_map_ptr(&zero,key);_,_=hash_map_get(&zero,key);_=hash_map_contains(&zero,key)
        it:=hash_map_iterator(&zero)
        _,_,_=hash_map_iterate(&it)
        hash_map_clear(&zero)
        hash_map_destroy(&zero)
    }
}

@(test)
hostile_text_through_the_interner :: proc(t:^testing.T) {
    h:=Hostile{13}
    buffer:[40]u8
    for _ in 0..<HOSTILE_ROUNDS {
        table:Interner
        if intern_init(&table,hostile_size(&h),hostile_size(&h)) {
            symbols:[dynamic]Symbol
            for _ in 0..<60 {
                text:=hostile_text(&h,buffer[:hostile_int(&h,41)])
                switch hostile_int(&h,5) {
                case 0,1:
                    symbol,ok:=intern_add(&table,text)
                    if ok {append(&symbols,symbol)}
                case 2: _,_=intern_find(&table,text)
                case 3:
                    symbol:=Symbol(hostile_next(&h))
                    if len(symbols)>0 && hostile_int(&h,2)==0 {symbol=symbols[hostile_int(&h,len(symbols))]}
                    _=intern_string(&table,symbol);_=intern_hash(&table,symbol)
                case 4:
                    if hostile_int(&h,8)==0 {intern_clear(&table);clear(&symbols)}
                }
            }
            delete(symbols)
            intern_destroy(&table)
        }
        intern_destroy(&table)
        zero:Interner
        text:=hostile_text(&h,buffer[:hostile_int(&h,41)])
        _,_=intern_add(&zero,text);_,_=intern_find(&zero,text)
        _=intern_string(&zero,Symbol(hostile_next(&h)));_=intern_hash(&zero,Symbol(hostile_next(&h)))
        intern_clear(&zero);intern_destroy(&zero)
    }
}

@(test)
hostile_keys_through_the_lru :: proc(t:^testing.T) {
    h:=Hostile{14}
    for _ in 0..<HOSTILE_ROUNDS {
        c:Lru(u32)
        if lru_init(&c,hostile_size(&h)) {
            for _ in 0..<100 {
                key:=hostile_key(&h)
                switch hostile_int(&h,7) {
                case 0,1,2: _,_,_=lru_put(&c,key,u32(key))
                case 3: _=lru_get(&c,key)
                case 4: _=lru_peek(&c,key)
                case 5: _,_=lru_remove(&c,key)
                case 6:
                    _=lru_len(&c);_,_,_=lru_oldest(&c)
                    if hostile_int(&h,10)==0 {lru_clear(&c)}
                }
            }
            lru_destroy(&c)
        }
        lru_destroy(&c)
        zero:Lru(u32)
        key:=hostile_key(&h)
        _,_,_=lru_put(&zero,key,1);_=lru_get(&zero,key);_=lru_peek(&zero,key)
        _,_=lru_remove(&zero,key);_=lru_len(&zero);_,_,_=lru_oldest(&zero)
        lru_clear(&zero);lru_destroy(&zero)
    }
}

@(test)
hostile_keys_through_the_priority_queue :: proc(t:^testing.T) {
    h:=Hostile{15}
    for _ in 0..<HOSTILE_ROUNDS {
        q:Priority_Queue(f32,u32)
        if priority_queue_init(&q,hostile_size(&h)) {
            for _ in 0..<80 {
                switch hostile_int(&h,5) {
                case 0,1,2:
                    key:f32
                    switch hostile_int(&h,4) {
                    case 0: key=f32(0h7fc00000)
                    case 1: key=f32(0h7f800000)
                    case: key=f32(hostile_int(&h,50))
                    }
                    _=priority_queue_push(&q,key,1)
                case 3: _,_,_=priority_queue_pop(&q)
                case 4:
                    _,_,_=priority_queue_peek(&q)
                    if hostile_int(&h,10)==0 {priority_queue_clear(&q)}
                }
            }
            priority_queue_destroy(&q)
        }
        priority_queue_destroy(&q)
        zero:Priority_Queue(f32,u32)
        _=priority_queue_push(&zero,1,1);_,_,_=priority_queue_pop(&zero);_,_,_=priority_queue_peek(&zero)
        priority_queue_clear(&zero);priority_queue_destroy(&zero)
    }
}

@(test)
hostile_values_through_the_ring_and_queue :: proc(t:^testing.T) {
    h:=Hostile{16}
    for _ in 0..<HOSTILE_ROUNDS {
        r:Ring(u32)
        if ring_init(&r,hostile_size(&h)) {
            for _ in 0..<100 {
                switch hostile_int(&h,9) {
                case 0: _=ring_push_back(&r,1)
                case 1: _=ring_push_front(&r,2)
                case 2: _,_=ring_push_overwrite(&r,3)
                case 3: _,_=ring_pop_front(&r)
                case 4: _,_=ring_pop_back(&r)
                case 5: _=ring_get(&r,hostile_small(&h)-1)
                case 6: _=ring_front(&r);_=ring_back(&r);_=ring_space(&r)
                case 7: if hostile_int(&h,10)==0 {ring_clear(&r)}
                case 8: _=ring_get(&r,hostile_size(&h))
                }
            }
            ring_destroy(&r)
        }
        ring_destroy(&r)
        buffer:[5]u32
        ring_init_buffer(&r,buffer[:hostile_int(&h,6)])
        _=ring_push_back(&r,1);_,_=ring_push_overwrite(&r,1);_,_=ring_pop_back(&r)
        zero:Ring(u32)
        _=ring_push_back(&zero,1);_=ring_push_front(&zero,1);_,_=ring_push_overwrite(&zero,1)
        _,_=ring_pop_front(&zero);_,_=ring_pop_back(&zero);_=ring_get(&zero,0)
        _=ring_front(&zero);_=ring_back(&zero);_=ring_space(&zero)
        ring_clear(&zero);ring_destroy(&zero)

        q:Spsc_Queue(u32)
        if spsc_init(&q,hostile_size(&h)) {
            for _ in 0..<100 {
                switch hostile_int(&h,3) {
                case 0,1: _=spsc_push(&q,1)
                case 2: _,_=spsc_pop(&q);_=spsc_len(&q)
                }
            }
            spsc_destroy(&q)
        }
        spsc_destroy(&q)
        zero_queue:Spsc_Queue(u32)
        _=spsc_push(&zero_queue,1);_,_=spsc_pop(&zero_queue);_=spsc_len(&zero_queue)
        spsc_destroy(&zero_queue)
    }
}

@(test)
hostile_keys_through_the_sparse_set :: proc(t:^testing.T) {
    h:=Hostile{17}
    for _ in 0..<HOSTILE_ROUNDS {
        s:Sparse_Set
        if sparse_set_init(&s,hostile_size(&h),hostile_size(&h)) {
            for _ in 0..<100 {
                key:=u32(hostile_key(&h))
                if hostile_int(&h,8)==0 {key=u32(hostile_next(&h))}
                switch hostile_int(&h,6) {
                case 0,1: _,_=sparse_set_insert(&s,key)
                case 2: _,_,_=sparse_set_remove(&s,key)
                case 3: _=sparse_set_contains(&s,key);_,_=sparse_set_index(&s,key)
                case 4: _=sparse_set_members(&s)
                case 5: if hostile_int(&h,10)==0 {sparse_set_clear(&s)}
                }
            }
            sparse_set_destroy(&s)
        }
        sparse_set_destroy(&s)
        sparse:[6]u32
        dense:[4]u32
        sparse_set_init_buffer(&s,sparse[:hostile_int(&h,7)],dense[:hostile_int(&h,5)])
        key:=u32(hostile_int(&h,10))
        _,_=sparse_set_insert(&s,key);_,_,_=sparse_set_remove(&s,key);_=sparse_set_contains(&s,key)
        zero:Sparse_Set
        _,_=sparse_set_insert(&zero,key);_,_,_=sparse_set_remove(&zero,key);_=sparse_set_contains(&zero,key)
        _,_=sparse_set_index(&zero,key);_=sparse_set_members(&zero)
        sparse_set_clear(&zero);sparse_set_destroy(&zero)
    }
}

@(test)
hostile_counts_through_the_radix_sort :: proc(t:^testing.T) {
    h:=Hostile{18}
    for _ in 0..<HOSTILE_ROUNDS {
        n:=hostile_int(&h,300)
        items:=make([]Sort_Key32,n);defer delete(items)
        scratch:=make([]Sort_Key32,n+hostile_int(&h,3));defer delete(scratch)
        wide:=make([]Sort_Key64,n);defer delete(wide)
        wide_scratch:=make([]Sort_Key64,n+hostile_int(&h,3));defer delete(wide_scratch)
        shape:=hostile_int(&h,4)
        for i in 0..<n {
            key:=u64(hostile_next(&h))
            switch shape {
            case 1: key=0
            case 2: key=max(u64)
            case 3: key&=0xff
            }
            items[i]={u32(key),u32(i)}
            wide[i]={key,u32(i)}
        }
        radix_sort32(items,scratch)
        radix_sort64(wide,wide_scratch)
        for i in 1..<n {
            testing.expect(t,items[i-1].key<=items[i].key)
            testing.expect(t,wide[i-1].key<=wide[i].key)
        }
        radix_sort32(nil,nil);radix_sort64(nil,nil)
        _=sort_key_f32(f32(0h7fc00000));_=sort_key_f32(f32(0hff800000))
        _=sort_key_i32(min(i32));_=sort_key_i64(max(i64))
    }
}

@(test)
hostile_short_scratch_in_the_radix_sort :: proc(t:^testing.T) {
    h:=Hostile{19}
    for _ in 0..<HOSTILE_ROUNDS {
        n:=hostile_int(&h,40)
        items:=make([]Sort_Key32,n);defer delete(items)
        scratch:=make([]Sort_Key32,hostile_int(&h,n+1));defer delete(scratch)
        for &item in items {item={u32(hostile_next(&h)),0}}
        radix_sort32(items,scratch)
        wide:=make([]Sort_Key64,n);defer delete(wide)
        radix_sort64(wide,nil)
    }
}

@(test)
hostile_bytes_through_the_text_buffers :: proc(t:^testing.T) {
    h:=Hostile{20}
    source:[80]u8
    store:[40]u8
    for _ in 0..<HOSTILE_ROUNDS {
        text:=hostile_text(&h,source[:hostile_int(&h,81)])
        other:=hostile_text(&h,source[hostile_int(&h,20):][:hostile_int(&h,20)])
        for &b in store {b=u8(hostile_next(&h))}
        buffer:=store[hostile_int(&h,41):]
        if hostile_int(&h,2)==0 {buffer=buffer[:hostile_int(&h,len(buffer)+1)]}
        _=text_set(buffer,text)
        _=text_get(buffer);_=text_len(buffer)
        _=text_equal(buffer,other)
        _=text_append(buffer,other)
        _=text_compare(buffer,store[:hostile_int(&h,41)])
        formats:=[?]string{"%s","%v","%d","%","%%%","%*d","%[9]d","%!","%s%s%s",string(source[:hostile_int(&h,10)])}
        _=text_format(buffer,formats[hostile_int(&h,len(formats))],text,hostile_int(&h,100))
        _=text_get(buffer)
        text_clear(buffer)
        _=text_set(nil,text);_=text_append(nil,text);_=text_format(nil,"%s",text)
        _=text_get(nil);_=text_len(nil);text_clear(nil);_=text_compare(nil,nil)
    }
}

@(test)
hostile_sizes_through_the_region :: proc(t:^testing.T) {
    h:=Hostile{21}
    for _ in 0..<HOSTILE_ROUNDS {
        r:Region
        size:=hostile_size(&h)
        if size>1<<28 && size<1<<62 {size=1<<28}
        if region_reserve(&r,size) {
            for _ in 0..<10 {
                want:=hostile_int(&h,3)==0?hostile_size(&h):hostile_int(&h,1<<18)
                if want>1<<24 {want=len(r.data)+hostile_int(&h,3)-1+(hostile_int(&h,2)==0?0:1<<40)}
                if hostile_int(&h,2)==0 {_=region_commit(&r,want)} else {_=region_commit_tail(&r,want)}
            }
            region_release(&r)
        }
        region_release(&r)
        list,ok:=region_dynamic(&r,u64,hostile_size(&h)>>20)
        if ok {
            for _ in 0..<5 {
                count:=hostile_small(&h)
                if region_grow(&r,&list,count) && count>=1 {for _ in 0..<count {append(&list,1)}}
            }
        }
        region_release(&r)
        zero:Region
        _=region_commit(&zero,hostile_size(&h));_=region_commit_tail(&zero,hostile_size(&h))
        region_release(&zero)
    }
}

@(test)
hostile_counts_through_the_region_slice :: proc(t:^testing.T) {
    h:=Hostile{22}
    for _ in 0..<HOSTILE_ROUNDS {
        r:Region
        if !region_reserve(&r,1<<16) {continue}
        _=region_commit(&r,1<<12)
        s:=region_slice(&r,u32,hostile_small(&h)-1)
        _=len(s)
        region_release(&r)
    }
}

@(test)
hostile_sizes_through_the_profile :: proc(t:^testing.T) {
    h:=Hostile{23}
    for _ in 0..<HOSTILE_ROUNDS {
        p:Profile
        threads,zones:=hostile_small(&h)-1,hostile_small(&h)-1
        if profile_init(&p,{threads,zones,{}}) {
            out:[8]Profile_Zone
            for _ in 0..<60 {
                thread:=hostile_small(&h)-1
                switch hostile_int(&h,6) {
                case 0,1:
                    scope:=profile_begin(&p,thread,"zone")
                    if hostile_int(&h,3)!=0 {profile_end(scope)}
                case 2:
                    func:=proc(p:^Profile,thread:int) {
                        profile_zone(p,thread,"nested")
                        profile_zone(p,thread,"inner")
                    }
                    func(&p,thread)
                case 3:
                    _=profile_read(&p,thread,out[:hostile_int(&h,9)])
                    _=profile_lost(&p,thread)
                    _,_,_=profile_read_since(&p,thread,u64(hostile_int(&h,64)),out[:hostile_int(&h,9)])
                case 4:
                    profile_frame(&p);profile_set_enabled(&p,hostile_int(&h,2)==0)
                case 5:
                    if hostile_int(&h,8)==0 {profile_clear(&p)}
                }
            }
            profile_destroy(&p)
        }
        profile_destroy(&p)
        zero:Profile
        scope:=profile_begin(&zero,hostile_small(&h)-1,"zone")
        profile_end(scope)
        profile_end({})
        out:[2]Profile_Zone
        _=profile_read(&zero,hostile_small(&h)-1,out[:]);_=profile_lost(&zero,hostile_small(&h)-1)
        _,_,_=profile_read_since(&zero,hostile_small(&h)-1,u64(hostile_small(&h)),out[:])
        profile_frame(&zero);profile_clear(&zero);profile_destroy(&zero)
        _=profile_begin(nil,0,"nil")
    }
}


@(test)
hostile_pointers_through_the_stack_allocator :: proc(t:^testing.T) {
    h:=Hostile{26}
    for _ in 0..<HOSTILE_ROUNDS {
        s:Stack
        if stack_init(&s,hostile_int(&h,600)+1) {
            hostile_allocator_use(&h,stack_allocator(&s),40)
            stack_destroy(&s)
        }
    }
}

@(test)
hostile_growing_a_map_that_was_never_initialized :: proc(t:^testing.T) {
    h:=Hostile{27}
    for _ in 0..<HOSTILE_ROUNDS {
        zero:Hash_Map(u32)
        if hash_map_grow(&zero,hostile_int(&h,50)-3) {_=hash_map_set(&zero,1,1)}
        hash_map_destroy(&zero)
    }
}

@(test)
hostile_alignments_through_the_arena :: proc(t:^testing.T) {
    h:=Hostile{24}
    for _ in 0..<HOSTILE_ROUNDS {
        a:Arena
        if arena_init(&a,hostile_int(&h,600)+1) {
            hostile_allocator_use(&h,arena_allocator(&a),20,true)
            arena_destroy(&a)
        }
    }
}

@(test)
hostile_alignments_through_the_stack :: proc(t:^testing.T) {
    h:=Hostile{28}
    for _ in 0..<HOSTILE_ROUNDS {
        s:Stack
        if stack_init(&s,hostile_int(&h,600)+1) {
            hostile_allocator_use(&h,stack_allocator(&s),20,true)
            stack_destroy(&s)
        }
    }
}

@(test)
hostile_alignments_through_the_frame_allocator :: proc(t:^testing.T) {
    h:=Hostile{29}
    for _ in 0..<HOSTILE_ROUNDS {
        f:Frame_Allocator
        if frame_init(&f,hostile_int(&h,600)+1) {
            _=frame_alloc(&f,hostile_int(&h,100),hostile_alignment(&h,true))
            hostile_allocator_use(&h,frame_allocator(&f),20,true)
            frame_destroy(&f)
        }
    }
}

@(test)
hostile_alignments_through_the_heap :: proc(t:^testing.T) {
    h:=Hostile{30}
    for _ in 0..<HOSTILE_ROUNDS {
        heap:Heap
        if heap_init(&heap,HEAP_OVERHEAD+hostile_int(&h,6000)+1) {
            hostile_allocator_use(&h,heap_allocator(&heap),30,true)
            heap_destroy(&heap)
        }
    }
}

@(test)
hostile_alignments_through_the_block_pool :: proc(t:^testing.T) {
    h:=Hostile{37}
    for _ in 0..<HOSTILE_ROUNDS {
        p:Block_Pool
        if block_pool_init(&p,hostile_int(&h,100)+1,hostile_int(&h,10)+1,hostile_alignment(&h,true)) {
            hostile_allocator_use(&h,block_pool_allocator(&p),30,true)
            block_pool_destroy(&p)
        }
    }
}

@(test)
hostile_sizes_near_the_largest_int_through_the_arena :: proc(t:^testing.T) {
    h:=Hostile{31}
    for _ in 0..<HOSTILE_ROUNDS {
        a:Arena
        if arena_init(&a,hostile_int(&h,600)+1) {
            allocator:=arena_allocator(&a)
            _,_=allocator.procedure(allocator.data,.Alloc,max(int)-hostile_int(&h,5000),hostile_alignment(&h,false),nil,0)
            arena_destroy(&a)
        }
    }
}

@(test)
hostile_sizes_near_the_largest_int_through_the_stack :: proc(t:^testing.T) {
    h:=Hostile{32}
    for _ in 0..<HOSTILE_ROUNDS {
        s:Stack
        if stack_init(&s,hostile_int(&h,600)+1) {
            allocator:=stack_allocator(&s)
            _,_=allocator.procedure(allocator.data,.Alloc,max(int)-hostile_int(&h,5000),hostile_alignment(&h,false),nil,0)
            stack_destroy(&s)
        }
    }
}

@(test)
hostile_sizes_near_the_largest_int_through_the_heap :: proc(t:^testing.T) {
    h:=Hostile{33}
    for _ in 0..<HOSTILE_ROUNDS {
        heap:Heap
        if heap_init(&heap,HEAP_OVERHEAD+hostile_int(&h,6000)+1) {
            _,_=heap_allocator_proc(&heap,.Alloc,max(int)-hostile_int(&h,5000),hostile_alignment(&h,false),nil,0)
            heap_destroy(&heap)
        }
    }
}

@(test)
hostile_sizes_near_the_largest_int_through_the_frame_allocator :: proc(t:^testing.T) {
    h:=Hostile{35}
    for _ in 0..<HOSTILE_ROUNDS {
        f:Frame_Allocator
        if frame_init(&f,hostile_int(&h,600)+1) {
            _=frame_alloc(&f,max(int)-hostile_int(&h,5000),hostile_alignment(&h,false))
            frame_destroy(&f)
        }
    }
}

@(test)
hostile_sizes_near_the_largest_int_through_the_block_pool :: proc(t:^testing.T) {
    h:=Hostile{36}
    for _ in 0..<HOSTILE_ROUNDS {
        p:Block_Pool
        if block_pool_init(&p,hostile_int(&h,100)+1,hostile_int(&h,10)+1) {
            _,_=block_pool_allocator_proc(&p,.Alloc,max(int)-hostile_int(&h,5000),hostile_alignment(&h,false),nil,0)
            block_pool_destroy(&p)
        }
    }
}

@(test)
hostile_counts_through_region_grow :: proc(t:^testing.T) {
    h:=Hostile{34}
    for _ in 0..<HOSTILE_ROUNDS {
        r:Region
        list,ok:=region_dynamic(&r,u64,1000)
        if !ok {continue}
        count:=max(int)-hostile_int(&h,100)
        testing.expect(t,!region_grow(&r,&list,count),"No room for max(int) more items")
        region_release(&r)
    }
}

// A capacity whose size in bytes overflows int for most element types.
@(private="file")
hostile_huge :: proc(h:^Hostile) -> int {
    huge:=[?]int{max(int),max(int)/2+1,1<<62,1<<61+1,1<<61,max(int)/3,1<<60+1,max(int)-1,1<<59,1<<58+1}
    return huge[hostile_int(h,len(huge))]
}

@(test)
hostile_huge_capacity_in_the_hash_map :: proc(t:^testing.T) {
    h:=Hostile{40}
    for _ in 0..<HOSTILE_ROUNDS {
        m:Hash_Map(u32)
        if hash_map_init(&m,hostile_huge(&h)) {
            for key in 1..=u64(10) {_=hash_map_set(&m,key,1)}
            _=hash_map_contains(&m,99)
            hash_map_destroy(&m)
        }
    }
}

@(test)
hostile_huge_capacity_in_the_ring :: proc(t:^testing.T) {
    h:=Hostile{41}
    for _ in 0..<HOSTILE_ROUNDS {
        r:Ring(u32)
        if ring_init(&r,hostile_huge(&h)) {
            for _ in 0..<10 {_=ring_push_back(&r,1)}
            ring_destroy(&r)
        }
    }
}

@(test)
hostile_huge_capacity_in_the_priority_queue :: proc(t:^testing.T) {
    h:=Hostile{42}
    for _ in 0..<HOSTILE_ROUNDS {
        q:Priority_Queue(f32,u32)
        if priority_queue_init(&q,hostile_huge(&h)) {
            for _ in 0..<10 {_=priority_queue_push(&q,1,1)}
            priority_queue_destroy(&q)
        }
    }
}

@(test)
hostile_huge_capacity_in_the_spsc_queue :: proc(t:^testing.T) {
    h:=Hostile{43}
    for _ in 0..<HOSTILE_ROUNDS {
        q:Spsc_Queue(u32)
        if spsc_init(&q,hostile_huge(&h)) {
            for _ in 0..<10 {_=spsc_push(&q,1)}
            spsc_destroy(&q)
        }
    }
}

@(test)
hostile_huge_capacity_in_the_sparse_set :: proc(t:^testing.T) {
    h:=Hostile{44}
    for _ in 0..<HOSTILE_ROUNDS {
        s:Sparse_Set
        if sparse_set_init(&s,hostile_huge(&h),hostile_huge(&h)) {
            for key in u32(0)..<10 {_,_=sparse_set_insert(&s,key)}
            sparse_set_destroy(&s)
        }
        if sparse_set_init(&s,hostile_int(&h,50)+1,hostile_huge(&h)) {
            for key in u32(0)..<10 {_,_=sparse_set_insert(&s,key)}
            sparse_set_destroy(&s)
        }
    }
}

@(test)
hostile_huge_capacity_in_the_interner :: proc(t:^testing.T) {
    h:=Hostile{45}
    for _ in 0..<HOSTILE_ROUNDS {
        table:Interner
        if intern_init(&table,hostile_huge(&h),hostile_huge(&h)) {
            _,_=intern_add(&table,"abc")
            intern_destroy(&table)
        }
        if intern_init(&table,hostile_int(&h,50)+1,hostile_huge(&h)) {
            _,_=intern_add(&table,"abc")
            intern_destroy(&table)
        }
        if intern_init(&table,hostile_huge(&h),hostile_int(&h,50)+1) {
            _,_=intern_add(&table,"abc")
            intern_destroy(&table)
        }
    }
}

@(test)
hostile_huge_capacity_in_the_block_pool :: proc(t:^testing.T) {
    h:=Hostile{46}
    for _ in 0..<HOSTILE_ROUNDS {
        p:Block_Pool
        if block_pool_init(&p,hostile_huge(&h),hostile_int(&h,50)+1) {
            _,_=block_pool_alloc(&p)
            block_pool_destroy(&p)
        }
        if block_pool_init(&p,hostile_int(&h,50)+1,hostile_huge(&h)) {
            _,_=block_pool_alloc(&p)
            block_pool_destroy(&p)
        }
        if block_pool_init(&p,hostile_huge(&h),hostile_huge(&h)) {
            _,_=block_pool_alloc(&p)
            block_pool_destroy(&p)
        }
    }
}

@(test)
hostile_huge_sizes_in_the_profile :: proc(t:^testing.T) {
    h:=Hostile{47}
    for _ in 0..<HOSTILE_ROUNDS {
        p:Profile
        if profile_init(&p,{hostile_int(&h,4)+1,hostile_huge(&h),{}}) {
            profile_zone(&p,0,"zone")
            profile_destroy(&p)
        }
        if profile_init(&p,{hostile_int(&h,2)==0?hostile_huge(&h):hostile_int(&h,1<<17),hostile_int(&h,100)+1,{}}) {
            profile_zone(&p,0,"zone")
            profile_destroy(&p)
        }
    }
}

@(test)
hostile_huge_capacity_in_the_other_containers :: proc(t:^testing.T) {
    h:=Hostile{48}
    for _ in 0..<HOSTILE_ROUNDS {
        capacity:=hostile_huge(&h)
        a:Arena
        if arena_init(&a,capacity) {_=arena_alloc(&a,8);arena_destroy(&a)}
        s:Stack
        if stack_init(&s,capacity) {stack_destroy(&s)}
        heap:Heap
        if heap_init(&heap,capacity) {heap_destroy(&heap)}
        f:Frame_Allocator
        if frame_init(&f,capacity) {_=frame_alloc(&f,8);frame_swap(&f);frame_destroy(&f)}
        pool:Handle_Pool
        if handle_pool_init(&pool,capacity) {_=handle_pool_alloc(&pool);handle_pool_destroy(&pool)}
        m:Slot_Map(u32,Handle)
        if slot_map_init(&m,capacity) {_=slot_map_insert(&m,1);slot_map_destroy(&m)}
        c:Lru(u32)
        if lru_init(&c,capacity) {_,_,_=lru_put(&c,1,1);lru_destroy(&c)}
        r:Region
        if region_reserve(&r,capacity) {_=region_commit(&r,4096);region_release(&r)}
        list,ok:=region_dynamic(&r,u64,capacity)
        if ok {_=region_grow(&r,&list,1);region_release(&r)}
    }
}
