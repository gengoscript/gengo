#!/usr/bin/env python3
"""
Gengo embedded in Python — a scriptable billing service.

Each merchant submits a Gengo script defining their own discount logic.
The billing service loads each script into its own isolated engine,
calls calculate_discount() with order data, and applies the result.

Properties demonstrated:
  - Isolated:  each script runs in its own engine instance
  - Budgeted:  scripts cannot loop forever (instruction limit)
  - Safe:      a crashing script does not affect the host process
  - Typed:     data flows between Python and Gengo via typed wire values

Build the shared library first:
  zig build engine-native

Then run:
  python3 examples/python/billing_plugins.py
"""

import ctypes
import os
import struct
import sys

# ── Library ────────────────────────────────────────────────────────────────────

_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
_LIB  = os.path.join(_ROOT, "zig-out", "lib", "libgengo-engine.so")

try:
    _lib = ctypes.CDLL(_LIB)
except OSError as e:
    sys.exit(f"Cannot load {_LIB}\n  {e}\n  Run: zig build engine-native")

# ── ValueWire ──────────────────────────────────────────────────────────────────
# Must match ValueWire in gengo-engine.h / src/runtime/host_abi.zig

WIRE_NULL    = 0
WIRE_BOOLEAN = 1
WIRE_NUMBER  = 2
WIRE_STRING  = 3

class _ValueWire(ctypes.Structure):
    _fields_ = [
        ("tag",       ctypes.c_uint8),
        ("flags",     ctypes.c_uint8),
        ("reserved",  ctypes.c_uint16),
        ("payload",   ctypes.c_uint64),   # at offset 8 (4 bytes padding before this)
        ("len",       ctypes.c_uint32),
        ("reserved2", ctypes.c_uint32),
    ]

def _num(v, *, integer=False):
    bits = struct.unpack("Q", struct.pack("d", float(v)))[0]
    # flags bit 0: mark as integer so wireToValue produces .int (not .float).
    # Without this, calling int-typed Gengo params fails with TypeError.
    return _ValueWire(tag=WIRE_NUMBER, flags=(1 if integer else 0), payload=bits)

def _str(s):
    b = s.encode("utf-8")
    buf = ctypes.create_string_buffer(b)
    ptr = ctypes.cast(buf, ctypes.c_void_p).value or 0
    return _ValueWire(tag=WIRE_STRING, payload=ptr, len=len(b)), buf

def _bool(v):
    return _ValueWire(tag=WIRE_BOOLEAN, payload=int(bool(v)))

def _unpack(w):
    if w.tag == WIRE_NULL:    return None
    if w.tag == WIRE_BOOLEAN: return bool(w.payload)
    if w.tag == WIRE_NUMBER:  return struct.unpack("d", struct.pack("Q", w.payload))[0]
    if w.tag == WIRE_STRING and w.len > 0:
        return (ctypes.c_char * w.len).from_address(w.payload).raw.decode("utf-8")
    return None

# ── InstanceConfig ─────────────────────────────────────────────────────────────
# Must match InstanceConfig in src/engine.zig

class _InstanceConfig(ctypes.Structure):
    _fields_ = [
        ("heap_size_bytes", ctypes.c_size_t),
        ("max_objects",     ctypes.c_size_t),
        ("max_stack",       ctypes.c_size_t),
        ("max_frames",      ctypes.c_size_t),
        ("max_defers",      ctypes.c_size_t),
        ("max_ops",         ctypes.c_int64),  # -1 = unlimited
        ("allow_io",        ctypes.c_bool),
    ]

# ── API ────────────────────────────────────────────────────────────────────────

_lib.engine_init.restype  = ctypes.c_int32
_lib.engine_init.argtypes = []

_lib.engine_init_with_config.restype  = ctypes.c_int32
_lib.engine_init_with_config.argtypes = [ctypes.c_void_p]

_lib.engine_destroy.restype  = None
_lib.engine_destroy.argtypes = [ctypes.c_int32]

_lib.engine_run.restype  = ctypes.c_int32
_lib.engine_run.argtypes = [ctypes.c_int32, ctypes.c_char_p, ctypes.c_int32]

_lib.engine_call.restype  = ctypes.c_int32
_lib.engine_call.argtypes = [
    ctypes.c_int32, ctypes.c_char_p, ctypes.c_int32,
    ctypes.c_void_p, ctypes.c_int32,
    ctypes.POINTER(_ValueWire),
]

_lib.engine_last_error.restype  = ctypes.c_int32
_lib.engine_last_error.argtypes = [ctypes.c_int32, ctypes.c_char_p, ctypes.c_int32]

# ── Engine ─────────────────────────────────────────────────────────────────────

class Engine:
    def __init__(self, max_ops=None):
        if max_ops is not None:
            cfg = _InstanceConfig(
                heap_size_bytes=524288,
                max_objects=2048,
                max_stack=512,
                max_frames=64,
                max_defers=128,
                max_ops=max_ops,
                allow_io=False,
            )
            self._h = _lib.engine_init_with_config(ctypes.byref(cfg))
        else:
            self._h = _lib.engine_init()
        if self._h <= 0:
            raise RuntimeError("engine_init failed")

    def __enter__(self): return self
    def __exit__(self, *_): self.close()

    def close(self):
        if self._h > 0:
            _lib.engine_destroy(self._h)
            self._h = 0

    def _last_error(self):
        buf = ctypes.create_string_buffer(512)
        n   = _lib.engine_last_error(self._h, buf, 512)
        return buf.value[:n].decode("utf-8", errors="replace") if n > 0 else ""

    def load(self, source):
        b  = source.encode("utf-8")
        rc = _lib.engine_run(self._h, b, len(b))
        if rc != 0:
            return False, self._last_error()
        return True, None

    def call(self, fn, *args):
        name = fn.encode("utf-8")
        wires = []
        bufs  = []
        for a in args:
            if isinstance(a, bool):
                wires.append(_bool(a))
            elif isinstance(a, int):
                wires.append(_num(a, integer=True))
            elif isinstance(a, float):
                wires.append(_num(a))
            elif isinstance(a, str):
                w, buf = _str(a)
                wires.append(w)
                bufs.append(buf)
            else:
                wires.append(_ValueWire(tag=WIRE_NULL))

        ArrT   = _ValueWire * len(wires)
        arr    = ArrT(*wires)
        out    = _ValueWire()
        argptr = ctypes.cast(arr, ctypes.c_void_p) if wires else None
        rc     = _lib.engine_call(self._h, name, len(name), argptr, len(wires), ctypes.byref(out))
        if rc != 0:
            return None, self._last_error()
        return _unpack(out), None

# ── Merchant plugins ───────────────────────────────────────────────────────────
#
# Each plugin exports:
#   func calculate_discount(subtotal float, quantity int, member bool) float
#
# The return value is a discount rate in [0.0, 1.0].

PLUGIN_VOLUME = """\
func calculate_discount(subtotal float, quantity int, member bool) float {
    rate := 0.0
    if subtotal >= 200.0 {
        rate = 0.15
    } else if subtotal >= 100.0 {
        rate = 0.10
    } else if subtotal >= 50.0 {
        rate = 0.05
    }
    if member {
        rate = rate + 0.02
    }
    return rate
}
"""

PLUGIN_FLAT = """\
func calculate_discount(subtotal float, quantity int, member bool) float {
    if member {
        return 0.08
    }
    if quantity >= 10 {
        return 0.05
    }
    return 0.0
}
"""

# This plugin has a bug: it accesses index 0 of an empty array.
# It compiles fine but panics at runtime.
PLUGIN_BUGGY = """\
func calculate_discount(subtotal float, quantity int, member bool) float {
    tiers := []
    return tiers[0]
}
"""

# This plugin loops forever.
# Without a budget it would hang; with max_ops it gets cut off cleanly.
PLUGIN_INFINITE = """\
func calculate_discount(subtotal float, quantity int, member bool) float {
    n := 0
    for true {
        n += 1
    }
    return 0.0
}
"""

# ── Demo ───────────────────────────────────────────────────────────────────────

ORDERS = [
    (30.00,  2, False),
    (85.00,  6, True),
    (210.00, 1, False),
]

PLUGINS = [
    ("volume_discount",  PLUGIN_VOLUME,   None),
    ("flat_rate_member", PLUGIN_FLAT,     None),
    ("buggy_logic",      PLUGIN_BUGGY,    None),
    ("runaway_loop",     PLUGIN_INFINITE, 100_000),
]

def bar(): return "─" * 60

def main():
    print()
    print("Gengo embedded in Python — scriptable billing plugins")
    print(bar())
    print("Each merchant submits a Gengo script. The billing service")
    print("runs each script in its own isolated engine instance.")
    print()

    for plugin_name, source, budget in PLUGINS:
        label = f"[{plugin_name}]"
        budget_note = f"  budget: {budget:,} ops" if budget else "  budget: unlimited"
        print(f"{label}{budget_note}")

        with Engine(max_ops=budget) as eng:
            ok, err = eng.load(source)
            if not ok:
                print(f"  COMPILE ERROR: {err}")
                print()
                continue

            any_error = False
            for subtotal, qty, member in ORDERS:
                rate, err = eng.call("calculate_discount", subtotal, qty, member)
                if err:
                    any_error = True
                    # Keep the error kind if the message part is empty
                    parts = err.split(": ", 2)
                    short = parts[-1] if (len(parts) > 1 and parts[-1]) else parts[1] if len(parts) > 1 else err
                    print(f"  ${subtotal:6.2f}  qty={qty}  member={member}  →  ERROR: {short}")
                    break
                else:
                    discount = subtotal * rate
                    print(f"  ${subtotal:6.2f}  qty={qty}  member={member}  →  {rate*100:.0f}% off  (${discount:.2f})")

            if any_error:
                print(f"  Script failed. Host process is unaffected.")

        print()

    print(bar())
    print("Host process still running. Scripts cannot harm the host.")
    print()

if __name__ == "__main__":
    main()
