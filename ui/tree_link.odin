package ui

// A tree whose components name other .ui files (Tree_Component.widget) as
// one set of records: the template of each of those components is the tree
// of its file, with its own components and overrides expanded, and the
// styles, variants, images, fonts and animations of the file join those of the
// tree. Overrides of an instance reach the nodes of the file by their names
// in it ("slot/icon"). A widget gives its root Box to the instance and keeps
// the bindings it declares: they read the fields of what the tree binds.

// imports: by row of components, the records of the file of each widget,
// linked already; nothing for the components of the tree itself. Returns the
// records unchanged when no component names a file. A transaction: false
// when an import is missing, does not load or has more than one root, or
// memory runs out.
tree_link :: proc(data:Tree_Data,imports:[]Tree_Data,allocator:=context.temp_allocator) -> (linked:Tree_Data,ok:bool) {
    widgets:=false
    for component in data.components {widgets|=component.widget!={}}
    if !widgets {return data,true}
    if len(imports)!=len(data.components) {return}
    components:=make([dynamic]Tree_Component,0,len(data.components),allocator)
    component_nodes:=make([dynamic]Tree_Node,allocator)
    styles:=make([dynamic]Node_Style,allocator)
    variants:=make([dynamic]Tree_Style_Variant,allocator)
    images:=make([dynamic]Tree_Image,allocator)
    fonts:=make([dynamic]Tree_Font,allocator)
    anims:=make([dynamic]Tree_Anim,allocator)
    tracks:=make([dynamic]Tree_Track,allocator)
    keys:=make([dynamic]Keyframe,allocator)
    parts:=make([dynamic]Anim,allocator)
    anim_sets:=make([dynamic]Anim_Set,allocator)
    translations:=make([dynamic]Tree_Translation,allocator)
    grid_tracks:=make([dynamic]Grid_Tracks,allocator)
    text:=make([dynamic]u8,allocator)
    grow :: proc(list:^[dynamic]$T,rows:[]T) -> bool {
        _,error:=append(list,..rows)
        return error==nil
    }
    ok=grow(&components,data.components) && grow(&component_nodes,data.component_nodes) && grow(&styles,data.styles) && grow(&variants,data.variants) &&
        grow(&images,data.images) && grow(&fonts,data.fonts) && grow(&anims,data.anims) && grow(&tracks,data.tracks) && grow(&keys,data.keys) && grow(&parts,data.parts) && grow(&anim_sets,data.anim_sets) && grow(&translations,data.translations) &&
        grow(&grid_tracks,data.grid_tracks) && grow(&text,data.text)
    if !ok {return}
    // Style 0 of a tree is what its nodes without a style use: a tree without
    // styles still has it, empty.
    if len(styles)==0 {append(&styles,Node_Style{})}
    for &component,row in components {
        if component.widget=={} {continue}
        widget:=imports[row]
        if len(widget.nodes)==0 {return {},false}
        expanded,expanded_ok:=tree_expand(widget,allocator)
        if !expanded_ok || len(expanded)==0 || expanded[0].kind!=.Box || expanded[0].parent!=-1 {return {},false}
        for node in expanded[1:] {if node.parent<0 {return {},false}}
        style_base:=u16(len(styles))
        image_base:=u16(len(images))
        font_base:=u8(len(fonts))
        set_base:=u16(len(anim_sets))
        anim_base:=Anim(len(anims))
        track_base,key_base,part_base:=u32(len(tracks)),u32(len(keys)),u32(len(parts))
        text_base,tracks_base:=u32(len(text)),u16(len(grid_tracks))
        if len(styles)+max(len(widget.styles),1)>int(max(u16)) || len(images)+len(widget.images)>int(max(u16)) || len(anim_sets)+len(widget.anim_sets)>int(max(u16)) || len(anims)+len(widget.anims)>=int(max(u16)) || FONT_TREE+len(fonts)+len(widget.fonts)>int(max(u8)) {return {},false}
        // The texts of a widget keep their ids: every instance of it shows the same translations.
        ok=grow(&styles,widget.styles) && grow(&images,widget.images) && grow(&fonts,widget.fonts) && grow(&keys,widget.keys) && grow(&text,widget.text) && grow(&grid_tracks,widget.grid_tracks)
        if len(text)>int(max(u32)) || len(grid_tracks)>int(max(u16)) {return {},false}
        for t in widget.translations {
            moved:=t
            moved.text.offset+=text_base
            _,error:=append(&translations,moved);ok&=error==nil
        }
        if len(widget.styles)==0 {_,error:=append(&styles,Node_Style{});ok&=error==nil}
        // The fonts of the file are rows after those already joined.
        for &style in styles[min(int(style_base),len(styles)):] {if style.text.font>=FONT_TREE {style.text.font+=font_base}}
        for variant in widget.variants {
            moved:=variant
            moved.style+=style_base
            if moved.patch.values.text.font>=FONT_TREE {moved.patch.values.text.font+=font_base}
            _,error:=append(&variants,moved);ok&=error==nil
        }
        for a in widget.anims {
            moved:=a
            moved.first+=track_base if a.kind==.Clip else part_base
            _,error:=append(&anims,moved);ok&=error==nil
        }
        for track in widget.tracks {
            moved:=track
            moved.first_key+=key_base
            _,error:=append(&tracks,moved);ok&=error==nil
        }
        for part in widget.parts {
            _,error:=append(&parts,part+anim_base if part!=0 else 0);ok&=error==nil
        }
        for set in widget.anim_sets {
            moved:=set
            for &played in (^[size_of(Anim_Set)/size_of(Anim)]Anim)(&moved) {if played!=0 {played+=anim_base}}
            _,error:=append(&anim_sets,moved);ok&=error==nil
        }
        first:=u32(len(component_nodes))
        for node in expanded {
            moved:=node
            moved.style+=style_base
            if moved.image!=0 {moved.image+=image_base}
            if moved.anims!=0 {moved.anims+=set_base}
            if moved.layout.tracks!=0 {moved.layout.tracks+=tracks_base}
            moved.text.offset+=text_base
            _,error:=append(&component_nodes,moved);ok&=error==nil
        }
        if !ok {return {},false}
        component.first,component.count,component.widget=first,u32(len(expanded)),{}
    }
    linked=data
    linked.components,linked.component_nodes,linked.styles,linked.variants=components[:],component_nodes[:],styles[:],variants[:]
    linked.images,linked.fonts,linked.anims,linked.tracks,linked.keys,linked.parts,linked.anim_sets=images[:],fonts[:],anims[:],tracks[:],keys[:],parts[:],anim_sets[:]
    linked.translations,linked.grid_tracks,linked.text=translations[:],grid_tracks[:],text[:]
    return linked,true
}
