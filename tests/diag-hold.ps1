# tests\diag-hold.ps1 <workspace> <file> - read-only: which programs hold this file (Windows Restart
# Manager), and which packages Unreal has loaded under that asset name. Changes nothing.
param([string]$Workspace, [string]$File)
$tool = Split-Path -Parent $PSScriptRoot
. (Join-Path $tool 'src\DvclCore.ps1')
Set-DvRoot (Find-DvRoot $Workspace)
Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class DvclRm {
  [StructLayout(LayoutKind.Sequential)] struct UNIQUE_PROCESS { public int Pid; public System.Runtime.InteropServices.ComTypes.FILETIME Start; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct INFO { public UNIQUE_PROCESS P; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string App; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string Svc; public int Type; public int Status; public int Session; [MarshalAs(UnmanagedType.Bool)] public bool Restartable; }
  [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmStartSession(out uint h, int f, string key);
  [DllImport("rstrtmgr.dll")] static extern int RmEndSession(uint h);
  [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmRegisterResources(uint h, uint n, string[] files, uint a, IntPtr b, uint c, string[] d);
  [DllImport("rstrtmgr.dll")] static extern int RmGetList(uint h, out uint need, ref uint n, [In, Out] INFO[] info, ref uint reasons);
  public static string Holders(string path) {
    uint h; var key = Guid.NewGuid().ToString(); if (RmStartSession(out h, 0, key) != 0) return "rm start failed";
    try {
      if (RmRegisterResources(h, 1, new[] { path }, 0, IntPtr.Zero, 0, null) != 0) return "rm register failed";
      uint need = 0, n = 0, r = 0; int e = RmGetList(h, out need, ref n, null, ref r);
      if (e == 0) return "none";
      var arr = new INFO[need]; n = need; e = RmGetList(h, out need, ref n, arr, ref r); if (e != 0) return "rm list failed " + e;
      var l = new List<string>(); for (int i = 0; i < n; i++) l.Add(arr[i].App + " pid " + arr[i].P.Pid); return string.Join(", ", l);
    } finally { RmEndSession(h); }
  }
}
'@
$full = Full-Path $File
'holders: ' + [DvclRm]::Holders($full)
$stem = [System.IO.Path]::GetFileNameWithoutExtension($full)
$py = "import unreal`nn=0`nfor p in unreal.ObjectIterator(unreal.Package):`n    nm=p.get_name()`n    if '" + $stem + "' in nm:`n        n+=1`n        print('pkg '+nm)`nfor w in unreal.ObjectIterator(unreal.World):`n    if '" + $stem + "' in w.get_path_name():`n        print('world '+w.get_path_name())`nprint('packages with name: '+str(n))`nprint('all worlds: '+str(len(list(unreal.ObjectIterator(unreal.World)))))`nfor w in unreal.ObjectIterator(unreal.World):`n    print('  w '+w.get_path_name())"
$r = Invoke-Ue $py
'unreal: ' + $r.State
$r.Lines | Where-Object { $_ -notlike 'RESULT*' } | Select-Object -First 30

