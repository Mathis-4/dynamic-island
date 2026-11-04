# ============================================================
#  Dynamic Island de Mathis - Windows 11
#  Clic droit sur la pilule : version, journal, redémarrer, quitter
# ============================================================
$Version = '2.3'

# ---------- Réglages ----------
$NoxStatusUrl     = ""         # ex. "https://ton-vps/nox/status" (JSON) ; vide = non connecté
$NoxToken         = ""         # facultatif : envoyé en "Authorization: Bearer ..."
$DefaultAccent    = "#8B7CFF"  # couleur quand la pochette n'en donne pas (violet Nox)
$TimerColor       = "#FF9F0A"
$ChargeColor      = "#30D158"
$HideInFullscreen = $true
# ------------------------------

$Here    = Split-Path -Parent $MyInvocation.MyCommand.Path
# Réglages perso (jamais écrasés par les mises à jour) : config.ps1 à côté de ce fichier
$ConfigPath = Join-Path $Here 'config.ps1'
if (Test-Path $ConfigPath) { . $ConfigPath }
$UpdateBase = 'https://raw.githubusercontent.com/Mathis-4/dynamic-island/main'
$LogPath = Join-Path $Here 'island.log'
try { Set-Content -Path $LogPath -Value "Dynamic Island v$Version - $(Get-Date)" -Encoding UTF8 } catch {}
$script:lastLog = ''
function Log($m) {
  if ($m -eq $script:lastLog) { return }
  $script:lastLog = $m
  try { Add-Content -Path $LogPath -Value ("{0:HH:mm:ss} UI  {1}" -f (Get-Date), $m) -Encoding UTF8 } catch {}
}

function Step($m) { if ($sync) { $sync.step = $m }; if (-not $Isl -or $Isl.tick -le 2) { Log ("étape : " + $m) } }

# Une seule instance
$created = $false
$script:mutex = New-Object System.Threading.Mutex($true, "Global\MathisDynamicIsland", [ref]$created)
if (-not $created) { exit }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Net.Http
Add-Type -AssemblyName System.Runtime.WindowsRuntime

# ============================================================
#  Code natif (C#) : volume, fenêtre, ressorts, couleurs
# ============================================================
$refs = @(
  'System.dll',
  [System.Windows.Window].Assembly.Location,
  [System.Windows.Media.Color].Assembly.Location,
  [System.Windows.DependencyObject].Assembly.Location,
  [System.Xaml.XamlReader].Assembly.Location
)
Add-Type -ReferencedAssemblies $refs -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

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
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    public static void NoActivate(IntPtr h) {
      int ex = GetWindowLong(h, -20);
      SetWindowLong(h, -20, ex | 0x08000000 | 0x00000080);
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
  }

  // Ressort amorti façon SwiftUI : response (s) + dampingFraction
  public class Spring {
    public double Value, Velocity, Target, Response = 0.45, Damping = 0.75;
    public Spring(double v) { Value = v; Target = v; }
    public void Step(double dt) {
      double k = Math.Pow(2 * Math.PI / Response, 2);
      double c = 4 * Math.PI * Damping / Response;
      double a = -k * (Value - Target) - c * Velocity;
      Velocity += a * dt; Value += Velocity * dt;
    }
    public bool Settled { get { return Math.Abs(Value - Target) < 0.15 && Math.Abs(Velocity) < 1.0; } }
    public void Snap() { Value = Target; Velocity = 0; }
  }

  // Fait "morpher" la pilule (largeur, hauteur, arrondi) + la bulle à côté
  public class Morph {
    Border pill; FrameworkElement content; Border bubble;
    public Spring W, H, R, B;
    bool running; TimeSpan last;
    public Morph(Border pill, FrameworkElement content, Border bubble, double w, double h) {
      this.pill = pill; this.content = content; this.bubble = bubble;
      W = new Spring(w); H = new Spring(h); R = new Spring(h / 2); B = new Spring(0);
      Apply();
    }
    public void To(double w, double h, double r, double response, double damping) {
      W.Target = w; H.Target = h; R.Target = r;
      W.Response = response; H.Response = response; R.Response = response;
      W.Damping = damping; H.Damping = damping; R.Damping = Math.Min(1.0, damping + 0.1);
      Start();
    }
    public void BubbleTo(double size) { B.Target = size; B.Response = 0.5; B.Damping = 0.68; Start(); }
    void Start() { if (!running) { running = true; last = TimeSpan.Zero; CompositionTarget.Rendering += OnFrame; } }
    void OnFrame(object s, EventArgs e) {
      RenderingEventArgs re = e as RenderingEventArgs;
      double dt = 1.0 / 60;
      if (re != null) {
        if (last != TimeSpan.Zero) dt = (re.RenderingTime - last).TotalSeconds;
        last = re.RenderingTime;
      }
      if (dt <= 0) return;
      if (dt > 0.05) dt = 0.05;
      int n = (int)Math.Ceiling(dt / 0.004); double st = dt / n;
      for (int i = 0; i < n; i++) { W.Step(st); H.Step(st); R.Step(st); B.Step(st); }
      if (W.Settled && H.Settled && R.Settled && B.Settled) {
        W.Snap(); H.Snap(); R.Snap(); B.Snap();
        CompositionTarget.Rendering -= OnFrame; running = false;
      }
      Apply();
    }
    void Apply() {
      double w = Math.Max(20, W.Value), h = Math.Max(20, H.Value);
      double r = Math.Max(0, Math.Min(R.Value, Math.Min(w, h) / 2));
      pill.Width = w; pill.Height = h; pill.CornerRadius = new CornerRadius(r);
      content.Clip = new RectangleGeometry(new Rect(0, 0, w, h), r, r);
      if (bubble != null) {
        double b = Math.Max(0, B.Value);
        bubble.Width = b; bubble.Height = b;
        bubble.CornerRadius = new CornerRadius(b / 2);
        bubble.Margin = new Thickness(Math.Min(8, b * 8 / 36), 0, 0, 0);
        bubble.Opacity = Math.Max(0, Math.Min(1, b / 30));
        bubble.Visibility = b < 0.5 ? Visibility.Collapsed : Visibility.Visible;
      }
    }
  }

  public static class Fx {
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
    // Couleur dominante "vive" d'une pochette (histogramme des teintes pondéré par saturation)
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
    // Arc de progression (minuteur)
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
  }
}
'@

# ============================================================
#  Fil de fond : musique (Windows) + Nox  -> table partagée
# ============================================================
$sync = [hashtable]::Synchronized(@{
  stop = $false; media = $null; playing = $false; timeline = $null; nox = $null
  cmds = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
  logPath = $LogPath; accent = $DefaultAccent
  dir = $Here; version = $Version; updateBase = $UpdateBase; updated = $null
})

$bgScript = {
  param($sync, $noxUrl, $noxToken)
  function BLog($m) { try { Add-Content -Path $sync.logPath -Value ("{0:HH:mm:ss} BG  {1}" -f (Get-Date), $m) -Encoding UTF8 } catch {} }
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
    $null = [Windows.Storage.Streams.DataReader,Windows.Storage.Streams,ContentType=WindowsRuntime]
    $tMgr   = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]
    $tProps = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties,Windows.Media.Control,ContentType=WindowsRuntime]
    $tStream = [Windows.Storage.Streams.IRandomAccessStreamWithContentType]
    $mgr = Await ($tMgr::RequestAsync()) $tMgr
    if ($mgr) { BLog 'musique : connecté au gestionnaire média Windows' } else { BLog 'musique : gestionnaire média introuvable' }
  } catch { BLog ("musique (init) : " + $_.Exception.Message); $mgr = $null }

  $http = New-Object System.Net.Http.HttpClient
  $http.Timeout = [TimeSpan]::FromSeconds(8)
  if ($noxToken) { $http.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $noxToken) }
  $noxNext = [DateTime]::MinValue
  $updNext = [DateTime]::Now.AddSeconds(15)
  $trackKey = ''
  $fallback = [System.Windows.Media.ColorConverter]::ConvertFromString($sync.accent)

  while (-not $sync.stop) {
    try {
      if ($mgr) {
        # session : celle qui joue en priorité
        $sess = $null
        foreach ($x in $mgr.GetSessions()) {
          if ($x.GetPlaybackInfo().PlaybackStatus.ToString() -eq 'Playing') { $sess = $x; break }
        }
        if (-not $sess) { $sess = $mgr.GetCurrentSession() }

        $c = $null
        while ($sync.cmds.TryDequeue([ref]$c)) {
          if ($sess) {
            switch ($c) {
              'play' { $null = $sess.TryTogglePlayPauseAsync() }
              'next' { $null = $sess.TrySkipNextAsync() }
              'prev' { $null = $sess.TrySkipPreviousAsync() }
              default {
                if ($c -like 'seek:*') {
                  $sec = [double]($c.Substring(5)) / 1000
                  $tl0 = $sess.GetTimelineProperties()
                  $null = $sess.TryChangePlaybackPositionAsync([long](($tl0.StartTime.TotalSeconds + $sec) * 10000000))
                }
              }
            }
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
                    $ms = New-Object System.IO.MemoryStream (,$bytes)
                    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
                    $bmp.BeginInit(); $bmp.CacheOption = 'OnLoad'; $bmp.DecodePixelWidth = 160; $bmp.StreamSource = $ms; $bmp.EndInit(); $bmp.Freeze()
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
            $sync.playing = $playing
          } else { $sync.media = $null; $sync.playing = $false; $trackKey = '' }
        } else { $sync.media = $null; $sync.playing = $false; $trackKey = '' }
      }
    } catch {
      $m = "musique : " + $_.Exception.Message
      if ($m -ne $lastErr) { BLog $m; $lastErr = $m }
    }

    if ($noxUrl -and [DateTime]::Now -ge $noxNext) {
      $noxNext = [DateTime]::Now.AddSeconds(20)
      try {
        $r = $http.GetStringAsync($noxUrl)
        if ($r.Wait(8000)) { $sync.nox = @{ ok = $true; json = $r.Result } } else { $sync.nox = @{ ok = $false } }
      } catch { $sync.nox = @{ ok = $false } }
    }
    if (-not $sync.wdDone -and $sync.uiStart -and ([DateTime]::Now - $sync.uiStart).TotalSeconds -gt 6) {
      $sync.wdDone = $true
      if (-not $sync.uiBeat) { BLog "ALERTE : l'interface ne répond pas (aucun cycle depuis 6 s), dernière étape : $($sync.step)" }
      else { BLog "interface OK (dernier cycle il y a $([int]([DateTime]::Now - $sync.uiBeat).TotalMilliseconds) ms, étape : $($sync.step))" }
    }
    # Mises à jour automatiques depuis GitHub (au démarrage puis toutes les 3 h)
    if ($sync.updateBase -and -not $sync.updated -and [DateTime]::Now -ge $updNext) {
      $updNext = [DateTime]::Now.AddHours(3)
      try {
        $vt = $http.GetStringAsync($sync.updateBase + '/version.txt?t=' + [DateTime]::Now.Ticks)
        if ($vt.Wait(10000)) {
          $remote = [version]($vt.Result.Trim())
          if ($remote -gt [version]$sync.version) {
            $dl = $http.GetByteArrayAsync($sync.updateBase + '/island.ps1?t=' + [DateTime]::Now.Ticks)
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
    Start-Sleep -Milliseconds 350
  }
}

$rs = [runspacefactory]::CreateRunspace()
$rs.ApartmentState = 'MTA'
$rs.Open()
$bg = [PowerShell]::Create()
$bg.Runspace = $rs
$null = $bg.AddScript($bgScript).AddArgument($sync).AddArgument($NoxStatusUrl).AddArgument($NoxToken)
$bgHandle = $bg.BeginInvoke()

# ============================================================
#  Interface
# ============================================================
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        Width="640" Height="340" UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="IconBtn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="#00FFFFFF" CornerRadius="22" Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
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
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="#1AFFFFFF" CornerRadius="13" Padding="11,5">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#30FFFFFF"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Background" Value="#45FFFFFF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe UI Variable Text, Segoe UI"/>
      <Setter Property="Foreground" Value="White"/>
    </Style>
  </Window.Resources>

  <StackPanel x:Name="Row" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,8,0,0">
    <Border x:Name="Pill" VerticalAlignment="Top" Width="150" Height="36" CornerRadius="18" RenderTransformOrigin="0.5,0">
      <Border.RenderTransform><ScaleTransform x:Name="PillScale"/></Border.RenderTransform>
      <Grid x:Name="Body">

        <!-- COMPACT -->
        <DockPanel x:Name="Compact" Height="36" VerticalAlignment="Top" Margin="7,0,13,0">
          <Border x:Name="CArtBox" DockPanel.Dock="Left" Width="24" Height="24" CornerRadius="7" Background="#1C1C1E" VerticalAlignment="Center">
            <Border.OpacityMask><VisualBrush><VisualBrush.Visual><Border Width="24" Height="24" CornerRadius="7" Background="Black"/></VisualBrush.Visual></VisualBrush></Border.OpacityMask>
            <Image x:Name="CArt" Stretch="UniformToFill"/>
          </Border>
          <TextBlock x:Name="CTimerIco" DockPanel.Dock="Left" Text="&#xE916;" FontFamily="Segoe Fluent Icons" FontSize="15" Foreground="$TimerColor" VerticalAlignment="Center" Margin="6,0,0,0"/>
          <TextBlock x:Name="CClock" DockPanel.Dock="Left" Margin="7,0,0,0" FontFamily="Segoe UI Variable Display Semibold, Segoe UI Semibold" FontSize="14" VerticalAlignment="Center"/>
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
            <StackPanel x:Name="CEq" Orientation="Horizontal" Height="15" VerticalAlignment="Center" Margin="14,0,0,0">
              <Rectangle x:Name="Eq1" Width="3" Height="15" RadiusX="1.5" RadiusY="1.5" Margin="1,0" RenderTransformOrigin="0.5,0.5"><Rectangle.RenderTransform><ScaleTransform ScaleY="0.35"/></Rectangle.RenderTransform></Rectangle>
              <Rectangle x:Name="Eq2" Width="3" Height="15" RadiusX="1.5" RadiusY="1.5" Margin="1,0" RenderTransformOrigin="0.5,0.5"><Rectangle.RenderTransform><ScaleTransform ScaleY="0.7"/></Rectangle.RenderTransform></Rectangle>
              <Rectangle x:Name="Eq3" Width="3" Height="15" RadiusX="1.5" RadiusY="1.5" Margin="1,0" RenderTransformOrigin="0.5,0.5"><Rectangle.RenderTransform><ScaleTransform ScaleY="0.5"/></Rectangle.RenderTransform></Rectangle>
              <Rectangle x:Name="Eq4" Width="3" Height="15" RadiusX="1.5" RadiusY="1.5" Margin="1,0" RenderTransformOrigin="0.5,0.5"><Rectangle.RenderTransform><ScaleTransform ScaleY="0.4"/></Rectangle.RenderTransform></Rectangle>
            </StackPanel>
            <TextBlock x:Name="CTimer" Margin="14,0,0,0" FontFamily="Segoe UI Variable Display Semibold, Segoe UI Semibold" FontSize="14" Foreground="$TimerColor" VerticalAlignment="Center"/>
            <StackPanel x:Name="CBatt" Orientation="Horizontal" Margin="16,0,0,0" VerticalAlignment="Center">
              <TextBlock x:Name="CBattTxt" FontSize="12" Foreground="#C7C7CC" VerticalAlignment="Center" Margin="0,0,5,0"/>
              <TextBlock x:Name="CBattIco" FontFamily="Segoe Fluent Icons" FontSize="15" VerticalAlignment="Center"/>
            </StackPanel>
            <Ellipse x:Name="CNox" Width="7" Height="7" Margin="9,0,0,0" Fill="#48484A" VerticalAlignment="Center"/>
          </StackPanel>
          <Border/>
        </DockPanel>

        <!-- TOAST (volume, charge...) -->
        <DockPanel x:Name="Toast" Height="38" VerticalAlignment="Top" Margin="14,0,16,0" Opacity="0" IsHitTestVisible="False">
          <TextBlock x:Name="TIco" DockPanel.Dock="Left" FontFamily="Segoe Fluent Icons" FontSize="17" VerticalAlignment="Center" Width="22"/>
          <TextBlock x:Name="TRight" DockPanel.Dock="Right" FontFamily="Segoe UI Variable Display Semibold, Segoe UI Semibold" FontSize="13" VerticalAlignment="Center" Margin="12,0,0,0" MinWidth="26" TextAlignment="Right"/>
          <Grid VerticalAlignment="Center" Margin="12,0,0,0">
            <TextBlock x:Name="TText" FontSize="13" TextTrimming="CharacterEllipsis"/>
            <Border x:Name="TBarBg" Height="6" CornerRadius="3" Background="#33FFFFFF" Width="170" HorizontalAlignment="Left">
              <Border x:Name="TBar" Height="6" CornerRadius="3" Background="White" HorizontalAlignment="Left" Width="0"/>
            </Border>
          </Grid>
        </DockPanel>

        <!-- PEEK (nouveau titre, message de Nox, minuteur fini) -->
        <Grid x:Name="Peek" VerticalAlignment="Top" HorizontalAlignment="Left" Margin="12,12,18,12" Opacity="0" IsHitTestVisible="False">
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <Border x:Name="PArtBox" Width="44" Height="44" CornerRadius="11" Background="#1C1C1E">
            <Border.OpacityMask><VisualBrush><VisualBrush.Visual><Border Width="44" Height="44" CornerRadius="11" Background="Black"/></VisualBrush.Visual></VisualBrush></Border.OpacityMask>
            <Grid>
              <TextBlock x:Name="PIco" FontFamily="Segoe Fluent Icons" FontSize="20" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              <Image x:Name="PArt" Stretch="UniformToFill"/>
            </Grid>
          </Border>
          <StackPanel Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center" MaxWidth="280">
            <TextBlock x:Name="PTitle" FontFamily="Segoe UI Variable Display Semibold, Segoe UI Semibold" FontSize="14.5" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="PSub" FontSize="12.5" Foreground="#A1A1A6" TextTrimming="CharacterEllipsis" Margin="0,1,0,0"/>
          </StackPanel>
        </Grid>

        <!-- ETENDU (survol) -->
        <StackPanel x:Name="Expanded" VerticalAlignment="Top" Width="392" Margin="20,18,20,16" HorizontalAlignment="Left" Opacity="0" IsHitTestVisible="False">

          <Grid x:Name="EMedia">
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Border x:Name="EArtBox" Width="68" Height="68" CornerRadius="15" Background="#1C1C1E">
              <Border.OpacityMask><VisualBrush><VisualBrush.Visual><Border Width="68" Height="68" CornerRadius="15" Background="Black"/></VisualBrush.Visual></VisualBrush></Border.OpacityMask>
              <Grid>
                <TextBlock Text="&#xEC4F;" FontFamily="Segoe Fluent Icons" FontSize="26" Foreground="#636366" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                <Image x:Name="EArt" Stretch="UniformToFill"/>
              </Grid>
            </Border>
            <StackPanel Grid.Column="1" Margin="14,0,8,0" VerticalAlignment="Center">
              <TextBlock x:Name="ETitle" FontFamily="Segoe UI Variable Display Semibold, Segoe UI Semibold" FontSize="17" TextTrimming="CharacterEllipsis"/>
              <TextBlock x:Name="EArtist" FontSize="13.5" Foreground="#C7C7CC" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
              <TextBlock x:Name="EApp" FontSize="11.5" Margin="0,4,0,0"/>
            </StackPanel>
            <StackPanel x:Name="EEq" Grid.Column="2" Orientation="Horizontal" Height="18" VerticalAlignment="Top" Margin="0,4,0,0">
              <Rectangle x:Name="Eq5" Width="3" Height="18" RadiusX="1.5" RadiusY="1.5" Margin="1,0" RenderTransformOrigin="0.5,0.5"><Rectangle.RenderTransform><ScaleTransform ScaleY="0.4"/></Rectangle.RenderTransform></Rectangle>
              <Rectangle x:Name="Eq6" Width="3" Height="18" RadiusX="1.5" RadiusY="1.5" Margin="1,0" RenderTransformOrigin="0.5,0.5"><Rectangle.RenderTransform><ScaleTransform ScaleY="0.7"/></Rectangle.RenderTransform></Rectangle>
              <Rectangle x:Name="Eq7" Width="3" Height="18" RadiusX="1.5" RadiusY="1.5" Margin="1,0" RenderTransformOrigin="0.5,0.5"><Rectangle.RenderTransform><ScaleTransform ScaleY="0.5"/></Rectangle.RenderTransform></Rectangle>
              <Rectangle x:Name="Eq8" Width="3" Height="18" RadiusX="1.5" RadiusY="1.5" Margin="1,0" RenderTransformOrigin="0.5,0.5"><Rectangle.RenderTransform><ScaleTransform ScaleY="0.3"/></Rectangle.RenderTransform></Rectangle>
            </StackPanel>
          </Grid>

          <DockPanel x:Name="EProg" Margin="0,16,0,0">
            <TextBlock x:Name="EPos" DockPanel.Dock="Left" FontSize="11" Foreground="#A1A1A6" Width="38" VerticalAlignment="Center"/>
            <TextBlock x:Name="ELeft" DockPanel.Dock="Right" FontSize="11" Foreground="#A1A1A6" Width="38" TextAlignment="Right" VerticalAlignment="Center"/>
            <Grid x:Name="EBarHit" VerticalAlignment="Center" Height="14" Background="#00000000" Cursor="Hand">
              <Border CornerRadius="2.5" Height="5" Background="#30FFFFFF"/>
              <Border x:Name="EBar" CornerRadius="2.5" Height="5" RenderTransformOrigin="0,0.5">
                <Border.RenderTransform><ScaleTransform x:Name="EBarScale" ScaleX="0"/></Border.RenderTransform>
              </Border>
            </Grid>
          </DockPanel>

          <StackPanel x:Name="ECtrl" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,8,0,0">
            <Button x:Name="BPrev" Style="{StaticResource IconBtn}" Padding="11" Margin="0,0,18,0"><TextBlock Text="&#xE892;" FontFamily="Segoe Fluent Icons" FontSize="19"/></Button>
            <Button x:Name="BPlay" Style="{StaticResource IconBtn}" Padding="11"><TextBlock x:Name="BPlayIco" Text="&#xE769;" FontFamily="Segoe Fluent Icons" FontSize="27"/></Button>
            <Button x:Name="BNext" Style="{StaticResource IconBtn}" Padding="11" Margin="18,0,0,0"><TextBlock Text="&#xE893;" FontFamily="Segoe Fluent Icons" FontSize="19"/></Button>
          </StackPanel>

          <StackPanel x:Name="EClockBox" Orientation="Horizontal">
            <TextBlock x:Name="EClock" FontFamily="Segoe UI Variable Display Semibold, Segoe UI Semibold" FontSize="42"/>
            <StackPanel Margin="16,0,0,0" VerticalAlignment="Center">
              <TextBlock x:Name="EDate" FontSize="14.5" Foreground="#E5E5EA"/>
              <TextBlock Text="Rien en lecture" FontSize="12.5" Foreground="#8E8E93" Margin="0,2,0,0"/>
            </StackPanel>
          </StackPanel>

          <Border Margin="0,14,0,0" CornerRadius="14" Background="#14FFFFFF" Padding="13,9">
            <DockPanel>
              <Ellipse x:Name="ENoxDot" DockPanel.Dock="Left" Width="9" Height="9" Fill="#48484A" VerticalAlignment="Center"/>
              <TextBlock DockPanel.Dock="Left" Text="Nox" Margin="9,0,9,0" FontFamily="Segoe UI Variable Text Semibold, Segoe UI Semibold" FontSize="13" VerticalAlignment="Center"/>
              <TextBlock x:Name="ENoxTxt" FontSize="12.5" Foreground="#A1A1A6" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
            </DockPanel>
          </Border>

          <DockPanel Margin="2,12,0,0" LastChildFill="False">
            <StackPanel DockPanel.Dock="Left" Orientation="Horizontal" VerticalAlignment="Center">
              <TextBlock x:Name="EBattIco" FontFamily="Segoe Fluent Icons" FontSize="16" VerticalAlignment="Center"/>
              <TextBlock x:Name="EBattTxt" FontSize="12.5" Foreground="#C7C7CC" Margin="7,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
              <TextBlock x:Name="ETimerTxt" FontFamily="Segoe UI Variable Display Semibold, Segoe UI Semibold" FontSize="14" Foreground="$TimerColor" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <Button x:Name="BT25" Style="{StaticResource Chip}" Margin="0,0,6,0"><TextBlock Text="Focus 25 min" FontSize="12"/></Button>
              <Button x:Name="BT5" Style="{StaticResource Chip}" Margin="0,0,0,0"><TextBlock Text="Pause 5 min" FontSize="12"/></Button>
              <Button x:Name="BTStop" Style="{StaticResource Chip}"><TextBlock Text="Arrêter" FontSize="12" Foreground="$TimerColor"/></Button>
            </StackPanel>
          </DockPanel>
        </StackPanel>

      </Grid>
    </Border>

    <!-- Bulle (2e activité, ex. minuteur pendant la musique) -->
    <Border x:Name="Bubble" Background="#000000" VerticalAlignment="Top" Width="0" Height="0" Visibility="Collapsed">
      <Grid Width="36" Height="36" HorizontalAlignment="Center" VerticalAlignment="Center">
        <Ellipse Width="26" Height="26" Stroke="#33FF9F0A" StrokeThickness="3"/>
        <Path x:Name="Ring" Width="26" Height="26" Stroke="$TimerColor" StrokeThickness="3" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
        <TextBlock x:Name="RingTxt" FontSize="10" FontFamily="Segoe UI Variable Display Semibold, Segoe UI Semibold" Foreground="$TimerColor" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Grid>
    </Border>
  </StackPanel>
</Window>
"@

try { $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml)) }
catch { Log ("XAML : " + $_.Exception.InnerException.Message + " | " + $_.Exception.Message); exit }
$ui = @{}
foreach ($n in 'Row','Pill','PillScale','Body','Compact','CArtBox','CArt','CTimerIco','CClock','CEq','Eq1','Eq2','Eq3','Eq4','CTimer','CBatt','CBattTxt','CBattIco','CNox',
               'Toast','TIco','TRight','TText','TBarBg','TBar','Peek','PArtBox','PIco','PArt','PTitle','PSub',
               'Expanded','EMedia','EArtBox','EArt','ETitle','EArtist','EApp','EEq','Eq5','Eq6','Eq7','Eq8','EProg','EBarHit','EPos','ELeft','EBar','EBarScale','ECtrl',
               'BPrev','BPlay','BPlayIco','BNext','EClockBox','EClock','EDate','ENoxDot','ENoxTxt','EBattIco','EBattTxt','ETimerTxt','BT25','BT5','BTStop',
               'Bubble','Ring','RingTxt') {
  $ui[$n] = $win.FindName($n)
}

$fr = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
function ToColor($hex) { [System.Windows.Media.ColorConverter]::ConvertFromString($hex) }
function NewBrush($hex) { New-Object System.Windows.Media.SolidColorBrush (ToColor $hex) }

$PropWidth   = [System.Windows.FrameworkElement]::WidthProperty
$PropOpacity = [System.Windows.UIElement]::OpacityProperty
$PropScaleX  = [System.Windows.Media.ScaleTransform]::ScaleXProperty
$PropScaleY  = [System.Windows.Media.ScaleTransform]::ScaleYProperty
$PropBlur    = [System.Windows.Media.Effects.BlurEffect]::RadiusProperty
$PropColor   = [System.Windows.Media.SolidColorBrush]::ColorProperty
$PropStop    = [System.Windows.Media.GradientStop]::ColorProperty
$PropFxColor = [System.Windows.Media.Effects.DropShadowEffect]::ColorProperty
$PropFxOp    = [System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty

# Pinceaux vivants (animés quand la pochette change)
$AccentBrush = NewBrush $DefaultAccent
$TintStop  = New-Object System.Windows.Media.GradientStop ((ToColor '#000000'), 0)
$BlackStop = New-Object System.Windows.Media.GradientStop ((ToColor '#000000'), 0.85)
$PillBg = New-Object System.Windows.Media.LinearGradientBrush
$PillBg.StartPoint = New-Object System.Windows.Point(0, 0)
$PillBg.EndPoint   = New-Object System.Windows.Point(0.35, 1)
$PillBg.GradientStops.Add($TintStop); $PillBg.GradientStops.Add($BlackStop)
$ui.Pill.Background = $PillBg
$Glow = New-Object System.Windows.Media.Effects.DropShadowEffect
$Glow.BlurRadius = 26; $Glow.ShadowDepth = 3; $Glow.Direction = 270; $Glow.Opacity = 0.45; $Glow.Color = ToColor '#000000'
$ui.Pill.Effect = $Glow
$ui.Bubble.Effect = (New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{ BlurRadius = 20; ShadowDepth = 3; Direction = 270; Opacity = 0.4; Color = (ToColor '#000000') })
foreach ($e in 'Eq1','Eq2','Eq3','Eq4','Eq5','Eq6','Eq7','Eq8') { $ui[$e].Fill = $AccentBrush }
$ui.EBar.Background = $AccentBrush
$ui.EApp.Foreground = $AccentBrush

$Layers = 'Compact','Toast','Peek','Expanded'
foreach ($l in $Layers) {
  $ui[$l].RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
  $ui[$l].RenderTransform = New-Object System.Windows.Media.ScaleTransform(1, 1)
  $ui[$l].Effect = New-Object System.Windows.Media.Effects.BlurEffect -Property @{ Radius = 0 }
}

$Morph = New-Object Island.Morph($ui.Pill, $ui.Body, $ui.Bubble, 150, 36)

# ---------- Etat ----------
$Isl = @{
  layer = 'Compact'; target = ''
  overSince = $null; outSince = $null; expanded = $false
  toastUntil = [DateTime]::MinValue; peekUntil = [DateTime]::MinValue
  trackKey = ''; firstTrack = $true; accent = (ToColor $DefaultAccent)
  timerEnd = $null; timerTotal = 1; timerLabel = ''
  vol = -2; muted = $null; power = $null; lowWarned = $false
  noxNotifId = $null; noxSeen = $false
  tick = 0; eqOn = $false; hidden = $false; tinted = $null; hwnd = [IntPtr]::Zero
}

# ---------- Animations utilitaires ----------
function Ease($kind) {
  if ($kind -eq 'back') { $e = New-Object System.Windows.Media.Animation.BackEase; $e.Amplitude = 0.3 }
  else { $e = New-Object System.Windows.Media.Animation.CubicEase }
  $e.EasingMode = 'EaseOut'; return $e
}
function AnimD($target, $prop, [double]$to, [int]$ms, [int]$delay = 0, $ease = 'cubic') {
  $a = New-Object System.Windows.Media.Animation.DoubleAnimation
  $a.To = $to
  $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($ms))
  if ($delay -gt 0) { $a.BeginTime = [TimeSpan]::FromMilliseconds($delay) }
  $a.EasingFunction = Ease $ease
  $target.BeginAnimation($prop, $a)
}
function AnimC($target, $prop, $color, [int]$ms) {
  $a = New-Object System.Windows.Media.Animation.ColorAnimation
  $a.To = $color
  $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($ms))
  $a.EasingFunction = Ease 'cubic'
  $target.BeginAnimation($prop, $a)
}

function Switch-Layer($name) {
  if ($Isl.layer -eq $name) { return }
  $Isl.layer = $name
  foreach ($l in $Layers) {
    $el = $ui[$l]; $on = ($l -eq $name)
    $el.IsHitTestVisible = $on
    if ($on) {
      $el.RenderTransform.BeginAnimation($PropScaleX, $null); $el.RenderTransform.BeginAnimation($PropScaleY, $null)
      $el.RenderTransform.ScaleX = 0.9; $el.RenderTransform.ScaleY = 0.9
      AnimD $el $PropOpacity 1 260 70
      AnimD $el.RenderTransform $PropScaleX 1 420 40 'back'
      AnimD $el.RenderTransform $PropScaleY 1 420 40 'back'
      AnimD $el.Effect $PropBlur 0 300 40
    } else {
      AnimD $el $PropOpacity 0 120
      AnimD $el.RenderTransform $PropScaleX 0.94 180
      AnimD $el.RenderTransform $PropScaleY 0.94 180
      AnimD $el.Effect $PropBlur 10 140
    }
  }
}

function Measure-Layer($el) {
  $el.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
  return $el.DesiredSize
}

function Set-Eq([bool]$on) {
  if ($Isl.eqOn -eq $on) { return }
  $Isl.eqOn = $on
  $durs = 330, 450, 380, 520, 360, 470, 400, 540
  $i = 0
  foreach ($e in 'Eq1','Eq2','Eq3','Eq4','Eq5','Eq6','Eq7','Eq8') {
    $st = $ui[$e].RenderTransform
    if ($on) {
      $a = New-Object System.Windows.Media.Animation.DoubleAnimation
      $a.From = 0.25; $a.To = 1.0; $a.AutoReverse = $true
      $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($durs[$i]))
      $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
      $a.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
      $st.BeginAnimation($PropScaleY, $a)
    } else {
      AnimD $st $PropScaleY 0.3 250
    }
    $i++
  }
}

function Set-Accent($color) {
  $Isl.accent = $color
  AnimC $AccentBrush $PropColor $color 700
  $Isl.tinted = $null   # force la mise à jour du fond
}

# ---------- Toast / Peek ----------
function Show-Toast($icon, $text, $right, $color, [double]$bar = -1, [int]$ms = 1600) {
  $ui.TIco.Text = $icon
  $ui.TIco.Foreground = NewBrush $color
  $ui.TRight.Text = $right
  if ($bar -ge 0) {
    $ui.TText.Visibility = 'Collapsed'; $ui.TBarBg.Visibility = 'Visible'
    $ui.TBar.Background = NewBrush $color
    AnimD $ui.TBar $PropWidth ([math]::Max(0, [math]::Min(1, $bar)) * 170) 180
  } else {
    $ui.TText.Visibility = 'Visible'; $ui.TBarBg.Visibility = 'Collapsed'
    $ui.TText.Text = $text
  }
  $Isl.toastUntil = (Get-Date).AddMilliseconds($ms)
}
function Show-Peek($art, $icon, $iconColor, $title, $sub, [int]$ms = 3200) {
  $ui.PArt.Source = $art
  $ui.PIco.Text = $icon
  $ui.PIco.Foreground = NewBrush $iconColor
  $ui.PArtBox.Background = if ($art) { NewBrush '#1C1C1E' } else { NewBrush '#2C2C2E' }
  $ui.PTitle.Text = $title
  $ui.PSub.Text = $sub
  $ui.PSub.Visibility = if ($sub) { 'Visible' } else { 'Collapsed' }
  $Isl.peekUntil = (Get-Date).AddMilliseconds($ms)
}

# ---------- Batterie ----------
function Batt-Glyph([int]$pct, [bool]$charging) {
  $i = [int][math]::Round($pct / 10.0)
  if ($charging) { if ($i -ge 10) { return [string][char]0xEA93 } elseif ($i -eq 9) { return [string][char]0xE83E } else { return [string][char](0xE85A + $i) } }
  else { if ($i -ge 10) { return [string][char]0xE83F } else { return [string][char](0xE850 + $i) } }
}
function Update-Battery {
  $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
  if (($ps.BatteryChargeStatus -band [System.Windows.Forms.BatteryChargeStatus]::NoSystemBattery) -ne 0) { $ui.CBatt.Visibility = 'Collapsed'; return }
  $pct = [int][math]::Round($ps.BatteryLifePercent * 100)
  $online = ($ps.PowerLineStatus -eq [System.Windows.Forms.PowerLineStatus]::Online)
  $g = Batt-Glyph $pct $online
  $ui.CBattIco.Text = $g; $ui.EBattIco.Text = $g
  $ui.CBattTxt.Text = "$pct%"
  $col = if ($online) { $ChargeColor } elseif ($pct -le 20) { '#FF453A' } else { '#FFFFFF' }
  $ui.CBattIco.Foreground = NewBrush $col; $ui.EBattIco.Foreground = NewBrush $col
  $ui.EBattTxt.Text = if ($online) { "$pct % · en charge" } else { "$pct %" }
  if ($null -ne $Isl.power -and $Isl.power -ne $online) {
    if ($online) { Show-Toast $g 'En charge' "$pct%" $ChargeColor -ms 2200 } else { Show-Toast $g 'Sur batterie' "$pct%" '#FFFFFF' -ms 2200 }
  }
  $Isl.power = $online
  if (-not $online -and $pct -le 20 -and -not $Isl.lowWarned) { $Isl.lowWarned = $true; Show-Toast $g 'Batterie faible' "$pct%" '#FF453A' -ms 3500 }
  if ($online) { $Isl.lowWarned = $false }
}

# ---------- Volume ----------
function Update-Volume {
  $v = [Island.Audio]::Level()
  if ($v -lt 0) { return }
  $m = [Island.Audio]::Muted()
  $changed = ($Isl.vol -ge 0) -and (([math]::Abs($v - $Isl.vol) -gt 0.004) -or ($m -ne $Isl.muted))
  $Isl.vol = $v; $Isl.muted = $m
  if ($changed) {
    $pct = [int][math]::Round($v * 100)
    if ($m) { Show-Toast ([string][char]0xE74F) '' 'Muet' '#8E8E93' 0 }
    else {
      $ico = if ($pct -eq 0) { [char]0xE992 } elseif ($pct -lt 34) { [char]0xE993 } elseif ($pct -lt 67) { [char]0xE994 } else { [char]0xE995 }
      Show-Toast ([string]$ico) '' "$pct" '#FFFFFF' $v
    }
  }
}

# ---------- Musique (lecture de la table partagée) ----------
function App-Name($id) {
  if (-not $id) { return '' }
  $l = $id.ToLower()
  if ($l -like '*spotify*') { 'Spotify' } elseif ($l -like '*chrome*') { 'Chrome' } elseif ($l -like '*msedge*') { 'Edge' }
  elseif ($l -like '*firefox*') { 'Firefox' } elseif ($l -like '*deezer*') { 'Deezer' } elseif ($l -like '*zune*' -or $l -like '*media*') { 'Lecteur multimédia' }
  else { (($id -split '[\\!]')[-1]) -replace '\.exe$','' }
}
function Fmt([double]$sec) { if ($sec -lt 0) { $sec = 0 }; $t = [TimeSpan]::FromSeconds([math]::Floor($sec)); if ($t.TotalHours -ge 1) { $t.ToString('h\:mm\:ss') } else { '{0}:{1:00}' -f [int][math]::Floor($t.TotalMinutes), $t.Seconds } }

function Update-Media {
  $md = $sync.media
  if ($md -and $md.key -ne $Isl.trackKey) {
    $Isl.trackKey = $md.key
    $ui.CArt.Source = $md.art; $ui.EArt.Source = $md.art
    $ui.ETitle.Text = $md.title; $ui.EArtist.Text = $md.artist
    $ui.EApp.Text = App-Name $md.app
    Set-Accent $md.color
    if (-not $Isl.firstTrack -and $sync.playing) { Show-Peek $md.art '' '#FFFFFF' $md.title $md.artist 3200 }
    $Isl.firstTrack = $false
  }
  if (-not $md) { $Isl.trackKey = '' }
  $ui.BPlayIco.Text = if ($sync.playing) { [string][char]0xE769 } else { [string][char]0xE768 }
  # progression
  $tl = $sync.timeline
  if ($md -and $tl -and $tl.end -gt 1) {
    $cur = $tl.pos
    if ($sync.playing) { $cur += ([DateTime]::Now - $tl.at).TotalSeconds }
    $cur = [math]::Min($cur, $tl.end)
    $ui.EProg.Visibility = 'Visible'
    $ui.EBarScale.ScaleX = [math]::Max(0, [math]::Min(1, $cur / $tl.end))
    $ui.EPos.Text = Fmt $cur
    $ui.ELeft.Text = '-' + (Fmt ($tl.end - $cur))
  } else { $ui.EProg.Visibility = 'Collapsed' }
}
function Media-Do($what) { $sync.cmds.Enqueue($what) }

# ---------- Nox ----------
function Set-Nox($state, $text) {
  $col = switch ($state) { 'online' { '#30D158' } 'busy' { $null } 'down' { '#FF453A' } default { '#48484A' } }
  if ($state -eq 'busy') { $ui.CNox.Fill = $AccentBrush; $ui.ENoxDot.Fill = $AccentBrush }
  else { $ui.CNox.Fill = NewBrush $col; $ui.ENoxDot.Fill = NewBrush $col }
  $ui.ENoxTxt.Text = $text
}
function Update-Nox {
  if (-not $NoxStatusUrl) { Set-Nox 'off' 'pas encore relié à la pilule'; return }
  $n = $sync.nox
  if (-not $n) { Set-Nox 'off' 'connexion…'; return }
  if (-not $n.ok) { Set-Nox 'down' 'injoignable'; return }
  try {
    $j = $n.json | ConvertFrom-Json
    if ($j.statut -eq 'occupe' -or $j.statut -eq 'occupé') { Set-Nox 'busy' ("en cours : " + $j.tache) }
    else { Set-Nox 'online' $(if ($j.tache) { [string]$j.tache } else { 'en ligne' }) }
    if ($j.notification -and $j.notification.id -and $j.notification.id -ne $Isl.noxNotifId) {
      $first = -not $Isl.noxSeen
      $Isl.noxNotifId = $j.notification.id
      if (-not $first) { Show-Peek $null ([string][char]0xE8BD) $DefaultAccent 'Nox' ([string]$j.notification.texte) 5000 }
    }
    $Isl.noxSeen = $true
  } catch { Set-Nox 'down' 'réponse illisible' }
}

# ---------- Minuteur ----------
function Start-Timer([int]$min, $label) { $Isl.timerEnd = (Get-Date).AddMinutes($min); $Isl.timerTotal = $min * 60; $Isl.timerLabel = $label }
function Update-Timer {
  if (-not $Isl.timerEnd) {
    $ui.CTimer.Text = ''; $ui.ETimerTxt.Text = ''
    $ui.BTStop.Visibility = 'Collapsed'; $ui.BT25.Visibility = 'Visible'; $ui.BT5.Visibility = 'Visible'
    return
  }
  $left = $Isl.timerEnd - (Get-Date)
  if ($left.TotalSeconds -le 0) {
    $lbl = $Isl.timerLabel; $Isl.timerEnd = $null
    [System.Media.SystemSounds]::Asterisk.Play()
    Show-Peek $null ([string][char]0xE916) $TimerColor "$lbl terminé" $(if ($lbl -eq 'Focus') { 'Prends une pause de 5 min' } else { 'On reprend ?' }) 6000
    Update-Timer; return
  }
  $txt = '{0:00}:{1:00}' -f [int][math]::Floor($left.TotalMinutes), $left.Seconds
  $ui.CTimer.Text = $txt; $ui.ETimerTxt.Text = "$($Isl.timerLabel) · $txt"
  $ui.RingTxt.Text = [string][int][math]::Ceiling($left.TotalMinutes)
  $ui.Ring.Data = [Island.Fx]::Arc(26, 3, ($left.TotalSeconds / $Isl.timerTotal))
  $ui.BTStop.Visibility = 'Visible'; $ui.BT25.Visibility = 'Collapsed'; $ui.BT5.Visibility = 'Collapsed'
}

# ---------- Etat -> forme ----------
function Update-Layout {
  $now = Get-Date
  $md = $sync.media
  $hasMedia = ($null -ne $md)
  $playing = $hasMedia -and $sync.playing
  $timerOn = ($null -ne $Isl.timerEnd)

  $ui.CClock.Text = $now.ToString('HH:mm'); $ui.EClock.Text = $now.ToString('HH:mm')
  $ui.EDate.Text = $fr.TextInfo.ToTitleCase($now.ToString('dddd d MMMM', $fr))

  # survol avec intention (pas d'ouverture si on passe juste la souris)
  $over = $ui.Pill.IsMouseOver -or $menu.IsOpen
  if ($over) { $Isl.outSince = $null; if (-not $Isl.overSince) { $Isl.overSince = $now } }
  else { $Isl.overSince = $null; if (-not $Isl.outSince) { $Isl.outSince = $now } }
  if ($Isl.expanded) { if ($Isl.outSince -and ($now - $Isl.outSince).TotalMilliseconds -gt 350) { $Isl.expanded = $false } }
  else { if ($Isl.overSince -and ($now - $Isl.overSince).TotalMilliseconds -ge 140) { $Isl.expanded = $true } }

  $bubble = 0
  if ($Isl.expanded) {
    $layer = 'Expanded'
    $ui.EMedia.Visibility = if ($hasMedia) { 'Visible' } else { 'Collapsed' }
    $ui.ECtrl.Visibility  = if ($hasMedia) { 'Visible' } else { 'Collapsed' }
    if (-not $hasMedia) { $ui.EProg.Visibility = 'Collapsed' }
    $ui.EClockBox.Visibility = if ($hasMedia) { 'Collapsed' } else { 'Visible' }
    $sz = Measure-Layer $ui.Expanded
    $w = 432; $h = [math]::Ceiling($sz.Height); $r = 34; $resp = 0.5; $damp = 0.74
  } elseif ($now -lt $Isl.toastUntil) {
    $layer = 'Toast'; $w = 300; $h = 38; $r = 19; $resp = 0.42; $damp = 0.72
  } elseif ($now -lt $Isl.peekUntil) {
    $layer = 'Peek'
    $sz = Measure-Layer $ui.Peek
    $w = [math]::Max(260, [math]::Ceiling($sz.Width)); $h = [math]::Ceiling($sz.Height); $r = 26; $resp = 0.48; $damp = 0.72
  } else {
    $layer = 'Compact'
    $musicMode = $playing
    $ui.CArtBox.Visibility   = if ($musicMode) { 'Visible' } else { 'Collapsed' }
    $ui.CEq.Visibility       = if ($musicMode) { 'Visible' } else { 'Collapsed' }
    $ui.CTimerIco.Visibility = if ($timerOn -and -not $musicMode) { 'Visible' } else { 'Collapsed' }
    $ui.CTimer.Visibility    = if ($timerOn -and -not $musicMode) { 'Visible' } else { 'Collapsed' }
    $ui.CClock.Visibility    = if ($musicMode -or $timerOn) { 'Collapsed' } else { 'Visible' }
    $ui.CBatt.Visibility     = if ($musicMode -or $timerOn) { 'Collapsed' } else { 'Visible' }
    $ui.CNox.Visibility      = if ($musicMode) { 'Collapsed' } else { 'Visible' }
    $sz = Measure-Layer $ui.Compact
    $w = [math]::Max(120, [math]::Ceiling($sz.Width)); $h = 36; $r = 18
    if ($musicMode) { $w = [math]::Max($w, 200) }
    $resp = 0.42; $damp = 0.82
    if ($musicMode -and $timerOn) { $bubble = 36 }
  }

  Set-Eq $playing

  $key = "$layer|$w|$h|$bubble"
  if ($key -ne $Isl.target) {
    $Isl.target = $key
    $Morph.To($w, $h, $r, $resp, $damp)
    $Morph.BubbleTo($bubble)
  }
  Switch-Layer $layer

  # teinte façon Apple Music : fond légèrement coloré quand la pilule est ouverte sur un morceau
  $tint = ($hasMedia -and ($layer -eq 'Expanded' -or ($layer -eq 'Peek' -and $ui.PArt.Source)))
  $tintKey = "$tint|$($Isl.accent)"
  if ($tintKey -ne $Isl.tinted) {
    $Isl.tinted = $tintKey
    if ($tint) {
      AnimC $TintStop $PropStop ([Island.Fx]::Shade($Isl.accent, 0.42)) 500
      AnimC $Glow $PropFxColor ([Island.Fx]::Shade($Isl.accent, 0.8)) 500
      AnimD $Glow $PropFxOp 0.55 500
    } else {
      AnimC $TintStop $PropStop (ToColor '#000000') 400
      AnimC $Glow $PropFxColor (ToColor '#000000') 400
      AnimD $Glow $PropFxOp 0.45 400
    }
  }
}

# ---------- Evénements ----------
$ui.BPlay.Add_Click({ Media-Do 'play' })
$ui.BNext.Add_Click({ Media-Do 'next' })
$ui.BPrev.Add_Click({ Media-Do 'prev' })
$ui.EBarHit.Add_MouseLeftButtonUp({
  param($sender, $e)
  $tl = $sync.timeline
  if ($tl -and $tl.end -gt 1) {
    $frac = [math]::Max(0, [math]::Min(1, $e.GetPosition($ui.EBarHit).X / $ui.EBarHit.ActualWidth))
    Media-Do ("seek:" + [int]($frac * $tl.end * 1000))
    $sync.timeline = @{ pos = $frac * $tl.end; end = $tl.end; at = [DateTime]::Now }
  }
})
$ui.BT25.Add_Click({ Start-Timer 25 'Focus'; Update-Timer })
$ui.BT5.Add_Click({ Start-Timer 5 'Pause'; Update-Timer })
$ui.BTStop.Add_Click({ $Isl.timerEnd = $null; Update-Timer })

# petit "écrasement" au clic, comme sur iPhone
$ui.Pill.Add_PreviewMouseLeftButtonDown({ AnimD $ui.PillScale $PropScaleX 0.97 120; AnimD $ui.PillScale $PropScaleY 0.97 120 })
$ui.Pill.Add_PreviewMouseLeftButtonUp({ AnimD $ui.PillScale $PropScaleX 1 380 0 'back'; AnimD $ui.PillScale $PropScaleY 1 380 0 'back' })
$ui.Pill.Add_MouseLeave({ AnimD $ui.PillScale $PropScaleX 1 300; AnimD $ui.PillScale $PropScaleY 1 300 })

# menu clic droit
$menu = New-Object System.Windows.Controls.ContextMenu
$miVer = New-Object System.Windows.Controls.MenuItem -Property @{ Header = "Dynamic Island v$Version"; IsEnabled = $false }
$miUpd = New-Object System.Windows.Controls.MenuItem -Property @{ Header = 'Mises à jour automatiques (GitHub)'; IsEnabled = $false }
$miLog = New-Object System.Windows.Controls.MenuItem -Property @{ Header = 'Ouvrir le journal' }
$miRestart = New-Object System.Windows.Controls.MenuItem -Property @{ Header = 'Redémarrer' }
$miQuit = New-Object System.Windows.Controls.MenuItem -Property @{ Header = 'Quitter' }
$miLog.Add_Click({ Start-Process notepad.exe $LogPath })
$miRestart.Add_Click({ $script:restart = $true; $win.Close() })
$miQuit.Add_Click({ $win.Close() })
foreach ($mi in $miVer, $miUpd, (New-Object System.Windows.Controls.Separator), $miLog, $miRestart, $miQuit) { $null = $menu.Items.Add($mi) }
$ui.Pill.ContextMenu = $menu

$win.Dispatcher.Add_UnhandledException({
  param($snd, $ev)
  Log ("EXCEPTION : " + $ev.Exception.ToString())
  $ev.Handled = $true
})
$win.Add_ContentRendered({ Log "fenêtre affichée à l'écran" })
$win.Add_SourceInitialized({
  Log "fenêtre créée"
  $Isl.hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
  [Island.Win]::NoActivate($Isl.hwnd)
})
function Place-Window {
  $wa = [System.Windows.SystemParameters]::WorkArea
  $win.Left = $wa.Left + ($wa.Width - $win.Width) / 2
  $win.Top = 0
}
Place-Window

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(100)
$timer.Add_Tick({
  $Isl.tick++
  $sync.uiBeat = [DateTime]::Now
  Step "cycle $($Isl.tick) volume"
  if ($Isl.tick % 50 -eq 0) { [Island.Audio]::Reset() }
  try { Update-Volume } catch { Log ("volume : " + $_.Exception.Message) }
  Step "cycle $($Isl.tick) musique"
  try { Update-Media } catch { Log ("musique : " + $_.Exception.Message) }
  if ($Isl.tick % 5 -eq 1) {
    try { Update-Timer } catch { Log ("minuteur : " + $_.Exception.Message) }
  }
  if ($Isl.tick % 10 -eq 1) {
    Step "cycle $($Isl.tick) batterie/nox/plein écran"
    try { Update-Battery } catch { Log ("batterie : " + $_.Exception.Message) }
    try { $wa = [System.Windows.SystemParameters]::WorkArea; if ("$wa" -ne $Isl.wa) { $Isl.wa = "$wa"; Place-Window } } catch {}
    try { Update-Nox } catch { Log ("nox : " + $_.Exception.Message) }
    try {
      if ($HideInFullscreen -and $Isl.hwnd -ne [IntPtr]::Zero) {
        $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $fs = [Island.Win]::ForegroundIsFullscreen($b.Width, $b.Height, $Isl.hwnd)
        if ($fs -ne $Isl.hidden) { $Isl.hidden = $fs; AnimD $ui.Row $PropOpacity ([double](-not $fs)) 220; $ui.Row.IsHitTestVisible = -not $fs }
      }
    } catch { Log ("plein écran : " + $_.Exception.Message) }
  }
  if ($sync.updated -and -not $Isl.updShown) {
    $Isl.updShown = $true; $Isl.restartAt = (Get-Date).AddSeconds(4)
    Show-Peek $null ([string][char]0xE895) $ChargeColor "Mise à jour v$($sync.updated)" 'Redémarrage de la pilule…' 4000
  }
  if ($Isl.restartAt -and (Get-Date) -ge $Isl.restartAt -and -not $Isl.expanded) { $script:restart = $true; $win.Close() }
  if ($Isl.tick -eq 30 -or $Isl.tick % 3000 -eq 0) {
    Log ("diag : visible={0} pos={1:N0},{2:N0} fenêtre={3:N0}x{4:N0} pilule={5:N0}x{6:N0} opacité={7} masquée={8} couche={9} compact={10} musique={11}" -f $win.IsVisible, $win.Left, $win.Top, $win.ActualWidth, $win.ActualHeight, $ui.Pill.ActualWidth, $ui.Pill.ActualHeight, $ui.Row.Opacity, $Isl.hidden, $Isl.layer, $ui.Compact.Opacity, ($null -ne $sync.media))
  }
  Step "cycle $($Isl.tick) affichage"
  try { Update-Layout } catch { Log ("affichage : " + $_.Exception.Message + " (ligne " + $_.InvocationInfo.ScriptLineNumber + ")") }
})

Step 'init batterie'; Update-Battery
Step 'init minuteur'; Update-Timer
Step 'init nox'; Update-Nox
$ui.Expanded.Opacity = 0; $ui.Toast.Opacity = 0; $ui.Peek.Opacity = 0
$timer.Start()
Log "démarrée"
$sync.uiStart = [DateTime]::Now
Step 'ouverture de la fenêtre'
try { $null = $win.ShowDialog() } catch { Log ("ShowDialog : " + $_.Exception.ToString()) }
Log 'fenêtre fermée'

# ---------- Fermeture ----------
$timer.Stop()
$sync.stop = $true
try { $bg.Stop(); $bg.Dispose(); $rs.Close() } catch {}
try { $script:mutex.ReleaseMutex() } catch {}
if ($script:restart) {
  Start-Process (Join-Path $env:WINDIR 'System32\conhost.exe') ('--headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "' + $MyInvocation.MyCommand.Path + '"')
}
