package asset

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:std/base"
import "mirai:std/serial"

// The kinds the engine defines. A kind is a fourcc, an extension and the
// tables a reader expects; a plugin adds its own by choosing another fourcc
// and extension and writing its tables through a Document.

KIND_MESH :: Fourcc(u32('M')|u32('E')<<8|u32('S')<<16|u32('H')<<24)
KIND_TEXTURE :: Fourcc(u32('T')|u32('E')<<8|u32('X')<<16|u32(' ')<<24)
KIND_MATERIAL :: Fourcc(u32('M')|u32('A')<<8|u32('T')<<16|u32(' ')<<24)
KIND_SCENE :: Fourcc(u32('S')|u32('C')<<8|u32('E')<<16|u32('N')<<24)
KIND_PREFAB :: Fourcc(u32('P')|u32('R')<<8|u32('F')<<16|u32('B')<<24)
KIND_ANIMATION :: Fourcc(u32('A')|u32('N')<<8|u32('I')<<16|u32('M')<<24)
KIND_SKELETON :: Fourcc(u32('S')|u32('K')<<8|u32('E')<<16|u32('L')<<24)
KIND_SOUND :: Fourcc(u32('S')|u32('N')<<8|u32('D')<<16|u32(' ')<<24)
KIND_SOUND_SET :: Fourcc(u32('S')|u32('S')<<8|u32('E')<<16|u32('T')<<24)
KIND_UI :: Fourcc(u32('U')|u32('I')<<8|u32(' ')<<16|u32(' ')<<24)
KIND_FRACTURE :: Fourcc(u32('F')|u32('R')<<8|u32('A')<<16|u32('C')<<24)
KIND_PHYSICS_CACHE :: Fourcc(u32('P')|u32('C')<<8|u32('A')<<16|u32('C')<<24)
KIND_FONT :: Fourcc(u32('F')|u32('O')<<8|u32('N')<<16|u32('T')<<24)
KIND_STRINGS :: Fourcc(u32('S')|u32('T')<<8|u32('R')<<16|u32('G')<<24)
KIND_PROMPTS :: Fourcc(u32('P')|u32('R')<<8|u32('M')<<16|u32('T')<<24)
KIND_RECORDS :: Fourcc(u32('R')|u32('C')<<8|u32('D')<<16|u32('S')<<24)

Kind_Info :: struct {
    kind:Fourcc,
    extension:string,
    name:string,
    version:u16, // the kind_version this build reads and writes (kind_check); 0 for a kind whose plugin keeps it
    presentation:bool, // only shown or heard: a dedicated server, which has neither renderer nor mixer, ships none
}

KINDS :: [?]Kind_Info{
    {KIND_MESH,".mesh","mesh",MESH_VERSION,false},
    {KIND_TEXTURE,".tex","texture",TEXTURE_VERSION,true},
    {KIND_MATERIAL,".mat","material",MATERIAL_VERSION,false},
    {KIND_SCENE,".scene","scene",SCENE_VERSION,false},
    {KIND_PREFAB,".prefab","prefab",SCENE_VERSION,false},
    {KIND_ANIMATION,".anim","animation",ANIMATION_VERSION,false},
    {KIND_SKELETON,".skeleton","skeleton",SKELETON_VERSION,false},
    {KIND_SOUND,".sound","sound",SOUND_VERSION,true},
    {KIND_SOUND_SET,".sound_set","sound set",SOUND_SET_VERSION,true},
    {KIND_UI,".ui","ui",UI_VERSION,true},
    {KIND_FRACTURE,".fracture","fracture",FRACTURE_VERSION,false},
    {KIND_PHYSICS_CACHE,".physics_cache","physics cache",0,false},
    {KIND_FONT,".font","font",FONT_VERSION,true},
    {KIND_STRINGS,".strings","strings",STRINGS_VERSION,false},
    {KIND_PROMPTS,".prompts","prompts",PROMPTS_VERSION,true},
    {KIND_RECORDS,".records","records",RECORDS_VERSION,false},
}

kind_of_extension :: proc(path:string) -> (kind:Fourcc,found:bool) {
    for info in KINDS {
        if strings.has_suffix(path,info.extension) {return info.kind,true}
    }
    return 0,false
}
kind_info :: proc(kind:Fourcc) -> (info:Kind_Info,found:bool) {
    for candidate in KINDS {
        if candidate.kind==kind {return candidate,true}
    }
    return {},false
}

// The rule of the versions of every kind, the engine's and the plugins':
//
//   - A kind reads the kind_version it writes and no other.
//   - A table, or a column of a row, added with a default keeps the version: a
//     file without it reads the default (asset_rows with a default, a table
//     that may be missing).
//   - A change of what a stored value means raises the version, and a file of
//     another one fails with Version: an imported asset is imported again
//     (version_message says how), and no reader keeps a path for old files.
//
// What every reader of a kind checks first.
kind_check :: proc "contextless" (a:^Asset,kind:Fourcc,version:u16) -> Error {
    if a.blob.header.kind!=kind {return .Invalid}
    if a.blob.header.kind_version!=version {return .Version}
    return .None
}

// What to tell of an asset that failed with Version: which file it is, its
// kind and version, and for an imported one the command that imports its
// source again into its folder. path: the file of the asset.
version_message :: proc(a:^Asset,types:^Types,path:string,allocator:=context.allocator) -> string {
    slashed :: proc(path:string) -> string {
        result,_:=strings.replace_all(path,"\\","/",context.temp_allocator)
        return result
    }
    // os.dir gives "" for a name without folders and "." for "": the walk up a
    // relative path ends at ".", as one of an absolute path ends at its root.
    parent :: proc(path:string) -> string {
        folder:=slashed(filepath.dir(path))
        return folder if folder!="" else "."
    }
    buffer:[4]u8
    kind:=fourcc_text(a.blob.header.kind,&buffer)
    if known,found:=kind_info(a.blob.header.kind);found {kind=known.name}
    stale:=fmt.tprintf("%s is a %s of version %d, which this build does not read",slashed(path),kind,a.blob.header.kind_version)
    info,_:=import_info(a,types)
    if info==nil {return fmt.aprintf("%s; it was not imported: write it again",stale,allocator=allocator)}
    source:=serial.text_field(info.source[:])
    folder:=parent(path)
    if filepath.is_abs(source) {return fmt.aprintf("%s; import its source again: mirai import %s --out %s",stale,source,folder,allocator=allocator)}
    // The source is named relative to the root of the import: the first folder above the asset that holds it.
    root:=folder
    for {
        joined,_:=filepath.join({root,source},context.temp_allocator)
        if os.exists(joined) {return fmt.aprintf("%s; import its source again: mirai import %s --out %s --root %s",stale,slashed(joined),folder,root,allocator=allocator)}
        up:=parent(root)
        if up==root {break}
        root=up
    }
    return fmt.aprintf("%s; import its source %s again with mirai import into %s",stale,source,folder,allocator=allocator)
}

// Where an asset built from a source file came from: what an importer needs
// to know whether it is out of date. It is the row of the table "import".
Import_Info :: struct {
    source:[260]u8 `mirai:"text"`,  // path of the source file, relative to the project
    name:[64]u8 `mirai:"text"`,     // what was taken from the source: a mesh, a material, an image
    index:i32,                      // its position among those of its kind in the source
    source_size:u64,                // bytes
    source_hash:u64,
    importer:[32]u8 `mirai:"text"`,
    importer_version:u32,
    settings_hash:u64,
}

TABLE_IMPORT :: "import"

// Records where the asset of doc came from, and marks it Cooked; nothing for a nil info.
import_put :: proc(doc:^Document,types:^Types,info:^Import_Info) -> Error {
    if info==nil {return .None}
    doc.flags+={.Cooked}
    _,error:=document_put_row(doc,types,TABLE_IMPORT,info,{.Import})
    return error
}

// Makes the asset of doc one that no import wrote: no owner, no import table,
// not Cooked; its id and everything else stay. What a copy made outside an
// editor becomes (registry_duplicates_resolve): an import of the source never
// writes it.
@(private)
document_detach :: proc(doc:^Document) {
    doc.owner={}
    doc.flags-={.Cooked}
    if table,found:=document_table(doc,TABLE_IMPORT);found {document_table_remove(doc,table)}
}

// nil for an asset that was not imported.
import_info :: proc(a:^Asset,types:^Types) -> (info:^Import_Info,error:Error) {
    if _,found:=asset_table(a,TABLE_IMPORT);!found {return nil,.None}
    return asset_row(a,types,TABLE_IMPORT,Import_Info)
}

// The header of an asset file and, for one that was imported, its
// Import_Info, read from the front of the file: the header, the directory and
// the chunks before the bulk data. What a search through the outputs of
// imports needs without reading whole meshes and textures. found is false for
// an asset without an import table. dependencies, when given, receives the ids
// the asset names.
import_peek :: proc(path:string,types:^Types,dependencies:^[dynamic]base.Asset_Id=nil) -> (header:Header,info:Import_Info,found:bool,error:Error) {
    head:[REGISTRY_HEAD]u8
    bytes,size,read_error:=serial.file_read_head(path,head[:])
    if read_error!=.None {return {},{},false,read_error==.Not_Found?.Not_Found:.IO}
    header=header_read(bytes) or_return
    if header.total_size!=u64(size) {return header,{},false,.Truncated}
    if .Cooked not_in header.flags && dependencies==nil {return header,{},false,.None}
    front,front_error:=front_read(path,bytes,header,false,context.temp_allocator)
    if front_error!=.None {return header,{},false,front_error}
    a:Asset
    asset_open_front(&a,front,context.temp_allocator) or_return
    defer asset_close(&a)
    if dependencies!=nil {append(dependencies,..a.dependencies)}
    if .Cooked not_in header.flags {return header,{},false,.None}
    row:=import_info(&a,types) or_return
    if row==nil {return header,{},false,.None}
    return header,row^,true,.None
}

// Copies a text into a field, cut at a character boundary if it is longer.
text_set :: proc(field:[]u8,text:string) {
    for &b in field {b=0}
    count:=min(len(text),len(field))
    for count>0 && count<len(text) && text[count]&0xc0==0x80 {count-=1}
    copy(field,text[:count])
}

@(private)
finite :: proc "contextless" (values:..f32) -> bool {
    for value in values {
        if value-value!=0 {return false}
    }
    return true
}

@(private)
table_rows :: proc(a:^Asset,types:^Types,name:string,$T:typeid,column:="") -> (rows:[]T,error:Error) {
    if _,found:=asset_table(a,name);!found {return nil,.None}
    return asset_rows(a,types,name,column,T)
}

@(private)
text_valid :: proc(field:[]u8) -> bool {return len(serial.text_field(field))<len(field)}
