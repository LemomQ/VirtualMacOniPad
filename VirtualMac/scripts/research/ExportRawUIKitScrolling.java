// Ghidra's Mach-O loader tries to import every UIKitCore dependency. For a
// focused analysis, import the x86_64 slice with BinaryLoader at base zero,
// then use this post-script to define and decompile only the scroll methods.
// The __TEXT vmaddr and file offset are both zero in this simulator image.

import java.io.FileWriter;
import java.io.PrintWriter;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;

public class ExportRawUIKitScrolling extends GhidraScript {
    private static final long[] ADDRESSES = {
        0x857c32L, 0x857e74L, 0x857f54L, 0x857f64L,
        0xee7606L, 0xee8491L, 0xee854eL, 0xee85f0L,
        0xee88b6L, 0xee92c5L, 0xee9761L, 0xee979cL, 0xee97bbL,
    };

    private static final String[] NAMES = {
        "UIPanGestureRecognizer_scrollingChangedWithEvent",
        "UIPanGestureRecognizer_scrollDeviceCategory",
        "UIPanGestureRecognizer_iOSMacUseNonacceleratedDelta",
        "UIPanGestureRecognizer_setIOSMacUseNonacceleratedDelta",
        "UIScrollEvent_initWithEvent",
        "UIScrollEvent_acceleratedDelta",
        "UIScrollEvent_nonAcceleratedDelta",
        "UIScrollEvent_adjustedDeltaForPan",
        "UIScrollEvent_adjustedAcceleratedDeltaInView",
        "UIScrollEvent_consumeBeforeDelivery",
        "UIScrollEvent_beginStiflingDeltas",
        "UIScrollEvent_endStiflingDeltas",
        "UIScrollEvent_simulateMomentumWithDelta",
    };

    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 1)
            throw new IllegalArgumentException("expected output path");

        for (int index = 0; index < ADDRESSES.length; index++) {
            Address address = toAddr(ADDRESSES[index]);
            disassemble(address);
            if (getFunctionAt(address) == null)
                createFunction(address, NAMES[index]);
        }

        DecompInterface decompiler = new DecompInterface();
        decompiler.toggleCCode(true);
        decompiler.toggleSyntaxTree(true);
        decompiler.openProgram(currentProgram);
        try (PrintWriter output = new PrintWriter(new FileWriter(args[0]))) {
            for (int index = 0; index < ADDRESSES.length; index++) {
                Address address = toAddr(ADDRESSES[index]);
                Function function = getFunctionAt(address);
                output.println("\n===== " + NAMES[index] + " @ " +
                               address + " =====");
                if (function == null) {
                    output.println("FUNCTION NOT FOUND");
                    continue;
                }
                DecompileResults result = decompiler.decompileFunction(
                    function, 180, monitor);
                if (result.decompileCompleted())
                    output.println(result.getDecompiledFunction().getC());
                else
                    output.println("DECOMPILE FAILED: " +
                                   result.getErrorMessage());
            }
        } finally {
            decompiler.dispose();
        }
    }
}
