package api

import "mirai:std/base"
import "mirai:std/serial"

// The pieces of JSON that methods write by hand into their results.

// A key of an object, after a comma unless it is the first.
write_key :: proc(w:^serial.Writer,key:string,first:=false) {
    if !first {serial.write_u8(w,',')}
    serial.text_write_string(w,key)
    serial.write_u8(w,':')
}

write_text :: proc(w:^serial.Writer,key,text:string,first:=false) {write_key(w,key,first);serial.text_write_string(w,text)}
write_int :: proc(w:^serial.Writer,key:string,value:i64,first:=false) {write_key(w,key,first);serial.text_write_int(w,value)}
write_uint :: proc(w:^serial.Writer,key:string,value:u64,first:=false) {write_key(w,key,first);serial.text_write_uint(w,value)}
write_bool :: proc(w:^serial.Writer,key:string,value:bool,first:=false) {write_key(w,key,first);write_flag(w,value)}
write_flag :: proc(w:^serial.Writer,value:bool) {serial.text_write_raw(w,value?"true":"false")}

// A number as the engine writes an f32: the shortest text that reads back the same value.
write_number :: proc(w:^serial.Writer,value:f32) {serial.text_write_float(w,u64(transmute(u32)value),4)}

write_list :: proc(w:^serial.Writer,values:[]f32) {
    serial.write_u8(w,'[')
    for value,i in values {
        if i>0 {serial.write_u8(w,',')}
        write_number(w,value)
    }
    serial.write_u8(w,']')
}

write_numbers :: proc{write_numbers_list,write_numbers_vector}
write_numbers_list :: proc(w:^serial.Writer,key:string,values:[]f32,first:=false) {write_key(w,key,first);write_list(w,values)}
write_numbers_vector :: proc(w:^serial.Writer,key:string,value:[3]f32,first:=false) {
    value:=value
    write_numbers_list(w,key,value[:],first)
}

// An id of the document, as a quoted hexadecimal string.
write_id :: proc(w:^serial.Writer,id:base.Entity_Id) {
    serial.write_u8(w,'"')
    serial.text_write_hex(w,u64(id))
    serial.write_u8(w,'"')
}
