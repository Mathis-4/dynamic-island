# ============================================================
#  Dynamic Island de Mathis - Windows 11
#  L'affichage est du code compilé (C#) ; PowerShell lance, lit la musique et parle à Nox.
#  Clic droit sur la pilule : version, journal, redémarrer, quitter
# ============================================================
$Version = '4.8'

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
  }
  [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceEnumerator {
    int f();
    int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
  }
  [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCom { }

  public static class Audio {
    static IMMDeviceEnumerator en;
    static IAudioEndpointVolume vol;
    static IAudioEndpointVolume Vol() {
      if (en == null) en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorCom());
      IMMDevice dev; en.GetDefaultAudioEndpoint(0, 1, out dev);
      Guid iid = typeof(IAudioEndpointVolume).GUID; object o;
      dev.Activate(ref iid, 23, IntPtr.Zero, out o);
      return (IAudioEndpointVolume)o;
    }
    public static void Reset() { vol = null; }
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
    bool noxUnread, peeking, tilted;
    double compactW = 160, stickyH = 0, expNatural = 0; string expKey = ""; Size peekSize = new Size(300, 60);
    bool firstTrack = true, eqOn = false, ringIsTimer = false, peekIsConfirm = false;
    DateTime? timerEnd = null; double timerTotal = 1; string timerLabel = "";
    double vol = -2; bool muted = false; int battPct = 100; bool? power = null; bool lowWarned = false;
    string noxMsgId = null; bool noxSeen = false; string noxState = "";
    double wheelAcc = 0; int tickN = 0;
    string[] pageNames = { "PgMusic", "PgTimer", "PgNox", "PgToday" };
    string[] tabNames = { "TabMusic", "TabTimer", "TabNox", "TabToday" };
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
      E<TextBlock>("EApp").Foreground = accentBrush;
      LinearGradientBrush bg = new LinearGradientBrush();
      bg.StartPoint = new Point(0.5, 0); bg.EndPoint = new Point(0.5, 1);
      bg.GradientStops.Add(new GradientStop(Colors.Black, 0));
      bg.GradientStops.Add(new GradientStop(Colors.Black, 0.5));
      tintStop = new GradientStop(Colors.Black, 1);
      bg.GradientStops.Add(tintStop);
      bg.MappingMode = BrushMappingMode.RelativeToBoundingBox;
      shape.Fill = bg;
      earL.Fill = Brushes.Black; earR.Fill = Brushes.Black;
      eyeGlow = new DropShadowEffect { BlurRadius = 8, ShadowDepth = 0, Opacity = 0.95, Color = Rgb("#B9B4FF") };
      eyeGlow2 = new DropShadowEffect { BlurRadius = 12, ShadowDepth = 0, Opacity = 0.95, Color = Rgb("#B9B4FF") };

      W = new Spring(160); H = new Spring(34); R = new Spring(16); B = new Spring(0);
      Apply();

      // survol : ouverture rapide, fermeture un peu retardée
      hoverTimer = new DispatcherTimer(DispatcherPriority.Normal, win.Dispatcher);
      hoverTimer.Tick += delegate { hoverTimer.Stop(); SetExpanded(mouseIn || typing); };
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
      Click("BMic", delegate {
        string u = Str(G(sync, "noxUrl"));
        if (u.Length == 0) { ShowPeek(null, "\uE720", "#FFFFFF", "#FF453A", "Nox", "Nox est introuvable", "Vérifie que Tailscale est lancé", 4000, false); Refresh(); return; }
        try { System.Diagnostics.Process.Start(u + "/voix"); } catch (Exception ex) { Log("voix : " + ex.Message); }
      });
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
      UpdateBattery(); UpdateTimer(); ShowPage("PgNox", 0);
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
      bool want = mouseIn || typing;
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
        else if (playing) ShowPage("PgMusic", 0);
        else if (timerEnd.HasValue) ShowPage("PgTimer", 0);
        else ShowPage(PageList()[0], 0);   // rien ne joue : Nox d'abord
      }
      Refresh();
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
      // musique en cours : Musique puis Nox ; sinon Nox en premier
      if (Playing()) { l.Add("PgMusic"); l.Add("PgNox"); }
      else { l.Add("PgNox"); l.Add("PgMusic"); }   // l'onglet Musique reste là pour lancer Spotify
      l.Add("PgTimer"); l.Add("PgToday");
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
      page = name;
      if (name == "PgNox" && expandedOn) noxUnread = false;
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
        tb.Background = on ? Br("#26FFFFFF") : Brushes.Transparent;
        tb.Foreground = on ? (Brush)Br("#FFFFFF") : Br("#8E8E93");
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

    void Tick() {
      tickN++;
      DateTime now = DateTime.Now;
      if (tickN % 60 == 0) Audio.Reset();
      Safe("volume", UpdateVolume);
      Safe("musique", UpdateMedia);
      if (tickN % 5 == 1) Safe("minuteur", UpdateTimer);
      if (dragging && (now - lastDrag).TotalMilliseconds > 450) { dragging = false; peekUntil = DateTime.MinValue; }
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
      E<TextBlock>("CClock").Text = clock; E<TextBlock>("EClock").Text = clock;
      E<TextBlock>("EDate").Text = fr.TextInfo.ToTitleCase(now.ToString("dddd d MMMM", fr));

      double w, h, r, resp, damp, bub = 0; string name;
      if (expandedOn) {
        name = "Expanded";
        List<string> l = PageList();
        if (!l.Contains(page)) ShowPage(l[0], 0);
        else if (string.Join(",", l.ToArray()) != tabOrder) ShowPage(page, 0);
        // la vue ne rétrécit pas tant que la souris est dessus (sinon elle se refermerait sous le curseur)
        string ek = page + "|" + VisKey("NConfirm") + VisKey("NLastBox") + VisKey("EProg") + VisKey("NAct") + VisKey("TMeteo") + VisKey("TAgenda1") + VisKey("TAgenda2");
        if (ek != expKey) { expKey = ek; expanded.Height = double.NaN; expNatural = Math.Ceiling(Natural(expanded, 440).Height); }
        stickyH = Math.Max(stickyH, expNatural);
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
        Vis("CClock", !music && !timerOn && !ev); Vis("CEyes", true);   // le masque de Nox reste aussi pendant la musique
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
        if (ck != compactKey) { compactKey = ck; compactW = Math.Max(150, Math.Ceiling(Natural(compact, double.NaN).Width)); }
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
      if (hasMedia && (playing || name == "Expanded")) { col = accent; level = name == "Compact" ? 0.42 : 0.5; }
      else level = name == "Compact" ? 0.26 : (name == "Expanded" ? 0.34 : 0.18);
      string tk = level + "|" + col;
      if (tk != tintKey) { tintKey = tk; AnimColor(tintStop, GradientStop.ColorProperty, Fx.Shade(col, level), 450); }
    }
    string VisKey(string n) { return E<UIElement>(n).Visibility == Visibility.Visible ? "1" : "0"; }
    void Vis(string n, bool on) { E<UIElement>(n).Visibility = on ? Visibility.Visible : Visibility.Collapsed; }

    void SetEq(bool on) {
      if (eqOn == on) return;
      eqOn = on;
      int[] durs = { 330, 450, 380, 520, 360, 470, 400, 540 };
      string[] names = { "Eq1", "Eq2", "Eq3", "Eq4", "Eq5", "Eq6", "Eq7", "Eq8" };
      for (int i = 0; i < names.Length; i++) {
        ScaleTransform st = (ScaleTransform)E<UIElement>(names[i]).RenderTransform;
        if (on) {
          DoubleAnimation a = new DoubleAnimation(0.25, 1.0, TimeSpan.FromMilliseconds(durs[i]));
          a.AutoReverse = true; a.RepeatBehavior = RepeatBehavior.Forever;
          a.EasingFunction = new SineEase();
          Timeline.SetDesiredFrameRate(a, 30);   // économise la batterie et la fluidité du reste
          st.BeginAnimation(ScaleTransform.ScaleYProperty, a);
        } else Anim(st, ScaleTransform.ScaleYProperty, 0.3, 200, 0, null);
      }
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
        double[] xs = new[] { -1.4, 0, 0, 1.4 };
        double x = busy ? (((TranslateTransform)E<UIElement>("CPupils").RenderTransform).X > 0 ? -1.4 : 1.4) : xs[rnd.Next(xs.Length)];
        foreach (string e in new[] { "CPupils", "PkPupils", "NPupils" })
          Anim((TranslateTransform)E<UIElement>(e).RenderTransform, TranslateTransform.XProperty, x * (e == "NPupils" ? 2.4 : 1), 280, 0, Quint());
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
        Vis("EArtIco", art == null);
        string title = Str(G(md, "title")), artist = Str(G(md, "artist")), app = AppName(Str(G(md, "app")));
        E<TextBlock>("ETitle").Text = title; E<TextBlock>("EArtist").Text = artist; E<TextBlock>("EApp").Text = app;
        SetMarquee(string.IsNullOrEmpty(artist) ? title : title + " · " + artist);
        if (G(md, "color") is Color) { accent = (Color)G(md, "color"); AnimColor(accentBrush, SolidColorBrush.ColorProperty, accent, 600); }
        if (!firstTrack && Bool(G(sync, "playing")) && !expandedOn) ShowPeek(art, "", "#FFFFFF", "#1C1C1E", app, title, artist, 3000, false);
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
      E<TextBlock>("BPlayIco").Text = Bool(G(sync, "playing")) ? "" : "";
      Hashtable tl = G(sync, "timeline") as Hashtable;
      if (md != null && tl != null && Num(G(tl, "end")) > 1) {
        double end = Num(G(tl, "end")), cur = Num(G(tl, "pos"));
        if (Bool(G(sync, "playing")) && G(tl, "at") is DateTime) cur += (DateTime.Now - (DateTime)G(tl, "at")).TotalSeconds;
        cur = Math.Min(cur, end);
        Vis("EProg", true);
        E<ScaleTransform>("EBarScale").ScaleX = Math.Max(0, Math.Min(1, cur / end));
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
      foreach (string mk in new[] { "EyeMask", "PkMask", "NMask" }) {
        Border mb = E<Border>(mk);
        mb.BorderThickness = new Thickness(state == "down" ? (mk == "NMask" ? 2.5 : 1.2) : 0);
      }
      E<UIElement>("CEyes").Opacity = state == "off" ? 0.55 : 1;
      if (n == null || !Bool(G(n, "ok"))) { Vis("NConfirm", false); return; }
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
        E<TextBlock>("NLastTime").Text = Str(G(msg, "heure"));
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
  Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Net.Http
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $refs = @(
    'System.dll',
    [System.Windows.Window].Assembly.Location,
    [System.Windows.Media.Color].Assembly.Location,
    [System.Windows.DependencyObject].Assembly.Location,
    [System.Xaml.XamlReader].Assembly.Location,
    [System.Management.Automation.PSObject].Assembly.Location
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

  $http = New-Object System.Net.Http.HttpClient
  $http.Timeout = [TimeSpan]::FromSeconds(10)
  $http.DefaultRequestHeaders.UserAgent.ParseAdd('MathisDynamicIsland/1.0')
  $updNext = [DateTime]::Now.AddSeconds(15)
  $trackKey = ''
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
            if ($key -ne $trackKey) {
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
              $sync.media = @{ key = $key; title = [string]$p.Title; artist = [string]$p.Artist; app = [string]$sess.SourceAppUserModelId; art = $art; color = $col }
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
  $nextFind = [DateTime]::MinValue; $nextEquipe = [DateTime]::MinValue; $nextWidget = [DateTime]::MinValue
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
            <Border Background="{TemplateBinding Background}" CornerRadius="11" Padding="10,4">
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
          <Grid x:Name="CEyes" Width="24" Height="12" Margin="10,0,0,0" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5">
            <Grid.RenderTransform><RotateTransform/></Grid.RenderTransform>
            <Border x:Name="EyeMask" CornerRadius="6" Background="#F4EFE6" BorderBrush="#FF453A" BorderThickness="0"/>
            <Canvas x:Name="CPupils" Width="24" Height="12">
              <Canvas.RenderTransform><TranslateTransform/></Canvas.RenderTransform>
              <Grid x:Name="EyeL" Width="5.2" Height="5.2" Canvas.Left="3.7" Canvas.Top="3.4" RenderTransformOrigin="0.5,0.5">
                <Grid.RenderTransform><ScaleTransform/></Grid.RenderTransform>
                <Ellipse Fill="#3A3734"/><Ellipse Width="1.6" Height="1.6" Fill="#F4EFE6" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="2.6,0.9,0,0"/>
              </Grid>
              <Grid x:Name="EyeR" Width="5.2" Height="5.2" Canvas.Left="15.1" Canvas.Top="3.4" RenderTransformOrigin="0.5,0.5">
                <Grid.RenderTransform><ScaleTransform/></Grid.RenderTransform>
                <Ellipse Fill="#3A3734"/><Ellipse Width="1.6" Height="1.6" Fill="#F4EFE6" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="2.6,0.9,0,0"/>
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
                  <TextBlock x:Name="EApp" FontSize="11" Margin="0,3,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="2" Orientation="Horizontal" Height="16" VerticalAlignment="Top" Margin="0,4,0,0">
                  <Rectangle x:Name="Eq5" Width="3" Height="16" RadiusX="1.5" RadiusY="1.5" Margin="1,0" RenderTransformOrigin="0.5,0.5"><Rectangle.RenderTransform><ScaleTransform ScaleY="0.4"/></Rectangle.RenderTransform></Rectangle>
                  <Rectangle x:Name="Eq6" Width="3" Height="16" RadiusX="1.5" RadiusY="1.5" Margin="1,0" RenderTransformOrigin="0.5,0.5"><Rectangle.RenderTransform><ScaleTransform ScaleY="0.7"/></Rectangle.RenderTransform></Rectangle>
                  <Rectangle x:Name="Eq7" Width="3" Height="16" RadiusX="1.5" RadiusY="1.5" Margin="1,0" RenderTransformOrigin="0.5,0.5"><Rectangle.RenderTransform><ScaleTransform ScaleY="0.5"/></Rectangle.RenderTransform></Rectangle>
                  <Rectangle x:Name="Eq8" Width="3" Height="16" RadiusX="1.5" RadiusY="1.5" Margin="1,0" RenderTransformOrigin="0.5,0.5"><Rectangle.RenderTransform><ScaleTransform ScaleY="0.3"/></Rectangle.RenderTransform></Rectangle>
                </StackPanel>
              </Grid>
              <DockPanel x:Name="EProg" Margin="0,10,0,0">
                <TextBlock x:Name="EPos" DockPanel.Dock="Left" FontSize="11" Foreground="#AEAEB2" Width="36" VerticalAlignment="Center"/>
                <TextBlock x:Name="ELeft" DockPanel.Dock="Right" FontSize="11" Foreground="#AEAEB2" Width="40" TextAlignment="Right" VerticalAlignment="Center"/>
                <Grid x:Name="EBarHit" VerticalAlignment="Center" Height="16" Background="#00000000" Cursor="Hand">
                  <Border CornerRadius="2" Height="4" Background="#30FFFFFF"/>
                  <Border x:Name="EBar" CornerRadius="2" Height="4" RenderTransformOrigin="0,0.5">
                    <Border.RenderTransform><ScaleTransform x:Name="EBarScale" ScaleX="0"/></Border.RenderTransform>
                  </Border>
                </Grid>
              </DockPanel>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,2,0,0">
                <Button x:Name="BPrev" Style="{StaticResource IconBtn}" Padding="9" Margin="0,0,16,0"><TextBlock Text="&#xE892;" FontFamily="Segoe Fluent Icons" FontSize="16"/></Button>
                <Button x:Name="BPlay" Style="{StaticResource IconBtn}" Padding="9"><TextBlock x:Name="BPlayIco" Text="&#xE769;" FontFamily="Segoe Fluent Icons" FontSize="22"/></Button>
                <Button x:Name="BNext" Style="{StaticResource IconBtn}" Padding="9" Margin="16,0,0,0"><TextBlock Text="&#xE893;" FontFamily="Segoe Fluent Icons" FontSize="16"/></Button>
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
                  <Button x:Name="BMic" DockPanel.Dock="Right" Style="{StaticResource IconBtn}" Padding="7" ToolTip="Parler à Nox"><TextBlock Text="&#xE720;" FontFamily="Segoe Fluent Icons" FontSize="13"/></Button>
                  <Grid VerticalAlignment="Center">
                    <TextBlock x:Name="NPh" Text="Demander à Nox… (ou glisse un fichier sur la pilule)" FontSize="13" Foreground="#8E8E93" IsHitTestVisible="False"/>
                    <TextBox x:Name="NInput" Background="Transparent" BorderThickness="0" Foreground="White" CaretBrush="White" FontSize="13" Padding="-2,0,0,0" FontFamily="Segoe UI Variable Text, Segoe UI"/>
                  </Grid>
                </DockPanel>
              </Border>
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
    </Canvas>
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
