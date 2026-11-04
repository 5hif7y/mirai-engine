package ui_inspector_editor

import "core:mem"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:editor/api"
import "mirai:std/serial"
import "mirai:ui"

// A hud with a named style and its rule, a localized title with a look of its
// own, a bar that holds a progress and a localized label without a name, and
// a button that plays an animation.
@(private="file")
document_sample :: proc(t:^testing.T,r:^Records) -> bool {
    texts:=make([dynamic]u8,context.temp_allocator)
    nodes:=[]ui.Tree_Node{
        ui.tree_node_record(&texts,-1,{kind=.Box,name="hud",float={to=.Safe,anchor=.Top_Left,pivot=.Top_Left}}),
        ui.tree_node_record(&texts,0,{kind=.Text,name="title",text="Trips",bind_text="trips"}),
        ui.tree_node_record(&texts,0,{kind=.Box,name="bar"}),
        ui.tree_node_record(&texts,2,{kind=.Progress,name="fuel",bind_value="fuel"}),
        ui.tree_node_record(&texts,2,{kind=.Text,text="Fuel"}), // without a name, as generated files have them
        ui.tree_node_record(&texts,-1,{kind=.Button,name="menu",text="Menu"}),
    }
    styles:=[]ui.Node_Style{{},{fill={20,20,30,255},radius={8,8,8,8}},{text={size=18}}}
    infos:=make([]ui.Tree_Style_Info,3,context.temp_allocator)
    ui.tree_text_set(infos[1].name[:],"card")
    infos[2].family=.Text
    if !testing.expect(t,records_load(r,{text=texts[:],nodes=nodes,styles=styles,style_infos=infos},context.allocator)) {return false}
    r.nodes[0].style,r.nodes[1].style=1,2
    append(&r.variants,ui.Tree_Style_Variant{style=1,states={.Hovered},patch={fields={.Fill},values={fill={40,40,60,255}}}})
    for row in ([2][2]int{{1,77},{4,78}}) {
        r.nodes[row[0]].flags+={.Localized}
        r.nodes[row[0]].text_id=u64(row[1])
        translation:=ui.Tree_Translation{id=u64(row[1])}
        ui.tree_text_set(translation.language[:],"es")
        append(&r.translations,translation)
        records_text_set(r,&r.translations[len(r.translations)-1].text,"Traducido")
    }
    pop:=records_clip(r,"pop",.Opacity,{0,0,0,0},{1,0,0,0},0.2)
    set:=records_anim_set(r,&r.nodes[5])
    r.anim_sets[set].shown=ui.Anim(pop+1)
    return true
}

@(private="file")
document_text :: proc(types:^asset.Types,r:^Records,root:int) -> string {
    buffer:=make([]u8,1<<16,context.temp_allocator)
    w:serial.Writer
    serial.writer_init_fixed(&w,buffer)
    document_write(&w,types,r,root)
    return string(serial.writer_bytes(&w))
}

@(test)
a_document_written_back_leaves_the_file_as_it_was :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    r:Records
    if !document_sample(t,&r) {return}
    defer records_destroy(&r)
    for root in ([2]int{-1,0}) {
        before:=document_text(&types,&r,root)
        call:api.Call
        args:=call_args(&call,&types,"{}")
        made,removed,ok:=document_apply(&args,&r,root,before)
        if !testing.expectf(t,ok,"%s",call.error.message) {return}
        testing.expect(t,made==0 && removed==0)
        testing.expect_value(t,document_text(&types,&r,root),before)
    }
    title:=document_row_of(&r,"title")
    testing.expect(t,.Localized in r.nodes[title].flags && r.nodes[title].text_id==77 && len(r.translations)==2)
    testing.expect(t,r.nodes[4].name[0]==0 && r.nodes[4].text_id==78,"a node without a name is matched by place and keeps none")
    testing.expect(t,records_load_as_tree(&r))
}

@(test)
a_document_of_a_node_changes_that_node_alone :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    r:Records
    if !document_sample(t,&r) {return}
    defer records_destroy(&r)
    menu:=r.nodes[document_row_of(&r,"menu")]
    call:api.Call
    args:=call_args(&call,&types,"{}")
    made,removed,ok:=document_apply(&args,&r,document_row_of(&r,"hud"),`{"nodes":[{"name":"hud","kind":"Box","style":"card","children":[
        {"name":"fuel","kind":"Progress","fields":{"bind_value":"fuel"}},
        {"name":"note","kind":"Text","text":"Hi"}]}]}`)
    if !testing.expectf(t,ok,"%s",call.error.message) {return}
    testing.expect_value(t,made,1)
    testing.expect_value(t,removed,3)
    expected:=[?]string{"hud","fuel","note","menu"}
    if !testing.expect_value(t,len(r.nodes),len(expected)) {return}
    for name,i in expected {testing.expect_value(t,serial.text_field(r.nodes[i].name[:]),name)}
    testing.expect(t,r.nodes[1].parent==0 && r.nodes[2].parent==0)
    // What the node does not give is that of a new node of its kind.
    testing.expect_value(t,r.nodes[0].float,node_default(.Box).float)
    testing.expect_value(t,records_text(&r,r.nodes[2].text),"Hi")
    testing.expect(t,mem.compare_ptrs(&r.nodes[3],&menu,size_of(ui.Tree_Node))==0)
    testing.expect_value(t,len(r.translations),0)
    testing.expect(t,records_load_as_tree(&r))
}

@(test)
a_document_without_nodes_changes_only_the_styles_and_animations_it_names :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    r:Records
    if !document_sample(t,&r) {return}
    defer records_destroy(&r)
    nodes:=len(r.nodes)
    call:api.Call
    args:=call_args(&call,&types,"{}")
    _,_,ok:=document_apply(&args,&r,-1,`{"styles":{"card":{"family":"Box","fields":{"radius":4}},"panel":{"family":"Box","defaults":["Box"]}},"animations":{"pop":null}}`)
    if !testing.expectf(t,ok,"%s",call.error.message) {return}
    testing.expect_value(t,len(r.nodes),nodes)
    card:=tree_style_row(&r,"card")
    testing.expect(t,r.styles[card].radius==[4]f32{4,4,4,4} && r.styles[card].fill==ui.Color{})
    for &v in r.variants {testing.expect(t,int(v.style)!=card,"a style declared without rules has none")}
    testing.expect_value(t,records_kind_style(&r,.Box),tree_style_row(&r,"panel"))
    testing.expect_value(t,len(r.anims),0)
    testing.expect_value(t,r.anim_sets[r.nodes[5].anims-1].shown,ui.Anim(0))
}

@(test)
a_document_says_where_it_cannot_be_written :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    Case :: struct {node,document,message:string}
    cases:=[?]Case{
        {"hud",`{"nodes":[{"name":"hud","kind":"Button"}]}`,"nodes[0].kind: a node keeps its kind"},
        {"hud",`{"nodes":[{"name":"hud","kind":"Box","children":[{"name":"menu","kind":"Button"}]}]}`,"nodes[0].children[0].name: the node 'menu' is outside"},
        {"hud",`{"nodes":[{"name":"hud","kind":"Box"},{"name":"other","kind":"Box"}]}`,"nodes: with node, the document declares that node alone"},
        {"",`{"nodes":[{"name":"x","kind":"Box","colour":1}]}`,"nodes[0] has no 'colour'"},
        {"",`{"nodes":[{"name":"x","kind":"Box","style":"nope"}]}`,"nodes[0]: style: the .ui has no style named 'nope'"},
        {"",`{"nodes":[{"name":"x","kind":"Text","children":[{"name":"y","kind":"Text"}]}]}`,"nodes[0].children[0]: parent: a Text holds no nodes"},
        {"",`{"nodes":[{"name":"x","kind":"Box"},{"name":"x","kind":"Text"}]}`,"nodes[1].name: 'x' is declared twice"},
        {"",`{"items":[]}`,"document has no 'items'"},
        {"",`{"styles":{"card":{"family":"Box","rules":[{"states":["Hovered"],"fields":{"colour":1}}]}}}`,"styles.card: rules[0]: fields.colour"},
        {"",`{"styles":{"card":null}}`,"styles.card: nodes still take it"},
    }
    for c in cases {
        r:Records
        if !document_sample(t,&r) {return}
        call:api.Call
        args:=call_args(&call,&types,"{}")
        root:=document_row_of(&r,c.node) if c.node!="" else -1
        _,_,ok:=document_apply(&args,&r,root,c.document)
        testing.expect(t,!ok)
        testing.expectf(t,strings.has_prefix(call.error.message,c.message),"%s gave '%s'",c.document,call.error.message)
        records_destroy(&r)
    }
}
