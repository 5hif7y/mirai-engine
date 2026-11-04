package base

// Generational handle to an entity of one ecs.World. Only valid inside that world and that run.
Entity :: distinct Handle
ENTITY_NONE :: Entity(0)

// Persistent identity of an entity inside its scene or prefab. Zero is none.
Entity_Id :: distinct u64

// Persistent identity of an asset. Zero is none.
Asset_Id :: distinct [2]u64

// Stable identity of a name (component, field, event, method): FNV-1a 64.
// Everything saved or replicated refers to names through this hash.
name_hash :: proc "contextless" (name:string) -> u64 {
    hash:=u64(0xcbf29ce484222325)
    for i in 0..<len(name) {
        hash~=u64(name[i])
        hash*=0x100000001b3
    }
    return hash
}

hash_combine :: #force_inline proc "contextless" (a,b:u64) -> u64 {
    return a~(b+0x9e3779b97f4a7c15+(a<<6)+(a>>2))
}
