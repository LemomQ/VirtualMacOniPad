// Ghidra headless post-script for the UIKit scroll-event policy between raw
// IOHID packets and UIPanGestureRecognizer. Usage:
//   analyzeHeadless <project-dir> <project-name> -import <UIKitCore slice> \
//       -postScript ExportUIKitScrolling.java <output-file>

import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.Locale;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;

public class ExportUIKitScrolling extends GhidraScript {
    private boolean relevant(String qualifiedName) {
        String name = qualifiedName.toLowerCase(Locale.ROOT);
        if (name.contains("uipangesturerecognizer"))
            return name.contains("scroll") ||
                   name.contains("iosmac") ||
                   name.contains("velocity") ||
                   name.contains("translation");
        if (name.contains("uiscrollevent"))
            return name.contains("delta") ||
                   name.contains("momentum") ||
                   name.contains("stifl") ||
                   name.contains("phase") ||
                   name.contains("consume") ||
                   name.contains("commoninit") ||
                   name.contains("initwithevent");
        if (name.contains("interruptscrolldeceleration"))
            return true;
        return false;
    }

    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 1)
            throw new IllegalArgumentException("expected output path");

        DecompInterface decompiler = new DecompInterface();
        decompiler.toggleCCode(true);
        decompiler.toggleSyntaxTree(true);
        decompiler.openProgram(currentProgram);
        try (PrintWriter output = new PrintWriter(new FileWriter(args[0]))) {
            output.println("PROGRAM: " + currentProgram.getName());
            output.println("LANGUAGE: " + currentProgram.getLanguageID());
            FunctionIterator functions =
                currentProgram.getFunctionManager().getFunctions(true);
            for (Function function : functions) {
                String name = function.getName(true);
                if (!relevant(name))
                    continue;
                DecompileResults result = decompiler.decompileFunction(
                    function, 180, monitor);
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
