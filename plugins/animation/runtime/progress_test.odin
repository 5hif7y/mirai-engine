package anim

import "core:testing"
import "mirai:core"

// The time of a clip goes to Animation_Progress, which a saved game keeps;
// when the World loads, Playback starts again and the clip seeks it.
@(test)
a_loaded_clip_seeks_the_progress_its_entity_kept :: proc(t:^testing.T) {
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    animations:core.Table(Animation);defer core.table_destroy(&animations)
    progress:core.Table(Animation_Progress);defer core.table_destroy(&progress)
    requests:Animation_Requests;defer delete(requests.seeks.items)
    playback:Playback;defer playback_free(&playback)
    e:=core.create(&entities)
    core.add(&animations,e,ANIMATION_DEFAULT);core.table_settle(&animations,&entities)
    state:=state_get(&playback,e)
    state.clip,state.time=0,1.5
    progress_write(&progress,core.read(&animations),&playback)
    core.table_settle(&progress,&entities)
    kept,found:=core.get(core.read(&progress),e)
    testing.expect(t,found && kept.time==1.5)

    progress_resume(&progress,&playback,&requests)
    testing.expect_value(t,len(requests.seeks.items),0)
    playback_free(&playback);playback={}
    progress_resume(&progress,&playback,&requests)
    testing.expect(t,len(requests.seeks.items)==1 && requests.seeks.items[0]==Animation_Seek{e,1.5})

    core.remove(&animations,e);core.table_settle(&animations,&entities)
    progress_write(&progress,core.read(&animations),&playback)
    core.table_settle(&progress,&entities)
    testing.expect(t,!core.has(&progress,e))
}
