// dvcl.exe: starts the dvcl window (src\dvcl-gui.ps1) without a console.
// Built locally by install.cmd with the C# compiler that ships with Windows.
using System;
using System.Diagnostics;
using System.IO;

static class Launcher
{
    [STAThread]
    static void Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string start = args.Length > 0 ? args[0] : Environment.CurrentDirectory;
        if (start.EndsWith("\\")) start += ".";
        var psi = new ProcessStartInfo("powershell.exe",
            "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" +
            Path.Combine(dir, "src\\dvcl-gui.ps1") + "\" \"" + start + "\"");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        Process.Start(psi);
    }
}
