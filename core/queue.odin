package core

// Requests: many push, the library that owns the queue takes them.
// Events: the library that owns the queue clears it and pushes; the others read items.
Queue :: struct($T:typeid) {items:[dynamic]T}

push :: proc(q:^Queue($T),item:T) {append(&q.items,item)}

// What was pushed since the last take. Valid until the next push.
take :: proc(q:^Queue($T)) -> []T {
    items:=q.items[:]
    clear(&q.items)
    return items
}

queue_clear :: proc(q:^Queue($T)) {clear(&q.items)}

// A storage read without copying it. Writing through it is a bug the
// generator cannot see: a function that writes a storage receives ^S.
Ref :: struct($S:typeid) {using ptr:^S}

ref :: #force_inline proc "contextless" (s:^$S) -> Ref(S) {return {s}}
