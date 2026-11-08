package main

/*
#include <stdlib.h>
*/
import "C"
import (
	"moyi/native/core"
	"unsafe"
)

//export MoyiRequest
func MoyiRequest(input *C.char) *C.char {
	if input == nil {
		return C.CString(`{"ok":false,"error":"请求为空"}`)
	}
	return C.CString(core.NativeRequest(C.GoString(input)))
}

//export MoyiFree
func MoyiFree(value *C.char) { C.free(unsafe.Pointer(value)) }

func main() {}
