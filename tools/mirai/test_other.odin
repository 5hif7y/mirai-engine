#+build !windows
package main

// Linux and macOS give the threads of a test executable 8 MB of stack already.
TEST_STACK_FLAG :: ""
