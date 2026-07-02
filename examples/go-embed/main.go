package main

/*
#cgo CFLAGS: -I../../include
#cgo LDFLAGS: -L../../zig-out/lib -lgengo-engine
#include "gengo-engine.h"
#include "gengo-wire.h"
#include <stdlib.h>
*/
import "C"

import (
	"fmt"
	"unsafe"
)

func engineError(handle C.int32_t) string {
	buf := (*C.char)(C.malloc(512))
	if buf == nil {
		return "engine_last_error buffer allocation failed"
	}
	defer C.free(unsafe.Pointer(buf))

	n := C.engine_last_error(handle, buf, 512)
	if n <= 0 {
		return "unknown engine error"
	}
	return C.GoStringN(buf, n)
}

func mustRun(handle C.int32_t, src string) {
	csrc := C.CString(src)
	defer C.free(unsafe.Pointer(csrc))

	rc := C.engine_run(handle, csrc, C.int32_t(len(src)))
	if rc != 0 {
		panic(engineError(handle))
	}
}

func main() {
	handle := C.engine_init()
	if handle <= 0 {
		panic("engine_init failed")
	}
	defer C.engine_destroy(handle)

	src := `
counter := 0

pub func bump(delta int) int {
    counter += delta
    return counter
}

pub func is_even(n int) bool {
    return n mod 2 == 0
}

pub func greet(name string) string {
    return "hello " + name
}
`

	mustRun(handle, src)

	bumpName := C.CString("bump")
	defer C.free(unsafe.Pointer(bumpName))

	call := func(name *C.char, nameLen int, args []C.gengo_value_wire_t) C.gengo_value_wire_t {
		var out C.gengo_value_wire_t
		if rc := C.engine_call(handle, name, C.int32_t(nameLen), &args[0], C.int32_t(len(args)), &out); rc != 0 {
			panic(engineError(handle))
		}
		return out
	}

	// Call bump three times; accumulation must be exact.
	r1 := call(bumpName, 4, []C.gengo_value_wire_t{C.gengo_wire_int(3)})
	r2 := call(bumpName, 4, []C.gengo_value_wire_t{C.gengo_wire_int(3)})
	r3 := call(bumpName, 4, []C.gengo_value_wire_t{C.gengo_wire_int(3)})
	fmt.Printf("bump(3) x3 -> %d, %d, %d\n",
		int64(C.gengo_wire_as_int(&r1)),
		int64(C.gengo_wire_as_int(&r2)),
		int64(C.gengo_wire_as_int(&r3)))

	// is_even checks the arg against a script literal (n % 2 == 0).
	isEvenName := C.CString("is_even")
	defer C.free(unsafe.Pointer(isEvenName))
	e4 := call(isEvenName, 7, []C.gengo_value_wire_t{C.gengo_wire_int(4)})
	e7 := call(isEvenName, 7, []C.gengo_value_wire_t{C.gengo_wire_int(7)})
	fmt.Printf("is_even(4) -> %v, is_even(7) -> %v\n",
		C.gengo_wire_as_bool(&e4) != 0,
		C.gengo_wire_as_bool(&e7) != 0)

	greetName := C.CString("greet")
	defer C.free(unsafe.Pointer(greetName))

	cname := C.CString("gopher")
	defer C.free(unsafe.Pointer(cname))
	greetOut := call(greetName, 5, []C.gengo_value_wire_t{C.gengo_wire_str(cname)})

	strBuf := (*C.char)(C.malloc(256))
	if strBuf == nil {
		panic("string buffer allocation failed")
	}
	defer C.free(unsafe.Pointer(strBuf))
	C.gengo_wire_read_str(&greetOut, strBuf, 256)
	fmt.Printf("greet(\"gopher\") -> %s\n", C.GoString(strBuf))
}
