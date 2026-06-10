#!/usr/bin/env python3
"""
Scriptable billing plugins — Gengo embedded in Python.

Each merchant submits a Gengo script defining their own discount logic.
The billing service loads each script into its own isolated engine,
calls calculate_discount() with order data, and applies the result.

What this demonstrates:
  - Each script runs in its own engine instance with no shared state.
  - A buggy script fails at the call site; the host process keeps running.
  - A runaway script is stopped by an instruction budget.
  - Data crosses the boundary as typed values, not raw strings.

Build the shared library first:
    zig build engine-native

Then run:
    python3 examples/billing-plugins/billing_plugins.py
"""

from gengo import Engine

# ---------------------------------------------------------------------------
# Merchant plugins
#
# Each plugin must export:
#   func calculate_discount(subtotal float, quantity int, member bool) float
#
# The return value is a discount rate in [0.0, 1.0].
# ---------------------------------------------------------------------------

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
    if member { rate = rate + 0.02 }
    return rate
}
"""

PLUGIN_FLAT = """\
func calculate_discount(subtotal float, quantity int, member bool) float {
    if member    { return 0.08 }
    if quantity >= 10 { return 0.05 }
    return 0.0
}
"""

# Compiles fine but panics at runtime: index 0 of an empty slice.
PLUGIN_BUGGY = """\
func calculate_discount(subtotal float, quantity int, member bool) float {
    tiers := []
    return tiers[0]
}
"""

# Loops forever. The instruction budget stops it cleanly.
PLUGIN_INFINITE = """\
func calculate_discount(subtotal float, quantity int, member bool) float {
    n := 0
    for true { n += 1 }
    return 0.0
}
"""

# ---------------------------------------------------------------------------
# Demo
# ---------------------------------------------------------------------------

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

def rule():
    return "─" * 60

def main():
    print()
    print("Scriptable billing — each merchant provides their own Gengo policy")
    print(rule())
    print()

    for plugin_name, source, budget in PLUGINS:
        budget_note = f"{budget:,} ops" if budget else "unlimited"
        print(f"[{plugin_name}]  budget: {budget_note}")

        with Engine(max_ops=budget) as eng:
            ok, err = eng.load(source)
            if not ok:
                print(f"  compile error: {err}")
                print()
                continue

            for subtotal, qty, member in ORDERS:
                rate, err = eng.call("calculate_discount", subtotal, qty, member)
                if err:
                    print(f"  ${subtotal:6.2f}  qty={qty}  member={member}  →  error: {err}")
                    print( "  (script isolated — host process unaffected)")
                    break
                discount = subtotal * rate
                print(f"  ${subtotal:6.2f}  qty={qty}  member={member}  →  {rate*100:.0f}% off  (-${discount:.2f})")

        print()

    print(rule())
    print("Host process still running. Scripts cannot harm the host.")
    print()

if __name__ == "__main__":
    main()
