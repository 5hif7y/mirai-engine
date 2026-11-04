package editor

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import "mirai:ui"

// The families of the kinds of the engine the filters of the browser take, in
// the order they show; each kind of a plugin it lists has a filter of its own
// after them.
Content_Category :: enum u8 {Prefab,Mesh,Material,Texture,Animation,Scene,Sound,Ui}
Content_Categories :: bit_set[Content_Category;u16]

CONTENT_CATEGORY_LABELS :: [Content_Category]string{.Prefab="Prefab",.Mesh="Model",.Material="Material",.Texture="Texture",.Animation="Animation",.Scene="Scene",.Sound="Sound",.Ui="UI"}
// The kind whose color a filter carries.
CONTENT_CATEGORY_KINDS :: [Content_Category]asset.Fourcc{.Prefab=asset.KIND_PREFAB,.Mesh=asset.KIND_MESH,.Material=asset.KIND_MATERIAL,.Texture=asset.KIND_TEXTURE,.Animation=asset.KIND_ANIMATION,.Scene=asset.KIND_SCENE,.Sound=asset.KIND_SOUND,.Ui=asset.KIND_UI}
CONTENT_ROW :: f32(28)       // a row of the list
CONTENT_HEADER :: f32(28)    // a folder of the first level, Recent and Favorites
CONTENT_SUBHEADER :: f32(24) // a folder inside another
CONTENT_COVER :: f32(22)     // the cover of a folder beside its name
CONTENT_FOOTER :: f32(28)    // the bar under the list
CONTENT_INDENT :: f32(14)    // what a level moves to the right
CONTENT_INSET :: f32(4)      // of the first level from the edge
CONTENT_GAP :: f32(8)        // between two thumbnails
CONTENT_ROW_GAP :: f32(12)   // from a name to the thumbnails of the next row
CONTENT_GRID_TOP :: f32(8)   // above the first row of the cards of a folder
CONTENT_GRID_BOTTOM :: f32(8) // under the last
CONTENT_BAR :: f32(2)        // the line of the color of its type under a thumbnail
CONTENT_PAD :: f32(4)        // of a card around its thumbnail and its name: the fill of its selection
CONTENT_RING_WIDTH :: f32(1.5) // the ring of the keyboard
CONTENT_CELL_GAP :: CONTENT_GAP-2*CONTENT_PAD // between two cards
CONTENT_NAME_LINE :: f32(13) // a line of the name under a card
CONTENT_FRAME :: ui.Color{34,37,45,255}      // under a thumbnail
CONTENT_FRAME_EDGE :: ui.Color{46,49,59,255} // its border
CONTENT_SIZE_MIN :: f32(40)  // a grid of smaller cards is the list
CONTENT_SIZE_MAX :: f32(128) // two columns of the panel
CONTENT_SIZE_LIST :: CONTENT_SIZE_MIN-8 // the end of the slider that shows the list
CONTENT_WIDTH :: f32(280)    // of the browser in its panel by default
CONTENT_RECENT :: 12
CONTENT_FAVORITES :: 64
CONTENT_CHIP_KINDS :: 8      // kinds of plugins with a chip
CONTENT_OPEN_KEPT :: 256     // folders open that the file of the project keeps
// Groups that are not folders, among the hashes of the paths of folders.
CONTENT_RECENT_GROUP :: u64(1)
CONTENT_FAVORITES_GROUP :: u64(2)
CONTENT_ROOT_GROUP :: u64(3) // the files at the root of the assets, in Shelves
CONTENT_COVER_NAME :: "cover" // a texture of this name is the cover of its folder, not an asset of the browser
STAR_COLOR :: ui.Color{243,196,90,255}

// The color of each type of asset, as Unreal draws its own: the border and the
// line under its thumbnail, its filter and its fields in Details.
asset_color :: proc "contextless" (kind:asset.Fourcc) -> ui.Color {
    switch kind {
    case asset.KIND_PREFAB:        return {63,126,255,255}  // Blueprint
    case asset.KIND_MESH:          return {0,255,255,255}   // Static Mesh
    case asset.KIND_SKELETON:      return {105,181,205,255} // Skeleton
    case asset.KIND_FRACTURE:      return {180,120,110,255} // Geometry Collection
    case asset.KIND_PHYSICS_CACHE: return {255,127,40,255}  // Chaos Cache Collection
    case asset.KIND_MATERIAL:      return {64,192,64,255}   // Material
    case asset.KIND_TEXTURE:       return {192,64,64,255}   // Texture
    case asset.KIND_ANIMATION:     return {80,123,72,255}   // Animation Sequence
    case asset.KIND_SCENE:         return {255,156,0,255}   // Level
    case asset.KIND_SOUND:         return {97,85,212,255}   // Sound Wave
    case asset.KIND_SOUND_SET:     return {120,105,230,255} // Sound Cue
    case asset.KIND_UI:            return {44,89,180,255}   // Widget Blueprint
    case asset.KIND_FONT:          return {176,120,80,255}  // Font
    case asset.KIND_STRINGS:       return {148,129,224,255} // String Table
    case asset.KIND_PROMPTS:       return {220,96,140,255}
    case asset.KIND_RECORDS:       return {130,170,100,255} // Data Table
    }
    return {128,131,143,255}
}

// The color of a kind of the engine or of a plugin.
asset_kind_color :: proc(s:^Session,kind:asset.Fourcc) -> ui.Color {
    if declared:=asset_plugin_kind(s,kind);declared!=nil {return declared.color}
    return asset_color(kind)
}

// The color of an asset of the registry: that of its type, and that of a
// Skeletal Mesh for a mesh on a skeleton.
asset_file_color :: proc(s:^Session,file:^asset.Registry_File) -> ui.Color {
    if file.kind==asset.KIND_MESH && asset.registry_skeleton(&s.app.assets.registry,file)!={} {return {241,163,241,255}}
    return asset_kind_color(s,file.kind)
}

// The icon of a kind of the engine or of a plugin, with its color.
asset_icon :: proc(s:^Session,kind:asset.Fourcc) -> (icon:ui.Icon,color:ui.Color) {
    color=asset_kind_color(s,kind)
    if declared:=asset_plugin_kind(s,kind);declared!=nil {return declared.icon,color}
    switch kind {
    case asset.KIND_PREFAB:        icon=.Prefab
    case asset.KIND_MESH:          icon=.Mesh
    case asset.KIND_MATERIAL:      icon=.Sphere
    case asset.KIND_TEXTURE:       icon=.Texture
    case asset.KIND_SCENE:         icon=.Scene
    case asset.KIND_ANIMATION:     icon=.Rotate
    case asset.KIND_SOUND,asset.KIND_SOUND_SET: icon=.Sound
    case asset.KIND_SKELETON:      icon=.Axis
    case asset.KIND_UI:            icon=.Layers
    case asset.KIND_FRACTURE:      icon=.Collider
    case asset.KIND_PHYSICS_CACHE: icon=.History
    case asset.KIND_FONT:          icon=.Edit
    case asset.KIND_STRINGS:       icon=.Split
    case asset.KIND_PROMPTS:       icon=.Target
    case asset.KIND_RECORDS:       icon=.Rows
    case:                          icon=.Cube
    }
    return
}

// The type of an asset as a row of the list says it, of the engine or of a plugin.
asset_kind_label :: proc(s:^Session,kind:asset.Fourcc) -> string {
    if declared:=asset_plugin_kind(s,kind);declared!=nil {return declared.label}
    return asset_type_label(kind)
}

asset_type_label :: proc(kind:asset.Fourcc) -> string {
    switch kind {
    case asset.KIND_PREFAB:        return "Prefab"
    case asset.KIND_MESH:          return "Mesh"
    case asset.KIND_MATERIAL:      return "Material"
    case asset.KIND_TEXTURE:       return "Texture"
    case asset.KIND_SCENE:         return "Scene"
    case asset.KIND_ANIMATION:     return "Animation"
    case asset.KIND_SKELETON:      return "Skeleton"
    case asset.KIND_SOUND:         return "Sound"
    case asset.KIND_SOUND_SET:     return "Sound set"
    case asset.KIND_UI:            return "UI"
    case asset.KIND_FRACTURE:      return "Fracture"
    case asset.KIND_PHYSICS_CACHE: return "Physics cache"
    case asset.KIND_FONT:          return "Font"
    case asset.KIND_STRINGS:       return "Texts"
    case asset.KIND_PROMPTS:       return "Prompts"
    case asset.KIND_RECORDS:       return "Records"
    }
    return "Asset"
}

// The family of a kind of the engine; engine is false for a kind of a plugin.
content_category :: proc "contextless" (kind:asset.Fourcc) -> (category:Content_Category,engine:bool) {
    switch kind {
    case asset.KIND_PREFAB:   return .Prefab,true
    case asset.KIND_MESH,asset.KIND_SKELETON,asset.KIND_FRACTURE,asset.KIND_PHYSICS_CACHE: return .Mesh,true
    case asset.KIND_MATERIAL: return .Material,true
    case asset.KIND_TEXTURE:  return .Texture,true
    case asset.KIND_ANIMATION:return .Animation,true
    case asset.KIND_SCENE:    return .Scene,true
    case asset.KIND_SOUND,asset.KIND_SOUND_SET: return .Sound,true
    case asset.KIND_UI,asset.KIND_FONT,asset.KIND_STRINGS,asset.KIND_PROMPTS: return .Ui,true
    }
    return {},false
}

Content_Mode :: enum u8 {Grid,List}
// Folders: what a folder holds goes a level further right than its name.
// Shelves: in line with it, under a name with its cover and its count, and
// the files of the root in a shelf of their own.
Content_Arrangement :: enum u8 {Folders,Shelves}

// How the content browser shows the assets, as the editor keeps it between
// sessions (preferences.odin).
Content_View :: struct {
    mode:Content_Mode, // the size decides it: under CONTENT_SIZE_MIN the grid is the list
    size:f32,          // of a card of the grid, points: CONTENT_SIZE_MIN to CONTENT_SIZE_MAX
    show_names:bool,
    show_parts:bool,   // the parts of imports show in their folders too (content_part)
    arrangement:Content_Arrangement,
    chips:Content_Categories, // the families with a chip under the search
    chip_kinds:[CONTENT_CHIP_KINDS]asset.Fourcc, // the kinds of plugins with one; a zero ends them
}

CONTENT_VIEW_DEFAULT :: Content_View{size=64,show_names=true,arrangement=.Shelves,chips={.Prefab,.Mesh,.Material}}

// What a user marks in the browser of a project, kept in its .mirai folder
// (preferences.odin), by id: a file that moves keeps its marks.
Content_Marks :: struct {
    recent:[CONTENT_RECENT]base.Asset_Id,      // the last used first; a zero ends them
    favorites:[CONTENT_FAVORITES]base.Asset_Id,
}

// Where the browser of a project was left, as the file of its marks keeps it
// (preferences.odin): written from Content and read back into it. The search
// is not kept: it is what is being looked for now.
Content_Navigation :: struct {
    place:[API_PATH_BYTES]u8 `mirai:"text"`, // Content.place
    categories:Content_Categories,
    kinds:[CONTENT_CHIP_KINDS]asset.Fourcc, // a zero ends them
    unused:bool,
    recent_closed:bool,
    open:[CONTENT_OPEN_KEPT]u64, // Content.open; a zero ends them
}

// A clip of a library: an .anim and the name of one of its clips in Content.clip_text.
Content_Clip :: struct {
    library:base.Asset_Id,
    start,length:u32,
}

// A part of an import (owner) as Registry.files has it (file), sorted by owner.
@(private)
Content_Part :: struct {
    owner:base.Asset_Id,
    file:i32,
}

// A card of the grid or a row of the list.
@(private)
Content_Card :: struct {
    file:i32,     // of Registry.files
    clip:i32,     // of Content.clips +1: a clip of the library of file; 0: the file itself
    name:string,  // inside a path of the registry or Content.clip_text: valid until either changes
    holds:bool,   // an .anim with clips or the owner of parts: an arrow shows them (open)
    open:bool,
    part:bool,    // shown after its owner
}

@(private)
Content_Line_Kind :: enum u8 {Header,Cards,Create}

// A line of the browser, of a height of Content.heights.
@(private)
Content_Line :: struct {
    kind:Content_Line_Kind,
    depth:u16,       // a header: its level; cards: the level of what holds them
    open:bool,       // a header
    group:u64,       // the hash of the path of the folder it is or is in, or a CONTENT_*_GROUP
    name:string,     // a header
    path:string,     // a header of a folder: its path under the assets, without the slash at its end
    first,count:i32, // cards: of Content.cards; a header: count is the assets under it
    top,bottom:bool, // cards: the first and the last row of a grid, with room above or under it
    cover:i32,       // a header in Shelves: its cover in Registry.files +1; 0: none
    names:u8,        // cards of a grid with names: the lines the longest name of the row takes, 1 or 2; 0: 2
    parent:[2]i32,   // the headers of the first two levels above it: they stay on top while it scrolls; -1: none
}

// A file of the registry, or a folder of it (index -1, its path with the slash at its end).
@(private)
Content_Entry :: struct {path:string,index:i32}

@(storage)
Content :: struct {
    filter:[64]u8,
    filter_length:int,
    categories:Content_Categories, // none, and no kind in kinds: all of them
    kinds:[dynamic]asset.Fourcc,   // the kinds of plugins the filters take
    unused:bool,                   // only the assets nothing references
    view:Content_View,
    marks:Content_Marks,
    selected:base.Asset_Id,        // the last clicked
    selected_clip:i32,             // of selected, as Content_Card.clip
    picked:[dynamic]base.Asset_Id, // selected too, with Ctrl or Shift
    scroll:f32,
    open:[dynamic]u64,             // folders open, as hashes of their paths; Favorites and the shelf of the root
    recent_closed:bool,
    lines:[dynamic]Content_Line,
    heights:[dynamic]f32,
    cards:[dynamic]Content_Card,
    key:[10]u64,
    revision:u64,
    results:int,                   // the assets listed outside Recent and Favorites, in folders open or not
    present:Content_Categories,    // those the registry has
    present_kinds:[dynamic]asset.Fourcc, // the kinds of plugins listed that the registry has
    referenced:[dynamic]base.Asset_Id, // sorted: what an asset depends on
    registry_key:[3]u64,
    parts:[dynamic]Content_Part,   // of the registry, read with what is referenced
    variants:[dynamic]Content_Part, // of the prefabs of the registry: a prefab whose base is the owner
    clips:[dynamic]Content_Clip,   // of the libraries of the registry
    clip_text:[dynamic]u8,
    clips_key:[2]u64,              // revisions of the registry and of the assets they were read at
    unfolded:[dynamic]base.Asset_Id, // libraries whose clips show and owners whose parts show
    focus_search:bool,             // the search takes the keyboard on the next frame
    card_focus:ui.Id,              // the card that had the keyboard when the browser was last built
    focus_asset:base.Asset_Id,     // the asset of card_focus; zero for a clip of a library
    reveal:base.Asset_Id,          // shown, selected and focused on the next frame
    menu:base.Asset_Id,            // the asset whose card opened the menu
    place:[API_PATH_BYTES]u8,      // the folder of what was clicked last: where the + of Create makes what it makes
    place_length:int,
    create_into:[API_PATH_BYTES]u8, // the folder the menu of Create makes in
    create_into_length:int,
    create_on_folder:bool,         // the menu of Create opened on the folder create_into: it also renames, copies and moves it
    creating:bool,                 // a line names what Create makes in create_folder
    create_kind:asset.Fourcc,
    create_record:int,             // of a .records: its type, in World_Info.records
    create_folder:[API_PATH_BYTES]u8,
    create_folder_length:int,
    create_name:[ASSET_CREATE_NAME]u8,
    create_name_length:int,
    create_edit:bool,              // the name takes the keyboard on the next frame
    created:base.Asset_Id,         // made by Create: selected and opened once the registry has it
    rename:[API_PATH_BYTES]u8,     // the asset or folder the line renames instead of making one; empty: it makes one
    rename_length:int,
    renaming:base.Asset_Id,        // of the asset it renames; zero for a folder
    restore:bool,                  // the navigation was read from the project: checked against the registry when the browser is built
}

CONTENT_DEFAULT :: Content{view=CONTENT_VIEW_DEFAULT}

// The cards of the browser at a size: the grid under CONTENT_SIZE_MIN is
// the list.
content_view_resize :: proc(view:^Content_View,size:f32) {
    if size<CONTENT_SIZE_MIN {
        view.mode=.List
        return
    }
    view.mode,view.size=.Grid,min(size,CONTENT_SIZE_MAX)
}

// The size of a name under a card of size points, from the size at the
// default card: it grows with the cards and never gets smaller.
content_name_font :: proc "contextless" (font,size:f32) -> f32 {
    return max(font,font*size/CONTENT_VIEW_DEFAULT.size)
}

// The steps of the cards in a width of the browser: the list (0), then one
// for each count of columns of the first level, from the most whose cards are
// not under CONTENT_SIZE_MIN to those of CONTENT_SIZE_MAX, so that each step
// changes the layout, of the levels under the first too.
@(private)
content_levels :: proc(width:f32) -> (most,fewest:int) {
    room:=max(width-CONTENT_INSET*2,1)
    fewest,_=content_cells({size=CONTENT_SIZE_MAX},width,0)
    most=max(int((room+CONTENT_GAP)/(CONTENT_SIZE_MIN+CONTENT_GAP)),fewest)
    return
}

// The step of the cards of a view in a width, of content_levels.
@(private)
content_level :: proc(view:Content_View,width:f32) -> int {
    if view.mode==.List {return 0}
    most,fewest:=content_levels(width)
    columns,_:=content_cells(view,width,0)
    return most-clamp(columns,fewest,most)+1
}

// The cards of a step in a width: the list keeps the size of the grid; a
// step of the grid takes the size whose columns fill the width exactly.
@(private)
content_level_set :: proc(view:^Content_View,width:f32,level:int) {
    if level<=0 {
        view.mode=.List
        return
    }
    most,fewest:=content_levels(width)
    columns:=max(most-level+1,fewest)
    room:=max(width-CONTENT_INSET*2,1)
    content_view_resize(view,clamp((room+CONTENT_GAP)/f32(columns)-CONTENT_GAP,CONTENT_SIZE_MIN,CONTENT_SIZE_MAX))
}

// notches of Ctrl+wheel over the browser of a width: each one a step of
// content_level, up to larger cards; the list is the smallest.
content_zoom :: proc(view:^Content_View,notches:f32,width:f32=CONTENT_WIDTH) {
    if notches==0 {return}
    steps:=int(math.round(notches))
    if steps==0 {steps=1 if notches>0 else -1}
    most,fewest:=content_levels(width)
    content_level_set(view,width,clamp(content_level(view^,width)+steps,0,most-fewest+1))
}

// The columns of the cards of a level in a width of the panel and the side
// of each card: square thumbnails as near the size of the view as the width
// lets, CONTENT_GAP apart, each in the padding of its card, which takes the
// gaps and the inset.
@(private)
content_cells :: proc(view:Content_View,width:f32,depth:u16) -> (columns:int,cell:f32) {
    room:=max(width-CONTENT_INSET*2-f32(depth)*CONTENT_INDENT,1)
    if view.mode==.List {return 1,room}
    columns=max(int(math.round((room+CONTENT_GAP)/(view.size+CONTENT_GAP))),1)
    cell=max((room-f32(columns-1)*CONTENT_GAP)/f32(columns),1)+2*CONTENT_PAD
    return
}

// The height of a card of a cell: its thumbnail and the lines of the name
// under it, in its padding.
@(private)
content_card_height :: proc(view:Content_View,cell:f32,names:u8=2) -> f32 {
    if view.mode==.List {return CONTENT_ROW}
    if view.show_names {return cell+5+f32(names if names>0 else 2)*CONTENT_NAME_LINE+2}
    return cell
}

// The room above a row of cards: more over the first row of a grid.
@(private)
content_line_top :: proc(view:Content_View,line:Content_Line) -> f32 {
    return CONTENT_GRID_TOP-CONTENT_PAD if line.top && view.mode==.Grid else 0
}

@(private)
content_line_height :: proc(view:Content_View,line:Content_Line,width:f32) -> f32 {
    switch line.kind {
    case .Header: return CONTENT_HEADER if line.depth==0 else CONTENT_SUBHEADER
    case .Create: return CONTENT_ROW+2
    case .Cards:
        if view.mode==.List {return CONTENT_ROW+2}
        _,cell:=content_cells(view,width,line.depth)
        // To the thumbnails of the next row, or to what follows the grid.
        after:=CONTENT_ROW_GAP-2*CONTENT_PAD if view.show_names else CONTENT_CELL_GAP
        if line.bottom {after=CONTENT_GRID_BOTTOM-CONTENT_PAD}
        return content_line_top(view,line)+content_card_height(view,cell,line.names)+after
    }
    return 0
}

@(private)
content_has :: proc(list:^[dynamic]u64,group:u64) -> bool {return slice.contains(list[:],group)}

@(private)
content_flip :: proc(c:^Content,list:^[dynamic]u64,group:u64) {
    c.revision+=1
    if at,found:=slice.linear_search(list[:],group);found {unordered_remove(list,at)} else {append(list,group)}
}

// Whether a group shows what it holds: Recent until it is closed; the
// folders, Favorites and the shelf of the root once they are opened.
@(private)
content_group_open :: proc(c:^Content,group:u64) -> bool {
    return !c.recent_closed if group==CONTENT_RECENT_GROUP else content_has(&c.open,group)
}

@(private)
content_group_flip :: proc(c:^Content,group:u64) {
    if group!=CONTENT_RECENT_GROUP {content_flip(c,&c.open,group);return}
    c.recent_closed=!c.recent_closed
    c.revision+=1
}

// Whether an asset is selected: the last clicked, or one Ctrl or Shift added.
content_selected :: proc(c:^Content,id:base.Asset_Id) -> bool {
    return id!={} && (c.selected==id || slice.contains(c.picked[:],id))
}

content_selected_count :: proc(c:^Content) -> int {return len(c.picked)+(1 if c.selected!={} else 0)}

// A click on an asset selects it alone; with add (Ctrl or Shift) it joins
// the selection, or leaves it if it was there.
@(private)
content_select :: proc(c:^Content,id:base.Asset_Id,add:bool) {
    if !add {
        clear(&c.picked)
        c.selected,c.selected_clip=id,0
        return
    }
    if c.selected==id && c.selected_clip==0 {
        c.selected={}
        if len(c.picked)>0 {c.selected=pop(&c.picked)}
        return
    }
    if at,found:=slice.linear_search(c.picked[:],id);found {
        ordered_remove(&c.picked,at)
        return
    }
    if c.selected!={} && c.selected_clip==0 {append(&c.picked,c.selected)}
    c.selected,c.selected_clip=id,0
}

@(private)
content_select_clear :: proc(c:^Content) {
    clear(&c.picked)
    c.selected,c.selected_clip={},0
}

// An asset left the registry: it leaves the selection.
content_unselect :: proc(c:^Content,id:base.Asset_Id) {
    if at,found:=slice.linear_search(c.picked[:],id);found {ordered_remove(&c.picked,at)}
    if c.selected!=id {return}
    c.selected,c.selected_clip={},0
    if len(c.picked)>0 {c.selected=pop(&c.picked)}
}

// An asset was used: placed, opened or assigned. Recent shows it first.
content_used :: proc(s:^Session,id:base.Asset_Id) {
    if s.content==nil || id=={} {return}
    m:=&s.content.marks
    at:=len(m.recent)-1
    for other,i in m.recent {
        if other==id || other=={} {at=i;break}
    }
    copy(m.recent[1:at+1],m.recent[:at])
    m.recent[0]=id
    s.content.revision+=1
}

content_favorite :: proc(m:^Content_Marks,id:base.Asset_Id) -> bool {
    if id=={} {return false}
    _,found:=slice.linear_search(m.favorites[:],id)
    return found
}

// Stars an asset or takes its star away; the list keeps its order and has no
// holes.
content_favorite_toggle :: proc(c:^Content,id:base.Asset_Id) {
    m:=&c.marks
    c.revision+=1
    if at,found:=slice.linear_search(m.favorites[:],id);found {
        copy(m.favorites[at:],m.favorites[at+1:])
        m.favorites[len(m.favorites)-1]={}
        return
    }
    for &slot in m.favorites {
        if slot=={} {slot=id;return}
    }
}

@(private)
content_path_matches :: proc(path,filter:string) -> bool {
    if filter=="" || contains_fold(asset_name(path),filter) {return true}
    slash:=strings.last_index_byte(path,'/')
    return slash>=0 && contains_fold(path[:slash],filter)
}

// Whether the filters of kinds take some and leave the others out.
@(private)
content_kinds_filtered :: proc(c:^Content) -> bool {return c.categories!={} || len(c.kinds)>0}

// Whether the filters of kinds take a kind.
@(private)
content_kind_taken :: proc(c:^Content,kind:asset.Fourcc) -> bool {
    if !content_kinds_filtered(c) {return true}
    category,engine:=content_category(kind)
    return category in c.categories if engine else slice.contains(c.kinds[:],kind)
}

// Whether the browser lists a file: an asset of a kind of the engine, or of a
// plugin that opens it as a document or declares it (opened). The other
// kinds of a plugin are edited by its API. A skeleton comes with the mesh on
// it, which stands for it.
@(private)
content_shown :: proc(file:^asset.Registry_File,opened:[]asset.Fourcc) -> bool {
    if file.state!=.Asset || file.kind==asset.KIND_SKELETON || !asset.registry_listed(file) || content_cover(file) {return false}
    _,engine:=content_category(file.kind)
    return engine || slice.contains(opened,file.kind)
}

// Whether a file is the cover of its folder.
@(private)
content_cover :: proc(file:^asset.Registry_File) -> bool {
    return file.kind==asset.KIND_TEXTURE && asset_name(file.path)==CONTENT_COVER_NAME
}

// The cover of the folder of prefix (its path with the slash at its end), as
// Content_Line.cover.
@(private)
content_cover_of :: proc(registry:^asset.Registry,prefix:string) -> i32 {
    file,found:=asset.registry_find_path(registry,fmt.tprintf("%s%s.tex",prefix,CONTENT_COVER_NAME))
    if !found || !content_cover(file) {return 0}
    return content_file_index(registry,file)+1
}

// Whether the browser lists a file under the filters of kinds.
@(private)
content_listed :: proc(c:^Content,file:^asset.Registry_File,opened:[]asset.Fourcc) -> bool {
    return content_shown(file,opened) && content_kind_taken(c,file.kind)
}

// Whether a file is a part of an import: its header names an owner
// (asset.Header.owner), which the importer gives only to what is surely of
// that model alone, and the owner is in the registry. The browser shows a part
// after its owner and hides it from its folder.
@(private)
content_part :: proc(registry:^asset.Registry,file:^asset.Registry_File) -> bool {
    if file.state!=.Asset || file.owner=={} || file.owner==file.id {return false}
    owner,found:=asset.registry_find(registry,file.owner)
    return found && owner.state==.Asset
}

// What the registry has, read again when it changes: the families present,
// what some asset depends on and the parts of each owner.
@(private)
content_registry_read :: proc(c:^Content,registry:^asset.Registry,opened:[]asset.Fourcc,types:^asset.Types=nil) {
    key:=[3]u64{u64(uintptr(raw_data(registry.files))),registry.revision,u64(len(registry.files))|u64(len(opened))<<32}
    if key==c.registry_key {return}
    c.registry_key=key
    c.present={}
    clear(&c.present_kinds)
    clear(&c.referenced)
    clear(&c.parts)
    clear(&c.variants)
    for &file,at in registry.files {
        if content_shown(&file,opened) {
            if category,engine:=content_category(file.kind);engine {
                c.present+={category}
            } else if !slice.contains(c.present_kinds[:],file.kind) {
                append(&c.present_kinds,file.kind)
            }
        }
        append(&c.referenced,..asset.registry_dependencies(registry,&file))
        if file.kind!=asset.KIND_SKELETON && content_part(registry,&file) {append(&c.parts,Content_Part{file.owner,i32(at)})}
        if base_id:=content_variant_base(registry,types,&file);base_id!={} {append(&c.variants,Content_Part{base_id,i32(at)})}
    }
    slice.sort_by(c.referenced[:],proc(a,b:base.Asset_Id) -> bool {return a[0]<b[0] || a[0]==b[0] && a[1]<b[1]})
    // The parts of an owner keep the order of their paths.
    by_owner :: proc(a,b:Content_Part) -> bool {return a.owner[0]<b.owner[0] || a.owner[0]==b.owner[0] && (a.owner[1]<b.owner[1] || a.owner[1]==b.owner[1] && a.file<b.file)}
    slice.sort_by(c.parts[:],by_owner)
    slice.sort_by(c.variants[:],by_owner)
    c.revision+=1
}

// The parts of an owner, in the order of their paths.
@(private)
content_parts_of :: proc(c:^Content,owner:base.Asset_Id) -> []Content_Part {return content_owned(c.parts[:],owner)}

@(private)
content_owned :: proc(list:[]Content_Part,owner:base.Asset_Id) -> []Content_Part {
    first,_:=slice.binary_search_by(list,owner,proc(part:Content_Part,owner:base.Asset_Id) -> slice.Ordering {
        a:=part.owner
        if a[0]<owner[0] || a[0]==owner[0] && a[1]<owner[1] {return .Less}
        return .Greater
    })
    last:=first
    for last<len(list) && list[last].owner==owner {last+=1}
    return list[first:last]
}

// The base of a prefab that is a variant; zero for any other file. Only a
// prefab that needs another is read, once per change of the registry.
@(private)
content_variant_base :: proc(registry:^asset.Registry,types:^asset.Types,file:^asset.Registry_File) -> base.Asset_Id {
    if types==nil || file.kind!=asset.KIND_PREFAB || file.state!=.Asset {return {}}
    nests:=false
    for id in asset.registry_dependencies(registry,file) {
        if dependency,found:=asset.registry_find(registry,id);found && dependency.kind==asset.KIND_PREFAB {nests=true;break}
    }
    if !nests {return {}}
    scene:asset.Scene
    if asset.scene_load(&scene,types,asset.registry_file_path(registry,file.path,context.temp_allocator),context.temp_allocator)!=.None {return {}}
    _,base_id:=asset.prefab_variant_base(&scene)
    return base_id
}

// Whether an asset is used by another. A scene is never unused: nothing holds it.
@(private)
content_referenced :: proc(c:^Content,file:^asset.Registry_File) -> bool {
    if file.kind==asset.KIND_SCENE {return true}
    _,found:=slice.binary_search_by(c.referenced[:],file.id,proc(a,b:base.Asset_Id) -> slice.Ordering {
        if a==b {return .Equal}
        return .Less if a[0]<b[0] || a[0]==b[0] && a[1]<b[1] else .Greater
    })
    return found
}

@(private)
content_clip_name :: proc(c:^Content,clip:int) -> string {
    at:=c.clips[clip]
    return string(c.clip_text[at.start:][:at.length])
}

// Reads the names of the clips of every library again when the registry or
// the assets changed.
@(private)
content_clips_read :: proc(c:^Content,a:^host.Assets) {
    key:=[2]u64{a.registry.revision,a.revision}
    if key==c.clips_key {return}
    c.clips_key=key
    clear(&c.clips)
    clear(&c.clip_text)
    for &file in a.registry.files {
        if file.state!=.Asset || file.kind!=asset.KIND_ANIMATION {continue}
        data:asset.Asset
        if host.assets_file(a,file.id,asset.KIND_ANIMATION,&data)!=.None {continue}
        if view,error:=asset.animation_view(&data,&a.types);error==.None {
            for &clip in view.clips {
                name:=base.text_get(clip.name[:])
                append(&c.clips,Content_Clip{file.id,u32(len(c.clip_text)),u32(len(name))})
                append(&c.clip_text,..transmute([]u8)name)
            }
        }
        asset.asset_close(&data)
    }
    c.revision+=1
}

// Shows or hides the clips of a library or the parts of an owner.
@(private)
content_unfold :: proc(c:^Content,id:base.Asset_Id) {
    if at,found:=slice.linear_search(c.unfolded[:],id);found {unordered_remove(&c.unfolded,at)} else {append(&c.unfolded,id)}
    c.revision+=1
}

// Whether a search finds a library by one of its clips.
@(private)
content_clip_matches :: proc(c:^Content,library:base.Asset_Id,filter:string) -> bool {
    if filter=="" {return false}
    for clip,k in c.clips {
        if clip.library==library && contains_fold(content_clip_name(c,k),filter) {return true}
    }
    return false
}

// Whether a file is listed under the search, the filters and Only unused. A
// part of an import shows in its folder only while a search finds it, Show
// parts of imports is on or the filters of kinds leave its owner out;
// marked: Recent and Favorites, which show it always.
@(private)
content_matches :: proc(c:^Content,registry:^asset.Registry,file:^asset.Registry_File,opened:[]asset.Fourcc,filter:string,marked:bool=false) -> bool {
    if !content_listed(c,file,opened) || c.unused && content_referenced(c,file) {return false}
    if filter=="" {
        if marked || c.view.show_parts || !content_part(registry,file) {return true}
        owner,_:=asset.registry_find(registry,file.owner)
        return !content_kind_taken(c,owner.kind)
    }
    return content_path_matches(file.path,filter) || content_clip_matches(c,file.id,filter)
}

@(private)
content_file_index :: proc(registry:^asset.Registry,file:^asset.Registry_File) -> i32 {
    return i32((uintptr(file)-uintptr(raw_data(registry.files)))/size_of(asset.Registry_File))
}

// The cards of files, in rows of the grid (one per row of the list), each
// library followed by its clips while it is open or a search finds them, and
// each owner by its parts while it is open.
@(private)
content_cards_add :: proc(c:^Content,registry:^asset.Registry,files:[]i32,depth:u16,group:u64,parent:[2]i32,columns:int,filter:string) {
    first:=len(c.cards)
    for index in files {
        file:=&registry.files[index]
        at:=len(c.cards)
        append(&c.cards,Content_Card{file=index,name=asset_name(file.path)})
        open:=slice.contains(c.unfolded[:],file.id)
        // A prefab opens to its variants; the parts of its import show in their folders.
        parts:=content_owned(c.variants[:],file.id) if file.kind==asset.KIND_PREFAB else content_parts_of(c,file.id)
        if len(parts)>0 {
            c.cards[at].holds,c.cards[at].open=true,open
            if open {
                for part in parts {append(&c.cards,Content_Card{file=part.file,name=asset_name(registry.files[part.file].path),part=true})}
            }
        }
        if file.kind!=asset.KIND_ANIMATION {continue}
        for clip,k in c.clips {
            if clip.library!=file.id {continue}
            c.cards[at].holds,c.cards[at].open=true,open
            clip_name:=content_clip_name(c,k)
            if filter!="" ? !contains_fold(clip_name,filter) : !open {continue}
            append(&c.cards,Content_Card{file=index,clip=i32(k+1),name=clip_name})
        }
    }
    count:=len(c.cards)-first
    for at:=first;at<first+count;at+=columns {
        append(&c.lines,Content_Line{kind=.Cards,depth=depth,group=group,first=i32(at),count=i32(min(columns,first+count-at)),top=at==first,bottom=at+columns>=first+count,parent=parent})
    }
}

// Recent or Favorites: the assets of the marks the filters take.
@(private)
content_marks_add :: proc(c:^Content,registry:^asset.Registry,ids:[]base.Asset_Id,group:u64,name:string,opened:[]asset.Fourcc,filter:string,filtering:bool,width:f32) {
    files:=make([dynamic]i32,context.temp_allocator)
    for id in ids {
        if id=={} {break}
        if file,found:=asset.registry_find(registry,id);found && content_matches(c,registry,file,opened,filter,marked=true) {append(&files,content_file_index(registry,file))}
    }
    if filtering && len(files)==0 {return}
    open:=filtering || content_group_open(c,group)
    header:=i32(len(c.lines))
    append(&c.lines,Content_Line{kind=.Header,group=group,name=name,open=open,count=i32(len(files)),parent={-1,-1}})
    if !open || len(files)==0 {return}
    columns,_:=content_cells(c.view,width,0)
    content_cards_add(c,registry,files[:],0,group,{header,-1},columns,filter)
}

// A folder and what is in it, from the files under it (entries, sorted by
// path), at depth levels: its folders first, each with what it holds while it
// is open, then its files. In Shelves its files line up with its name and
// those of the root have a shelf of their own, after the folders.
@(private)
content_folder_add :: proc(c:^Content,registry:^asset.Registry,entries:[]Content_Entry,prefix:string,depth:u16,group:u64,parent:[2]i32,filtering:bool,width:f32,filter:string) {
    shelves:=c.view.arrangement==.Shelves
    level:=depth-1 if shelves && depth>0 else depth
    root:=shelves && depth==0
    group,parent:=group,parent
    files:=make([dynamic]i32,context.temp_allocator)
    if !root && content_create_in(c,prefix) {append(&c.lines,Content_Line{kind=.Create,depth=level,group=group,parent=parent})}
    for i:=0;i<len(entries); {
        path:=entries[i].path[len(prefix):]
        slash:=strings.index_byte(path,'/')
        if slash<0 {
            if entries[i].index>=0 {append(&files,entries[i].index)}
            i+=1
            continue
        }
        folder:=entries[i].path[:len(prefix)+slash+1]
        j:=i+1
        held:=i32(entries[i].index>=0)
        for j<len(entries) && strings.has_prefix(entries[j].path,folder) {
            if entries[j].index>=0 {held+=1}
            j+=1
        }
        hash:=base.hash64(transmute([]u8)folder[:len(folder)-1])
        open:=filtering || content_group_open(c,hash)
        header:=i32(len(c.lines))
        append(&c.lines,Content_Line{kind=.Header,depth=depth,group=hash,name=path[:slash],path=folder[:len(folder)-1],open=open,count=held,cover=content_cover_of(registry,folder) if shelves else 0,parent=parent})
        if open {
            inner:=parent
            if depth<2 {inner[depth]=header}
            content_folder_add(c,registry,entries[i:j],folder,depth+1,hash,inner,filtering,width,filter)
        }
        i=j
    }
    if root {
        creating:=content_create_in(c,"")
        if len(files)==0 && !creating {return}
        open:=filtering || content_group_open(c,CONTENT_ROOT_GROUP)
        header:=i32(len(c.lines))
        append(&c.lines,Content_Line{kind=.Header,group=CONTENT_ROOT_GROUP,name="Assets",open=open,count=i32(len(files)),cover=content_cover_of(registry,""),parent={-1,-1}})
        if !open {return}
        group,parent=CONTENT_ROOT_GROUP,{header,-1}
        if creating {append(&c.lines,Content_Line{kind=.Create,group=group,parent=parent})}
    }
    if len(files)==0 {return}
    columns,_:=content_cells(c.view,width,level)
    content_cards_add(c,registry,files[:],level,group,parent,columns,filter)
}

// The lines of the browser in a width: Recent and Favorites, then the folders
// of the assets as Folders or Shelves arrange them, with what
// content_registry_read read of the registry this frame. Built again only when
// the registry, the filters, the marks or what is open change.
@(private)
content_lines :: proc(c:^Content,registry:^asset.Registry,width:f32,opened:[]asset.Fourcc=nil,font:^ui.Font=nil,name_size:f32=0) -> []Content_Line {
    filter:=string(c.filter[:c.filter_length])
    v:=c.view
    key:=[10]u64{u64(uintptr(raw_data(registry.files))),u64(len(registry.files)),registry.revision,base.hash64(transmute([]u8)filter),u64(transmute(u16)c.categories)|u64(c.unused)<<16|u64(v.arrangement)<<17|u64(v.mode)<<18|u64(v.show_names)<<19|u64(v.show_parts)<<20,c.revision,u64(transmute(u32)v.size),u64(transmute(u32)width),u64(len(opened)),base.hash64(slice.to_bytes(c.kinds[:]))}
    if key==c.key {return c.lines[:]}
    c.key=key
    clear(&c.lines)
    clear(&c.cards)
    clear(&c.heights)
    c.results=0
    filtering:=filter!="" || content_kinds_filtered(c) || c.unused
    content_marks_add(c,registry,c.marks.recent[:],CONTENT_RECENT_GROUP,"Recent",opened,filter,filtering,width)
    content_marks_add(c,registry,c.marks.favorites[:],CONTENT_FAVORITES_GROUP,"Favorites",opened,filter,filtering,width)
    // The registry keeps its files sorted by path: a folder is a run of them.
    entries:=make([dynamic]Content_Entry,context.temp_allocator)
    for &file,index in registry.files {
        if content_matches(c,registry,&file,opened,filter) {append(&entries,Content_Entry{file.path,i32(index)})}
    }
    c.results=len(entries)
    // The folders of the project show also without files, not while filtering.
    if !filtering && len(registry.folders)>0 {
        for folder in registry.folders {
            if folder[0]!='.' && !content_mounted(registry,folder) {append(&entries,Content_Entry{folder,-1})}
        }
        slice.sort_by(entries[:],proc(a,b:Content_Entry) -> bool {return a.path<b.path})
    }
    content_folder_add(c,registry,entries[:],"",0,0,{-1,-1},filtering,width,filter)
    // What Create names shows at the end when its folder does not.
    if c.creating && !slice.any_of_proc(c.lines[:],proc(line:Content_Line) -> bool {return line.kind==.Create}) {append(&c.lines,Content_Line{kind=.Create,parent={-1,-1}})}
    // A row whose names all fit in one line keeps the room of one.
    if font!=nil && v.mode==.Grid && v.show_names {
        for &line in c.lines {
            if line.kind!=.Cards {continue}
            _,cell:=content_cells(v,width,line.depth)
            line.names=1
            for card in c.cards[line.first:][:line.count] {
                if ui.text_width(font,card.name,name_size)>cell-2*CONTENT_PAD-2 {line.names=2;break}
            }
        }
    }
    for line in c.lines {append(&c.heights,content_line_height(v,line,width))}
    return c.lines[:]
}

// Every folder closed, Favorites and the shelf of the root too, and no
// library or owner showing what it holds. Recent stays as it is.
@(private)
content_collapse :: proc(c:^Content) {
    clear(&c.open)
    clear(&c.unfolded)
    c.revision+=1
}

// Whether everything content_collapse closes is closed.
@(private)
content_collapsed :: proc(c:^Content) -> bool {return len(c.open)==0 && len(c.unfolded)==0}

// Every folder open, Favorites and the shelf of the root too.
@(private)
content_expand :: proc(c:^Content,registry:^asset.Registry) {
    for group in ([2]u64{CONTENT_FAVORITES_GROUP,CONTENT_ROOT_GROUP}) {
        if !content_has(&c.open,group) {append(&c.open,group)}
    }
    for &file in registry.files {
        for i in 0..<len(file.path) {
            if file.path[i]!='/' {continue}
            hash:=base.hash64(transmute([]u8)file.path[:i])
            if !content_has(&c.open,hash) {append(&c.open,hash)}
        }
    }
    c.revision+=1
}

// Opens the way to an asset to show it: its folders, or the shelf of the
// root for a file at the root. A part its folder hides shows after its owner.
@(private)
content_reveal_open :: proc(c:^Content,registry:^asset.Registry) {
    file,found:=asset.registry_find(registry,c.reveal)
    if !found {
        c.reveal={}
        return
    }
    if content_part(registry,file) && !c.view.show_parts {
        // A prefab opens to its variants, not its parts: they show in their folder.
        if owner,_:=asset.registry_find(registry,file.owner);owner.kind==asset.KIND_PREFAB {
            c.view.show_parts=true
        } else {
            file=owner
            if !slice.contains(c.unfolded[:],file.id) {append(&c.unfolded,file.id)}
        }
    }
    content_folder_open(c,content_folder_of(file.path))
}

// The folder a path of the assets is in; "" for the root.
@(private)
content_folder_of :: proc(path:string) -> string {return path[:max(strings.last_index_byte(path,'/'),0)]}

// Opens a folder and those it is in; for the root, its shelf in Shelves.
@(private)
content_folder_open :: proc(c:^Content,folder:string) {
    if folder=="" && !content_has(&c.open,CONTENT_ROOT_GROUP) {append(&c.open,CONTENT_ROOT_GROUP)}
    for i in 1..=len(folder) {
        if i<len(folder) && folder[i]!='/' {continue}
        hash:=base.hash64(transmute([]u8)folder[:i])
        if !content_has(&c.open,hash) {append(&c.open,hash)}
    }
    c.revision+=1
}

// Whether a folder of the registry belongs to a plugin, the engine or the
// editor: its files are listed, the folder is not.
@(private)
content_mounted :: proc(registry:^asset.Registry,folder:string) -> bool {
    for mount in registry.mounts {
        if len(folder)>len(mount.prefix) && folder[len(mount.prefix)]=='/' && strings.has_prefix(folder,mount.prefix) {return true}
    }
    return false
}

@(private)
content_place_set :: proc(c:^Content,folder:string) {c.place_length=copy(c.place[:],folder)}

// What the file of the project keeps of where the browser was left.
content_navigation :: proc(c:^Content) -> (n:Content_Navigation) {
    copy(n.place[:],c.place[:c.place_length])
    n.categories,n.unused,n.recent_closed=c.categories,c.unused,c.recent_closed
    copy(n.kinds[:],c.kinds[:])
    copy(n.open[:],c.open[:])
    return
}

// Puts the browser where the file of the project says it was left; the
// first build checks it against the registry (content_navigation_restore).
content_navigation_set :: proc(c:^Content,n:^Content_Navigation) {
    content_place_set(c,base.text_get(n.place[:]))
    c.categories,c.unused,c.recent_closed=n.categories,n.unused,n.recent_closed
    clear(&c.kinds)
    for kind in n.kinds {
        if kind==0 {break}
        append(&c.kinds,kind)
    }
    clear(&c.open)
    for group in n.open {
        if group==0 {break}
        append(&c.open,group)
    }
    c.restore=true
    c.revision+=1
}

// Whether the registry has a folder: empty, or holding files.
@(private)
content_folder_exists :: proc(registry:^asset.Registry,folder:string) -> bool {
    for path in registry.folders {
        if len(path)==len(folder)+1 && strings.has_prefix(path,folder) {return true}
    }
    for &file in registry.files {
        if len(file.path)>len(folder) && file.path[len(folder)]=='/' && strings.has_prefix(file.path,folder) {return true}
    }
    return false
}

// What was read of the project as the registry has it now: a folder that is
// gone gives its place to the nearest one above it that is there, or to the
// root; the folders open that are gone are left out, and so are the filters
// whose chip is not shown.
@(private)
content_navigation_restore :: proc(c:^Content,registry:^asset.Registry) {
    c.restore=false
    place:=string(c.place[:c.place_length])
    for place!="" && !content_folder_exists(registry,place) {place=content_folder_of(place)}
    c.place_length=len(place)
    folders:=make([dynamic]u64,context.temp_allocator)
    for path in registry.folders {append(&folders,base.hash64(transmute([]u8)strings.trim_suffix(path,"/")))}
    for &file in registry.files {
        for i in 0..<len(file.path) {
            if file.path[i]=='/' {append(&folders,base.hash64(transmute([]u8)file.path[:i]))}
        }
    }
    slice.sort(folders[:])
    for i:=len(c.open)-1;i>=0;i-=1 {
        group:=c.open[i]
        if group==CONTENT_FAVORITES_GROUP || group==CONTENT_ROOT_GROUP {continue}
        if _,found:=slice.binary_search(folders[:],group);!found {ordered_remove(&c.open,i)}
    }
    c.categories&=c.view.chips
    for i:=len(c.kinds)-1;i>=0;i-=1 {
        if !slice.contains(content_chip_kinds(c),c.kinds[i]) || !slice.contains(c.present_kinds[:],c.kinds[i]) {ordered_remove(&c.kinds,i)}
    }
    c.revision+=1
}

// ---------------------------------------------------------------- Create

// Whether what Create names goes at the top of what the folder of prefix
// holds (its path with the slash at its end; "" the root).
@(private)
content_create_in :: proc(c:^Content,prefix:string) -> bool {
    folder:=string(c.create_folder[:c.create_folder_length])
    return c.creating && (prefix=="" if folder=="" else len(prefix)==len(folder)+1 && strings.has_prefix(prefix,folder))
}

@(private)
content_create_id :: proc(g:^Editor_Ui) -> ui.Id {return shell_id(g,"content_create")}

@(private)
content_create_icon :: proc(s:^Session,kind:asset.Fourcc) -> (icon:ui.Icon,color:ui.Color) {
    if kind==ASSET_CREATE_FOLDER {return ui.icon_user(u8(User_Icon.Folder)),s.gui.ctx.theme.text_muted}
    return asset_icon(s,kind)
}

// Opens the menu of Create at anchor, to make in folder; on_folder: it was
// opened on that folder, which it also renames, copies and moves.
@(private)
content_create_open :: proc(s:^Session,folder:string,anchor:ui.Rect,on_folder:=false) {
    c:=s.content
    c.create_into_length=copy(c.create_into[:],folder)
    c.create_on_folder=on_folder && folder!=""
    ui.popup_open(s.gui.ctx,content_create_id(s.gui),anchor)
}

// The + of the panel: the menu of Create, to make in the folder of what was
// clicked last.
@(private)
content_create_button :: proc(s:^Session,id:ui.Id,height:f32=22) {
    ctx:=s.gui.ctx
    popup:=content_create_id(s.gui)
    if ui.button(ctx,id,{icon=.Plus,icon_color=ctx.theme.text_muted,tip="Create",style=.Toggle,width=height,height=height,disabled=s.content==nil || files_registry(s)==nil,active=ui.popup_is_open(ctx,popup)}).clicked && !ui.popup_is_open(ctx,popup) {
        anchor,_:=ui.widget_rect(ctx,id)
        content_create_open(s,string(s.content.place[:s.content.place_length]),anchor)
    }
}

// The entries of Create, one for each kind it makes, into folder.
@(private)
content_create_items :: proc(s:^Session,folder:string) {
    ctx:=s.gui.ctx
    disabled:=asset_create_refusal(s)!=""
    for kind,i in asset_create_kinds(s) {
        icon,color:=content_create_icon(s,kind)
        // A table of game data is of a type of the code: one entry for each.
        if kind==asset.KIND_RECORDS {
            records:[]core.Record_Info
            if s.app.info!=nil {records=s.app.info.records}
            for &r,at in records {
                if ui.menu_item(ctx,ui.id(ctx,"create_records",at+1),fmt.tprintf("Records: %s",r.name),{icon=icon,icon_color=color,disabled=disabled}) {
                    s.content.create_record=at
                    content_create_begin(s,kind,folder)
                }
            }
            continue
        }
        if ui.menu_item(ctx,ui.id(ctx,"create",i+1),asset_create_label(s,kind),{icon=icon,icon_color=color,disabled=disabled}) {content_create_begin(s,kind,folder)}
    }
}

@(private)
content_create_menu :: proc(s:^Session) {
    c:=s.content
    ctx:=s.gui.ctx
    popup:=content_create_id(s.gui)
    if ui.popup(ctx,popup,{min_width=180}) {
        ui.id_push(ctx,popup)
        defer ui.id_pop(ctx)
        folder:=string(c.create_into[:c.create_into_length])
        ui.menu_header(ctx,fmt.tprintf("Create in %s",asset_name(folder) if folder!="" else "Assets"))
        content_create_items(s,folder)
        if c.create_on_folder {
            ui.menu_separator(ctx)
            off:=asset_create_refusal(s)!=""
            if ui.menu_item(ctx,ui.id(ctx,"rename"),"Rename",{icon=action_icon(.Rename),disabled=off}) {content_rename_begin(s,{},folder)}
            if ui.menu_item(ctx,ui.id(ctx,"duplicate"),"Duplicate",{icon=action_icon(.Duplicate),disabled=off}) {
                if _,message:=asset_folder_duplicate(s,folder);message!="" {notify(s,message)}
            }
            if ui.submenu(ctx,ui.id(ctx,"move"),"Move to",{icon=ui.icon_user(u8(User_Icon.Folder)),disabled=off}) {content_move_items(s,{},folder)}
        }
    }
}

// The folders of the project an asset, or the folder from, can go to, as
// entries of a menu: the root first.
@(private)
content_move_items :: proc(s:^Session,id:base.Asset_Id,from:string) {
    ctx:=s.gui.ctx
    r:=files_registry(s)
    if r==nil {return}
    here:=content_folder_of(from)
    if id!={} {
        file,found:=asset.registry_find(r,id)
        if !found {return}
        here=content_folder_of(file.path)
    }
    folders:=make([dynamic]string,context.temp_allocator)
    append(&folders,"")
    for folder in r.folders {
        if folder[0]!='.' && !content_mounted(r,folder) {append(&folders,folder[:len(folder)-1])}
    }
    for folder,i in folders {
        if ui.menu_item(ctx,ui.id(ctx,"move",i+1),folder if folder!="" else "Assets",{icon=ui.icon_user(u8(User_Icon.Folder)),icon_color=ctx.theme.text_muted,disabled=folder==here || from!="" && (folder==from || asset_path_inside(folder,from))}) {
            message:string
            if id!={} {_,message=asset_move(s,id,folder,"")} else {_,message=asset_folder_move(s,from,folder,"")}
            if message!="" {notify(s,message)}
            // The names of the folders went with the scan.
            return
        }
    }
}

// An asset dropped on the header of a folder moves there with its parts.
@(private)
content_drop :: proc(s:^Session,folder:string) {
    g:=s.gui
    if g.drag.kind!=.Asset || base.text_get(g.drag.part[:])!="" {return}
    r:=files_registry(s)
    if r==nil {return}
    file,found:=asset.registry_find(r,g.drag.asset_id)
    if !found || content_folder_of(file.path)==folder {return}
    if _,message:=asset_move(s,file.id,folder,"");message!="" {notify(s,message)}
}

// Copies an asset beside itself, and selects the copy.
@(private)
content_duplicate :: proc(s:^Session,id:base.Asset_Id) {
    if _,_,message:=asset_duplicate(s,id);message!="" {notify(s,message)}
}

// The line of Create names the asset id, or the folder when id is zero, to
// type its new name over the one it has: Enter or a click elsewhere renames
// it, Escape leaves it.
content_rename_begin :: proc(s:^Session,id:base.Asset_Id,folder:="") {
    c:=s.content
    r:=files_registry(s)
    if c==nil || r==nil {return}
    path,kind,name:=folder,ASSET_CREATE_FOLDER,asset_path_base(folder)
    refusal:=asset_create_refusal(s)
    if id!={} {
        file,found:=asset.registry_find(r,id)
        if !found {return}
        path,kind,name=file.path,file.kind,asset_name(file.path)
        if refusal=="" {refusal=asset_move_refusal(s,r,file)}
    }
    if refusal!="" || path=="" {
        if refusal!="" {notify(s,refusal)}
        return
    }
    parent:=content_folder_of(path)
    c.create_name_length=copy(c.create_name[:],name)
    c.create_folder_length=copy(c.create_folder[:],parent)
    c.creating,c.create_kind,c.create_edit=true,kind,true
    c.rename_length,c.renaming=copy(c.rename[:],path),id
    c.filter_length,c.categories,c.unused=0,{},false
    content_place_set(c,parent)
    content_folder_open(c,parent)
}

// Renames what the line of Create names. A name that cannot be, or is
// taken, keeps the line to type another.
@(private)
content_rename_finish :: proc(s:^Session) {
    c:=s.content
    path:=strings.clone(string(c.rename[:c.rename_length]),context.temp_allocator)
    name:=strings.trim_space(string(c.create_name[:c.create_name_length]))
    message:=asset_name_refusal(name)
    if message=="" {
        if c.renaming!={} {_,message=asset_move(s,c.renaming,content_folder_of(path),name)} else {_,message=asset_folder_move(s,path,content_folder_of(path),name)}
    }
    if message!="" {
        notify(s,message)
        c.create_edit=true
        return
    }
    content_create_end(c)
}

// A line in folder names what Create makes of kind, with a free name to type
// over: Enter or a click elsewhere makes it, Escape leaves it.
content_create_begin :: proc(s:^Session,kind:asset.Fourcc,folder:string) {
    c:=s.content
    r:=files_registry(s)
    if c==nil || r==nil || asset_create_refusal(s)!="" {return}
    extension:=asset_create_extension(s,kind)
    path:=asset_create_path(r,folder,asset_create_default(s,kind),extension)
    c.create_name_length=copy(c.create_name[:],path[len(folder)+(1 if folder!="" else 0):len(path)-len(extension)])
    c.create_folder_length=copy(c.create_folder[:],folder)
    c.creating,c.create_kind,c.create_edit=true,kind,true
    c.rename_length,c.renaming=0,{}
    c.filter_length,c.categories,c.unused=0,{},false
    content_place_set(c,folder)
    content_folder_open(c,folder)
}

@(private)
content_create_end :: proc(c:^Content) {
    c.creating,c.create_edit=false,false
    c.rename_length,c.renaming=0,{}
    c.revision+=1
}

// Makes what the line of Create names. A name that cannot be, or is taken,
// keeps the line to type another.
@(private)
content_create_finish :: proc(s:^Session) {
    c:=s.content
    r:=files_registry(s)
    if r==nil {content_create_end(c);return}
    if c.rename_length>0 {content_rename_finish(s);return}
    kind:=c.create_kind
    folder:=string(c.create_folder[:c.create_folder_length])
    extension:=asset_create_extension(s,kind)
    name:=strings.trim_space(string(c.create_name[:c.create_name_length]))
    if extension!="" && strings.has_suffix(name,extension) {name=name[:len(name)-len(extension)]}
    if refused:=asset_name_refusal(name);refused!="" {
        notify(s,refused)
        c.create_edit=true
        return
    }
    path:=asset_create_join(folder,name,extension)
    if asset_path_taken(r,path) {
        notify(s,fmt.tprintf("%s already exists: give another name",path))
        c.create_edit=true
        return
    }
    id:base.Asset_Id
    if kind!=ASSET_CREATE_FOLDER {id=asset_id_new(s)}
    content_create_end(c)
    if problem:=asset_create(s,kind,path,id);problem!="" {
        notify(s,problem)
        return
    }
    if kind==ASSET_CREATE_FOLDER {
        content_place_set(c,path)
        content_folder_open(c,path)
        return
    }
    c.created=id
}

// The line of Create: the icon of its kind and the field of its name. Returns
// whether to make or rename what it names, once the lines are built: that
// changes the registry their names are in.
@(private)
content_create_line :: proc(s:^Session,line:Content_Line) -> (finish:bool) {
    c:=s.content
    ctx:=s.gui.ctx
    field:=ui.id(ctx,"content_create_name")
    icon,color:=content_create_icon(s,c.create_kind)
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(CONTENT_ROW),padding={CONTENT_INSET+f32(line.depth)*CONTENT_INDENT,2,CONTENT_INSET,2},gap=7,align_y=.Center}) {
        ui.icon(ctx,icon,color,14)
        if c.create_edit {
            ui.edit_request(ctx,field)
            c.create_edit=false
        }
        r:=ui.text_field(ctx,field,c.create_name[:],&c.create_name_length,{height=CONTENT_ROW-4})
        switch {
        case r.cancelled: content_create_end(c)
        case r.committed || !r.editing && !r.began && ctx.edit.id!=field: finish=true
        }
    }
    return
}

// What Create made comes into sight once the registry has it: selected, with
// the keyboard, and open in its document when its kind has one. What its
// plugin was asked for and did not write is told.
@(private)
content_created :: proc(s:^Session,registry:^asset.Registry) {
    c:=s.content
    file,found:=asset.registry_find(registry,c.created)
    if !found {
        notify(s,"The new asset could not be made")
        c.created={}
        return
    }
    c.created={}
    c.selected,c.selected_clip,c.reveal=file.id,0,file.id
    content_used(s,file.id)
    switch {
    case file.kind==asset.KIND_SCENE: if s.mode==.Edit {file_open_path(s,file.path)}
    case asset_document_opens(s,file.kind): asset_document_open(s,file.id)
    }
}

@(private)
content_settings_popup :: proc(g:^Editor_Ui) -> ui.Id {return shell_id(g,"content_settings")}

@(private)
content_settings_button :: proc(s:^Session,id:ui.Id,height:f32=22) {
    ctx:=s.gui.ctx
    popup:=content_settings_popup(s.gui)
    if ui.button(ctx,id,{icon=ui.icon_user(u8(User_Icon.Gear)),icon_color=ctx.theme.text_muted,style=.Toggle,width=height,height=height,disabled=s.content==nil,active=ui.popup_is_open(ctx,popup)}).clicked && !ui.popup_is_open(ctx,popup) {
        anchor,_:=ui.widget_rect(ctx,id)
        ui.popup_open(ctx,popup,anchor)
    }
}

// The gear of the panel. content_view: Content Browser is shown, not Editor.
@(private)
content_settings_build :: proc(s:^Session,content_view:bool) {
    c:=s.content
    if c==nil {return}
    ctx:=s.gui.ctx
    th:=&ctx.theme
    popup:=content_settings_popup(s.gui)
    if ui.popup(ctx,popup,{width=230}) {
        ui.id_push(ctx,popup)
        list:=c.view.mode==.List
        if content_view {
            // The arrangement is one choice of two, as in the prototype.
            ui.menu_header(ctx,"Layout")
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,padding=ui.padding_all(2),gap=2,fill=th.field,radius=4}) {
                labels:=[Content_Arrangement]string{.Folders="Folders",.Shelves="Shelves"}
                for arrangement in Content_Arrangement {
                    if !ui.button(ctx,ui.id(ctx,"layout",int(arrangement)+1),{label=labels[arrangement],style=.Tab,active=c.view.arrangement==arrangement,width=-1,height=24,size=th.font_small,padding=4,center=true}).clicked {continue}
                    c.view.arrangement=arrangement
                    c.scroll=0
                }
            }
        }
        // The browser has its own slider, in its bar.
        if !content_view {
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.control),padding={6,0,6,0},gap=7,align_y=.Center}) {
                ui.label(ctx,"Size",th.font_small,th.text,32)
                size:=f64(CONTENT_SIZE_LIST if list else c.view.size)
                if ui.slider_field(ctx,ui.id(ctx,"size"),&size,{min=f64(CONTENT_SIZE_LIST),max=f64(CONTENT_SIZE_MAX),has_min=true,has_max=true,integer=true,height=22}).changed {
                    content_view_resize(&c.view,f32(size))
                    c.scroll=0
                }
            }
        }
        if !(content_view && list) {
            if ui.menu_item(ctx,ui.id(ctx,"names"),"Show asset names",{checked=c.view.show_names}) {c.view.show_names=!c.view.show_names;c.scroll=0}
        }
        if content_view && ui.menu_item(ctx,ui.id(ctx,"unused"),"Only unused assets",{icon=.Filter,checked=c.unused}) {
            c.unused=!c.unused
            c.scroll=0
        }
        if content_view && ui.menu_item(ctx,ui.id(ctx,"parts"),"Show parts of imports",{icon=.Layers,checked=c.view.show_parts}) {
            c.view.show_parts=!c.view.show_parts
            c.scroll=0
        }
        ui.menu_separator(ctx)
        if ui.menu_item(ctx,ui.id(ctx,"reload"),"Refresh assets",{icon=.Refresh,disabled=s.app.assets==nil}) {
            if asset.registry_scan(&s.app.assets.registry)!=.None {notify(s,"The asset folder could not be read")}
        }
        if ui.menu_item(ctx,ui.id(ctx,"import"),"Import",{icon=.Import,disabled=action_state(s,.Import).disabled}) {action_run(s,.Import)}
        ui.id_pop(ctx)
    }
}

@(private)
// points: the side it is shown at. clip: of an animation, from 1; 0: the asset.
content_preview :: proc(s:^Session,file:^asset.Registry_File,points:f32,clip:u32=0) -> (icon:ui.Icon,color:ui.Color,quad:ui.Quad) {
    icon,color=asset_icon(s,file.kind)
    a:=s.app.assets
    if a.renderer==nil {return}
    switch file.kind {
    case asset.KIND_MATERIAL:  quad=ui.quad_whole(host.UI_QUAD_MATERIAL_PREVIEW,host.assets_material_row(a,file.id))
    case asset.KIND_MESH:      quad=preview_geometry(s,.None,file.id,points)
    case asset.KIND_TEXTURE:   quad=texture_quad(s,file.id)
    case asset.KIND_PREFAB:    quad=preview_document(s,file.id,points)
    case asset.KIND_SCENE:     quad=preview_scene(s,file.id,points)
    case:                      quad=preview_provided(s,file,clip,points)
    }
    if quad.kind!=.Solid {icon=.None}
    return
}

// A row of a list of a panel that names an asset, as the list of the browser
// shows one: its thumbnail and its label, with the color of its kind while it
// is selected. What follows the label goes before asset_list_row_end; what a
// click on it does is the caller's.
asset_list_row_begin :: proc(s:^Session,id:ui.Id,value:base.Asset_Id,kind:asset.Fourcc,label:string,selected:bool) -> (it:ui.Interaction) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    it=ui.interact(ctx,id,{.Focusable})
    file:^asset.Registry_File
    if value!={} && s.app!=nil && s.app.assets!=nil {file,_=asset.registry_find(&s.app.assets.registry,value)}
    color:=file!=nil?asset_file_color(s,file):asset_kind_color(s,kind)
    ui.box_begin(ctx,asset_row_box(ctx,id,4,selected,it.hot,content_keyboard(ctx,it)))
    if file!=nil {
        asset_thumbnail(s,file,20)
    } else {
        icon,_:=asset_icon(s,kind)
        asset_frame(s,20,color,CONTENT_FRAME_EDGE,1,{},icon,color,kind)
    }
    ui.label(ctx,label,th.font,th.text,0,font=ui.FONT_MEDIUM if selected else 0)
    return
}

// The box of a row of a list of assets: the fill of a selected row of the
// editor while it is selected, the field under the pointer, and the ring of
// the keyboard, the only light one, while the keys moved to it.
@(private)
asset_row_box :: proc(ctx:^ui.Context,id:ui.Id,indent:f32,selected,hot,keyboard:bool) -> ui.Box {
    th:=&ctx.theme
    fill:=th.accent_soft if selected else (th.field if hot else {})
    return {id=id,width=ui.GROW,height=ui.fixed(CONTENT_ROW),padding={indent,3,4,3},gap=7,align_y=.Center,fill=fill,stroke=th.text if keyboard else {},stroke_width=CONTENT_RING_WIDTH,radius=3}
}

// Whether the keys moved to a card or a row: it shows the ring of the
// keyboard, apart from its selection.
@(private)
content_keyboard :: proc(ctx:^ui.Context,it:ui.Interaction) -> bool {return it.focused && ctx.focus_ring}

// The box of a card of the grid: its padding, filled while it is selected,
// and the ring of the keyboard while the keys moved to it.
@(private)
asset_card_box :: proc(ctx:^ui.Context,id:ui.Id,view:Content_View,cell:f32,selected,keyboard:bool,names:u8=2) -> ui.Box {
    th:=&ctx.theme
    return {id=id,width=ui.fixed(cell),height=ui.fixed(content_card_height(view,cell,names)),direction=.Column,padding=ui.padding_all(CONTENT_PAD),gap=5,fill=th.accent_soft if selected else {},stroke=th.text if keyboard else {},stroke_width=CONTENT_RING_WIDTH,radius=6}
}
asset_list_row_end :: proc(s:^Session) {ui.box_end(s.gui.ctx,{})}

// The columns of a grid of asset cards of a panel in a width and the side of
// each, at the size and in the mode the content browser has: one column in
// its list.
asset_cards :: proc(s:^Session,width:f32) -> (columns:int,cell:f32) {
    return content_cells(asset_cards_view(s),width+CONTENT_INSET*2-2*CONTENT_PAD,0)
}

@(private)
asset_cards_view :: proc(s:^Session) -> Content_View {
    return s.content.view if s.content!=nil else CONTENT_VIEW_DEFAULT
}

// A card of a panel that names an asset as the browser shows one: a row of
// its list, or a thumbnail of side cell with the label under it while the
// browser shows names. What follows goes before asset_card_end: after the
// label of a row, floating over a card (asset_card_float). What a click on
// it does is the caller's.
asset_card_begin :: proc(s:^Session,id:ui.Id,value:base.Asset_Id,kind:asset.Fourcc,label:string,selected:bool,cell:f32) -> (it:ui.Interaction) {
    view:=asset_cards_view(s)
    if view.mode==.List {return asset_list_row_begin(s,id,value,kind,label,selected)}
    ctx:=s.gui.ctx
    th:=&ctx.theme
    it=ui.interact(ctx,id,{.Focusable})
    file:^asset.Registry_File
    if value!={} && s.app!=nil && s.app.assets!=nil {file,_=asset.registry_find(&s.app.assets.registry,value)}
    ui.box_begin(ctx,asset_card_box(ctx,id,view,cell,selected,content_keyboard(ctx,it)))
    if file!=nil {
        asset_thumbnail(s,file,cell-2*CONTENT_PAD,it.hot,selected=selected)
    } else {
        color:=asset_kind_color(s,kind)
        icon,_:=asset_icon(s,kind)
        side:=cell-2*CONTENT_PAD
        edge,width:=asset_frame_edge(th,it.hot,selected)
        asset_frame(s,side,color,edge,width,{},icon,color,kind)
    }
    if view.show_names {content_name(ctx,label,selected,cell)}
    if it.hot && (!view.show_names || content_name_cut(ctx,label,cell)) {ui.tooltip(ctx,label)}
    return
}

asset_card_end :: proc(s:^Session) {ui.box_end(s.gui.ctx,{})}

// Where what goes over a card of the grid floats: the top left corner of its
// thumbnail. In the list it follows the label.
asset_card_float :: proc(s:^Session) -> ui.Float {
    if asset_cards_view(s).mode==.List {return {}}
    return {to=.Parent,anchor=.Top_Left,pivot=.Top_Left,offset={CONTENT_PAD+3,CONTENT_PAD+3}}
}

// Whether the name under a card of a cell takes more than its names lines:
// then it is cut and the pointer on the card shows it whole.
@(private)
content_name_cut :: proc(ctx:^ui.Context,name:string,cell:f32,names:u8=2) -> bool {
    lines:=ui.text_lines(&ctx.font,name,ctx.theme.font,cell-2*CONTENT_PAD-2,.Words)
    count:=0
    for {
        _,_,ok:=ui.text_lines_next(&lines)
        if !ok {break}
        count+=1
        if count>int(names if names>0 else 2) {return true}
    }
    return false
}

// The name under the thumbnail of a card of a cell, in up to names lines
// as wide as it, the last ending in an ellipsis when more does not fit.
@(private)
content_name :: proc(ctx:^ui.Context,name:string,selected:bool,cell:f32,names:u8=2) {
    th:=&ctx.theme
    if ui.box(ctx,{width=ui.fixed(cell-2*CONTENT_PAD),height=ui.fixed(f32(names if names>0 else 2)*CONTENT_NAME_LINE+2),padding={1,0,1,0}}) {
        style:=ui.Text_Style{font=ui.FONT_MEDIUM if selected else 0,size=th.font,color=th.text if selected else th.text_label,wrap=.Words,ellipsis=true,line_height=CONTENT_NAME_LINE/th.font}
        ui.text(ctx,name,style,ui.GROW,ui.GROW)
    }
}

// The border of a thumbnail and its width: faint, lighter under the
// pointer, and violet while it is selected.
@(private)
asset_frame_edge :: proc(th:^ui.Theme,hot,selected:bool) -> (ui.Color,f32) {
    if selected {return th.toggle_on_stroke,1}
    return th.border if hot else CONTENT_FRAME_EDGE,1
}

// The thumbnail of an asset of a card, a row or a field: its preview over a
// dark square with a faint border and the line of the color of its type
// under it. clip: a clip of an animation, from 1, which shows Play until its
// preview is there.
@(private)
asset_thumbnail :: proc(s:^Session,file:^asset.Registry_File,side:f32,hot:bool=false,clip:u32=0,selected:bool=false) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    color:=asset_file_color(s,file)
    icon,_,quad:=content_preview(s,file,side,clip)
    if clip>0 && quad.kind==.Solid {icon=.Play}
    edge,width:=asset_frame_edge(th,hot,selected)
    asset_frame(s,side,color,edge,width,quad,icon,th.accent if clip>0 else color,file.kind)
}

// The clip a card of a clip is in its animation, from 1; 0 for the card of a file.
@(private)
content_clip_index :: proc(c:^Content,card:Content_Card) -> u32 {
    if card.clip<=0 || int(card.clip)>len(c.clips) {return 0}
    at:=int(card.clip)-1
    library:=c.clips[at].library
    first:=at
    for first>0 && c.clips[first-1].library==library {first-=1}
    return u32(at-first+1)
}

// A square of side points with the border of stroke, a preview or an icon in
// the middle and the line of color along its bottom. The line is part of the
// layout, not a float, so a list that clips the square clips it too.
@(private)
asset_frame :: proc(s:^Session,side:f32,color,stroke:ui.Color,stroke_width:f32,quad:ui.Quad,icon:ui.Icon,icon_color:ui.Color,kind:asset.Fourcc) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    if ui.box(ctx,{width=ui.fixed(side),height=ui.fixed(side),direction=.Column,padding={1,1,1,1},fill=CONTENT_FRAME,stroke=stroke,stroke_width=stroke_width,radius=4 if side>24 else 3}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.GROW,align_x=.Center,align_y=.Center}) {
            if quad.kind!=.Solid {
                inner:=side-2 if kind==asset.KIND_TEXTURE || kind==asset.KIND_SCENE else side*(0.78 if kind==asset.KIND_MATERIAL else 0.86)
                ui.image(ctx,{quad=quad,width=ui.fixed(min(inner,side-2)),height=ui.fixed(min(inner,side-2-CONTENT_BAR))})
            } else if icon!=.None {ui.icon(ctx,icon,icon_color,side*0.42)}
        }
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(CONTENT_BAR),fill=color}) {}
    }
}

// The star that marks an asset as a favorite.
@(private)
content_star :: proc(s:^Session,id:ui.Id,asset_id:base.Asset_Id,favorite:bool,float:ui.Float={}) {
    ctx:=s.gui.ctx
    if ui.box(ctx,{width=ui.FIT,height=ui.FIT,float=float,fill={20,22,27,217} if float.to!=.None else {},radius=3}) {
        if ui.button(ctx,id,{icon=ui.icon_user(u8(User_Icon.Star_Filled if favorite else User_Icon.Star)),icon_color=STAR_COLOR if favorite else ctx.theme.text_muted,style=.Ghost,width=18,height=18,icon_size=12,padding=-1,center=true}).clicked {
            content_favorite_toggle(s.content,asset_id)
        }
    }
}

// The arrow of a library or an owner that shows or hides its clips or parts.
@(private)
content_expander :: proc(s:^Session,card:Content_Card,key:u64,float:ui.Float) {
    ctx:=s.gui.ctx
    if ui.box(ctx,{width=ui.FIT,height=ui.FIT,float=float,fill={20,22,27,217} if float.to!=.None else {},radius=3}) {
        if ui.button(ctx,ui.id(ctx,"content_unfold",int(key)),{icon=.Chevron_Down if card.open else .Chevron_Right,icon_color=ctx.theme.text_muted,style=.Ghost,width=16,height=22,icon_size=12}).clicked {
            content_unfold(s.content,s.app.assets.registry.files[card.file].id)
        }
    }
}

// What tells a card from the others: its path, its clip, whether it shows after
// its owner and whether it is in Recent or Favorites, where an asset of a
// folder also is.
@(private)
content_card_key :: proc(path:string,card:Content_Card,group:u64) -> u64 {
    key:=base.hash64(transmute([]u8)path)~u64(card.clip)
    if card.part {key~=0xc2b2ae3d27d4eb4f}
    if group==CONTENT_RECENT_GROUP || group==CONTENT_FAVORITES_GROUP {key~=group*0x9e3779b97f4a7c15}
    return key
}

@(private)
content_card_selected :: proc(s:^Session,file:^asset.Registry_File,clip:i32) -> bool {
    c:=s.content
    g:=s.gui
    if clip!=0 {return c.selected==file.id && c.selected_clip==clip}
    return c.selected==file.id && c.selected_clip==0 || slice.contains(c.picked[:],file.id) || g.drag.kind==.Asset && g.drag.asset_id==file.id || g.placement.active && g.placement.kind==.Asset && g.placement.asset_id==file.id
}

// A card of the grid or a row of the list, with its star, the arrow of a
// library and the mark of unsaved changes.
@(private)
// whole: its line is all in sight; the buttons that float over a card stay out
// of one the edge of the list cuts, as floats are not clipped.
content_item :: proc(s:^Session,card:Content_Card,group:u64,depth:u16,cell:f32,whole:bool=true,names:u8=2) -> (it:ui.Interaction,id:ui.Id) {
    c:=s.content
    ctx:=s.gui.ctx
    th:=&ctx.theme
    registry:=&s.app.assets.registry
    file:=&registry.files[card.file]
    key:=content_card_key(file.path,card,group)
    id=ui.id(ctx,"content_entry",int(key))
    it=ui.interact(ctx,id,{.Focusable})
    selected:=content_card_selected(s,file,card.clip)
    star:=ui.id(ctx,"content_star",int(key))
    favorite:=card.clip==0 && content_favorite(&c.marks,file.id)
    starred:=card.clip==0 && (favorite || it.hot || ctx.hot==star)
    unsaved:=card.clip==0 && asset_unsaved(s,file.id)
    if c.view.mode==.List {
        indent:=CONTENT_INSET+f32(depth+(1 if card.clip>0 || card.part else 0))*CONTENT_INDENT
        if ui.box(ctx,asset_row_box(ctx,id,indent,selected,it.hot,content_keyboard(ctx,it))) {
            asset_thumbnail(s,file,20,clip=content_clip_index(c,card))
            ui.label(ctx,card.name,th.font,th.text,0,font=ui.FONT_MEDIUM if selected else 0)
            described:=asset_kind_label(s,file.kind)
            if card.clip>0 {
                described="Clip"
            } else if content_part(registry,file) {
                owner,_:=asset.registry_find(registry,file.owner)
                described=fmt.tprintf("in %s",asset_name(owner.path))
            }
            ui.label(ctx,described,th.font_small,th.text_faint)
            if unsaved {
                if ui.box(ctx,{width=ui.fixed(5),height=ui.fixed(5),fill=UNSAVED_COLOR,radius=2.5}) {}
            }
            if card.holds {content_expander(s,card,key,{})}
            if starred {content_star(s,star,file.id,favorite)} else {ui.spacer(ctx,18,18)}
        }
        return
    }
    if ui.box(ctx,asset_card_box(ctx,id,c.view,cell,selected,content_keyboard(ctx,it),names)) {
        asset_thumbnail(s,file,cell-2*CONTENT_PAD,it.hot,content_clip_index(c,card),selected)
        if c.view.show_names {content_name(ctx,card.name,selected,cell,names)}
        inset:=CONTENT_PAD+3
        if starred && whole {content_star(s,star,file.id,favorite,{to=.Parent,anchor=.Top_Left,pivot=.Top_Left,offset={inset,inset}})}
        if card.holds && whole {content_expander(s,card,key,{to=.Parent,anchor=.Top_Right,pivot=.Center_Right,offset={-CONTENT_PAD-2,cell*0.5}})}
        if unsaved && whole {
            if ui.box(ctx,{width=ui.fixed(5),height=ui.fixed(5),fill=UNSAVED_COLOR,radius=2.5,float={to=.Parent,anchor=.Top_Right,pivot=.Top_Right,offset={-inset-2,inset+2}}}) {}
        }
    }
    if it.hot && (!c.view.show_names || content_name_cut(ctx,card.name,cell,names)) {ui.tooltip(ctx,card.name)}
    return
}

// The name of a folder, Recent or Favorites, with the arrow that opens it and
// a line under it while a group of the first level is open and holds
// something. In Shelves, the
// cover of a folder and the count of the assets under it too, in width.
// marked: the folder the menu of Create makes in.
@(private)
content_header :: proc(s:^Session,line:Content_Line,id:ui.Id,width:f32,marked:bool=false) -> ui.Interaction {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    it:=ui.interact(ctx,id,{.Focusable})
    icon,color:=ui.icon_user(u8(User_Icon.Folder)),th.text_faint
    if line.group==CONTENT_RECENT_GROUP {icon,color=.History,th.text_muted}
    if line.group==CONTENT_FAVORITES_GROUP {icon,color=ui.icon_user(u8(User_Icon.Star_Filled)),STAR_COLOR}
    height:=CONTENT_HEADER if line.depth==0 else CONTENT_SUBHEADER
    shelves:=s.content!=nil && s.content.view.arrangement==.Shelves
    // The line is in the flow: what floats is not cut by the list that scrolls it.
    ruled:=line.open && line.depth==0 && line.count>0
    if ui.box(ctx,{width=ui.fixed(width),height=ui.fixed(height),direction=.Column}) {
        if ui.box(ctx,{id=id,width=ui.GROW,height=ui.fixed(height-1 if ruled else height),padding={CONTENT_INSET+f32(line.depth)*CONTENT_INDENT,0,8,0},gap=7,align_y=.Center,fill=th.field if it.hot || marked else th.panel,radius=3}) {
            ui.icon(ctx,.Chevron_Down if line.open else .Chevron_Right,th.text_faint,10)
            ui.icon(ctx,icon,color,14)
            if line.cover>0 {
                cover:=texture_quad(s,s.app.assets.registry.files[line.cover-1].id)
                if ui.box(ctx,{width=ui.fixed(CONTENT_COVER),height=ui.fixed(CONTENT_COVER),fill=th.field,radius=3,clip_x=true,clip_y=true}) {
                    if cover.kind!=.Solid {ui.image(ctx,{quad=cover,width=ui.GROW,height=ui.GROW})}
                }
            }
            ui.label(ctx,line.name,th.font if line.depth==0 else th.font_small,th.text if line.open else th.text_muted,0,font=ui.FONT_MEDIUM if line.depth==0 else 0)
            if shelves {ui.label(ctx,fmt.tprintf("%d",line.count),th.font_small,th.text_faint)}
        }
        if ruled {
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=th.divider}) {}
        }
    }
    return it
}

@(private)
content_chips_popup :: proc(g:^Editor_Ui) -> ui.Id {return shell_id(g,"content_chips")}

// The kinds of plugins the browser lists that have a chip.
@(private)
content_chip_kinds :: proc(c:^Content) -> []asset.Fourcc {
    for kind,at in c.view.chip_kinds {
        if kind==0 {return c.view.chip_kinds[:at]}
    }
    return c.view.chip_kinds[:]
}

// Gives a kind of a plugin a chip, or takes it away; the filter it had goes
// with it.
@(private)
content_chip_kind_flip :: proc(c:^Content,kind:asset.Fourcc) {
    kinds:=content_chip_kinds(c)
    if at,found:=slice.linear_search(kinds,kind);found {
        copy(c.view.chip_kinds[at:],c.view.chip_kinds[at+1:])
        c.view.chip_kinds[len(c.view.chip_kinds)-1]=0
        if on,taken:=slice.linear_search(c.kinds[:],kind);taken {ordered_remove(&c.kinds,on)}
        return
    }
    if len(kinds)<len(c.view.chip_kinds) {c.view.chip_kinds[len(kinds)]=kind}
}

// What the chips under the search are: each family and each kind of a plugin
// listed, with its icon and its color, and a box that gives it a chip. A
// click keeps the menu open.
@(private)
content_chips_menu :: proc(s:^Session) {
    c:=s.content
    ctx:=s.gui.ctx
    popup:=content_chips_popup(s.gui)
    if ui.popup(ctx,popup,{min_width=170}) {
        ui.id_push(ctx,popup)
        defer ui.id_pop(ctx)
        ui.menu_header(ctx,"One-click filters")
        row :: proc(ctx:^ui.Context,id:ui.Id,label:string,icon:ui.Icon,color:ui.Color,on:bool) -> bool {
            th:=&ctx.theme
            it:=ui.interact(ctx,id,{.Focusable})
            if ui.box(ctx,{id=id,width=ui.GROW,height=ui.fixed(th.control),padding={8,0,8,0},gap=8,align_y=.Center,fill=ui.color_hover(th) if it.hot else {},radius=th.radius_control}) {
                if ui.box(ctx,{width=ui.fixed(12),height=ui.fixed(12),align_x=.Center,align_y=.Center,fill=th.toggle_on if on else {},stroke=th.toggle_on_stroke if on else th.well_stroke_hover,stroke_width=1,radius=2}) {
                    if on {ui.icon(ctx,.Check,th.text,10)}
                }
                ui.icon(ctx,icon,color,14)
                ui.label(ctx,label,th.font,th.text,0)
            }
            return it.clicked
        }
        labels:=CONTENT_CATEGORY_LABELS
        kinds:=CONTENT_CATEGORY_KINDS
        for category in Content_Category {
            icon,color:=asset_icon(s,kinds[category])
            if !row(ctx,ui.id(ctx,"category",int(category)+1),labels[category],icon,color,category in c.view.chips) {continue}
            if category in c.view.chips {
                c.view.chips-={category}
                c.categories-={category}
            } else {c.view.chips+={category}}
            c.scroll=0
        }
        for kind in c.present_kinds {
            icon,_:=asset_icon(s,kind)
            if row(ctx,ui.id(ctx,"kind",int(kind)),asset_kind_label(s,kind),icon,asset_kind_color(s,kind),slice.contains(content_chip_kinds(c),kind)) {
                content_chip_kind_flip(c,kind)
                c.scroll=0
            }
        }
    }
}

// The chips under the search: a click on one shows only its family or its
// kind, with others on; the bar of each takes its color while it is on.
@(private)
content_chips :: proc(s:^Session,width:f32) -> f32 {
    c:=s.content
    ctx:=s.gui.ctx
    th:=&ctx.theme
    labels:=CONTENT_CATEGORY_LABELS
    kinds:=CONTENT_CATEGORY_KINDS
    font:=th.font_small
    Chip :: struct {category:Content_Category,kind:asset.Fourcc,label:string}
    chips:=make([dynamic]Chip,context.temp_allocator)
    for category in Content_Category {
        if category in c.view.chips {append(&chips,Chip{category,0,labels[category]})}
    }
    for kind in content_chip_kinds(c) {
        if slice.contains(c.present_kinds[:],kind) {append(&chips,Chip{kind=kind,label=asset_kind_label(s,kind)})}
    }
    if len(chips)==0 {return 0}
    // The bar, the gap, the label as ui.label measures it and the room after it.
    chip_width :: proc(ctx:^ui.Context,text:string,font:f32) -> f32 {return 3+6+ui.text_width(&ctx.font,text,font)+1+8}
    // Where each row ends: as many as fit in the width.
    ends:=make([dynamic]int,context.temp_allocator)
    for at:=0;at<len(chips); {
        used:=f32(0)
        for at<len(chips) {
            w:=chip_width(ctx,chips[at].label,font)
            if used>0 && used+3+w>width {break}
            used+=(3 if used>0 else 0)+w
            at+=1
        }
        append(&ends,at)
    }
    height:=f32(len(ends))*20+f32(len(ends)-1)*3
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(height),direction=.Column,gap=3}) {
        at:=0
        for end in ends {
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(20),gap=3}) {
                for chip in chips[at:end] {
                    id:=ui.id(ctx,"content_category",int(chip.category)+1) if chip.kind==0 else ui.id(ctx,"content_kind",int(chip.kind))
                    it:=ui.interact(ctx,id,{.Focusable})
                    on:=chip.category in c.categories if chip.kind==0 else slice.contains(c.kinds[:],chip.kind)
                    color:=asset_color(kinds[chip.category]) if chip.kind==0 else asset_kind_color(s,chip.kind)
                    if ui.box(ctx,{id=id,width=ui.FIT,height=ui.fixed(20),padding={0,0,8,0},gap=6,align_y=.Center,fill=ctx.theme.chip_on if on || it.hot else ctx.theme.chip,radius=2,clip_x=true}) {
                        if ui.box(ctx,{width=ui.fixed(3),height=ui.GROW,fill=color if on else ctx.theme.rule}) {}
                        ui.label(ctx,chip.label,font,th.text if on else th.text_caption)
                    }
                    if it.clicked {
                        switch {
                        case chip.kind!=0 && on:
                            if found,ok:=slice.linear_search(c.kinds[:],chip.kind);ok {ordered_remove(&c.kinds,found)}
                        case chip.kind!=0: append(&c.kinds,chip.kind)
                        case on:           c.categories-={chip.category}
                        case:              c.categories+={chip.category}
                        }
                        c.scroll=0
                    }
                }
            }
            at=end
        }
    }
    return height
}

// The bar under the list of a width: how many assets are selected, or listed
// while none is, the step of the cards (as Ctrl+wheel) and the grid or the list.
@(private)
content_footer :: proc(s:^Session,width:f32) {
    c:=s.content
    ctx:=s.gui.ctx
    th:=&ctx.theme
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(CONTENT_FOOTER),direction=.Column}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=th.divider}) {}
        if ui.box(ctx,{width=ui.GROW,height=ui.GROW,padding={CONTENT_INSET+2,0,0,0},gap=8,align_y=.Center}) {
            ui.label(ctx,content_count_text(c),th.font_small,th.text_faint,0)
            list:=c.view.mode==.List
            most,fewest:=content_levels(width)
            level:=f64(content_level(c.view,width))
            if ui.slider_field(ctx,ui.id(ctx,"content_size"),&level,{width=ui.fixed(70),height=20,min=0,max=f64(most-fewest+1),has_min=true,has_max=true,integer=true,bare=true}).changed {
                content_level_set(&c.view,width,int(level))
                c.scroll=0
            }
            if ui.box(ctx,{width=ui.FIT,height=ui.FIT,padding=ui.padding_all(1),gap=1,fill=th.well,radius=th.radius_control}) {
                if ui.button(ctx,ui.id(ctx,"content_grid"),{icon=.Grid,icon_size=12,icon_color=th.text if !list else th.text_muted,style=.Toggle,active=!list,width=22,height=20}).clicked && list {
                    content_view_resize(&c.view,c.view.size)
                    c.scroll=0
                }
                if ui.button(ctx,ui.id(ctx,"content_list_mode"),{icon=ui.icon_user(u8(User_Icon.List)),icon_size=12,icon_color=th.text if list else th.text_muted,style=.Toggle,active=list,width=22,height=20}).clicked && !list {
                    c.view.mode=.List
                    c.scroll=0
                }
            }
        }
    }
}

// What the bar under the list says: how many assets are selected, or how
// many are listed while none is.
@(private)
content_count_text :: proc(c:^Content) -> string {
    if selected:=content_selected_count(c);selected>0 {return fmt.tprintf("%d selected",selected)}
    return fmt.tprintf("%d %s",c.results,"asset" if c.results==1 else "assets")
}

@(private)
content_asset_action :: proc(s:^Session,w:core.World_Ref,card:Content_Card,it:ui.Interaction) -> string {
    c:=s.content
    g:=s.gui
    file:=&s.app.assets.registry.files[card.file]
    if card.clip>0 {
        // A clip of a library: it opens in the document of the library, and
        // what it is let go on plays it (asset_drop_take).
        if it.pressed {
            d:=Drag{kind=.Asset,asset_id=file.id,asset_kind=file.kind}
            base.text_set(d.part[:],card.name)
            drag_begin(g,d,card.name)
        }
        if it.clicked {
            clear(&c.picked)
            c.selected,c.selected_clip=file.id,card.clip
        }
        if it.double && s.mode!=.Play && asset_document_opens(s,file.kind) {
            g.drag,g.placement={},{}
            content_used(s,file.id)
            asset_document_open(s,file.id,card.name)
        }
        return ""
    }
    // Ctrl or Shift adds to the selection or takes from it, and does nothing else.
    if .Primary in g.ctx.input.modifiers || .Shift in g.ctx.input.modifiers {
        if it.clicked {
            content_place_set(c,content_folder_of(file.path))
            content_select(c,file.id,true)
        }
        return ""
    }
    if it.pressed {drag_begin(g,{kind=.Asset,asset_id=file.id,asset_kind=file.kind},card.name)}
    if it.clicked || it.right {content_place_set(c,content_folder_of(file.path))}
    if it.clicked {content_select(c,file.id,false)}
    if it.right {
        if !content_selected(c,file.id) {content_select(c,file.id,false)}
        c.menu=file.id
        ui.popup_open(g.ctx,content_menu_id(g),{g.ctx.pointer.x,g.ctx.pointer.y,0,0})
    }
    // While an asset document covers the scene, a click does nothing to it.
    scene:=!scene_covered(s)
    switch {
    case it.double && s.mode!=.Play && file.kind!=asset.KIND_SCENE && file.kind!=asset.KIND_PREFAB && asset_document_opens(s,file.kind):
        g.drag,g.placement={},{}
        content_used(s,file.id)
        asset_document_open(s,file.id)
    case file.kind==asset.KIND_MATERIAL && it.clicked && s.mode!=.Play && scene:
        if meshes:=selected_meshes(s,w);len(meshes)>0 {
            content_used(s,file.id)
            material_assign(s,w,meshes[:],file.id)
        }
    case it.clicked && s.mode!=.Play && scene && asset_kind_click(s,w,file):
    case (file.kind==asset.KIND_SCENE || file.kind==asset.KIND_PREFAB) && it.double && s.mode==.Edit:
        g.drag,g.placement={},{}
        content_used(s,file.id)
        return file.path
    }
    return ""
}

// The selected entities that show a mesh, which a material is assigned to.
@(private)
selected_meshes :: proc(s:^Session,w:core.World_Ref) -> []core.Entity {
    meshes:=make([dynamic]core.Entity,context.temp_allocator)
    for e in s.selection.entities {
        if entity_has(w,e,erender.Mesh_Renderer) {append(&meshes,e)}
    }
    return meshes[:]
}

@(private)
content_menu_id :: proc(g:^Editor_Ui) -> ui.Id {return shell_id(g,"content_menu")}

// The menu of a card, as the prototype has it: open the asset, assign a
// material to the selection, star it, and take what a scene open in a tab
// shows as its thumbnail. Returns the path of a scene or prefab to open.
@(private)
content_menu :: proc(s:^Session,w:core.World_Ref) -> (open:string) {
    c:=s.content
    g:=s.gui
    ctx:=g.ctx
    popup:=content_menu_id(g)
    a:=s.app.assets
    file:^asset.Registry_File
    found:=false
    if a!=nil {file,found=asset.registry_find(&a.registry,c.menu)}
    if !found {
        if ui.popup_is_open(ctx,popup) {ui.popup_close(ctx,popup)}
        return
    }
    if ui.popup(ctx,popup,{min_width=200}) {
        ui.id_push(ctx,popup)
        defer ui.id_pop(ctx)
        document:=file.kind==asset.KIND_SCENE || file.kind==asset.KIND_PREFAB
        opens:=document?s.mode==.Edit:s.mode!=.Play && asset_document_opens(s,file.kind)
        icon,_:=asset_icon(s,file.kind)
        if ui.menu_item(ctx,ui.id(ctx,"open"),"Open",{icon=icon,disabled=!opens}) {
            g.drag,g.placement={},{}
            content_used(s,file.id)
            if document {open=file.path} else {asset_document_open(s,file.id)}
        }
        if file.kind==asset.KIND_MATERIAL {
            meshes:=selected_meshes(s,w)
            if ui.menu_item(ctx,ui.id(ctx,"apply"),"Apply to selection",{icon=.Sphere,disabled=len(meshes)==0 || s.mode==.Play || watching(s) || scene_covered(s)}) {
                content_used(s,file.id)
                material_assign(s,w,meshes,file.id)
            }
        }
        if file.kind==asset.KIND_SOUND || file.kind==asset.KIND_SOUND_SET {
            heard:=sound_heard(s,file.id)
            if ui.menu_item(ctx,ui.id(ctx,"listen"),"Stop sound" if heard else "Play sound",{icon=heard?.Stop:.Play,disabled=s.app.mixer==nil}) {
                if heard {sound_hear_stop(s)} else {sound_hear(s,file.id)}
            }
        }
        if file.kind==asset.KIND_PREFAB {
            if ui.menu_item(ctx,ui.id(ctx,"variant"),"Create variant",{icon=.Prefab,disabled=s.mode!=.Edit || watching(s)}) {
                path:=prefab_variant_path(s,file.id)
                _,error:=prefab_variant_create(s,file.id,path)
                notify(s,error==.None?fmt.tprintf("Prefab variant %s created",path):prefab_error_text(error))
                return // writing the file may move the entries of the registry
            }
        }
        if file.kind==asset.KIND_SCENE && scene_tab(s,file.id)>=0 {
            if ui.menu_item(ctx,ui.id(ctx,"thumbnail"),"Update thumbnail",{icon=action_icon(.Scene_Thumbnail),disabled=s.mode!=.Edit || !scene_thumbnails_kept(s)}) {scene_thumbnail_update(s,file.id)}
        }
        asset_plugin_menus(s,file)
        if ui.menu_item(ctx,ui.id(ctx,"ask"),"Ask agent",{icon=.Sparkle,disabled=!s.has_project}) {
            asked:=make([dynamic]base.Asset_Id,context.temp_allocator)
            append(&asked,file.id,c.selected)
            append(&asked,..c.picked[:])
            ai_ask(s,asked[:])
        }
        favorite:=content_favorite(&c.marks,file.id)
        if ui.menu_item(ctx,ui.id(ctx,"favorite"),"Remove from favorites" if favorite else "Add to favorites",{icon=ui.icon_user(u8(User_Icon.Star))}) {content_favorite_toggle(c,file.id)}
        // What Create makes, beside it in its folder.
        if ui.submenu(ctx,ui.id(ctx,"new"),"Create",{icon=.Plus}) {content_create_items(s,content_folder_of(file.path))}
        ui.menu_separator(ctx)
        // Duplicating and moving scan the registry again: what follows names the asset by its id.
        id:=file.id
        off:=asset_create_refusal(s)!=""
        if ui.menu_item(ctx,ui.id(ctx,"rename"),"Rename",{icon=action_icon(.Rename),shortcut=shortcut_text(ACTION_SHORTCUTS[.Rename]),disabled=off}) {content_rename_begin(s,id)}
        if ui.menu_item(ctx,ui.id(ctx,"duplicate"),"Duplicate",{icon=action_icon(.Duplicate),shortcut=shortcut_text(ACTION_SHORTCUTS[.Duplicate]),disabled=off}) {content_duplicate(s,id)}
        if ui.submenu(ctx,ui.id(ctx,"move"),"Move to",{icon=ui.icon_user(u8(User_Icon.Folder)),disabled=off}) {content_move_items(s,id,"")}
        if ui.menu_item(ctx,ui.id(ctx,"delete"),"Delete",{icon=action_icon(.Delete),shortcut="Del",danger=true,disabled=s.mode!=.Edit || watching(s)}) {asset_delete_ask(s,id)}
    }
    return
}

// The asset whose card has the keyboard, as content_typing tells it; zero for none.
content_focused :: proc(c:^Content,ctx:^ui.Context) -> base.Asset_Id {
    if c==nil || c.card_focus==0 || ctx.focus!=c.card_focus || ctx.edit.id!=0 {return {}}
    if _,built:=ui.widget_rect(ctx,c.card_focus);!built {return {}}
    return c.focus_asset
}

// What is typed while a card of the browser has the keyboard searches: the
// card focused when the browser was built in the last frame still has it.
content_typing :: proc(c:^Content,ctx:^ui.Context) -> bool {
    if c==nil || c.card_focus==0 || ctx.focus!=c.card_focus || ctx.edit.id!=0 || ctx.input.text_count==0 || ctx.input.modifiers-{.Shift}!={} {return false}
    _,built:=ui.widget_rect(ctx,c.card_focus)
    return built
}

// Shows an asset in the browser: Find in Content Browser of a field of Details.
// The filters that could hide it go before the search is shown again.
content_reveal :: proc(s:^Session,id:base.Asset_Id) {
    c:=s.content
    if c==nil || id=={} {return}
    c.reveal=id
    c.filter_length,c.categories,c.unused=0,{},false
    clear(&c.kinds)
    clear(&c.picked)
    library_select(s,.Content)
}

@(private)
content_build :: proc(s:^Session,w:core.World_Ref,height:f32,width:f32=CONTENT_WIDTH) {
    width:=width
    c:=s.content
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    a:=s.app.assets
    filter_id:=ui.id(ctx,"content_filter")
    if content_typing(c,ctx) {
        typed:=string(ctx.input.text[:ctx.input.text_count])
        c.filter_length+=copy(c.filter[c.filter_length:],typed)
        c.scroll=0
        ui.edit_request(ctx,filter_id)
    }
    c.card_focus=0
    if c.focus_search {
        ui.edit_request(ctx,filter_id)
        c.focus_search=false
    }
    toggled,flip_all:=u64(0),false
    open_path:string
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(height),direction=.Column,gap=5}) {
        used:=f32(28)+5+CONTENT_FOOTER
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(28),gap=3,align_y=.Center}) {
            if search_field(s,filter_id,c.filter[:],&c.filter_length,"Search assets") {c.scroll=0}
            chips:=content_chips_popup(g)
            chips_open:=ui.popup_is_open(ctx,chips)
            filter_button:=ui.id(ctx,"content_chips_open")
            if ui.button(ctx,filter_button,{icon=.Filter,icon_color=th.text_muted,tip="Filters",style=.Toggle,active=chips_open,width=28,height=28}).clicked && !chips_open {
                anchor,_:=ui.widget_rect(ctx,filter_button)
                ui.popup_open(ctx,chips,anchor)
            }
            // With everything closed it opens everything instead.
            collapsed:=content_collapsed(c)
            if ui.button(ctx,ui.id(ctx,"content_collapse"),{icon=ui.icon_user(u8(collapsed?User_Icon.Expand:User_Icon.Collapse)),icon_color=th.text_muted,tip=collapsed?"Expand all":"Collapse all",style=.Ghost,width=28,height=28,disabled=a==nil}).clicked && a!=nil {
                if collapsed {content_expand(c,&a.registry)} else {content_collapse(c)}
            }
        }
        if import_working(s) {used+=th.row+5}
        if a==nil {
            ui.label(ctx,"No assets folder",th.font_small,th.text_faint)
            return
        }
        if !a.indexed && len(a.registry.files)==0 && a.registry.revision==0 {
            _=asset.registry_scan(&a.registry)
        }
        opened:=content_plugin_kinds(s)
        content_clips_read(c,a)
        content_registry_read(c,&a.registry,opened,&a.types)
        if c.restore {content_navigation_restore(c,&a.registry)}
        if c.creating && asset_create_refusal(s)!="" {content_create_end(c)}
        if c.created!={} {content_created(s,&a.registry)}
        if c.reveal!={} {content_reveal_open(c,&a.registry)}
        if chips:=content_chips(s,width);chips>0 {used+=5+chips}
        lines:=content_lines(c,&a.registry,width,opened,&ctx.font,th.font)
        room:=max(height-used-5,CONTENT_ROW)
        // A list taller than its room leaves its bar a column of its own.
        total:f32
        for h in c.heights {total+=h}
        if total>room {
            width-=ui.SCROLL_GUTTER
            lines=content_lines(c,&a.registry,width,opened,&ctx.font,th.font)
        }
        list:=ui.id(ctx,"content_list")
        // Ctrl+wheel resizes the cards and keeps the line in sight.
        if notches:=ui.zoom(ctx,list);notches!=0 {
            top:f32
            group:u64
            for h,i in c.heights {
                if top+h>c.scroll {group=lines[i].group;break}
                top+=h
            }
            content_zoom(&c.view,notches,width)
            lines=content_lines(c,&a.registry,width,opened,&ctx.font,th.font)
            c.scroll=0
            top=0
            for line,i in lines {
                if line.group==group {c.scroll=top;break}
                top+=c.heights[i]
            }
        }
        // The asset to show: in the middle of the list, selected, with the keyboard.
        if c.reveal!={} {
            top:f32
            for line,i in lines {
                if line.kind==.Cards {
                    for card in c.cards[line.first:][:line.count] {
                        if card.clip!=0 || a.registry.files[card.file].id!=c.reveal {continue}
                        c.scroll=max(top-room*0.5+c.heights[i]*0.5,0)
                        content_select(c,c.reveal,false)
                        ui.focus_set(ctx,ui.id(ctx,"content_entry",int(content_card_key(a.registry.files[card.file].path,card,line.group))))
                    }
                }
                top+=c.heights[i]
            }
            c.reveal={}
        }
        // The line of Create in sight when its name takes the keyboard.
        if c.create_edit {
            top:f32
            for line,i in lines {
                if line.kind==.Create {
                    if top<c.scroll || top+c.heights[i]>c.scroll+room {c.scroll=max(top-room*0.5,0)}
                    break
                }
                top+=c.heights[i]
            }
        }
        // Where no card or folder is, a right click opens Create and a click
        // clears the selection.
        area:=ui.id(ctx,"content_area")
        background:=ui.interact(ctx,area)
        if background.right {content_create_open(s,string(c.place[:c.place_length]),{ctx.pointer.x,ctx.pointer.y,0,0})}
        if background.clicked && ctx.input.modifiers&{.Primary,.Shift}=={} {content_select_clear(c)}
        ui.box_begin(ctx,{id=area,width=ui.GROW,height=ui.fixed(room),direction=.Column})
        creating:=ui.popup_is_open(ctx,content_create_id(g))
        create_into:=string(c.create_into[:c.create_into_length])
        finish,dropped:=false,false
        drop:string
        first,last:=ui.rows_begin(ctx,list,&c.scroll,c.heights[:],ui.GROW,room)
        top:f32
        for h in c.heights[:first] {top+=h}
        if len(lines)==0 {ui.label(ctx,"No results",th.font_small,th.text_faint)}
        for index in first..<last {
            line:=lines[index]
            whole_line:=top>=c.scroll-0.5 && top+c.heights[index]<=c.scroll+room+0.5
            top+=c.heights[index]
            switch line.kind {
            case .Header:
                folder:=line.group!=CONTENT_RECENT_GROUP && line.group!=CONTENT_FAVORITES_GROUP
                header:=ui.id(ctx,"content_folder",int(line.group))
                // A card carried over a folder moves there when it is let go.
                rect,built:=ui.widget_rect(ctx,header)
                carried:=folder && built && g.drag.kind==.Asset
                it:=content_header(s,line,header,width,folder && (creating && line.path==create_into || carried && drag_over(g,rect)))
                if carried && drag_dropped(g,rect) {dropped,drop=true,strings.clone(line.path,context.temp_allocator)}
                if it.clicked {
                    toggled=line.group
                    flip_all=.Alt in ctx.input.modifiers && line.depth==0 && folder
                }
                if folder && (it.clicked || it.right) {content_place_set(c,line.path)}
                if folder && it.right {content_create_open(s,line.path,{ctx.pointer.x,ctx.pointer.y,0,0},true)}
            case .Create:
                finish|=content_create_line(s,line)
            case .Cards:
                _,cell:=content_cells(c.view,width,line.depth)
                if c.view.mode==.List {cell=width}
                height:=c.heights[index]
                grid:=c.view.mode==.Grid
                inset:=CONTENT_INSET+f32(line.depth)*CONTENT_INDENT-CONTENT_PAD
                if ui.box(ctx,{width=ui.fixed(width),height=ui.fixed(height),padding={inset if grid else 0,content_line_top(c.view,line),CONTENT_INSET-CONTENT_PAD if grid else CONTENT_INSET,0},gap=CONTENT_CELL_GAP}) {
                    for card in c.cards[line.first:][:line.count] {
                        it,id:=content_item(s,card,line.group,line.depth,cell,whole_line,line.names)
                        if it.focused {c.card_focus,c.focus_asset=id,card.clip>0?base.Asset_Id{}:s.app.assets.registry.files[card.file].id}
                        if path:=content_asset_action(s,w,card,it);path!="" {open_path=path}
                    }
                }
            }
        }
        // The folders of the first two levels above the first line stay on top.
        if first<len(lines) {
            pinned:=f32(0)
            for depth in 0..<2 {
                header:=lines[first].parent[depth]
                if lines[first].kind==.Header && int(lines[first].depth)==depth {break}
                if header<0 {break}
                top:f32
                for h in c.heights[:header] {top+=h}
                if top>=c.scroll+pinned {break}
                if ui.box(ctx,{width=ui.fixed(width),height=ui.FIT,float={to=.Parent,anchor=.Top_Left,pivot=.Top_Left,offset={0,c.scroll+pinned}}}) {
                    if content_header(s,lines[header],ui.id(ctx,"content_sticky",depth+1),width).clicked {toggled=lines[header].group}
                }
                pinned+=c.heights[header]
            }
        }
        ui.rows_end(ctx,list,&c.scroll,c.heights[:],last)
        ui.box_end(ctx,{id=area})
        if finish {content_create_finish(s)}
        if dropped {content_drop(s,drop)}
        content_footer(s,width)
        if toggled!=0 {
            if flip_all {
                if content_group_open(c,toggled) {content_collapse(c)} else {content_expand(c,&a.registry)}
            } else {content_group_flip(c,toggled)}
        }
        if path:=content_menu(s,w);path!="" {open_path=path}
        content_create_menu(s)
        content_chips_menu(s)
        if open_path!="" {file_open_path(s,open_path)}
        host.assets_commit(a)
    }
}
