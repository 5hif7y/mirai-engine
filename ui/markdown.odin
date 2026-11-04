package ui

import "core:math"
import "core:strings"
import "core:unicode/utf8"

// Markdown laid out in a width, as the answers of an agent: paragraphs,
// headings, lists, quotes, fenced code and rules, with bold, code, links and
// pills inline. The text is parsed while it is laid out, line by line into
// fixed buffers: nothing is kept and nothing is allocated, and what is built
// points into the text, which must last until the frame is drawn.
// markdown_height walks the same procedures without building, so it gives
// the height markdown builds.

Markdown_Link :: struct {
    label:string,   // what it shows; empty: the text of the link
    pill:bool,      // a pill that does not break across lines, as the entities of an answer
    live:bool,      // it leads somewhere: lit under the pointer and reported when clicked
    selected:bool,  // a pill outlined, as what is selected
    color:Color,    // of its text; zero: the accent for a link, theme text for a pill, on_accent for a button
    icon:Icon,      // before the label of a pill
    button:bool,    // a pill that does something: the fill of the accent
}
// Called while text is measured and built, with the same answer for the same target within a frame.
Markdown_Resolve :: #type proc(data:rawptr,target,text:string,buffer:[]u8) -> Markdown_Link
Markdown_Style :: struct {
    size:f32,                 // of the body; 0: theme.font_small
    color:Color,              // of the body; zero: theme.text_body
    resolve:Markdown_Resolve, // nil: every link is accent text, live
    data:rawptr,
}

MARKDOWN_RUNS :: 64     // runs of one line; a line that holds more goes on in the next
MARKDOWN_PARTS :: 16    // runs of one word in different styles; more break it there
MARKDOWN_DEPTH :: 8     // lists nested in one another; deeper items stay at the last
MARKDOWN_LABELS :: 2048 // bytes resolve writes the labels of the links of a block in
MARKDOWN_PILL_PAD :: f32(5)
MARKDOWN_PILL_GAP :: f32(2)
MARKDOWN_CHIP_PAD :: f32(3)
MARKDOWN_BAR :: f32(2)             // width of the rule left of a quote
MARKDOWN_CODE_LINE :: f32(1.5)     // line of code, in sizes
MARKDOWN_HEADING_LINE :: f32(1.35) // line of a heading, in sizes

// Height of text as markdown lays it out in width, without building it.
markdown_height :: proc(ctx:^Context,text:string,width:f32,style:Markdown_Style={}) -> f32 {
    m:Md
    md_init(&m,ctx,width,style)
    md_walk(&m,text)
    return m.height
}

// Builds text laid out in width. Returns the target of the link clicked this frame, or "".
markdown :: proc(ctx:^Context,id:Id,text:string,width:f32,style:Markdown_Style={}) -> (clicked:string) {
    m:Md
    md_init(&m,ctx,width,style)
    m.build=true
    box_begin(ctx,{id=id,width=fixed(m.width),height=FIT,direction=.Column})
    id_push(ctx,id)
    md_walk(&m,text)
    id_pop(ctx)
    box_end(ctx,{})
    if m.copied>0 && ctx.clipboard_set!=nil {
        code:=make([dynamic]u8,context.temp_allocator)
        c:Md
        md_init(&c,ctx,width,style)
        c.collect,c.code=m.copied,&code
        md_walk(&c,text)
        ctx.clipboard_set(ctx.clipboard_user,string(code[:]))
    }
    return m.clicked
}

@(private="file")
Md_Kind :: enum u8 {Text,Code,Link,Pill}
@(private="file")
Md_Run :: struct {
    text:string,
    target:string,  // of a link or a pill
    x,width:f32,    // in its line; width: of its box, with the spaces after a text
    gap:f32,        // room after its box that is no part of it
    size:f32,
    kind:Md_Kind,
    font:u8,
    link:u16,       // the link it is part of, plus one
    live,selected,button:bool,
    icon:Icon,
    color:Color,
}
@(private="file")
Md_Block :: enum u8 {Paragraph,Heading,Code,Rule}
@(private="file")
Md_Line_Kind :: enum u8 {Text,Fence,Heading,Rule,Item}
@(private="file")
Md_List :: struct {marker,content:int} // columns of the markers of its items and of their text
@(private="file")
Md :: struct {
    ctx:^Context,
    resolve:Markdown_Resolve,
    data:rawptr,
    build:bool,
    clicked:string,
    copied:int,       // the code block whose copy button was clicked, plus one
    collect:int,      // the code block whose text goes to code, plus one
    code:^[dynamic]u8,
    copy_lines:int,
    body:f32,
    color:Color,
    width:f32,
    height:f32,       // of the blocks so far
    blocks,codes,widgets,links:int,
    last_quote,last_depth:int,
    // The block being laid out.
    open:bool,
    block:Md_Block,
    quote,depth:int,
    room:f32,         // width of its lines
    line:f32,         // height of its lines
    size:f32,
    font:u8,
    text_color:Color,
    lines:int,
    // The line being filled and the word being read.
    runs:[MARKDOWN_RUNS]Md_Run,count:int,
    used:f32,
    word:[MARKDOWN_PARTS]Md_Run,parts:int,
    space:f32,space_text:string,
    bold,em:int,      // where the ** and the * that close the open ones are on their line; -1: none
    labels:[MARKDOWN_LABELS]u8,labels_used:int,
}

@(private="file")
md_init :: proc(m:^Md,ctx:^Context,width:f32,style:Markdown_Style) {
    th:=&ctx.theme
    m.ctx,m.resolve,m.data,m.width=ctx,style.resolve,style.data,max(width,1)
    m.body=style.size if style.size>0 else th.font_small
    m.color=style.color if style.color!={} else th.text_body
    m.bold,m.em=-1,-1
}

// A face of the defaults, or the first font when the context has fonts of its own.
@(private="file")
md_face :: proc(m:^Md,f:u8) -> u8 {return f if int(f)<m.ctx.font.font_count else FONT_REGULAR}

@(private="file")
md_walk :: proc(m:^Md,text:string) {
    lists:[MARKDOWN_DEPTH]Md_List
    depth,list_quote:=0,0
    fence:u8
    fence_count,fence_indent,fence_quote:=0,0,0
    blank:=false
    rest:=text
    for len(rest)>0 {
        line:=rest
        if n:=strings.index_byte(rest,'\n');n>=0 {line,rest=rest[:n],rest[n+1:]} else {rest=""}
        if len(line)>0 && line[len(line)-1]=='\r' {line=line[:len(line)-1]}
        q:=0
        body:=line
        for fence==0 || q<fence_quote {
            s:=md_skip(body,3)
            if len(s)==0 || s[0]!='>' {break}
            q+=1;body=s[1:]
            if len(body)>0 && body[0]==' ' {body=body[1:]}
        }
        if fence!=0 {
            if q>=fence_quote {
                code:=md_skip(body,fence_indent)
                if md_fence_end(code,fence,fence_count) {md_close(m);fence=0;blank=false} else {md_code_line(m,code)}
                continue
            }
            md_close(m);fence=0
        }
        indent,content:=md_indent(body)
        if len(content)==0 {
            if m.open {md_close(m)}
            blank=true
            continue
        }
        kind:=Md_Line_Kind.Text
        first:=content[0]
        run:=md_count(content,first)
        heading:=md_heading(content)
        marker_len:=0
        if (first=='`' || first=='~') && run>=3 && (first=='~' || strings.index_byte(content[run:],'`')<0) {
            kind=.Fence
        } else if heading>0 {
            kind=.Heading
        } else if md_rule(content) {
            kind=.Rule
        } else if marker_len=md_item(content);marker_len>0 {
            kind=.Item
        }
        // A line of text goes on with the paragraph before it, also out of its quote.
        if kind==.Text && m.open && m.block==.Paragraph && !blank && q<=m.quote {
            md_space(m,"")
            md_inline(m,strings.trim_space(content))
            continue
        }
        if m.open {md_close(m)}
        if q!=list_quote {depth,list_quote=0,q}
        marker:=""
        if kind==.Item {
            for depth>0 && indent<lists[depth-1].marker {depth-=1}
            if depth==0 || indent>=lists[depth-1].content {
                depth=min(depth+1,MARKDOWN_DEPTH)
                lists[depth-1].marker=indent
            }
            after:=content[marker_len:]
            spaces,text_after:=md_indent(after)
            if spaces>4 || text_after=="" {spaces=1}
            lists[depth-1].content=indent+marker_len+spaces
            marker="•" if marker_len==1 else content[:marker_len]
            content=text_after
        } else {
            for depth>0 && indent<=lists[depth-1].marker {depth-=1}
        }
        switch kind {
        case .Fence:
            md_open(m,.Code,0,q,depth,"",blank)
            fence,fence_count,fence_indent,fence_quote=first,run,indent,q
        case .Heading:
            md_open(m,.Heading,heading,q,depth,"",blank)
            md_inline(m,md_heading_text(content[heading:]))
            md_close(m)
        case .Rule:
            md_open(m,.Rule,0,q,depth,"",blank)
            md_close(m)
        case .Text,.Item:
            md_open(m,.Paragraph,0,q,depth,marker,blank)
            md_inline(m,strings.trim_space(content))
        }
        blank=false
    }
    if m.open {md_close(m)}
}

// ---------------------------------------------------------------- blocks

@(private="file")
md_open :: proc(m:^Md,block:Md_Block,level,quote,depth:int,marker:string,blank:bool) {
    ctx:=m.ctx;th:=&ctx.theme
    s:=m.body
    gap:f32
    if m.blocks>0 {
        gap=math.floor(s*2/3)
        if !blank && depth>0 && m.last_depth>0 {gap=math.floor(s/4)}
        if block==.Heading {gap+=math.floor(s/2)}
    }
    // The rules of the quotes the block before was in go on through the gap.
    continued:=min(quote,m.last_quote) if m.blocks>0 else 0
    m.block,m.quote,m.depth,m.open=block,quote,depth,true
    m.size,m.font,m.text_color=s,md_face(m,FONT_REGULAR),th.text_muted if quote>0 else m.color
    m.line=math.floor(s*PARAGRAPH_LINE)
    pad:=math.floor(s*2/3)
    switch block {
    case .Heading:
        m.size=s+(5 if level==1 else 3 if level==2 else 1)
        m.font,m.text_color=md_face(m,FONT_SEMIBOLD),th.text
        m.line=math.floor(m.size*MARKDOWN_HEADING_LINE)
    case .Code:
        m.size=max(s-1,1)
        m.font,m.text_color=md_face(m,FONT_MONO),m.color
        m.line=math.floor(m.size*MARKDOWN_CODE_LINE)
        m.codes+=1
    case .Paragraph,.Rule:
    }
    quote_width,list_width:=math.floor(s),math.floor(s*1.5)
    outer:=m.width-f32(quote)*quote_width
    m.room=max(outer-f32(depth)*list_width-(2*pad if block==.Code else 0),1)
    m.lines,m.count,m.used,m.parts,m.space,m.space_text,m.labels_used=0,0,0,0,0,"",0
    m.height+=gap
    m.blocks+=1
    m.last_quote,m.last_depth=quote,depth
    if !m.build {return}
    box_begin(ctx,{width=fixed(m.width),height=FIT})
    for k in 0..<quote {
        box_begin(ctx,{width=fixed(quote_width),height=GROW,direction=.Column})
        if k>=continued && gap>0 {spacer(ctx,MARKDOWN_BAR,gap)}
        element_leaf(ctx,{layout={width=fixed(MARKDOWN_BAR),height=GROW},custom=paint_add(ctx,{kind=.Rect,fill=th.border})})
        box_end(ctx,{})
    }
    box_begin(ctx,{width=fixed(outer),height=FIT,direction=.Column,padding={0,gap,0,0}})
    if depth>0 {
        box_begin(ctx,{width=fixed(outer),height=FIT})
        if depth>1 {spacer(ctx,f32(depth-1)*list_width,0)}
        if marker!="" {
            paint:=paint_add(ctx,{kind=.Text,text=marker,text_color=th.text_muted,size=s,center=true,style={font=md_face(m,FONT_REGULAR)}})
            element_leaf(ctx,{layout={width=fixed(list_width-math.floor(s/4)),height=fixed(math.floor(s*PARAGRAPH_LINE))},custom=paint})
            spacer(ctx,math.floor(s/4),0)
        } else {
            spacer(ctx,list_width,0)
        }
    }
    if block==.Code {
        box_begin(ctx,{id=id(ctx,"code",m.codes),track=true,width=fixed(m.room+2*pad),height=FIT,direction=.Stack,fill=th.well,radius=th.radius_popup})
        box_begin(ctx,{width=fixed(m.room+2*pad),height=FIT,direction=.Column,padding=padding_all(pad)})
    } else {
        box_begin(ctx,{width=fixed(m.room),height=FIT,direction=.Column})
    }
}

@(private="file")
md_close :: proc(m:^Md) {
    if !m.open {return}
    m.open=false
    md_word_place(m)
    if m.block!=.Rule && (m.count>0 || m.lines==0) {md_line(m)}
    pad:=math.floor(m.body*2/3)
    switch m.block {
    case .Paragraph,.Heading: m.height+=f32(m.lines)*m.line
    case .Code: m.height+=f32(m.lines)*m.line+2*pad
    case .Rule: m.height+=m.line
    }
    if !m.build {return}
    ctx:=m.ctx;th:=&ctx.theme
    if m.block==.Rule {
        if box(ctx,{width=fixed(m.room),height=fixed(m.line),align_y=.Center}) {
            element_leaf(ctx,{layout={width=fixed(m.room),height=fixed(1)},custom=paint_add(ctx,{kind=.Rect,fill=th.divider})})
        }
    }
    box_end(ctx,{})
    if m.block==.Code {
        // While the pointer is on the block, a button at its corner copies its code.
        copy:=id(ctx,"copy",m.codes)
        if widget_under(ctx,id(ctx,"code",m.codes)) || ctx.hot==copy || ctx.active==copy {
            side:=min(th.row-4,m.line+2*pad-8)
            if box(ctx,{width=FIT,height=FIT,self_x=.End,self_y=.Start,padding=padding_all(4)}) {
                if button(ctx,copy,{icon=.Copy,style=.Ghost,width=side,height=side,icon_size=min(14,side),icon_color=th.text_muted}).clicked {m.copied=m.codes}
            }
        }
        box_end(ctx,{})
    }
    if m.depth>0 {box_end(ctx,{})}
    box_end(ctx,{})
    box_end(ctx,{})
}

// A line of a fenced code block: wrapped at characters, its tabs at every
// four spaces.
@(private="file")
md_code_line :: proc(m:^Md,line:string) {
    if m.collect>0 {
        if m.collect==m.codes {
            if m.copy_lines>0 {append(m.code,'\n')}
            append(m.code,line)
            m.copy_lines+=1
        }
        return
    }
    font:=&m.ctx.font
    f:=int(m.font)
    tab:=4*text_width(font," ",m.size,f)
    pen:=text_pen(font,m.size,f)
    x,run_x:=f32(0),f32(0)
    start:=0
    for c,i in line {
        if c=='\t' {
            md_code_run(m,line[start:i],run_x,x-run_x)
            x=(math.floor(x/tab)+1)*tab if tab>0 else x
            if x>m.room {md_line(m);x=0}
            start,run_x=i+1,x
            pen=text_pen(font,m.size,f)
            continue
        }
        kern,advance:=text_pen_step(&pen,c)
        if x+kern+advance>m.room+0.01 && x>0 {
            md_code_run(m,line[start:i],run_x,x-run_x)
            md_line(m)
            x,run_x,start=0,0,i
            pen=text_pen(font,m.size,f)
            kern,advance=text_pen_step(&pen,c)
        }
        x+=kern+advance
    }
    md_code_run(m,line[start:],run_x,x-run_x)
    md_line(m)
}
@(private="file")
md_code_run :: proc(m:^Md,text:string,x,width:f32) {
    if text=="" {return}
    m.used=x
    md_place(m,{text=text,width=width,size=m.size,kind=.Text,font=m.font,color=m.text_color})
}

// ---------------------------------------------------------------- inlines

// One line of a paragraph or a heading: what closes on it opens on it.
@(private="file")
md_inline :: proc(m:^Md,s:string) {
    m.bold,m.em=-1,-1
    start,i:=0,0
    for i<len(s) {
        c:=s[i]
        switch {
        case c==' ':
            md_emit(m,s[start:i])
            md_space(m,s[i:i+1])
            i+=1;start=i
        case c=='\\' && i+1<len(s) && md_punctuation(s[i+1]):
            md_emit(m,s[start:i])
            start=i+1;i+=2
        case c=='`':
            n:=md_count(s[i:],'`')
            close:=md_code_close(s,i+n,n)
            if close<0 {i+=n;continue}
            md_emit(m,s[start:i])
            md_code(m,s[i+n:close])
            i=close+n;start=i
        case c=='*' || c=='_':
            n:=md_count(s[i:],c)
            if i==m.bold && n>=2 {
                md_emit(m,s[start:i])
                if m.em==i {m.em=i+2}
                m.bold=-1;i+=2;start=i
                continue
            }
            if i==m.em {
                md_emit(m,s[start:i])
                if m.bold==i {m.bold=i+1}
                m.em=-1;i+=1;start=i
                continue
            }
            if n>=2 && m.bold<0 {
                if close:=md_delimiter_close(s,i,2,c);close>=0 {md_emit(m,s[start:i]);m.bold=close;i+=2;start=i;continue}
            }
            if m.em<0 {
                if close:=md_delimiter_close(s,i,1,c);close>=0 {md_emit(m,s[start:i]);m.em=close;i+=1;start=i;continue}
            }
            i+=n
        case c=='[':
            if end:=md_link(m,s,i,start);end>0 {i,start=end,end;continue}
            i+=1
        case:
            i+=1
        }
    }
    md_emit(m,s[start:])
}

// A run of text without spaces in the style the line has here.
@(private="file")
md_emit :: proc(m:^Md,text:string) {
    if text=="" {return}
    font:=md_face(m,FONT_SEMIBOLD) if m.bold>=0 else m.font
    md_part(m,{text=text,width=text_width(&m.ctx.font,text,m.size,int(font)),size=m.size,kind=.Text,font=font,color=m.text_color})
}

@(private="file")
md_code :: proc(m:^Md,text:string) {
    text:=text
    if len(text)>=2 && text[0]==' ' && text[len(text)-1]==' ' && strings.trim_space(text)!="" {text=text[1:len(text)-1]}
    if text=="" {return}
    size:=max(m.size-1,1)
    font:=md_face(m,FONT_MONO)
    md_part(m,{text=text,width=text_width(&m.ctx.font,text,size,int(font))+2*MARKDOWN_CHIP_PAD,size=size,kind=.Code,font=font,color=m.ctx.theme.text})
}

// [text](target) at i, after the text from start; returns where it ends, or 0.
@(private="file")
md_link :: proc(m:^Md,s:string,i,start:int) -> int {
    close:=strings.index_byte(s[i+1:],']')
    if close<=0 {return 0}
    close+=i+1
    text:=s[i+1:close]
    if strings.index_byte(text,'[')>=0 || close+1>=len(s) || s[close+1]!='(' {return 0}
    end:=strings.index_byte(s[close+2:],')')
    if end<0 {return 0}
    end+=close+2
    target:=strings.trim_space(s[close+2:end])
    if target=="" {return 0}
    md_emit(m,s[start:i])
    th:=&m.ctx.theme
    link:=Markdown_Link{live=true}
    if m.resolve!=nil {link=m.resolve(m.data,target,text,m.labels[m.labels_used:])}
    shown:=text
    if link.label!="" {
        shown=link.label
        // A label written in the room of the labels keeps its bytes until the block ends.
        base,at:=uintptr(raw_data(m.labels[:])),uintptr(raw_data(link.label))
        if at>=base+uintptr(m.labels_used) && at+uintptr(len(link.label))<=base+MARKDOWN_LABELS {m.labels_used=int(at-base)+len(link.label)}
    }
    m.links+=1
    run:=Md_Run{target=target,size=m.size,link=u16(m.links),live=link.live,selected=link.selected,button=link.button,icon=link.icon,color=link.color}
    if link.pill {
        run.kind,run.font,run.text,run.gap=.Pill,m.font,shown,MARKDOWN_PILL_GAP
        if run.color=={} {run.color=th.on_accent if run.button else th.text}
        run.width=text_width(&m.ctx.font,shown,m.size,int(m.font))+2*MARKDOWN_PILL_PAD+(m.size+6 if run.icon!=.None else 0)
        md_part(m,run)
        return end+1
    }
    run.kind=.Link
    run.font=md_face(m,FONT_SEMIBOLD) if m.bold>=0 else m.font
    if run.color=={} {run.color=th.accent}
    word:=0
    for k in 0..=len(shown) {
        if k<len(shown) && shown[k]!=' ' {continue}
        if k>word {
            run.text=shown[word:k]
            run.width=text_width(&m.ctx.font,run.text,m.size,int(run.font))
            md_part(m,run)
        }
        if k<len(shown) {md_space(m,shown[k:k+1])}
        word=k+1
    }
    return end+1
}

// ---------------------------------------------------------------- words and lines

// Adds a run to the word being read: one that goes on from the run before in
// the same style joins it.
@(private="file")
md_part :: proc(m:^Md,run:Md_Run) {
    if m.parts>0 {
        last:=&m.word[m.parts-1]
        if md_joins(last,run) {last.text=md_extend(last.text,run.text);last.width+=run.width;return}
    }
    if m.parts==MARKDOWN_PARTS {md_word_place(m)}
    m.word[m.parts]=run
    m.parts+=1
}

// The spaces after a word end it. text: the space of the text, or "" for a
// line break inside a paragraph.
@(private="file")
md_space :: proc(m:^Md,text:string) {
    if m.parts==0 {return}
    m.space_text=text
    m.space=text_width(&m.ctx.font," ",m.size,int(m.word[m.parts-1].font))
    md_word_place(m)
}

// Puts the word read on the line, or on the next one when it does not fit.
// A word longer than a line breaks where the line ends.
@(private="file")
md_word_place :: proc(m:^Md) {
    if m.parts==0 {return}
    bare:=f32(0)
    for run,i in m.word[:m.parts] {bare+=run.width+(run.gap if i<m.parts-1 else 0)}
    if m.used>0 && m.used+bare>m.room+0.01 {md_line(m)}
    if bare<=m.room+0.01 {
        for run in m.word[:m.parts] {md_place(m,run)}
    } else {
        for run in m.word[:m.parts] {md_break(m,run)}
    }
    // The spaces are part of a text before them, and room after a chip or a pill.
    if m.space>0 && m.count>0 {
        last:=&m.runs[m.count-1]
        if (last.kind==.Text || last.kind==.Link) && last.gap==0 && abs(last.x+last.width-m.used)<0.001 {
            last.width+=m.space
            if m.space_text!="" && md_adjacent(last.text,m.space_text) {last.text=md_extend(last.text,m.space_text)}
        }
    }
    m.used+=m.space
    m.parts,m.space,m.space_text=0,0,""
}

@(private="file")
md_place :: proc(m:^Md,run:Md_Run) {
    run:=run
    run.x=m.used
    if m.count>0 {
        last:=&m.runs[m.count-1]
        if md_joins(last,run) && abs(last.x+last.width-run.x)<0.001 {
            last.text=md_extend(last.text,run.text);last.width+=run.width
            m.used+=run.width
            return
        }
    }
    if m.count==MARKDOWN_RUNS {md_line(m);run.x=0}
    m.runs[m.count]=run
    m.count+=1
    m.used=run.x+run.width+run.gap
}

@(private="file")
md_break :: proc(m:^Md,run:Md_Run) {
    run:=run
    font:=&m.ctx.font
    pad:=2*MARKDOWN_CHIP_PAD if run.kind==.Code else 0
    for {
        room:=m.room-m.used
        if run.width<=room+0.01 {md_place(m,run);return}
        if run.kind==.Pill {
            if m.used>0 {md_line(m)}
            run.width=min(run.width,m.room)
            md_place(m,run)
            return
        }
        cut,width:=md_cut(font,run.text,run.size,room-pad,int(run.font))
        if cut==0 {
            if m.used>0 {md_line(m);continue}
            _,cut=utf8.decode_rune_in_string(run.text)
            width=text_width(font,run.text[:cut],run.size,int(run.font))
        }
        head:=run
        head.text,head.width,head.gap=run.text[:cut],width+pad,0
        md_place(m,head)
        md_line(m)
        run.text=run.text[cut:]
        if run.text=="" {return}
        run.width=text_width(font,run.text,run.size,int(run.font))+pad
    }
}

// The longest start of text no wider than width, and its width.
@(private="file")
md_cut :: proc(font:^Font,text:string,size,width:f32,f:int) -> (cut:int,cut_width:f32) {
    pen:=text_pen(font,size,f)
    for c,i in text {
        kern,advance:=text_pen_step(&pen,c)
        if cut_width+kern+advance>width+0.01 {return i,cut_width}
        cut_width+=kern+advance
    }
    return len(text),cut_width
}

// Ends the line being filled: a row of its runs, each in its box.
@(private="file")
md_line :: proc(m:^Md) {
    if m.count>0 {
        last:=&m.runs[m.count-1]
        if over:=last.x+last.width-m.room;over>0 && (last.kind==.Text || last.kind==.Link) {last.width=max(last.width-over,0)}
    }
    if m.build {
        ctx:=m.ctx
        box_begin(ctx,{width=fixed(m.room),height=fixed(m.line),align_y=.Center})
        x:=f32(0)
        for &run in m.runs[:m.count] {
            if run.x>x+0.001 {spacer(ctx,run.x-x,0)}
            md_run_build(m,&run)
            x=run.x+run.width
        }
        box_end(ctx,{})
    }
    m.lines+=1
    m.count,m.used=0,0
}

@(private="file")
md_run_build :: proc(m:^Md,run:^Md_Run) {
    ctx:=m.ctx;th:=&ctx.theme
    switch run.kind {
    case .Text:
        paint:=paint_add(ctx,{kind=.Text,text=run.text,text_color=run.color,size=run.size,style={font=run.font}})
        element_leaf(ctx,{layout={width=fixed(run.width),height=fixed(m.line)},custom=paint})
    case .Code:
        paint:=paint_add(ctx,{kind=.Box,fill=th.chip_on,radius=th.radius_control,text=run.text,text_color=run.color,size=run.size,padding=MARKDOWN_CHIP_PAD,style={font=run.font}})
        element_leaf(ctx,{layout={width=fixed(run.width),height=fixed(min(math.floor(run.size*TEXT_LINE)+2,m.line))},custom=paint})
    case .Link,.Pill:
        m.widgets+=1
        widget:=id(ctx,"link",m.widgets)
        it:Interaction
        if run.live {
            it=interact(ctx,widget)
            if it.clicked {m.clicked=run.target}
        }
        lit:=it.hot && run.live
        paint:=Paint{kind=.Box,radius=th.radius_control,text=run.text,text_color=run.color,size=run.size,style={font=run.font}}
        if run.kind==.Pill {
            paint.fill=color_alpha(th.accent,61 if lit else 36)
            if run.button {paint.fill=th.accent_hover if lit else th.accent}
            paint.padding=MARKDOWN_PILL_PAD
            paint.icon,paint.icon_color,paint.icon_size=run.icon,run.color,run.size
            if run.selected {paint.stroke,paint.stroke_width=th.text,1.5}
        } else if lit {
            paint.fill=th.chip_on
        }
        element_leaf(ctx,{id=widget,layout={width=fixed(run.width),height=fixed(m.line)},custom=paint_add(ctx,paint)})
    }
}

@(private="file")
md_joins :: proc(a:^Md_Run,b:Md_Run) -> bool {
    return a.kind==b.kind && (a.kind==.Text || a.kind==.Link) && a.font==b.font && a.size==b.size && a.color==b.color && a.link==b.link && a.gap==0 && md_adjacent(a.text,b.text)
}
@(private="file")
md_adjacent :: proc(a,b:string) -> bool {return uintptr(raw_data(a))+uintptr(len(a))==uintptr(raw_data(b))}
@(private="file")
md_extend :: proc(a,b:string) -> string {return string(raw_data(a)[:len(a)+len(b)])}

// ---------------------------------------------------------------- lines of the text

// Up to n spaces off the start of s.
@(private="file")
md_skip :: proc(s:string,n:int) -> string {
    i:=0
    for i<n && i<len(s) && s[i]==' ' {i+=1}
    return s[i:]
}
// The columns of the indentation of s, a tab to the next of four, and what follows it.
@(private="file")
md_indent :: proc(s:string) -> (columns:int,rest:string) {
    i:=0
    for i<len(s) && (s[i]==' ' || s[i]=='\t') {
        columns=(columns/4+1)*4 if s[i]=='\t' else columns+1
        i+=1
    }
    return columns,s[i:]
}
@(private="file")
md_count :: proc(s:string,c:u8) -> int {
    n:=0
    for n<len(s) && s[n]==c {n+=1}
    return n
}
@(private="file")
md_fence_end :: proc(s:string,c:u8,count:int) -> bool {
    s:=md_skip(s,3)
    n:=md_count(s,c)
    return n>=count && strings.trim_space(s[n:])==""
}
// The level of an ATX heading that starts s, or 0.
@(private="file")
md_heading :: proc(s:string) -> int {
    n:=md_count(s,'#')
    return n if n>=1 && n<=6 && (n==len(s) || s[n]==' ' || s[n]=='\t') else 0
}
// The text of a heading without the hashes that may close it.
@(private="file")
md_heading_text :: proc(s:string) -> string {
    s:=strings.trim_space(s)
    end:=len(s)
    for end>0 && s[end-1]=='#' {end-=1}
    if end==0 {return ""}
    if s[end-1]==' ' {return strings.trim_space(s[:end])}
    return s
}
// Three or more of the same -, * or _, with spaces between them.
@(private="file")
md_rule :: proc(s:string) -> bool {
    c:=s[0]
    if c!='-' && c!='*' && c!='_' {return false}
    n:=0
    for i in 0..<len(s) {
        if s[i]==c {n+=1} else if s[i]!=' ' && s[i]!='\t' {return false}
    }
    return n>=3
}
// The bytes of the marker of a list item that starts s (-, *, +, 1. or 1)), or 0.
@(private="file")
md_item :: proc(s:string) -> int {
    n:=0
    if s[0]=='-' || s[0]=='*' || s[0]=='+' {
        n=1
    } else {
        for n<len(s) && n<9 && s[n]>='0' && s[n]<='9' {n+=1}
        if n==0 || n>=len(s) || (s[n]!='.' && s[n]!=')') {return 0}
        n+=1
    }
    return n if n==len(s) || s[n]==' ' || s[n]=='\t' else 0
}
@(private="file")
md_punctuation :: proc(c:u8) -> bool {
    return c>='!' && c<='/' || c>=':' && c<='@' || c>='[' && c<='`' || c>='{' && c<='~'
}
@(private="file")
md_word_char :: proc(c:u8) -> bool {
    return c>='0' && c<='9' || c>='a' && c<='z' || c>='A' && c<='Z' || c>=0x80
}
// Where the run of backticks that closes one of n before from is, or -1.
@(private="file")
md_code_close :: proc(s:string,from,n:int) -> int {
    for j:=from;j<len(s); {
        if s[j]!='`' {j+=1;continue}
        run:=md_count(s[j:],'`')
        if run==n {return j}
        j+=run
    }
    return -1
}
// Where the n markers that close the n at i are on the line, or -1. An opener
// is followed by no space and a closer follows none; underscores do not open
// or close inside a word.
@(private="file")
md_delimiter_close :: proc(s:string,i,n:int,c:u8) -> int {
    after:=i+n
    if after>=len(s) || s[after]==' ' || c=='_' && i>0 && md_word_char(s[i-1]) {return -1}
    for j:=after+1;j+n<=len(s); {
        if s[j]!=c {j+=1;continue}
        run:=md_count(s[j:],c)
        if (n==1 && run==2) || (n==2 && run<2) || s[j-1]==' ' || c=='_' && j+n<len(s) && md_word_char(s[j+n]) {j+=run;continue}
        return j
    }
    return -1
}
