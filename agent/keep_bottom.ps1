# Keeps every Playwright Chromium window (the remote browser, headless=false) at the BOTTOM of the z-order,
# so a remote client opening a page never covers the window you are working in.
# Each window is pushed to the bottom ONCE, when first seen; afterwards it is left alone.
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
  static HashSet<IntPtr> done = new HashSet<IntPtr>();
  static Dictionary<uint, bool> ours = new Dictionary<uint, bool>();
  static bool Ours(uint pid, string dir) {
    bool r; if (ours.TryGetValue(pid, out r)) return r;
    r = false; IntPtr h = OpenProcess(0x1000, false, pid);
    if (h != IntPtr.Zero) { var sb = new StringBuilder(1024); int n = 1024;
      if (QueryFullProcessImageName(h, 0, sb, ref n)) r = sb.ToString().StartsWith(dir, StringComparison.OrdinalIgnoreCase);
      CloseHandle(h); }
    ours[pid] = r; return r;
  }
  // Moves our visible Chromium top-level windows to the bottom unless already there; returns how many were moved.
  public static int Sweep(string dir) {
    int moved = 0; var list = new List<IntPtr>();
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      var cn = new StringBuilder(64); GetClassName(h, cn, 64);
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (cn.ToString() == "Chrome_WidgetWin_1" && Ours(pid, dir)) list.Add(h);
      return true; }, IntPtr.Zero);
    if (ours.Count > 2000) ours.Clear();
    done.RemoveWhere(x => !list.Contains(x));   // forget closed windows
    foreach (var h in list) {
      if (!done.Add(h)) continue;   // already pushed once
      // already at the bottom if every visible window below it is also one of ours
      bool bottom = true; for (IntPtr n = GetWindow(h, 2); n != IntPtr.Zero; n = GetWindow(n, 2)) if (IsWindowVisible(n) && !list.Contains(n)) { bottom = false; break; }
      if (bottom) continue;
      SetWindowPos(h, (IntPtr)1, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);  // HWND_BOTTOM; NOSIZE|NOMOVE|NOACTIVATE
      moved++; }
    return moved;
  }
}
'@
while ($true) { try { [void][ChromeBottom]::Sweep($BrowsersDir) } catch {}; Start-Sleep -Milliseconds 250 }
