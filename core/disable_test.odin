package core

import "core:testing"

@(private="file")
Probe :: struct {value:i32}

@(private="file")
World_Of_Probes :: struct {
    es:Entities,
    disabled:Table(Disabled),
    parents:Table(Parent),
    names:Table(Name),
    probes:Table(Probe),
    hierarchy:Hierarchy,
}

@(private="file")
probes_init :: proc(w:^World_Of_Probes) {
    entities_init(&w.es)
    table_init(&w.disabled,"Disabled");table_init(&w.parents,"Parent");table_init(&w.names,"Name");table_init(&w.probes,"Probe")
    w.disabled.base,w.parents.base,w.names.base=true,true,true
}

@(private="file")
probes_destroy :: proc(w:^World_Of_Probes) {
    table_destroy(&w.disabled);table_destroy(&w.parents);table_destroy(&w.names);table_destroy(&w.probes)
    value_free(&w.hierarchy,type_info_of(Hierarchy))
    entities_destroy(&w.es)
}

// What the generated settle does.
@(private="file")
probes_settle :: proc(w:^World_Of_Probes) {
    table_settle(&w.disabled,&w.es)
    table_settle(&w.parents,&w.es)
    hierarchy_settle(&w.hierarchy,read(&w.parents),&w.es)
    entities_activity(&w.es,read(&w.disabled),ref(&w.hierarchy))
    table_settle(&w.names,&w.es)
    table_settle(&w.probes,&w.es)
    entities_settle(&w.es)
}

@(test)
a_component_turned_off_keeps_its_value_out_of_sight :: proc(t:^testing.T) {
    w:World_Of_Probes
    probes_init(&w)
    defer probes_destroy(&w)
    a,b,c:=create(&w.es),create(&w.es),create(&w.es)
    add(&w.probes,a,Probe{1});add(&w.probes,b,Probe{2});add(&w.probes,c,Probe{3})
    probes_settle(&w)
    seen:Seen
    _=changes(&w.probes,&seen)

    disable(&w.probes,a)
    testing.expect(t,has(&w.probes,a)) // it turns off when the function ends
    shape:=layout(&w.probes)
    probes_settle(&w)
    testing.expect_value(t,count(&w.probes),2)
    testing.expect(t,!has(&w.probes,a) && get(&w.probes,a)==nil && row_of(&w.probes,a)==-1)
    testing.expect(t,layout(&w.probes)>shape)
    for row in 0..<count(&w.probes) {testing.expect(t,entity_at(&w.probes,row)!=a)}
    on,turned_off,found:=raw_state(raw(&w.probes),a)
    testing.expect(t,found && !on && turned_off)
    testing.expect_value(t,(cast(^Probe)raw_find(raw(&w.probes),type_info_of(Probe),a))^,Probe{1})
    testing.expect_value(t,raw_count(raw(&w.probes)),3)
    c1:=changes(&w.probes,&seen)
    testing.expect(t,!c1.all && len(c1.gone)==1 && c1.gone[0]==a)

    // A new value of a component off keeps it off.
    add(&w.probes,a,Probe{10})
    probes_settle(&w)
    testing.expect(t,!has(&w.probes,a))

    enable(&w.probes,a)
    probes_settle(&w)
    testing.expect_value(t,count(&w.probes),3)
    value,ok:=get(read(&w.probes),a)
    testing.expect(t,ok && value==Probe{10})
    c2:=changes(&w.probes,&seen)
    testing.expect(t,!c2.all && len(c2.gone)==0)
    testing.expect(t,changed(&w.probes,c2,row_of(&w.probes,a)))
    testing.expect(t,!changed(&w.probes,c2,row_of(&w.probes,b)))

    // Removing a row off and one on keeps every row where its entity says;
    // gone has b when it turned off and again when its row went.
    disable(&w.probes,b)
    probes_settle(&w)
    remove(&w.probes,b);remove(&w.probes,c)
    probes_settle(&w)
    testing.expect_value(t,count(&w.probes),1)
    testing.expect_value(t,raw_count(raw(&w.probes)),1)
    testing.expect_value(t,row_of(&w.probes,a),0)
    c3:=changes(&w.probes,&seen)
    testing.expect(t,len(c3.gone)==3 && c3.gone[0]==b && c3.gone[1]==b && c3.gone[2]==c)
}

@(test)
a_disabled_entity_turns_off_what_hangs_from_it_and_keeps_what_was_off :: proc(t:^testing.T) {
    w:World_Of_Probes
    probes_init(&w)
    defer probes_destroy(&w)
    root,child,grandchild,other:=create(&w.es),create(&w.es),create(&w.es),create(&w.es)
    add(&w.parents,child,Parent{root,0});add(&w.parents,grandchild,Parent{child,0})
    for e in ([]Entity{root,child,grandchild,other}) {
        add(&w.probes,e,Probe{i32(entity_index(e))})
        add(&w.names,e,name_make("e"))
    }
    probes_settle(&w)
    disable(&w.probes,grandchild)
    probes_settle(&w)

    add(&w.disabled,root,Disabled{})
    probes_settle(&w)
    testing.expect(t,entity_off(&w.es,root) && entity_off(&w.es,child) && entity_off(&w.es,grandchild) && !entity_off(&w.es,other))
    testing.expect_value(t,count(&w.probes),1)
    testing.expect(t,has(&w.probes,other))
    // The base stays on.
    testing.expect(t,has(&w.names,root) && has(&w.names,grandchild) && has(&w.parents,child))

    // Turning off a row already off with its entity is a change its stamp tells.
    seen:Seen
    _=changes(&w.probes,&seen)
    disable(&w.probes,child)
    probes_settle(&w)
    c:=changes(&w.probes,&seen)
    turned:=raw_row(raw(&w.probes),child)
    testing.expect(t,version(&w.probes)>c.since && turned>=0 && w.probes.stamps[turned]>c.since && w.probes.off[turned])
    enable(&w.probes,child)
    probes_settle(&w)
    c=changes(&w.probes,&seen)
    turned=raw_row(raw(&w.probes),child)
    testing.expect(t,turned>=0 && w.probes.stamps[turned]>c.since && !w.probes.off[turned])

    // What comes into a disabled tree comes off.
    late:=create(&w.es)
    add(&w.parents,late,Parent{child,0})
    add(&w.probes,late,Probe{7})
    probes_settle(&w)
    testing.expect(t,entity_off(&w.es,late) && !has(&w.probes,late))
    testing.expect_value(t,raw_count(raw(&w.probes)),5)

    // Out of it, it is on again.
    remove(&w.parents,late)
    probes_settle(&w)
    testing.expect(t,!entity_off(&w.es,late) && has(&w.probes,late))

    remove(&w.disabled,root)
    probes_settle(&w)
    testing.expect(t,has(&w.probes,root) && has(&w.probes,child))
    testing.expect(t,!has(&w.probes,grandchild)) // off by itself before
    testing.expect_value(t,w.es.disabled,0)

    // A child under an entity destroyed while disabled is on.
    add(&w.disabled,child,Disabled{})
    probes_settle(&w)
    testing.expect(t,entity_off(&w.es,grandchild))
    destroy(&w.es,child)
    probes_settle(&w)
    testing.expect(t,!entity_off(&w.es,grandchild))
    reused:=create(&w.es)
    testing.expect(t,!entity_off(&w.es,reused))
}

@(test)
a_component_on_owns_what_its_locks_take_and_one_off_lets_it_go :: proc(t:^testing.T) {
    es:Entities;entities_init(&es);defer entities_destroy(&es)
    bodies:Table(Probe);table_init(&bodies,"Body");defer table_destroy(&bodies)
    owner:Table(u8);table_init(&owner,"Transform");defer table_destroy(&owner)
    locks:=[1]Lock{{offset=lock_offset(&bodies,&owner),id=1,target="Transform",names={"","Body"}}}
    bodies.locks=locks[:]
    e:=create(&es)
    add(&bodies,e,Probe{1})
    table_settle(&bodies,&es)
    testing.expect_value(t,owner.owners[entity_index(e)].id,u16(1))
    disable(&bodies,e)
    table_settle(&bodies,&es)
    testing.expect_value(t,owner.owners[entity_index(e)],Row_Owner{})
    enable(&bodies,e)
    table_settle(&bodies,&es)
    testing.expect_value(t,owner.owners[entity_index(e)].id,u16(1))
}

@(test)
changes_read_the_table_whole_when_a_reader_falls_behind_or_it_is_replaced :: proc(t:^testing.T) {
    es:Entities;entities_init(&es);defer entities_destroy(&es)
    probes:Table(Probe);table_init(&probes,"Probe");defer table_destroy(&probes)
    first:Seen
    testing.expect(t,!changes(&probes,&first).all) // an empty table has nothing to read
    made:=make([dynamic]Entity,context.temp_allocator)
    for i in 0..<GONE_CAPACITY+2 {
        e:=create(&es)
        append(&made,e)
        add(&probes,e,Probe{i32(i)})
    }
    table_settle(&probes,&es)
    seen:Seen
    _=changes(&probes,&seen)
    behind:=seen
    for e in made[:GONE_CAPACITY/2] {remove(&probes,e)}
    table_settle(&probes,&es)
    c:=changes(&probes,&seen)
    testing.expect(t,!c.all && len(c.gone)==GONE_CAPACITY/2)
    // Dropping what every reader read leaves them their part; one that read
    // none of it reads the table whole.
    for e in made[GONE_CAPACITY/2:] {remove(&probes,e)}
    table_settle(&probes,&es)
    c=changes(&probes,&seen)
    testing.expect(t,!c.all && len(c.gone)==GONE_CAPACITY/2+2)
    // More rows than GONE_CAPACITY go at once without a reader that reads
    // each settle reading the table whole; one that falls behind more than
    // the room does.
    pushed:=0
    for pushed<=cap(probes.gone) {
        clear(&made)
        for i in 0..<GONE_CAPACITY+2 {
            e:=create(&es)
            append(&made,e)
            add(&probes,e,Probe{i32(i)})
        }
        table_settle(&probes,&es)
        testing.expect(t,!changes(&probes,&seen).all)
        for e in made {remove(&probes,e)}
        table_settle(&probes,&es)
        c=changes(&probes,&seen)
        testing.expect(t,!c.all && len(c.gone)==len(made))
        pushed+=len(made)
    }
    testing.expect(t,changes(&probes,&behind).all)

    // Copied over, the rows are others for whoever read the table before.
    add(&probes,create(&es),Probe{1})
    table_settle(&probes,&es)
    _=changes(&probes,&seen)
    other:Table(Probe);table_init(&other,"Probe");defer table_destroy(&other)
    shown,hidden:=create(&es),create(&es)
    add(&other,shown,Probe{2});add(&other,hidden,Probe{3})
    table_settle(&other,&es)
    disable(&other,hidden)
    table_settle(&other,&es)
    testing.expect(t,table_copy(&probes,&other))
    testing.expect(t,changes(&probes,&seen).all)
    testing.expect(t,count(&probes)==1 && has(&probes,shown) && !has(&probes,hidden))
    testing.expect_value(t,raw_count(raw(&probes)),2)
}

// In a single table the one on goes off with its entity and the one turned
// on before it is on until that entity is on again; one turned on while its
// entity is off is on once its entity is.
@(test)
a_single_component_follows_the_entities_turned_off_and_on :: proc(t:^testing.T) {
    w:World_Of_Probes
    probes_init(&w)
    defer probes_destroy(&w)
    w.probes.single=true
    root,section:=create(&w.es),create(&w.es)
    add(&w.probes,root,Probe{1});add(&w.probes,section,Probe{2})
    probes_settle(&w)
    enable(&w.probes,section)
    probes_settle(&w)
    testing.expect(t,count(&w.probes)==1 && has(&w.probes,section))

    add(&w.disabled,section,Disabled{})
    probes_settle(&w)
    testing.expect(t,count(&w.probes)==1 && has(&w.probes,root))
    remove(&w.disabled,section)
    probes_settle(&w)
    testing.expect(t,count(&w.probes)==1 && has(&w.probes,section),"it was turned on last")

    add(&w.disabled,section,Disabled{})
    probes_settle(&w)
    disable(&w.probes,root)
    enable(&w.probes,root)
    probes_settle(&w)
    remove(&w.disabled,section)
    probes_settle(&w)
    testing.expect(t,count(&w.probes)==1 && has(&w.probes,root),"turned on after the section went off")
    _,waits,_:=raw_state(raw(&w.probes),section)
    testing.expect(t,waits)
}
