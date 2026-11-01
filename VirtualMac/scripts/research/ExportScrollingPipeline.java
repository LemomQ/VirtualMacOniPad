// Ghidra headless post-script used to document Ventura's complete native
// trackpad and surface-mouse scroll pipeline. Usage:
//   analyzeHeadless <project-dir> <project-name> -import <Mach-O> \
//       -postScript ExportScrollingPipeline.java <output-file>

import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.Locale;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;

public class ExportScrollingPipeline extends GhidraScript {
    private boolean relevant(String qualifiedName) {
        String name = qualifiedName.toLowerCase(Locale.ROOT);
        if (name.contains("mttrackpadeventdispatcher"))
            return name.contains("initialize") ||
                   name.contains("mttrackpadeventdispatcher") ||
                   name.contains("handleevent") ||
                   name.contains("momentum") ||
                   name.contains("scroll") ||
                   name.contains("fingerstats") ||
                   name.contains("clickstate");
        if (name.contains("mtchordintegrating"))
            return name.contains("initialize") ||
                   name.contains("mtchordintegrating") ||
                   name.contains("momentum") ||
                   name.contains("chordintegration") ||
                   name.contains("touchdown") ||
                   name.contains("mickeys");
        if (name.contains("mtmouseeventdispatcher") ||
            name.contains("mtmouseembeddedeventdispatcher"))
            return name.contains("initialize") ||
                   name.contains("mtmouseeventdispatcher") ||
                   name.contains("mtmouseembeddedeventdispatcher") ||
                   name.contains("dispatch") || name.contains("event");
        if (name.contains("mtdragmanagereventqueue"))
            return name.contains("momentum") || name.contains("dispatch");
        if (name.contains("mtchordgestureset"))
            return name.contains("pause") || name.contains("readytointegrate");
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
