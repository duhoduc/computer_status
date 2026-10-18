# Keeps every Playwright Chromium window (the remote browser, headless=false) at the BOTTOM of the z-order,
# so a remote client opening a page never covers the window you are working in. Polls every 250 ms.
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
  // Moves our visible Chromium top-level windows to the bottom, but only those that are NOT already there.
  // EnumWindows walks the z-order top to bottom; a window of ours needs a push only if some foreign window
  // (anything but the desktop's Progman/WorkerW) lies below it. Returns how many were moved.
  public static int Sweep(string dir) {
    int moved = 0; var order = new List<IntPtr>(); var isOurs = new List<bool>(); int lastForeign = -1;
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      var cn = new StringBuilder(64); GetClassName(h, cn, 64); string c = cn.ToString();
      uint pid; GetWindowThreadProcessId(h, out pid);
      bool mine = c == "Chrome_WidgetWin_1" && Ours(pid, dir);
      if (!mine && c != "Progman" && c != "WorkerW") lastForeign = order.Count;
      order.Add(h); isOurs.Add(mine);
      return true; }, IntPtr.Zero);
    if (ours.Count > 2000) ours.Clear();
    for (int i = 0; i < order.Count && i < lastForeign; i++) {
      if (!isOurs[i]) continue;
      SetWindowPos(order[i], (IntPtr)1, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);  // HWND_BOTTOM; NOSIZE|NOMOVE|NOACTIVATE
      moved++; }
    return moved;
  }
}
'@
while ($true) { try { [void][ChromeBottom]::Sweep($BrowsersDir) } catch {}; Start-Sleep -Milliseconds 250 }
