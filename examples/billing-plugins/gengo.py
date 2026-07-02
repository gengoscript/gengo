"""
gengo — Python binding for libgengo-engine.so.

Wraps the Gengoscript engine C API with a single class, Engine, that handles
ValueWire encoding, memory lifetime, and error reporting.

Build the shared library before importing this module:
    zig build engine-native

Usage:
    from gengo import Engine

    with Engine(max_ops=100_000) as eng:
        eng.load('func greet(name string) string { return "hello, " + name }')
        result, err = eng.call("greet", "world")
        if err:
            print("error:", err)
        else:
            print(result)          # hello, world
"""

import ctypes
import os
import struct
import sys

# ---------------------------------------------------------------------------
# Library loading
# ---------------------------------------------------------------------------

def _find_lib():
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(here, "..", "..", "zig-out", "lib", "libgengo-engine.so"),
        os.path.join(here, "libgengo-engine.so"),
    ]
    for p in candidates:
        if os.path.exists(p):
            return os.path.realpath(p)
    return candidates[0]

_LIB_PATH = _find_lib()

try:
    _lib = ctypes.CDLL(_LIB_PATH)
except OSError as e:
    sys.exit(
        f"Cannot load {_LIB_PATH}\n"
        f"  {e}\n"
        f"  Run: zig build engine-native"
    )

# ---------------------------------------------------------------------------
# ValueWire  (must match ValueWire in src/runtime/host_abi.zig)
#
#  offset  size  field
#  ------  ----  -----
#       0     1  tag
#       1     1  flags
#       2     2  reserved
#       4     4  (implicit padding)
#       8     8  payload  (u64, little-endian)
#      16     4  len      (u32)
#      20     4  reserved2
#  total: 24 bytes
# ---------------------------------------------------------------------------

_WIRE_NULL    = 0
_WIRE_BOOLEAN = 1
_WIRE_NUMBER  = 2
_WIRE_STRING  = 3
_WIRE_ARRAY   = 4
_WIRE_MAP     = 5
_WIRE_ERROR   = 6

_FLAG_INTEGER = 0x01   # payload is raw i64 bits (two's complement)
_FLAG_DECIMAL = 0x02   # payload is raw i64 fixed-point (scale ×1000)
_FLAG_RUNE    = 0x04   # payload is a Unicode codepoint

class _ValueWire(ctypes.Structure):
    _fields_ = [
        ("tag",       ctypes.c_uint8),
        ("flags",     ctypes.c_uint8),
        ("reserved",  ctypes.c_uint16),
        ("payload",   ctypes.c_uint64),   # 4 bytes implicit padding before this
        ("len",       ctypes.c_uint32),
        ("reserved2", ctypes.c_uint32),
    ]

def _encode(value):
    """Return a (_ValueWire, keepalive) pair for a Python value.

    The keepalive object must stay alive for the duration of any engine call
    that uses the wire value (ctypes buffers are freed when GC'd).
    """
    if value is None:
        return _ValueWire(tag=_WIRE_NULL), None
    if isinstance(value, bool):
        return _ValueWire(tag=_WIRE_BOOLEAN, payload=int(value)), None
    if isinstance(value, int):
        bits = struct.unpack("Q", struct.pack("q", value))[0]  # raw i64 bits
        return _ValueWire(tag=_WIRE_NUMBER, flags=_FLAG_INTEGER, payload=bits), None
    if isinstance(value, float):
        bits = struct.unpack("Q", struct.pack("d", value))[0]
        return _ValueWire(tag=_WIRE_NUMBER, payload=bits), None
    if isinstance(value, str):
        b   = value.encode("utf-8")
        buf = ctypes.create_string_buffer(b)
        ptr = ctypes.cast(buf, ctypes.c_void_p).value or 0
        return _ValueWire(tag=_WIRE_STRING, payload=ptr, len=len(b)), buf
    return _ValueWire(tag=_WIRE_NULL), None

def _decode(w):
    """Decode a _ValueWire back to a Python value."""
    if w.tag == _WIRE_NULL:
        return None
    if w.tag == _WIRE_BOOLEAN:
        return bool(w.payload)
    if w.tag == _WIRE_NUMBER:
        if w.flags & _FLAG_DECIMAL:
            return struct.unpack("q", struct.pack("Q", w.payload))[0]
        if w.flags & _FLAG_RUNE:
            return chr(w.payload)
        if w.flags & _FLAG_INTEGER:
            return struct.unpack("q", struct.pack("Q", w.payload))[0]  # raw i64 bits
        return struct.unpack("d", struct.pack("Q", w.payload))[0]
    if w.tag in (_WIRE_STRING, _WIRE_ERROR) and w.len > 0:
        return (ctypes.c_char * w.len).from_address(w.payload).raw.decode("utf-8")
    return None

# ---------------------------------------------------------------------------
# InstanceConfig  (must match InstanceConfig in src/engine.zig)
# ---------------------------------------------------------------------------

class _InstanceConfig(ctypes.Structure):
    _fields_ = [
        ("heap_size_bytes", ctypes.c_size_t),
        ("max_objects",     ctypes.c_size_t),
        ("max_stack",       ctypes.c_size_t),
        ("max_frames",      ctypes.c_size_t),
        ("max_defers",      ctypes.c_size_t),
        ("max_ops",         ctypes.c_int64),   # -1 = unlimited
        ("allow_io",        ctypes.c_bool),
    ]

_DEFAULT_CONFIG = dict(
    heap_size_bytes = 524_288,
    max_objects     = 2_048,
    max_stack       = 512,
    max_frames      = 64,
    max_defers      = 128,
)

# ---------------------------------------------------------------------------
# Engine API bindings
# ---------------------------------------------------------------------------

_lib.engine_init.restype  = ctypes.c_int32
_lib.engine_init.argtypes = []

_lib.engine_init_with_config.restype  = ctypes.c_int32
_lib.engine_init_with_config.argtypes = [ctypes.POINTER(_InstanceConfig)]

_lib.engine_destroy.restype  = None
_lib.engine_destroy.argtypes = [ctypes.c_int32]

_lib.engine_run.restype  = ctypes.c_int32
_lib.engine_run.argtypes = [ctypes.c_int32, ctypes.c_char_p, ctypes.c_int32]

_lib.engine_call.restype  = ctypes.c_int32
_lib.engine_call.argtypes = [
    ctypes.c_int32,
    ctypes.c_char_p, ctypes.c_int32,
    ctypes.c_void_p, ctypes.c_int32,
    ctypes.POINTER(_ValueWire),
]

_lib.engine_last_error.restype  = ctypes.c_int32
_lib.engine_last_error.argtypes = [ctypes.c_int32, ctypes.c_char_p, ctypes.c_int32]

_lib.engine_last_error_line.restype  = ctypes.c_int32
_lib.engine_last_error_line.argtypes = [ctypes.c_int32]

_lib.engine_last_error_col.restype  = ctypes.c_int32
_lib.engine_last_error_col.argtypes = [ctypes.c_int32]

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

class Engine:
    """An isolated Gengoscript engine instance.

    Each instance has its own heap and state. A failing script does not
    affect other instances or the host process.

    Args:
        max_ops:  Instruction budget. The script is stopped with a runtime
                  error if it exceeds this many operations. None = unlimited.
        allow_io: Whether std.io functions are allowed. Defaults to False.
    """

    def __init__(self, max_ops=None, allow_io=False):
        cfg = _InstanceConfig(
            **_DEFAULT_CONFIG,
            max_ops  = max_ops if max_ops is not None else -1,
            allow_io = allow_io,
        )
        self._h = _lib.engine_init_with_config(ctypes.pointer(cfg))
        if self._h <= 0:
            raise RuntimeError(f"engine_init failed (code {self._h})")

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def close(self):
        """Destroy the engine instance and free its resources."""
        if self._h > 0:
            _lib.engine_destroy(self._h)
            self._h = 0

    def load(self, source):
        """Compile and run a Gengoscript source string.

        Returns:
            (True, None) on success.
            (False, error_message) on compile or runtime error.
        """
        b  = source.encode("utf-8")
        rc = _lib.engine_run(self._h, b, len(b))
        if rc != 0:
            return False, self._last_error()
        return True, None

    def call(self, fn_name, *args):
        """Call a named function exported by the loaded script.

        Args:
            fn_name: Name of the exported function.
            *args:   Arguments as Python values (bool, int, float, str, None).

        Returns:
            (result, None) on success, where result is a Python value.
            (None, error_message) on error.
        """
        name   = fn_name.encode("utf-8")
        wires  = []
        keepalive = []
        for a in args:
            w, buf = _encode(a)
            wires.append(w)
            if buf is not None:
                keepalive.append(buf)

        ArrT   = _ValueWire * max(len(wires), 1)
        arr    = ArrT(*wires)
        out    = _ValueWire()
        argptr = ctypes.cast(arr, ctypes.c_void_p) if wires else None
        rc     = _lib.engine_call(self._h, name, len(name), argptr, len(wires), ctypes.byref(out))
        _ = keepalive
        if rc != 0:
            return None, self._last_error()
        return _decode(out), None

    def _last_error(self):
        buf = ctypes.create_string_buffer(512)
        n   = _lib.engine_last_error(self._h, buf, 512)
        msg = buf.value[:n].decode("utf-8", errors="replace") if n > 0 else "(no error)"
        line = _lib.engine_last_error_line(self._h)
        col  = _lib.engine_last_error_col(self._h)
        if line > 0:
            return f"{msg} (line {line}, col {col})"
        return msg


__all__ = ["Engine"]
