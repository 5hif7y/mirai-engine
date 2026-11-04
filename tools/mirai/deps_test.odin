package main

import "core:os"
import "core:testing"

// A checkout whose C library is in the shared cache, built from the same
// sources elsewhere, copies it instead of compiling it; another source is
// another library.
@(test)
a_c_library_built_from_the_same_sources_comes_from_the_shared_cache :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root,error:=os.make_directory_temp("","mirai-c-library-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    defer os.remove_all(root)
    sources:=[]string{"fake.c"}
    definitions:=[]string{"FAKE=1"}
    library:=C_Library{name="fake",sources=sources,definitions=definitions}
    files:=c_library_files(root,library)
    source,header:=join(files.folder,"fake.c"),join(files.folder,"fake.h")
    os.make_directory_all(files.folder)
    testing.expect(t,os.write_entire_file(source,"int fake(void) {return 1;}\r\n")==nil)
    testing.expect(t,os.write_entire_file(header,"int fake(void);\n")==nil)
    key:=c_library_key(files,library)
    // The line endings of a checkout do not change what it is built from.
    testing.expect(t,os.write_entire_file(source,"int fake(void) {return 1;}\n")==nil)
    testing.expect_value(t,c_library_key(files,library),key)
    testing.expect(t,!c_library_current(root,library))

    cached:=c_library_cached(root,library,files,key)
    os.make_directory_all(os.dir(cached))
    testing.expect(t,os.write_entire_file(cached,"built elsewhere")==nil)
    testing.expect(t,ensure_c_library(root,library,nil))
    copied,_:=os.read_entire_file(files.library,context.temp_allocator)
    testing.expect_value(t,string(copied),"built elsewhere")
    testing.expect(t,c_library_current(root,library))

    testing.expect(t,os.write_entire_file(header,"int fake(int);\n")==nil)
    testing.expect(t,!c_library_current(root,library),"another header is another library")
}
