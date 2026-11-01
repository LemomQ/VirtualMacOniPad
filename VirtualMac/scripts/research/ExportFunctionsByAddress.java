// Focused Ghidra headless exporter for large shared-cache images. Import the
// extracted image with BinaryLoader at its original __TEXT vmaddr, then pass
// an output path followed by name/address pairs. This avoids analyzing every
// UIKitCore dependency merely to inspect a handful of functions.

import java.io.FileWriter;
import java.io.PrintWriter;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;

public class ExportFunctionsByAddress extends GhidraScript {
    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 3 || (args.length & 1) == 0)
            throw new IllegalArgumentException(
                "expected output path followed by name/address pairs");

        for (int index = 1; index < args.length; index += 2) {
            Address address = toAddr(Long.decode(args[index + 1]));
            disassemble(address);
            if (getFunctionAt(address) == null)
                createFunction(address, args[index]);
        }

        DecompInterface decompiler = new DecompInterface();
        decompiler.toggleCCode(true);
        decompiler.toggleSyntaxTree(true);
        decompiler.openProgram(currentProgram);
        try (PrintWriter output = new PrintWriter(new FileWriter(args[0]))) {
            for (int index = 1; index < args.length; index += 2) {
                Address address = toAddr(Long.decode(args[index + 1]));
                Function function = getFunctionAt(address);
                output.println("\n===== " + args[index] + " @ " +
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
