package core

import "core:testing"

@(test)
clearing_entities_invalidates_every_previous_handle_before_and_after_reuse :: proc(t:^testing.T) {
    es,copy:Entities
    entities_init(&es);entities_init(&copy)
    defer entities_destroy(&es);defer entities_destroy(&copy)
    old:[8]Entity
    for &entity in old {entity=create(&es)}
    destroy(&es,old[3]);entities_settle(&es)
    old[3]=create(&es)
    destroy(&es,old[6])
    for _ in 0..<3 {
        entities_clear(&es)
        testing.expect_value(t,es.alive,0)
        testing.expect_value(t,len(es.doomed),0)
        testing.expect_value(t,entities_capacity(&es),len(old)+1)
        for entity in old {testing.expect(t,!alive(&es,entity))}
        entities_copy(&copy,&es)
        for &entity,index in old {
            previous:=entity
            entity=create(&es)
            cloned:=create(&copy)
            testing.expect_value(t,cloned,entity)
            testing.expect_value(t,entity_index(entity),index+1)
            testing.expect(t,entity!=previous && !alive(&es,previous) && alive(&es,entity))
        }
        destroy(&es,old[0]);entities_settle(&es)
        old[0]=create(&es)
    }
}

@(test)
clearing_entities_skips_generation_zero_and_resets_an_empty_pool :: proc(t:^testing.T) {
    es:Entities
    entities_init(&es);defer entities_destroy(&es)
    entities_clear(&es)
    first:=create(&es)
    es.generation[entity_index(first)]=max(u32)
    wrapped:=entity_make(entity_index(first),max(u32))
    entities_clear(&es)
    testing.expect(t,!alive(&es,wrapped))
    replacement:=create(&es)
    testing.expect_value(t,entity_generation(replacement),u32(1))
    testing.expect(t,alive(&es,replacement))
}
