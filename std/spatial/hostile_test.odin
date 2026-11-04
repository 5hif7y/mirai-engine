package spatial

import "core:testing"

// Every public procedure takes whatever it is given and returns: boxes that are
// NaN, infinite, huge, tiny, empty or inverted, handles that are stale, forged
// or out of range, capacities and cell sizes out of range, structures that are
// zero, and trees whose bytes were corrupted.

@(private="file") HOSTILE_ROUNDS :: #config(SPATIAL_HOSTILE_ROUNDS,400)
@(private="file") ITERATION_LIMIT :: 100000

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

@(private="file")
hostile_f32 :: proc(h:^Hostile) -> f32 {
    switch hostile_int(h,12) {
    case 0: return f32(0h7fc00000)
    case 1: return f32(0h7f800000)
    case 2: return f32(0hff800000)
    case 3: return 1e30
    case 4: return -1e30
    case 5: return 1e-30
    case 6: return 0
    case 7: return 1
    }
    return f32(hostile_int(h,2001)-1000)/100
}

@(private="file")
hostile_vec3 :: proc(h:^Hostile,wild:bool) -> [3]f32 {
    if !wild {return {f32(hostile_int(h,201)-100)/50,f32(hostile_int(h,201)-100)/50,f32(hostile_int(h,201)-100)/50}}
    return {hostile_f32(h),hostile_f32(h),hostile_f32(h)}
}

@(private="file")
hostile_box :: proc(h:^Hostile) -> Aabb {
    switch hostile_int(h,9) {
    case 0: return {hostile_vec3(h,true),hostile_vec3(h,true)}
    case 1:
        p:=hostile_vec3(h,false)
        return {p,p}
    case 2: return {{-1e30,-1e30,-1e30},{1e30,1e30,1e30}}
    case 3: return {{-max(f32),-max(f32),-max(f32)},{max(f32),max(f32),max(f32)}}
    case 4:
        p:=hostile_vec3(h,false)
        return {p+{1,1,1},p}
    case 5:
        p:=hostile_vec3(h,false)
        return {p,p+{1e-30,1e-30,1e-30}}
    }
    c:=hostile_vec3(h,false)
    e:=hostile_vec3(h,false)
    e={abs(e.x)/4,abs(e.y)/4,abs(e.z)/4}
    return {c-e,c+e}
}

@(private="file")
hostile_valid_box :: proc(h:^Hostile) -> Aabb {
    c:=hostile_vec3(h,false)
    e:=hostile_vec3(h,false)
    e={abs(e.x)/4,abs(e.y)/4,abs(e.z)/4}
    return {c-e,c+e}
}

@(private="file")
hostile_handle :: proc(h:^Hostile,live:[]i32,high:i32) -> i32 {
    if len(live)>0 && hostile_int(h,3)!=0 {return live[hostile_int(h,len(live))]}
    switch hostile_int(h,10) {
    case 0: return -1
    case 1: return 0
    case 2: return 1
    case 3: return high
    case 4: return high+1
    case 5: return max(i32)
    case 6: return min(i32)
    case 7: return i32(hostile_int(h,max(int(high),1)))
    case 8: return -2
    }
    return 1<<30
}

@(private="file")
hostile_capacity :: proc(h:^Hostile) -> int {
    switch hostile_int(h,12) {
    case 0: return -1
    case 1: return 0
    case 2: return 1<<40
    case 3: return max(int)
    case 4: return 1
    case 5: return 2
    }
    return 4+hostile_int(h,60)
}

@(private="file")
hostile_cell_size :: proc(h:^Hostile) -> f32 {
    if hostile_int(h,10)<4 {return hostile_f32(h)}
    return f32(1+hostile_int(h,40))/10
}

@(private="file")
hostile_bounds :: proc(h:^Hostile) -> Aabb {
    switch hostile_int(h,6) {
    case 0: return {hostile_vec3(h,true),hostile_vec3(h,true)}
    case 1: return {}
    case 2:
        p:=hostile_vec3(h,false)
        return {p+{1,1,1},p}
    }
    e:=f32(1+hostile_int(h,20))
    return {{-e,-e,-e},{e,e,e}}
}

@(private="file")
hostile_grid_desc :: proc(h:^Hostile) -> Grid_Desc {
    desc:=Grid_Desc{cell_size=hostile_cell_size(h),item_capacity=hostile_capacity(h)}
    switch hostile_int(h,6) {
    case 0: desc.link_capacity=-1
    case 1: desc.link_capacity=1<<40
    case 2: desc.link_capacity=1
    case: desc.link_capacity=hostile_int(h,200)
    }
    if hostile_int(h,2)==0 {
        switch hostile_int(h,6) {
        case 0: desc.buckets=-1
        case 1: desc.buckets=1<<40
        case 2: desc.buckets=1
        case: desc.buckets=1+hostile_int(h,500)
        }
    } else {
        desc.bounds=hostile_bounds(h)
    }
    return desc
}

@(private="file")
grid_probe :: proc(t:^testing.T,g:^Grid,h:^Hostile) {
    n:=0
    q:=grid_query(g,hostile_box(h))
    for {
        _,_,ok:=grid_query_next(&q)
        if !ok {break}
        n+=1
        if n>int(g.item_count)||n>ITERATION_LIMIT {
            testing.expect(t,false,"grid query gives more items than there are")
            break
        }
    }
    n=0
    r:=grid_ray(g,hostile_vec3(h,true),hostile_vec3(h,true),hostile_f32(h))
    for {
        _,_,ok:=grid_ray_next(&r)
        if !ok {break}
        n+=1
        if n>int(g.item_count)||n>ITERATION_LIMIT {
            testing.expect(t,false,"grid ray gives more items than there are")
            break
        }
        if hostile_int(h,4)==0 {r.max_fraction=hostile_f32(h)}
    }
}

@(test)
hostile_calls_through_the_grid :: proc(t:^testing.T) {
    h:=Hostile{1}
    live:[dynamic]i32
    defer delete(live)
    for _ in 0..<HOSTILE_ROUNDS {
        g:Grid
        if !grid_init(&g,hostile_grid_desc(&h)) {
            grid_destroy(&g)
            continue
        }
        clear(&live)
        for _ in 0..<40 {
            switch hostile_int(&h,10) {
            case 0,1,2:
                item,ok:=grid_insert(&g,hostile_box(&h),hostile_next(&h))
                if ok {append(&live,item)}
            case 3: _=grid_move(&g,hostile_handle(&h,live[:],g.item_high),hostile_box(&h))
            case 4: grid_remove(&g,hostile_handle(&h,live[:],g.item_high))
            case 5: grid_probe(t,&g,&h)
            case 6: _=grid_cell(&g,hostile_vec3(&h,true))
            case 7:
                if hostile_int(&h,8)==0 {grid_clear(&g);clear(&live)}
            case 8: testing.expect(t,grid_validate(&g),"grid state is not valid")
            case 9: grid_remove(&g,hostile_handle(&h,nil,g.item_high))
            }
        }
        grid_probe(t,&g,&h)
        testing.expect(t,grid_validate(&g),"grid state is not valid")
        grid_destroy(&g)
    }
}

@(test)
hostile_handles_through_the_grid_accessors :: proc(t:^testing.T) {
    h:=Hostile{2}
    live:[dynamic]i32
    defer delete(live)
    for _ in 0..<HOSTILE_ROUNDS {
        g:Grid
        if !grid_init(&g,Grid_Desc{cell_size=1,bounds={{-5,-5,-5},{5,5,5}},item_capacity=4}) {continue}
        clear(&live)
        for _ in 0..<hostile_int(&h,6) {
            item,ok:=grid_insert(&g,hostile_valid_box(&h),1)
            if ok {append(&live,item)}
        }
        if len(live)>0 && hostile_int(&h,2)==0 {grid_remove(&g,live[0])}
        item:=hostile_handle(&h,live[:],g.item_high)
        _=grid_aabb(&g,item)
        _=grid_user(&g,item)
        grid_set_user(&g,item,7)
        grid_destroy(&g)
    }
}

@(private="file")
hostile_octree_desc :: proc(h:^Hostile) -> Octree_Desc {
    if hostile_int(h,2)==0 {return {bounds={{-10,-10,-10},{10,10,10}},item_capacity=4+hostile_int(h,60),max_depth=hostile_int(h,17),leaf_items=hostile_int(h,6),node_capacity=hostile_int(h,2)==0?0:1+hostile_int(h,100)}}
    desc:=Octree_Desc{bounds=hostile_bounds(h),item_capacity=hostile_capacity(h)}
    switch hostile_int(h,8) {
    case 0: desc.max_depth=-1
    case 1: desc.max_depth=17
    case 2: desc.max_depth=max(int)
    case 3: desc.max_depth=16
    case 4: desc.max_depth=1
    case: desc.max_depth=hostile_int(h,10)
    }
    switch hostile_int(h,6) {
    case 0: desc.leaf_items=-1
    case 1: desc.leaf_items=1
    case 2: desc.leaf_items=max(int)
    case: desc.leaf_items=hostile_int(h,10)
    }
    switch hostile_int(h,8) {
    case 0: desc.node_capacity=-1
    case 1: desc.node_capacity=1<<40
    case 2: desc.node_capacity=1
    case 3: desc.node_capacity=max(int)
    case 4: desc.node_capacity=9
    case: desc.node_capacity=hostile_int(h,100)
    }
    return desc
}

@(private="file")
octree_probe :: proc(t:^testing.T,o:^Octree,h:^Hostile) {
    n:=0
    q:=octree_query(o,hostile_box(h))
    for {
        _,_,ok:=octree_query_next(&q)
        if !ok {break}
        n+=1
        if n>int(o.item_count)||n>ITERATION_LIMIT {
            testing.expect(t,false,"octree query gives more items than there are")
            break
        }
    }
    n=0
    r:=octree_ray(o,hostile_vec3(h,true),hostile_vec3(h,true),hostile_f32(h))
    for {
        _,_,ok:=octree_ray_next(&r)
        if !ok {break}
        n+=1
        if n>int(o.item_count)||n>ITERATION_LIMIT {
            testing.expect(t,false,"octree ray gives more items than there are")
            break
        }
        if hostile_int(h,4)==0 {r.max_fraction=hostile_f32(h)}
    }
}

@(test)
hostile_calls_through_the_octree :: proc(t:^testing.T) {
    h:=Hostile{3}
    live:[dynamic]i32
    defer delete(live)
    for _ in 0..<HOSTILE_ROUNDS {
        o:Octree
        if !octree_init(&o,hostile_octree_desc(&h)) {
            octree_destroy(&o)
            continue
        }
        clear(&live)
        for _ in 0..<60 {
            switch hostile_int(&h,10) {
            case 0,1,2:
                item,ok:=octree_insert(&o,hostile_box(&h),hostile_next(&h))
                if ok {append(&live,item)}
            case 3: _=octree_move(&o,hostile_handle(&h,live[:],o.item_high),hostile_box(&h))
            case 4: octree_remove(&o,hostile_handle(&h,live[:],o.item_high))
            case 5: octree_probe(t,&o,&h)
            case 6: _=octree_node_count(&o)
            case 7:
                if hostile_int(&h,8)==0 {octree_clear(&o);clear(&live)}
            case 8: testing.expect(t,octree_validate(&o),"octree state is not valid")
            case 9: octree_remove(&o,hostile_handle(&h,nil,o.item_high))
            }
        }
        octree_probe(t,&o,&h)
        testing.expect(t,octree_validate(&o),"octree state is not valid")
        octree_destroy(&o)
    }
}

@(test)
hostile_handles_through_the_octree_accessors :: proc(t:^testing.T) {
    h:=Hostile{4}
    live:[dynamic]i32
    defer delete(live)
    for _ in 0..<HOSTILE_ROUNDS {
        o:Octree
        if !octree_init(&o,Octree_Desc{bounds={{-5,-5,-5},{5,5,5}},item_capacity=4}) {continue}
        clear(&live)
        for _ in 0..<hostile_int(&h,6) {
            item,ok:=octree_insert(&o,hostile_valid_box(&h),1)
            if ok {append(&live,item)}
        }
        if len(live)>0 && hostile_int(&h,2)==0 {octree_remove(&o,live[0])}
        item:=hostile_handle(&h,live[:],o.item_high)
        _=octree_aabb(&o,item)
        _=octree_user(&o,item)
        octree_set_user(&o,item,7)
        octree_destroy(&o)
    }
}

@(private="file")
tree_probe :: proc(t:^testing.T,tree:^Dynamic_Tree,h:^Hostile) {
    n:=0
    q:=dynamic_tree_query(tree,hostile_box(h))
    for {
        _,_,ok:=tree_query_next(&q)
        if !ok {break}
        n+=1
        if n>int(tree.proxy_count)||n>ITERATION_LIMIT {
            testing.expect(t,false,"tree query gives more proxies than there are")
            break
        }
    }
    n=0
    r:=dynamic_tree_ray(tree,hostile_vec3(h,true),hostile_vec3(h,true),hostile_f32(h))
    for {
        _,_,ok:=tree_ray_next(&r)
        if !ok {break}
        n+=1
        if n>int(tree.proxy_count)||n>ITERATION_LIMIT {
            testing.expect(t,false,"tree ray gives more proxies than there are")
            break
        }
        if hostile_int(h,4)==0 {r.max_fraction=hostile_f32(h)}
    }
    n=0
    s:=dynamic_tree_sweep(tree,hostile_box(h),hostile_vec3(h,true),hostile_f32(h))
    for {
        _,_,ok:=tree_sweep_next(&s)
        if !ok {break}
        n+=1
        if n>int(tree.proxy_count)||n>ITERATION_LIMIT {
            testing.expect(t,false,"tree sweep gives more proxies than there are")
            break
        }
    }
}

@(test)
hostile_calls_through_the_dynamic_tree :: proc(t:^testing.T) {
    h:=Hostile{5}
    live:[dynamic]i32
    defer delete(live)
    buffer:[]byte
    defer delete(buffer)
    other:Dynamic_Tree
    defer dynamic_tree_destroy(&other)
    _=dynamic_tree_init(&other,{proxy_capacity=64})
    for round in 0..<HOSTILE_ROUNDS {
        tree:Dynamic_Tree
        wild:=round%3==0
        if !dynamic_tree_init(&tree,{proxy_capacity=hostile_int(&h,3)==0?hostile_capacity(&h):1+hostile_int(&h,40),margin=hostile_f32(&h)}) {
            dynamic_tree_destroy(&tree)
            continue
        }
        clear(&live)
        for _ in 0..<60 {
            box:=wild?hostile_box(&h):hostile_valid_box(&h)
            switch hostile_int(&h,11) {
            case 0,1,2,3:
                proxy,ok:=dynamic_tree_insert(&tree,box,hostile_next(&h))
                if ok {append(&live,proxy)}
            case 4:
                if len(live)>0 {dynamic_tree_move(&tree,live[hostile_int(&h,len(live))],box)}
            case 5:
                if len(live)>0 {_=dynamic_tree_update(&tree,live[hostile_int(&h,len(live))],box,hostile_vec3(&h,wild))}
            case 6:
                if len(live)>0 {
                    at:=hostile_int(&h,len(live))
                    dynamic_tree_remove(&tree,live[at])
                    unordered_remove(&live,at)
                }
            case 7: tree_probe(t,&tree,&h)
            case 8:
                valid:=dynamic_tree_validate(&tree)
                if !wild {testing.expect(t,valid,"tree state is not valid")}
            case 9:
                _=dynamic_tree_height(&tree)
                _=dynamic_tree_area_ratio(&tree)
            case 10:
                size:=dynamic_tree_snapshot_size(&tree)
                delete(buffer)
                buffer=make([]byte,max(size+hostile_int(&h,5)-2,0))
                written,ok:=dynamic_tree_snapshot(&tree,buffer)
                if ok {
                    _,_=dynamic_tree_snapshot_check(&other,buffer[:written])
                    _,_=dynamic_tree_restore(&other,buffer[:written])
                }
            }
        }
        tree_probe(t,&tree,&h)
        if !wild {testing.expect(t,dynamic_tree_validate(&tree),"tree state is not valid")}
        dynamic_tree_clear(&tree)
        dynamic_tree_destroy(&tree)
    }
}

@(test)
hostile_proxies_through_the_tree_remove :: proc(t:^testing.T) {
    h:=Hostile{6}
    live:[dynamic]i32
    defer delete(live)
    for _ in 0..<HOSTILE_ROUNDS {
        tree:Dynamic_Tree
        if !dynamic_tree_init(&tree,{proxy_capacity=8}) {continue}
        clear(&live)
        for _ in 0..<hostile_int(&h,8) {
            proxy,ok:=dynamic_tree_insert(&tree,hostile_valid_box(&h),1)
            if ok {append(&live,proxy)}
        }
        if len(live)>0 && hostile_int(&h,2)==0 {dynamic_tree_remove(&tree,live[0])}
        dynamic_tree_remove(&tree,hostile_handle(&h,live[:],tree.node_high))
        dynamic_tree_destroy(&tree)
    }
}

@(test)
hostile_proxies_through_the_tree_move :: proc(t:^testing.T) {
    h:=Hostile{7}
    live:[dynamic]i32
    defer delete(live)
    for _ in 0..<HOSTILE_ROUNDS {
        tree:Dynamic_Tree
        if !dynamic_tree_init(&tree,{proxy_capacity=8}) {continue}
        clear(&live)
        for _ in 0..<hostile_int(&h,8) {
            proxy,ok:=dynamic_tree_insert(&tree,hostile_valid_box(&h),1)
            if ok {append(&live,proxy)}
        }
        if len(live)>0 && hostile_int(&h,2)==0 {dynamic_tree_remove(&tree,live[0])}
        dynamic_tree_move(&tree,hostile_handle(&h,live[:],tree.node_high),hostile_box(&h))
        dynamic_tree_destroy(&tree)
    }
}

@(test)
hostile_proxies_through_the_tree_update :: proc(t:^testing.T) {
    h:=Hostile{8}
    live:[dynamic]i32
    defer delete(live)
    for _ in 0..<HOSTILE_ROUNDS {
        tree:Dynamic_Tree
        if !dynamic_tree_init(&tree,{proxy_capacity=8,margin=0.1}) {continue}
        clear(&live)
        for _ in 0..<hostile_int(&h,8) {
            proxy,ok:=dynamic_tree_insert(&tree,hostile_valid_box(&h),1)
            if ok {append(&live,proxy)}
        }
        if len(live)>0 && hostile_int(&h,2)==0 {dynamic_tree_remove(&tree,live[0])}
        _=dynamic_tree_update(&tree,hostile_handle(&h,live[:],tree.node_high),hostile_box(&h),hostile_vec3(&h,true))
        dynamic_tree_destroy(&tree)
    }
}

@(test)
hostile_proxies_through_the_tree_accessors :: proc(t:^testing.T) {
    h:=Hostile{9}
    live:[dynamic]i32
    defer delete(live)
    for _ in 0..<HOSTILE_ROUNDS {
        tree:Dynamic_Tree
        if !dynamic_tree_init(&tree,{proxy_capacity=8}) {continue}
        clear(&live)
        for _ in 0..<hostile_int(&h,8) {
            proxy,ok:=dynamic_tree_insert(&tree,hostile_valid_box(&h),1)
            if ok {append(&live,proxy)}
        }
        proxy:=hostile_handle(&h,live[:],tree.node_high)
        _=dynamic_tree_aabb(&tree,proxy)
        _=dynamic_tree_user(&tree,proxy)
        dynamic_tree_set_user(&tree,proxy,7)
        dynamic_tree_destroy(&tree)
    }
}

@(test)
hostile_bytes_through_the_tree_restore :: proc(t:^testing.T) {
    h:=Hostile{10}
    source:Dynamic_Tree
    _=dynamic_tree_init(&source,{proxy_capacity=24})
    defer dynamic_tree_destroy(&source)
    for _ in 0..<20 {_,_=dynamic_tree_insert(&source,hostile_valid_box(&h),1)}
    proxy,_:=dynamic_tree_insert(&source,hostile_valid_box(&h),1)
    dynamic_tree_remove(&source,proxy)
    good:=make([]byte,dynamic_tree_snapshot_size(&source))
    defer delete(good)
    _,_=dynamic_tree_snapshot(&source,good)
    scratch:=make([]byte,len(good))
    defer delete(scratch)
    for _ in 0..<HOSTILE_ROUNDS {
        copy(scratch,good)
        for _ in 0..<1+hostile_int(&h,3) {
            at:=hostile_int(&h,len(scratch)/4)*4
            word:u32
            switch hostile_int(&h,8) {
            case 0: word=0xffffffff
            case 1: word=0
            case 2: word=1
            case 3: word=0x7fffffff
            case 4: word=0x80000000
            case 5: word=0x7fc00000
            case 6: word=u32(hostile_int(&h,30))
            case: word=u32(hostile_next(&h))
            }
            (^u32)(&scratch[at])^=word
        }
        src:=scratch[:len(scratch)-(hostile_int(&h,4)==0?hostile_int(&h,len(scratch)):0)]
        capacity:=hostile_int(&h,3)==0?1+hostile_int(&h,30):24
        dst:Dynamic_Tree
        if !dynamic_tree_init(&dst,{proxy_capacity=capacity}) {continue}
        _,_=dynamic_tree_snapshot_check(&dst,src)
        _,ok:=dynamic_tree_restore(&dst,src)
        if ok && dynamic_tree_validate(&dst) {
            tree_probe(t,&dst,&h)
            _=dynamic_tree_height(&dst)
            _=dynamic_tree_area_ratio(&dst)
            _,_=dynamic_tree_insert(&dst,hostile_valid_box(&h),1)
            testing.expect(t,dynamic_tree_validate(&dst),"tree is not valid after an insertion")
        }
        dynamic_tree_destroy(&dst)
    }
    for _ in 0..<HOSTILE_ROUNDS {
        random:=make([]byte,hostile_int(&h,200))
        for &b in random {b=u8(hostile_next(&h))}
        dst:Dynamic_Tree
        if dynamic_tree_init(&dst,{proxy_capacity=8}) {
            _,_=dynamic_tree_snapshot_check(&dst,random)
            _,_=dynamic_tree_restore(&dst,random)
            _=dynamic_tree_validate(&dst)
            dynamic_tree_destroy(&dst)
        }
        delete(random)
    }
}

@(private="file")
bvh_probe :: proc(t:^testing.T,bvh:^Bvh,h:^Hostile) {
    n:=0
    q:=bvh_query(bvh,hostile_box(h))
    for {
        primitives,ok:=bvh_query_next(&q)
        if !ok {break}
        n+=len(primitives)
        if n>len(bvh.order)||n>ITERATION_LIMIT {
            testing.expect(t,false,"bvh query gives more primitives than there are")
            break
        }
    }
    n=0
    r:=bvh_ray(bvh,hostile_vec3(h,true),hostile_vec3(h,true),hostile_f32(h))
    for {
        primitives,ok:=bvh_ray_next(&r)
        if !ok {break}
        n+=len(primitives)
        if n>len(bvh.order)||n>ITERATION_LIMIT {
            testing.expect(t,false,"bvh ray gives more primitives than there are")
            break
        }
        if hostile_int(h,4)==0 {r.max_fraction=hostile_f32(h)}
    }
    n=0
    s:=bvh_sweep(bvh,hostile_box(h),hostile_vec3(h,true),hostile_f32(h))
    for {
        primitives,ok:=bvh_sweep_next(&s)
        if !ok {break}
        n+=len(primitives)
        if n>len(bvh.order)||n>ITERATION_LIMIT {
            testing.expect(t,false,"bvh sweep gives more primitives than there are")
            break
        }
    }
}

@(private="file")
hostile_leaf_size :: proc(h:^Hostile) -> int {
    switch hostile_int(h,6) {
    case 0: return -1
    case 1: return 1
    case 2: return max(int)
    }
    return hostile_int(h,9)
}

@(test)
hostile_boxes_through_the_bvh_build :: proc(t:^testing.T) {
    h:=Hostile{11}
    boxes:[dynamic]Aabb
    defer delete(boxes)
    for round in 0..<HOSTILE_ROUNDS {
        clear(&boxes)
        wild:=round%4==0
        same:=hostile_int(&h,6)==0
        first:=hostile_valid_box(&h)
        for _ in 0..<hostile_int(&h,40) {append(&boxes,same?first:(wild?hostile_box(&h):hostile_valid_box(&h)))}
        bvh:Bvh
        ok:=bvh_build(&bvh,boxes[:],{max_leaf_size=hostile_leaf_size(&h)})
        if ok {testing.expect(t,bvh_validate(&bvh),"bvh is not valid")}
        _=bvh_bounds(&bvh)
        bvh_probe(t,&bvh,&h)
        bvh_destroy(&bvh)
        free_all(context.temp_allocator)
    }
}

@(test)
hostile_meshes_through_the_bvh_build :: proc(t:^testing.T) {
    h:=Hostile{12}
    vertices:[dynamic][3]f32
    indices:[dynamic]u32
    defer {delete(vertices);delete(indices)}
    for round in 0..<HOSTILE_ROUNDS {
        clear(&vertices);clear(&indices)
        wild:=round%4==0
        n:=hostile_int(&h,20)
        for _ in 0..<n {append(&vertices,hostile_vec3(&h,wild))}
        count:=hostile_int(&h,40)
        if hostile_int(&h,3)!=0 {count-=count%3}
        for _ in 0..<count {append(&indices,u32(hostile_int(&h,max(n,1)+(hostile_int(&h,5)==0?3:0))))}
        bvh:Bvh
        ok:=bvh_build_triangles(&bvh,vertices[:],indices[:],{max_leaf_size=hostile_leaf_size(&h)})
        if ok {testing.expect(t,bvh_validate(&bvh),"bvh is not valid")}
        bvh_probe(t,&bvh,&h)
        bvh_destroy(&bvh)
        free_all(context.temp_allocator)
    }
}

@(test)
hostile_nodes_through_the_bvh_validate :: proc(t:^testing.T) {
    h:=Hostile{13}
    boxes:[dynamic]Aabb
    defer delete(boxes)
    for _ in 0..<HOSTILE_ROUNDS {
        clear(&boxes)
        for _ in 0..<1+hostile_int(&h,30) {append(&boxes,hostile_valid_box(&h))}
        bvh:Bvh
        if !bvh_build(&bvh,boxes[:],{max_leaf_size=1+hostile_int(&h,4)}) {continue}
        for _ in 0..<1+hostile_int(&h,3) {
            word:u32
            switch hostile_int(&h,6) {
            case 0: word=0xffffffff
            case 1: word=0
            case 2: word=1
            case 3: word=u32(len(bvh.nodes))
            case: word=u32(hostile_int(&h,len(bvh.nodes)+2))
            }
            if hostile_int(&h,4)==0 {
                bvh.order[hostile_int(&h,len(bvh.order))]=word
            } else {
                node:=&bvh.nodes[hostile_int(&h,len(bvh.nodes))]
                if hostile_int(&h,2)==0 {node.first=word} else {node.count=word}
            }
        }
        if bvh_validate(&bvh) {bvh_probe(t,&bvh,&h)}
        bvh_destroy(&bvh)
        free_all(context.temp_allocator)
    }
}

@(test)
hostile_boxes_through_the_segment_tests :: proc(t:^testing.T) {
    h:=Hostile{14}
    for _ in 0..<HOSTILE_ROUNDS {
        a,b:=hostile_box(&h),hostile_box(&h)
        _=aabb_area(a)
        _=aabb_center(a)
        _=aabb_extents(a)
        _=aabb_translate_extend(a,hostile_vec3(&h,true))
        _=aabb_valid(a)
        _,_=aabb_ray(a,hostile_vec3(&h,true),hostile_vec3(&h,true),hostile_f32(&h))
        _,_=aabb_sweep(a,b,hostile_vec3(&h,true),hostile_f32(&h))
    }
}

@(test)
hostile_calls_through_empty_structures :: proc(t:^testing.T) {
    h:=Hostile{15}
    for _ in 0..<HOSTILE_ROUNDS/8 {
        g:Grid
        _,_=grid_insert(&g,hostile_box(&h),0)
        _=grid_move(&g,hostile_handle(&h,nil,0),hostile_box(&h))
        grid_remove(&g,hostile_handle(&h,nil,0))
        _=grid_cell(&g,hostile_vec3(&h,true))
        grid_probe(t,&g,&h)
        _=grid_validate(&g)
        grid_clear(&g)
        grid_destroy(&g)
        o:Octree
        _,_=octree_insert(&o,hostile_box(&h),0)
        _=octree_move(&o,hostile_handle(&h,nil,0),hostile_box(&h))
        octree_remove(&o,hostile_handle(&h,nil,0))
        octree_probe(t,&o,&h)
        _=octree_validate(&o)
        octree_clear(&o)
        octree_destroy(&o)
        tree:Dynamic_Tree
        _,_=dynamic_tree_insert(&tree,hostile_box(&h),0)
        tree_probe(t,&tree,&h)
        _=dynamic_tree_validate(&tree)
        _=dynamic_tree_height(&tree)
        _=dynamic_tree_area_ratio(&tree)
        _=dynamic_tree_snapshot_size(&tree)
        _,_=dynamic_tree_snapshot(&tree,nil)
        _,_=dynamic_tree_snapshot_check(&tree,nil)
        _,_=dynamic_tree_restore(&tree,nil)
        dynamic_tree_clear(&tree)
        dynamic_tree_destroy(&tree)
        bvh:Bvh
        bvh_probe(t,&bvh,&h)
        _=bvh_validate(&bvh)
        _=bvh_bounds(&bvh)
        bvh_destroy(&bvh)
        _=bvh_build(&bvh,nil,{})
        _=bvh_build_triangles(&bvh,nil,nil,{})
        bvh_destroy(&bvh)
    }
}

@(test)
hostile_nested_boxes_through_every_structure :: proc(t:^testing.T) {
    h:=Hostile{16}
    for count in ([?]int{70,150,300}) {
        boxes:=make([]Aabb,count)
        defer delete(boxes)
        for &box,i in boxes {
            e:=f32(i+1)
            box={{-e,-e,-e},{e,e,e}}
        }
        tree:Dynamic_Tree
        _=dynamic_tree_init(&tree,{proxy_capacity=count})
        for box in boxes {_,_=dynamic_tree_insert(&tree,box,1)}
        testing.expect(t,dynamic_tree_validate(&tree),"nested tree is not valid")
        for _ in 0..<HOSTILE_ROUNDS/8 {tree_probe(t,&tree,&h)}
        dynamic_tree_destroy(&tree)
        bvh:Bvh
        if bvh_build(&bvh,boxes,{}) {testing.expect(t,bvh_validate(&bvh),"nested bvh is not valid")}
        for _ in 0..<HOSTILE_ROUNDS/8 {bvh_probe(t,&bvh,&h)}
        bvh_destroy(&bvh)
        o:Octree
        _=octree_init(&o,{bounds={{-400,-400,-400},{400,400,400}},item_capacity=count,max_depth=16})
        for box in boxes {_,_=octree_insert(&o,box,1)}
        testing.expect(t,octree_validate(&o),"nested octree is not valid")
        for _ in 0..<HOSTILE_ROUNDS/8 {octree_probe(t,&o,&h)}
        octree_destroy(&o)
        g:Grid
        _=grid_init(&g,{cell_size=8,bounds={{-400,-400,-400},{400,400,400}},item_capacity=count,link_capacity=count*100})
        for box in boxes {_,_=grid_insert(&g,box,1)}
        testing.expect(t,grid_validate(&g),"nested grid is not valid")
        for _ in 0..<HOSTILE_ROUNDS/8 {grid_probe(t,&g,&h)}
        grid_destroy(&g)
    }
}

@(test)
hostile_node_count_of_a_zero_octree :: proc(t:^testing.T) {
    o:Octree
    _=octree_node_count(&o)
}
