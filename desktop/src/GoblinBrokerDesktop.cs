using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Globalization;
using System.IO;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("Goblin Broker Desktop")]
[assembly: AssemblyDescription("Read-only WoW: Forever Auction House telemetry companion (0% ToS risk)")]
[assembly: AssemblyCompany("Goblin Broker: Forever")]
[assembly: AssemblyProduct("Goblin Broker Desktop")]
[assembly: AssemblyVersion("3.0.0.0")]
[assembly: AssemblyFileVersion("3.0.0.0")]

namespace GoblinBrokerDesktop
{
    public class AppConfig
    {
        public const string DefaultEndpointUrl = "https://goblin-broker-telemetry.d-remesnik-au.workers.dev/ingest";

        public string SavedVarsPath { get; set; }
        public string RepoRoot { get; set; }
        public string EndpointUrl { get; set; }
        public string DashboardUrl { get; set; }
        public bool AutoSync { get; set; }

        public AppConfig()
        {
            SavedVarsPath = "";
            RepoRoot = "";
            EndpointUrl = DefaultEndpointUrl;
            DashboardUrl = "https://dremesnik.github.io/wow-auction-scanner/";
            AutoSync = true;
        }
    }

    public class TelemetryBuildResult
    {
        public string Json { get; set; }
        public int ItemsCount { get; set; }
        public int SalesCount { get; set; }
        public int Fresh15m { get; set; }
        public int ByteSize { get; set; }
    }

    internal static class Theme
    {
        public static readonly Color BgCanvas     = Color.FromArgb(14, 16, 22);     // #0E1016
        public static readonly Color BgCard       = Color.FromArgb(20, 22, 31);     // #14161F
        public static readonly Color BgCardElev   = Color.FromArgb(26, 30, 42);     // #1A1E2A
        public static readonly Color BgInput      = Color.FromArgb(11, 13, 18);     // #0B0D12
        public static readonly Color BorderSubtle = Color.FromArgb(38, 44, 60);     // #262C3C
        public static readonly Color BorderBright = Color.FromArgb(56, 65, 88);     // #384158
        public static readonly Color TextPrimary  = Color.FromArgb(248, 250, 252);  // #F8FAFC
        public static readonly Color TextSecondary= Color.FromArgb(186, 198, 214);  // #BAC6D6
        public static readonly Color TextMuted    = Color.FromArgb(124, 139, 162);  // #7C8BA2
        public static readonly Color AccentGold   = Color.FromArgb(245, 158, 11);   // #F59E0B
        public static readonly Color AccentGreen  = Color.FromArgb(16, 185, 129);   // #10B981
        public static readonly Color AccentCyan   = Color.FromArgb(56, 189, 248);   // #38BDF8
        public static readonly Color AccentRed    = Color.FromArgb(248, 113, 113);  // #F87171

        public static GraphicsPath RoundedRect(Rectangle r, int radius)
        {
            var path = new GraphicsPath();
            int d = radius * 2;
            if (d > r.Width) d = r.Width;
            if (d > r.Height) d = r.Height;
            path.AddArc(r.X, r.Y, d, d, 180, 90);
            path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }
    }

    internal class RoundedPanel : Panel
    {
        public int CornerRadius { get; set; }
        public Color FillColor { get; set; }
        public Color BorderColor { get; set; }

        public RoundedPanel()
        {
            CornerRadius = 10;
            FillColor = Theme.BgCard;
            BorderColor = Theme.BorderSubtle;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var rect = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var path = Theme.RoundedRect(rect, CornerRadius))
            using (var br = new SolidBrush(FillColor))
            using (var pen = new Pen(BorderColor, 1f))
            {
                e.Graphics.FillPath(br, path);
                e.Graphics.DrawPath(pen, path);
            }
            base.OnPaint(e);
        }
    }

    internal class ObsidianButton : Control
    {
        public int CornerRadius { get; set; }
        public Color NormalBg { get; set; }
        public Color HoverBg { get; set; }
        public Color BorderCol { get; set; }
        public Color TextCol { get; set; }
        private bool _hover;
        private bool _pressed;

        public ObsidianButton()
        {
            CornerRadius = 8;
            NormalBg = Theme.BgCardElev;
            HoverBg = Color.FromArgb(35, 41, 56);
            BorderCol = Theme.BorderBright;
            TextCol = Theme.TextPrimary;
            Cursor = Cursors.Hand;
            Font = new Font("Segoe UI Semibold", 9.5f, FontStyle.Bold);
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
        }

        protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { _hover = false; _pressed = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { _pressed = true; Invalidate(); } base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { _pressed = false; Invalidate(); base.OnMouseUp(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;

            Color bg = !Enabled ? Color.FromArgb(20, 23, 32) : (_pressed ? NormalBg : (_hover ? HoverBg : NormalBg));
            Color brd = !Enabled ? Theme.BorderSubtle : BorderCol;
            Color fg = !Enabled ? Theme.TextMuted : TextCol;

            var rect = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var path = Theme.RoundedRect(rect, CornerRadius))
            using (var br = new SolidBrush(bg))
            using (var pen = new Pen(brd, 1f))
            {
                e.Graphics.FillPath(br, path);
                e.Graphics.DrawPath(pen, path);
            }

            var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            using (var tbr = new SolidBrush(fg))
            {
                e.Graphics.DrawString(Text, Font, tbr, new RectangleF(0, _pressed ? 1 : 0, Width, Height), sf);
            }
        }
    }

    internal class ToggleSwitch : Control
    {
        private bool _checked;
        public bool Checked
        {
            get { return _checked; }
            set { if (_checked != value) { _checked = value; Invalidate(); if (CheckedChanged != null) CheckedChanged(this, EventArgs.Empty); } }
        }
        public string LabelText { get; set; }
        public Color ActiveColor { get; set; }
        public event EventHandler CheckedChanged;

        public ToggleSwitch()
        {
            ActiveColor = Theme.AccentGreen;
            LabelText = "";
            Cursor = Cursors.Hand;
            Font = new Font("Segoe UI", 9f);
            Size = new Size(240, 24);
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
        }

        protected override void OnClick(EventArgs e)
        {
            Checked = !Checked;
            base.OnClick(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;

            int trackW = 34, trackH = 18;
            int ty = (Height - trackH) / 2;
            var trackRect = new Rectangle(0, ty, trackW, trackH);

            Color trackBg = _checked ? Color.FromArgb(14, 62, 46) : Color.FromArgb(24, 28, 40);
            Color trackBrd = _checked ? ActiveColor : Theme.BorderBright;
            using (var path = Theme.RoundedRect(trackRect, 9))
            using (var br = new SolidBrush(trackBg))
            using (var pen = new Pen(trackBrd, 1f))
            {
                e.Graphics.FillPath(br, path);
                e.Graphics.DrawPath(pen, path);
            }

            int knobD = 12;
            int kx = _checked ? (trackW - knobD - 3) : 3;
            int ky = ty + (trackH - knobD) / 2;
            using (var kbr = new SolidBrush(_checked ? ActiveColor : Theme.TextMuted))
            {
                e.Graphics.FillEllipse(kbr, kx, ky, knobD, knobD);
            }

            using (var tbr = new SolidBrush(_checked ? Theme.TextPrimary : Theme.TextSecondary))
            {
                var sf = new StringFormat { LineAlignment = StringAlignment.Center };
                e.Graphics.DrawString(LabelText, Font, tbr, new RectangleF(trackW + 10, 0, Width - trackW - 10, Height), sf);
            }
        }
    }

    internal static class LuaTelemetryParser
    {
        private static readonly string[] ForbiddenKeys = new[]
        {
            "\"presets\"", "\"keybinds\"", "\"character\"", "\"account\"",
            "\"gold\"", "\"money\"", "\"bait\"", "\"watchlist\"", "\"sessionLog\""
        };

        private static string ExtractLuaBlock(string text, string keyName)
        {
            if (string.IsNullOrEmpty(text)) return "";
            string marker = "[\"" + keyName + "\"] = {";
            int start = text.IndexOf(marker, StringComparison.Ordinal);
            if (start < 0) return "";
            int braceStart = text.IndexOf('{', start);
            if (braceStart < 0) return "";

            int depth = 0;
            bool inStr = false;
            for (int i = braceStart; i < text.Length; i++)
            {
                char ch = text[i];
                if (ch == '"' && (i == 0 || text[i - 1] != '\\')) inStr = !inStr;
                else if (!inStr)
                {
                    if (ch == '{') depth++;
                    else if (ch == '}')
                    {
                        depth--;
                        if (depth == 0) return text.Substring(braceStart + 1, i - braceStart - 1);
                    }
                }
            }
            return "";
        }

        private static Dictionary<string, Dictionary<string, object>> ParseRecords(string block, bool numericKeys)
        {
            var map = new Dictionary<string, Dictionary<string, object>>();
            if (string.IsNullOrWhiteSpace(block)) return map;

            var rxEntry = numericKeys
                ? new Regex(@"\[(\d+)\]\s*=\s*\{([^{}]*)\}", RegexOptions.Compiled)
                : new Regex(@"\[""([^""]+)""\]\s*=\s*\{([^{}]*)\}", RegexOptions.Compiled);
            var rxKv = new Regex(@"\[""([^""]+)""\]\s*=\s*(""([^""]*)""|[-+]?\d+(?:\.\d+)?)", RegexOptions.Compiled);

            foreach (Match m in rxEntry.Matches(block))
            {
                string key = m.Groups[1].Value;
                string body = m.Groups[2].Value;
                var rec = new Dictionary<string, object>();

                foreach (Match kv in rxKv.Matches(body))
                {
                    string k = kv.Groups[1].Value;
                    if (kv.Groups[3].Success) rec[k] = kv.Groups[3].Value;
                    else
                    {
                        string numTxt = kv.Groups[2].Value;
                        if (numTxt.Contains("."))
                        {
                            double d;
                            if (double.TryParse(numTxt, NumberStyles.Float, CultureInfo.InvariantCulture, out d)) rec[k] = d;
                        }
                        else
                        {
                            long l;
                            if (long.TryParse(numTxt, NumberStyles.Integer, CultureInfo.InvariantCulture, out l)) rec[k] = l;
                        }
                    }
                }
                map[key] = rec;
            }
            return map;
        }

        private static long GetLong(Dictionary<string, object> d, string k, long defVal = 0)
        {
            object v;
            if (!d.TryGetValue(k, out v) || v == null) return defVal;
            if (v is long) return (long)v;
            if (v is int) return (int)v;
            if (v is double) return (long)(double)v;
            long res;
            return long.TryParse(v.ToString(), NumberStyles.Any, CultureInfo.InvariantCulture, out res) ? res : defVal;
        }

        private static double GetDouble(Dictionary<string, object> d, string k, double defVal = 0)
        {
            object v;
            if (!d.TryGetValue(k, out v) || v == null) return defVal;
            if (v is double) return (double)v;
            if (v is long) return (long)v;
            if (v is int) return (int)v;
            double res;
            return double.TryParse(v.ToString(), NumberStyles.Any, CultureInfo.InvariantCulture, out res) ? res : defVal;
        }

        public static TelemetryBuildResult BuildFromSavedVariables(string svPath)
        {
            if (string.IsNullOrWhiteSpace(svPath) || !File.Exists(svPath))
                throw new FileNotFoundException("Файл SavedVariables не найден", svPath);

            string txt;
            using (var fs = new FileStream(svPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (var sr = new StreamReader(fs, Encoding.UTF8))
                txt = sr.ReadToEnd();

            var marketRecs = ParseRecords(ExtractLuaBlock(txt, "market"), true);
            var telRecs = ParseRecords(ExtractLuaBlock(ExtractLuaBlock(txt, "telemetry"), "items"), true);
            var salesRecs = ParseRecords(ExtractLuaBlock(ExtractLuaBlock(txt, "sales"), "byItem"), false);

            var allIds = new HashSet<string>(marketRecs.Keys);
            foreach (var k in telRecs.Keys) allIds.Add(k);

            DateTime nowUtc = DateTime.UtcNow;
            long epoch = (long)(nowUtc - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
            int fresh15m = 0, stale1h = 0;
            long? newestAge = null, oldestAge = null;

            var items = new Dictionary<string, Dictionary<string, object>>();

            foreach (var id in allIds)
            {
                var o = new Dictionary<string, object>();
                Dictionary<string, object> m;
                if (marketRecs.TryGetValue(id, out m))
                {
                    if (m.ContainsKey("p1")) o["p1"] = GetLong(m, "p1");
                    if (m.ContainsKey("q1")) o["q1"] = GetLong(m, "q1");
                    if (m.ContainsKey("p2")) o["p2"] = GetLong(m, "p2");
                    if (m.ContainsKey("wallQty")) o["wallQty"] = GetLong(m, "wallQty");
                    if (m.ContainsKey("wall10Qty")) o["wall10Qty"] = GetLong(m, "wall10Qty");
                    if (m.ContainsKey("wall15Qty")) o["wall15Qty"] = GetLong(m, "wall15Qty");
                    if (m.ContainsKey("resetCost15")) o["resetCost15"] = GetLong(m, "resetCost15");
                    if (m.ContainsKey("totalDepth")) o["totalDepth"] = GetLong(m, "totalDepth");
                    if (m.ContainsKey("spreadPct")) o["spreadPct"] = Math.Round(GetDouble(m, "spreadPct"), 1);
                    if (m.ContainsKey("vDrain")) o["vDrain"] = Math.Round(GetDouble(m, "vDrain"), 1);
                    if (m.ContainsKey("cls")) o["cls"] = (int)GetLong(m, "cls");
                    if (m.ContainsKey("sniperScore")) o["sniperScore"] = (int)GetLong(m, "sniperScore");
                    if (m.ContainsKey("confidence")) o["confidence"] = (int)GetLong(m, "confidence");

                    int dipCount = (int)GetLong(m, "dipCount");
                    if (dipCount > 0) o["dipCount"] = dipCount;
                    double dipDepth = GetDouble(m, "dipDepthAvg");
                    if (dipDepth > 0) o["dipDepthAvg"] = Math.Round(dipDepth, 1);
                    double dipDur = GetDouble(m, "dipDurAvg");
                    if (dipDur > 0) o["dipDurAvg"] = Math.Round(dipDur, 1);
                    double rebound = GetDouble(m, "reboundRatio");
                    if (rebound > 0) o["reboundRatio"] = Math.Round(rebound, 2);
                    if (m.ContainsKey("scans")) o["scans"] = (int)GetLong(m, "scans");

                    long uTs = GetLong(m, "updatedAt");
                    if (uTs > 0)
                    {
                        long age = Math.Max(0, epoch - uTs);
                        o["updatedAt"] = uTs;
                        o["ageSec"] = age;
                        if (age < 900) fresh15m++;
                        if (age >= 3600) stale1h++;
                        if (!newestAge.HasValue || age < newestAge.Value) newestAge = age;
                        if (!oldestAge.HasValue || age > oldestAge.Value) oldestAge = age;
                    }
                }

                Dictionary<string, object> t;
                if (telRecs.TryGetValue(id, out t))
                {
                    int buys = (int)GetLong(t, "buys");
                    int missed = (int)GetLong(t, "missed");
                    int dips = (int)GetLong(t, "dips");
                    int scanCnt = (int)GetLong(t, "scanCnt");
                    long scanSum = GetLong(t, "scanSum");
                    if (dips > 0) o["dips"] = dips;
                    if (buys + missed > 0)
                    {
                        o["winRate"] = Math.Round((buys * 100.0) / (buys + missed), 1);
                        o["attempts"] = buys + missed;
                    }
                    if (scanCnt > 0 && scanSum > 0)
                        o["avgFloor"] = (long)Math.Floor((double)scanSum / scanCnt);
                }

                if (o.Count > 0) items[id] = o;
            }

            var salesByName = new Dictionary<string, Dictionary<string, object>>();
            foreach (var kv in salesRecs)
            {
                long qty = GetLong(kv.Value, "qty");
                long net = GetLong(kv.Value, "net");
                int deals = (int)GetLong(kv.Value, "deals");
                if (qty > 0 && net > 0)
                {
                    salesByName[kv.Key] = new Dictionary<string, object>
                    {
                        { "avgSellNet", (long)Math.Floor((double)net / qty) },
                        { "qty", qty },
                        { "deals", deals }
                    };
                }
            }

            var payload = new Dictionary<string, object>
            {
                { "version", 2 },
                { "source", "ForeverSniper" },
                { "updated_at", nowUtc.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture) },
                { "updated_ts", epoch },
                { "items_count", items.Count },
                { "sales_count", salesByName.Count },
                { "freshness", new Dictionary<string, object>
                    {
                        { "fresh_15m", fresh15m },
                        { "stale_1h", stale1h },
                        { "newest_sec", newestAge.HasValue ? newestAge.Value : -1 },
                        { "oldest_sec", oldestAge.HasValue ? oldestAge.Value : -1 }
                    }
                },
                { "items", items },
                { "salesByName", salesByName }
            };

            var ser = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024 };
            string json = ser.Serialize(payload);

            foreach (string bad in ForbiddenKeys)
            {
                if (json.IndexOf(bad, StringComparison.OrdinalIgnoreCase) >= 0)
                    throw new InvalidOperationException("Privacy Audit FAILED: обнаружен запрещённый ключ " + bad);
            }

            return new TelemetryBuildResult
            {
                Json = json,
                ItemsCount = items.Count,
                SalesCount = salesByName.Count,
                Fresh15m = fresh15m,
                ByteSize = Encoding.UTF8.GetByteCount(json)
            };
        }
    }

    public class MainForm : Form
    {
        [DllImport("user32.dll")]
        private static extern bool ReleaseCapture();
        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr hWnd, int msg, int wParam, int lParam);
        [DllImport("dwmapi.dll", PreserveSig = true)]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

        private const int WM_NCLBUTTONDOWN = 0xA1;
        private const int HT_CAPTION = 0x2;
        private const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
        private const int DWMWCP_ROUND = 2;

        private readonly string _appDataDir;
        private readonly string _configPath;
        private readonly string _logPath;
        private AppConfig _cfg;

        private NotifyIcon _trayIcon;
        private FileSystemWatcher _watcher;
        private System.Windows.Forms.Timer _debounceTimer;
        private bool _isSyncing;
        private bool _allowClose;
        private bool _settingsExpanded;

        private const int CompactHeight = 452;
        private const int ExpandedHeight = 594;

        // UI controls
        private Label _lblStatusDot;
        private Label _lblStatusText;
        private Label _lblStatusSub;
        private Label _lblKpiItems;
        private Label _lblKpiFresh;
        private Label _lblKpiMeta;
        private Label _lblModeBadge;
        private ObsidianButton _btnSyncNow;
        private ObsidianButton _btnSettings;
        private RoundedPanel _settingsCard;
        private TextBox _txtSvPath;
        private TextBox _txtEndpoint;
        private ToggleSwitch _tglAutoSync;
        private ToggleSwitch _tglAutostart;
        private RoundedPanel _logCard;
        private RichTextBox _txtLog;
        private Label _lblFooter;

        public MainForm(bool startMinimized)
        {
            _appDataDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "GoblinBrokerDesktop");
            Directory.CreateDirectory(_appDataDir);
            _configPath = Path.Combine(_appDataDir, "config.json");
            _logPath = Path.Combine(_appDataDir, "desktop.log");

            LoadConfig();
            InitializeUi();
            InitializeTray();
            SetupWatcher();

            Log("Goblin Broker: Desktop v3.0 запущен (0% CPU · Read-Only).", Theme.AccentCyan);
            if (!string.IsNullOrEmpty(_cfg.SavedVarsPath) && File.Exists(_cfg.SavedVarsPath))
                Log("Найден SavedVariables: " + Path.GetFileName(_cfg.SavedVarsPath), Theme.TextMuted);
            else
                Log("Файл ForeverSniper.lua не найден — откройте «Настройки».", Theme.AccentGold);

            UpdateModeBadge();

            if (startMinimized)
            {
                WindowState = FormWindowState.Minimized;
                ShowInTaskbar = false;
                Opacity = 0;
                Load += (s, e) => { Hide(); Opacity = 1; };
            }
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            try
            {
                int pref = DWMWCP_ROUND;
                DwmSetWindowAttribute(Handle, DWMWA_WINDOW_CORNER_PREFERENCE, ref pref, sizeof(int));
            }
            catch { }
        }

        private void DragWindow(object sender, MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left)
            {
                ReleaseCapture();
                SendMessage(Handle, WM_NCLBUTTONDOWN, HT_CAPTION, 0);
            }
        }

        private void LoadConfig()
        {
            _cfg = new AppConfig();
            try
            {
                if (File.Exists(_configPath))
                {
                    var ser = new JavaScriptSerializer();
                    var loaded = ser.Deserialize<AppConfig>(File.ReadAllText(_configPath, Encoding.UTF8));
                    if (loaded != null) _cfg = loaded;
                }
            }
            catch { }

            if (string.IsNullOrWhiteSpace(_cfg.SavedVarsPath) || !File.Exists(_cfg.SavedVarsPath))
            {
                string found = DiscoverSavedVariables();
                if (!string.IsNullOrEmpty(found)) _cfg.SavedVarsPath = found;
            }
            if (string.IsNullOrWhiteSpace(_cfg.RepoRoot) || !Directory.Exists(Path.Combine(_cfg.RepoRoot, ".git")))
            {
                string repo = DiscoverRepoRoot();
                if (!string.IsNullOrEmpty(repo)) _cfg.RepoRoot = repo;
            }
            if (string.IsNullOrWhiteSpace(_cfg.EndpointUrl) && !string.IsNullOrWhiteSpace(AppConfig.DefaultEndpointUrl))
                _cfg.EndpointUrl = AppConfig.DefaultEndpointUrl;
            if (string.IsNullOrWhiteSpace(_cfg.DashboardUrl))
                _cfg.DashboardUrl = "https://dremesnik.github.io/wow-auction-scanner/";

            SaveConfig();
        }

        private void SaveConfig()
        {
            try
            {
                var ser = new JavaScriptSerializer();
                File.WriteAllText(_configPath, ser.Serialize(_cfg), new UTF8Encoding(false));
            }
            catch { }
        }

        private static string DiscoverRepoRoot()
        {
            try
            {
                string cur = Path.GetDirectoryName(Application.ExecutablePath);
                for (int i = 0; i < 4 && !string.IsNullOrEmpty(cur); i++)
                {
                    if (Directory.Exists(Path.Combine(cur, ".git")) &&
                        File.Exists(Path.Combine(cur, "scripts", "sync_live_telemetry.ps1")))
                        return cur;
                    cur = Path.GetDirectoryName(cur);
                }
            }
            catch { }
            return "";
        }

        private static string DiscoverSavedVariables()
        {
            var candidates = new List<string>();
            string[] roots = new[]
            {
                @"D:\Games\World of Warcraft\_forever_\WTF\Account",
                @"C:\Games\World of Warcraft\_forever_\WTF\Account",
                @"C:\Program Files (x86)\World of Warcraft\_forever_\WTF\Account",
                @"D:\World of Warcraft\_forever_\WTF\Account",
                @"E:\Games\World of Warcraft\_forever_\WTF\Account",
                @"E:\World of Warcraft\_forever_\WTF\Account",
                @"C:\Battle.net\World of Warcraft\_forever_\WTF\Account",
                @"D:\Battle.net\World of Warcraft\_forever_\WTF\Account"
            };
            foreach (string accRoot in roots)
            {
                try
                {
                    if (!Directory.Exists(accRoot)) continue;
                    foreach (string accDir in Directory.GetDirectories(accRoot))
                    {
                        string sv = Path.Combine(accDir, "SavedVariables", "ForeverSniper.lua");
                        if (File.Exists(sv)) candidates.Add(sv);
                    }
                }
                catch { }
            }
            string best = "";
            DateTime bestTime = DateTime.MinValue;
            foreach (string c in candidates)
            {
                try
                {
                    DateTime t = File.GetLastWriteTimeUtc(c);
                    if (t > bestTime) { bestTime = t; best = c; }
                }
                catch { }
            }
            return best;
        }

        private void InitializeUi()
        {
            Text = "Goblin Broker: Desktop";
            FormBorderStyle = FormBorderStyle.None;
            Size = new Size(564, CompactHeight);
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Theme.BgCanvas;
            ForeColor = Theme.TextPrimary;
            Font = new Font("Segoe UI", 9.5f);
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);

            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            // Outer 1px Obsidian border + top brand hairline (Gold -> Emerald -> Cyan)
            Paint += (s, e) =>
            {
                e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
                using (var br = new LinearGradientBrush(new Rectangle(0, 0, Width, 3), Theme.AccentGold, Theme.AccentCyan, 0f))
                {
                    var cb = new ColorBlend
                    {
                        Colors = new[] { Theme.AccentGold, Theme.AccentGreen, Theme.AccentCyan },
                        Positions = new[] { 0f, 0.52f, 1f }
                    };
                    br.InterpolationColors = cb;
                    e.Graphics.FillRectangle(br, 0, 0, Width, 3);
                }
                using (var pen = new Pen(Theme.BorderSubtle, 1f))
                    e.Graphics.DrawRectangle(pen, 0, 0, Width - 1, Height - 1);
            };

            // Custom Draggable Title Bar
            var header = new Panel { Location = new Point(1, 3), Size = new Size(Width - 2, 64), BackColor = Theme.BgCanvas };
            header.MouseDown += DragWindow;

            // Goblin Logo Badge
            var logoBox = new RoundedPanel
            {
                Location = new Point(18, 12),
                Size = new Size(40, 40),
                CornerRadius = 9,
                FillColor = Color.FromArgb(24, 21, 16),
                BorderColor = Color.FromArgb(145, 98, 18)
            };
            if (Icon != null)
            {
                var pic = new PictureBox
                {
                    Image = Icon.ToBitmap(),
                    SizeMode = PictureBoxSizeMode.Zoom,
                    Size = new Size(26, 26),
                    Location = new Point(7, 7),
                    BackColor = Color.Transparent
                };
                pic.MouseDown += DragWindow;
                logoBox.Controls.Add(pic);
            }
            logoBox.MouseDown += DragWindow;
            header.Controls.Add(logoBox);

            var lblBrand1 = new Label
            {
                Text = "Goblin Broker",
                Font = new Font("Segoe UI Semibold", 13f, FontStyle.Bold),
                ForeColor = Theme.AccentGold,
                Location = new Point(68, 12),
                AutoSize = true
            };
            lblBrand1.MouseDown += DragWindow;
            header.Controls.Add(lblBrand1);

            var lblBrand2 = new Label
            {
                Text = ": Desktop",
                Font = new Font("Segoe UI Semibold", 13f, FontStyle.Bold),
                ForeColor = Theme.TextPrimary,
                Location = new Point(185, 12),
                AutoSize = true
            };
            lblBrand2.MouseDown += DragWindow;
            header.Controls.Add(lblBrand2);

            var lblSub = new Label
            {
                Text = "EU Орда · Read-Only · 0% риск Blizzard ToS",
                Font = new Font("Segoe UI", 8.5f),
                ForeColor = Theme.TextMuted,
                Location = new Point(70, 37),
                AutoSize = true
            };
            lblSub.MouseDown += DragWindow;
            header.Controls.Add(lblSub);

            // Mode Pill Badge
            _lblModeBadge = new Label
            {
                Text = "HTTPS · ОБЛАКО",
                Font = new Font("Segoe UI Semibold", 7.8f, FontStyle.Bold),
                ForeColor = Theme.AccentCyan,
                BackColor = Color.FromArgb(12, 34, 48),
                TextAlign = ContentAlignment.MiddleCenter,
                Size = new Size(118, 24),
                Location = new Point(358, 20)
            };
            _lblModeBadge.MouseDown += DragWindow;
            header.Controls.Add(_lblModeBadge);

            // Custom Minimize & Close-to-Tray buttons
            var btnMin = new ObsidianButton
            {
                Text = "—",
                Location = new Point(486, 18),
                Size = new Size(28, 28),
                CornerRadius = 6,
                NormalBg = Theme.BgCard,
                HoverBg = Theme.BgCardElev,
                BorderCol = Theme.BorderSubtle,
                TextCol = Theme.TextSecondary,
                Font = new Font("Segoe UI", 9f, FontStyle.Bold)
            };
            btnMin.Click += (s, e) => HideToTray();
            header.Controls.Add(btnMin);

            var btnClose = new ObsidianButton
            {
                Text = "×",
                Location = new Point(520, 18),
                Size = new Size(28, 28),
                CornerRadius = 6,
                NormalBg = Theme.BgCard,
                HoverBg = Color.FromArgb(72, 24, 30),
                BorderCol = Theme.BorderSubtle,
                TextCol = Theme.TextSecondary,
                Font = new Font("Segoe UI", 11f, FontStyle.Bold)
            };
            btnClose.Click += (s, e) => HideToTray();
            header.Controls.Add(btnClose);

            Controls.Add(header);

            // Hero Status + KPI Card
            var statusCard = new RoundedPanel
            {
                Location = new Point(18, 76),
                Size = new Size(528, 122),
                CornerRadius = 10,
                FillColor = Theme.BgCard,
                BorderColor = Theme.BorderSubtle
            };

            _lblStatusDot = new Label
            {
                Text = "●",
                Font = new Font("Segoe UI", 12f, FontStyle.Bold),
                ForeColor = Theme.AccentGreen,
                Location = new Point(16, 13),
                AutoSize = true
            };
            statusCard.Controls.Add(_lblStatusDot);

            _lblStatusText = new Label
            {
                Text = "Готов к синхронизации (ожидание сохранения WoW)",
                Font = new Font("Segoe UI Semibold", 10f, FontStyle.Bold),
                ForeColor = Theme.TextPrimary,
                Location = new Point(36, 14),
                Size = new Size(476, 22)
            };
            statusCard.Controls.Add(_lblStatusText);

            _lblStatusSub = new Label
            {
                Text = "Авто-отправка срабатывает при выходе с персонажа, закрытии WoW или /reload",
                Font = new Font("Segoe UI", 8.3f),
                ForeColor = Theme.TextMuted,
                Location = new Point(36, 37),
                Size = new Size(476, 18)
            };
            statusCard.Controls.Add(_lblStatusSub);

            // 3 Mini KPI Tiles inside Status Card
            _lblKpiItems = CreateKpiTile(statusCard, 16, 64, 160, "ТОВАРЫ В БАЗЕ", "—", Theme.TextPrimary);
            _lblKpiFresh = CreateKpiTile(statusCard, 184, 64, 160, "СВЕЖИЕ (<15 МИН)", "—", Theme.AccentGreen);
            _lblKpiMeta  = CreateKpiTile(statusCard, 352, 64, 160, "ПОСЛЕДНИЙ СИНХР.", "ещё не было", Theme.AccentCyan);
            Controls.Add(statusCard);

            // Primary Action Row (Deep Obsidian Tinted Buttons — high contrast!)
            _btnSyncNow = new ObsidianButton
            {
                Text = "Синхронизировать сейчас",
                Location = new Point(18, 210),
                Size = new Size(228, 38),
                CornerRadius = 9,
                NormalBg = Color.FromArgb(11, 46, 34),
                HoverBg = Color.FromArgb(16, 66, 48),
                BorderCol = Theme.AccentGreen,
                TextCol = Color.FromArgb(224, 255, 240)
            };
            _btnSyncNow.Click += (s, e) => TriggerSync("ручной запуск");
            Controls.Add(_btnSyncNow);

            var btnDash = new ObsidianButton
            {
                Text = "Открыть Дэшборд",
                Location = new Point(256, 210),
                Size = new Size(166, 38),
                CornerRadius = 9,
                NormalBg = Color.FromArgb(11, 38, 56),
                HoverBg = Color.FromArgb(16, 56, 82),
                BorderCol = Theme.AccentCyan,
                TextCol = Color.FromArgb(224, 246, 255)
            };
            btnDash.Click += (s, e) => OpenDashboard();
            Controls.Add(btnDash);

            _btnSettings = new ObsidianButton
            {
                Text = "Настройки ▾",
                Location = new Point(432, 210),
                Size = new Size(114, 38),
                CornerRadius = 9,
                NormalBg = Theme.BgCard,
                HoverBg = Theme.BgCardElev,
                BorderCol = Theme.BorderBright,
                TextCol = Theme.TextSecondary,
                Font = new Font("Segoe UI Semibold", 9f, FontStyle.Bold)
            };
            _btnSettings.Click += (s, e) => ToggleSettingsDrawer();
            Controls.Add(_btnSettings);

            // Custom Pill Toggles Row
            _tglAutoSync = new ToggleSwitch
            {
                LabelText = "Авто-синхронизация WoW",
                Checked = _cfg.AutoSync,
                ActiveColor = Theme.AccentGreen,
                Location = new Point(20, 260),
                Size = new Size(240, 24)
            };
            _tglAutoSync.CheckedChanged += (s, e) =>
            {
                _cfg.AutoSync = _tglAutoSync.Checked;
                SaveConfig();
                SetupWatcher();
                Log(_cfg.AutoSync ? "Авто-синхронизация включена." : "Авто-синхронизация выключена.", Theme.TextMuted);
            };
            Controls.Add(_tglAutoSync);

            _tglAutostart = new ToggleSwitch
            {
                LabelText = "Запуск с Windows (в трее)",
                Checked = IsAutostartEnabled(),
                ActiveColor = Theme.AccentGold,
                Location = new Point(290, 260),
                Size = new Size(256, 24)
            };
            _tglAutostart.CheckedChanged += (s, e) => SetAutostart(_tglAutostart.Checked);
            Controls.Add(_tglAutostart);

            // Collapsible Settings Drawer (hidden by default for ultra-clean look!)
            _settingsCard = new RoundedPanel
            {
                Location = new Point(18, 296),
                Size = new Size(528, 132),
                CornerRadius = 10,
                FillColor = Theme.BgCard,
                BorderColor = Theme.BorderSubtle,
                Visible = false
            };

            var lblSv = new Label
            {
                Text = "Файл SavedVariables (ForeverSniper.lua):",
                Font = new Font("Segoe UI", 8.2f),
                ForeColor = Theme.TextMuted,
                Location = new Point(14, 10),
                AutoSize = true
            };
            _settingsCard.Controls.Add(lblSv);

            _txtSvPath = new TextBox
            {
                Text = _cfg.SavedVarsPath,
                BackColor = Theme.BgInput,
                ForeColor = Theme.TextSecondary,
                BorderStyle = BorderStyle.FixedSingle,
                Location = new Point(14, 30),
                Size = new Size(404, 24),
                ReadOnly = true
            };
            _settingsCard.Controls.Add(_txtSvPath);

            var btnBrowse = new ObsidianButton
            {
                Text = "Обзор...",
                Location = new Point(426, 29),
                Size = new Size(88, 26),
                CornerRadius = 6,
                Font = new Font("Segoe UI Semibold", 8.5f, FontStyle.Bold)
            };
            btnBrowse.Click += (s, e) => BrowseSavedVars();
            _settingsCard.Controls.Add(btnBrowse);

            var lblEp = new Label
            {
                Text = "HTTPS-сервер синхронизации (вшит по умолчанию для друзей):",
                Font = new Font("Segoe UI", 8.2f),
                ForeColor = Theme.TextMuted,
                Location = new Point(14, 66),
                AutoSize = true
            };
            _settingsCard.Controls.Add(lblEp);

            _txtEndpoint = new TextBox
            {
                Text = _cfg.EndpointUrl,
                BackColor = Theme.BgInput,
                ForeColor = Theme.AccentCyan,
                BorderStyle = BorderStyle.FixedSingle,
                Location = new Point(14, 86),
                Size = new Size(404, 24)
            };
            _settingsCard.Controls.Add(_txtEndpoint);

            var btnSaveEp = new ObsidianButton
            {
                Text = "Сохранить",
                Location = new Point(426, 85),
                Size = new Size(88, 26),
                CornerRadius = 6,
                NormalBg = Color.FromArgb(40, 30, 12),
                HoverBg = Color.FromArgb(58, 42, 16),
                BorderCol = Theme.AccentGold,
                TextCol = Theme.AccentGold,
                Font = new Font("Segoe UI Semibold", 8.5f, FontStyle.Bold)
            };
            btnSaveEp.Click += (s, e) =>
            {
                _cfg.EndpointUrl = _txtEndpoint.Text.Trim();
                SaveConfig();
                UpdateModeBadge();
                Log("Адрес сервера сохранён.", Theme.AccentGold);
            };
            _settingsCard.Controls.Add(btnSaveEp);
            Controls.Add(_settingsCard);

            // Log Console Card
            _logCard = new RoundedPanel
            {
                Location = new Point(18, 296),
                Size = new Size(528, 122),
                CornerRadius = 10,
                FillColor = Theme.BgInput,
                BorderColor = Theme.BorderSubtle
            };
            _txtLog = new RichTextBox
            {
                Location = new Point(10, 8),
                Size = new Size(508, 106),
                BackColor = Theme.BgInput,
                ForeColor = Theme.TextMuted,
                BorderStyle = BorderStyle.None,
                Font = new Font("Consolas", 8.5f),
                ReadOnly = true
            };
            _logCard.Controls.Add(_txtLog);
            Controls.Add(_logCard);

            // Minimal Footer
            _lblFooter = new Label
            {
                Text = "v3.0 · 0% CPU idle · Privacy Self-Audit: только анонимные рыночные цены",
                Font = new Font("Segoe UI", 8f),
                ForeColor = Color.FromArgb(88, 102, 124),
                Location = new Point(20, 426),
                AutoSize = true
            };
            Controls.Add(_lblFooter);

            _debounceTimer = new System.Windows.Forms.Timer { Interval = 1800 };
            _debounceTimer.Tick += (s, e) =>
            {
                _debounceTimer.Stop();
                TriggerSync("авто-событие WoW");
            };

            FormClosing += (s, e) =>
            {
                if (!_allowClose && e.CloseReason == CloseReason.UserClosing)
                {
                    e.Cancel = true;
                    HideToTray();
                }
            };
        }

        private Label CreateKpiTile(Control parent, int x, int y, int w, string title, string value, Color valColor)
        {
            var tile = new RoundedPanel
            {
                Location = new Point(x, y),
                Size = new Size(w, 46),
                CornerRadius = 7,
                FillColor = Theme.BgInput,
                BorderColor = Color.FromArgb(30, 35, 48)
            };
            tile.Controls.Add(new Label
            {
                Text = title,
                Font = new Font("Segoe UI Semibold", 7f, FontStyle.Bold),
                ForeColor = Theme.TextMuted,
                Location = new Point(10, 6),
                AutoSize = true
            });
            var lblVal = new Label
            {
                Text = value,
                Font = new Font("Segoe UI Semibold", 10.5f, FontStyle.Bold),
                ForeColor = valColor,
                Location = new Point(10, 21),
                Size = new Size(w - 16, 20)
            };
            tile.Controls.Add(lblVal);
            parent.Controls.Add(tile);
            return lblVal;
        }

        private void ToggleSettingsDrawer()
        {
            _settingsExpanded = !_settingsExpanded;
            _settingsCard.Visible = _settingsExpanded;
            _btnSettings.Text = _settingsExpanded ? "Настройки ▴" : "Настройки ▾";

            int logTop = _settingsExpanded ? 438 : 296;
            _logCard.Location = new Point(18, logTop);
            _lblFooter.Location = new Point(20, logTop + 130);
            Height = _settingsExpanded ? ExpandedHeight : CompactHeight;
            Invalidate();
        }

        private void InitializeTray()
        {
            var menu = new ContextMenuStrip();
            menu.Items.Add("Открыть Goblin Broker", null, (s, e) => RestoreFromTray());
            menu.Items.Add("Синхронизировать сейчас", null, (s, e) => TriggerSync("трей"));
            menu.Items.Add("Открыть Web-дэшборд", null, (s, e) => OpenDashboard());
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Выход", null, (s, e) => ExitApp());

            _trayIcon = new NotifyIcon
            {
                Icon = Icon ?? SystemIcons.Application,
                Text = "Goblin Broker: Desktop (0% CPU · Read-Only)",
                ContextMenuStrip = menu,
                Visible = true
            };
            _trayIcon.DoubleClick += (s, e) => RestoreFromTray();
        }

        private void HideToTray()
        {
            Hide();
            ShowInTaskbar = false;
            _trayIcon.ShowBalloonTip(1600, "Goblin Broker: Desktop", "Свернут в трей. Авто-синхронизация активна (0% CPU).", ToolTipIcon.Info);
        }

        private void RestoreFromTray()
        {
            Show();
            WindowState = FormWindowState.Normal;
            ShowInTaskbar = true;
            Activate();
        }

        private void ExitApp()
        {
            _allowClose = true;
            if (_watcher != null) _watcher.Dispose();
            if (_trayIcon != null) { _trayIcon.Visible = false; _trayIcon.Dispose(); }
            Application.Exit();
        }

        private void BrowseSavedVars()
        {
            using (var ofd = new OpenFileDialog())
            {
                ofd.Title = "Выберите ForeverSniper.lua в папке WoW SavedVariables";
                ofd.Filter = "ForeverSniper.lua|ForeverSniper.lua|Lua files (*.lua)|*.lua";
                if (!string.IsNullOrEmpty(_cfg.SavedVarsPath) && Directory.Exists(Path.GetDirectoryName(_cfg.SavedVarsPath)))
                    ofd.InitialDirectory = Path.GetDirectoryName(_cfg.SavedVarsPath);

                if (ofd.ShowDialog() == DialogResult.OK)
                {
                    _cfg.SavedVarsPath = ofd.FileName;
                    _txtSvPath.Text = _cfg.SavedVarsPath;
                    SaveConfig();
                    SetupWatcher();
                    Log("Выбран файл: " + _cfg.SavedVarsPath, Theme.AccentGreen);
                }
            }
        }

        private void SetupWatcher()
        {
            if (_watcher != null)
            {
                _watcher.EnableRaisingEvents = false;
                _watcher.Dispose();
                _watcher = null;
            }
            if (!_cfg.AutoSync || string.IsNullOrWhiteSpace(_cfg.SavedVarsPath)) return;
            string dir = Path.GetDirectoryName(_cfg.SavedVarsPath);
            string file = Path.GetFileName(_cfg.SavedVarsPath);
            if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) return;

            _watcher = new FileSystemWatcher(dir, file)
            {
                NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.CreationTime,
                EnableRaisingEvents = true
            };
            FileSystemEventHandler onChange = (s, e) =>
            {
                if (IsHandleCreated)
                {
                    BeginInvoke((Action)(() =>
                    {
                        _debounceTimer.Stop();
                        _debounceTimer.Start();
                    }));
                }
            };
            _watcher.Changed += onChange;
            _watcher.Created += onChange;
        }

        private void UpdateModeBadge()
        {
            if (!string.IsNullOrWhiteSpace(_cfg.EndpointUrl))
            {
                _lblModeBadge.Text = "HTTPS · ОБЛАКО";
                _lblModeBadge.ForeColor = Theme.AccentCyan;
                _lblModeBadge.BackColor = Color.FromArgb(12, 34, 48);
            }
            else if (!string.IsNullOrWhiteSpace(_cfg.RepoRoot) && Directory.Exists(Path.Combine(_cfg.RepoRoot, ".git")))
            {
                _lblModeBadge.Text = "GIT · ВЛАДЕЛЕЦ";
                _lblModeBadge.ForeColor = Theme.AccentGold;
                _lblModeBadge.BackColor = Color.FromArgb(40, 30, 12);
            }
            else
            {
                _lblModeBadge.Text = "ЛОКАЛЬНЫЙ";
                _lblModeBadge.ForeColor = Theme.TextMuted;
                _lblModeBadge.BackColor = Theme.BgCard;
            }
        }

        private void TriggerSync(string reason)
        {
            if (_isSyncing) return;
            if (string.IsNullOrWhiteSpace(_cfg.SavedVarsPath) || !File.Exists(_cfg.SavedVarsPath))
            {
                SetStatus("Файл ForeverSniper.lua не найден", Theme.AccentRed);
                Log("Ошибка: укажите путь к ForeverSniper.lua в «Настройках».", Theme.AccentRed);
                return;
            }

            _isSyncing = true;
            _btnSyncNow.Enabled = false;
            SetStatus("Синхронизация (" + reason + ")...", Theme.AccentGold);

            Task.Run(() =>
            {
                try
                {
                    var built = LuaTelemetryParser.BuildFromSavedVariables(_cfg.SavedVarsPath);
                    string localJson = Path.Combine(_appDataDir, "live_telemetry.json");
                    File.WriteAllText(localJson, built.Json, new UTF8Encoding(false));

                    string transportInfo;
                    bool hasGitRepo = !string.IsNullOrWhiteSpace(_cfg.RepoRoot) && Directory.Exists(Path.Combine(_cfg.RepoRoot, ".git"));
                    if (!string.IsNullOrWhiteSpace(_cfg.EndpointUrl))
                    {
                        try
                        {
                            PushViaHttps(_cfg.EndpointUrl, built.Json);
                            transportInfo = "HTTPS OK";
                        }
                        catch (Exception)
                        {
                            if (hasGitRepo)
                            {
                                SafeUi(() => Log("HTTPS недоступен -> резервная отправка через Git...", Theme.AccentGold));
                                string repoDataJson = Path.Combine(_cfg.RepoRoot, "data", "live_telemetry.json");
                                Directory.CreateDirectory(Path.GetDirectoryName(repoDataJson));
                                File.WriteAllText(repoDataJson, built.Json, new UTF8Encoding(false));
                                PushViaGitWorktree(_cfg.RepoRoot, repoDataJson);
                                transportInfo = "gh-pages OK (резерв)";
                            }
                            else throw;
                        }
                    }
                    else if (hasGitRepo)
                    {
                        string repoDataJson = Path.Combine(_cfg.RepoRoot, "data", "live_telemetry.json");
                        Directory.CreateDirectory(Path.GetDirectoryName(repoDataJson));
                        File.WriteAllText(repoDataJson, built.Json, new UTF8Encoding(false));
                        PushViaGitWorktree(_cfg.RepoRoot, repoDataJson);
                        transportInfo = "gh-pages OK";
                    }
                    else
                    {
                        transportInfo = "локально";
                    }

                    string ts = DateTime.Now.ToString("HH:mm:ss");
                    SafeUi(() =>
                    {
                        SetStatus("Синхронизировано · " + transportInfo, Theme.AccentGreen);
                        _lblKpiItems.Text = built.ItemsCount + " поз.";
                        _lblKpiFresh.Text = built.Fresh15m + " из " + built.ItemsCount;
                        _lblKpiMeta.Text = ts + " (" + (built.ByteSize / 1024.0).ToString("0.0") + " КБ)";
                        Log(string.Format("[OK] {0}: {1} поз. ({2} свежих), {3} продаж -> {4}",
                            reason, built.ItemsCount, built.Fresh15m, built.SalesCount, transportInfo), Theme.AccentGreen);
                    });
                }
                catch (Exception ex)
                {
                    SafeUi(() =>
                    {
                        SetStatus("Ошибка синхронизации", Theme.AccentRed);
                        Log("[ERR] " + ex.Message, Theme.AccentRed);
                    });
                }
                finally
                {
                    SafeUi(() =>
                    {
                        _isSyncing = false;
                        _btnSyncNow.Enabled = true;
                    });
                }
            });
        }

        private static void PushViaHttps(string endpointUrl, string json)
        {
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
            var req = (HttpWebRequest)WebRequest.Create(endpointUrl);
            req.Method = "POST";
            req.ContentType = "application/json; charset=utf-8";
            req.Timeout = 15000;
            req.UserAgent = "GoblinBrokerDesktop/3.0";

            byte[] data = Encoding.UTF8.GetBytes(json);
            req.ContentLength = data.Length;
            using (var stream = req.GetRequestStream())
                stream.Write(data, 0, data.Length);

            using (var resp = (HttpWebResponse)req.GetResponse())
            {
                if ((int)resp.StatusCode < 200 || (int)resp.StatusCode >= 300)
                    throw new Exception("HTTP " + (int)resp.StatusCode);
            }
        }

        private static void PushViaGitWorktree(string repoRoot, string localJsonPath)
        {
            string wtDir = Path.Combine(Path.GetTempPath(), "wow_ah_ghpages_live_sync");
            try
            {
                RunGit(repoRoot, "worktree remove --force \"" + wtDir + "\"", true);
                RunGit(repoRoot, "worktree prune", true);
                if (Directory.Exists(wtDir)) { try { Directory.Delete(wtDir, true); } catch { } }

                RunGit(repoRoot, "fetch origin gh-pages --depth=1", false);
                RunGit(repoRoot, "worktree add --detach \"" + wtDir + "\" origin/gh-pages", false);
                File.Copy(localJsonPath, Path.Combine(wtDir, "live_telemetry.json"), true);

                RunGit(wtDir, "add live_telemetry.json", false);
                string diff = RunGit(wtDir, "status --porcelain live_telemetry.json", false);
                if (!string.IsNullOrWhiteSpace(diff))
                {
                    string msg = "chore(live): sync addon telemetry " + DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm UTC", CultureInfo.InvariantCulture);
                    RunGit(wtDir, "commit -m \"" + msg + "\"", false);
                    RunGit(wtDir, "push origin HEAD:gh-pages", false);
                }
            }
            finally
            {
                RunGit(repoRoot, "worktree remove --force \"" + wtDir + "\"", true);
                if (Directory.Exists(wtDir)) { try { Directory.Delete(wtDir, true); } catch { } }
            }
        }

        private static string RunGit(string workDir, string args, bool ignoreError)
        {
            var psi = new ProcessStartInfo("git", args)
            {
                WorkingDirectory = workDir,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            };
            using (var p = Process.Start(psi))
            {
                string stdout = p.StandardOutput.ReadToEnd();
                string stderr = p.StandardError.ReadToEnd();
                p.WaitForExit(30000);
                if (!ignoreError && p.ExitCode != 0)
                    throw new Exception("git " + args + " -> " + (string.IsNullOrWhiteSpace(stderr) ? stdout : stderr).Trim());
                return stdout;
            }
        }

        private void OpenDashboard()
        {
            try { Process.Start(_cfg.DashboardUrl); } catch { }
        }

        private static bool IsAutostartEnabled()
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", false))
                    return key != null && key.GetValue("GoblinBrokerDesktop") != null;
            }
            catch { return false; }
        }

        private void SetAutostart(bool enable)
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true))
                {
                    if (key == null) return;
                    if (enable) key.SetValue("GoblinBrokerDesktop", "\"" + Application.ExecutablePath + "\" --minimized");
                    else key.DeleteValue("GoblinBrokerDesktop", false);
                }
                Log(enable ? "Автозапуск с Windows включён." : "Автозапуск с Windows отключён.", Theme.TextMuted);
            }
            catch (Exception ex) { Log("[ERR] Автозапуск: " + ex.Message, Theme.AccentRed); }
        }

        private void SetStatus(string text, Color dotColor)
        {
            _lblStatusDot.ForeColor = dotColor;
            _lblStatusText.Text = text;
        }

        private void Log(string msg, Color color)
        {
            string ts = DateTime.Now.ToString("HH:mm:ss");
            string line = "[" + ts + "] " + msg;
            try { File.AppendAllText(_logPath, line + Environment.NewLine, Encoding.UTF8); } catch { }
            SafeUi(() =>
            {
                if (_txtLog.TextLength > 8000) _txtLog.Clear();
                _txtLog.SelectionStart = _txtLog.TextLength;
                _txtLog.SelectionColor = Color.FromArgb(90, 104, 128);
                _txtLog.AppendText("[" + ts + "] ");
                _txtLog.SelectionColor = color;
                _txtLog.AppendText(msg + Environment.NewLine);
                _txtLog.SelectionStart = _txtLog.TextLength;
                _txtLog.ScrollToCaret();
            });
        }

        private void SafeUi(Action act)
        {
            if (IsDisposed) return;
            if (InvokeRequired) BeginInvoke(act);
            else act();
        }
    }

    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            bool createdNew;
            using (var mutex = new Mutex(true, "GoblinBrokerDesktop_SingleInstance_v3", out createdNew))
            {
                if (!createdNew)
                {
                    MessageBox.Show(
                        "Goblin Broker: Desktop уже запущен (значок гоблина в системном трее).",
                        "Goblin Broker: Desktop",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Information);
                    return;
                }

                bool startMin = false;
                foreach (var a in args)
                {
                    if (string.Equals(a, "--minimized", StringComparison.OrdinalIgnoreCase))
                        startMin = true;
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new MainForm(startMin));
            }
        }
    }
}
