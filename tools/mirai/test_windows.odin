#+build windows
package main

// The stack each thread of a test executable reserves. Windows gives 1 MB, a tenth of what the
// editor tests that keep a Session, an App and a UI context on the stack can come near; Linux and
// macOS give 8 MB.
TEST_STACK_FLAG :: "-extra-linker-flags:/STACK:8388608"
