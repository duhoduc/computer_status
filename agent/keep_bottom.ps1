# Keeps every Playwright Chromium window (the remote browser, headless=false) at the BOTTOM of the z-order,
# so a remote client opening a page never covers the window you are working in. Polls every 250 ms, but each
# window is pushed only once, when it first appears (afterwards you may raise it freely).
param([string]$BrowsersDir = (Join-Path (Split-Path $PSScriptRoot) 'browsers'))
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class ChromeBottom {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, int flags, StringBuilder s, ref int n);
  static Dictionary<uint, bool> ours = new Dictionary<uint, bool>();
  static bool Ours(uint pid, string dir) {
    bool r; if (ours.TryGetValue(pid, out r)) return r;
    r = false; IntPtr h = OpenProcess(0x1000, false, pid);
    if (h != IntPtr.Zero) { var sb = new StringBuilder(1024); int n = 1024;
      if (QueryFullProcessImageName(h, 0, sb, ref n)) r = sb.ToString().StartsWith(dir, StringComparison.OrdinalIgnoreCase);
      CloseHandle(h); }
    ours[pid] = r; return r;
  }
  // Each Chromium window is pushed to the bottom exactly ONCE, when it first appears. After that it is left alone,
  // so you can bring it forward to look at it. Returns how many new windows were pushed.
  static HashSet<IntPtr> handled = new HashSet<IntPtr>();
  public static int Sweep(string dir) {
    int moved = 0; var now = new List<IntPtr>();
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      var cn = new StringBuilder(64); GetClassName(h, cn, 64);
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (cn.ToString() == "Chrome_WidgetWin_1" && Ours(pid, dir)) now.Add(h);
      return true; }, IntPtr.Zero);
    if (ours.Count > 2000) ours.Clear();
    handled.IntersectWith(now);   // forget closed windows (their handles may be reused later)
    foreach (var h in now) {
      if (!handled.Add(h)) continue;
      SetWindowPos(h, (IntPtr)1, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);  // HWND_BOTTOM; NOSIZE|NOMOVE|NOACTIVATE
      moved++; }
    return moved;
  }
}
'@
while ($true) { try { [void][ChromeBottom]::Sweep($BrowsersDir) } catch {}; Start-Sleep -Milliseconds 250 }
