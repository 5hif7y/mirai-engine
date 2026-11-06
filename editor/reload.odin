package editor

import "core:log"
import "mirai:core"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:project"

// A Build replaces the library of the project while the editor runs. When
// the new one lays its worlds out as the loaded one, its procedures take over
// the same memory. Otherwise every struct of the worlds migrates, where it
// is, to the new layout (core.place_migrate, host.app_worlds_migrate): the
// scenes, the history, the Play and the runs of the agents go on, and so do
// the agents. The editor restarts with the scene as it is only when the
// migration cannot keep what the engine holds in place: a storage of the
// engine that would move, or a struct past the room it has. Libraries stay loaded until the editor ends: what a world holds can
// point into them.

Library_Reload :: enum u8 {
    Reloaded,
    Wait,    // something runs that the migration cannot move: a call of the API, a load
    Restart, // the editor starts again on the new library
}

@(private)
library_reload :: proc(s:^Session) -> Library_Reload {
    if library_busy(s) {return .Wait}
    tool_preview_cancel(s)
    path:=project.project_library(s.project_root,"editor")
    s.library_generation+=1
    library,error:=host.project_library_load(path,s.library_generation)
    if error!=.None {
        log.errorf("%s",host.library_error_text(error,path))
        return .Restart
    }
    if core.world_layout_hash(&library.info)!=core.world_layout_hash(s.info) {
        if !library_migrate(s,&library) {
            host.project_library_unload(&library)
            return .Restart
        }
    } else {
        s.info^=library.info
    }
    if len(s.app.step_ns)!=len(s.info.steps) {
        delete(s.app.step_ns,s.app.allocator)
        s.app.step_ns=make([]u64,len(s.info.steps),s.app.allocator)
    }
    append(&s.libraries,library)
    log.infof("code reloaded from %s",path)
    notify(s,"Code reloaded")
    return .Reloaded
}

// What keeps the worlds from migrating now: a call of the API that runs
// frames holds them on its stack, and a scene or a section that loads fills
// one over frames.
@(private)
library_busy :: proc(s:^Session) -> bool {
    if st:=api_state(s);st!=nil && (st.in_call>0 || st.stepping) {return true}
    app:=s.app
    if loads:=core.world_storage_of(core.world_ref(app.shared,s.info,.Shared),scene.Scene_Loads);loads!=nil && loads.job!=nil {return true}
    for slot in app.worlds {
        if slot.data==nil {continue}
        if sections:=host.app_world_storage(app,slot.data,scene.Section_Loads);sections!=nil {
            for item in sections.items {if item.job!=nil {return true}}
            for item in sections.far {if item.job!=nil {return true}}
        }
    }
    return false
}

// The worlds move to the layout of library. False, with nothing changed,
// when the engine would not keep its storages where they are.
@(private)
library_migrate :: proc(s:^Session,library:^host.Project_Library) -> bool {
    info:=new(core.World_Info)
    info^=library.info
    m:core.World_Migration
    if !core.world_migration_make(&m,s.info,info) {
        core.world_migration_destroy(&m)
        free(info)
        return false
    }
    defer core.world_migration_destroy(&m)
    // The editor and the engine hold their storages by address across frames.
    for &t,i in info.storages {
        if t.place==.World || t.plugin!="" || t.game || m.storages[i]!=.Move {continue}
        if m.from.storages[m.storage_sources[i]].offset!=t.offset {
            log.infof("the layout of the world changed and %s would move: restarting",t.name)
            free(info)
            return false
        }
    }
    // What holds worlds of another layout or rows by table elsewhere ends first.
    if s.mode==.Watch {watch_stop(s)}
    play_plugin_stop(s)
    for &r in s.runs {
        if r.world!=nil && r.player>0 {run_free(s,&r)}
        // Its copies of the World are of the old layout: its past starts again.
        if r.world!=nil {history_free(s,&r)}
    }
    replay_free(s)
    collab_leave(s)
    edits_commit(s.edits,edited_world(s),s.selection)
    for slot in s.app.worlds {
        if slot.data!=nil {core.world_settle(core.world_ref(slot.data,s.info))}
    }
    if !host.app_worlds_migrate(s.app,&m,s.editor_world) {
        log.info("the worlds of the new layout do not fit the room they have: restarting")
        free(info)
        return false
    }
    s.info=info
    session_bind(s)
    // The history and the reviews name tables by index and hold their values.
    edits_relayout(s.edits,edited_world(s),&m)
    for &tab,i in s.documents {
        if i==s.active_document || tab.world==nil {continue}
        edits_relayout(&tab.edits,core.world_ref(tab.world,info),&m)
    }
    if s.ai!=nil {
        for &task in s.ai.tasks[:s.ai.task_count] {
            for &set in task.review.transactions {change_rows_relayout(&set,&m)}
        }
    }
    sections_relayout(s,&m)
    log.infof("the layout of the world changed: its worlds moved to it")
    return true
}
