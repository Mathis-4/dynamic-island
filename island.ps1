# ============================================================
#  Dynamic Island de Mathis - Windows 11
#  L'affichage est du code compilé (C#) ; PowerShell lance, lit la musique et parle à Nox.
#  Clic droit sur la pilule : version, journal, redémarrer, quitter
# ============================================================
$Version = '4.31'

# ---------- Réglages ----------
$NoxUrl           = ""         # vide = trouvé tout seul par Tailscale (https://jarvis.<tailnet>.ts.net)
$DefaultAccent    = "#8B7CFF"  # violet Nox
$TimerColor       = "#FF9F0A"
$ChargeColor      = "#30D158"
$HideInFullscreen = $true
# ------------------------------

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Here 'config.ps1'
if (Test-Path $ConfigPath) { . $ConfigPath }
if ($NoxStatusUrl -and -not $NoxUrl) { $NoxUrl = '' }   # ancien réglage, plus utilisé
$UpdateRepo = 'Mathis-4/dynamic-island'
$LogPath = Join-Path $Here 'island.log'
$SkipPath = Join-Path $Here 'skip.txt'
try { Set-Content -Path $LogPath -Value "Dynamic Island v$Version - $(Get-Date)" -Encoding UTF8 } catch {}
function Log($m) { try { Add-Content -Path $LogPath -Value ("{0:HH:mm:ss} PS  {1}" -f (Get-Date), $m) -Encoding UTF8 } catch {} }

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# Une seule instance
# (on attend quelques secondes que l'ancienne se ferme, pour que « Redémarrer » et les mises à jour marchent)
$script:mutex = New-Object System.Threading.Mutex($false, "Global\MathisDynamicIsland")
$owned = $false
try { $owned = $script:mutex.WaitOne(8000) } catch { $owned = $true }   # ancienne pilule fermée brutalement
if (-not $owned) { Log 'une autre pilule tourne déjà'; exit }

function Restart-Island {
  try { $script:mutex.ReleaseMutex() } catch {}
  Start-Process (Join-Path $env:WINDIR 'System32\conhost.exe') ('--headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "' + (Join-Path $Here 'island.ps1') + '"')
  [Environment]::Exit(0)
}
# En cas d'échec au démarrage : retour automatique à la version précédente
function Fail($what, $err) {
  Log "ÉCHEC ($what) : $err"
  # gardé à part : le journal est effacé au redémarrage de la version de secours
  try { Add-Content -Path (Join-Path $Here 'echecs.log') -Value ("{0:dd/MM HH:mm:ss} v{1} ({2}) : {3}" -f (Get-Date), $Version, $what, $err) -Encoding UTF8 } catch {}
  $bak = Join-Path $Here 'island.ps1.bak'
  if ((Test-Path $bak) -and -not $env:ISLAND_ROLLBACK) {
    Add-Content -Path $SkipPath -Value $Version
    Copy-Item $bak (Join-Path $Here 'island.ps1') -Force
    Log "retour à la version précédente (v$Version ne sera plus proposée)"
    $env:ISLAND_ROLLBACK = '1'
    Restart-Island
  }
  try { $script:mutex.ReleaseMutex() } catch {}
  [Environment]::Exit(1)
}

$CSharp = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Path = System.Windows.Shapes.Path;
using System.Management.Automation;

namespace Island {
  [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioEndpointVolume {
    int f(); int g(); int h(); int i();
    int SetMasterVolumeLevelScalar(float fLevel, ref Guid ctx);
    int j();
    int GetMasterVolumeLevelScalar(out float pfLevel);
    int k(); int l(); int m(); int n();
    int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, ref Guid ctx);
    int GetMute([MarshalAs(UnmanagedType.Bool)] out bool pbMute);
  }
  [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDevice {
    int Activate(ref Guid id, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    int OpenPropertyStore(int access, out IPropertyStore props);
    int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
  }
  [StructLayout(LayoutKind.Sequential)] struct PROPERTYKEY { public Guid fmtid; public int pid; }
  [StructLayout(LayoutKind.Explicit, Size = 24)] struct PROPVARIANT { [FieldOffset(0)] public short vt; [FieldOffset(8)] public IntPtr p; }
  [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IPropertyStore {
    int GetCount(out int n);
    int GetAt(int i, out PROPERTYKEY k);
    int GetValue(ref PROPERTYKEY k, out PROPVARIANT v);
  }
  [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceEnumerator {
    int f();
    int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
  }
  [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCom { }

  [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioMeterInformation { int GetPeakValue(out float pfPeak); }

  public static class Audio {
    static IMMDeviceEnumerator en;
    static IAudioMeterInformation meter;
    // niveau sonore réel (0 à 1) de la sortie audio, pour que l'égaliseur et la vague suivent la musique
    public static float Peak() {
      try {
        if (meter == null) {
          if (en == null) en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorCom());
          IMMDevice dev; en.GetDefaultAudioEndpoint(0, 1, out dev);
          Guid iid = typeof(IAudioMeterInformation).GUID; object o;
          dev.Activate(ref iid, 23, IntPtr.Zero, out o);
          meter = (IAudioMeterInformation)o;
        }
        float p; meter.GetPeakValue(out p); return p;
      } catch { meter = null; return -1f; }
    }
    static IAudioEndpointVolume vol;
    static IAudioEndpointVolume Vol() {
      if (en == null) en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorCom());
      IMMDevice dev; en.GetDefaultAudioEndpoint(0, 1, out dev);
      Guid iid = typeof(IAudioEndpointVolume).GUID; object o;
      dev.Activate(ref iid, 23, IntPtr.Zero, out o);
      return (IAudioEndpointVolume)o;
    }
    public static void Reset() { vol = null; meter = null; }
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PROPVARIANT v);
    // sortie audio par défaut (identifiant + nom affiché), pour annoncer « Son sur : AirPods »
    public static string DefaultOutput(out string name) {
      name = "";
      try {
        if (en == null) en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorCom());
        IMMDevice dev; en.GetDefaultAudioEndpoint(0, 1, out dev);
        string id; dev.GetId(out id);
        IPropertyStore ps;
        if (dev.OpenPropertyStore(0, out ps) == 0 && ps != null) {
          PROPERTYKEY k = new PROPERTYKEY(); k.fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"); k.pid = 14;
          PROPVARIANT v;
          if (ps.GetValue(ref k, out v) == 0) { if (v.vt == 31 && v.p != IntPtr.Zero) name = Marshal.PtrToStringUni(v.p); PropVariantClear(ref v); }
          Marshal.ReleaseComObject(ps);
        }
        Marshal.ReleaseComObject(dev);
        return id;
      } catch { return null; }
    }
    public static float Level() { try { if (vol == null) vol = Vol(); float v; vol.GetMasterVolumeLevelScalar(out v); return v; } catch { vol = null; return -1f; } }
    public static bool Muted() { try { if (vol == null) vol = Vol(); bool m; vol.GetMute(out m); return m; } catch { vol = null; return false; } }
  }

  public static class Img {
    [DllImport("shcore.dll")]
    static extern int CreateStreamOverRandomAccessStream([MarshalAs(UnmanagedType.IUnknown)] object ras, ref Guid riid,
      [MarshalAs(UnmanagedType.Interface)] out System.Runtime.InteropServices.ComTypes.IStream stream);
    public static byte[] ReadAll(object ras) {
      Guid iid = new Guid("0000000c-0000-0000-C000-000000000046");
      System.Runtime.InteropServices.ComTypes.IStream st;
      int hr = CreateStreamOverRandomAccessStream(ras, ref iid, out st);
      if (hr != 0) Marshal.ThrowExceptionForHR(hr);
      System.IO.MemoryStream ms = new System.IO.MemoryStream();
      byte[] buf = new byte[65536];
      IntPtr pRead = Marshal.AllocHGlobal(4);
      try {
        while (true) {
          st.Read(buf, buf.Length, pRead);
          int n = Marshal.ReadInt32(pRead);
          if (n <= 0) break;
          ms.Write(buf, 0, n);
        }
      } finally { Marshal.FreeHGlobal(pRead); Marshal.ReleaseComObject(st); }
      return ms.ToArray();
    }
  }

  public static class Win {
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct SPS { public byte AC; public byte Flag; public byte Pct; public byte Saver; public int Life; public int Full; }
    [DllImport("kernel32.dll")] static extern bool GetSystemPowerStatus(out SPS s);
    const int WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOOLWINDOW = 0x00000080;
    public static void NoActivate(IntPtr h, bool on) {
      int ex = GetWindowLong(h, -20);
      ex = on ? (ex | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW) : ((ex & ~WS_EX_NOACTIVATE) | WS_EX_TOOLWINDOW);
      SetWindowLong(h, -20, ex);
    }
    public static bool ForegroundIsFullscreen(int sw, int sh, IntPtr self) {
      IntPtr h = GetForegroundWindow();
      if (h == IntPtr.Zero || h == self) return false;
      System.Text.StringBuilder sb = new System.Text.StringBuilder(64); GetClassName(h, sb, 64);
      string c = sb.ToString();
      if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd") return false;
      RECT r; if (!GetWindowRect(h, out r)) return false;
      return Math.Abs(r.L) <= 1 && Math.Abs(r.T) <= 1 && Math.Abs(r.R - sw) <= 1 && Math.Abs(r.B - sh) <= 1;
    }
    // pourcentage (-1 si pas de batterie) et secteur
    public static int Battery(out bool charging) {
      SPS s; charging = false;
      if (!GetSystemPowerStatus(out s)) return -1;
      charging = s.AC == 1;
      if (s.Flag == 128 || s.Pct == 255) return -1;
      return s.Pct;
    }
  }

  // Ressort amorti façon SwiftUI : response (s) + dampingFraction
  public class Spring {
    public double Value, Velocity, Target, Response = 0.4, Damping = 0.8;
    public Spring(double v) { Value = v; Target = v; }
    public void Step(double dt) {
      double k = Math.Pow(2 * Math.PI / Response, 2);
      double c = 4 * Math.PI * Damping / Response;
      double a = -k * (Value - Target) - c * Velocity;
      Velocity += a * dt; Value += Velocity * dt;
    }
    public bool Settled { get { return Math.Abs(Value - Target) < 0.1 && Math.Abs(Velocity) < 0.8; } }
    public void Snap() { Value = Target; Velocity = 0; }
  }

  public static class Fx {
    public static Geometry Notch(double x, double w, double h, double r) {
      r = Math.Max(0, Math.Min(r, Math.Min(w / 2, h)));
      StreamGeometry g = new StreamGeometry();
      using (StreamGeometryContext c = g.Open()) {
        c.BeginFigure(new Point(x, 0), true, true);
        c.LineTo(new Point(x + w, 0), false, false);
        c.LineTo(new Point(x + w, h - r), false, false);
        c.ArcTo(new Point(x + w - r, h), new Size(r, r), 0, false, SweepDirection.Clockwise, false, false);
        c.LineTo(new Point(x + r, h), false, false);
        c.ArcTo(new Point(x, h - r), new Size(r, r), 0, false, SweepDirection.Clockwise, false, false);
      }
      g.Freeze(); return g;
    }
    // contour des côtés et du bas seulement (le haut touche le bord de l'écran) : tous les segments sont tracés
    public static Geometry NotchEdge(double x, double w, double h, double r) {
      r = Math.Max(0, Math.Min(r, Math.Min(w / 2, h)));
      StreamGeometry g = new StreamGeometry();
      using (StreamGeometryContext c = g.Open()) {
        c.BeginFigure(new Point(x, 0), false, false);
        c.LineTo(new Point(x, h - r), true, true);
        c.ArcTo(new Point(x + r, h), new Size(r, r), 0, false, SweepDirection.Counterclockwise, true, true);
        c.LineTo(new Point(x + w - r, h), true, true);
        c.ArcTo(new Point(x + w, h - r), new Size(r, r), 0, false, SweepDirection.Counterclockwise, true, true);
        c.LineTo(new Point(x + w, 0), true, true);
      }
      g.Freeze(); return g;
    }
    public static Geometry Arc(double size, double thickness, double frac) {
      frac = Math.Max(0.0001, Math.Min(0.9999, frac));
      double r = (size - thickness) / 2, c = size / 2, a = frac * 2 * Math.PI;
      Point p0 = new Point(c, c - r);
      Point p1 = new Point(c + r * Math.Sin(a), c - r * Math.Cos(a));
      StreamGeometry g = new StreamGeometry();
      using (StreamGeometryContext ctx = g.Open()) {
        ctx.BeginFigure(p0, false, false);
        ctx.ArcTo(p1, new Size(r, r), 0, frac > 0.5, SweepDirection.Clockwise, true, true);
      }
      g.Freeze(); return g;
    }
    static double Hue(double r, double g, double b, double max, double min) {
      double d = max - min; if (d <= 0) return 0;
      double h;
      if (max == r) h = ((g - b) / d) % 6; else if (max == g) h = (b - r) / d + 2; else h = (r - g) / d + 4;
      h *= 60; if (h < 0) h += 360; return h;
    }
    public static Color FromHsv(double h, double s, double v) {
      double c = v * s, x = c * (1 - Math.Abs((h / 60) % 2 - 1)), m = v - c;
      double r = 0, g = 0, b = 0;
      if (h < 60) { r = c; g = x; } else if (h < 120) { r = x; g = c; } else if (h < 180) { g = c; b = x; }
      else if (h < 240) { g = x; b = c; } else if (h < 300) { r = x; b = c; } else { r = c; b = x; }
      return Color.FromRgb((byte)Math.Round((r + m) * 255), (byte)Math.Round((g + m) * 255), (byte)Math.Round((b + m) * 255));
    }
    public static Color Dominant(BitmapSource src, Color fallback) {
      try {
        if (src == null || src.PixelWidth < 2 || src.PixelHeight < 2) return fallback;
        BitmapSource sm = new TransformedBitmap(src, new ScaleTransform(40.0 / src.PixelWidth, 40.0 / src.PixelHeight));
        sm = new FormatConvertedBitmap(sm, PixelFormats.Bgra32, null, 0);
        int w = sm.PixelWidth, h = sm.PixelHeight, stride = w * 4;
        byte[] px = new byte[stride * h]; sm.CopyPixels(px, stride, 0);
        double[] wt = new double[24], rr = new double[24], gg = new double[24], bb = new double[24];
        double tot = 0;
        for (int i = 0; i + 3 < px.Length; i += 4) {
          double b = px[i] / 255.0, g = px[i + 1] / 255.0, r = px[i + 2] / 255.0;
          double max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b));
          double sat = max <= 0 ? 0 : (max - min) / max;
          if (max < 0.18 || sat < 0.2) continue;
          int bin = ((int)(Hue(r, g, b, max, min) / 15)) % 24;
          double k = sat * sat * max;
          wt[bin] += k; rr[bin] += r * k; gg[bin] += g * k; bb[bin] += b * k; tot += k;
        }
        if (tot < 2) return fallback;
        int best = 0; double bestW = -1;
        for (int q = 0; q < 24; q++) {
          double sc = wt[q] + 0.5 * (wt[(q + 23) % 24] + wt[(q + 1) % 24]);
          if (sc > bestW) { bestW = sc; best = q; }
        }
        double R = 0, G = 0, B = 0, Wt = 0;
        for (int d = -1; d <= 1; d++) { int q = (best + d + 24) % 24; R += rr[q]; G += gg[q]; B += bb[q]; Wt += wt[q]; }
        R /= Wt; G /= Wt; B /= Wt;
        double mx = Math.Max(R, Math.Max(G, B)), mn = Math.Min(R, Math.Min(G, B));
        double hue = Hue(R, G, B, mx, mn), sv = mx <= 0 ? 0 : (mx - mn) / mx;
        return FromHsv(hue, Math.Min(Math.Max(sv, 0.45), 0.85), Math.Max(mx, 0.85));
      } catch { return fallback; }
    }
    public static Color Shade(Color c, double f) {
      return Color.FromRgb((byte)(c.R * f), (byte)(c.G * f), (byte)(c.B * f));
    }
  }


  // =================================================================
  //  Voix : parler à Nox directement depuis la pilule (Gemini Live, comme la page /voix en mode talkie-walkie)
  //  Le jeton éphémère et les outils passent par l'appli de Nox (Tailscale) ; la clé ne quitte jamais le serveur.
  // =================================================================
  [StructLayout(LayoutKind.Sequential, Pack = 2)]
  struct WAVEFORMATEX { public short wFormatTag, nChannels; public int nSamplesPerSec, nAvgBytesPerSec; public short nBlockAlign, wBitsPerSample, cbSize; }
  [StructLayout(LayoutKind.Sequential)]
  struct WAVEHDR { public IntPtr lpData; public int dwBufferLength, dwBytesRecorded; public IntPtr dwUser; public int dwFlags, dwLoops; public IntPtr lpNext, reserved; }

  static class WinMM {
    [DllImport("winmm.dll")] public static extern int waveInOpen(out IntPtr h, int dev, ref WAVEFORMATEX f, IntPtr cb, IntPtr inst, int flags);
    [DllImport("winmm.dll")] public static extern int waveInPrepareHeader(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] public static extern int waveInUnprepareHeader(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] public static extern int waveInAddBuffer(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] public static extern int waveInStart(IntPtr h);
    [DllImport("winmm.dll")] public static extern int waveInReset(IntPtr h);
    [DllImport("winmm.dll")] public static extern int waveInClose(IntPtr h);
    [DllImport("winmm.dll")] public static extern int waveOutOpen(out IntPtr h, int dev, ref WAVEFORMATEX f, IntPtr cb, IntPtr inst, int flags);
    [DllImport("winmm.dll")] public static extern int waveOutPrepareHeader(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] public static extern int waveOutUnprepareHeader(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] public static extern int waveOutWrite(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] public static extern int waveOutReset(IntPtr h);
    public static WAVEFORMATEX Pcm16(int rate) {
      WAVEFORMATEX f = new WAVEFORMATEX();
      f.wFormatTag = 1; f.nChannels = 1; f.nSamplesPerSec = rate; f.wBitsPerSample = 16; f.nBlockAlign = 2; f.nAvgBytesPerSec = rate * 2; f.cbSize = 0;
      return f;
    }
    public static readonly int HdrSize = Marshal.SizeOf(typeof(WAVEHDR));
    public static readonly int FlagsOffset = (int)Marshal.OffsetOf(typeof(WAVEHDR), "dwFlags");
    public static readonly int RecordedOffset = (int)Marshal.OffsetOf(typeof(WAVEHDR), "dwBytesRecorded");
    public static IntPtr NewHeader(int bytes, out IntPtr data) {
      data = Marshal.AllocHGlobal(bytes);
      WAVEHDR w = new WAVEHDR(); w.lpData = data; w.dwBufferLength = bytes;
      IntPtr hdr = Marshal.AllocHGlobal(HdrSize);
      Marshal.StructureToPtr(w, hdr, false);
      return hdr;
    }
  }

  // Micro : 16 kHz mono, morceaux de 100 ms (lecture des tampons sans rappel, sur un fil à part)
  class Mic {
    IntPtr h; IntPtr[] hdrs; IntPtr[] datas; volatile bool run; System.Threading.Thread th; Action<byte[]> cb; int bytes;
    public Mic(int rate, Action<byte[]> onChunk) {
      cb = onChunk; bytes = rate / 10 * 2;
      WAVEFORMATEX f = WinMM.Pcm16(rate);
      int r = WinMM.waveInOpen(out h, -1, ref f, IntPtr.Zero, IntPtr.Zero, 0);
      if (r != 0) throw new Exception("micro indisponible (code " + r + ")");
      hdrs = new IntPtr[6]; datas = new IntPtr[6];
      for (int i = 0; i < hdrs.Length; i++) {
        hdrs[i] = WinMM.NewHeader(bytes, out datas[i]);
        WinMM.waveInPrepareHeader(h, hdrs[i], WinMM.HdrSize);
        WinMM.waveInAddBuffer(h, hdrs[i], WinMM.HdrSize);
      }
      run = true;
      th = new System.Threading.Thread(Loop); th.IsBackground = true; th.Start();
      WinMM.waveInStart(h);
    }
    void Loop() {
      int i = 0;
      while (run) {
        IntPtr hdr = hdrs[i];
        int flags = Marshal.ReadInt32(hdr, WinMM.FlagsOffset);
        if ((flags & 1) != 0) {   // WHDR_DONE
          int n = Marshal.ReadInt32(hdr, WinMM.RecordedOffset);
          if (n > 0 && run) {
            byte[] b = new byte[n]; Marshal.Copy(datas[i], b, 0, n);
            try { cb(b); } catch { }
          }
          if (run) WinMM.waveInAddBuffer(h, hdr, WinMM.HdrSize);
          i = (i + 1) % hdrs.Length;
        } else System.Threading.Thread.Sleep(10);
      }
    }
    public void Stop() {
      if (!run) return;
      run = false;
      try { th.Join(500); } catch { }
      WinMM.waveInReset(h);
      for (int i = 0; i < hdrs.Length; i++) { WinMM.waveInUnprepareHeader(h, hdrs[i], WinMM.HdrSize); Marshal.FreeHGlobal(datas[i]); Marshal.FreeHGlobal(hdrs[i]); }
      WinMM.waveInClose(h);
    }
  }

  // Haut-parleur : 24 kHz mono, morceaux mis en file
  class Player {
    IntPtr h = IntPtr.Zero; readonly object lk = new object();
    List<IntPtr[]> queued = new List<IntPtr[]>();
    void Open() {
      if (h != IntPtr.Zero) return;
      WAVEFORMATEX f = WinMM.Pcm16(24000);
      int r = WinMM.waveOutOpen(out h, -1, ref f, IntPtr.Zero, IntPtr.Zero, 0);
      if (r != 0) { h = IntPtr.Zero; throw new Exception("sortie audio indisponible (code " + r + ")"); }
    }
    void Cleanup(bool all) {
      for (int i = queued.Count - 1; i >= 0; i--) {
        IntPtr hdr = queued[i][0];
        if (all || (Marshal.ReadInt32(hdr, WinMM.FlagsOffset) & 1) != 0) {
          WinMM.waveOutUnprepareHeader(h, hdr, WinMM.HdrSize);
          Marshal.FreeHGlobal(queued[i][1]); Marshal.FreeHGlobal(hdr);
          queued.RemoveAt(i);
        }
      }
    }
    public void Play(byte[] pcm) {
      if (pcm == null || pcm.Length == 0) return;
      lock (lk) {
        Open(); Cleanup(false);
        IntPtr data; IntPtr hdr = WinMM.NewHeader(pcm.Length, out data);
        Marshal.Copy(pcm, 0, data, pcm.Length);
        WinMM.waveOutPrepareHeader(h, hdr, WinMM.HdrSize);
        WinMM.waveOutWrite(h, hdr, WinMM.HdrSize);
        queued.Add(new IntPtr[] { hdr, data });
      }
    }
    public bool Busy { get { lock (lk) { if (h == IntPtr.Zero) return false; Cleanup(false); return queued.Count > 0; } } }
    public void Reset() { lock (lk) { if (h == IntPtr.Zero) return; WinMM.waveOutReset(h); Cleanup(true); } }
  }

  public class Voice {
    public Action<string> OnHeard, OnSaid, OnState, OnLog;
    public Action<string> OnTurnDone;
    string baseUrl; ClientWebSocket ws; volatile bool ready; bool startSent, endPending, closeAfter;
    readonly System.Threading.SemaphoreSlim sendLock = new System.Threading.SemaphoreSlim(1, 1);
    readonly JavaScriptSerializer js = new JavaScriptSerializer();
    Mic mic; readonly Player player = new Player();
    readonly List<string> pending = new List<string>(); readonly object pl = new object();
    volatile bool talking; string heard = "", said = "", heardForTool = ""; string handle;
    long tokIn, tokOut; public DateTime LastActivity = DateTime.Now; bool connecting;
    static readonly string[] Urls = {
      "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained",
      "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained" };

    public Voice() { js.MaxJsonLength = int.MaxValue; }
    public bool Open { get { return ws != null; } }
    public bool Speaking { get { return player.Busy; } }
    void Log(string m) { if (OnLog != null) OnLog(m); }
    void State(string s) { if (OnState != null) OnState(s); }

    string Post(string path, object body, int timeoutMs) {
      HttpWebRequest req = (HttpWebRequest)WebRequest.Create(baseUrl + path);
      req.Method = "POST"; req.ContentType = "application/json"; req.Headers["X-Jarvis"] = "1"; req.Timeout = timeoutMs;
      req.UserAgent = "MathisDynamicIsland/1.0";
      byte[] b = Encoding.UTF8.GetBytes(js.Serialize(body));
      using (System.IO.Stream s = req.GetRequestStream()) s.Write(b, 0, b.Length);
      using (WebResponse resp = req.GetResponse())
      using (System.IO.StreamReader rd = new System.IO.StreamReader(resp.GetResponseStream(), Encoding.UTF8)) return rd.ReadToEnd();
    }

    void Send(object msg) {
      ClientWebSocket s = ws;
      if (s == null || s.State != WebSocketState.Open) return;
      byte[] b = Encoding.UTF8.GetBytes(msg is string ? (string)msg : js.Serialize(msg));
      sendLock.Wait();
      try { s.SendAsync(new ArraySegment<byte>(b), WebSocketMessageType.Text, true, System.Threading.CancellationToken.None).Wait(10000); }
      catch (Exception ex) { Log("voix (envoi) : " + ex.GetBaseException().Message); }
      finally { sendLock.Release(); }
    }
    static Dictionary<string, object> D(params object[] kv) {
      Dictionary<string, object> d = new Dictionary<string, object>();
      for (int i = 0; i + 1 < kv.Length; i += 2) d[(string)kv[i]] = kv[i + 1];
      return d;
    }

    // ---- appui / relâchement du bouton micro ----
    public void PressStart(string url) {
      baseUrl = url.TrimEnd('/');
      talking = true; startSent = false; endPending = false; heard = ""; LastActivity = DateTime.Now;
      player.Reset();   // couper Nox s'il parlait
      try { if (mic == null) mic = new Mic(16000, OnMicChunk); }
      catch (Exception ex) { Log("voix : " + ex.Message); State("erreur:" + ex.Message); talking = false; return; }
      State("ecoute");
      if (ready) Task.Run(new Action(SendStart));
      else if (!connecting) Task.Run(new Action(Connect));
    }
    public void PressEnd() {
      if (!talking) return;
      talking = false; LastActivity = DateTime.Now;
      Task.Run(new Action(delegate {
        System.Threading.Thread.Sleep(300);   // le micro vide son tampon
        Mic m = mic; mic = null;
        if (m != null) m.Stop();
        if (ready) { FlushPending(); if (startSent) { Send(D("realtimeInput", D("activityEnd", D()))); startSent = false; } State("reflechit"); }
        else endPending = true;
      }));
    }
    void SendStart() { if (!startSent) { Send(D("realtimeInput", D("activityStart", D()))); startSent = true; } FlushPending(); }
    void FlushPending() {
      List<string> l;
      lock (pl) { l = new List<string>(pending); pending.Clear(); }
      if (l.Count > 0 && !startSent) { Send(D("realtimeInput", D("activityStart", D()))); startSent = true; }
      foreach (string b in l) Send(D("realtimeInput", D("audio", D("mimeType", "audio/pcm;rate=16000", "data", b))));
    }
    void OnMicChunk(byte[] pcm) {
      string b64 = Convert.ToBase64String(pcm);
      if (ready) {
        if (!startSent) { Send(D("realtimeInput", D("activityStart", D()))); startSent = true; }
        FlushPending();
        Send(D("realtimeInput", D("audio", D("mimeType", "audio/pcm;rate=16000", "data", b64))));
      } else lock (pl) pending.Add(b64);
    }

    // ---- connexion ----
    void Connect() {
      connecting = true;
      try {
        Dictionary<string, object> d = js.DeserializeObject(Post("/api/voix/jeton", D("mode", "talkie"), 20000)) as Dictionary<string, object>;
        if (d == null || !d.ContainsKey("jeton")) throw new Exception("jeton refusé");
        string jeton = Convert.ToString(d["jeton"]);
        Dictionary<string, object> setup = d["setup"] as Dictionary<string, object>;
        if (handle != null && setup != null && setup.ContainsKey("setup")) ((Dictionary<string, object>)setup["setup"])["sessionResumption"] = D("handle", handle);
        Exception last = null;
        foreach (string u in Urls) {
          ClientWebSocket s = new ClientWebSocket();
          try {
            s.ConnectAsync(new Uri(u + "?access_token=" + Uri.EscapeDataString(jeton)), System.Threading.CancellationToken.None).Wait(15000);
            if (s.State != WebSocketState.Open) throw new Exception("connexion impossible");
            ws = s; ready = false;
            Send(setup);
            Task.Run(new Action(delegate { Receive(s); }));
            last = null; break;
          } catch (Exception ex) { last = ex; try { s.Dispose(); } catch { } }
        }
        if (last != null) throw last;
        Log("voix : connecté à Gemini Live");
      } catch (Exception ex) {
        Log("voix (connexion) : " + ex.GetBaseException().Message);
        State("erreur:Nox ne répond pas en vocal");
        ws = null; ready = false;
      } finally { connecting = false; }
    }

    void Receive(ClientWebSocket s) {
      byte[] buf = new byte[65536];
      System.IO.MemoryStream acc = new System.IO.MemoryStream();
      try {
        while (s.State == WebSocketState.Open) {
          Task<WebSocketReceiveResult> t = s.ReceiveAsync(new ArraySegment<byte>(buf), System.Threading.CancellationToken.None);
          t.Wait();
          WebSocketReceiveResult r = t.Result;
          if (r.MessageType == WebSocketMessageType.Close) { Log("voix : session fermée (" + r.CloseStatusDescription + ")"); break; }
          acc.Write(buf, 0, r.Count);
          if (!r.EndOfMessage) continue;
          string text = Encoding.UTF8.GetString(acc.ToArray()); acc.SetLength(0);
          try { Handle(js.DeserializeObject(text) as Dictionary<string, object>); }
          catch (Exception ex) { Log("voix (message) : " + ex.Message); }
        }
      } catch (Exception ex) { Log("voix (réception) : " + ex.GetBaseException().Message); }
      if (ws == s) { ws = null; ready = false; State("ferme"); }
    }

    static Dictionary<string, object> Dict(Dictionary<string, object> d, string k) { object o; return d != null && d.TryGetValue(k, out o) ? o as Dictionary<string, object> : null; }
    static string Text(Dictionary<string, object> d, string k) { object o; return d != null && d.TryGetValue(k, out o) && o != null ? Convert.ToString(o) : null; }

    void Handle(Dictionary<string, object> m) {
      if (m == null) return;
      LastActivity = DateTime.Now;
      Dictionary<string, object> u = Dict(m, "usageMetadata");
      if (u != null) {
        object a, b;
        if (u.TryGetValue("promptTokenCount", out a)) tokIn = Math.Max(tokIn, Convert.ToInt64(a));
        if (u.TryGetValue("responseTokenCount", out b)) tokOut = Math.Max(tokOut, Convert.ToInt64(b));
      }
      if (m.ContainsKey("setupComplete")) {
        ready = true;
        bool hasAudio; lock (pl) hasAudio = pending.Count > 0;
        if (talking || hasAudio) SendStart();
        if (endPending) { endPending = false; FlushPending(); if (startSent) { Send(D("realtimeInput", D("activityEnd", D()))); startSent = false; } State("reflechit"); }
        return;
      }
      Dictionary<string, object> sr = Dict(m, "sessionResumptionUpdate");
      if (sr != null && Text(sr, "newHandle") != null) handle = Text(sr, "newHandle");
      if (m.ContainsKey("goAway")) { Log("voix : Gemini demande de se reconnecter"); }
      Dictionary<string, object> tc = Dict(m, "toolCall");
      if (tc != null && tc.ContainsKey("functionCalls")) {
        object[] calls = tc["functionCalls"] as object[];
        if (calls != null) Task.Run(new Action(delegate { Tools(calls); }));
      }
      Dictionary<string, object> c = Dict(m, "serverContent");
      if (c == null) return;
      if (c.ContainsKey("interrupted")) player.Reset();
      string it = Text(Dict(c, "inputTranscription"), "text");
      if (!string.IsNullOrEmpty(it)) { heard += it; heardForTool += it; if (OnHeard != null) OnHeard(heard.Trim()); }
      string ot = Text(Dict(c, "outputTranscription"), "text");
      if (!string.IsNullOrEmpty(ot)) { said += ot; if (OnSaid != null) OnSaid(said.Trim()); State("parle"); }
      Dictionary<string, object> mt = Dict(c, "modelTurn");
      if (mt != null && mt.ContainsKey("parts")) {
        object[] parts = mt["parts"] as object[];
        if (parts != null) foreach (object p in parts) {
          Dictionary<string, object> inl = Dict(p as Dictionary<string, object>, "inlineData");
          string data = Text(inl, "data");
          if (data != null) { try { player.Play(Convert.FromBase64String(data)); } catch (Exception ex) { Log("voix (son) : " + ex.Message); } }
        }
      }
      if (c.ContainsKey("turnComplete")) {
        string done = said.Trim();
        said = ""; heard = "";
        if (OnTurnDone != null) OnTurnDone(done);
        if (closeAfter) { closeAfter = false; Task.Run(new Action(delegate { while (player.Busy) System.Threading.Thread.Sleep(200); Close(); })); }
      }
    }

    void Tools(object[] calls) {
      List<object> reps = new List<object>();
      State("reflechit");
      foreach (object o in calls) {
        Dictionary<string, object> call = o as Dictionary<string, object>;
        if (call == null) continue;
        string id = Text(call, "id"), name = Text(call, "name");
        object args; call.TryGetValue("args", out args);
        string res;
        if (name == "terminer_conversation") { closeAfter = true; res = "C'est noté : dis juste au revoir en quelques mots."; }
        else {
          try {
            Dictionary<string, object> body = D("nom", name, "arguments", args ?? D());
            if (name == "demander_jarvis") { body["entendu"] = heardForTool.Length > 2000 ? heardForTool.Substring(heardForTool.Length - 2000) : heardForTool; heardForTool = ""; }
            Dictionary<string, object> r = js.DeserializeObject(Post("/api/voix/outil", body, 120000)) as Dictionary<string, object>;
            res = Text(r, "resultat") ?? "";
          } catch (Exception ex) { res = "Erreur : " + ex.GetBaseException().Message; }
        }
        reps.Add(D("id", id, "name", name, "response", D("resultat", res)));
      }
      if (reps.Count > 0) Send(D("toolResponse", D("functionResponses", reps)));
    }

    public void Close() {
      ClientWebSocket s = ws; ws = null; ready = false;
      if (s != null) { try { s.CloseAsync(WebSocketCloseStatus.NormalClosure, "fin", System.Threading.CancellationToken.None).Wait(2000); } catch { } }
      if (tokIn > 0 || tokOut > 0) {
        long a = tokIn, b = tokOut; tokIn = 0; tokOut = 0;
        try { Post("/api/voix/fin", D("entree", a, "sortie", b), 10000); } catch { }
      }
      State("ferme");
    }
    // ferme la session après 3 minutes sans échange (comme la page /voix, la session coûte tant qu'elle est ouverte)
    public void IdleCheck() {
      if (ws != null && !talking && !connecting && (DateTime.Now - LastActivity).TotalMinutes > 3 && !player.Busy) Task.Run(new Action(Close));
    }
  }

  // ===================================================================
  //  L'application : tout l'affichage tourne ici, en code compilé
  // ===================================================================
  public class App {
    Window win; Hashtable sync; Hashtable cfg;
    Canvas root, clipHost; Path shape, earL, earR; Border bubble;
    FrameworkElement compact, toast, peek, expanded;
    FrameworkElement[] layers;
    string[] layerNames = { "Compact", "Toast", "Peek", "Expanded" };
    string layer = "Compact";
    Spring W, H, R, B;
    bool running; TimeSpan last;
    const double WinW = 520, Cx = 260;
    IntPtr hwnd;
    string logPath; string lastLog = "";
    Color accentDefault, timerColor, chargeColor, accent;
    SolidColorBrush accentBrush;
    GradientStop tintStop;
    DropShadowEffect eyeGlow, eyeGlow2;
    DispatcherTimer tick, hoverTimer;
    bool expandedOn, mouseIn, typing, hiddenFs, restartPending;
    DateTime toastUntil = DateTime.MinValue, peekUntil = DateTime.MinValue, restartAt = DateTime.MinValue;
    DateTime nextBlink = DateTime.Now.AddSeconds(3), nextLook = DateTime.Now.AddSeconds(5), lastPage = DateTime.MinValue;
    string targetKey = "", tintKey = "", trackKey = "", marqueeText = null, page = "PgNox", tabOrder = "", compactKey = "", peekKey = "";
    List<string> agendaItems = new List<string>();
    HashSet<string> evPeeked = new HashSet<string>();
    static readonly Color EventColor = Color.FromRgb(0x0A, 0x84, 0xFF);
    bool dragging; DateTime lastDrag = DateTime.MinValue; string btnKey = "";
    DispatcherTimer waveTimer; double progressFrac, wavePhase, waveAmp; DateTime lastWave = DateTime.Now;
    DateTime holdUntil = DateTime.MinValue;
    Path edgePath; GradientBrush edgeBrush; GradientStop edgeTop, edgeMid, edgeLow;
    bool noxUnread, peeking, tilted; string clockShown = ""; string eyeModeShown = ""; string lastSong = "";
    double compactW = 160, stickyH = 0, expNatural = 0; string expKey = ""; Size peekSize = new Size(300, 60);
    bool firstTrack = true, eqOn = false, ringIsTimer = false, peekIsConfirm = false;
    DateTime? timerEnd = null; double timerTotal = 1; string timerLabel = "";
    double vol = -2; bool muted = false; int battPct = 100; bool? power = null; bool lowWarned = false;
    string noxMsgId = null; bool noxSeen = false; string noxState = "";
    double wheelAcc = 0; int tickN = 0;
    string[] pageNames = { "PgMusic", "PgTimer", "PgNox", "PgToday", "PgAgenda", "PgHouse", "PgTools" };
    string[] tabNames = { "TabMusic", "TabTimer", "TabNox", "TabToday", "TabAgenda", "TabHouse", "TabTools" };
    System.Globalization.CultureInfo fr = System.Globalization.CultureInfo.GetCultureInfo("fr-FR");

    public App(Window w, Hashtable s, Hashtable c) {
      win = w; sync = s; cfg = c;
      logPath = Str(G(cfg, "logPath"));
      accentDefault = Rgb(Str(G(cfg, "accent")));
      timerColor = Rgb(Str(G(cfg, "timerColor")));
      chargeColor = Rgb(Str(G(cfg, "chargeColor")));
      accent = accentDefault;

      root = E<Canvas>("Root"); clipHost = E<Canvas>("ClipHost");
      shape = E<Path>("Shape"); earL = E<Path>("EarL"); earR = E<Path>("EarR"); bubble = E<Border>("Bubble");
      compact = E<FrameworkElement>("Compact"); toast = E<FrameworkElement>("Toast");
      peek = E<FrameworkElement>("Peek"); expanded = E<FrameworkElement>("Expanded");
      layers = new FrameworkElement[] { compact, toast, peek, expanded };
      foreach (FrameworkElement l in layers) {
        TransformGroup tg = new TransformGroup();
        tg.Children.Add(new ScaleTransform(1, 1)); tg.Children.Add(new TranslateTransform(0, 0));
        l.RenderTransform = tg; l.RenderTransformOrigin = new Point(0.5, 0);
        Canvas.SetTop(l, 0);
        if (l != compact) { l.Opacity = 0; l.IsHitTestVisible = false; }
      }
      foreach (string p in pageNames) E<FrameworkElement>(p).RenderTransform = new TranslateTransform(0, 0);

      // pinceaux vivants
      accentBrush = new SolidColorBrush(accentDefault);
      foreach (string e in new[] { "Eq1", "Eq2", "Eq3", "Eq4", "Eq5", "Eq6", "Eq7", "Eq8" }) E<Shape>(e).Fill = accentBrush;
      E<Border>("EBar").Background = accentBrush;
      E<Path>("EWave").Stroke = accentBrush;
      // barre de lecture en vague (style Apple Music / Android) : redessinée ~45 fois par seconde, seulement quand on la voit
      meterTimer = new DispatcherTimer(DispatcherPriority.Render, win.Dispatcher);
      meterTimer.Interval = TimeSpan.FromMilliseconds(40);   // 25 fois par seconde
      meterTimer.Tick += delegate { Safe("son", MeterTick); };
      waveTimer = new DispatcherTimer(DispatcherPriority.Render, win.Dispatcher);
      waveTimer.Interval = TimeSpan.FromMilliseconds(22);
      waveTimer.Tick += delegate { Safe("vague", DrawWave); };
      LinearGradientBrush bg = new LinearGradientBrush();
      bg.StartPoint = new Point(0.5, 0); bg.EndPoint = new Point(0.5, 1);
      bg.GradientStops.Add(new GradientStop(Colors.Black, 0));
      bg.GradientStops.Add(new GradientStop(Colors.Black, 0.68));   // teinte seulement dans le bas (avis design)
      tintStop = new GradientStop(Colors.Black, 1);
      bg.GradientStops.Add(tintStop);
      bg.MappingMode = BrushMappingMode.RelativeToBoundingBox;
      shape.Fill = bg;
      // fin liseré à la couleur de la pochette : invisible en haut (collé à l'écran), présent sur les côtés et le bas
      // reflet façon verre poli : lumineux au centre du bas, s'estompe vers les côtés et disparaît en haut
      RadialGradientBrush rb = new RadialGradientBrush();
      rb.Center = new Point(0.5, 1); rb.GradientOrigin = new Point(0.5, 1); rb.RadiusX = 0.62; rb.RadiusY = 1.05;
      edgeBrush = rb;
      edgeLow = new GradientStop(Color.FromArgb(0, 255, 255, 255), 0.0);
      edgeMid = new GradientStop(Color.FromArgb(0, 255, 255, 255), 0.55);
      edgeTop = new GradientStop(Color.FromArgb(0, 255, 255, 255), 1.0);
      edgeBrush.GradientStops.Add(edgeTop); edgeBrush.GradientStops.Add(edgeMid); edgeBrush.GradientStops.Add(edgeLow);
      edgePath = E<Path>("Edge"); edgePath.Stroke = edgeBrush;
      earL.Fill = Brushes.Black; earR.Fill = Brushes.Black;
      eyeGlow = new DropShadowEffect { BlurRadius = 8, ShadowDepth = 0, Opacity = 0.95, Color = Rgb("#B9B4FF") };
      eyeGlow2 = new DropShadowEffect { BlurRadius = 12, ShadowDepth = 0, Opacity = 0.95, Color = Rgb("#B9B4FF") };

      eyeGlow.Color = Rgb("#F4EFE6"); eyeGlow.BlurRadius = 7; eyeGlow.Opacity = 0.6;
      E<FrameworkElement>("CEyes").Effect = eyeGlow;
      W = new Spring(160); H = new Spring(34); R = new Spring(16); B = new Spring(0);
      Apply();

      // survol : ouverture rapide, fermeture un peu retardée
      hoverTimer = new DispatcherTimer(DispatcherPriority.Normal, win.Dispatcher);
      hoverTimer.Tick += delegate {
        hoverTimer.Stop();
        // juste après un changement de widget, la vue peut rétrécir et laisser la souris en dessous : on attend qu'elle revienne
        if (!mouseIn && expandedOn && DateTime.Now < holdUntil) { hoverTimer.Interval = TimeSpan.FromMilliseconds(150); hoverTimer.Start(); return; }
        SetExpanded(mouseIn || typing || talking);
      };
      win.MouseEnter += delegate { mouseIn = true; Hover(); };
      win.MouseLeave += delegate { mouseIn = false; Hover(); };
      win.PreviewMouseLeftButtonDown += delegate { Squish(0.97, 90); };
      win.PreviewMouseLeftButtonUp += delegate { Squish(1, 320); };

      // boutons
      Click("BPlay", delegate { Cmd(HasMedia() ? "play" : "spotify"); });
      Click("BNext", delegate { Cmd("next"); });
      Click("BPrev", delegate { Cmd("prev"); });
      Click("BT25", delegate { StartTimer(25, "Focus"); });
      Click("BT5", delegate { StartTimer(5, "Pause"); });
      Click("BTStop", delegate { timerEnd = null; UpdateTimer(); Refresh(); });
      for (int i = 0; i < tabNames.Length; i++) {
        string target = pageNames[i];
        Click(tabNames[i], delegate { GoPage(target); });
      }
      E<FrameworkElement>("EBarHit").MouseLeftButtonUp += SeekClick;
      Click("BSend", delegate { SendNox(); });
      Click("BConfOk", delegate { Confirm(true); });
      Click("BConfNo", delegate { Confirm(false); });
      // micro : maintenir pour parler à Nox, relâcher pour qu'il réponde (directement dans la pilule)
      Button mic = E<Button>("BMic");
      mic.PreviewMouseLeftButtonDown += delegate(object o, MouseButtonEventArgs ev) { ev.Handled = true; TalkStart(); };
      mic.PreviewMouseLeftButtonUp += delegate(object o, MouseButtonEventArgs ev) { ev.Handled = true; TalkEnd(); };
      mic.MouseLeave += delegate { if (talking) TalkEnd(); };
      voice.OnLog = delegate(string m) { win.Dispatcher.BeginInvoke(new Action(delegate { Log(m); })); };
      voice.OnState = delegate(string st) { win.Dispatcher.BeginInvoke(new Action(delegate { VoiceState(st); })); };
      voice.OnHeard = delegate(string t) { win.Dispatcher.BeginInvoke(new Action(delegate { ShowVoiceText("Toi", t); })); };
      voice.OnSaid = delegate(string t) { win.Dispatcher.BeginInvoke(new Action(delegate { ShowVoiceText("Nox", t); })); };
      voice.OnTurnDone = delegate(string t) { win.Dispatcher.BeginInvoke(new Action(delegate { VoiceTurnDone(t); })); };
      // glisser un fichier sur la pilule : Nox propose où le ranger
      win.AllowDrop = true;
      win.DragEnter += OnDrag; win.DragOver += OnDrag; win.Drop += OnDrop;
      Click("BPeekOk", delegate { Confirm(true); peekUntil = DateTime.MinValue; Refresh(); });
      Click("BPeekNo", delegate { Confirm(false); peekUntil = DateTime.MinValue; Refresh(); });
      TextBox input = E<TextBox>("NInput");
      input.PreviewMouseLeftButtonDown += delegate { StartTyping(); };
      input.TextChanged += delegate { E<UIElement>("NPh").Visibility = input.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed; };
      input.KeyDown += delegate(object o, KeyEventArgs ev) {
        if (ev.Key == Key.Enter) { SendNox(); ev.Handled = true; }
        else if (ev.Key == Key.Escape) { StopTyping(); ev.Handled = true; }
      };
      win.Deactivated += delegate { if (typing) StopTyping(); };
      input.LostKeyboardFocus += delegate { if (typing) StopTyping(); };

      // menu clic droit
      ContextMenu menu = new ContextMenu();
      menu.Items.Add(new MenuItem { Header = "Dynamic Island v" + G(cfg, "version"), IsEnabled = false });
      menu.Items.Add(new MenuItem { Header = "Mises à jour automatiques (GitHub)", IsEnabled = false });
      menu.Items.Add(new Separator());
      MenuItem miLog = new MenuItem { Header = "Ouvrir le journal" };
      miLog.Click += delegate { try { System.Diagnostics.Process.Start("notepad.exe", "\"" + logPath + "\""); } catch { } };
      MenuItem miRestart = new MenuItem { Header = "Redémarrer" };
      miRestart.Click += delegate { sync["restart"] = true; win.Close(); };
      MenuItem miQuit = new MenuItem { Header = "Quitter" };
      miQuit.Click += delegate { win.Close(); };
      menu.Items.Add(miLog); menu.Items.Add(miRestart); menu.Items.Add(miQuit);
      win.ContextMenu = menu;

      win.SourceInitialized += delegate {
        hwnd = new WindowInteropHelper(win).Handle;
        Win.NoActivate(hwnd, true);
        HwndSource src = HwndSource.FromHwnd(hwnd);
        if (src != null) src.AddHook(WndProc);
        Log("fenêtre créée");
      };
      win.ContentRendered += delegate { Log("fenêtre affichée à l'écran"); };
      win.Dispatcher.UnhandledException += delegate(object s2, DispatcherUnhandledExceptionEventArgs ue) { Log("erreur : " + ue.Exception.Message); ue.Handled = true; };
      Place();

      tick = new DispatcherTimer(DispatcherPriority.Background, win.Dispatcher);
      tick.Interval = TimeSpan.FromMilliseconds(100);
      tick.Tick += delegate { Safe("cycle", Tick); };
      UpdateBattery(); UpdateTimer(); Safe("raccourcis", BuildTools); Safe("maison", delegate { UpdateHouse(null); }); ShowPage("PgNox", 0);
      tick.Start();
      Log("interface prête (code compilé)");
    }

    // ---------------- utilitaires ----------------
    T E<T>(string n) where T : class {
      object o = win.FindName(n);
      if (o == null) throw new Exception("élément introuvable : " + n);
      return (T)o;
    }
    void Click(string n, RoutedEventHandler h) { E<Button>(n).Click += h; }
    static Color Rgb(string hex) { return (Color)ColorConverter.ConvertFromString(hex); }
    static SolidColorBrush Br(string hex) { SolidColorBrush b = new SolidColorBrush(Rgb(hex)); b.Freeze(); return b; }
    static SolidColorBrush Br(Color c) { SolidColorBrush b = new SolidColorBrush(c); b.Freeze(); return b; }
    public void Log(string m) {
      if (m == lastLog) return; lastLog = m;
      try { System.IO.File.AppendAllText(logPath, DateTime.Now.ToString("HH:mm:ss") + " UI  " + m + Environment.NewLine, System.Text.Encoding.UTF8); } catch { }
    }
    void Safe(string what, Action a) { try { a(); } catch (Exception ex) { Log(what + " : " + ex.Message); } }
    static object U(object o) { PSObject p = o as PSObject; return p != null ? p.BaseObject : o; }
    static object G(Hashtable h, string k) { return h == null ? null : U(h[k]); }
    static string Str(object o) { return o == null ? "" : o.ToString(); }
    static bool Bool(object o) { o = U(o); return o is bool && (bool)o; }
    static double Num(object o) { o = U(o); try { return o == null ? 0 : Convert.ToDouble(o); } catch { return 0; } }

    static void Anim(Animatable target, DependencyProperty p, double to, int ms, int delay, IEasingFunction ease) {
      DoubleAnimation a = new DoubleAnimation(to, TimeSpan.FromMilliseconds(ms));
      if (delay > 0) a.BeginTime = TimeSpan.FromMilliseconds(delay);
      a.EasingFunction = ease ?? new CubicEase { EasingMode = EasingMode.EaseOut };
      target.BeginAnimation(p, a);
    }
    static void Anim(UIElement target, DependencyProperty p, double to, int ms, int delay, IEasingFunction ease) {
      DoubleAnimation a = new DoubleAnimation(to, TimeSpan.FromMilliseconds(ms));
      if (delay > 0) a.BeginTime = TimeSpan.FromMilliseconds(delay);
      a.EasingFunction = ease ?? new CubicEase { EasingMode = EasingMode.EaseOut };
      target.BeginAnimation(p, a);
    }
    static IEasingFunction Quint() { return new QuinticEase { EasingMode = EasingMode.EaseOut }; }
    static IEasingFunction Back(double amp) { return new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = amp }; }
    static void AnimColor(Animatable target, DependencyProperty p, Color to, int ms) {
      ColorAnimation a = new ColorAnimation(to, TimeSpan.FromMilliseconds(ms));
      a.EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut };
      target.BeginAnimation(p, a);
    }

    void Place() {
      Rect wa = SystemParameters.WorkArea;
      win.Left = wa.Left + (wa.Width - win.Width) / 2;
      win.Top = 0;
    }

    // ---------------- forme (ressorts, image par image) ----------------
    void MorphTo(double w, double h, double r, double resp, double damp) {
      W.Target = w; H.Target = h; R.Target = r;
      W.Response = resp; H.Response = resp * 1.06; R.Response = resp;
      W.Damping = damp; H.Damping = damp; R.Damping = Math.Min(1, damp + 0.1);
      StartFrames();
    }
    void BubbleTo(double s) { B.Target = s; B.Response = 0.45; B.Damping = 0.7; StartFrames(); }
    void StartFrames() { if (!running) { running = true; last = TimeSpan.Zero; CompositionTarget.Rendering += OnFrame; } }
    void OnFrame(object s, EventArgs e) {
      RenderingEventArgs re = e as RenderingEventArgs;
      double dt = 1.0 / 60;
      if (re != null) {
        if (re.RenderingTime == last) return;   // même image, déjà calculée
        if (last != TimeSpan.Zero) dt = (re.RenderingTime - last).TotalSeconds;
        last = re.RenderingTime;
      }
      if (dt <= 0) return;
      if (dt > 0.034) dt = 0.034;
      int n = (int)Math.Ceiling(dt / 0.004); double st = dt / n;
      for (int i = 0; i < n; i++) { W.Step(st); H.Step(st); R.Step(st); B.Step(st); }
      if (W.Settled && H.Settled && R.Settled && B.Settled) {
        W.Snap(); H.Snap(); R.Snap(); B.Snap();
        CompositionTarget.Rendering -= OnFrame; running = false;
      }
      Apply();
    }
    void Apply() {
      double w = Math.Max(24, W.Value), h = Math.Max(20, H.Value), r = Math.Max(0, R.Value);
      double x = Cx - w / 2;
      Geometry g = Fx.Notch(x, w, h, r);
      shape.Data = g;
      edgePath.Data = Fx.NotchEdge(x + 0.8, w - 1.6, h - 0.8, Math.Max(0, r - 0.8));   // légèrement à l'intérieur : pas coupé par le bord
      clipHost.Clip = g;
      ((TranslateTransform)earL.RenderTransform).X = x - 12;
      ((TranslateTransform)earR.RenderTransform).X = x + w;
      FrameworkElement pk = E<FrameworkElement>("Peeker");
      Canvas.SetLeft(pk, x + w - 46); Canvas.SetTop(pk, h - 13);
      double b = Math.Max(0, B.Value);
      bubble.Width = b; bubble.Height = b; bubble.CornerRadius = new CornerRadius(b / 2);
      bubble.Opacity = Math.Max(0, Math.Min(1, b / 30));
      ((TranslateTransform)bubble.RenderTransform).X = x + w + 18;
      bubble.Visibility = b < 0.5 ? Visibility.Collapsed : Visibility.Visible;
    }
    void Squish(double s, int ms) {
      ScaleTransform st = (ScaleTransform)root.RenderTransform;
      IEasingFunction e = s < 1 ? null : Back(0.4);
      Anim(st, ScaleTransform.ScaleXProperty, s, ms, 0, e);
      Anim(st, ScaleTransform.ScaleYProperty, s, ms, 0, e);
    }

    // ---------------- couches ----------------
    void ShowLayer(string name, double width) {
      for (int i = 0; i < layers.Length; i++) {
        FrameworkElement l = layers[i];
        bool on = layerNames[i] == name;
        if (on && !double.IsNaN(width)) { l.Width = width; Canvas.SetLeft(l, Cx - width / 2); }
      }
      if (name == layer) return;
      layer = name;
      for (int i = 0; i < layers.Length; i++) {
        FrameworkElement l = layers[i];
        bool on = layerNames[i] == name;
        ScaleTransform sc = (ScaleTransform)((TransformGroup)l.RenderTransform).Children[0];
        l.IsHitTestVisible = on;
        if (on) {
          l.BeginAnimation(UIElement.OpacityProperty, null); l.Opacity = 0;
          sc.BeginAnimation(ScaleTransform.ScaleXProperty, null); sc.BeginAnimation(ScaleTransform.ScaleYProperty, null);
          sc.ScaleX = 0.9; sc.ScaleY = 0.9;
          Anim(l, UIElement.OpacityProperty, 1, 200, 45, null);
          // passe du flou au net en même temps que la forme grandit, puis l'effet est retiré (aucun coût ensuite)
          BlurEffect blur = new BlurEffect(); blur.Radius = 7; blur.RenderingBias = RenderingBias.Performance;
          l.Effect = blur;
          DoubleAnimation ba = new DoubleAnimation(0, TimeSpan.FromMilliseconds(240));
          ba.BeginTime = TimeSpan.FromMilliseconds(30);
          ba.EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut };
          FrameworkElement target = l;
          ba.Completed += delegate { if (target.Effect == blur) target.Effect = null; };
          blur.BeginAnimation(BlurEffect.RadiusProperty, ba);
          Anim(sc, ScaleTransform.ScaleXProperty, 1, 420, 20, Back(0.35));
          Anim(sc, ScaleTransform.ScaleYProperty, 1, 420, 20, Back(0.35));
        } else {
          Anim(l, UIElement.OpacityProperty, 0, 90, 0, null);
          Anim(sc, ScaleTransform.ScaleXProperty, 0.95, 120, 0, null);
          Anim(sc, ScaleTransform.ScaleYProperty, 0.95, 120, 0, null);
        }
      }
    }
    Size Natural(FrameworkElement el, double width) {
      el.Width = width;
      el.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
      return el.DesiredSize;
    }

    // ---------------- survol / clavier ----------------
    void Hover() {
      hoverTimer.Stop();
      bool want = mouseIn || typing || talking;
      if (want == expandedOn) return;
      hoverTimer.Interval = TimeSpan.FromMilliseconds(want ? 60 : 220);
      hoverTimer.Start();
    }
    void SetExpanded(bool on) {
      if (on == expandedOn) return;
      expandedOn = on;
      if (!on) { stickyH = 0; expKey = ""; }
      if (on) {
        bool playing = Playing();
        if (DateTime.Now < peekUntil && (peekIsConfirm || E<TextBlock>("PApp").Text == "Nox")) { peekUntil = DateTime.MinValue; ShowPage("PgNox", 0); }
        else ShowPage("PgNox", 0);   // on arrive toujours sur Nox, au milieu
      }
      bool fly = on && page == "PgMusic" && Playing() && layer == "Compact";
      Refresh();
      if (fly) Safe("pochette", FlyArt);
    }

    // la petite pochette glisse et grandit jusqu'à sa place dans la vue ouverte
    void FlyArt() {
      Border from = E<Border>("CArtBox"), to = E<Border>("EArtBox"), fl = E<Border>("Flyer");
      if (from.Visibility != Visibility.Visible || !(from.Background is ImageBrush)) return;
      expanded.UpdateLayout();
      Point a = from.TranslatePoint(new Point(0, 0), compact), b = to.TranslatePoint(new Point(0, 0), expanded);
      double ax = Canvas.GetLeft(compact) + a.X, ay = a.Y, bx = Canvas.GetLeft(expanded) + b.X, by = b.Y;
      if (double.IsNaN(ax) || double.IsNaN(bx)) return;
      fl.Background = from.Background;
      fl.Visibility = Visibility.Visible;
      to.BeginAnimation(UIElement.OpacityProperty, null); to.Opacity = 0;
      IEasingFunction e = new QuinticEase { EasingMode = EasingMode.EaseOut };
      int ms = 420;
      DoubleAnimation ml = new DoubleAnimation(ax, bx, TimeSpan.FromMilliseconds(ms)); ml.EasingFunction = e;
      DoubleAnimation mt = new DoubleAnimation(ay, by, TimeSpan.FromMilliseconds(ms)); mt.EasingFunction = e;
      DoubleAnimation mw = new DoubleAnimation(from.ActualWidth, to.ActualWidth, TimeSpan.FromMilliseconds(ms)); mw.EasingFunction = e;
      DoubleAnimation mh = new DoubleAnimation(from.ActualHeight, to.ActualHeight, TimeSpan.FromMilliseconds(ms)); mh.EasingFunction = e;
      mw.Completed += delegate {
        fl.Visibility = Visibility.Collapsed;
        fl.BeginAnimation(Canvas.LeftProperty, null); fl.BeginAnimation(Canvas.TopProperty, null);
        fl.BeginAnimation(FrameworkElement.WidthProperty, null); fl.BeginAnimation(FrameworkElement.HeightProperty, null);
        to.Opacity = 1;
      };
      fl.BeginAnimation(Canvas.LeftProperty, ml); fl.BeginAnimation(Canvas.TopProperty, mt);
      fl.BeginAnimation(FrameworkElement.WidthProperty, mw); fl.BeginAnimation(FrameworkElement.HeightProperty, mh);
    }
    void StartTyping() {
      if (typing) return;
      typing = true;
      Win.NoActivate(hwnd, false);
      win.Activate(); Win.SetForegroundWindow(hwnd);
      E<TextBox>("NInput").Focus();
      Hover();
    }
    void StopTyping() {
      if (!typing) return;
      typing = false;
      Keyboard.ClearFocus();
      Win.NoActivate(hwnd, true);
      Hover();
    }

    IntPtr WndProc(IntPtr h, int msg, IntPtr wParam, IntPtr lParam, ref bool handled) {
      if (msg == 0x020A || msg == 0x020E) {   // molette verticale / horizontale (pavé tactile)
        if (expandedOn) {
          int delta = (short)((wParam.ToInt64() >> 16) & 0xFFFF);
          double d = msg == 0x020A ? -delta : delta;   // vers le bas ou vers la droite = page suivante
          wheelAcc += d;
          if ((DateTime.Now - lastPage).TotalMilliseconds > 380 && Math.Abs(wheelAcc) >= 100) {
            NextPage(wheelAcc > 0 ? 1 : -1);
            wheelAcc = 0; lastPage = DateTime.Now;
          }
          if ((DateTime.Now - lastPage).TotalMilliseconds <= 380) wheelAcc = 0;
          handled = true;
        }
      }
      return IntPtr.Zero;
    }

    // ---------------- pages ----------------
    List<string> PageList() {
      List<string> l = new List<string>();
      // ordre fixe, Nox au milieu (demande de Mathis) : un geste à gauche ou à droite suffit
      l.Add("PgAgenda"); l.Add("PgMusic"); l.Add("PgNox"); l.Add("PgHouse"); l.Add("PgTools");
      return l;
    }
    void GoPage(string p) {
      List<string> l = PageList();
      int a = l.IndexOf(page), b = l.IndexOf(p);
      if (b < 0 || p == page) return;
      ShowPage(p, b > a ? 1 : -1);
      Refresh();
    }
    void NextPage(int dir) {
      List<string> l = PageList();
      int i = Math.Max(0, l.IndexOf(page)), j = i + dir;
      if (j < 0 || j >= l.Count) {   // petit rebond en bout de liste
        TranslateTransform t = (TranslateTransform)E<FrameworkElement>(page).RenderTransform;
        t.BeginAnimation(TranslateTransform.XProperty, null); t.X = -10 * dir;
        Anim(t, TranslateTransform.XProperty, 0, 320, 0, Back(0.6));
        return;
      }
      ShowPage(l[j], dir);
      Refresh();
    }
    void ShowPage(string name, int dir) {
      foreach (string p in pageNames) {
        FrameworkElement el = E<FrameworkElement>(p);
        if (p == name) {
          el.Visibility = Visibility.Visible;
          if (dir != 0) {
            TranslateTransform t = (TranslateTransform)el.RenderTransform;
            t.BeginAnimation(TranslateTransform.XProperty, null); t.X = 40 * dir;
            Anim(t, TranslateTransform.XProperty, 0, 380, 0, Quint());
            el.BeginAnimation(UIElement.OpacityProperty, null); el.Opacity = 0;
            Anim(el, UIElement.OpacityProperty, 1, 220, 0, null);
          }
        } else el.Visibility = Visibility.Collapsed;
      }
      if (name != page && expandedOn) holdUntil = DateTime.Now.AddMilliseconds(1600);
      page = name;
      if (name == "PgNox" && expandedOn) noxUnread = false;
      sync["houseWanted"] = name == "PgHouse" && expandedOn;
      List<string> l = PageList();
      string order = string.Join(",", l.ToArray());
      if (order != tabOrder) {   // remet les onglets dans le même ordre que les pages
        tabOrder = order;
        Panel tabs = (Panel)E<Button>("TabNox").Parent;
        foreach (string pg in l) {
          Button tb = E<Button>(tabNames[Array.IndexOf(pageNames, pg)]);
          tabs.Children.Remove(tb); tabs.Children.Add(tb);
        }
      }
      for (int i = 0; i < tabNames.Length; i++) {
        Button tb = E<Button>(tabNames[i]);
        bool avail = l.Contains(pageNames[i]);
        tb.Visibility = avail ? Visibility.Visible : Visibility.Collapsed;
        bool on = pageNames[i] == name;
        tb.Background = on ? (HasMedia() && Playing() ? Br(Color.FromArgb(0x40, accent.R, accent.G, accent.B)) : Br("#26FFFFFF")) : Brushes.Transparent;
        tb.Foreground = on ? (Brush)Br("#FFFFFF") : Br("#A1A1A6");
      }
    }

    // ---------------- données ----------------
    Hashtable Media() { return G(sync, "media") as Hashtable; }
    bool HasMedia() { return Media() != null; }
    bool Playing() { return HasMedia() && Bool(G(sync, "playing")); }
    void Cmd(string c) {
      System.Collections.Concurrent.ConcurrentQueue<string> q = G(sync, "cmds") as System.Collections.Concurrent.ConcurrentQueue<string>;
      if (q != null) q.Enqueue(c); else Log("file de commandes introuvable");
    }
    void NoxCmd(string c) {
      System.Collections.Concurrent.ConcurrentQueue<string> q = G(sync, "noxcmds") as System.Collections.Concurrent.ConcurrentQueue<string>;
      if (q != null) q.Enqueue(c); else Log("file Nox introuvable");
    }

    [DllImport("user32.dll")] static extern bool GetCursorPos(out Win.POINT p);
    bool looking;
    // les yeux suivent la souris quand elle s'approche de la pilule réduite
    void FollowCursor() {
      if (layer != "Compact" || hwnd == IntPtr.Zero) { looking = false; return; }
      FrameworkElement eyes = E<FrameworkElement>("CEyes");
      if (eyes.Visibility != Visibility.Visible || !eyes.IsLoaded) return;
      Win.POINT p; if (!GetCursorPos(out p)) return;
      Point c = eyes.PointToScreen(new Point(eyes.ActualWidth / 2, eyes.ActualHeight / 2));
      double dx = p.X - c.X, dy = p.Y - c.Y, dist = Math.Sqrt(dx * dx + dy * dy);
      TranslateTransform t = (TranslateTransform)E<UIElement>("CPupils").RenderTransform;
      if (dist < 500 && dist > 8) {
        looking = true;
        double tx = Math.Max(-2.2, Math.Min(2.2, dx / 40.0)), ty = Math.Max(-1.0, Math.Min(1.0, dy / 60.0));
        Anim(t, TranslateTransform.XProperty, tx, 160, 0, null); Anim(t, TranslateTransform.YProperty, ty, 160, 0, null);
        nextLook = DateTime.Now.AddSeconds(2);
      } else if (looking) {
        looking = false;
        Anim(t, TranslateTransform.YProperty, 0, 250, 0, null);
      }
    }
    // yeux plissés quand Nox travaille
    void Squint(bool on) {
      foreach (string e in new[] { "EyeL", "EyeR" }) {
        FrameworkElement fe = E<FrameworkElement>(e);
        Anim(fe, FrameworkElement.HeightProperty, on ? 5.0 : 9.0, 260, 0, null);
        Canvas.SetTop(fe, on ? 2.5 : 0.5);
      }
    }
    bool squinting;

    void Tick() {
      Safe("regard", FollowCursor);
      Safe("voix", delegate {
        voice.IdleCheck();
        // musique remise après la réponse de Nox (si c'est la voix qui l'avait mise en pause)
        if (musicPausedByVoice && !talking && !voice.Speaking && DateTime.Now > resumeMusicAt && voiceState != "reflechit") {
          musicPausedByVoice = false;
          if (!Playing()) Cmd("play");
        }
      });
      bool sq = noxState == "busy";
      if (sq != squinting) { squinting = sq; Safe("yeux", delegate { Squint(sq); }); }
      tickN++;
      DateTime now = DateTime.Now;
      if (tickN % 60 == 0) Audio.Reset();
      Safe("volume", UpdateVolume);
      Safe("musique", UpdateMedia);
      if (tickN % 5 == 1) Safe("minuteur", UpdateTimer);
      if (dragging && (now - lastDrag).TotalMilliseconds > 450) { dragging = false; peekUntil = DateTime.MinValue; }
      if (tickN % 10 == 3) Safe("appareils", WatchDevices);
      if (tickN % 10 == 1) {
        Safe("batterie", delegate { if (!ringIsTimer) UpdateBattery(); });
        Safe("nox", UpdateNox);
        Safe("plein écran", CheckFullscreen);
        Rect wa = SystemParameters.WorkArea;
        if (Math.Abs(win.Left - (wa.Left + (wa.Width - win.Width) / 2)) > 1) Place();
      }
      if (G(sync, "updated") != null && !restartPending) {
        restartPending = true; restartAt = now.AddSeconds(4);
        ShowPeek(null, "", "#FFFFFF", Str(G(cfg, "chargeColor")), "Dynamic Island", "Mise à jour v" + Str(G(sync, "updated")), "Redémarrage…", 4000, false);
      }
      if (restartPending && now >= restartAt && !expandedOn && !typing) { sync["restart"] = true; win.Close(); return; }
      if (tickN == 30 || tickN % 3000 == 0)
        Log(string.Format("diag : couche={0} page={1} forme={2:0}x{3:0} musique={4} nox={5}", layer, page, W.Value, H.Value, HasMedia(), noxState));
      Refresh();
    }

    // ---------------- état -> forme ----------------
    void Refresh() {
      DateTime now = DateTime.Now;
      bool hasMedia = HasMedia(), playing = Playing(), timerOn = timerEnd.HasValue;
      string clock = now.ToString("HH:mm");
      E<TextBlock>("EClock").Text = clock;
      if (clock != clockShown) {   // pilule au repos : date discrète + heure (« Mer 4 nov  20:35 »)
        clockShown = clock;
        string d = now.ToString("ddd d MMM", fr).Replace(".", "");
        d = char.ToUpper(d[0]) + d.Substring(1);
        TextBlock cc = E<TextBlock>("CClock");
        cc.Inlines.Clear();
        System.Windows.Documents.Run rd = new System.Windows.Documents.Run(d + "   ");
        rd.Foreground = Br("#A1A1A6"); rd.FontSize = 12.5;
        rd.FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI");
        cc.Inlines.Add(rd);
        cc.Inlines.Add(new System.Windows.Documents.Run(clock));
      }
      E<TextBlock>("EDate").Text = fr.TextInfo.ToTitleCase(now.ToString("dddd d MMMM", fr));

      double w, h, r, resp, damp, bub = 0; string name;
      if (expandedOn) {
        name = "Expanded";
        List<string> l = PageList();
        if (!l.Contains(page)) ShowPage(l[0], 0);
        else if (string.Join(",", l.ToArray()) != tabOrder) ShowPage(page, 0);
        // la vue ne rétrécit pas tant que la souris est dessus (sinon elle se refermerait sous le curseur)
        string ek = page + "|" + agendaRev + "|" + houseRev + "|" + VisKey("NConfirm") + VisKey("NLastBox") + VisKey("EProg") + VisKey("NAct") + VisKey("TMeteo") + VisKey("TAgenda1") + VisKey("TAgenda2");
        if (ek != expKey) { expKey = ek; expanded.Height = double.NaN; expNatural = Math.Ceiling(Natural(expanded, 440).Height); }
        stickyH = expNatural;   // chaque widget a sa hauteur (plus de vide) ; un délai de grâce évite la fermeture sous le curseur
        expanded.Height = stickyH;
        w = 440; h = stickyH; r = 30; resp = 0.42; damp = 0.8;
      } else if (now < toastUntil) {
        name = "Toast"; w = 300; h = 34; r = 16; resp = 0.32; damp = 0.82;
      } else if (now < peekUntil) {
        name = "Peek";
        string pk = E<TextBlock>("PTitle").Text + "|" + E<TextBlock>("PSub").Text + "|" + E<TextBlock>("PApp").Text + "|" + peekIsConfirm;
        if (pk != peekKey) { peekKey = pk; peekSize = Natural(peek, double.NaN); }
        w = Math.Ceiling(peekSize.Width); h = Math.Ceiling(peekSize.Height); r = 26; resp = 0.4; damp = 0.8;
      } else {
        name = "Compact";
        bool music = playing;
        bool noxBusy = noxState == "busy";
        string evTitle; double evMin;
        bool ev = NextEvent(now, out evTitle, out evMin) && !timerOn;
        Vis("CArtBox", music); Vis("CTitleBox", music); Vis("CEq", music);
        // plus d'anneau de batterie (demande de Mathis) : l'anneau sert au minuteur et au prochain rendez-vous
        Vis("CRingBox", (timerOn || ev) && !music); Vis("CTimer", timerOn && !music); Vis("CEvent", ev && !music);
        Vis("CClock", !music && !timerOn && !ev); Vis("CEyes", true);   // les yeux de Nox restent aussi pendant la musique
        // ils prennent la couleur de la pochette pendant la musique (rouges si Nox est injoignable)
        string eyeMode = noxState == "down" ? "down" : (music ? "music" : "idle");
        if (eyeMode != eyeModeShown) {
          eyeModeShown = eyeMode;
          Brush f = eyeMode == "down" ? (Brush)Br("#FF6B5E") : (eyeMode == "music" ? (Brush)accentBrush : Br("#F4EFE6"));
          E<Ellipse>("CEyeFillL").Fill = f; E<Ellipse>("CEyeFillR").Fill = f;
        }
        Color gc = eyeMode == "music" ? accent : (eyeMode == "down" ? Rgb("#FF6B5E") : Rgb("#F4EFE6"));
        if (eyeGlow.Color != gc) eyeGlow.Color = gc;
        Path ring = E<Path>("CRing");
        if (timerOn && !music) {
          ring.Stroke = Br(timerColor);
          ring.Data = Fx.Arc(17, 2.5, (timerEnd.Value - now).TotalSeconds / timerTotal);
        } else if (ev && !music) {
          ring.Stroke = Br(EventColor);
          ring.Data = Fx.Arc(17, 2.5, Math.Max(0.001, evMin / 15.0));
          string t = evTitle.Length > 22 ? evTitle.Substring(0, 21).TrimEnd() + "…" : evTitle;
          E<TextBlock>("CEvent").Text = t + (evMin > 0.5 ? " · " + (int)Math.Ceiling(evMin) + " min" : " · maintenant");
        }
        string ck = "m" + music + "|" + timerOn + "|" + ev + "|" + clock + "|" + E<TextBlock>("CTimer").Text + "|" + E<TextBlock>("CEvent").Text + "|" + E<FrameworkElement>("CTitleBox").Width;
        if (ck != compactKey || tickN % 10 == 5) {   // re-mesure régulière : au démarrage, la mise en page n'est pas encore prête
           compactKey = ck; compactW = Math.Max(150, Math.Ceiling(Natural(compact, double.NaN).Width)); }
        w = compactW; h = 34; r = 16; resp = 0.34; damp = 0.86;
        if (music && timerOn) {
          bub = 32;
          E<Path>("Ring").Stroke = Br(timerColor); E<TextBlock>("RingTxt").Foreground = Br(timerColor);
        } else if (music && ev) {
          bub = 32;
          E<Path>("Ring").Stroke = Br(EventColor); E<TextBlock>("RingTxt").Foreground = Br(EventColor);
          E<Path>("Ring").Data = Fx.Arc(22, 2.5, Math.Max(0.001, evMin / 15.0));
          E<TextBlock>("RingTxt").Text = evMin > 0.5 ? ((int)Math.Ceiling(evMin)).ToString() : "!";
        }

      }
      SetEq(playing);
      UpdateEyes(now);
      // pendant la musique, Nox jette un œil sous la pilule quand il travaille ou a un message pour toi
      bool wantPeek = false;   // remplacé par le masque dans la pilule (demande de Mathis)
      if (wantPeek != peeking) {
        peeking = wantPeek;
        Anim((TranslateTransform)E<UIElement>("Peeker").RenderTransform, TranslateTransform.YProperty, wantPeek ? 9 : 0, wantPeek ? 520 : 260, 0, wantPeek ? Back(0.5) : null);
      }
      // tête penchée quand il a quelque chose pour toi (comme dans l'appli)
      bool attentive = noxUnread || (G(G(sync, "nox") as Hashtable, "confirm") != null);
      if (attentive != tilted) {
        tilted = attentive;
        foreach (string tn in new[] { "CEyes", "PkMaskBox" }) Anim((RotateTransform)E<UIElement>(tn).RenderTransform, RotateTransform.AngleProperty, attentive ? -12 : 0, 420, 0, Back(0.5));
        Anim((RotateTransform)E<UIElement>("NOwl").RenderTransform, RotateTransform.AngleProperty, attentive ? -10 : 0, 420, 0, Back(0.5));
      }

      string key = name + "|" + w + "|" + h + "|" + bub;
      ShowLayer(name, w);
      if (key != targetKey) {
        targetKey = key;
        MorphTo(w, h, r, resp, damp);
        BubbleTo(bub);
      }

      // teinte du bas : pochette quand ça joue, violet de Nox sinon
      Color col = accentDefault; double level;
      // teinte légère (avis design : la bande saturée faisait « défaut d'affichage »)
      if (playing) { col = accent; level = name == "Compact" ? 0.14 : 0.3; }   // musique en pause = ambiance du moment
      else level = name == "Compact" ? 0.08 : (name == "Expanded" ? 0.18 : 0.08);
      // sans musique : ambiance du moment de la journée (et de Nox), même style que la pochette
      string palKey = PaletteKey(now);
      bool useArt = playing && artTiny != null;
      if (!playing) col = PaletteMain(palKey);
      string ambKey = useArt ? "art:" + trackKey : "pal:" + palKey;
      if (ambKey != ambShown) { ambShown = ambKey; Safe("ambiance", delegate { E<Image>("AmbImg").Source = useArt ? artTiny : PaletteBitmap(palKey); }); tintKey = ""; }
      string tk = level + "|" + col + "|" + ambKey;
      if (tk != tintKey) {
        tintKey = tk; AnimColor(tintStop, GradientStop.ColorProperty, Fx.Shade(col, level), 450);
        // liseré coloré seulement pendant la musique ; plus marqué quand la pilule est ouverte
        bool edge = playing || name == "Expanded";
        byte alpha = (byte)(edge ? (name == "Compact" ? 200 : (playing ? 240 : 170)) : 0);
        // couleur éclaircie (35 % vers le blanc) pour se détacher de la teinte du fond
        Color lc = Color.FromRgb((byte)(col.R + (255 - col.R) * 0.45), (byte)(col.G + (255 - col.G) * 0.45), (byte)(col.B + (255 - col.B) * 0.45));
        AnimColor(edgeMid, GradientStop.ColorProperty, Color.FromArgb((byte)(alpha * 0.35), lc.R, lc.G, lc.B), 500);
        // le fond vivant remplace la teinte du bas dans la vue ouverte
        bool amb = name == "Expanded";
        Anim(E<UIElement>("Amb"), UIElement.OpacityProperty, amb ? 1 : 0, amb ? 500 : 200, 0, null);
        if (amb) AnimColor(tintStop, GradientStop.ColorProperty, Colors.Black, 300);
        SetAmbDrift(amb);
        AnimColor(edgeLow, GradientStop.ColorProperty, Color.FromArgb(alpha, lc.R, lc.G, lc.B), 500);
        AnimColor(edgeTop, GradientStop.ColorProperty, Color.FromArgb(0, lc.R, lc.G, lc.B), 500);
      }
    }
    string VisKey(string n) { return E<UIElement>(n).Visibility == Visibility.Visible ? "1" : "0"; }
    void Vis(string n, bool on) { E<UIElement>(n).Visibility = on ? Visibility.Visible : Visibility.Collapsed; }

    void SetEq(bool on) {
      if (eqOn == on) return;
      eqOn = on;
      if (on) {
        for (int k = 1; k <= 8; k++) ((ScaleTransform)E<UIElement>("Eq" + k).RenderTransform).BeginAnimation(ScaleTransform.ScaleYProperty, null);
        lastMeter = DateTime.Now; meterTimer.Start(); return;
      }
      meterTimer.Stop();
      string[] names = { "Eq1", "Eq2", "Eq3", "Eq4", "Eq5", "Eq6", "Eq7", "Eq8" };
      for (int i = 0; i < names.Length; i++) {
        ScaleTransform st = (ScaleTransform)E<UIElement>(names[i]).RenderTransform;
        st.BeginAnimation(ScaleTransform.ScaleYProperty, null);
        Anim(st, ScaleTransform.ScaleYProperty, 0.3, 200, 0, null);
      }
    }

    // ---------------- son réel -> égaliseur et vague ----------------
    DispatcherTimer meterTimer; DateTime lastMeter = DateTime.Now; double level, meterT;
    double[] eqLevels = new double[4];
    void MeterTick() {
      DateTime now = DateTime.Now;
      double dt = Math.Min(0.1, (now - lastMeter).TotalSeconds); lastMeter = now; meterT += dt;
      float p = Audio.Peak();
      double target = p < 0 ? 0.5 + 0.3 * Math.Sin(meterT * 6) : Math.Min(1, Math.Sqrt(p) * 1.15);   // racine : plus vivant à bas volume
      level = target > level ? level + (target - level) * Math.Min(1, dt * 22) : level + (target - level) * Math.Min(1, dt * 7);
      double[] f = { 7.1, 9.3, 5.7, 11.2 }, ph = { 0, 1.7, 3.1, 4.4 }, gain = { 0.85, 1.0, 0.92, 0.75 };
      for (int i = 0; i < 4; i++) {
        double wob = 0.75 + 0.25 * Math.Sin(meterT * f[i] + ph[i]);
        double t = Math.Max(0.18, Math.Min(1, level * gain[i] * wob * 1.25));
        eqLevels[i] = t;
        ((ScaleTransform)E<UIElement>("Eq" + (i + 1)).RenderTransform).ScaleY = t;
      }
    }

    // ---------------- fond vivant (pochette) ----------------
    bool ambReady, ambDrifting; BitmapSource artTiny; string ambShown = "";
    // moment de la journée + humeur de Nox -> palette
    string PaletteKey(DateTime now) {
      int hr = now.Hour;
      string moment = hr >= 6 && hr < 11 ? "matin" : hr >= 11 && hr < 17 ? "jour" : hr >= 17 && hr < 21 ? "soir" : "nuit";
      return moment + (noxState == "busy" ? "+nox" : "");
    }
    static Color[] PaletteColors(string key) {
      Color[] p;
      if (key.StartsWith("matin")) p = new[] { Rgb("#E8A87C"), Rgb("#F4EFE6"), Rgb("#849C8B"), Rgb("#D46F61") };   // aube : pêche, crème, sauge
      else if (key.StartsWith("jour")) p = new[] { Rgb("#849C8B"), Rgb("#5FA8A0"), Rgb("#F4EFE6"), Rgb("#6F8877") };  // journée : sauge, eau, crème
      else if (key.StartsWith("soir")) p = new[] { Rgb("#D46F61"), Rgb("#8B6FB8"), Rgb("#E8A87C"), Rgb("#4A3F6B") };  // soir : terracotta, violet
      else p = new[] { Rgb("#3B3F7A"), Rgb("#5B6B9A"), Rgb("#2A2D4F"), Rgb("#849C8B") };                            // nuit : indigo, sauge
      if (key.EndsWith("+nox")) p[1] = Rgb("#9C8BFF");   // Nox au travail : une touche de violet
      return p;
    }
    static Color PaletteMain(string key) { return PaletteColors(key)[0]; }
    static BitmapSource PaletteBitmap(string key) {
      Color[] p = PaletteColors(key);
      int[] grid = { 0, 0, 1, 1,  0, 2, 2, 1,  3, 2, 2, 0,  3, 3, 0, 1 };   // 4 x 4 : taches de couleurs, fondues une fois agrandies
      byte[] px = new byte[16 * 4];
      for (int i = 0; i < 16; i++) { Color c = p[grid[i]]; px[i * 4] = c.B; px[i * 4 + 1] = c.G; px[i * 4 + 2] = c.R; px[i * 4 + 3] = 255; }
      BitmapSource b = BitmapSource.Create(4, 4, 96, 96, PixelFormats.Bgra32, null, px, 16);
      b.Freeze(); return b;
    }
    void SetAmbArt(ImageSource art) {
      BitmapSource src = art as BitmapSource;
      ambReady = false;
      if (src == null || src.PixelWidth < 2) { artTiny = null; ambShown = ""; return; }
      // pochette réduite à 4 x 4 pixels : une fois agrandie, elle donne un dégradé doux de ses couleurs
      BitmapSource tiny = new TransformedBitmap(src, new ScaleTransform(4.0 / src.PixelWidth, 4.0 / src.PixelHeight));
      tiny.Freeze();
      artTiny = tiny; ambShown = "";
      ambReady = true; tintKey = "";
    }
    void SetAmbDrift(bool on) {
      if (on == ambDrifting) return;
      ambDrifting = on;
      ScaleTransform sc = E<ScaleTransform>("AmbScale"); TranslateTransform mv = E<TranslateTransform>("AmbMove");
      if (!on) { sc.BeginAnimation(ScaleTransform.ScaleXProperty, null); sc.BeginAnimation(ScaleTransform.ScaleYProperty, null); mv.BeginAnimation(TranslateTransform.XProperty, null); return; }
      DoubleAnimation a = new DoubleAnimation(1.2, 1.45, TimeSpan.FromSeconds(9)); a.AutoReverse = true; a.RepeatBehavior = RepeatBehavior.Forever; a.EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut };
      DoubleAnimation m = new DoubleAnimation(-28, 28, TimeSpan.FromSeconds(13)); m.AutoReverse = true; m.RepeatBehavior = RepeatBehavior.Forever; m.EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut };
      Timeline.SetDesiredFrameRate(a, 20); Timeline.SetDesiredFrameRate(m, 20);   // mouvement lent : 20 images/s suffisent
      sc.BeginAnimation(ScaleTransform.ScaleXProperty, a); sc.BeginAnimation(ScaleTransform.ScaleYProperty, a.Clone());
      mv.BeginAnimation(TranslateTransform.XProperty, m);
    }

    // ---------------- yeux de Nox ----------------
    void UpdateEyes(DateTime now) {
      if (now >= nextBlink) {
        foreach (string e in new[] { "EyeL", "EyeR", "NEyeL", "NEyeR", "PkL", "PkR" }) {
          DoubleAnimationUsingKeyFrames a = new DoubleAnimationUsingKeyFrames();
          a.KeyFrames.Add(new LinearDoubleKeyFrame(1.0, KeyTime.FromTimeSpan(TimeSpan.Zero)));
          a.KeyFrames.Add(new EasingDoubleKeyFrame(0.1, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(70))));
          a.KeyFrames.Add(new EasingDoubleKeyFrame(1.0, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(180))));
          ((ScaleTransform)E<UIElement>(e).RenderTransform).BeginAnimation(ScaleTransform.ScaleYProperty, a);
        }
        Random rnd = new Random();
        nextBlink = rnd.Next(5) == 0 ? now.AddMilliseconds(260) : now.AddMilliseconds(rnd.Next(2500, 6500));
      }
      bool busy = noxState == "busy";
      if (now >= nextLook) {
        Random rnd = new Random();
        // les pupilles bougent dans le masque (lecture de gauche à droite quand il travaille)
        double[] xs = new double[] { -2.0, 0.0, 0.0, 2.0 };
        double x = busy ? (((TranslateTransform)E<UIElement>("CPupils").RenderTransform).X > 0 ? -2 : 2) : xs[rnd.Next(xs.Length)];
        foreach (string e in new[] { "CPupils", "PkPupils", "NPupils" })
          Anim((TranslateTransform)E<UIElement>(e).RenderTransform, TranslateTransform.XProperty, x * (e == "NPupils" ? 1.6 : (e == "PkPupils" ? 0.7 : 1)), 280, 0, Quint());
        nextLook = busy ? now.AddMilliseconds(700) : now.AddMilliseconds(rnd.Next(3000, 8000));
      }
    }

    // ---------------- titre qui défile ----------------
    void SetMarquee(string text) {
      if (text == marqueeText) return;
      marqueeText = text;
      TextBlock t = E<TextBlock>("CTitle");
      TranslateTransform tr = (TranslateTransform)t.RenderTransform;
      t.Text = text;
      tr.BeginAnimation(TranslateTransform.XProperty, null); tr.X = 0;
      t.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
      double tw = Math.Ceiling(t.DesiredSize.Width), max = 150;
      E<FrameworkElement>("CTitleBox").Width = Math.Min(tw, max);
      // fondu sur les bords quand le titre défile (au lieu d'être coupé net)
      if (tw > max) {
        LinearGradientBrush fade = new LinearGradientBrush();
        fade.StartPoint = new Point(0, 0.5); fade.EndPoint = new Point(1, 0.5);
        fade.GradientStops.Add(new GradientStop(Color.FromArgb(0, 0, 0, 0), 0));
        fade.GradientStops.Add(new GradientStop(Colors.Black, 0.07));
        fade.GradientStops.Add(new GradientStop(Colors.Black, 0.93));
        fade.GradientStops.Add(new GradientStop(Color.FromArgb(0, 0, 0, 0), 1));
        fade.Freeze();
        E<UIElement>("CTitleBox").OpacityMask = fade;
      } else E<UIElement>("CTitleBox").OpacityMask = null;
      if (tw > max) {
        double dist = tw - max, scroll = Math.Max(1.5, dist / 28.0);
        double t1 = 2.2, t2 = t1 + scroll, t3 = t2 + 1.8, t4 = t3 + 0.5;
        DoubleAnimationUsingKeyFrames a = new DoubleAnimationUsingKeyFrames();
        a.RepeatBehavior = RepeatBehavior.Forever;
        a.KeyFrames.Add(new LinearDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(t1))));
        a.KeyFrames.Add(new LinearDoubleKeyFrame(-dist, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(t2))));
        a.KeyFrames.Add(new LinearDoubleKeyFrame(-dist, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(t3))));
        a.KeyFrames.Add(new EasingDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(t4))));
        Timeline.SetDesiredFrameRate(a, 40);
        tr.BeginAnimation(TranslateTransform.XProperty, a);
      }
    }

    // ---------------- toast / notification ----------------
    // ---------------- Wi-Fi, Bluetooth, sortie audio, clé USB : annoncés brièvement en haut ----------------
    string lastOut = null; bool? wifiUp = null; HashSet<string> btKnown = null, drivesKnown = null;
    void WatchDevices() {
      // sortie audio par défaut
      string nm; string id = Audio.DefaultOutput(out nm);
      if (id != null) {
        if (lastOut != null && id != lastOut) {
          Audio.Reset();   // volume et niveau sonore suivent le nouvel appareil
          string low = nm.ToLowerInvariant();
          bool casque = low.Contains("casque") || low.Contains("head") || low.Contains("airpods") || low.Contains("buds") || low.Contains("écouteurs");
          ShowToast(casque ? "\uE7F6" : "\uE767", "Son sur " + ShortName(nm), "", Colors.White, -1, 2600); Refresh();
        }
        lastOut = id;
      }
      // Wi-Fi
      bool up = false;
      foreach (System.Net.NetworkInformation.NetworkInterface ni in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
        if (ni.NetworkInterfaceType == System.Net.NetworkInformation.NetworkInterfaceType.Wireless80211 && ni.OperationalStatus == System.Net.NetworkInformation.OperationalStatus.Up) up = true;
      if (wifiUp.HasValue && wifiUp.Value != up) {
        if (up) Task.Run(new Action(delegate {
          string ssid = WifiName();
          win.Dispatcher.BeginInvoke(new Action(delegate { ShowToast("\uE701", ssid.Length > 0 ? "Connecté à " + ssid : "Wi-Fi connecté", "", Rgb("#0A84FF"), -1, 2600); Refresh(); }));
        }));
        else { ShowToast("\uEB5E", "Wi-Fi déconnecté", "", Rgb("#8E8E93"), -1, 2600); Refresh(); }
      }
      wifiUp = up;
      // Bluetooth (liste lue par PowerShell)
      IEnumerable bt = G(sync, "bt") as IEnumerable;
      if (bt != null && !(bt is string)) {
        HashSet<string> now = new HashSet<string>();
        foreach (object o in bt) { string s = Str(U(o)); if (s.Length > 0) now.Add(s); }
        if (btKnown != null) {
          foreach (string s in now) if (!btKnown.Contains(s)) { ShowToast("\uE702", ShortName(s) + " connecté", "", Rgb("#0A84FF"), -1, 2600); Refresh(); }
          foreach (string s in btKnown) if (!now.Contains(s)) { ShowToast("\uE702", ShortName(s) + " déconnecté", "", Rgb("#8E8E93"), -1, 2600); Refresh(); }
        }
        btKnown = now;
      }
      // clés USB et disques amovibles
      HashSet<string> drives = new HashSet<string>(); Dictionary<string, string> labels = new Dictionary<string, string>();
      foreach (System.IO.DriveInfo d in System.IO.DriveInfo.GetDrives()) {
        try { if (d.DriveType == System.IO.DriveType.Removable && d.IsReady) { drives.Add(d.Name); labels[d.Name] = d.VolumeLabel; } } catch { }
      }
      if (drivesKnown != null) {
        foreach (string d in drives) if (!drivesKnown.Contains(d)) { string lb = labels[d]; ShowToast("\uE88E", (lb.Length > 0 ? lb : "Clé USB") + " connectée", d.TrimEnd('\\'), Colors.White, -1, 2600); Refresh(); }
        foreach (string d in drivesKnown) if (!drives.Contains(d)) { ShowToast("\uE88E", "Clé USB retirée", d.TrimEnd('\\'), Rgb("#8E8E93"), -1, 2200); Refresh(); }
      }
      drivesKnown = drives;
    }
    static string ShortName(string s) { return s.Length > 26 ? s.Substring(0, 25).TrimEnd() + "…" : s; }
    static string WifiName() {
      try {
        System.Diagnostics.ProcessStartInfo psi = new System.Diagnostics.ProcessStartInfo("netsh", "wlan show interfaces");
        psi.CreateNoWindow = true; psi.UseShellExecute = false; psi.RedirectStandardOutput = true;
        psi.StandardOutputEncoding = Encoding.GetEncoding(850);
        using (System.Diagnostics.Process p = System.Diagnostics.Process.Start(psi)) {
          string outp = p.StandardOutput.ReadToEnd(); p.WaitForExit(3000);
          foreach (string line in outp.Split('\n')) {
            string l = line.Trim();
            if (l.StartsWith("SSID") && !l.StartsWith("SSID BSSID")) { int i = l.IndexOf(':'); if (i > 0) return l.Substring(i + 1).Trim(); }
          }
        }
      } catch { }
      return "";
    }

    void ShowToast(string icon, string text, string right, Color color, double bar, int ms) {
      E<TextBlock>("TIco").Text = icon; E<TextBlock>("TIco").Foreground = Br(color);
      E<TextBlock>("TRight").Text = right;
      if (bar >= 0) {
        Vis("TText", false); Vis("TBarBg", true);
        Border b = E<Border>("TBar");
        b.Background = Br(color);
        Anim(b, FrameworkElement.WidthProperty, Math.Max(0, Math.Min(1, bar)) * 170, 140, 0, null);
      } else { Vis("TText", true); Vis("TBarBg", false); E<TextBlock>("TText").Text = text; }
      toastUntil = DateTime.Now.AddMilliseconds(ms);
    }
    void ShowPeek(ImageSource art, string icon, string iconColor, string iconBg, string app, string title, string sub, int ms, bool confirm) {
      SetArt("PArtBox", art);
      E<TextBlock>("PIco").Text = art == null ? icon : "";
      E<TextBlock>("PIco").Foreground = Br(iconColor);
      if (art == null) E<Border>("PArtBox").Background = Br(iconBg ?? "#2C2C2E");
      E<TextBlock>("PApp").Text = app;
      E<TextBlock>("PTitle").Text = title;
      E<TextBlock>("PSub").Text = sub ?? "";
      Vis("PSub", !string.IsNullOrEmpty(sub));
      Vis("PButtons", confirm);
      peekIsConfirm = confirm;
      peekUntil = DateTime.Now.AddMilliseconds(ms);
    }
    void SetArt(string box, ImageSource art) {
      Border b = E<Border>(box);
      if (art != null) { ImageBrush ib = new ImageBrush(art); ib.Stretch = Stretch.UniformToFill; ib.Freeze(); b.Background = ib; }
      else b.Background = Br("#1C1C1E");
    }

    // ---------------- batterie / volume / plein écran ----------------
    static string BattGlyph(int pct, bool charging) {
      int i = (int)Math.Round(pct / 10.0);
      if (charging) return i >= 10 ? "" : (i == 9 ? "" : ((char)(0xE85A + i)).ToString());
      return i >= 10 ? "" : ((char)(0xE850 + i)).ToString();
    }
    void UpdateBattery() {
      bool online; int pct = Win.Battery(out online);
      if (pct < 0) { battPct = -1; Vis("CRingBox", false); return; }
      battPct = pct;
      string g = BattGlyph(pct, online);
      Color col = online ? chargeColor : (pct <= 20 ? Rgb("#FF453A") : Rgb("#F2F2F7"));
      E<TextBlock>("EBattIco").Text = g; E<TextBlock>("EBattIco").Foreground = Br(col);
      E<TextBlock>("EBattTxt").Text = online ? pct + " % · en charge" : pct + " %";
      if (power.HasValue && power.Value != online)
        ShowToast(g, online ? "En charge" : "Sur batterie", pct + "%", online ? chargeColor : Colors.White, -1, 2000);
      power = online;
      if (!online && pct <= 20 && !lowWarned) { lowWarned = true; ShowToast(g, "Batterie faible", pct + "%", Rgb("#FF453A"), -1, 3500); }
      if (online) lowWarned = false;
    }
    static string VolGlyph(int pct, bool m) {
      if (m) return "";
      return pct == 0 ? "" : (pct < 34 ? "" : (pct < 67 ? "" : ""));
    }
    void UpdateVolume() {
      double v = Audio.Level();
      if (v < 0) return;
      bool m = Audio.Muted();
      bool changed = vol >= 0 && (Math.Abs(v - vol) > 0.004 || m != muted);
      vol = v; muted = m;
      int pct = (int)Math.Round(v * 100);
      string ico = VolGlyph(pct, m);
      E<TextBlock>("EVolIco").Text = ico; E<TextBlock>("EVolTxt").Text = m ? "muet" : pct + " %";
      if (changed) {
        if (m) ShowToast(ico, "", "Muet", Rgb("#8E8E93"), 0, 1400);
        else ShowToast(ico, "", pct.ToString(), Colors.White, v, 1400);
        Refresh();
      }
    }
    void CheckFullscreen() {
      if (!Bool(G(cfg, "hideFullscreen")) || hwnd == IntPtr.Zero) return;
      int sw = (int)Math.Round(SystemParameters.PrimaryScreenWidth), sh = (int)Math.Round(SystemParameters.PrimaryScreenHeight);
      // GetWindowRect renvoie des pixels physiques : on compare avec la taille physique de l'écran
      PresentationSource ps = PresentationSource.FromVisual(win);
      if (ps != null && ps.CompositionTarget != null) {
        Matrix mx = ps.CompositionTarget.TransformToDevice;
        sw = (int)Math.Round(SystemParameters.PrimaryScreenWidth * mx.M11); sh = (int)Math.Round(SystemParameters.PrimaryScreenHeight * mx.M22);
      }
      bool fs = Win.ForegroundIsFullscreen(sw, sh, hwnd);
      if (fs == hiddenFs) return;
      hiddenFs = fs;
      Anim(root, UIElement.OpacityProperty, fs ? 0 : 1, 220, 0, null);
      root.IsHitTestVisible = !fs;
    }

    // ---------------- musique ----------------
    static string AppName(string id) {
      if (string.IsNullOrEmpty(id)) return "";
      string l = id.ToLowerInvariant();
      if (l.Contains("spotify")) return "Spotify";
      if (l.Contains("chrome")) return "Chrome";
      if (l.Contains("msedge")) return "Edge";
      if (l.Contains("firefox")) return "Firefox";
      if (l.Contains("deezer")) return "Deezer";
      if (l.Contains("zune") || l.Contains("media")) return "Lecteur multimédia";
      string[] parts = id.Split('\\', '!');
      return parts[parts.Length - 1].Replace(".exe", "");
    }
    static string Fmt(double sec) {
      if (sec < 0) sec = 0;
      TimeSpan t = TimeSpan.FromSeconds(Math.Floor(sec));
      return t.TotalHours >= 1 ? t.ToString(@"h\:mm\:ss") : string.Format("{0}:{1:00}", (int)Math.Floor(t.TotalMinutes), t.Seconds);
    }
    void UpdateMedia() {
      Hashtable md = Media();
      if (md != null && Str(G(md, "key")) != trackKey) {
        trackKey = Str(G(md, "key"));
        ImageSource art = G(md, "art") as ImageSource;
        SetArt("CArtBox", art); SetArt("EArtBox", art);
        foreach (string ab in new[] { "CArtBox", "EArtBox" }) {   // nouvelle pochette : fondu + léger zoom
          FrameworkElement fe = E<FrameworkElement>(ab);
          ScaleTransform zs = fe.RenderTransform as ScaleTransform;
          if (zs == null) { zs = new ScaleTransform(1, 1); fe.RenderTransform = zs; fe.RenderTransformOrigin = new Point(0.5, 0.5); }
          zs.ScaleX = 0.9; zs.ScaleY = 0.9; fe.Opacity = 0;
          Anim(zs, ScaleTransform.ScaleXProperty, 1, 420, 0, Back(0.3)); Anim(zs, ScaleTransform.ScaleYProperty, 1, 420, 0, Back(0.3));
          Anim(fe, UIElement.OpacityProperty, 1, 300, 0, null);
        }
        Vis("EArtIco", art == null);
        string title = Str(G(md, "title")), artist = Str(G(md, "artist")), app = AppName(Str(G(md, "app")));
        E<TextBlock>("ETitle").Text = title; E<TextBlock>("EArtist").Text = artist; E<TextBlock>("EApp").Text = app;
        SetMarquee(string.IsNullOrEmpty(artist) ? title : title + " · " + artist);
        Safe("fond", delegate { SetAmbArt(art); });
        if (G(md, "color") is Color) { accent = (Color)G(md, "color"); AnimColor(accentBrush, SolidColorBrush.ColorProperty, accent, 600); }
        bool sameSong = (title + "|" + artist) == lastSong;
        lastSong = title + "|" + artist;
        if (!firstTrack && !sameSong && Bool(G(sync, "playing")) && !expandedOn) ShowPeek(art, "", "#FFFFFF", "#1C1C1E", app, title, artist, 3000, false);
        firstTrack = false;
      }
      if (md == null && trackKey != "none") {   // rien en lecture : de quoi lancer Spotify
        trackKey = "none";
        SetArt("EArtBox", null); Vis("EArtIco", true);
        E<TextBlock>("ETitle").Text = "Rien en lecture";
        E<TextBlock>("EArtist").Text = "Appuie sur lecture pour lancer Spotify";
        E<TextBlock>("EApp").Text = "Spotify";
        accent = accentDefault; AnimColor(accentBrush, SolidColorBrush.ColorProperty, accent, 600);
      }
      Vis("BPrev", md != null); Vis("BNext", md != null);
      bool pl = Bool(G(sync, "playing"));
      Vis("BPauseShape", pl); Vis("BPlayShape", !pl);
      E<TextBlock>("BPlayIco").Text = pl ? "" : "";
      Hashtable tl = G(sync, "timeline") as Hashtable;
      if (md != null && tl != null && Num(G(tl, "end")) > 1) {
        double end = Num(G(tl, "end")), cur = Num(G(tl, "pos"));
        if (Bool(G(sync, "playing")) && G(tl, "at") is DateTime) cur += (DateTime.Now - (DateTime)G(tl, "at")).TotalSeconds;
        cur = Math.Min(cur, end);
        Vis("EProg", true);
        progressFrac = Math.Max(0, Math.Min(1, cur / end));
        bool showWave = expandedOn && page == "PgMusic";
        if (showWave && !waveTimer.IsEnabled) { lastWave = DateTime.Now; waveTimer.Start(); }
        else if (!showWave && waveTimer.IsEnabled) waveTimer.Stop();
        E<TextBlock>("EPos").Text = Fmt(cur);
        E<TextBlock>("ELeft").Text = "-" + Fmt(end - cur);
      } else Vis("EProg", false);
    }
    void SeekClick(object o, MouseButtonEventArgs ev) {
      Hashtable tl = G(sync, "timeline") as Hashtable;
      FrameworkElement hit = E<FrameworkElement>("EBarHit");
      if (tl == null || Num(G(tl, "end")) <= 1 || hit.ActualWidth <= 0) return;
      double frac = Math.Max(0, Math.Min(0.995, ev.GetPosition(hit).X / hit.ActualWidth));
      double end = Num(G(tl, "end"));
      int ms = (int)(frac * end * 1000);
      Hashtable md = Media();
      bool spotify = md != null && AppName(Str(G(md, "app"))) == "Spotify";
      Cmd((spotify ? "seekspotify:" : "seek:") + ms);
      Hashtable n = new Hashtable(); n["pos"] = frac * end; n["end"] = end; n["at"] = DateTime.Now;
      sync["timeline"] = n;
      ev.Handled = true;
    }

    void DrawWave() {
      FrameworkElement host = E<FrameworkElement>("EBarHit");
      double W0 = host.ActualWidth, mid = host.ActualHeight / 2;
      if (W0 <= 0) return;
      DateTime now = DateTime.Now;
      double dt = Math.Min(0.1, (now - lastWave).TotalSeconds); lastWave = now;
      bool playing = Playing();
      double wantAmp = playing ? 1.2 + level * 3.6 : 0;   // la vague respire avec le son
      waveAmp += (wantAmp - waveAmp) * Math.Min(1, dt * 8);   // la vague s'aplatit en douceur à la pause
      if (playing) wavePhase += dt * 2 * Math.PI * 0.9;
      double px = Math.Round(W0 * progressFrac, 1);
      StreamGeometry g = new StreamGeometry();
      using (StreamGeometryContext ctx = g.Open()) {
        ctx.BeginFigure(new Point(1.5, mid + waveAmp * Math.Sin(wavePhase)), false, false);
        for (double x = 3; x <= px; x += 2) {
          // l'amplitude se réduit près de la tête de lecture pour rejoindre le trait
          double fade = Math.Min(1, (px - x) / 10.0);
          ctx.LineTo(new Point(x, mid + waveAmp * fade * Math.Sin(x * 2 * Math.PI / 18.0 - wavePhase)), true, true);
        }
      }
      g.Freeze();
      E<Path>("EWave").Data = g;
      StreamGeometry r = new StreamGeometry();
      using (StreamGeometryContext ctx = r.Open()) {
        if (px + 6 < W0 - 1.5) { ctx.BeginFigure(new Point(px + 6, mid), false, false); ctx.LineTo(new Point(W0 - 1.5, mid), true, false); }
      }
      r.Freeze();
      E<Path>("ERest").Data = r;
      E<FrameworkElement>("EKnob").Margin = new Thickness(Math.Max(0, px - 2), 0, 0, 0);
      if (!expandedOn || page != "PgMusic") waveTimer.Stop();
    }

    // ---------------- minuteur ----------------
    void StartTimer(int min, string label) { timerEnd = DateTime.Now.AddMinutes(min); timerTotal = min * 60; timerLabel = label; UpdateTimer(); Refresh(); }
    void UpdateTimer() {
      if (!timerEnd.HasValue) {
        E<TextBlock>("CTimer").Text = "";
        E<Path>("TRing").Data = null; E<TextBlock>("TRingTxt").Text = "25:00";
        E<TextBlock>("TLabel").Text = "Minuteur"; E<TextBlock>("TSub").Text = "Prêt quand tu l'es";
        Vis("BTStop", false); Vis("BT25", true); Vis("BT5", true);
        return;
      }
      TimeSpan left = timerEnd.Value - DateTime.Now;
      if (left.TotalSeconds <= 0) {
        string lbl = timerLabel; timerEnd = null;
        System.Media.SystemSounds.Asterisk.Play();
        ShowPeek(null, "", "#FFFFFF", "#FF9F0A", "Minuteur", lbl + " terminé", lbl == "Focus" ? "Prends une pause de 5 min" : "On reprend ?", 6000, false);
        UpdateTimer(); return;
      }
      string txt = string.Format("{0:00}:{1:00}", (int)Math.Floor(left.TotalMinutes), left.Seconds);
      double frac = left.TotalSeconds / timerTotal;
      E<TextBlock>("CTimer").Text = txt; E<TextBlock>("TRingTxt").Text = txt;
      E<Path>("TRing").Data = Fx.Arc(64, 5, frac);
      E<TextBlock>("TLabel").Text = timerLabel; E<TextBlock>("TSub").Text = "Fin à " + timerEnd.Value.ToString("HH:mm");
      E<TextBlock>("RingTxt").Text = ((int)Math.Ceiling(left.TotalMinutes)).ToString();
      E<Path>("Ring").Data = Fx.Arc(22, 2.5, frac);
      Vis("BTStop", true); Vis("BT25", false); Vis("BT5", false);
    }

    // ---------------- Nox ----------------
    void UpdateNox() {
      Hashtable n = G(sync, "nox") as Hashtable;
      string state, text, act = "";
      if (n == null) { state = "off"; text = "connexion…"; }
      else if (!Bool(G(n, "ok"))) { state = Str(G(n, "state")) == "nourl" ? "off" : "down"; text = Str(G(n, "error")); }
      else {
        state = Bool(G(n, "busy")) ? "busy" : "online";
        text = Bool(G(n, "busy")) ? "au travail" : "en ligne";
        act = Str(G(n, "activity"));
      }
      noxState = state;
      Color dot = state == "online" ? Rgb("#30D158") : state == "busy" ? accentDefault : state == "down" ? Rgb("#FF453A") : Rgb("#8E8E93");
      Color glow = state == "online" ? Rgb("#9BF0B0") : state == "down" ? Rgb("#FF8A80") : Rgb("#B9B4FF");
      E<Ellipse>("NDot").Fill = Br(dot);
      E<TextBlock>("NState").Text = text;
      E<TextBlock>("NAct").Text = act;
      Vis("NAct", act.Length > 0);
      // masque bordé de rouge en cas d'erreur, estompé quand Nox est introuvable (charte de Nox)
      // petits yeux de la pilule : crème avec une lueur douce, rouges si Nox est injoignable
      foreach (string mk in new[] { "PkMask", "NMask" }) {
        Border mb = E<Border>(mk);
        mb.BorderThickness = new Thickness(state == "down" ? (mk == "NMask" ? 2.5 : 1.2) : 0);
      }
      E<UIElement>("CEyes").Opacity = state == "off" ? 0.55 : 1;
      if (n == null || !Bool(G(n, "ok"))) { Vis("NConfirm", false); return; }
      Safe("agenda", delegate { UpdateAgenda(G(n, "week") as IEnumerable); });
      Safe("maison", delegate { UpdateHouse(G(n, "house") as Hashtable); });
      Hashtable wd = G(n, "widget") as Hashtable;
      if (wd != null) {
        Hashtable me = G(wd, "meteo") as Hashtable;
        E<TextBlock>("TMeteo").Text = me == null ? "" : Str(G(me, "temp")) + "°  " + Str(G(me, "libelle")) + "  ·  " + Str(G(me, "min")) + "° / " + Str(G(me, "max")) + "°";
        Vis("TMeteo", me != null);
        IEnumerable ag = G(wd, "agenda") as IEnumerable;
        List<string> items = new List<string>();
        if (ag != null && !(ag is string)) foreach (object o in ag) if (o != null && items.Count < 2) items.Add(o.ToString());
        agendaItems = items;
        E<TextBlock>("TAgenda1").Text = items.Count > 0 ? items[0] : "";
        E<TextBlock>("TAgenda2").Text = items.Count > 1 ? items[1] : "";
        Vis("TAgenda1", items.Count > 0); Vis("TAgenda2", items.Count > 1);
      }

      // dernier message de Nox
      Hashtable msg = G(n, "last") as Hashtable;
      if (msg != null) {
        string id = Str(G(msg, "id")), txt = Str(G(msg, "texte"));
        E<TextBlock>("NLast").Text = txt;
        E<TextBlock>("NLastTime").Text = NiceTime(Str(G(msg, "heure")));
        Vis("NLastBox", txt.Length > 0);
        SetNoxButtons(id, G(msg, "boutons") as IEnumerable);
        if (id != noxMsgId) {
          bool first = !noxSeen;
          noxMsgId = id;
          if (!first && !(expandedOn && page == "PgNox")) noxUnread = true;
          if (!first && !(expandedOn && page == "PgNox")) {
            string flat = txt.Replace("\r", " ").Replace("\n", " ").Replace("**", "");
            string t1 = flat.Length > 60 ? flat.Substring(0, 60).TrimEnd() + "…" : flat;
            string t2 = flat.Length > 60 ? (flat.Length > 140 ? flat.Substring(60, 80).Trim() + "…" : flat.Substring(60).Trim()) : "";
            ShowPeek(null, "", "#FFFFFF", "#849C8B", "Nox", t1, t2, 6000, false);
          }
        }
      }
      noxSeen = true;
      // feu vert en attente : on peut répondre depuis la pilule
      Hashtable conf = G(n, "confirm") as Hashtable;
      Vis("NConfirm", conf != null);
      if (conf != null) {
        string desc = Str(G(conf, "description"));
        E<TextBlock>("NConfText").Text = desc;
        string jt = Str(G(conf, "jeton"));
        if (Str(G(sync, "confShown")) != jt) {
          sync["confShown"] = jt;
          ShowPeek(null, "", "#FFFFFF", "#FF9F0A", "Nox · feu vert", desc, null, 15000, true);
        }
      }
      Vis("NBusy", Bool(G(n, "occupe")));
    }
    void SendNox() {
      TextBox input = E<TextBox>("NInput");
      string t = input.Text.Trim();
      if (t.Length == 0) return;
      NoxCmd("send:" + t);
      input.Text = "";
      E<TextBlock>("NLast").Text = "Envoyé : " + t;
      Vis("NLastBox", true);
      StopTyping();
    }
    // prochain rendez-vous d'aujourd'hui (texte « 14:30 · Dentiste » renvoyé par Nox) dans les 15 min
    bool NextEvent(DateTime now, out string title, out double minutes) {
      title = ""; minutes = 0;
      foreach (string it in agendaItems) {
        System.Text.RegularExpressions.Match m = System.Text.RegularExpressions.Regex.Match(it, @"^(\d{1,2}):(\d{2}) · (.+)$");
        if (!m.Success) continue;
        DateTime t = now.Date.AddHours(int.Parse(m.Groups[1].Value)).AddMinutes(int.Parse(m.Groups[2].Value));
        double mins = (t - now).TotalMinutes;
        if (mins > 15 || mins < -5) continue;
        title = m.Groups[3].Value; minutes = Math.Max(0, mins);
        string k15 = it + "|15", k0 = it + "|0";
        if (mins > 0.5 && !evPeeked.Contains(k15)) {
          evPeeked.Add(k15);
          ShowPeek(null, "\uE787", "#FFFFFF", "#0A84FF", "Agenda", title, "dans " + (int)Math.Ceiling(mins) + " min · à " + t.ToString("HH:mm"), 6000, false);
        } else if (mins <= 0.5 && !evPeeked.Contains(k0)) {
          evPeeked.Add(k0);
          ShowPeek(null, "\uE787", "#FFFFFF", "#0A84FF", "Agenda", title, "C'est maintenant", 6000, false);
        }
        return true;
      }
      return false;
    }

    void SetNoxButtons(string id, IEnumerable btns) {
      List<object[]> list = new List<object[]>();
      if (btns != null && !(btns is string))
        foreach (object o in btns) {
          Hashtable b = U(o) as Hashtable;
          if (b != null && list.Count < 3) list.Add(new object[] { Str(G(b, "l")), Str(G(b, "a")) });
        }
      string key = id + "|" + list.Count;
      foreach (object[] b in list) key += "|" + b[0];
      if (key == btnKey) return;
      btnKey = key;
      Panel row = E<Panel>("NBtns");
      row.Children.Clear();
      foreach (object[] b in list) {
        string action = (string)b[1];
        Button bt = new Button();
        bt.Style = (Style)win.FindResource("Chip");
        bt.Margin = new Thickness(0, 0, 6, 0);
        TextBlock tb = new TextBlock(); tb.Text = (string)b[0]; tb.FontSize = 12;
        bt.Content = tb;
        bt.Click += delegate { NoxCmd("bouton:" + id + "\u001f" + action); row.Children.Clear(); btnKey = ""; };
        row.Children.Add(bt);
      }
      Vis("NBtns", list.Count > 0);
    }

    static readonly string[] DropTypes = { ".pdf", ".jpg", ".jpeg", ".png", ".webp", ".gif" };
    void OnDrag(object o, DragEventArgs e) {
      if (e.Data.GetDataPresent(DataFormats.FileDrop)) {
        e.Effects = DragDropEffects.Copy;
        lastDrag = DateTime.Now;
        if (!dragging) {
          dragging = true;
          ShowPeek(null, "\uE898", "#FFFFFF", "#849C8B", "Nox", "Dépose le fichier ici", "Nox te proposera où le ranger", 60000, false);
          Refresh();
        }
      } else e.Effects = DragDropEffects.None;
      e.Handled = true;
    }
    void OnDrop(object o, DragEventArgs e) {
      dragging = false;
      e.Handled = true;
      string[] files = e.Data.GetData(DataFormats.FileDrop) as string[];
      if (files == null || files.Length == 0) return;
      string f = files[0], ext = System.IO.Path.GetExtension(f).ToLowerInvariant(), name = System.IO.Path.GetFileName(f);
      Hashtable n = G(sync, "nox") as Hashtable;
      if (Array.IndexOf(DropTypes, ext) < 0)
        ShowPeek(null, "\uE783", "#FFFFFF", "#FF453A", "Nox", "Format non pris en charge", "PDF ou photo seulement", 4000, false);
      else if (new System.IO.FileInfo(f).Length > 5000000)
        ShowPeek(null, "\uE783", "#FFFFFF", "#FF453A", "Nox", "Fichier trop lourd", "5 Mo maximum", 4000, false);
      else if (n == null || !Bool(G(n, "ok")))
        ShowPeek(null, "\uE783", "#FFFFFF", "#FF453A", "Nox", "Nox est injoignable", "Vérifie que Tailscale est lancé", 4000, false);
      else {
        NoxCmd("file:" + f);
        ShowPeek(null, "\uE898", "#FFFFFF", "#30D158", "Nox", "Envoyé à Nox", name, 4000, false);
        if (files.Length > 1) Log("glisser-déposer : seul le premier fichier est envoyé");
      }
      Refresh();
    }

    // ---------------- Maison ----------------
    string houseKey = ""; int houseRev = 0;
    readonly string[][] Routines = { new[] { "je_pars", "Je pars", "\uE7E8" }, new[] { "je_rentre", "Je rentre", "\uE80F" },
                                     new[] { "bonne_nuit", "Bonne nuit", "\uE708" }, new[] { "tout_eteindre", "Tout éteindre", "\uEA80" } };
    Border Tile(string icon, string label, string sub, bool on, MouseButtonEventHandler click) {
      StackPanel sp = new StackPanel(); sp.Orientation = Orientation.Horizontal;
      TextBlock ic = new TextBlock(); ic.Text = icon; ic.FontFamily = new FontFamily("Segoe Fluent Icons"); ic.FontSize = 14; ic.VerticalAlignment = VerticalAlignment.Center;
      ic.Foreground = on ? Br("#FFD60A") : Br("#C7C7CC");
      StackPanel tx = new StackPanel(); tx.Margin = new Thickness(8, 0, 0, 0);
      TextBlock a = new TextBlock(); a.Text = label; a.FontSize = 12.5; a.FontWeight = FontWeights.SemiBold; a.TextTrimming = TextTrimming.CharacterEllipsis;
      tx.Children.Add(a);
      if (!string.IsNullOrEmpty(sub)) { TextBlock b = new TextBlock(); b.Text = sub; b.FontSize = 11; b.Foreground = Br("#AEAEB2"); tx.Children.Add(b); }
      sp.Children.Add(ic); sp.Children.Add(tx);
      Border t = new Border(); t.Child = sp; t.CornerRadius = new CornerRadius(12); t.Padding = new Thickness(10, 7, 8, 7); t.Margin = new Thickness(0, 0, 6, 6);
      t.Background = on ? Br("#30FFD60A") : Br("#16FFFFFF"); t.Cursor = Cursors.Hand;
      t.MouseLeftButtonUp += click;
      return t;
    }
    void UpdateHouse(Hashtable h) {
      Panel routines = E<Panel>("HRoutines");
      if (routines.Children.Count == 0) {
        foreach (string[] r in Routines) {
          string nom = r[0], lib = r[1];
          Border chip = new Border(); chip.CornerRadius = new CornerRadius(13); chip.Padding = new Thickness(11, 5, 11, 5); chip.Margin = new Thickness(0, 0, 6, 0);
          chip.Background = Br("#1AFFFFFF"); chip.Cursor = Cursors.Hand;
          StackPanel sp = new StackPanel(); sp.Orientation = Orientation.Horizontal;
          TextBlock ic = new TextBlock(); ic.Text = r[2]; ic.FontFamily = new FontFamily("Segoe Fluent Icons"); ic.FontSize = 11; ic.VerticalAlignment = VerticalAlignment.Center;
          TextBlock t = new TextBlock(); t.Text = lib; t.FontSize = 12; t.Margin = new Thickness(6, 0, 0, 0);
          sp.Children.Add(ic); sp.Children.Add(t); chip.Child = sp;
          chip.MouseLeftButtonUp += delegate {
            NoxCmd("house:routine:" + nom);
            ShowToast("\uE80F", lib + " : c'est parti", "", Rgb("#FFD60A"), -1, 1800); Refresh();
          };
          routines.Children.Add(chip);
        }
      }
      if (h == null) return;
      IEnumerable rooms = G(h, "pieces") as IEnumerable;
      List<Hashtable> list = new List<Hashtable>();
      string key = Str(G(h, "allumees")) + "/" + Str(G(h, "total")) + "|";
      if (rooms != null && !(rooms is string)) foreach (object o in rooms) { Hashtable p = U(o) as Hashtable; if (p != null) { list.Add(p); key += Str(G(p, "nom")) + Bool(G(p, "allumee")) + Str(G(p, "lum")) + ";"; } }
      foreach (string g in new List<string>(houseOverride.Keys)) if (DateTime.Now >= (DateTime)houseOverride[g][2]) houseOverride.Remove(g);
      key += "|" + houseOverride.Count;
      if (roomDragging) return;   // pas de redessin pendant qu'on règle une pièce
      E<TextBlock>("HSummary").Text = Str(G(h, "total")).Length > 0 ? Str(G(h, "allumees")) + " / " + Str(G(h, "total")) + " lampes allumées" : "";
      if (key == houseKey) return;
      houseKey = key; houseRev++;
      Panel grid = E<Panel>("HRooms"); grid.Children.Clear();
      foreach (Hashtable p in list) {
        if (grid.Children.Count == 6) break;
        string groupe = Str(G(p, "groupe")), nom = Str(G(p, "nom"));
        bool on = Bool(G(p, "allumee"));
        int lum; if (!int.TryParse(Str(G(p, "lum")), out lum)) lum = on ? 100 : 0;
        object[] ov;   // changement fait à l'instant : on garde ce qu'on vient de régler le temps que Hue suive
        if (houseOverride.TryGetValue(groupe, out ov) && DateTime.Now < (DateTime)ov[2]) { on = (bool)ov[0]; lum = (int)ov[1]; }
        grid.Children.Add(RoomTile(groupe, nom, on, lum));
      }
      Vis("HEmpty", list.Count == 0);
      if (list.Count == 0) E<TextBlock>("HEmpty").Text = "Pas de lumières trouvées (Hue indisponible ?)";
    }

    // tuile de pièce façon Centre de contrôle : toucher = allumer / éteindre, glisser = luminosité
    Dictionary<string, object[]> houseOverride = new Dictionary<string, object[]>();
    bool roomDragging;
    FrameworkElement RoomTile(string groupe, string nom, bool on0, int lum0) {
      bool on = on0; int lum = Math.Max(1, Math.Min(100, lum0));
      Grid tile = new Grid(); tile.Margin = new Thickness(0, 0, 6, 6); tile.Height = 46; tile.Cursor = Cursors.SizeWE;
      tile.Background = Brushes.Transparent; tile.ClipToBounds = true;
      Border back = new Border(); back.CornerRadius = new CornerRadius(12); back.Background = Br("#16FFFFFF");
      Border fill = new Border(); fill.CornerRadius = new CornerRadius(12); fill.Background = Br("#38FFD60A");
      ScaleTransform fs = new ScaleTransform(on ? lum / 100.0 : 0, 1); fill.RenderTransform = fs; fill.RenderTransformOrigin = new Point(0, 0.5);
      StackPanel sp = new StackPanel(); sp.Orientation = Orientation.Horizontal; sp.Margin = new Thickness(10, 0, 8, 0); sp.VerticalAlignment = VerticalAlignment.Center;
      TextBlock ic = new TextBlock(); ic.FontFamily = new FontFamily("Segoe Fluent Icons"); ic.FontSize = 14; ic.VerticalAlignment = VerticalAlignment.Center;
      StackPanel tx = new StackPanel(); tx.Margin = new Thickness(8, 0, 0, 0);
      TextBlock a = new TextBlock(); a.Text = nom; a.FontSize = 12.5; a.FontWeight = FontWeights.SemiBold; a.TextTrimming = TextTrimming.CharacterEllipsis;
      TextBlock b = new TextBlock(); b.FontSize = 11; b.Foreground = Br("#AEAEB2");
      tx.Children.Add(a); tx.Children.Add(b); sp.Children.Add(ic); sp.Children.Add(tx);
      tile.Children.Add(back); tile.Children.Add(fill); tile.Children.Add(sp);
      Action paint = delegate {
        ic.Text = on ? "\uEA80" : "\uE781"; ic.Foreground = on ? Br("#FFD60A") : Br("#C7C7CC");
        b.Text = on ? lum + " %" : "éteinte";
        fs.ScaleX = on ? lum / 100.0 : 0;
      };
      paint();
      double startX = 0; bool moved = false;
      tile.MouseLeftButtonDown += delegate(object o, MouseButtonEventArgs ev) { startX = ev.GetPosition(tile).X; moved = false; tile.CaptureMouse(); ev.Handled = true; };
      tile.MouseMove += delegate(object o, MouseEventArgs ev) {
        if (!tile.IsMouseCaptured) return;
        double xx = ev.GetPosition(tile).X;
        if (!moved && Math.Abs(xx - startX) < 5) return;
        moved = true; roomDragging = true;
        lum = (int)Math.Round(Math.Max(1, Math.Min(100, xx / Math.Max(1, tile.ActualWidth) * 100)));
        on = true; paint();
      };
      tile.MouseLeftButtonUp += delegate(object o, MouseButtonEventArgs ev) {
        if (!tile.IsMouseCaptured) return;
        tile.ReleaseMouseCapture(); ev.Handled = true;
        if (!moved) { on = !on; paint(); SendLight(groupe, on, on ? lum : 0); }
        else SendLight(groupe, true, lum);
        houseOverride[groupe] = new object[] { on, lum, DateTime.Now.AddSeconds(6) };
        roomDragging = false;
      };
      return tile;
    }
    // envoi direct à l'appli de Nox (sans attendre le fil de fond) : la lampe réagit tout de suite
    readonly JavaScriptSerializer json = new JavaScriptSerializer();
    void SendLight(string groupe, bool on, int lum) {
      string url = Str(G(sync, "noxUrl"));
      if (url.Length == 0) { NoxCmd("house:piece:" + groupe + ":" + (on ? "1" : "0")); return; }
      Dictionary<string, object> body = new Dictionary<string, object>();
      body["action"] = "piece"; body["groupe"] = groupe; body["allumer"] = on; body["leger"] = true;
      if (on) body["luminosite"] = lum;
      string data = json.Serialize(body);
      Task.Run(new Action(delegate {
        try {
          HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url.TrimEnd('/') + "/api/lumiere");
          req.Method = "POST"; req.ContentType = "application/json"; req.Headers["X-Jarvis"] = "1"; req.Timeout = 8000; req.UserAgent = "MathisDynamicIsland/1.0";
          byte[] bb = Encoding.UTF8.GetBytes(data);
          using (System.IO.Stream s = req.GetRequestStream()) s.Write(bb, 0, bb.Length);
          using (WebResponse r = req.GetResponse()) { }
          sync["houseRefresh"] = true;   // relire l'état réel juste après
        } catch (Exception ex) { win.Dispatcher.BeginInvoke(new Action(delegate { Log("lumière : " + ex.Message); ShowToast("\uE781", "La lumière ne répond pas", "", Rgb("#FF453A"), -1, 2200); Refresh(); })); }
      }));
    }

    // ---------------- Raccourcis Windows ----------------
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, int flags, IntPtr extra);
    [DllImport("user32.dll")] static extern bool LockWorkStation();
    static void Keys(params byte[] vks) {
      foreach (byte k in vks) keybd_event(k, 0, 0, IntPtr.Zero);
      for (int i = vks.Length - 1; i >= 0; i--) keybd_event(vks[i], 0, 2, IntPtr.Zero);
    }
    void BuildTools() {
      Panel g = E<Panel>("PgTools");
      if (g.Children.Count > 0) return;
      object[][] tools = {
        new object[] { "\uE924", "Capture", new Action(delegate { Run("ms-screenclip:"); }) },
        new object[] { "\uE8EF", "Calculatrice", new Action(delegate { Run("calc.exe"); }) },
        new object[] { "\uE7F4", "Bureau", new Action(delegate { Keys(0x5B, 0x44); }) },
        new object[] { "\uEC50", "Explorateur", new Action(delegate { Run("explorer.exe"); }) },
        new object[] { "\uE74F", "Couper le son", new Action(delegate { Keys(0xAD); }) },
        new object[] { "\uE72E", "Verrouiller", new Action(delegate { LockWorkStation(); }) },
        new object[] { "\uE9D9", "Gestionnaire", new Action(delegate { Run("taskmgr.exe"); }) },
        new object[] { "\uE896", "Téléchargements", new Action(delegate { Run(System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads")); }) } };
      foreach (object[] t in tools) {
        Action act = (Action)t[2];
        StackPanel sp = new StackPanel(); sp.HorizontalAlignment = HorizontalAlignment.Center;
        Border ic = new Border(); ic.Width = 40; ic.Height = 40; ic.CornerRadius = new CornerRadius(12); ic.Background = Br("#1FFFFFFF");
        TextBlock gl = new TextBlock(); gl.Text = (string)t[0]; gl.FontFamily = new FontFamily("Segoe Fluent Icons"); gl.FontSize = 16;
        gl.HorizontalAlignment = HorizontalAlignment.Center; gl.VerticalAlignment = VerticalAlignment.Center; ic.Child = gl;
        TextBlock lb = new TextBlock(); lb.Text = (string)t[1]; lb.FontSize = 11; lb.Foreground = Br("#C7C7CC"); lb.HorizontalAlignment = HorizontalAlignment.Center; lb.Margin = new Thickness(0, 4, 0, 8);
        sp.Children.Add(ic); sp.Children.Add(lb);
        Border cell = new Border(); cell.Child = sp; cell.Background = Brushes.Transparent; cell.Cursor = Cursors.Hand;
        cell.MouseEnter += delegate { ic.Background = Br("#33FFFFFF"); };
        cell.MouseLeave += delegate { ic.Background = Br("#1FFFFFFF"); };
        cell.MouseLeftButtonUp += delegate { try { act(); } catch (Exception ex) { Log("raccourci : " + ex.Message); } };
        g.Children.Add(cell);
      }
    }
    void Run(string what) { System.Diagnostics.Process.Start(what); }

    // ---------------- Agenda ----------------
    List<Hashtable> week = new List<Hashtable>();
    string weekKey = "", selDate = "";
    int agendaRev = 0;
    void UpdateAgenda(IEnumerable data) {
      if (data == null || data is string) return;
      List<Hashtable> days = new List<Hashtable>();
      string key = "";
      foreach (object o in data) {
        Hashtable d = U(o) as Hashtable; if (d == null) continue;
        days.Add(d);
        key += Str(G(d, "date")) + ":";
        IEnumerable ev = G(d, "evts") as IEnumerable;
        if (ev != null && !(ev is string)) foreach (object e in ev) { Hashtable h = U(e) as Hashtable; if (h != null) key += Str(G(h, "debut")) + Str(G(h, "titre")) + ";"; }
      }
      string today = DateTime.Now.ToString("yyyy-MM-dd");
      if (key == weekKey && (selDate.Length == 0 || string.Compare(selDate, today) >= 0)) return;
      weekKey = key; week = days;
      if (selDate.Length == 0 || string.Compare(selDate, today) < 0) selDate = today;
      RenderAgenda();
    }
    static DateTime ParseDay(string s) { DateTime d; return DateTime.TryParseExact(s, "yyyy-MM-dd", null, System.Globalization.DateTimeStyles.None, out d) ? d : DateTime.Today; }
    List<Hashtable> EventsOf(Hashtable day) {
      List<Hashtable> l = new List<Hashtable>();
      IEnumerable ev = G(day, "evts") as IEnumerable;
      if (ev != null && !(ev is string)) foreach (object e in ev) { Hashtable h = U(e) as Hashtable; if (h != null) l.Add(h); }
      return l;
    }
    void RenderAgenda() {
      agendaRev++;
      Panel daysRow = E<Panel>("ADays"), list = E<Panel>("AList");
      daysRow.Children.Clear(); list.Children.Clear();
      string today = DateTime.Now.ToString("yyyy-MM-dd");
      Hashtable sel = null;
      foreach (Hashtable d in week) {
        string ds = Str(G(d, "date"));
        DateTime dt = ParseDay(ds);
        bool isSel = ds == selDate, isToday = ds == today;
        if (isSel) sel = d;
        string lettre = dt.ToString("ddd", fr).Replace(".", "");
        lettre = char.ToUpper(lettre[0]) + lettre.Substring(1);
        StackPanel sp = new StackPanel(); sp.HorizontalAlignment = HorizontalAlignment.Center;
        TextBlock t1 = new TextBlock(); t1.Text = lettre; t1.FontSize = 11; t1.Foreground = Br("#8E8E93"); t1.HorizontalAlignment = HorizontalAlignment.Center;
        Border num = new Border(); num.Width = 26; num.Height = 26; num.CornerRadius = new CornerRadius(13); num.Margin = new Thickness(0, 3, 0, 2);
        num.Background = isToday ? Br("#FF453A") : (isSel ? Br("#33FFFFFF") : Brushes.Transparent);
        TextBlock t2 = new TextBlock(); t2.Text = dt.Day.ToString(); t2.FontSize = 14; t2.FontWeight = FontWeights.SemiBold;
        t2.HorizontalAlignment = HorizontalAlignment.Center; t2.VerticalAlignment = VerticalAlignment.Center;
        num.Child = t2;
        Ellipse dot = new Ellipse(); dot.Width = 4; dot.Height = 4; dot.HorizontalAlignment = HorizontalAlignment.Center;
        dot.Fill = EventsOf(d).Count > 0 ? (Brush)Br("#A1A1A6") : Brushes.Transparent;
        sp.Children.Add(t1); sp.Children.Add(num); sp.Children.Add(dot);
        if (isSel && !isToday) num.BorderBrush = Br("#66FFFFFF");
        Border cell = new Border(); cell.Background = Brushes.Transparent; cell.Cursor = Cursors.Hand; cell.Child = sp;
        cell.CornerRadius = new CornerRadius(10); cell.Padding = new Thickness(0, 2, 0, 2);
        if (isSel) cell.Background = Br("#14FFFFFF");
        string target = ds;
        cell.MouseLeftButtonUp += delegate { selDate = target; RenderAgenda(); Refresh(); };
        daysRow.Children.Add(cell);
      }
      DateTime selDt = ParseDay(selDate);
      string m = selDt.ToString("dddd d MMMM", fr);
      E<TextBlock>("AMonth").Text = selDate == today ? "Aujourd'hui · " + m : char.ToUpper(m[0]) + m.Substring(1);
      List<Hashtable> evs = sel == null ? new List<Hashtable>() : EventsOf(sel);
      if (evs.Count == 0) {
        TextBlock empty = new TextBlock(); empty.Text = "Rien de prévu. Je garde un œil ouvert."; empty.FontSize = 12.5; empty.Foreground = Br("#8E8E93"); empty.Margin = new Thickness(2, 2, 0, 2);
        list.Children.Add(empty);
      }
      int shown = 0;
      foreach (Hashtable ev in evs) {
        if (shown == 3) {
          TextBlock more = new TextBlock(); more.Text = "+ " + (evs.Count - 3) + " autre" + (evs.Count - 3 > 1 ? "s" : ""); more.FontSize = 12; more.Foreground = Br("#8E8E93"); more.Margin = new Thickness(13, 2, 0, 0);
          list.Children.Add(more); break;
        }
        shown++;
        string titre = Str(G(ev, "titre")), debut = Str(G(ev, "debut")), fin = Str(G(ev, "fin")), lieu = Str(G(ev, "lieu")), lien = Str(G(ev, "lien"));
        bool journee = Bool(G(ev, "journee"));
        DockPanel row = new DockPanel(); row.Margin = new Thickness(0, 0, 0, 6); row.Background = Brushes.Transparent;
        Border bar = new Border(); bar.Width = 3; bar.CornerRadius = new CornerRadius(1.5); bar.Background = Br(EventColor); bar.Margin = new Thickness(0, 1, 10, 1);
        DockPanel.SetDock(bar, Dock.Left);
        StackPanel txt = new StackPanel();
        TextBlock a = new TextBlock(); a.Text = titre; a.FontSize = 13; a.FontWeight = FontWeights.SemiBold; a.TextTrimming = TextTrimming.CharacterEllipsis;
        TextBlock b = new TextBlock(); b.FontSize = 11.5; b.Foreground = Br("#AEAEB2"); b.TextTrimming = TextTrimming.CharacterEllipsis;
        b.Text = (journee ? "Toute la journée" : debut + (fin.Length > 0 ? " – " + fin : "")) + (lieu.Length > 0 ? "  ·  " + lieu : "");
        txt.Children.Add(a); txt.Children.Add(b);
        row.Children.Add(bar); row.Children.Add(txt);
        if (lien.Length > 0) {
          row.Cursor = Cursors.Hand;
          string url = lien;
          row.MouseLeftButtonUp += delegate { try { System.Diagnostics.Process.Start(url); } catch (Exception ex) { Log("agenda : " + ex.Message); } };
        }
        list.Children.Add(row);
      }
    }

    // « 2026-11-04T20:22:09+01:00 » -> « Aujourd'hui · 20:22 »
    string NiceTime(string iso) {
      DateTimeOffset d;
      if (!DateTimeOffset.TryParse(iso, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out d)) return iso;
      DateTime l = d.LocalDateTime;
      string jour = l.Date == DateTime.Today ? "Aujourd'hui" : (l.Date == DateTime.Today.AddDays(-1) ? "Hier" : l.ToString("ddd d MMM", fr).Replace(".", ""));
      return jour + " · " + l.ToString("HH:mm");
    }

    // ---------------- voix dans la pilule ----------------
    readonly Voice voice = new Voice();
    bool talking, musicPausedByVoice; DateTime resumeMusicAt = DateTime.MinValue; string voiceState = "";
    void TalkStart() {
      string u = Str(G(sync, "noxUrl"));
      if (u.Length == 0) { ShowPeek(null, "\uE720", "#FFFFFF", "#FF453A", "Nox", "Nox est introuvable", "Vérifie que Tailscale est lancé", 4000, false); Refresh(); return; }
      talking = true; Hover();
      if (Playing()) { Cmd("play"); musicPausedByVoice = true; }   // on baisse le rideau sur la musique pendant qu'on parle
      resumeMusicAt = DateTime.MaxValue;
      ((TextBlock)E<Button>("BMic").Content).Foreground = Br("#FF453A");
      voice.PressStart(u);
    }
    void TalkEnd() {
      if (!talking) return;
      talking = false;
      ((TextBlock)E<Button>("BMic").Content).Foreground = Brushes.White;
      voice.PressEnd();
      resumeMusicAt = DateTime.Now.AddSeconds(25);   // filet : la musique revient même si Nox ne répond pas
      Hover();
    }
    void VoiceState(string st) {
      voiceState = st;
      TextBlock s = E<TextBlock>("NState");
      if (st == "ecoute") s.Text = "t'écoute…";
      else if (st == "reflechit") s.Text = "réfléchit…";
      else if (st == "parle") s.Text = "parle…";
      else if (st.StartsWith("erreur:")) { s.Text = "en ligne"; ShowPeek(null, "\uE720", "#FFFFFF", "#FF453A", "Nox", "Vocal indisponible", st.Substring(7), 5000, false); Refresh(); }
      else s.Text = "en ligne";
      squinting = st == "reflechit"; Squint(squinting);
    }
    void ShowVoiceText(string who, string t) {
      E<TextBlock>("NLastTime").Text = who == "Toi" ? "Tu dis" : "Nox répond";
      E<TextBlock>("NLast").Text = t;
      Vis("NLastBox", true);
      Vis("NBtns", false);
    }
    void VoiceTurnDone(string said) {
      voiceState = "";
      E<TextBlock>("NState").Text = "en ligne";
      resumeMusicAt = DateTime.Now.AddSeconds(1.5);
      if (!expandedOn && said.Length > 0) {
        string t1 = said.Length > 60 ? said.Substring(0, 60).TrimEnd() + "…" : said;
        ShowPeek(null, "\uE720", "#FFFFFF", "#849C8B", "Nox", t1, said.Length > 60 ? (said.Length > 140 ? said.Substring(60, 80).Trim() + "…" : said.Substring(60).Trim()) : "", 7000, false);
        Refresh();
      }
    }

    void Confirm(bool yes) {
      Hashtable n = G(sync, "nox") as Hashtable;
      Hashtable conf = n == null ? null : G(n, "confirm") as Hashtable;
      if (conf == null) return;
      NoxCmd("confirm:" + (yes ? "1" : "0") + ":" + Str(G(conf, "jeton")));
      Vis("NConfirm", false);
    }
  }
}

'@

try {
  Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Net.Http, System.Web.Extensions
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $refs = @(
    'System.dll',
    [System.Windows.Window].Assembly.Location,
    [System.Windows.Media.Color].Assembly.Location,
    [System.Windows.DependencyObject].Assembly.Location,
    [System.Xaml.XamlReader].Assembly.Location,
    [System.Management.Automation.PSObject].Assembly.Location,
    [System.Web.Script.Serialization.JavaScriptSerializer].Assembly.Location
  )
  Add-Type -ReferencedAssemblies $refs -TypeDefinition $CSharp -IgnoreWarnings -ErrorAction Stop
} catch { Fail 'compilation' ((@($Error | Select-Object -First 8 | ForEach-Object { $_.ToString() }) -join ' | ')) }
Log 'code compilé'

# ============================================================
#  Table partagée entre les fils
# ============================================================
$sync = [hashtable]::Synchronized(@{
  stop = $false; media = $null; playing = $false; timeline = $null; nox = $null; noxUrl = $null
  cmds = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
  noxcmds = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
  logPath = $LogPath; accent = $DefaultAccent; dir = $Here; version = $Version
  updateRepo = $UpdateRepo; updated = $null; skipPath = $SkipPath; restart = $false
})

# ============================================================
#  Fil 1 : musique (Windows) + mises à jour
# ============================================================
$mediaScript = {
  param($sync)
  function BLog($m) { try { Add-Content -Path $sync.logPath -Value ("{0:HH:mm:ss} MUS {1}" -f (Get-Date), $m) -Encoding UTF8 } catch {} }
  $lastErr = ''
  try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime, PresentationCore, WindowsBase, System.Net.Http
    $asTaskG = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
      $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    function Await($op, [Type]$t) {
      $task = $asTaskG.MakeGenericMethod($t).Invoke($null, @($op))
      if ($task.Wait(3000)) { return $task.Result }
      return $null
    }
    $null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime]
    $null = [Windows.Storage.Streams.IRandomAccessStreamWithContentType,Windows.Storage.Streams,ContentType=WindowsRuntime]
    $tMgr    = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]
    $tProps  = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties,Windows.Media.Control,ContentType=WindowsRuntime]
    $tStream = [Windows.Storage.Streams.IRandomAccessStreamWithContentType]
    $mgr = Await ($tMgr::RequestAsync()) $tMgr
    if ($mgr) { BLog 'connecté au gestionnaire média Windows' } else { BLog 'gestionnaire média introuvable' }
  } catch { BLog ("init : " + $_.Exception.Message); $mgr = $null }

  # Bluetooth : appareils connectés (casques, enceintes, téléphone…), relus toutes les 4 s
  $btSel = $null; $btNext = [DateTime]::Now.AddSeconds(3)
  try {
    $null = [Windows.Devices.Enumeration.DeviceInformation,Windows.Devices.Enumeration,ContentType=WindowsRuntime]
    $null = [Windows.Devices.Bluetooth.BluetoothDevice,Windows.Devices.Bluetooth,ContentType=WindowsRuntime]
    $tDevColl = [Windows.Devices.Enumeration.DeviceInformationCollection,Windows.Devices.Enumeration,ContentType=WindowsRuntime]
    $btSel = [Windows.Devices.Bluetooth.BluetoothDevice]::GetDeviceSelectorFromConnectionStatus([Windows.Devices.Bluetooth.BluetoothConnectionStatus]::Connected)
  } catch { BLog ("bluetooth (init) : " + $_.Exception.Message) }

  $http = New-Object System.Net.Http.HttpClient
  $http.Timeout = [TimeSpan]::FromSeconds(10)
  $http.DefaultRequestHeaders.UserAgent.ParseAdd('MathisDynamicIsland/1.0')
  $updNext = [DateTime]::Now.AddSeconds(15)
  $trackKey = ''; $artTries = 0; $artNext = [DateTime]::MinValue
  $spotifyUntil = [DateTime]::MinValue
  $fallback = [System.Windows.Media.ColorConverter]::ConvertFromString($sync.accent)

  while (-not $sync.stop) {
    try {
      if ($mgr) {
        $sess = $null
        foreach ($x in $mgr.GetSessions()) {
          if ($x.GetPlaybackInfo().PlaybackStatus.ToString() -eq 'Playing') { $sess = $x; break }
        }
        if (-not $sess) { $sess = $mgr.GetCurrentSession() }

        $c = $null
        while ($sync.cmds.TryDequeue([ref]$c)) {
          if ($c -eq 'spotify') {
            # ouvre Spotify puis lance la lecture dès que sa session apparaît
            try { Start-Process 'spotify:' } catch { BLog ("Spotify : " + $_.Exception.Message) }
            $spotifyUntil = [DateTime]::Now.AddSeconds(15)
            BLog 'ouverture de Spotify'
            continue
          }
          if (-not $sess) { continue }
          if ($c -eq 'play') { $null = $sess.TryTogglePlayPauseAsync() }
          elseif ($c -eq 'next') { $null = $sess.TrySkipNextAsync() }
          elseif ($c -eq 'prev') { $null = $sess.TrySkipPreviousAsync() }
          elseif ($c -like 'seek*:*') {
            $ms = [long]($c.Substring($c.IndexOf(':') + 1))
            $done = $false
            if ($c -like 'seekspotify:*' -and $sync.noxUrl) {
              # Spotify gère mal la commande Windows : on passe par Nox (API Spotify)
              try {
                $body = New-Object System.Net.Http.StringContent ('{"action":"position","valeur":' + $ms + ',"leger":true}'), ([System.Text.Encoding]::UTF8), 'application/json'
                $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post), ($sync.noxUrl + '/api/musique')
                $req.Content = $body; $req.Headers.Add('X-Jarvis', '1')
                $r = $http.SendAsync($req)
                if ($r.Wait(6000) -and $r.Result.IsSuccessStatusCode) { $done = $true; BLog "position $([int]($ms/1000)) s via Nox" }
                else { BLog "position via Nox refusée ($(if ($r.IsCompleted) { [int]$r.Result.StatusCode } else { 'délai' }))" }
              } catch { BLog ("position via Nox : " + $_.Exception.Message) }
            }
            if (-not $done) {
              $tl0 = $sess.GetTimelineProperties()
              $ticks = [long]($tl0.StartTime.Ticks + $ms * 10000)
              $ok = Await ($sess.TryChangePlaybackPositionAsync($ticks)) ([bool])
              BLog "position $([int]($ms/1000)) s via Windows : $ok"
            }
          }
        }

        if ($spotifyUntil -gt [DateTime]::Now) {
          $sp = @($mgr.GetSessions()) | Where-Object { $_.SourceAppUserModelId -like '*Spotify*' } | Select-Object -First 1
          if ($sp) {
            if ($sp.GetPlaybackInfo().PlaybackStatus.ToString() -ne 'Playing') { $null = $sp.TryPlayAsync() }
            $spotifyUntil = [DateTime]::MinValue; BLog 'lecture Spotify lancée'
          }
        } elseif ($spotifyUntil -ne [DateTime]::MinValue) {
          $spotifyUntil = [DateTime]::MinValue
          if ($sync.noxUrl) {   # Spotify ouvert mais sans session Windows : on demande à Nox de reprendre la lecture
            try {
              $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post), ($sync.noxUrl + '/api/musique')
              $req.Content = New-Object System.Net.Http.StringContent '{"action":"lecture","leger":true}', ([System.Text.Encoding]::UTF8), 'application/json'
              $req.Headers.Add('X-Jarvis', '1'); $null = $http.SendAsync($req); BLog 'lecture demandée à Nox'
            } catch {}
          }
        }

        if ($sess) {
          $playing = ($sess.GetPlaybackInfo().PlaybackStatus.ToString() -eq 'Playing')
          $sync.playing = $playing
          $p = Await ($sess.TryGetMediaPropertiesAsync()) $tProps
          if ($p -and $p.Title) {
            $key = "$($p.Title)|$($p.Artist)|$($sess.SourceAppUserModelId)"
            # pochette pas encore prête (fréquent juste après un démarrage) : on réessaie toutes les 2 s, 10 fois
            $retryArt = ($key -eq $trackKey -and $artTries -gt 0 -and [DateTime]::Now -ge $artNext)
            if ($key -ne $trackKey -or $retryArt) {
              if ($key -ne $trackKey) { $artTries = 10 }
              $trackKey = $key
              $art = $null; $col = $fallback
              try {
                if ($p.Thumbnail) {
                  $ras = Await ($p.Thumbnail.OpenReadAsync()) $tStream
                  if ($ras) {
                    $bytes = [Island.Img]::ReadAll($ras)
                    $ms2 = New-Object System.IO.MemoryStream (,$bytes)
                    $bmp = [System.Windows.Media.Imaging.BitmapImage]::new()
                    $bmp.BeginInit(); $bmp.CacheOption = 'OnLoad'; $bmp.DecodePixelWidth = 160; $bmp.StreamSource = $ms2; $bmp.EndInit(); $bmp.Freeze()
                    $art = $bmp
                    $col = [Island.Fx]::Dominant($bmp, $fallback)
                  }
                }
              } catch { BLog ("pochette : " + $_.Exception.Message) }
              if ($art) { $artTries = 0 } else { $artTries--; $artNext = [DateTime]::Now.AddSeconds(2) }
              if ($retryArt -and -not $art) { } else {
              $sync.media = @{ key = $key + $(if ($art) { '|a' } else { '' }); title = [string]$p.Title; artist = [string]$p.Artist; app = [string]$sess.SourceAppUserModelId; art = $art; color = $col }
              }
            }
            $tl = $sess.GetTimelineProperties()
            $end = ($tl.EndTime - $tl.StartTime).TotalSeconds
            $pos = ($tl.Position - $tl.StartTime).TotalSeconds
            if ($playing -and $tl.LastUpdatedTime.Year -gt 2000) { $pos += [math]::Min(([DateTimeOffset]::Now - $tl.LastUpdatedTime).TotalSeconds, $end) }
            $sync.timeline = @{ pos = $pos; end = $end; at = [DateTime]::Now }
          } else { $sync.media = $null; $sync.playing = $false; $trackKey = '' }
        } else { $sync.media = $null; $sync.playing = $false; $trackKey = '' }
      }
    } catch {
      $m = "musique : " + $_.Exception.Message
      if ($m -ne $lastErr) { BLog $m; $lastErr = $m }
    }

    if ($btSel -and [DateTime]::Now -ge $btNext) {
      $btNext = [DateTime]::Now.AddSeconds(4)
      try {
        $col = Await ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($btSel)) $tDevColl
        if ($col) { $sync.bt = @(@($col | ForEach-Object { [string]$_.Name }) | Where-Object { $_ } | Sort-Object -Unique) }
      } catch { $m = "bluetooth : " + $_.Exception.Message; if ($m -ne $lastErr) { BLog $m; $lastErr = $m } }
    }
    # Mises à jour automatiques depuis GitHub (15 s après le démarrage puis toutes les 3 h)
    if (-not $sync.updated -and [DateTime]::Now -ge $updNext) {
      $updNext = [DateTime]::Now.AddHours(3)
      try {
        $ct = $http.GetStringAsync('https://api.github.com/repos/' + $sync.updateRepo + '/commits/main')
        if (-not $ct.Wait(10000)) { throw 'GitHub injoignable' }
        $sha = ($ct.Result | ConvertFrom-Json).sha
        $base = 'https://raw.githubusercontent.com/' + $sync.updateRepo + '/' + $sha
        $vt = $http.GetStringAsync($base + '/version.txt')
        if ($vt.Wait(10000)) {
          $remote = [version]($vt.Result.Trim())
          $skip = @(); if (Test-Path $sync.skipPath) { $skip = Get-Content $sync.skipPath }
          if ($remote -gt [version]$sync.version -and ($skip -notcontains $remote.ToString())) {
            $dl = $http.GetByteArrayAsync($base + '/island.ps1')
            if ($dl.Wait(30000)) {
              $txt = [System.Text.Encoding]::UTF8.GetString($dl.Result).TrimStart([char]0xFEFF)
              $errs = $null; $tok = $null
              $null = [System.Management.Automation.Language.Parser]::ParseInput($txt, [ref]$tok, [ref]$errs)
              if ($errs.Count -eq 0 -and $txt -match "Version = '$([regex]::Escape($remote.ToString()))'") {
                $dest = Join-Path $sync.dir 'island.ps1'
                Copy-Item $dest ($dest + '.bak') -Force
                [System.IO.File]::WriteAllText($dest, $txt, (New-Object System.Text.UTF8Encoding $true))
                BLog "mise à jour installée : v$remote"
                $sync.updated = $remote.ToString()
              } else { BLog "mise à jour v$remote ignorée (fichier invalide)" }
            }
          }
        }
      } catch { BLog ("mise à jour : " + $_.Exception.Message) }
    }
    Start-Sleep -Milliseconds 300
  }
}

# ============================================================
#  Fil 2 : Nox (appli de Nox par Tailscale, rien d'ouvert sur Internet)
# ============================================================
$noxScript = {
  param($sync, $fixedUrl)
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
  function NLog($m) { try { Add-Content -Path $sync.logPath -Value ("{0:HH:mm:ss} NOX {1}" -f (Get-Date), $m) -Encoding UTF8 } catch {} }
  Add-Type -AssemblyName System.Net.Http
  $http = New-Object System.Net.Http.HttpClient
  $http.Timeout = [TimeSpan]::FromSeconds(40)
  $http.DefaultRequestHeaders.UserAgent.ParseAdd('MathisDynamicIsland/1.0')
  $http.DefaultRequestHeaders.Add('X-Jarvis', '1')

  function Find-Url {
    if ($fixedUrl) { return $fixedUrl.TrimEnd('/') }
    $ts = @("$env:ProgramFiles\Tailscale\tailscale.exe", "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $ts) { $cmd = Get-Command tailscale -ErrorAction SilentlyContinue; if ($cmd) { $ts = $cmd.Source } }
    if (-not $ts) { return $null }
    $j = (& $ts status --json 2>$null | Out-String) | ConvertFrom-Json
    if (-not $j -or -not $j.Peer) { return $null }
    $peers = @($j.Peer.PSObject.Properties | ForEach-Object { $_.Value })
    $p = $peers | Where-Object { $_.HostName -match '^jarvis' -or $_.DNSName -match '^jarvis\.' } | Select-Object -First 1
    if (-not $p) { return $null }
    return 'https://' + $p.DNSName.TrimEnd('.')
  }
  function Get-Json($path, [int]$wait = 12000) {
    $t = $http.GetStringAsync($sync.noxUrl + $path)
    if (-not $t.Wait($wait)) { throw "délai dépassé ($path)" }
    return ($t.Result | ConvertFrom-Json)
  }
  function Post-Json($path, $obj) {
    $json = $obj | ConvertTo-Json -Compress
    $c = New-Object System.Net.Http.StringContent $json, ([System.Text.Encoding]::UTF8), 'application/json'
    return $http.PostAsync($sync.noxUrl + $path, $c)
  }

  $state = @{ ok = $false; state = 'nourl'; error = 'recherche de Nox…' }
  $sync.nox = $state.Clone()
  $nextFind = [DateTime]::MinValue; $nextEquipe = [DateTime]::MinValue; $nextWidget = [DateTime]::MinValue; $nextWeek = [DateTime]::MinValue; $nextHouse = [DateTime]::Now.AddSeconds(5); $houseWas = $false
  $pouls = $null; $f = ''; $needConv = $true; $lastErr = ''; $pending = @()

  while (-not $sync.stop) {
    try {
      if (-not $sync.noxUrl) {
        if ([DateTime]::Now -ge $nextFind) {
          $nextFind = [DateTime]::Now.AddSeconds(60)
          $u = Find-Url
          if ($u) { $sync.noxUrl = $u; NLog "Nox trouvé : $u"; $needConv = $true }
          else { $sync.nox = @{ ok = $false; state = 'nourl'; error = 'Tailscale ou Nox introuvable' } }
        }
        Start-Sleep -Milliseconds 1000; continue
      }

      # ordres venus de la pilule
      $c = $null
      while ($sync.noxcmds.TryDequeue([ref]$c)) {
        if ($c -like 'file:*') {
          $path = $c.Substring(5)
          $ext = [System.IO.Path]::GetExtension($path).ToLower()
          $mime = @{ '.pdf' = 'application/pdf'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.png' = 'image/png'; '.webp' = 'image/webp'; '.gif' = 'image/gif' }[$ext]
          $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($path))
          $pending += Post-Json '/api/conversation' @{ texte = ''; image = @{ type = $mime; donnees = $b64 } }
          NLog ("fichier envoyé à Nox : " + [System.IO.Path]::GetFileName($path))
        }
        elseif ($c -like 'bouton:*') {
          $parts = $c.Substring(7).Split([char]0x1f, 2)
          $pending += Post-Json '/api/conversation/bouton' @{ id = $parts[0]; action = $parts[1] }
          NLog 'bouton de Nox'
        }
        elseif ($c -like 'house:*') {
          $parts = $c.Split(':', 4)
          if ($parts[1] -eq 'routine') { $pending += Post-Json '/api/lumiere' @{ action = 'routine'; nom = $parts[2]; leger = $true } }
          else { $pending += Post-Json '/api/lumiere' @{ action = 'piece'; groupe = $parts[2]; allumer = ($parts[3] -eq '1'); leger = $true } }
          $nextHouse = [DateTime]::Now.AddSeconds(1.5)
          NLog ("maison : " + $parts[1] + ' ' + $parts[2])
        }
        elseif ($c -like 'send:*') { $pending += Post-Json '/api/conversation' @{ texte = $c.Substring(5) }; NLog 'message envoyé à Nox' }
        elseif ($c -like 'confirm:*') {
          $parts = $c.Split(':', 3)
          $pending += Post-Json '/api/conversation/confirmer' @{ jeton = $parts[2]; oui = ($parts[1] -eq '1') }
          NLog ("feu vert : " + $(if ($parts[1] -eq '1') { 'confirmé' } else { 'annulé' }))
        }
      }
      $pending = @($pending | Where-Object { -not $_.IsCompleted })

      # qui travaille en ce moment
      if ([DateTime]::Now -ge $nextEquipe) {
        $nextEquipe = [DateTime]::Now.AddSeconds(8)
        $e = Get-Json '/api/equipe'
        $actifs = @($e.maintenant | Where-Object { $_.en_tache })
        $state.busy = $actifs.Count -gt 0
        $state.activity = if ($actifs.Count -gt 0) { (@($actifs | ForEach-Object { "$($_.nom) · $($_.activite)" }) -join '   ') } else { 'Rien en cours' }
        $state.ok = $true; $state.state = 'ok'; $state.error = ''
      }
      # météo et agenda pour la page Aujourd'hui
      if ([DateTime]::Now -ge $nextWidget) {
        $nextWidget = [DateTime]::Now.AddMinutes(5)
        try {
          $w = Get-Json '/api/widget' 20000
          $me = $null
          if ($w.meteo) { $me = @{ temp = [string]$w.meteo.temp; libelle = [string]$w.meteo.libelle; min = [string]$w.meteo.min; max = [string]$w.meteo.max } }
          $state.widget = @{ meteo = $me; agenda = @($w.agenda_liste | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
        } catch { NLog ("widget : " + $_.Exception.Message) }
      }
      # lumières (onglet Maison) : toutes les 4 s quand l'onglet est ouvert, sinon toutes les 2 min
      if ([DateTime]::Now -ge $nextHouse) {
        $nextHouse = [DateTime]::Now.AddSeconds($(if ($sync.houseWanted) { 4 } else { 120 }))
        try {
          $et = Get-Json '/api/etat' 25000
          $l = $et.lumieres
          if ($l -and -not $l.erreur) {
            $state.house = @{ allumees = [string]$l.allumees; total = [string]$l.total
              pieces = @(@($l.pieces) | Where-Object { $_ } | ForEach-Object { @{ groupe = [string]$_.groupe; nom = [string]$_.nom; allumee = [bool]$_.allumee; lum = [string]$_.luminosite } }) }
          }
        } catch { NLog ("maison : " + $_.Exception.Message) }
      }
      if ($sync.houseWanted -and -not $houseWas) { $nextHouse = [DateTime]::Now }
      if ($sync.houseRefresh) { $sync.houseRefresh = $false; $nextHouse = [DateTime]::Now.AddMilliseconds(600) }
      $houseWas = [bool]$sync.houseWanted
      # agenda des 7 prochains jours (onglet Agenda), toutes les 10 min
      if ([DateTime]::Now -ge $nextWeek) {
        $nextWeek = [DateTime]::Now.AddMinutes(10)
        try {
          $d0 = (Get-Date).Date
          $w1 = Get-Json ('/api/carnet/semaine?date=' + $d0.ToString('yyyy-MM-dd')) 20000
          $w2 = Get-Json ('/api/carnet/semaine?date=' + $d0.AddDays(7).ToString('yyyy-MM-dd')) 20000
          $tous = @(@($w1.jours) + @($w2.jours)) | Where-Object { $_ -and [string]$_.date -ge $d0.ToString('yyyy-MM-dd') } | Select-Object -First 7
          $state.week = @($tous | ForEach-Object {
            $evs = @($_.evenements | Where-Object { $_ } | ForEach-Object {
              @{ titre = [string]$_.titre; debut = [string]$_.debut; fin = [string]$_.fin; journee = [bool]$_.journee; lieu = [string]$_.lieu; lien = [string]$_.lien } })
            @{ date = [string]$_.date; evts = $evs }
          })
        } catch { NLog ("agenda : " + $_.Exception.Message); $nextWeek = [DateTime]::Now.AddMinutes(1) }
      }
      # fil de discussion : le « pouls » revient dès qu'un message arrive
      if ($pouls -and $pouls.IsCompleted) {
        if ($pouls.Status -eq 'RanToCompletion') {
          $pj = $pouls.Result | ConvertFrom-Json
          if ([string]$pj.f -ne $f) { $f = [string]$pj.f; $needConv = $true }
          $state.occupe = [bool]$pj.occupe
        } else { Start-Sleep -Milliseconds 2000 }
        $pouls = $null
      }
      if ($needConv) {
        $needConv = $false
        $conv = Get-Json '/api/conversation'
        $msgs = @($conv.messages)
        $state.occupe = [bool]$conv.occupe
        $lastNox = $msgs | Where-Object { $_.role -ne 'moi' } | Select-Object -Last 1
        if ($lastNox) {
          $btns = @()
          foreach ($ligne in @($lastNox.boutons)) { foreach ($b in @($ligne)) { if ($b -and $b.s -eq 'appli' -and $btns.Count -lt 3) { $btns += @{ l = [string]$b.l; a = [string]$b.a } } } }
          $state.last = @{ id = [string]$lastNox.id; texte = [string]$lastNox.texte; heure = [string]$lastNox.heure; boutons = $btns }
        }
        $att = $msgs | Where-Object { $_.confirmation -and $_.confirmation.etat -eq 'attente' } | Select-Object -Last 1
        $state.confirm = if ($att) { @{ jeton = [string]$att.confirmation.jeton; description = [string]$att.confirmation.description } } else { $null }
      }
      if (-not $pouls) { $pouls = $http.GetStringAsync($sync.noxUrl + '/api/pouls?f=' + [uri]::EscapeDataString($f)) }
      $sync.nox = $state.Clone()
      $lastErr = ''
    } catch {
      $m = $_.Exception.Message; if ($_.Exception.InnerException) { $m += ' / ' + $_.Exception.InnerException.Message }
      if ($m -ne $lastErr) { NLog $m; $lastErr = $m }
      $state.ok = $false; $state.state = 'down'; $state.error = 'injoignable'
      $sync.nox = $state.Clone()
      $pouls = $null
      Start-Sleep -Milliseconds 5000
      if ($m -match 'nom|name|resolve|introuvable') { $sync.noxUrl = $null }
    }
    Start-Sleep -Milliseconds 400
  }
}

function Start-Worker($sb, $args2) {
  $rs = [runspacefactory]::CreateRunspace()
  $rs.ApartmentState = 'MTA'
  $rs.Open()
  $ps = [PowerShell]::Create()
  $ps.Runspace = $rs
  $null = $ps.AddScript($sb)
  foreach ($a in $args2) { $null = $ps.AddArgument($a) }
  $null = $ps.BeginInvoke()
  return $ps
}
$workers = @(
  (Start-Worker $mediaScript @($sync)),
  (Start-Worker $noxScript @($sync, $NoxUrl))
)

# ============================================================
#  Interface
# ============================================================
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        Width="520" Height="320" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <Style x:Key="IconBtn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="#00FFFFFF" CornerRadius="18" Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#1FFFFFFF"/></Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="b" Property="Background" Value="#38FFFFFF"/>
                <Setter TargetName="b" Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="0.88" ScaleY="0.88"/></Setter.Value></Setter>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Chip" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="#1AFFFFFF"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="13" Padding="12,5">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.65"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Tab" TargetType="Button">
      <Setter Property="Foreground" Value="#8E8E93"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Margin" Value="2,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" CornerRadius="11" Padding="8,4">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe UI Variable Text, Segoe UI"/>
      <Setter Property="Foreground" Value="White"/>
    </Style>
  </Window.Resources>

  <Canvas x:Name="Root" Width="520" Height="320" RenderTransformOrigin="0.5,0">
    <Canvas.RenderTransform><ScaleTransform/></Canvas.RenderTransform>

    <!-- Nox qui jette un œil sous la pilule (quand il travaille ou a un message pendant la musique) -->
    <Grid x:Name="Peeker">
      <Grid.RenderTransform><TranslateTransform/></Grid.RenderTransform>
      <Grid x:Name="PkMaskBox" Width="24" Height="12" RenderTransformOrigin="0.5,0.5">
            <Grid.RenderTransform><RotateTransform/></Grid.RenderTransform>
            <Border x:Name="PkMask" CornerRadius="6" Background="#F4EFE6" BorderBrush="#FF453A" BorderThickness="0"/>
            <Canvas x:Name="PkPupils" Width="24" Height="12">
              <Canvas.RenderTransform><TranslateTransform/></Canvas.RenderTransform>
              <Grid x:Name="PkL" Width="5.2" Height="5.2" Canvas.Left="3.7" Canvas.Top="3.4" RenderTransformOrigin="0.5,0.5">
                <Grid.RenderTransform><ScaleTransform/></Grid.RenderTransform>
                <Ellipse Fill="#3A3734"/><Ellipse Width="1.6" Height="1.6" Fill="#F4EFE6" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="2.6,0.9,0,0"/>
              </Grid>
              <Grid x:Name="PkR" Width="5.2" Height="5.2" Canvas.Left="15.1" Canvas.Top="3.4" RenderTransformOrigin="0.5,0.5">
                <Grid.RenderTransform><ScaleTransform/></Grid.RenderTransform>
                <Ellipse Fill="#3A3734"/><Ellipse Width="1.6" Height="1.6" Fill="#F4EFE6" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="2.6,0.9,0,0"/>
              </Grid>
            </Canvas>
          </Grid>
    </Grid>

    <!-- la forme (dessinée image par image) -->
    <Path x:Name="Shape"/>
    <Path x:Name="EarL" Data="M0,0 L12,0 L12,12 A12,12 0 0 0 0,0 Z"><Path.RenderTransform><TranslateTransform/></Path.RenderTransform></Path>
    <Path x:Name="EarR" Data="M0,0 L12,0 A12,12 0 0 0 0,12 Z"><Path.RenderTransform><TranslateTransform/></Path.RenderTransform></Path>

    <!-- bulle : 2e activité (minuteur ou Nox au travail pendant la musique) -->
    <Border x:Name="Bubble" Canvas.Top="1" Background="#000000" Width="0" Height="0" Visibility="Collapsed">
      <Border.RenderTransform><TranslateTransform/></Border.RenderTransform>
      <Grid>
        <Grid x:Name="BRing" Width="22" Height="22" HorizontalAlignment="Center" VerticalAlignment="Center">
          <Ellipse Width="22" Height="22" Stroke="#33FF9F0A" StrokeThickness="2.5"/>
          <Path x:Name="Ring" Width="22" Height="22" Stroke="$TimerColor" StrokeThickness="2.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
          <TextBlock x:Name="RingTxt" FontSize="9" FontFamily="Segoe UI Variable Display Semibold, Segoe UI Semibold" Foreground="$TimerColor" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Grid>
      </Grid>
    </Border>

    <!-- le contenu, découpé à la forme de la pilule -->
    <Canvas x:Name="ClipHost" Width="520" Height="320">

      <!-- fond « dégradé vivant » : pochette minuscule agrandie (flou naturel), qui dérive lentement -->
      <Grid x:Name="Amb" Width="520" Height="320" Opacity="0" IsHitTestVisible="False">
        <Image x:Name="AmbImg" Stretch="Fill" RenderOptions.BitmapScalingMode="HighQuality" RenderTransformOrigin="0.5,0.5">
          <Image.RenderTransform>
            <TransformGroup><ScaleTransform x:Name="AmbScale" ScaleX="1.25" ScaleY="1.25"/><TranslateTransform x:Name="AmbMove"/></TransformGroup>
          </Image.RenderTransform>
        </Image>
        <Rectangle>
          <Rectangle.Fill>
            <LinearGradientBrush StartPoint="0.5,0" EndPoint="0.5,1">
              <GradientStop Color="#F2000000" Offset="0"/>
              <GradientStop Color="#B8000000" Offset="0.3"/>
              <GradientStop Color="#8C000000" Offset="0.7"/>
              <GradientStop Color="#A6000000" Offset="1"/>
            </LinearGradientBrush>
          </Rectangle.Fill>
        </Rectangle>
      </Grid>

      <!-- COMPACT -->
      <Grid x:Name="Compact" Height="34">
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <Grid Grid.Column="0" Margin="10,0,0,0" VerticalAlignment="Center">
          <Border x:Name="CArtBox" Width="22" Height="22" CornerRadius="6" Background="#1C1C1E"/>
          <Grid x:Name="CRingBox" Width="17" Height="17" Margin="2,0,0,0">
            <Ellipse Width="17" Height="17" Stroke="#30FFFFFF" StrokeThickness="2.5"/>
            <Path x:Name="CRing" Width="17" Height="17" StrokeThickness="2.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
          </Grid>
        </Grid>
        <Grid Grid.Column="1" VerticalAlignment="Center" Margin="9,0,9,0">
          <TextBlock x:Name="CClock" FontFamily="Segoe UI Variable Display Semibold, Segoe UI Semibold" FontSize="14" HorizontalAlignment="Center"/>
          <TextBlock x:Name="CTimer" FontFamily="Segoe UI Variable Display Semibold, Segoe UI Semibold" FontSize="14" Foreground="$TimerColor" HorizontalAlignment="Center"/>
          <TextBlock x:Name="CEvent" FontFamily="Segoe UI Variable Text Semibold, Segoe UI Semibold" FontSize="12.5" Foreground="#64B5FF" HorizontalAlignment="Center" Visibility="Collapsed"/>
          <Canvas x:Name="CTitleBox" Height="18" Width="10" ClipToBounds="True" HorizontalAlignment="Left">
            <TextBlock x:Name="CTitle" FontSize="12.5" Foreground="#F2F2F7">
              <TextBlock.RenderTransform><TranslateTransform/></TextBlock.RenderTransform>
            </TextBlock>
          </Canvas>
        </Grid>
        <StackPanel Grid.Column="2" Orientation="Horizontal" Margin="0,0,12,0" VerticalAlignment="Center">
          <StackPanel x:Name="CEq" Orientation="Horizontal" Height="14" VerticalAlignment="Center">
            <Rectangle x:Name="Eq1" Width="3" Height="14" RadiusX="1.5" RadiusY="1.5" Margin="1,0" RenderTransformOrigin="0.5,0.5"><Rectangle.RenderTransform><ScaleTransform ScaleY="0.35"/></Rectangle.RenderTransform></Rectangle>
            <Rectangle x:Name="Eq2" Width="3" Height="14" RadiusX="1.5" RadiusY="1.5" Margin="1,0" RenderTransformOrigin="0.5,0.5"><Rectangle.RenderTransform><ScaleTransform ScaleY="0.7"/></Rectangle.RenderTransform></Rectangle>
            <Rectangle x:Name="Eq3" Width="3" Height="14" RadiusX="1.5" RadiusY="1.5" Margin="1,0" RenderTransformOrigin="0.5,0.5"><Rectangle.RenderTransform><ScaleTransform ScaleY="0.5"/></Rectangle.RenderTransform></Rectangle>
            <Rectangle x:Name="Eq4" Width="3" Height="14" RadiusX="1.5" RadiusY="1.5" Margin="1,0" RenderTransformOrigin="0.5,0.5"><Rectangle.RenderTransform><ScaleTransform ScaleY="0.4"/></Rectangle.RenderTransform></Rectangle>
          </StackPanel>
          <Grid x:Name="CEyes" Width="16" Height="10" Margin="9,0,0,0" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5" Opacity="0.85">
            <Grid.RenderTransform><RotateTransform/></Grid.RenderTransform>
            <Border x:Name="EyeMask" Background="Transparent" BorderThickness="0"/>
            <Canvas x:Name="CPupils" Width="18" Height="11">
              <Canvas.RenderTransform><TranslateTransform/></Canvas.RenderTransform>
              <Grid x:Name="EyeL" Width="4.5" Height="9" Canvas.Left="2.2" Canvas.Top="0.5" RenderTransformOrigin="0.5,0.5">
                <Grid.RenderTransform><ScaleTransform/></Grid.RenderTransform>
                <Ellipse x:Name="CEyeFillL" Fill="#F4EFE6"/>
              </Grid>
              <Grid x:Name="EyeR" Width="4.5" Height="9" Canvas.Left="9.3" Canvas.Top="0.5" RenderTransformOrigin="0.5,0.5">
                <Grid.RenderTransform><ScaleTransform/></Grid.RenderTransform>
                <Ellipse x:Name="CEyeFillR" Fill="#F4EFE6"/>
              </Grid>
            </Canvas>
          </Grid>
        </StackPanel>
      </Grid>

      <!-- TOAST (volume, charge) -->
      <DockPanel x:Name="Toast" Height="34" Width="300">
        <TextBlock x:Name="TIco" DockPanel.Dock="Left" FontFamily="Segoe Fluent Icons" FontSize="16" VerticalAlignment="Center" Width="22" Margin="14,0,0,0"/>
        <TextBlock x:Name="TRight" DockPanel.Dock="Right" FontFamily="Segoe UI Variable Display Semibold, Segoe UI Semibold" FontSize="13" VerticalAlignment="Center" Margin="12,0,16,0" MinWidth="26" TextAlignment="Right"/>
        <Grid VerticalAlignment="Center" Margin="10,0,0,0">
          <TextBlock x:Name="TText" FontSize="13" TextTrimming="CharacterEllipsis"/>
          <Border x:Name="TBarBg" Height="6" CornerRadius="3" Background="#33FFFFFF" Width="170" HorizontalAlignment="Left">
            <Border x:Name="TBar" Height="6" CornerRadius="3" Background="White" HorizontalAlignment="Left" Width="0"/>
          </Border>
        </Grid>
      </DockPanel>

      <!-- NOTIFICATION façon iOS -->
      <Border x:Name="Peek" Padding="16,10,16,14">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <Border x:Name="PArtBox" Width="40" Height="40" CornerRadius="10" Background="#2C2C2E" VerticalAlignment="Top" Margin="0,2,0,0">
            <TextBlock x:Name="PIco" FontFamily="Segoe Fluent Icons" FontSize="18" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center" Width="300">
            <DockPanel>
              <TextBlock DockPanel.Dock="Right" Text="maintenant" FontSize="11.5" Foreground="#8E8E93"/>
              <TextBlock x:Name="PApp" FontSize="11.5" Foreground="#8E8E93"/>
            </DockPanel>
            <TextBlock x:Name="PTitle" FontFamily="Segoe UI Variable Display Semibold, Segoe UI Semibold" FontSize="14.5" TextTrimming="CharacterEllipsis" Margin="0,1,0,0"/>
            <TextBlock x:Name="PSub" FontSize="12.5" Foreground="#AEAEB2" TextTrimming="CharacterEllipsis"/>
            <StackPanel x:Name="PButtons" Orientation="Horizontal" Margin="0,8,0,0" Visibility="Collapsed">
              <Button x:Name="BPeekOk" Style="{StaticResource Chip}" Background="#30D158" Margin="0,0,6,0"><TextBlock Text="Confirmer" FontSize="12"/></Button>
              <Button x:Name="BPeekNo" Style="{StaticResource Chip}"><TextBlock Text="Annuler" FontSize="12"/></Button>
            </StackPanel>
          </StackPanel>
        </Grid>
      </Border>

      <!-- VUE OUVERTE : 4 widgets -->
      <Border x:Name="Expanded" Width="440" Padding="20,12,20,10">
        <DockPanel LastChildFill="True">
          <!-- onglets : clic, ou molette / deux doigts -->
          <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,10,0,0">
            <Button x:Name="TabMusic" Style="{StaticResource Tab}">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xEC4F;" FontFamily="Segoe Fluent Icons" FontSize="11" VerticalAlignment="Center" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
                <TextBlock Text="Musique" FontSize="11" Margin="5,0,0,0" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
              </StackPanel>
            </Button>
            <Button x:Name="TabTimer" Style="{StaticResource Tab}">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE916;" FontFamily="Segoe Fluent Icons" FontSize="11" VerticalAlignment="Center" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
                <TextBlock Text="Minuteur" FontSize="11" Margin="5,0,0,0" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
              </StackPanel>
            </Button>
            <Button x:Name="TabNox" Style="{StaticResource Tab}">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE8BD;" FontFamily="Segoe Fluent Icons" FontSize="11" VerticalAlignment="Center" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
                <TextBlock Text="Nox" FontSize="11" Margin="5,0,0,0" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
              </StackPanel>
            </Button>
            <Button x:Name="TabHouse" Style="{StaticResource Tab}">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE80F;" FontFamily="Segoe Fluent Icons" FontSize="11" VerticalAlignment="Center" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
                <TextBlock Text="Maison" FontSize="11" Margin="5,0,0,0" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
              </StackPanel>
            </Button>
            <Button x:Name="TabTools" Style="{StaticResource Tab}">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE8A9;" FontFamily="Segoe Fluent Icons" FontSize="11" VerticalAlignment="Center" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
                <TextBlock Text="Raccourcis" FontSize="11" Margin="5,0,0,0" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
              </StackPanel>
            </Button>
            <Button x:Name="TabAgenda" Style="{StaticResource Tab}">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE787;" FontFamily="Segoe Fluent Icons" FontSize="11" VerticalAlignment="Center" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
                <TextBlock Text="Agenda" FontSize="11" Margin="5,0,0,0" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
              </StackPanel>
            </Button>
            <Button x:Name="TabToday" Style="{StaticResource Tab}">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE787;" FontFamily="Segoe Fluent Icons" FontSize="11" VerticalAlignment="Center" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
                <TextBlock Text="Aujourd'hui" FontSize="11" Margin="5,0,0,0" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
              </StackPanel>
            </Button>
          </StackPanel>
          <Grid VerticalAlignment="Center">

            <!-- Musique -->
            <StackPanel x:Name="PgMusic">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <Border x:Name="EArtBox" Width="56" Height="56" CornerRadius="13" Background="#1C1C1E">
                  <TextBlock x:Name="EArtIco" Text="&#xEC4F;" FontFamily="Segoe Fluent Icons" FontSize="22" Foreground="#636366" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <StackPanel Grid.Column="1" Margin="13,0,8,0" VerticalAlignment="Center">
                  <TextBlock x:Name="ETitle" FontFamily="Segoe UI Variable Display Semibold, Segoe UI Semibold" FontSize="16" TextTrimming="CharacterEllipsis"/>
                  <TextBlock x:Name="EArtist" FontSize="13" Foreground="#C7C7CC" TextTrimming="CharacterEllipsis" Margin="0,1,0,0"/>
                  <TextBlock x:Name="EApp" FontSize="11" Foreground="#8E8E93" Margin="0,3,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="2" Orientation="Horizontal" Height="16" VerticalAlignment="Top" Margin="0,4,0,0" Visibility="Collapsed">
                  <Rectangle x:Name="Eq5" Width="3" Height="16" RadiusX="1.5" RadiusY="1.5" Margin="1,0" RenderTransformOrigin="0.5,0.5"><Rectangle.RenderTransform><ScaleTransform ScaleY="0.4"/></Rectangle.RenderTransform></Rectangle>
                  <Rectangle x:Name="Eq6" Width="3" Height="16" RadiusX="1.5" RadiusY="1.5" Margin="1,0" RenderTransformOrigin="0.5,0.5"><Rectangle.RenderTransform><ScaleTransform ScaleY="0.7"/></Rectangle.RenderTransform></Rectangle>
                  <Rectangle x:Name="Eq7" Width="3" Height="16" RadiusX="1.5" RadiusY="1.5" Margin="1,0" RenderTransformOrigin="0.5,0.5"><Rectangle.RenderTransform><ScaleTransform ScaleY="0.5"/></Rectangle.RenderTransform></Rectangle>
                  <Rectangle x:Name="Eq8" Width="3" Height="16" RadiusX="1.5" RadiusY="1.5" Margin="1,0" RenderTransformOrigin="0.5,0.5"><Rectangle.RenderTransform><ScaleTransform ScaleY="0.3"/></Rectangle.RenderTransform></Rectangle>
                </StackPanel>
              </Grid>
              <DockPanel x:Name="EProg" Margin="0,10,0,0">
                <TextBlock x:Name="EPos" DockPanel.Dock="Left" FontSize="12" Foreground="#AEAEB2" Width="38" Typography.NumeralAlignment="Tabular" VerticalAlignment="Center"/>
                <TextBlock x:Name="ELeft" DockPanel.Dock="Right" FontSize="12" Foreground="#AEAEB2" Width="42" Typography.NumeralAlignment="Tabular" TextAlignment="Right" VerticalAlignment="Center"/>
                <Grid x:Name="EBarHit" VerticalAlignment="Center" Height="18" Background="#00000000" Cursor="Hand">
                  <!-- reste du morceau : trait fin ; partie écoutée : vague qui ondule pendant la lecture -->
                  <Path x:Name="ERest" StrokeThickness="3" Stroke="#30FFFFFF" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                  <Path x:Name="EWave" StrokeThickness="3" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                  <Rectangle x:Name="EKnob" Width="4" Height="12" RadiusX="2" RadiusY="2" Fill="White" HorizontalAlignment="Left" VerticalAlignment="Center"/>
                  <Border x:Name="EBar" Visibility="Collapsed" CornerRadius="2" Height="4" RenderTransformOrigin="0,0.5">
                    <Border.RenderTransform><ScaleTransform x:Name="EBarScale" ScaleX="0"/></Border.RenderTransform>
                  </Border>
                </Grid>
              </DockPanel>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,2,0,0">
                <Button x:Name="BPrev" Style="{StaticResource IconBtn}" Padding="10" Margin="0,0,18,0"><Path Width="20" Height="16" Fill="White" Stretch="Uniform" Data="M2,0 L4.5,0 L4.5,16 L2,16 Z M20,0.6 L20,15.4 Q20,16.6 19,16 L6.4,8.9 Q5.5,8 6.4,7.1 L19,0 Q20,-0.6 20,0.6 Z"/></Button>
                <Button x:Name="BPlay" Style="{StaticResource IconBtn}" Padding="10"><Grid Width="28" Height="28">
                  <TextBlock x:Name="BPlayIco" Visibility="Collapsed"/>
                  <Path x:Name="BPauseShape" Fill="White" Data="M7,3.5 Q7,2 8.5,2 L11,2 Q12.5,2 12.5,3.5 L12.5,24.5 Q12.5,26 11,26 L8.5,26 Q7,26 7,24.5 Z M15.5,3.5 Q15.5,2 17,2 L19.5,2 Q21,2 21,3.5 L21,24.5 Q21,26 19.5,26 L17,26 Q15.5,26 15.5,24.5 Z"/>
                  <Path x:Name="BPlayShape" Fill="White" Visibility="Collapsed" Data="M8,3.8 Q8,1.9 9.7,2.9 L24.6,12.3 Q26.1,13.3 24.6,14.3 L9.7,23.7 Q8,24.7 8,22.8 Z"/>
                </Grid></Button>
                <Button x:Name="BNext" Style="{StaticResource IconBtn}" Padding="10" Margin="18,0,0,0"><Path Width="20" Height="16" Fill="White" Stretch="Uniform" Data="M18,0 L15.5,0 L15.5,16 L18,16 Z M0,0.6 L0,15.4 Q0,16.6 1,16 L13.6,8.9 Q14.5,8 13.6,7.1 L1,0 Q0,-0.6 0,0.6 Z"/></Button>
              </StackPanel>
            </StackPanel>

            <!-- Minuteur -->
            <Grid x:Name="PgTimer" Visibility="Collapsed" HorizontalAlignment="Center">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Grid Width="64" Height="64">
                <Ellipse Width="64" Height="64" Stroke="#33FF9F0A" StrokeThickness="5"/>
                <Path x:Name="TRing" Width="64" Height="64" Stroke="$TimerColor" StrokeThickness="5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                <TextBlock x:Name="TRingTxt" FontFamily="Segoe UI Variable Display Semibold, Segoe UI Semibold" FontSize="14" Foreground="$TimerColor" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Grid>
              <StackPanel Grid.Column="1" Margin="16,0,0,0" VerticalAlignment="Center">
                <TextBlock x:Name="TLabel" FontFamily="Segoe UI Variable Display Semibold, Segoe UI Semibold" FontSize="16"/>
                <TextBlock x:Name="TSub" FontSize="12.5" Foreground="#AEAEB2" Margin="0,1,0,8"/>
                <StackPanel Orientation="Horizontal">
                  <Button x:Name="BT25" Style="{StaticResource Chip}" Margin="0,0,6,0"><TextBlock Text="Focus 25 min" FontSize="12"/></Button>
                  <Button x:Name="BT5" Style="{StaticResource Chip}"><TextBlock Text="Pause 5 min" FontSize="12"/></Button>
                  <Button x:Name="BTStop" Style="{StaticResource Chip}"><TextBlock Text="Arrêter" FontSize="12" Foreground="$TimerColor"/></Button>
                </StackPanel>
              </StackPanel>
            </Grid>

            <!-- Nox -->
            <StackPanel x:Name="PgNox" Visibility="Collapsed">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <!-- la chouette de Nox (même dessin que dans l'appli) -->
                <Viewbox Width="48" Height="48">
                  <Canvas x:Name="NOwl" Width="64" Height="64" RenderTransformOrigin="0.5,0.6">
                    <Canvas.RenderTransform><RotateTransform/></Canvas.RenderTransform>
                    <Ellipse Canvas.Left="6" Canvas.Top="8" Width="52" Height="52" Fill="#849C8B"/>
                    <Path Data="M14,14 L20,22 L12,22 Z M50,14 L44,22 L52,22 Z" Fill="#6F8877"/>
                    <Border x:Name="NMask" Canvas.Left="11" Canvas.Top="22" Width="42" Height="22" CornerRadius="11" Background="#F4EFE6" BorderBrush="#FF453A" BorderThickness="0"/>
                    <Canvas x:Name="NPupils" Width="64" Height="64">
                      <Canvas.RenderTransform><TranslateTransform/></Canvas.RenderTransform>
                      <Grid x:Name="NEyeL" Width="9" Height="9" Canvas.Left="17.5" Canvas.Top="28.5" RenderTransformOrigin="0.5,0.5">
                        <Grid.RenderTransform><ScaleTransform/></Grid.RenderTransform>
                        <Ellipse Fill="#3A3734"/><Ellipse Width="2.8" Height="2.8" Fill="#F4EFE6" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="4.6,1.6,0,0"/>
                      </Grid>
                      <Grid x:Name="NEyeR" Width="9" Height="9" Canvas.Left="37.5" Canvas.Top="28.5" RenderTransformOrigin="0.5,0.5">
                        <Grid.RenderTransform><ScaleTransform/></Grid.RenderTransform>
                        <Ellipse Fill="#3A3734"/><Ellipse Width="2.8" Height="2.8" Fill="#F4EFE6" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="4.6,1.6,0,0"/>
                      </Grid>
                    </Canvas>
                    <Path Data="M29,40 L35,40 L32,46 Z" Fill="#D46F61"/>
                  </Canvas>
                </Viewbox>
                <StackPanel Grid.Column="1" Margin="14,0,0,0" VerticalAlignment="Center">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="Nox" FontFamily="Segoe UI Variable Display Semibold, Segoe UI Semibold" FontSize="16"/>
                    <Ellipse x:Name="NDot" Width="8" Height="8" Margin="9,3,0,0" VerticalAlignment="Center" Fill="#8E8E93"/>
                    <TextBlock x:Name="NState" FontSize="12.5" Foreground="#AEAEB2" Margin="6,3,0,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="NBusy" Text="  · écrit…" FontSize="12.5" Foreground="#B9B4FF" Margin="0,3,0,0" VerticalAlignment="Center" Visibility="Collapsed"/>
                  </StackPanel>
                  <TextBlock x:Name="NAct" FontSize="12.5" Foreground="#C7C7CC" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
                </StackPanel>
              </Grid>
              <Border x:Name="NLastBox" Margin="0,10,0,0" Background="#14FFFFFF" CornerRadius="12" Padding="12,7" Visibility="Collapsed">
                <StackPanel>
                  <TextBlock x:Name="NLastTime" FontSize="10.5" Foreground="#8E8E93"/>
                  <TextBlock x:Name="NLast" FontSize="12.5" Foreground="#E5E5EA" TextWrapping="Wrap" MaxHeight="50" TextTrimming="CharacterEllipsis"/>
                  <StackPanel x:Name="NBtns" Orientation="Horizontal" Margin="0,7,0,0" Visibility="Collapsed"/>
                </StackPanel>
              </Border>
              <Border x:Name="NConfirm" Margin="0,8,0,0" Background="#26FF9F0A" CornerRadius="12" Padding="12,8" Visibility="Collapsed">
                <DockPanel>
                  <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center" Margin="8,0,0,0">
                    <Button x:Name="BConfNo" Style="{StaticResource Chip}" Margin="0,0,6,0"><TextBlock Text="Annuler" FontSize="12"/></Button>
                    <Button x:Name="BConfOk" Style="{StaticResource Chip}" Background="#30D158"><TextBlock Text="Confirmer" FontSize="12"/></Button>
                  </StackPanel>
                  <TextBlock x:Name="NConfText" FontSize="12.5" TextWrapping="Wrap" VerticalAlignment="Center"/>
                </DockPanel>
              </Border>
              <Border Margin="0,10,0,0" CornerRadius="17" Background="#1FFFFFFF" Height="34" Padding="14,0,3,0">
                <DockPanel>
                  <Button x:Name="BSend" DockPanel.Dock="Right" Style="{StaticResource IconBtn}" Padding="7"><TextBlock Text="&#xE724;" FontFamily="Segoe Fluent Icons" FontSize="13"/></Button>
                  <Button x:Name="BMic" DockPanel.Dock="Right" Style="{StaticResource IconBtn}" Padding="7" ToolTip="Maintiens pour parler à Nox"><TextBlock Text="&#xE720;" FontFamily="Segoe Fluent Icons" FontSize="13"/></Button>
                  <Grid VerticalAlignment="Center">
                    <TextBlock x:Name="NPh" Text="Écris à Nox, ou maintiens le micro pour lui parler" FontSize="13" Foreground="#8E8E93" IsHitTestVisible="False"/>
                    <TextBox x:Name="NInput" Background="Transparent" BorderThickness="0" Foreground="White" CaretBrush="White" FontSize="13" Padding="-2,0,0,0" FontFamily="Segoe UI Variable Text, Segoe UI"/>
                  </Grid>
                </DockPanel>
              </Border>
            </StackPanel>

            <!-- Maison : routines et pièces (lumières Hue, par Nox) -->
            <StackPanel x:Name="PgHouse" Visibility="Collapsed">
              <DockPanel Margin="2,0,0,8">
                <TextBlock x:Name="HSummary" DockPanel.Dock="Right" FontSize="12" Foreground="#8E8E93"/>
                <TextBlock Text="Maison" FontFamily="Segoe UI Variable Display Semibold, Segoe UI Semibold" FontSize="15"/>
              </DockPanel>
              <WrapPanel x:Name="HRoutines" Margin="0,0,0,10"/>
              <UniformGrid x:Name="HRooms" Columns="3"/>
              <TextBlock x:Name="HEmpty" Text="Les lumières arrivent…" FontSize="12.5" Foreground="#8E8E93" Margin="2,2,0,2"/>
            </StackPanel>

            <!-- Raccourcis Windows -->
            <UniformGrid x:Name="PgTools" Visibility="Collapsed" Columns="4"/>

            <!-- Agenda : les 7 prochains jours, puis les rendez-vous du jour choisi -->
            <StackPanel x:Name="PgAgenda" Visibility="Collapsed">
              <TextBlock x:Name="AMonth" FontSize="12" Foreground="#8E8E93" Margin="2,0,0,6"/>
              <UniformGrid x:Name="ADays" Columns="7" Margin="0,0,0,10"/>
              <StackPanel x:Name="AList"/>
            </StackPanel>

            <!-- Aujourd'hui -->
            <Grid x:Name="PgToday" Visibility="Collapsed" HorizontalAlignment="Center">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock x:Name="EClock" FontFamily="Segoe UI Variable Display Semibold, Segoe UI Semibold" FontSize="40" VerticalAlignment="Center"/>
              <StackPanel Grid.Column="1" Margin="18,0,0,0" VerticalAlignment="Center">
                <TextBlock x:Name="EDate" FontSize="14.5" Foreground="#E5E5EA"/>
                <TextBlock x:Name="TMeteo" FontSize="12.5" Foreground="#C7C7CC" Margin="0,3,0,0" Visibility="Collapsed"/>
                <TextBlock x:Name="TAgenda1" FontSize="12.5" Foreground="#C7C7CC" TextTrimming="CharacterEllipsis" Margin="0,3,0,0" Visibility="Collapsed"/>
                <TextBlock x:Name="TAgenda2" FontSize="12.5" Foreground="#8E8E93" TextTrimming="CharacterEllipsis" Visibility="Collapsed"/>
                <StackPanel Orientation="Horizontal" Margin="0,5,0,0">
                  <TextBlock x:Name="EBattIco" FontFamily="Segoe Fluent Icons" FontSize="15" VerticalAlignment="Center"/>
                  <TextBlock x:Name="EBattTxt" FontSize="12.5" Foreground="#C7C7CC" Margin="6,0,14,0" VerticalAlignment="Center"/>
                  <TextBlock x:Name="EVolIco" FontFamily="Segoe Fluent Icons" FontSize="14" VerticalAlignment="Center"/>
                  <TextBlock x:Name="EVolTxt" FontSize="12.5" Foreground="#C7C7CC" Margin="6,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
              </StackPanel>
            </Grid>
          </Grid>

        </DockPanel>
      </Border>

      <!-- pochette qui « voyage » de la pilule réduite vers la vue ouverte -->
      <Border x:Name="Flyer" Visibility="Collapsed" CornerRadius="9" IsHitTestVisible="False"/>
    </Canvas>
    <!-- liseré coloré, dessiné par-dessus tout le reste -->
    <Path x:Name="Edge" IsHitTestVisible="False" StrokeThickness="1" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
  </Canvas>
</Window>

"@

try {
  $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
  $cfg = @{ logPath = [string]$LogPath; accent = $DefaultAccent; timerColor = $TimerColor; chargeColor = $ChargeColor; hideFullscreen = [bool]$HideInFullscreen; version = $Version }
  $app = New-Object Island.App($win, $sync, $cfg)
} catch {
  $sync.stop = $true
  Fail 'interface' ($_.Exception.ToString())
}

Log 'démarrée'
try { $null = $win.ShowDialog() } catch { Log ("ShowDialog : " + $_.Exception.ToString()) }
Log 'fenêtre fermée'

# ---------- Fermeture ----------
$sync.stop = $true
foreach ($w in $workers) { try { $null = $w.BeginStop($null, $null) } catch {} }
if ($sync.restart) { Log 'redémarrage'; Restart-Island }
try { $script:mutex.ReleaseMutex() } catch {}
[Environment]::Exit(0)   # ferme aussi les fils de fond
