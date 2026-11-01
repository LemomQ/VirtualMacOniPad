"""LLDB callback for Ventura VMM process_scroll_wheel_events payloads."""

import lldb
import os
import struct
import time

_OUTPUT = os.environ.get(
    "VZ_SCROLL_TRACE_OUTPUT", "/tmp/real-vmm-scroll.log"
)


def trace_scroll(frame, breakpoint_location, internal_dict):
    del breakpoint_location, internal_dict
    process = frame.GetThread().GetProcess()
    vector = frame.FindRegister("x2").GetValueAsUnsigned()
    device = frame.FindRegister("w1").GetValueAsUnsigned()
    error = lldb.SBError()
    start = process.ReadUnsignedFromMemory(vector, 8, error)
    if not error.Success():
        return False
    finish = process.ReadUnsignedFromMemory(vector + 8, 8, error)
    if not error.Success() or finish < start or (finish - start) % 32:
        return False

    lines = []
    for address in range(start, finish, 32):
        payload = process.ReadMemory(address, 32, error)
        if not error.Success() or len(payload) != 32:
            continue
        raw_x, raw_y = struct.unpack_from("<ii", payload, 0)
        accelerated_x, accelerated_y = struct.unpack_from("<dd", payload, 8)
        phase, momentum = struct.unpack_from("<II", payload, 24)
        lines.append(
            "%.6f device=%u raw=(%d,%d) accelerated=(%.6f,%.6f) "
            "phase=%u momentum=%u\n"
            % (
                time.time(),
                device,
                raw_x,
                raw_y,
                accelerated_x,
                accelerated_y,
                phase,
                momentum,
            )
        )
    if lines:
        with open(_OUTPUT, "a", encoding="utf-8") as output:
            output.writelines(lines)
    return False


def __lldb_init_module(debugger, internal_dict):
    del internal_dict
    debugger.HandleCommand(
        "breakpoint command add -F lldb_trace_vmm_scroll.trace_scroll 1"
    )
