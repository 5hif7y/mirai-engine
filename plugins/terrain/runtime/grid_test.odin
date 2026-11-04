package terrain

grid_equal :: proc(a,b:^Grid($T)) -> bool {
    if a.size!=b.size || len(a.pages)!=len(b.pages) {return false}
    for z in 0..<a.size.z {for y in 0..<a.size.y {for x in 0..<a.size.x {if grid_value(a,{x,y,z})!=grid_value(b,{x,y,z}) {return false}}}}
    return true
}
