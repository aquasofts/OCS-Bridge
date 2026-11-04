param([Parameter(Mandatory)][string]$Executable)
$ErrorActionPreference = 'Stop'
$Executable = (Resolve-Path -LiteralPath $Executable).Path

# Process creation only: the child must not be able to attach to a terminal
# belonging to this test host. Inherited pipes/console handles masked the 0.2.0
# startup crash; test both zero standard handles and the normal visible window.
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class OcsDesktopStartupTest {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct Startup {
    public int cb;
    public string reserved, desktop, title;
    public int x, y, width, height, charsX, charsY, fill, flags;
    public short show, reserved2;
    public IntPtr reservedPtr, input, output, error;
  }
  [StructLayout(LayoutKind.Sequential)]
  struct ProcessInfo { public IntPtr process, thread; public uint pid, tid; }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern bool CreateProcess(string app, StringBuilder command,
      IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd,
      ref Startup startup, out ProcessInfo info);
  [DllImport("kernel32.dll")] static extern bool FreeConsole();
  [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle, uint timeout);
  [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr handle, out uint code);
  [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr handle, uint code);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  public static string Run(string executable, string argument) {
    FreeConsole();
    var startup = new Startup();
    startup.cb = Marshal.SizeOf(startup);
    startup.flags = 0x100; // STARTF_USESTDHANDLES: all three handles are null.
    ProcessInfo info;
    if (!CreateProcess(executable, new StringBuilder("\"" + executable + "\" " + argument),
        IntPtr.Zero, IntPtr.Zero, false, 8, IntPtr.Zero,
        System.IO.Path.GetDirectoryName(executable), ref startup, out info)) {
      throw new Win32Exception();
    }
    CloseHandle(info.thread);
    try {
      if (WaitForSingleObject(info.process, 60000) != 0) {
        TerminateProcess(info.process, 1); // Only the child created by this test.
        throw new Exception("Startup timed out, pid=" + info.pid);
      }
      uint code;
      if (!GetExitCodeProcess(info.process, out code)) throw new Win32Exception();
      if (code != 0) throw new Exception("Startup failed, pid=" + info.pid + " exit=0x" + code.ToString("X8"));
      return argument + " PASS pid=" + info.pid;
    } finally { CloseHandle(info.process); }
  }
}
'@
[OcsDesktopStartupTest]::Run($Executable, '--smoke-test-close')
[OcsDesktopStartupTest]::Run($Executable, '--smoke-test-visible')
