package core

import "base:runtime"

// A hash of how a type lays its values out in memory: sizes, offsets, field
// names and the same of every type it holds or points to. Two libraries of a
// project whose worlds hash the same can run on each other's memory.
type_layout_hash :: proc(info:^runtime.Type_Info) -> u64 {
    seen:=make(map[^runtime.Type_Info]bool,context.temp_allocator)
    return layout_mix(FNV_OFFSET,info,&seen)
}

// The layout of every place of a world: the place_layout_hash of each.
world_layout_hash :: proc(info:^World_Info) -> u64 {
    h:=FNV_OFFSET
    for place in Place {h=mix_u64(h,place_layout_hash(info,place))}
    return h
}

// The layout of one place of a world: its size, where each of its tables
// and storages is and how each one lays out its values.
place_layout_hash :: proc(info:^World_Info,place:Place) -> u64 {
    h:=FNV_OFFSET
    h=mix_u64(h,u64(info.sizes[place]))
    h=mix_u64(h,u64(info.aligns[place]))
    if place==.World {h=mix_u64(h,u64(info.entities))}
    for t in info.tables {
        if t.place!=place {continue}
        h=mix_string(h,t.name)
        h=mix_u64(h,u64(t.offset))
        h=mix_u64(h,type_layout_hash(t.info))
    }
    for s in info.storages {
        if s.place!=place {continue}
        h=mix_string(h,s.name)
        h=mix_u64(h,u64(s.offset))
        h=mix_u64(h,type_layout_hash(s.info))
    }
    return h
}

@(private="file") FNV_OFFSET :: u64(0xcbf29ce484222325)
@(private="file") FNV_PRIME  :: u64(0x100000001b3)

@(private="file")
mix_u64 :: proc(h,value:u64) -> u64 {
    h:=h
    for i in 0..<8 {h=(h~((value>>(u64(i)*8))&0xff))*FNV_PRIME}
    return h
}

@(private="file")
mix_string :: proc(h:u64,text:string) -> u64 {
    h:=mix_u64(h,u64(len(text)))
    for i in 0..<len(text) {h=(h~u64(text[i]))*FNV_PRIME}
    return h
}

@(private="file")
layout_mix :: proc(h:u64,info:^runtime.Type_Info,seen:^map[^runtime.Type_Info]bool) -> u64 {
    if info==nil {return mix_u64(h,0)}
    h:=mix_u64(h,u64(info.size))
    h=mix_u64(h,u64(info.align))
    // A type met again on the way down is only named: pointers can go round.
    if info in seen {return mix_u64(h,1)}
    seen[info]=true
    defer delete_key(seen,info)
    switch v in info.variant {
    case runtime.Type_Info_Named:
        h=mix_string(h,v.pkg)
        h=mix_string(h,v.name)
        h=layout_mix(h,v.base,seen)
    case runtime.Type_Info_Struct:
        h=mix_u64(h,2)
        h=mix_u64(h,u64(v.field_count))
        for i in 0..<int(v.field_count) {
            h=mix_string(h,v.names[i])
            h=mix_u64(h,u64(v.offsets[i]))
            h=layout_mix(h,v.types[i],seen)
        }
    case runtime.Type_Info_Union:
        h=mix_u64(h,3)
        h=mix_u64(h,u64(v.tag_offset))
        for variant in v.variants {h=layout_mix(h,variant,seen)}
    case runtime.Type_Info_Enum:
        h=mix_u64(h,4)
        h=layout_mix(h,v.base,seen)
        for name,i in v.names {
            h=mix_string(h,name)
            h=mix_u64(h,u64(v.values[i]))
        }
    case runtime.Type_Info_Array:
        h=mix_u64(h,5)
        h=mix_u64(h,u64(v.count))
        h=layout_mix(h,v.elem,seen)
    case runtime.Type_Info_Enumerated_Array:
        h=mix_u64(h,6)
        h=mix_u64(h,u64(v.count))
        h=layout_mix(h,v.elem,seen)
        h=layout_mix(h,v.index,seen)
    case runtime.Type_Info_Dynamic_Array:
        h=mix_u64(h,7)
        h=layout_mix(h,v.elem,seen)
    case runtime.Type_Info_Slice:
        h=mix_u64(h,8)
        h=layout_mix(h,v.elem,seen)
    case runtime.Type_Info_Pointer:
        h=mix_u64(h,9)
        h=layout_mix(h,v.elem,seen)
    case runtime.Type_Info_Multi_Pointer:
        h=mix_u64(h,10)
        h=layout_mix(h,v.elem,seen)
    case runtime.Type_Info_Map:
        h=mix_u64(h,11)
        h=layout_mix(h,v.key,seen)
        h=layout_mix(h,v.value,seen)
    case runtime.Type_Info_Bit_Set:
        h=mix_u64(h,12)
        h=layout_mix(h,v.elem,seen)
        h=layout_mix(h,v.underlying,seen)
        h=mix_u64(h,u64(v.lower))
        h=mix_u64(h,u64(v.upper))
    case runtime.Type_Info_Bit_Field:
        h=mix_u64(h,13)
        h=layout_mix(h,v.backing_type,seen)
        for i in 0..<int(v.field_count) {
            h=mix_string(h,v.names[i])
            h=mix_u64(h,u64(v.bit_offsets[i]))
            h=mix_u64(h,u64(v.bit_sizes[i]))
            h=layout_mix(h,v.types[i],seen)
        }
    case runtime.Type_Info_Integer:
        h=mix_u64(h,14)
        h=mix_u64(h,u64(v.signed))
        h=mix_u64(h,u64(v.endianness))
    case runtime.Type_Info_Float:
        h=mix_u64(h,15)
        h=mix_u64(h,u64(v.endianness))
    case runtime.Type_Info_Matrix:
        h=mix_u64(h,16)
        h=mix_u64(h,u64(v.row_count))
        h=mix_u64(h,u64(v.column_count))
        h=mix_u64(h,u64(v.layout))
        h=layout_mix(h,v.elem,seen)
    case runtime.Type_Info_Simd_Vector:
        h=mix_u64(h,17)
        h=mix_u64(h,u64(v.count))
        h=layout_mix(h,v.elem,seen)
    case runtime.Type_Info_Quaternion:
        h=mix_u64(h,18)
    case runtime.Type_Info_Complex:
        h=mix_u64(h,19)
    case runtime.Type_Info_Rune,runtime.Type_Info_String,runtime.Type_Info_Boolean,runtime.Type_Info_Any,
         runtime.Type_Info_Type_Id,runtime.Type_Info_Procedure,runtime.Type_Info_Parameters,runtime.Type_Info_Soa_Pointer,
         runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
        h=mix_u64(h,20)
    }
    return h
}
