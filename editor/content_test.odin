package editor

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import "mirai:ui"

@(private)
CONTENT_TEST_PLUGIN_KIND :: asset.Fourcc(u32('P')|u32('O')<<8|u32('S')<<16|u32('E')<<24)
// The browser in Folders, which these tests walk.
CONTENT_TEST_FOLDERS :: Content{view={size=CONTENT_VIEW_DEFAULT.size,show_names=true,arrangement=.Folders,chips=CONTENT_VIEW_DEFAULT.chips}}

@(private)
content_test_registry :: proc() -> asset.Registry {
    files:=make([dynamic]asset.Registry_File)
    append(&files,
        asset.Registry_File{path="Animations/run.pose",state=.Asset,kind=CONTENT_TEST_PLUGIN_KIND,id={1,9}},
        asset.Registry_File{path="Animations/walk.anim",state=.Asset,kind=asset.KIND_ANIMATION,id={1,1}},
        asset.Registry_File{path="Materials/red.mat",state=.Asset,kind=asset.KIND_MATERIAL,id={1,2}},
        asset.Registry_File{path="Meshes/box.mesh",state=.Asset,kind=asset.KIND_MESH,id={1,3}},
        asset.Registry_File{path="Meshes/nested/sphere.mesh",state=.Asset,kind=asset.KIND_MESH,id={1,4}},
        asset.Registry_File{path="Prefabs/robot.prefab",state=.Asset,kind=asset.KIND_PREFAB,id={1,5}},
        asset.Registry_File{path="Sounds/hit.sound",state=.Asset,kind=asset.KIND_SOUND,id={1,6}},
        asset.Registry_File{path="Textures/color.tex",state=.Asset,kind=asset.KIND_TEXTURE,id={1,7}},
        asset.Registry_File{path="UI/hud.ui",state=.Asset,kind=asset.KIND_UI,id={1,8}},
    )
    // Sorted by path and found by id, as a scan leaves a registry.
    registry:=asset.Registry{files=files}
    for file,at in registry.files {registry.by_id[file.id]=u32(at)}
    return registry
}

// Frees what content_test_registry made: its paths are not its own.
@(private)
content_test_registry_free :: proc(r:^asset.Registry) {
    delete(r.files);delete(r.dependencies);delete(r.by_id);delete(r.by_path);delete(r.duplicates)
}

@(private)
content_test_names :: proc(c:^Content,registry:^asset.Registry,lines:[]Content_Line) -> string {
    out:=make([dynamic]u8,context.temp_allocator)
    for line,i in lines {
        if i>0 {append(&out,' ')}
        switch line.kind {
        case .Header: append(&out,..transmute([]u8)fmt.tprintf("[%s%s]",line.name,"" if line.open else "+"))
        case .Create: append(&out,..transmute([]u8)fmt.tprintf("(%s)",string(c.create_name[:c.create_name_length])))
        case .Cards:
            for card,k in c.cards[line.first:][:line.count] {
                if k>0 {append(&out,',')}
                append(&out,..transmute([]u8)card.name)
            }
        }
    }
    return string(out[:])
}

@(private)
content_test_hash :: proc(path:string) -> u64 {return base.hash64(transmute([]u8)path)}

// The lines of a frame of the browser: what it reads of the registry, then them.
@(private)
content_test_lines :: proc(c:^Content,registry:^asset.Registry,width:f32,opened:[]asset.Fourcc=nil) -> []Content_Line {
    content_registry_read(c,registry,opened)
    return content_lines(c,registry,width,opened)
}

@(test)
content_folders_open_in_place_with_their_folders_first_and_filters_find_inside_them :: proc(t:^testing.T) {
    registry:=content_test_registry()
    defer content_test_registry_free(&registry)
    c:=CONTENT_TEST_FOLDERS
    defer core.value_free(&c,type_info_of(Content))
    lines:=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"[Recent] [Favorites+] [Animations+] [Materials+] [Meshes+] [Prefabs+] [Sounds+] [Textures+] [UI+]")
    testing.expect_value(t,c.heights[0],CONTENT_HEADER)
    // A kind of a plugin is listed while a plugin opens it as a document.
    content_flip(&c,&c.open,content_test_hash("Animations"))
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines[2:4]),"[Animations] walk")
    lines=content_test_lines(&c,&registry,280,{CONTENT_TEST_PLUGIN_KIND})
    testing.expect_value(t,content_test_names(&c,&registry,lines[2:4]),"[Animations] run,walk")
    testing.expect_value(t,lines[3].depth,u16(1))
    // The kind of a plugin has a filter of its own, which takes it alone.
    testing.expect(t,len(c.present_kinds)==1 && c.present_kinds[0]==CONTENT_TEST_PLUGIN_KIND && .Animation in c.present)
    append(&c.kinds,CONTENT_TEST_PLUGIN_KIND)
    testing.expect_value(t,content_test_names(&c,&registry,content_test_lines(&c,&registry,280,{CONTENT_TEST_PLUGIN_KIND})),"[Animations] run")
    clear(&c.kinds)
    // Its folders come before its files, one level further right.
    content_flip(&c,&c.open,content_test_hash("Animations"))
    content_flip(&c,&c.open,content_test_hash("Meshes"))
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines[4:7]),"[Meshes] [nested+] box")
    testing.expect(t,lines[5].depth==1 && lines[6].depth==1 && lines[5].parent[0]==4)
    testing.expect_value(t,c.heights[5],CONTENT_SUBHEADER)
    content_flip(&c,&c.open,content_test_hash("Meshes/nested"))
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines[4:8]),"[Meshes] [nested] sphere box")
    testing.expect(t,lines[6].depth==2 && lines[6].parent=={4,5})
    // Four columns of the first level in 280, the nearest to the size: the
    // square thumbnails grow to fill it, each in the padding of its card.
    columns,cell:=content_cells(c.view,280,1)
    testing.expectf(t,columns==4 && abs(cell-(234.0/4+2*CONTENT_PAD))<0.01,"%v %v",columns,cell)
    testing.expect(t,lines[7].top && lines[7].bottom)
    testing.expect_value(t,c.heights[7],CONTENT_GRID_TOP-CONTENT_PAD+content_card_height(c.view,cell)+CONTENT_GRID_BOTTOM-CONTENT_PAD)
    cached:=raw_data(c.lines)
    testing.expect_value(t,raw_data(content_test_lines(&c,&registry,280)),cached)
    // A search opens what holds its matches and hides the rest.
    c.filter_length=copy(c.filter[:],"SPHERE")
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"[Meshes] [nested] sphere")
    testing.expect_value(t,c.results,1)
    c.filter_length=0
    c.categories={.Mesh,.Material}
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"[Materials] red [Meshes] [nested] sphere box")
    c.categories={}
    ui_category,_:=content_category(asset.KIND_UI)
    testing.expect_value(t,ui_category,Content_Category.Ui)
    skeleton_category,_:=content_category(asset.KIND_SKELETON)
    testing.expect_value(t,skeleton_category,Content_Category.Mesh)
    _,engine:=content_category(CONTENT_TEST_PLUGIN_KIND)
    testing.expect(t,!engine)
    testing.expect(t,c.present=={.Animation,.Material,.Mesh,.Prefab,.Sound,.Texture,.Ui})
    // Only unused: what no asset references, never a scene.
    append(&registry.dependencies,registry.files[3].id)
    registry.files[5].dependency_count=1
    registry.revision+=1
    c.unused=true
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"[Animations] walk [Materials] red [Meshes] [nested] sphere [Prefabs] robot [Sounds] hit [Textures] color [UI] hud")
    clear(&registry.dependencies)
    registry.files[5].dependency_count=0
    registry.revision+=1
    // Collapse all closes Favorites too and leaves Recent as it is; Alt
    // opens every folder.
    c.unused=false
    content_collapse(&c)
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines[:3]),"[Recent] [Favorites+] [Animations+]")
    testing.expect(t,content_collapsed(&c))
    content_expand(&c,&registry)
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines[:3]),"[Recent] [Favorites] [Animations]")
    testing.expect(t,content_has(&c.open,content_test_hash("Meshes/nested")))
}

// A registry with the cover of a folder and a file at the root.
@(private)
content_test_shelves_registry :: proc() -> asset.Registry {
    files:=make([dynamic]asset.Registry_File)
    append(&files,
        asset.Registry_File{path="Meshes/box.mesh",state=.Asset,kind=asset.KIND_MESH,id={7,1}},
        asset.Registry_File{path="Meshes/cover.tex",state=.Asset,kind=asset.KIND_TEXTURE,id={7,2}},
        asset.Registry_File{path="Meshes/nested/sphere.mesh",state=.Asset,kind=asset.KIND_MESH,id={7,3}},
        asset.Registry_File{path="Prefabs/robot.prefab",state=.Asset,kind=asset.KIND_PREFAB,id={7,4}},
        asset.Registry_File{path="rock.mesh",state=.Asset,kind=asset.KIND_MESH,id={7,5}},
    )
    registry:=asset.Registry{files=files}
    for file,at in registry.files {
        registry.by_id[file.id]=u32(at)
        registry.by_path[file.path]=u32(at)
    }
    return registry
}

@(test)
content_shelves_open_folders_in_place_with_their_cover_and_count_and_recent_stays_open :: proc(t:^testing.T) {
    registry:=content_test_shelves_registry()
    defer content_test_registry_free(&registry)
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    // Recent opens and Favorites, the folders and the shelf of the root are
    // closed; the cover of a folder is not an asset of it.
    lines:=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"[Recent] [Favorites+] [Meshes+] [Prefabs+] [Assets+]")
    testing.expect(t,lines[2].count==2 && lines[2].cover==2 && lines[3].cover==0,"Meshes holds two assets and its cover")
    // A folder opens in place: its folders as shelves further right, its
    // files in line with its name, all of them.
    content_group_flip(&c,content_test_hash("Meshes"))
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines[2:5]),"[Meshes] [nested+] box")
    testing.expect(t,lines[3].depth==1 && lines[4].depth==0 && lines[3].count==1)
    content_folder_open(&c,"Meshes/nested")
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines[2:6]),"[Meshes] [nested] sphere box")
    testing.expect(t,lines[4].depth==1 && lines[4].parent=={2,3})
    // Recent shows all it has, in rows of the grid.
    c.view.size=CONTENT_SIZE_MAX
    session:=Session{content=&c}
    for at in ([]int{0,3,4}) {content_used(&session,registry.files[at].id)}
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines[:4]),"[Recent] rock,robot box [Favorites+]")
    testing.expect_value(t,lines[0].count,i32(3))
    // Collapse all leaves Recent open; expand all opens Favorites and the root too.
    content_collapse(&c)
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"[Recent] rock,robot box [Favorites+] [Meshes+] [Prefabs+] [Assets+]")
    content_favorite_toggle(&c,registry.files[3].id)
    content_expand(&c,&registry)
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines[3:]),"[Favorites] robot [Meshes] [nested] sphere box [Prefabs] robot [Assets] rock")
    content_group_flip(&c,CONTENT_RECENT_GROUP)
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines[:2]),"[Recent+] [Favorites]")
    // A search finds no cover.
    c.filter_length=copy(c.filter[:],"cover")
    testing.expect_value(t,len(content_test_lines(&c,&registry,280)),0)
    c.filter_length=0
    c.marks={}
    // Used assets come first in Recent, once; a star keeps an asset in Favorites.
    content_used(&session,registry.files[0].id)
    content_used(&session,registry.files[3].id)
    content_used(&session,registry.files[0].id)
    testing.expect(t,c.marks.recent[0]==registry.files[0].id && c.marks.recent[1]==registry.files[3].id && c.marks.recent[2]=={})
    content_favorite_toggle(&c,registry.files[3].id)
    content_favorite_toggle(&c,registry.files[4].id)
    content_favorite_toggle(&c,registry.files[3].id)
    testing.expect(t,c.marks.favorites[0]==registry.files[4].id && c.marks.favorites[1]=={} && content_favorite(&c.marks,registry.files[4].id))
    for i in 0..<CONTENT_RECENT+3 {content_used(&session,{9,u64(i)})}
    testing.expect_value(t,c.marks.recent[0],base.Asset_Id{9,CONTENT_RECENT+2})
}

@(test)
ctrl_or_shift_add_an_asset_to_the_selection_or_take_it_away :: proc(t:^testing.T) {
    c:Content
    defer core.value_free(&c,type_info_of(Content))
    a,b,d:=base.Asset_Id{1,1},base.Asset_Id{1,2},base.Asset_Id{1,3}
    content_select(&c,a,false)
    content_select(&c,b,true)
    content_select(&c,d,true)
    testing.expect(t,c.selected==d && content_selected(&c,a) && content_selected(&c,b) && content_selected_count(&c)==3)
    // Taking the last clicked away leaves the one added before it.
    content_select(&c,d,true)
    testing.expect(t,c.selected==b && !content_selected(&c,d) && content_selected_count(&c)==2)
    content_select(&c,a,true)
    testing.expect(t,c.selected==b && !content_selected(&c,a) && content_selected_count(&c)==1)
    content_unselect(&c,b)
    testing.expect(t,c.selected=={} && content_selected_count(&c)==0)
    content_select(&c,a,true)
    content_select(&c,b,true)
    content_select(&c,d,false)
    testing.expect(t,c.selected==d && content_selected_count(&c)==1,"A click alone selects it alone")
}

@(test)
content_lines_follow_registry_revisions_when_storage_and_count_are_reused :: proc(t:^testing.T) {
    root:=fmt.tprintf(".mirai/test-content-registry-%d",os.get_pid())
    if !testing.expect(t,!os.exists(root)) {return}
    if !testing.expect_value(t,os.make_directory_all(root),os.Error(nil)) {return}
    defer os.remove_all(root)
    path:=fmt.tprintf("%s/.index",root)
    source:=content_test_registry()
    defer content_test_registry_free(&source)
    source.allocator=context.allocator
    if !testing.expect(t,asset.registry_save(&source,path)) {return}
    registry:asset.Registry
    asset.registry_init(&registry,root)
    defer asset.registry_destroy(&registry)
    resize(&registry.files,len(source.files))
    testing.expect_value(t,asset.registry_load(&registry,path),asset.Error.None)
    c:=Content{categories={.Mesh},view=CONTENT_TEST_FOLDERS.view}
    defer core.value_free(&c,type_info_of(Content))
    append(&c.open,content_test_hash("Meshes"),content_test_hash("Meshes/nested"),content_test_hash("Meshes/renamed"))
    c.selected=source.files[3].id
    lines:=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"[Meshes] [nested] sphere box")
    files,count,revision:=raw_data(registry.files),len(registry.files),registry.revision
    source.files[3].path="Meshes/bar_box.mesh"
    source.files[4].path="Meshes/renamed/round_sphere.mesh"
    testing.expect(t,asset.registry_save(&source,path))
    testing.expect_value(t,asset.registry_load(&registry,path),asset.Error.None)
    testing.expect(t,raw_data(registry.files)==files && len(registry.files)==count)
    testing.expect_value(t,registry.revision,revision+1)
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"[Meshes] [renamed] round_sphere bar_box")
    testing.expect_value(t,c.selected,source.files[3].id)
    cached:=raw_data(c.lines)
    testing.expect_value(t,raw_data(content_test_lines(&c,&registry,280)),cached)
    testing.expect_value(t,asset.registry_scan(&registry),asset.Error.None)
    testing.expect_value(t,registry.revision,revision+2)
    testing.expect_value(t,len(content_test_lines(&c,&registry,280)),0)
}

@(private)
content_test_frame :: proc(s:^Session,input:ui.Input,content_view:bool=true) -> ui.Frame {
    ctx:=s.gui.ctx
    ui.frame_begin(ctx,input)
    ui.id_push(ctx,ui.Id(100))
    if ui.box(ctx,{width=ui.fixed(280),height=ui.fixed(420),direction=.Column,gap=6}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(26),align_x=.End,align_y=.Center}) {content_settings_button(s,ui.id(ctx,"content_settings_open"))}
        content_build(s,core.World_Ref{},388,280)
        content_settings_build(s,content_view)
    }
    ui.id_pop(ctx)
    return ui.frame_end(ctx)
}

@(private)
content_test_click :: proc(t:^testing.T,s:^Session,id:ui.Id,content_view:bool=true,clicks:u8=1,modifiers:ui.Modifiers={}) {
    rect,found:=ui.widget_rect(s.gui.ctx,id)
    testing.expect(t,found)
    if !found {return}
    for phase in 0..<3 {
        input:=ui.Input{size={800,600},pointer=ui.rect_center(rect),modifiers=modifiers}
        if phase==1 {input.down,input.pressed,input.clicks={.Left},{.Left},clicks}
        if phase==2 {input.released={.Left}}
        frame:=content_test_frame(s,input,content_view)
        testing.expect(t,!frame.overflow)
        testing.expect_value(t,s.gui.ctx.stats.layout_errors,u32(0))
    }
}

// A click at the middle of a rect, where no widget may be.
@(private)
content_test_click_at :: proc(t:^testing.T,s:^Session,rect:ui.Rect,modifiers:ui.Modifiers={}) {
    for phase in 0..<3 {
        input:=ui.Input{size={800,600},pointer=ui.rect_center(rect),modifiers=modifiers}
        if phase==1 {input.down,input.pressed,input.clicks={.Left},{.Left},1}
        if phase==2 {input.released={.Left}}
        _=content_test_frame(s,input)
        testing.expect_value(t,s.gui.ctx.stats.layout_errors,u32(0))
    }
}

@(private)
content_test_still :: proc(s:^Session,content_view:bool=true) {_=content_test_frame(s,{size={800,600},pointer_absent=true},content_view)}

@(test)
content_browser_opens_folders_selects_drags_stars_filters_and_searches_from_the_keyboard :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    assets:=host.Assets{registry=content_test_registry(),indexed=true}
    defer content_test_registry_free(&assets.registry)
    app:=host.App{assets=&assets}
    g:=Editor_Ui{ctx=&ctx}
    c:=CONTENT_TEST_FOLDERS
    defer core.value_free(&c,type_info_of(Content))
    selection:Selection
    info:core.World_Info
    session:=Session{app=&app,gui=&g,content=&c,selection=&selection,info=&info,headless=true}
    for _ in 0..<3 {
        frame:=content_test_frame(&session,{size={800,600},pointer_absent=true})
        testing.expect(t,!frame.overflow)
        testing.expect_value(t,ctx.stats.layout_errors,u32(0))
    }
    folder:=ui.id_derive(&ctx,100,"content_folder",int(content_test_hash("Meshes")))
    rect,found:=ui.widget_rect(&ctx,folder)
    testing.expectf(t,found && rect.w==280 && rect.h==CONTENT_HEADER,"%v",rect)
    content_test_click(t,&session,folder)
    testing.expect(t,content_has(&c.open,content_test_hash("Meshes")),"A click opens a folder in place")
    content_test_still(&session)
    asset_id:=assets.registry.files[3].id
    entry:=ui.id_derive(&ctx,100,"content_entry",int(content_test_hash(assets.registry.files[3].path)))
    rect,found=ui.widget_rect(&ctx,entry)
    // The open folder makes the list taller than its room: its bar takes a column.
    _,cell:=content_cells(c.view,280-ui.SCROLL_GUTTER,1)
    // Its row keeps the lines of its longest name.
    names:=u8(2)
    for line in c.lines {
        if line.kind!=.Cards {continue}
        for card in c.cards[line.first:][:line.count] {if card.file==3 {names=line.names}}
    }
    testing.expectf(t,found && abs(rect.w-cell)<0.01 && abs(rect.h-content_card_height(c.view,cell,names))<0.01,"%v",rect)
    content_test_click(t,&session,entry)
    testing.expect_value(t,c.selected,asset_id)
    testing.expect(t,g.drag.kind==.Asset && g.drag.asset_id==asset_id)
    g.drag={}
    // Ctrl+click adds a card to the selection, and takes it away again.
    content_flip(&c,&c.open,content_test_hash("Materials"))
    content_test_still(&session)
    material:=ui.id_derive(&ctx,100,"content_entry",int(content_test_hash(assets.registry.files[2].path)))
    content_test_click(t,&session,material,modifiers={.Primary})
    testing.expect(t,c.selected==assets.registry.files[2].id && content_selected(&c,asset_id) && content_selected_count(&c)==2 && g.drag.kind==.None)
    content_test_click(t,&session,material,modifiers={.Shift})
    testing.expect(t,c.selected==asset_id && content_selected_count(&c)==1)
    content_flip(&c,&c.open,content_test_hash("Materials"))
    content_test_still(&session)
    rect,_=ui.widget_rect(&ctx,entry)
    // The star of a card under the pointer marks it.
    star:=ui.id_derive(&ctx,100,"content_star",int(content_test_hash(assets.registry.files[3].path)))
    _=content_test_frame(&session,{size={800,600},pointer=ui.rect_center(rect)})
    content_test_click(t,&session,star)
    testing.expect(t,content_favorite(&c.marks,asset_id))
    // The filters of the families present; a click turns one on.
    chip:=ui.id_derive(&ctx,100,"content_category",int(Content_Category.Mesh)+1)
    content_test_click(t,&session,chip)
    testing.expect_value(t,c.categories,Content_Categories{.Mesh})
    content_test_click(t,&session,chip)
    testing.expect_value(t,c.categories,Content_Categories{})
    // The filter button chooses which families have a chip.
    _,texture_chip:=ui.widget_rect(&ctx,ui.id_derive(&ctx,100,"content_category",int(Content_Category.Texture)+1))
    testing.expect(t,!texture_chip,"Textures have no chip by default")
    content_test_click(t,&session,ui.id_derive(&ctx,100,"content_chips_open"))
    chips:=content_chips_popup(&g)
    content_test_still(&session)
    content_test_click(t,&session,ui.id_derive(&ctx,chips,"category",int(Content_Category.Texture)+1))
    c.categories={.Mesh}
    content_test_click(t,&session,ui.id_derive(&ctx,chips,"category",int(Content_Category.Mesh)+1))
    testing.expect(t,c.view.chips=={.Prefab,.Material,.Texture} && c.categories=={} && ui.popup_is_open(&ctx,chips),"A box keeps the menu open and the filter of a chip goes with it")
    ui.popup_close(&ctx,chips)
    content_test_still(&session)
    _,texture_chip=ui.widget_rect(&ctx,ui.id_derive(&ctx,100,"content_category",int(Content_Category.Texture)+1))
    testing.expect(t,texture_chip)
    c.view.chips=CONTENT_VIEW_DEFAULT.chips
    // Choosing the tab gives the keyboard to the search; what is typed over a
    // card searches too.
    c.focus_search=true
    content_test_still(&session)
    filter:=ui.id_derive(&ctx,100,"content_filter")
    testing.expect_value(t,ctx.edit.id,filter)
    ctx.edit={}
    ui.focus_set(&ctx,entry)
    content_test_still(&session)
    testing.expect_value(t,c.card_focus,entry)
    typed:=ui.Input{size={800,600},pointer_absent=true}
    typed.text_count=copy(typed.text[:],"bo")
    _=content_test_frame(&session,typed)
    testing.expect_value(t,string(c.filter[:c.filter_length]),"bo")
    content_test_still(&session)
    testing.expect_value(t,ctx.edit.id,filter)
    ctx.edit={}
    c.filter_length=0
    // Once the browser is not built, or a press goes to what is under the UI,
    // letters are shortcuts again.
    ui.focus_set(&ctx,entry)
    content_test_still(&session)
    for built in ([]bool{true,false}) {
        ui.frame_begin(&ctx,typed)
        testing.expect_value(t,content_typing(&c,&ctx),built)
        _=ui.frame_end(&ctx)
    }
    content_test_still(&session)
    pressed:=ui.Input{size={800,600},pointer={790,590},down={.Left},pressed={.Left},clicks=1}
    _=content_test_frame(&session,pressed)
    testing.expect(t,ctx.focus==0 && c.card_focus==0)
    _=content_test_frame(&session,{size={800,600},pointer={790,590},released={.Left}})
    // The gear: the layout is a choice that keeps the menu open; Only unused filters.
    content_test_still(&session)
    content_test_click(t,&session,ui.id_derive(&ctx,100,"content_settings_open"))
    popup:=content_settings_popup(&g)
    content_test_still(&session)
    content_test_click(t,&session,ui.id_derive(&ctx,popup,"layout",int(Content_Arrangement.Shelves)+1))
    testing.expect(t,c.view.arrangement==.Shelves && ui.popup_is_open(&ctx,popup))
    content_test_click(t,&session,ui.id_derive(&ctx,popup,"unused"))
    testing.expect(t,c.unused && !ui.popup_is_open(&ctx,popup))
    c.unused=false
    // The list of the bar under it: rows as wide as the panel.
    content_test_still(&session)
    content_test_click(t,&session,ui.id_derive(&ctx,100,"content_list_mode"))
    testing.expect_value(t,c.view.mode,Content_Mode.List)
    content_test_still(&session)
    rect,found=ui.widget_rect(&ctx,entry)
    testing.expectf(t,found && rect.h==CONTENT_ROW,"%v",rect)
    testing.expect_value(t,c.selected,asset_id)
    // Collapse all leaves Recent open.
    content_test_click(t,&session,ui.id_derive(&ctx,100,"content_collapse"))
    testing.expect(t,!c.recent_closed && !content_has(&c.open,content_test_hash("Meshes")))
    content_test_click(t,&session,ui.id_derive(&ctx,100,"content_grid"))
    testing.expect(t,c.view.mode==.Grid && c.view.size==CONTENT_VIEW_DEFAULT.size,"The grid comes back at its size")
    // Shown from a field of Details: the search empties, its folder opens and
    // it is selected with the keyboard, which the search does not take.
    c.view.arrangement=.Folders
    c.selected={}
    c.filter_length=copy(c.filter[:],"robot")
    session.ai=new(Ai)
    defer free(session.ai)
    content_reveal(&session,assets.registry.files[4].id)
    testing.expect(t,c.filter_length==0 && !c.focus_search)
    content_test_still(&session)
    testing.expect(t,c.selected==assets.registry.files[4].id && c.reveal=={} && content_has(&c.open,content_test_hash("Meshes/nested")))
    testing.expect_value(t,ctx.focus,ui.id_derive(&ctx,100,"content_entry",int(content_test_hash(assets.registry.files[4].path))))
    testing.expect(t,ctx.edit.id==0 && c.filter_length==0)
    // Without assets the gear still changes the names of Editor.
    app.assets=nil
    content_test_still(&session)
    content_test_click(t,&session,ui.id_derive(&ctx,100,"content_settings_open"))
    content_test_still(&session)
    content_test_click(t,&session,ui.id_derive(&ctx,popup,"names"))
    testing.expect(t,!c.view.show_names && !ui.popup_is_open(&ctx,popup),"An item of the menu closes it")
}

// Each step of the slider and of Ctrl+wheel changes the columns of the first
// level, and of the one under it, in any width of the panel.
@(test)
each_step_of_the_size_of_the_cards_changes_their_columns :: proc(t:^testing.T) {
    most,fewest:=content_levels(280)
    testing.expect(t,most==5 && fewest==2,"The list and four grids in the panel by default")
    testing.expect_value(t,content_level(CONTENT_VIEW_DEFAULT,280),2)
    for width:=f32(160);width<=640;width+=1 {
        most,fewest=content_levels(width)
        view:=CONTENT_VIEW_DEFAULT
        last:=[2]int{max(int),max(int)}
        for level in 0..=most-fewest+1 {
            content_level_set(&view,width,level)
            testing.expect_value(t,content_level(view,width),level)
            testing.expect_value(t,view.mode,level==0 ? Content_Mode.List : Content_Mode.Grid)
            if level==0 {continue}
            testing.expect(t,view.size>=CONTENT_SIZE_MIN && view.size<=CONTENT_SIZE_MAX)
            for depth in 0..<2 {
                columns,_:=content_cells(view,width,u16(depth))
                testing.expectf(t,columns<last[depth],"%v points, step %d, level %d: %d columns again",width,level,depth,columns)
                last[depth]=columns
            }
        }
    }
}

@(test)
ctrl_and_the_wheel_resize_the_cards_and_the_list_is_their_smallest_size :: proc(t:^testing.T) {
    view:=CONTENT_VIEW_DEFAULT
    content_zoom(&view,1)
    columns,cell:=content_cells(view,280,0)
    testing.expect(t,view.mode==.Grid && columns==3 && content_level(view,280)==3,"A notch is a step: from four columns to three")
    content_zoom(&view,100)
    testing.expect_value(t,view.size,CONTENT_SIZE_MAX)
    columns,cell=content_cells(view,280,0)
    testing.expect(t,columns==2 && cell==132+2*CONTENT_PAD,"Two columns at the largest size")
    content_zoom(&view,-100)
    testing.expect(t,view.mode==.List && view.size==CONTENT_SIZE_MAX,"Under the smallest size the grid is the list, which keeps the size")
    content_zoom(&view,-1)
    testing.expect_value(t,view.mode,Content_Mode.List)
    content_zoom(&view,0.5)
    columns,_=content_cells(view,280,0)
    testing.expect(t,view.mode==.Grid && content_level(view,280)==1 && columns==5 && view.size>=CONTENT_SIZE_MIN,"Up from the list is the grid of the most columns")
    content_view_resize(&view,CONTENT_SIZE_LIST)
    testing.expect_value(t,view.mode,Content_Mode.List)

    // In the browser Ctrl+wheel zooms.
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    assets:=host.Assets{registry=content_test_registry(),indexed=true}
    defer content_test_registry_free(&assets.registry)
    app:=host.App{assets=&assets}
    g:=Editor_Ui{ctx=&ctx}
    c:=CONTENT_TEST_FOLDERS
    defer core.value_free(&c,type_info_of(Content))
    selection:Selection
    info:core.World_Info
    session:=Session{app=&app,gui=&g,content=&c,selection=&selection,info=&info,headless=true}
    for _ in 0..<2 {content_test_still(&session)}
    header,_:=ui.widget_rect(&ctx,ui.id_derive(&ctx,100,"content_folder",int(content_test_hash("Meshes"))))
    over:=ui.Input{size={800,600},pointer=ui.rect_center(header)}
    _=content_test_frame(&session,over)
    zoom:=over
    zoom.modifiers,zoom.wheel={.Primary},{0,2}
    _=content_test_frame(&session,zoom)
    testing.expect(t,c.view.mode==.Grid && c.view.size==CONTENT_SIZE_MAX && content_level(c.view,280)==4)
    zoom.wheel={0,-10}
    _=content_test_frame(&session,zoom)
    testing.expect_value(t,c.view.mode,Content_Mode.List)
    _=content_test_frame(&session,over)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
    // The slider of the bar has a step for the list and for each grid.
    content_test_still(&session)
    track:=ui.id_derive(&ctx,ui.id_derive(&ctx,100,"content_size"),"track")
    rect,found:=ui.widget_rect(&ctx,track)
    if !testing.expect(t,found) {return}
    most,fewest:=content_levels(280)
    steps:=most-fewest+1
    for level in 0..=steps {
        at:=[2]f32{rect.x+6+(rect.w-12)*f32(level)/f32(steps),rect.y+rect.h*0.5}
        _=content_test_frame(&session,{size={800,600},pointer=at,down={.Left},pressed={.Left},clicks=1})
        _=content_test_frame(&session,{size={800,600},pointer=at,released={.Left}})
        testing.expect_value(t,content_level(c.view,280),level)
    }
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
}

@(test)
ctrl_and_the_wheel_over_create_resize_its_cards_with_those_of_the_browser :: proc(t:^testing.T) {
    view:=CONTENT_VIEW_DEFAULT
    _,cell:=content_cells(view,284,0)
    view.mode=.List
    content_zoom(&view,1)
    testing.expect(t,view.mode==.Grid && content_level(view,CONTENT_WIDTH)==1,"Up from the list Create and the browser are the grid of the most columns")

    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    app:host.App
    g:=Editor_Ui{ctx=&ctx}
    c:=CONTENT_TEST_FOLDERS
    defer core.value_free(&c,type_info_of(Content))
    selection:Selection
    session:=Session{app=&app,gui=&g,content=&c,selection=&selection,headless=true}
    frame :: proc(s:^Session,input:ui.Input) {
        ui.frame_begin(s.gui.ctx,input)
        if ui.box(s.gui.ctx,{width=ui.fixed(284),height=ui.fixed(440),direction=.Column}) {create_build(s,core.World_Ref{},440,284)}
        _=ui.frame_end(s.gui.ctx)
    }
    for _ in 0..<2 {frame(&session,{size={800,600},pointer_absent=true})}
    card,found:=ui.widget_rect(&ctx,ui.id(&ctx,"card",int(Preset.Cube)+1))
    testing.expect(t,found && abs(card.w-cell)<0.01,"A card of Create is a cell of the browser at its width")
    over:=ui.Input{size={800,600},pointer=ui.rect_center(card)}
    frame(&session,over)
    zoom:=over
    zoom.modifiers,zoom.wheel={.Primary},{0,2}
    frame(&session,zoom)
    testing.expect(t,c.view.mode==.Grid && c.view.size==CONTENT_SIZE_MAX && g.create_scroll==0,"The cards of the browser go two steps and Create does not scroll")
    frame(&session,over)
    card,_=ui.widget_rect(&ctx,ui.id(&ctx,"card",int(Preset.Cube)+1))
    testing.expect(t,card.w>cell)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
}

@(private)
CONTENT_TEST_ROBOT :: base.Asset_Id{2,1}

// An imported model: its prefab owns its mesh, its skeleton, its atlas material
// and that material's texture; the material it shares with another import is of
// its own. A part whose owner is gone is of its own too.
@(private)
content_test_parts_registry :: proc() -> asset.Registry {
    files:=make([dynamic]asset.Registry_File)
    append(&files,
        asset.Registry_File{path="Robot/MI_Robot_01.mat",state=.Asset,kind=asset.KIND_MATERIAL,id={2,2},owner=CONTENT_TEST_ROBOT},
        asset.Registry_File{path="Robot/MI_Shared.mat",state=.Asset,kind=asset.KIND_MATERIAL,id={2,3}},
        asset.Registry_File{path="Robot/SKM_Robot.mesh",state=.Asset,kind=asset.KIND_MESH,id={2,4},owner=CONTENT_TEST_ROBOT},
        asset.Registry_File{path="Robot/SK_Robot.skeleton",state=.Asset,kind=asset.KIND_SKELETON,id={2,5},owner=CONTENT_TEST_ROBOT},
        asset.Registry_File{path="Robot/T_Robot_01_D.tex",state=.Asset,kind=asset.KIND_TEXTURE,id={2,6},owner=CONTENT_TEST_ROBOT},
        asset.Registry_File{path="Robot/robot.prefab",state=.Asset,kind=asset.KIND_PREFAB,id=CONTENT_TEST_ROBOT},
        asset.Registry_File{path="Spider/spider.prefab",state=.Asset,kind=asset.KIND_PREFAB,id={3,1}},
        asset.Registry_File{path="Stray/orphan.mesh",state=.Asset,kind=asset.KIND_MESH,id={4,1},owner={9,9}},
    )
    registry:=asset.Registry{files=files}
    for file,at in registry.files {registry.by_id[file.id]=u32(at)}
    return registry
}

@(test)
content_hides_the_parts_of_an_import_in_their_folder_and_a_prefab_opens_to_its_variants :: proc(t:^testing.T) {
    registry:=content_test_parts_registry()
    defer content_test_registry_free(&registry)
    c:=CONTENT_TEST_FOLDERS
    defer core.value_free(&c,type_info_of(Content))
    append(&c.open,CONTENT_FAVORITES_GROUP,content_test_hash("Robot"),content_test_hash("Spider"),content_test_hash("Stray"))
    // The atlas material, the mesh, the skeleton and the texture are parts;
    // the material two imports share and the part without its owner show.
    lines:=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"[Recent] [Favorites] [Robot] MI_Shared,robot [Spider] spider [Stray] orphan")
    testing.expect(t,content_part(&registry,&registry.files[0]) && !content_part(&registry,&registry.files[1]) && !content_part(&registry,&registry.files[7]))
    // A prefab opens to its variants, not to its parts: without variants it has no arrow.
    owner:=c.cards[lines[3].first+1]
    testing.expect(t,!owner.holds && !c.cards[lines[3].first].holds)
    content_unfold(&c,CONTENT_TEST_ROBOT)
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines[2:4]),"[Robot] MI_Shared,robot")
    content_unfold(&c,CONTENT_TEST_ROBOT)
    // A search finds a part in its folder; Recent and Favorites list it.
    c.filter_length=copy(c.filter[:],"skm")
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"[Robot] SKM_Robot")
    testing.expect_value(t,c.results,1)
    c.filter_length=0
    session:=Session{content=&c}
    content_used(&session,registry.files[2].id)
    content_favorite_toggle(&c,registry.files[4].id)
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines[:4]),"[Recent] SKM_Robot [Favorites] T_Robot_01_D")
    testing.expect_value(t,content_test_names(&c,&registry,lines[4:6]),"[Robot] MI_Shared,robot")
    // A filter of families that leaves the owner out shows its parts in their folder.
    c.categories={.Mesh}
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"[Recent] SKM_Robot [Robot] SKM_Robot [Stray] orphan")
    c.categories={.Mesh,.Prefab}
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"[Recent] SKM_Robot [Robot] robot [Spider] spider [Stray] orphan")
    c.categories={}
    c.marks={}
    // Show parts of imports lists them in their folders too.
    c.view.show_parts=true
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines[2:5]),"[Robot] MI_Robot_01,MI_Shared,SKM_Robot,T_Robot_01_D robot")
    c.view.show_parts=false
    // Find in Content Browser of a hidden part of a prefab lists the parts in their folders.
    c.reveal=registry.files[2].id
    content_reveal_open(&c,&registry)
    testing.expect(t,c.view.show_parts && !slice.contains(c.unfolded[:],CONTENT_TEST_ROBOT))
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines[2:5]),"[Robot] MI_Robot_01,MI_Shared,SKM_Robot,T_Robot_01_D robot")
}

@(test)
content_gear_shows_the_parts_and_details_lists_them_after_the_rest :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    assets:=host.Assets{registry=content_test_parts_registry(),indexed=true}
    defer content_test_registry_free(&assets.registry)
    app:=host.App{assets=&assets}
    g:=Editor_Ui{ctx=&ctx}
    c:=CONTENT_TEST_FOLDERS
    defer core.value_free(&c,type_info_of(Content))
    ins:Inspector
    selection:Selection
    info:core.World_Info
    session:=Session{app=&app,gui=&g,content=&c,inspector=&ins,selection=&selection,info=&info,headless=true}
    append(&c.open,content_test_hash("Robot"))
    for _ in 0..<2 {content_test_still(&session)}
    mesh:=ui.id_derive(&ctx,100,"content_entry",int(content_test_hash(assets.registry.files[2].path)))
    _,found:=ui.widget_rect(&ctx,mesh)
    testing.expect(t,!found,"The mesh of the import is not in its folder")
    content_test_click(t,&session,ui.id_derive(&ctx,100,"content_settings_open"))
    content_test_still(&session)
    content_test_click(t,&session,ui.id_derive(&ctx,content_settings_popup(&g),"parts"))
    testing.expect(t,c.view.show_parts)
    content_test_still(&session)
    _,found=ui.widget_rect(&ctx,mesh)
    testing.expect(t,found,"Show parts of imports lists it")
    c.view.show_parts=false
    // Find in Content Browser gives the keyboard to the part, in its folder.
    c.reveal=assets.registry.files[2].id
    content_test_still(&session)
    testing.expect(t,c.view.show_parts)
    testing.expect_value(t,ctx.focus,ui.id_derive(&ctx,100,"content_entry",int(content_card_key(assets.registry.files[2].path,{},0))))
    testing.expect_value(t,c.selected,assets.registry.files[2].id)
    // The list of a material field of Details: None, the material of its own,
    // then the part; choosing it marks it as used.
    list_open(&session,{key=77,table=-1,kinds={0=asset.KIND_MATERIAL}},{20,20,260,40})
    frame :: proc(ctx:^ui.Context,s:^Session,input:ui.Input) {
        ui.frame_begin(ctx,input)
        list_build(s,core.World_Ref{})
        ui.frame_end(ctx)
    }
    for _ in 0..<2 {frame(&ctx,&session,{size={800,600},pointer_absent=true})}
    row,shown:=ui.widget_rect(&ctx,ui.id_derive(&ctx,list_popup(&g),"row",3))
    _,more:=ui.widget_rect(&ctx,ui.id_derive(&ctx,list_popup(&g),"row",4))
    testing.expect(t,shown && !more)
    if !shown {return}
    for phase in 0..<3 {
        input:=ui.Input{size={800,600},pointer=ui.rect_center(row)}
        if phase==1 {input.down,input.pressed={.Left},{.Left}}
        if phase==2 {input.released={.Left}}
        frame(&ctx,&session,input)
    }
    testing.expect_value(t,c.marks.recent[0],assets.registry.files[0].id)
}

@(test)
content_lists_the_clips_of_a_library_while_it_is_open_and_when_a_search_finds_them :: proc(t:^testing.T) {
    registry:=content_test_registry()
    defer content_test_registry_free(&registry)
    c:=CONTENT_TEST_FOLDERS
    defer core.value_free(&c,type_info_of(Content))
    walk:=base.Asset_Id{1,1}
    append(&c.clip_text,..transmute([]u8)string("idlerun"))
    append(&c.clips,Content_Clip{walk,0,4},Content_Clip{walk,4,3})
    append(&c.open,content_test_hash("Animations"))
    lines:=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines[2:4]),"[Animations] walk")
    testing.expect(t,c.cards[lines[3].first].holds && !c.cards[lines[3].first].open)
    content_unfold(&c,walk)
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines[2:4]),"[Animations] walk,idle,run")
    card:=c.cards[lines[3].first+1]
    testing.expect(t,card.clip==1 && card.file==c.cards[lines[3].first].file)
    content_unfold(&c,walk)
    c.filter_length=copy(c.filter[:],"RUN")
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"[Animations] walk,run")
}

@(test)
content_shelves_reveal_opens_the_shelf_of_the_root :: proc(t:^testing.T) {
    files:=make([dynamic]asset.Registry_File)
    append(&files,
        asset.Registry_File{path="Props/crate.prefab",state=.Asset,kind=asset.KIND_PREFAB,id={5,1}},
        asset.Registry_File{path="Props/crate_body.mesh",state=.Asset,kind=asset.KIND_MESH,id={5,2},owner={5,1}},
        asset.Registry_File{path="a.mesh",state=.Asset,kind=asset.KIND_MESH,id={6,4}},
        asset.Registry_File{path="b.mesh",state=.Asset,kind=asset.KIND_MESH,id={6,5}},
        asset.Registry_File{path="c.mesh",state=.Asset,kind=asset.KIND_MESH,id={6,6}},
        asset.Registry_File{path="hero.prefab",state=.Asset,kind=asset.KIND_PREFAB,id={6,1}},
        asset.Registry_File{path="hero_body.mesh",state=.Asset,kind=asset.KIND_MESH,id={6,2},owner={6,1}},
        asset.Registry_File{path="rock.mesh",state=.Asset,kind=asset.KIND_MESH,id={6,3}},
    )
    registry:=asset.Registry{files=files}
    defer content_test_registry_free(&registry)
    for file,at in registry.files {registry.by_id[file.id]=u32(at)}
    c:=CONTENT_TEST_FOLDERS
    defer core.value_free(&c,type_info_of(Content))
    c.view.arrangement=.Shelves
    // A prefab in a shelf has no arrow of its parts: it opens to its variants.
    content_folder_open(&c,"Props")
    lines:=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"[Recent] [Favorites+] [Props] crate [Assets+]")
    testing.expect(t,!c.cards[lines[3].first].holds)
    // Find in Content Browser of the part of a prefab at the root opens the
    // shelf of the root, with the parts in their folders.
    c.reveal={6,2}
    content_reveal_open(&c,&registry)
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines[4:]),"[Assets] a,b,c,hero hero_body,rock")
}

// Folders without files show while nothing filters;
// Folders without files show while nothing filters; the line of Create goes
// at the top of what its folder holds, or of the shelf of its folder.
@(test)
content_shows_empty_folders_and_the_line_of_create_inside_its_folder :: proc(t:^testing.T) {
    registry:=content_test_registry()
    defer content_test_registry_free(&registry)
    append(&registry.folders,"Animations/","Empty/","Meshes/","Meshes/nested/")
    defer delete(registry.folders)
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    c.view.arrangement=.Folders
    lines:=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"[Recent] [Favorites+] [Animations+] [Empty+] [Materials+] [Meshes+] [Prefabs+] [Sounds+] [Textures+] [UI+]")
    c.creating,c.create_kind=true,asset.KIND_MATERIAL
    c.create_folder_length=copy(c.create_folder[:],"Meshes")
    c.create_name_length=copy(c.create_name[:],"New Material")
    content_folder_open(&c,"Meshes")
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"[Recent] [Favorites+] [Animations+] [Empty+] [Materials+] [Meshes] (New Material) [nested+] box [Prefabs+] [Sounds+] [Textures+] [UI+]")
    testing.expect_value(t,lines[6].depth,u16(1))
    testing.expect_value(t,lines[5].path,"Meshes")
    // A search hides the folders without files.
    content_create_end(&c)
    c.filter_length=copy(c.filter[:],"box")
    lines=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"[Meshes] box")
    // In Shelves, at the top of its shelf: the root has one without files.
    c.filter_length=0
    c.view.arrangement=.Shelves
    c.creating,c.create_folder_length=true,0
    content_folder_open(&c,"")
    lines=content_test_lines(&c,&registry,280)
    names:=content_test_names(&c,&registry,lines)
    testing.expectf(t,names[len(names)-len("[Assets] (New Material)"):]=="[Assets] (New Material)","%s",names)
}

// A right click on a folder opens Create; its entry names the new asset in
// the folder, Enter makes it unsaved, and it comes selected and open.
@(test)
a_right_click_on_a_folder_creates_an_asset_named_in_place :: proc(t:^testing.T) {
    temporary,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-content-create-%d",temporary,os.get_pid())
    os.remove_all(root)
    defer os.remove_all(root)
    if !testing.expect_value(t,os.make_directory_all(fmt.tprintf("%s/Materials",root)),os.Error(nil)) {return}
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets}
    g:=Editor_Ui{ctx=&ctx}
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    selection:Selection
    info:core.World_Info
    session:=Session{app=&app,gui=&g,content=&c,selection=&selection,info=&info,headless=true}
    defer delete(session.asset_documents)
    for _ in 0..<3 {content_test_still(&session)}
    folder:=ui.id_derive(&ctx,100,"content_folder",int(content_test_hash("Materials")))
    rect,found:=ui.widget_rect(&ctx,folder)
    if !testing.expect(t,found,"a folder without files shows") {return}
    _=content_test_frame(&session,{size={800,600},pointer=ui.rect_center(rect),down={.Right},pressed={.Right}})
    popup:=content_create_id(&g)
    testing.expect(t,ui.popup_is_open(&ctx,popup) && string(c.create_into[:c.create_into_length])=="Materials")
    content_test_still(&session)
    content_test_click(t,&session,ui.id_derive(&ctx,popup,"create",3))
    testing.expect(t,c.creating && c.create_kind==asset.KIND_MATERIAL && string(c.create_name[:c.create_name_length])=="New Material")
    content_test_still(&session)
    testing.expect_value(t,ctx.edit.id,ui.id_derive(&ctx,100,"content_create_name"))
    _=content_test_frame(&session,{size={800,600},pointer_absent=true,keys_down={.Enter},keys_pressed={.Enter}})
    testing.expect(t,!c.creating && c.created!={})
    file,made:=asset.registry_find_path(&assets.registry,"Materials/New Material.mat")
    testing.expect(t,made && file.kind==asset.KIND_MATERIAL && !os.exists(fmt.tprintf("%s/Materials/New Material.mat",root)))
    content_test_still(&session)
    testing.expect(t,made && c.selected==file.id && c.created=={})
    testing.expect(t,len(session.asset_documents)==1 && session.asset_documents[0].id==c.selected,"its document opens")
}

@(test)
a_selection_fills_its_row_or_card_and_the_keyboard_has_a_ring_of_its_own :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    th:=&ctx.theme
    row:=asset_row_box(&ctx,1,4,true,false,false)
    testing.expect(t,row.fill==th.accent_soft && row.stroke=={},"A selected row fills, as the rows of the outliner")
    row=asset_row_box(&ctx,1,4,false,false,true)
    testing.expect(t,row.fill=={} && row.stroke==th.text,"Only the keyboard has the light ring")
    card:=asset_card_box(&ctx,1,CONTENT_VIEW_DEFAULT,60,true,false)
    testing.expect(t,card.fill==th.accent_soft && card.stroke=={} && card.radius==6 && card.padding==ui.padding_all(CONTENT_PAD))
    edge,width:=asset_frame_edge(th,false,true)
    testing.expect(t,edge==th.toggle_on_stroke && width==1,"Its thumbnail has a violet border, no light ring")
    columns,_:=content_cells(CONTENT_VIEW_DEFAULT,280,0)
    testing.expect_value(t,columns,4)
}

// The bar under the list says how many assets are selected, or how many it
// lists while none is, in the folders closed too.
@(test)
the_bar_of_the_browser_counts_the_selection_or_the_assets_listed :: proc(t:^testing.T) {
    registry:=content_test_registry()
    defer content_test_registry_free(&registry)
    c:=CONTENT_TEST_FOLDERS
    defer core.value_free(&c,type_info_of(Content))
    _=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_count_text(&c),"8 assets")
    c.filter_length=copy(c.filter[:],"SPHERE")
    _=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_count_text(&c),"1 asset")
    c.filter_length=copy(c.filter[:],"nothing")
    _=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_count_text(&c),"0 assets")
    content_select(&c,registry.files[3].id,false)
    testing.expect_value(t,content_count_text(&c),"1 selected")
    content_select(&c,registry.files[2].id,true)
    testing.expect_value(t,content_count_text(&c),"2 selected")
}

// A click where no card, row or folder is clears the selection of the
// browser; with Ctrl or Shift, or on a folder, it keeps it.
@(test)
a_click_on_the_background_of_the_browser_clears_its_selection :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    assets:=host.Assets{registry=content_test_shelves_registry(),indexed=true}
    defer content_test_registry_free(&assets.registry)
    app:=host.App{assets=&assets}
    g:=Editor_Ui{ctx=&ctx}
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    selection:Selection
    info:core.World_Info
    session:=Session{app=&app,gui=&g,content=&c,selection=&selection,info=&info,headless=true}
    append(&c.open,content_test_hash("Prefabs"))
    for _ in 0..<2 {content_test_still(&session)}
    for mode in Content_Mode {
        c.view.mode=mode
        content_test_still(&session)
        card:=ui.id_derive(&ctx,100,"content_entry",int(content_test_hash(assets.registry.files[3].path)))
        content_test_click(t,&session,card)
        testing.expect_value(t,c.selected,assets.registry.files[3].id)
        g.drag={}
        folder:=ui.id_derive(&ctx,100,"content_folder",int(content_test_hash("Meshes")))
        content_test_click(t,&session,folder)
        content_test_click(t,&session,folder)
        testing.expect_value(t,c.selected,assets.registry.files[3].id)
        area,found:=ui.widget_rect(&ctx,ui.id_derive(&ctx,100,"content_area"))
        if !testing.expect(t,found) {return}
        empty:=ui.Rect{area.x,area.y+area.h-12,area.w,8}
        for modifier in ([]ui.Modifiers{{.Primary},{.Shift}}) {
            content_test_click_at(t,&session,empty,modifier)
            testing.expect_value(t,c.selected,assets.registry.files[3].id)
        }
        content_test_click_at(t,&session,empty)
        testing.expect(t,c.selected=={} && len(c.picked)==0 && g.drag.kind==.None)
        testing.expect_value(t,content_count_text(&c),"4 assets")
    }
}

// A folder the browser was left in that is gone gives its place to the
// nearest one above it, or to the root; the folders open that are gone and
// the filters without a chip are left out.
@(test)
content_navigation_falls_to_what_the_registry_still_has :: proc(t:^testing.T) {
    registry:=content_test_registry()
    defer content_test_registry_free(&registry)
    append(&registry.folders,"Empty/")
    defer delete(registry.folders)
    c:=CONTENT_TEST_FOLDERS
    defer core.value_free(&c,type_info_of(Content))
    n:Content_Navigation
    copy(n.place[:],"Meshes/gone/deeper")
    n.categories={.Mesh,.Texture}
    n.kinds[0]=CONTENT_TEST_PLUGIN_KIND
    n.open={0=CONTENT_FAVORITES_GROUP,1=CONTENT_ROOT_GROUP,2=content_test_hash("Meshes"),3=content_test_hash("Meshes/gone"),4=content_test_hash("Empty"),5=content_test_hash("Stray")}
    content_navigation_set(&c,&n)
    content_registry_read(&c,&registry,{CONTENT_TEST_PLUGIN_KIND})
    content_navigation_restore(&c,&registry)
    testing.expect_value(t,string(c.place[:c.place_length]),"Meshes")
    testing.expect_value(t,c.categories,Content_Categories{.Mesh})
    testing.expect_value(t,len(c.kinds),0)
    testing.expect(t,slice.equal(c.open[:],[]u64{CONTENT_FAVORITES_GROUP,CONTENT_ROOT_GROUP,content_test_hash("Meshes"),content_test_hash("Empty")}))
    lines:=content_test_lines(&c,&registry,280)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"[Meshes] [nested] sphere box")
    // Nothing of it is left: the root.
    n.place={}
    copy(n.place[:],"Gone/away")
    content_navigation_set(&c,&n)
    content_navigation_restore(&c,&registry)
    testing.expect_value(t,string(c.place[:c.place_length]),"")
}
