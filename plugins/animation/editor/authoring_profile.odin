package animation_editor

import "core:fmt"
import "mirai:asset"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/base"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

Profile_Table :: enum u8 {IK,Look,Limit,Contact,Grounding,Retarget,Chain_IK,Twist,Spring,Multi_IK,Chain_Retarget,Spline_IK,Corrective,Follow}
Profile_Counts :: struct {IK,Look,Limit,Contact,Grounding,Retarget,Chain_IK,Twist,Spring,Multi_IK,Chain_Retarget,Spline_IK,Corrective,Follow:u32}
Profile_Inspect_Result :: struct {
    asset:base.Asset_Id,path:[1024]u8 `mirai:"text"`,table:Profile_Table,counts:Profile_Counts,
    ik:[256]Authoring_Page(anim.IK_Constraint),look:[256]Authoring_Page(anim.Look_Constraint),limits:[256]Authoring_Page(anim.Rotation_Constraint),contacts:[256]Authoring_Page(anim.Foot_Contact_Constraint),grounding:[1]Authoring_Page(Profile_Grounding_Params),retarget:[256]Authoring_Page(anim.Retarget_Mapping),
    chain_ik:[256]Authoring_Page(Profile_Chain_Params),twist:[256]Authoring_Page(Profile_Twist_Params),springs:[256]Authoring_Page(Profile_Spring_Params),multi_ik:[256]Authoring_Page(Profile_Multi_Params),retarget_chains:[256]Authoring_Page(anim.Chain_Retarget_Constraint),
    spline_ik:[256]Authoring_Page(Profile_Spline_Params),correctives:[256]Authoring_Page(Profile_Corrective_Params),follow:[256]Authoring_Page(Profile_Follow_Params),
}
Profile_Inspect_Params :: struct {
    asset:base.Asset_Id,
    table:Profile_Table,
    offset:u32 `mirai:"optional"`,
    limit:u32 `mirai:"optional,min=1,max=256"`,
}
Profile_Set_Params :: struct {
    asset:base.Asset_Id,
    table:Profile_Table `mirai:"label=The table; the field named after it holds the value and the lengths of its arrays are its counts"`,
    index:u32 `mirai:"label=Existing row or the row count of the table to append; a table holds 256 rows and Grounding one rig of up to 16 legs"`,
    ik:anim.IK_Constraint `mirai:"optional"`,
    look:anim.Look_Constraint `mirai:"optional"`,
    limit:anim.Rotation_Constraint `mirai:"optional"`,
    contact:anim.Foot_Contact_Constraint `mirai:"optional"`,
    grounding:Profile_Grounding_Params `mirai:"optional"`,
    retarget:anim.Retarget_Mapping `mirai:"optional"`,
    chain_ik:Profile_Chain_Params `mirai:"optional"`,
    twist:Profile_Twist_Params `mirai:"optional"`,
    spring:Profile_Spring_Params `mirai:"optional"`,
    multi_ik:Profile_Multi_Params `mirai:"optional"`,
    retarget_chain:anim.Chain_Retarget_Constraint `mirai:"optional"`,
    spline_ik:Profile_Spline_Params `mirai:"optional"`,
    corrective:Profile_Corrective_Params `mirai:"optional"`,
    follow:Profile_Follow_Params `mirai:"optional"`,
    remove:bool `mirai:"optional"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}

@(private)
authoring_profile_register :: proc(s:^editor.Session) {
    inspect:=Profile_Inspect_Params{limit=128}
    set:=new(Profile_Set_Params,context.temp_allocator);if set==nil {return}
    set.ik,set.look,set.limit,set.contact=anim.IK_CONSTRAINT_DEFAULT,anim.LOOK_CONSTRAINT_DEFAULT,anim.ROTATION_CONSTRAINT_DEFAULT,anim.FOOT_CONTACT_CONSTRAINT_DEFAULT
    set.retarget,set.retarget_chain=anim.RETARGET_MAPPING_DEFAULT,anim.CHAIN_RETARGET_CONSTRAINT_DEFAULT;profile_constraints_defaults(set)
    authoring_method_register(s,{name="pose.profile.create",summary="Creates an empty .pose profile of rig operations; pose.profile.set fills its tables.",params=Authoring_Create_Params,params_info=type_info_of(Authoring_Create_Params),run=authoring_profile_create},Authoring_Write_Result,type_info_of(Authoring_Write_Result))
    authoring_method_register(s,{name="pose.profile.set",summary="Replaces, appends or removes one row of a table of a .pose profile.",params=Profile_Set_Params,params_info=type_info_of(Profile_Set_Params),defaults=set,run=authoring_profile_set},Authoring_Write_Result,type_info_of(Authoring_Write_Result))
}

@(private)
authoring_profile_open :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,result:^Authoring_File) -> (profile:anim.Pose_Profile,ok:bool) {
    if !authoring_open(s,call,id,anim.POSE_KIND,result) {return}
    error:asset.Error
    profile,error=anim.pose_profile_view(&result.file,&s.app.assets.types)
    if error!=.None {authoring_failure(call,"asset","Invalid_Asset","a valid .pose asset",fmt.tprintf("%v",error),"The pose profile is invalid");return}
    return profile,true
}

@(private)
authoring_profile_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Profile_Inspect_Params)
    file:Authoring_File;defer asset.asset_close(&file.file)
    profile,ok:=authoring_profile_open(s,call,p.asset,&file);if !ok {return}
    out:=call.out
    serial.text_write_raw(out,"{");authoring_result(call,p.asset,file.path)
    api.write_key(out,"counts");serial.text_write_raw(out,"{")
    api.write_uint(out,"IK",u64(len(profile.ik)),true);api.write_uint(out,"Look",u64(len(profile.look)));api.write_uint(out,"Limit",u64(len(profile.limits)));api.write_uint(out,"Contact",u64(len(profile.contacts)));api.write_uint(out,"Grounding",u64(len(profile.grounding)));api.write_uint(out,"Retarget",u64(len(profile.retarget)));api.write_uint(out,"Chain_IK",u64(len(profile.chain_ik)));api.write_uint(out,"Twist",u64(len(profile.twist)));api.write_uint(out,"Spring",u64(len(profile.springs)));api.write_uint(out,"Multi_IK",u64(len(profile.multi_ik)));api.write_uint(out,"Chain_Retarget",u64(len(profile.retarget_chains)));api.write_uint(out,"Spline_IK",u64(len(profile.spline_ik)));api.write_uint(out,"Corrective",u64(len(profile.correctives)));api.write_uint(out,"Follow",u64(len(profile.follow)));serial.text_write_raw(out,"}")
    api.write_key(out,"table");authoring_write_value(call,&p.table,type_info_of(Profile_Table))
    program_rows(call,"ik",profile.ik if p.table==.IK else nil,p.offset,p.limit)
    program_rows(call,"look",profile.look if p.table==.Look else nil,p.offset,p.limit)
    program_rows(call,"limits",profile.limits if p.table==.Limit else nil,p.offset,p.limit)
    program_rows(call,"contacts",profile.contacts if p.table==.Contact else nil,p.offset,p.limit)
    profile_constraint_rows(call,"grounding",profile.grounding if p.table==.Grounding else nil,p.offset,p.limit)
    program_rows(call,"retarget",profile.retarget if p.table==.Retarget else nil,p.offset,p.limit)
    profile_constraint_rows(call,"chain_ik",profile.chain_ik if p.table==.Chain_IK else nil,p.offset,p.limit)
    profile_constraint_rows(call,"twist",profile.twist if p.table==.Twist else nil,p.offset,p.limit)
    profile_constraint_rows(call,"springs",profile.springs if p.table==.Spring else nil,p.offset,p.limit)
    profile_constraint_rows(call,"multi_ik",profile.multi_ik if p.table==.Multi_IK else nil,p.offset,p.limit)
    program_rows(call,"retarget_chains",profile.retarget_chains if p.table==.Chain_Retarget else nil,p.offset,p.limit)
    profile_constraint_rows(call,"spline_ik",profile.spline_ik if p.table==.Spline_IK else nil,p.offset,p.limit)
    profile_constraint_rows(call,"correctives",profile.correctives if p.table==.Corrective else nil,p.offset,p.limit)
    profile_constraint_rows(call,"follow",profile.follow if p.table==.Follow else nil,p.offset,p.limit)
    serial.text_write_raw(out,"}")
}

@(private)
authoring_profile_save :: proc(s:^editor.Session,call:^api.Call,target:Authoring_File,id:base.Asset_Id,profile:anim.Pose_Profile) {
    doc:asset.Document;defer asset.document_destroy(&doc)
    if error:=anim.pose_profile_document(&doc,&s.app.assets.types,id,profile,s.app.allocator);error!=.None {authoring_failure(call,"profile","Out_Of_Memory" if error==.Out_Of_Memory else "Invalid_Definition","valid constraints within profile capacities",fmt.tprintf("%v",error),"The pose profile edit could not be prepared",api.SERVER_ERROR if error==.Out_Of_Memory else api.INVALID_PARAMS);return}
    _=authoring_publish(s,call,target,&doc)
}

@(private)
authoring_profile_create :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Authoring_Create_Params)
    file,id,ok:=authoring_create_target(s,call,base.text_get(p.path[:]),".pose");if !ok {return}
    authoring_profile_save(s,call,file,id,{})
}

@(private)
authoring_profile_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Profile_Set_Params)
    if !authoring_editable(s,call) {return}
    fields:=[Profile_Table]string{.IK="ik",.Look="look",.Limit="limit",.Contact="contact",.Grounding="grounding",.Retarget="retarget",.Chain_IK="chain_ik",.Twist="twist",.Spring="spring",.Multi_IK="multi_ik",.Chain_Retarget="retarget_chain",.Spline_IK="spline_ik",.Corrective="corrective",.Follow="follow"}
    if p.table>max(Profile_Table) || !p.remove && !authoring_field_present(call,fields[p.table]) {authoring_failure(call,"table","Required","the constraint field selected by table","missing or invalid table","Supply the constraint field selected by table");return}
    file:Authoring_File;defer asset.asset_close(&file.file)
    profile,ok:=authoring_profile_open(s,call,p.asset,&file);if !ok {return}
    replaced:=false
    switch p.table {
    case .IK: profile.ik,replaced=authoring_replace_row(profile.ik,int(p.index),p.ik,p.remove,anim.POSE_CONSTRAINTS,call.allocator)
    case .Look: profile.look,replaced=authoring_replace_row(profile.look,int(p.index),p.look,p.remove,anim.POSE_CONSTRAINTS,call.allocator)
    case .Limit: profile.limits,replaced=authoring_replace_row(profile.limits,int(p.index),p.limit,p.remove,anim.POSE_CONSTRAINTS,call.allocator)
    case .Contact: profile.contacts,replaced=authoring_replace_row(profile.contacts,int(p.index),p.contact,p.remove,anim.POSE_CONSTRAINTS,call.allocator)
    case .Grounding: profile.grounding,replaced=authoring_replace_row(profile.grounding,int(p.index),profile_grounding_value(call,p.grounding),p.remove,1,call.allocator)
    case .Retarget: profile.retarget,replaced=authoring_replace_row(profile.retarget,int(p.index),p.retarget,p.remove,anim.POSE_CONSTRAINTS,call.allocator)
    case .Chain_IK: profile.chain_ik,replaced=authoring_replace_row(profile.chain_ik,int(p.index),profile_chain_value(call,p.chain_ik),p.remove,anim.POSE_CONSTRAINTS,call.allocator)
    case .Twist: profile.twist,replaced=authoring_replace_row(profile.twist,int(p.index),profile_twist_value(call,p.twist),p.remove,anim.POSE_CONSTRAINTS,call.allocator)
    case .Spring: profile.springs,replaced=authoring_replace_row(profile.springs,int(p.index),profile_spring_value(call,p.spring),p.remove,anim.POSE_CONSTRAINTS,call.allocator)
    case .Multi_IK: profile.multi_ik,replaced=authoring_replace_row(profile.multi_ik,int(p.index),profile_multi_value(call,p.multi_ik),p.remove,anim.POSE_CONSTRAINTS,call.allocator)
    case .Chain_Retarget: profile.retarget_chains,replaced=authoring_replace_row(profile.retarget_chains,int(p.index),p.retarget_chain,p.remove,anim.POSE_CONSTRAINTS,call.allocator)
    case .Spline_IK: profile.spline_ik,replaced=authoring_replace_row(profile.spline_ik,int(p.index),profile_spline_value(p.spline_ik),p.remove,anim.POSE_CONSTRAINTS,call.allocator)
    case .Corrective: profile.correctives,replaced=authoring_replace_row(profile.correctives,int(p.index),profile_corrective_value(call,p.corrective),p.remove,anim.POSE_CONSTRAINTS,call.allocator)
    case .Follow: profile.follow,replaced=authoring_replace_row(profile.follow,int(p.index),profile_follow_value(p.follow),p.remove,anim.POSE_CONSTRAINTS,call.allocator)
    }
    if !replaced {authoring_failure(call,"index","Invalid_Edit","an existing constraint or append after the last row",fmt.tprintf("%d; remove=%t",p.index,p.remove),"The constraint edit cannot be prepared within capacity");return}
    authoring_profile_save(s,call,file,p.asset,profile)
}
