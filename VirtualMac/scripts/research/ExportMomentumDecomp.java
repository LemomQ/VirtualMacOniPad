// Ghidra headless post-script used to document Ventura's native trackpad
// momentum producer. Usage:
//   analyzeHeadless <project-dir> <project-name> -import <Mach-O> \
//       -postScript ExportMomentumDecomp.java <output-file>

import java.io.FileWriter;
import java.io.PrintWriter;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;

public class ExportMomentumDecomp extends GhidraScript {
    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 1)
            throw new IllegalArgumentException("expected output path");

        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);
        try (PrintWriter output = new PrintWriter(new FileWriter(args[0]))) {
            FunctionIterator functions =
                currentProgram.getFunctionManager().getFunctions(true);
            for (Function function : functions) {
                String name = function.getName(true);
                if (!name.contains("MTTrackpadEventDispatcher") &&
                    !name.contains("MTChordIntegrating"))
                    continue;
                if (!name.toLowerCase().contains("momentum"))
                    continue;
                DecompileResults result = decompiler.decompileFunction(
                    function, 120, monitor);
                output.println("\n===== " + name + " @ " +
                               function.getEntryPoint() + " =====");
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
