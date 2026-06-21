# Firmware rollout gate (C)

A native C example that embeds `libgengo-engine.so` inside a long-running
device-update service.

Real-world shape:

* the host daemon is already written in C
* different customers or product lines need different rollout rules
* the host must keep fleet state and hardware facts in trusted C code
* a bad script must fail closed without crashing the daemon

This example shows:

* native C embedding through `libgengo-engine.so`
* a request-loop pattern: load once, call many times
* host-owned device facts passed into the script as vetted scalar inputs
* typed boundary checks in the script (`Build`, `BatteryPercent`, `RegionCode`)
* explicit reject reasons surfaced back to the host

## Build

Build the native engine first:

```bash
zig build -Dpreset=1m engine-native
```

Then build the example:

```bash
cd examples/firmware-gate-c
make
```

## Run

From the `examples/firmware-gate-c` directory:

```bash
./firmware_gate
```

To try a different script:

```bash
./firmware_gate /path/to/policy.gengo
```

## What the script decides

The script receives:

* `model`
* `serial`
* `region`
* `current_build`
* `target_build`
* `model_enabled`
* `serial_blocked`
* `battery_percent`

It may:

* reject disabled models
* reject blocked device serials
* reject low-battery update attempts
* enforce region-specific rollout rules
* reject invalid or out-of-range build numbers
* return a human-readable reject reason
