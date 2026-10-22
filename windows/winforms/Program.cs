using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Drawing.Drawing2D;
using Microsoft.Win32;

namespace KeyboardBridge;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Contains("--self-test", StringComparer.OrdinalIgnoreCase))
            return SelfTests.Run();

        if (args.Contains("--input-self-test", StringComparer.OrdinalIgnoreCase))
        {
            ApplicationConfiguration.Initialize();
            return InputSmokeTest.Run();
        }

        ApplicationConfiguration.Initialize();
        Application.Run(new MainForm());
        return 0;
    }
}

internal static class InputSmokeTest
{
    public static int Run()
    {
        const string expected = "AbC_123-$HOME/path|grep";
        using var form = new Form
        {
            Text = "KeyboardBridge input self-test",
            ClientSize = new Size(420, 70),
            StartPosition = FormStartPosition.CenterScreen,
            ShowInTaskbar = false,
            TopMost = true
        };
        using var target = new TextBox
        {
            Dock = DockStyle.Fill,
            Font = new Font("Consolas", 11F),
            ImeMode = ImeMode.Disable
        };
        form.Controls.Add(target);
        form.Show();
        form.Activate();
        target.Focus();
        Application.DoEvents();

        foreach (var character in expected)
        {
            if (!KeyboardEmitter.Send(character.ToString(), out var win32Error))
            {
                Console.WriteLine($"INPUT SELF-TEST FAILED: SendInput Win32={win32Error}");
                return 1;
            }
            Thread.Sleep(2);
            Application.DoEvents();
        }

        for (var attempt = 0; attempt < 10 && target.Text.Length < expected.Length; attempt++)
        {
            Thread.Sleep(20);
            Application.DoEvents();
        }

        var passed = target.Text == expected;
        Console.WriteLine(passed
            ? "INPUT SELF-TEST OK"
            : $"INPUT SELF-TEST FAILED: expected={expected.Length} actual={target.Text.Length} text={target.Text}");
        return passed ? 0 : 1;
    }
}

internal sealed class SafeLogger
{
    public static SafeLogger Instance { get; } = new();
    private readonly object _gate = new();
    private readonly string _path;

    private SafeLogger()
    {
        var folder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "KeyboardBridge", "logs");
        Directory.CreateDirectory(folder);
        _path = Path.Combine(folder, $"bridge-{DateTime.Now:yyyyMMdd}.log");
    }

    public string ContentId(string text)
    {
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(text));
        return Convert.ToHexString(digest.AsSpan(0, 6)).ToLowerInvariant();
    }

    public void Write(string eventName, IReadOnlyDictionary<string, string>? fields = null)
    {
        var suffix = fields is null ? string.Empty : string.Join(" ", fields
            .OrderBy(pair => pair.Key)
            .Select(pair => $"{pair.Key}={pair.Value.Replace('\r', '_').Replace('\n', '_')}"));
        var line = $"{DateTimeOffset.Now:O} version=0.2.5 event={eventName} {suffix}{Environment.NewLine}";
        lock (_gate) File.AppendAllText(_path, line, Encoding.UTF8);
    }
}

internal static class SettingsStore
{
    private const string RegistryPath = @"Software\KeyboardBridge";
    private const string MonitorCopyName = "MonitorCopyShortcut";
    private const string UiScaleName = "UiScale";

    public static bool LoadMonitorCopy()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RegistryPath);
            return key?.GetValue(MonitorCopyName) is int value ? value != 0 : true;
        }
        catch
        {
            return true;
        }
    }

    public static void SaveMonitorCopy(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RegistryPath);
            key?.SetValue(MonitorCopyName, enabled ? 1 : 0, RegistryValueKind.DWord);
        }
        catch (Exception ex)
        {
            SafeLogger.Instance.Write("setting_save_failed", new Dictionary<string, string>
            {
                ["exception"] = ex.GetType().Name
            });
        }
    }

    public static string LoadUiScale()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RegistryPath);
            var value = key?.GetValue(UiScaleName) as string;
            return value is "small" or "large" ? value : "medium";
        }
        catch
        {
            return "medium";
        }
    }

    public static void SaveUiScale(string value)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RegistryPath);
            key?.SetValue(UiScaleName, value, RegistryValueKind.String);
        }
        catch (Exception ex)
        {
            SafeLogger.Instance.Write("setting_save_failed", new Dictionary<string, string>
            {
                ["exception"] = ex.GetType().Name
            });
        }
    }
}

internal static class KeyboardEmitter
{
    private const uint InputKeyboard = 1;
    private const uint KeyeventfKeyup = 0x0002;
    private const uint KeyeventfUnicode = 0x0004;
    private const uint KeyeventfScancode = 0x0008;
    private const uint MapvkVkToVsc = 0;
    private const ushort VkReturn = 0x0D;
    private const ushort VkLeftShift = 0xA0;

    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint Type;
        public InputUnion Union;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        // INPUT's native union is sized by MOUSEINPUT (32 bytes on x64), not
        // KEYBDINPUT (24 bytes on x64). Omitting the other members makes the
        // managed INPUT 32 bytes instead of the required 40 and causes
        // SendInput to fail with ERROR_INVALID_PARAMETER.
        [FieldOffset(0)] public MouseInput Mouse;
        [FieldOffset(0)] public KeyboardInput Keyboard;
        [FieldOffset(0)] public HardwareInput Hardware;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int X;
        public int Y;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HardwareInput
    {
        public uint Message;
        public ushort ParameterLow;
        public ushort ParameterHigh;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, Input[] inputs, int size);

    [DllImport("user32.dll")]
    private static extern uint MapVirtualKey(uint code, uint mapType);

    public static int InputStructureSize => Marshal.SizeOf<Input>();

    public static bool Send(string unit, out int win32Error)
    {
        win32Error = 0;
        foreach (var ch in unit)
        {
            if (ch == '\n')
            {
                if (!SendPhysical(new PhysicalKey(VkReturn, false), out win32Error)) return false;
            }
            else if (PhysicalKeyMapper.Map(ch) is { } physical)
            {
                if (!SendPhysical(physical, out win32Error)) return false;
            }
            else if (!SendUnicode(ch, out win32Error))
            {
                return false;
            }
        }
        return true;
    }

    private static bool SendPhysical(PhysicalKey key, out int win32Error)
    {
        win32Error = 0;
        var keyScan = (ushort)MapVirtualKey(key.VirtualKey, MapvkVkToVsc);
        if (keyScan == 0)
        {
            win32Error = 87; // ERROR_INVALID_PARAMETER
            return false;
        }
        var inputs = new List<Input>(key.Shift ? 4 : 2);
        if (key.Shift)
        {
            var shiftScan = (ushort)MapVirtualKey(VkLeftShift, MapvkVkToVsc);
            inputs.Add(MakeInput(0, shiftScan, KeyeventfScancode));
        }
        inputs.Add(MakeInput(0, keyScan, KeyeventfScancode));
        inputs.Add(MakeInput(0, keyScan, KeyeventfScancode | KeyeventfKeyup));
        if (key.Shift)
        {
            var shiftScan = (ushort)MapVirtualKey(VkLeftShift, MapvkVkToVsc);
            inputs.Add(MakeInput(0, shiftScan, KeyeventfScancode | KeyeventfKeyup));
        }
        var buffer = inputs.ToArray();
        var sent = SendInput((uint)buffer.Length, buffer, InputStructureSize);
        if (sent == buffer.Length) return true;
        win32Error = Marshal.GetLastWin32Error();
        return false;
    }

    private static bool SendUnicode(char character, out int win32Error)
    {
        win32Error = 0;
        var inputs = new[]
        {
            MakeInput(0, character, KeyeventfUnicode),
            MakeInput(0, character, KeyeventfUnicode | KeyeventfKeyup)
        };
        var sent = SendInput((uint)inputs.Length, inputs, InputStructureSize);
        if (sent == inputs.Length) return true;
        win32Error = Marshal.GetLastWin32Error();
        return false;
    }

    private static Input MakeInput(ushort virtualKey, ushort scanCode, uint flags) => new()
    {
        Type = InputKeyboard,
        Union = new InputUnion
        {
            Keyboard = new KeyboardInput
            {
                VirtualKey = virtualKey,
                ScanCode = scanCode,
                Flags = flags,
                Time = 0,
                ExtraInfo = UIntPtr.Zero
            }
        }
    };
}

internal static class UiPalette
{
    public static readonly Color Canvas = Color.FromArgb(244, 247, 251);
    public static readonly Color Card = Color.White;
    public static readonly Color Border = Color.FromArgb(226, 232, 240);
    public static readonly Color Text = Color.FromArgb(15, 23, 42);
    public static readonly Color Muted = Color.FromArgb(100, 116, 139);
    public static readonly Color Accent = Color.FromArgb(37, 99, 235);
    public static readonly Color AccentHover = Color.FromArgb(29, 78, 216);
    public static readonly Color Warning = Color.FromArgb(161, 98, 7);
    public static readonly Color WarningBackground = Color.FromArgb(255, 251, 235);
}

internal sealed class RoundedPanel : Panel
{
    public int CornerRadius { get; set; } = 12;
    public Color BorderColor { get; set; } = UiPalette.Border;

    public RoundedPanel()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);
        ResizeRedraw = true;
        BackColor = UiPalette.Card;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        var bounds = new Rectangle(0, 0, Math.Max(1, Width - 1), Math.Max(1, Height - 1));
        using var path = CreateRoundedRectangle(bounds, CornerRadius);
        using var fill = new SolidBrush(BackColor);
        using var border = new Pen(BorderColor);
        e.Graphics.FillPath(fill, path);
        e.Graphics.DrawPath(border, path);
        base.OnPaint(e);
    }

    private static GraphicsPath CreateRoundedRectangle(Rectangle bounds, int radius)
    {
        var diameter = Math.Max(2, radius * 2);
        var path = new GraphicsPath();
        path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }
}

internal static class UiFactory
{
    public static Button Button(string text, bool primary)
    {
        var button = new Button
        {
            Text = text,
            Dock = DockStyle.Fill,
            FlatStyle = FlatStyle.Flat,
            BackColor = primary ? UiPalette.Accent : Color.White,
            ForeColor = primary ? Color.White : UiPalette.Text,
            Cursor = Cursors.Hand,
            Font = new Font("Segoe UI", 10F, FontStyle.Bold),
            Margin = new Padding(0)
        };
        button.FlatAppearance.BorderColor = primary ? UiPalette.Accent : UiPalette.Border;
        button.FlatAppearance.BorderSize = 1;
        button.FlatAppearance.MouseOverBackColor = primary ? UiPalette.AccentHover : Color.FromArgb(248, 250, 252);
        return button;
    }
}

internal sealed class MainForm : Form
{
    private const int HotkeyId = 0x4B42;
    private const uint ModAlt = 0x0001;
    private const uint ModControl = 0x0002;
    private const uint VkEscape = 0x1B;
    private const uint VkControl = 0x11;
    private const uint VkC = 0x43;
    private const int WmHotkey = 0x0312;
    private const int WmKeydown = 0x0100;
    private const int WmSyskeydown = 0x0104;
    private const int WhKeyboardLl = 13;
    private const uint SwpNosize = 0x0001;
    private const uint SwpNomove = 0x0002;
    private const uint SwpNoactivate = 0x0010;
    private static readonly IntPtr HwndTopmost = new(-1);

    private readonly RichTextBox _preview = new();
    private readonly Label _previewInfo = new();
    private readonly Label _status = new();
    private readonly NumericUpDown _delay = new();
    private readonly NumericUpDown _countdown = new();
    private readonly ComboBox _uiScale = new();
    private readonly CheckBox _allowReturn = new();
    private readonly CheckBox _dryRun = new();
    private readonly CheckBox _monitorCopy = new();
    private readonly Button _start = UiFactory.Button(string.Empty, true);
    private readonly Button _stop = UiFactory.Button("停止  Ctrl+Alt+Esc", false);
    private readonly System.Windows.Forms.Timer _frontTimer = new();
    private bool _dpiLayoutScaled;
    private bool _uiScaleReady;
    private float _currentUserScale = 1F;
    private float _dpiFactor = 1F;
    private readonly NotifyIcon _tray = new();
    private readonly LowLevelKeyboardProc _keyboardProc;
    private CancellationTokenSource? _cancellation;
    private IntPtr _keyboardHook;
    private DateTime _lastCopyTrigger = DateTime.MinValue;
    private bool _typing;
    private bool _reallyExit;

    private delegate IntPtr LowLevelKeyboardProc(int code, IntPtr message, IntPtr data);

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardHookData
    {
        public uint VirtualKey;
        public uint ScanCode;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint virtualKey);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr window, int id);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int hookId, LowLevelKeyboardProc callback, IntPtr module, uint threadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int virtualKey);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string? moduleName);

    public MainForm()
    {
        _keyboardProc = KeyboardHookCallback;
        Text = "键盘输入桥";
        AutoScaleDimensions = new SizeF(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(720, 590);
        MinimumSize = new Size(420, 500);
        StartPosition = FormStartPosition.CenterScreen;
        TopMost = true;
        ShowInTaskbar = true;
        MinimizeBox = true;
        MaximizeBox = false;
        BackColor = UiPalette.Canvas;
        Font = new Font("Segoe UI", 10F);
        try
        {
            var icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!);
            if (icon is not null) Icon = icon;
        }
        catch { }

        BuildModernUi();
        BuildTray();
        _frontTimer.Interval = 800;
        _frontTimer.Tick += (_, _) => KeepOnTop();
        _frontTimer.Start();
        SafeLogger.Instance.Write("app_started", new Dictionary<string, string> { ["platform"] = "windows" });
    }

    protected override void OnLoad(EventArgs e)
    {
        base.OnLoad(e);
        if (_dpiLayoutScaled) return;
        _dpiLayoutScaled = true;

        // Runtime-created controls need one explicit geometry pass at the
        // monitor DPI. Font points already scale through GDI; Scale expands
        // the rows, padding and window so those glyphs are never clipped.
        var factor = DeviceDpi / 96F;
        _dpiFactor = factor;
        if (factor > 1.01F)
        {
            SuspendLayout();
            Scale(new SizeF(factor, factor));
            ResumeLayout(true);
        }

        _uiScaleReady = true;
        ApplyUiScale(SelectedUiScaleKey(), persist: false);
        var arguments = Environment.GetCommandLineArgs();
        if (arguments.Contains("--layout-test-min", StringComparer.OrdinalIgnoreCase))
        {
            Size = MinimumSize;
        }
        else if (arguments.Contains("--layout-test-narrow", StringComparer.OrdinalIgnoreCase))
        {
            var workArea = Screen.FromControl(this).WorkingArea;
            Size = new Size(MinimumSize.Width, Math.Min(workArea.Height - 32, Math.Max(MinimumSize.Height, Height)));
        }
    }

    private string SelectedUiScaleKey() => _uiScale.SelectedIndex switch
    {
        0 => "small",
        2 => "large",
        _ => "medium"
    };

    private static float UiScaleFactor(string key) => key switch
    {
        "small" => 0.80F,
        "large" => 1.25F,
        _ => 1F
    };

    private static void ScaleFonts(Control control, float ratio)
    {
        foreach (Control child in control.Controls) ScaleFonts(child, ratio);
        if (control.Font is null) return;
        var size = Math.Max(6F, control.Font.SizeInPoints * ratio);
        control.Font = new Font(control.Font.FontFamily, size, control.Font.Style, GraphicsUnit.Point);
    }

    private void UpdateMinimumSize(float userScale)
    {
        MinimumSize = new Size(
            (int)Math.Ceiling(420F * _dpiFactor * userScale),
            (int)Math.Ceiling(500F * _dpiFactor * userScale));
    }

    private void ApplyUiScale(string key, bool persist)
    {
        var target = UiScaleFactor(key);
        var ratio = target / _currentUserScale;
        if (Math.Abs(ratio - 1F) > 0.001F)
        {
            var center = new Point(Left + Width / 2, Top + Height / 2);
            SuspendLayout();
            ScaleFonts(this, ratio);
            Scale(new SizeF(ratio, ratio));
            UpdateMinimumSize(target);
            ResumeLayout(true);
            _currentUserScale = target;

            var workArea = Screen.FromControl(this).WorkingArea;
            Size = new Size(
                Math.Min(Width, Math.Max(MinimumSize.Width, workArea.Width - 32)),
                Math.Min(Height, Math.Max(MinimumSize.Height, workArea.Height - 32)));
            Location = new Point(
                Math.Clamp(center.X - Width / 2, workArea.Left, Math.Max(workArea.Left, workArea.Right - Width)),
                Math.Clamp(center.Y - Height / 2, workArea.Top, Math.Max(workArea.Top, workArea.Bottom - Height)));
        }
        else
        {
            UpdateMinimumSize(target);
        }

        if (persist) SettingsStore.SaveUiScale(key);
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        if (!RegisterHotKey(Handle, HotkeyId, ModAlt | ModControl, VkEscape))
            _status.Text = "警告：Ctrl+Alt+Esc 停止热键注册失败";
        SetCopyHookEnabled(_monitorCopy.Checked);
    }

    protected override void OnHandleDestroyed(EventArgs e)
    {
        UnregisterHotKey(Handle, HotkeyId);
        if (_keyboardHook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_keyboardHook);
            _keyboardHook = IntPtr.Zero;
        }
        base.OnHandleDestroyed(e);
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == WmHotkey && message.WParam.ToInt32() == HotkeyId) StopTyping();
        base.WndProc(ref message);
    }

    private IntPtr KeyboardHookCallback(int code, IntPtr message, IntPtr data)
    {
        if (_monitorCopy.Checked && code >= 0 &&
            (message.ToInt32() == WmKeydown || message.ToInt32() == WmSyskeydown))
        {
            var key = Marshal.PtrToStructure<KeyboardHookData>(data);
            var controlPressed = (GetAsyncKeyState((int)VkControl) & 0x8000) != 0;
            if (key.VirtualKey == VkC && controlPressed && !_typing && IsHandleCreated && !IsDisposed)
            {
                try { BeginInvoke(new Action(ScheduleCopyCapture)); }
                catch (InvalidOperationException) { }
            }
        }
        return CallNextHookEx(_keyboardHook, code, message, data);
    }

    private void BuildModernUi()
    {
        Label Caption(string text) => new()
        {
            Text = text,
            AutoSize = true,
            ForeColor = UiPalette.Text,
            Font = new Font("Segoe UI", 9.5F, FontStyle.Bold),
            Margin = new Padding(0, 5, 10, 4)
        };

        void StyleNumber(NumericUpDown number, int width)
        {
            number.Width = width;
            number.Font = new Font("Segoe UI", 10F);
            number.TextAlign = HorizontalAlignment.Center;
            number.Margin = new Padding(0, 0, 0, 4);
        }

        FlowLayoutPanel SettingPair(string caption, Control control)
        {
            var pair = new FlowLayoutPanel
            {
                AutoSize = true,
                AutoSizeMode = AutoSizeMode.GrowAndShrink,
                WrapContents = false,
                FlowDirection = FlowDirection.LeftToRight,
                BackColor = Color.White,
                Margin = new Padding(0, 0, 24, 2)
            };
            pair.Controls.Add(Caption(caption));
            pair.Controls.Add(control);
            return pair;
        }

        var warningCard = new RoundedPanel
        {
            Dock = DockStyle.Fill,
            BackColor = UiPalette.WarningBackground,
            BorderColor = Color.FromArgb(253, 230, 138),
            Padding = new Padding(14, 10, 14, 10),
            Margin = new Padding(0, 0, 0, 12),
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink
        };
        var warningLabel = new Label
        {
            Text = "请检查内容后再输入。不要粘贴密码、令牌或私钥；换行默认会替换为空格。",
            AutoSize = true,
            Dock = DockStyle.Top,
            ForeColor = UiPalette.Warning,
            Font = new Font("Segoe UI", 9.5F),
            Margin = new Padding(0)
        };
        var warningClose = new Button
        {
            Text = "×",
            Width = 28,
            Height = 28,
            Anchor = AnchorStyles.Top | AnchorStyles.Right,
            FlatStyle = FlatStyle.Flat,
            BackColor = UiPalette.WarningBackground,
            ForeColor = UiPalette.Warning,
            Font = new Font("Segoe UI", 11F, FontStyle.Bold),
            Cursor = Cursors.Hand,
            Margin = new Padding(0),
            Visible = false,
            TabStop = false,
            AccessibleName = "隐藏安全提示"
        };
        warningClose.FlatAppearance.BorderSize = 0;
        void LayoutWarning()
        {
            var closeSpace = warningClose.Visible ? warningClose.Width + 8 : 0;
            warningLabel.MaximumSize = new Size(
                Math.Max(120, warningCard.ClientSize.Width - warningCard.Padding.Horizontal - closeSpace), 0);
            warningClose.Location = new Point(
                Math.Max(warningCard.Padding.Left, warningCard.ClientSize.Width - warningCard.Padding.Right - warningClose.Width),
                warningCard.Padding.Top - 3);
        }
        warningCard.ClientSizeChanged += (_, _) => LayoutWarning();
        warningCard.Controls.Add(warningLabel);
        warningCard.Controls.Add(warningClose);

        warningClose.Click += (_, _) =>
        {
            warningCard.Visible = false;
        };

        var previewCard = new RoundedPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(14, 6, 14, 12),
            Margin = new Padding(0, 0, 0, 12)
        };
        var previewLayout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 2,
            BackColor = Color.White
        };
        previewLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        previewLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        previewLayout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var previewHeader = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            ColumnCount = 2,
            RowCount = 1,
            BackColor = Color.White,
            Margin = new Padding(0, 0, 0, 2)
        };
        previewHeader.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        previewHeader.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        previewHeader.Controls.Add(new Label
        {
            Text = "待输入内容",
            AutoSize = true,
            Anchor = AnchorStyles.Left,
            ForeColor = UiPalette.Text,
            Font = new Font("Segoe UI", 10F, FontStyle.Bold),
            Margin = new Padding(0)
        }, 0, 0);
        _previewInfo.Text = "0 字符 · 1 行";
        _previewInfo.AutoSize = false;
        _previewInfo.Dock = DockStyle.Fill;
        _previewInfo.ForeColor = UiPalette.Muted;
        _previewInfo.TextAlign = ContentAlignment.MiddleRight;
        _previewInfo.Margin = new Padding(12, 0, 0, 0);
        previewHeader.Controls.Add(_previewInfo, 1, 0);
        _preview.Dock = DockStyle.Fill;
        _preview.BorderStyle = BorderStyle.None;
        _preview.BackColor = Color.White;
        _preview.ForeColor = UiPalette.Text;
        _preview.Font = new Font("Cascadia Mono", 10F);
        _preview.WordWrap = false;
        _preview.Margin = new Padding(0, 2, 0, 0);
        _preview.TextChanged += (_, _) => UpdatePreviewStatus();
        previewLayout.Controls.Add(previewHeader, 0, 0);
        previewLayout.Controls.Add(_preview, 0, 1);
        previewCard.Controls.Add(previewLayout);

        TableLayoutPanel? root = null;
        var fittingSettings = false;
        var settingsCard = new RoundedPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(14, 10, 14, 10),
            Margin = new Padding(0, 0, 0, 12)
        };
        var settingsLayout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 2,
            BackColor = Color.White
        };
        settingsLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 44));
        settingsLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 44));

        _delay.Minimum = 1;
        _delay.Maximum = 500;
        _delay.Value = 10;
        StyleNumber(_delay, 72);
        _countdown.Minimum = 1;
        _countdown.Maximum = 30;
        _countdown.Value = 3;
        StyleNumber(_countdown, 64);
        _countdown.ValueChanged += (_, _) => UpdateStartButtonText();
        _uiScale.DropDownStyle = ComboBoxStyle.DropDownList;
        _uiScale.Items.AddRange(new object[] { "小", "中", "大" });
        _uiScale.Width = 70;
        _uiScale.Font = new Font("Segoe UI", 10F);
        _uiScale.Margin = new Padding(0, 0, 0, 4);
        _uiScale.SelectedIndex = SettingsStore.LoadUiScale() switch
        {
            "small" => 0,
            "large" => 2,
            _ => 1
        };
        _uiScale.SelectedIndexChanged += (_, _) =>
        {
            if (_uiScaleReady) ApplyUiScale(SelectedUiScaleKey(), persist: true);
        };
        var numberRow = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            WrapContents = true,
            FlowDirection = FlowDirection.LeftToRight,
            BackColor = Color.White,
            Margin = new Padding(0)
        };
        numberRow.Controls.Add(SettingPair("字符间隔（毫秒）", _delay));
        numberRow.Controls.Add(SettingPair("输入倒计时（秒）", _countdown));
        numberRow.Controls.Add(SettingPair("界面大小", _uiScale));
        settingsLayout.Controls.Add(numberRow, 0, 0);

        _allowReturn.Text = "允许回车（可能直接执行命令）";
        _dryRun.Text = "演练模式（不发送按键）";
        _monitorCopy.Text = "监听 Ctrl+C 并自动唤起窗口";
        foreach (var option in new[] { _allowReturn, _dryRun, _monitorCopy })
        {
            option.AutoSize = true;
            option.ForeColor = UiPalette.Text;
            option.Margin = new Padding(0, 5, 26, 0);
            option.Cursor = Cursors.Hand;
        }
        _monitorCopy.Checked = SettingsStore.LoadMonitorCopy();
        _monitorCopy.CheckedChanged += (_, _) => CopyMonitoringChanged();
        var optionRow = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            WrapContents = true,
            FlowDirection = FlowDirection.LeftToRight,
            BackColor = Color.White,
            Margin = new Padding(0)
        };
        optionRow.Controls.Add(_allowReturn);
        optionRow.Controls.Add(_dryRun);
        optionRow.Controls.Add(_monitorCopy);
        settingsLayout.Controls.Add(optionRow, 0, 1);
        settingsCard.Controls.Add(settingsLayout);

        void FitSettingsToWidth()
        {
            if (root is null || fittingSettings || settingsCard.ClientSize.Width <= 0) return;
            fittingSettings = true;
            try
            {
                var available = Math.Max(160, settingsCard.ClientSize.Width - settingsCard.Padding.Horizontal);
                numberRow.MaximumSize = new Size(available, 0);
                optionRow.MaximumSize = new Size(available, 0);
                var numberHeight = Math.Max(32, numberRow.GetPreferredSize(new Size(available, 0)).Height);
                var optionHeight = Math.Max(30, optionRow.GetPreferredSize(new Size(available, 0)).Height);
                settingsLayout.RowStyles[0].Height = numberHeight;
                settingsLayout.RowStyles[1].Height = optionHeight;
                root.RowStyles[2].Height = numberHeight + optionHeight + settingsCard.Padding.Vertical + settingsCard.Margin.Vertical;
                var warningHeight = warningCard.Visible ? warningCard.PreferredSize.Height : 0;
                var contentHeight = warningHeight + 150 + root.RowStyles[2].Height +
                    root.RowStyles[3].Height + Math.Max(28, _status.PreferredHeight) + root.Padding.Vertical + 18;
                root.AutoScrollMinSize = new Size(0, (int)Math.Ceiling(contentHeight));
            }
            finally
            {
                fittingSettings = false;
            }
        }
        settingsCard.ClientSizeChanged += (_, _) => FitSettingsToWidth();
        warningCard.VisibleChanged += (_, _) => FitSettingsToWidth();

        _start.Click += async (_, _) => await StartCountdownAsync();
        _stop.Click += (_, _) => StopTyping();
        UpdateStartButtonText();
        var actionRow = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            RowCount = 1,
            Margin = new Padding(0, 0, 0, 10)
        };
        actionRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 62));
        actionRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 38));
        _start.Margin = new Padding(0, 0, 8, 0);
        _stop.Margin = new Padding(0, 0, 0, 0);
        actionRow.Controls.Add(_start, 0, 0);
        actionRow.Controls.Add(_stop, 1, 0);

        _status.Text = _monitorCopy.Checked ? "●  已就绪，等待 Ctrl+C" : "●  已就绪，复制监听已关闭";
        _status.ForeColor = UiPalette.Muted;
        _status.Dock = DockStyle.Fill;
        _status.TextAlign = ContentAlignment.MiddleLeft;
        _status.AutoEllipsis = true;
        _status.Margin = new Padding(2, 0, 0, 0);

        root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoScroll = true,
            Padding = new Padding(20, 18, 20, 14),
            ColumnCount = 1,
            RowCount = 5,
            BackColor = UiPalette.Canvas
        };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 126));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 58));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.Controls.Add(warningCard, 0, 0);
        root.Controls.Add(previewCard, 0, 1);
        root.Controls.Add(settingsCard, 0, 2);
        root.Controls.Add(actionRow, 0, 3);
        root.Controls.Add(_status, 0, 4);
        Controls.Add(root);
        root.SizeChanged += (_, _) => FitSettingsToWidth();
        Shown += async (_, _) =>
        {
            FitSettingsToWidth();
            warningCard.Visible = true;
            warningClose.Visible = false;
            LayoutWarning();
            await Task.Delay(5000);
            if (IsDisposed || !IsHandleCreated || !warningCard.Visible) return;
            warningClose.Visible = true;
            LayoutWarning();
            warningClose.BringToFront();
            warningCard.PerformLayout();
            warningCard.Invalidate(true);
        };
        AcceptButton = _start;
    }

    private void UpdateStartButtonText()
    {
        _start.Text = $"{(int)_countdown.Value} 秒后输入";
    }

    private void BuildTray()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("显示键盘输入桥", null, (_, _) => ShowAndActivate());
        menu.Items.Add("退出", null, (_, _) =>
        {
            _reallyExit = true;
            Close();
        });
        _tray.Icon = Icon;
        _tray.Text = "键盘输入桥";
        _tray.Visible = true;
        _tray.ContextMenuStrip = menu;
        _tray.DoubleClick += (_, _) => ShowAndActivate();
    }

    private async void ScheduleCopyCapture()
    {
        if (!_monitorCopy.Checked || _typing) return;
        var now = DateTime.UtcNow;
        if (_typing || now - _lastCopyTrigger < TimeSpan.FromMilliseconds(150)) return;
        _lastCopyTrigger = now;
        await Task.Delay(220);
        if (!_monitorCopy.Checked || _typing) return;

        for (var attempt = 0; attempt < 4; attempt++)
        {
            try
            {
                if (!Clipboard.ContainsText()) return;
                var text = Clipboard.GetText(TextDataFormat.UnicodeText);
                if (string.IsNullOrEmpty(text)) return;
                _preview.Text = text;
                UpdatePreviewStatus();
                System.Media.SystemSounds.Beep.Play();
                ShowAndActivate();
                SafeLogger.Instance.Write("ctrl_c_captured", new Dictionary<string, string>
                {
                    ["chars"] = text.Length.ToString(),
                    ["content_id"] = SafeLogger.Instance.ContentId(text)
                });
                return;
            }
            catch (ExternalException)
            {
                await Task.Delay(60);
            }
        }
        _status.Text = "已检测到 Ctrl+C，但剪贴板暂时被其他程序占用";
        SafeLogger.Instance.Write("clipboard_busy");
    }

    private void CopyMonitoringChanged()
    {
        var enabled = _monitorCopy.Checked;
        SettingsStore.SaveMonitorCopy(enabled);
        if (IsHandleCreated) SetCopyHookEnabled(enabled);
        _status.Text = enabled
            ? "已开启 Ctrl+C 监听；复制后会自动唤起"
            : "已关闭 Ctrl+C 监听；复制操作不会唤起工具";
        SafeLogger.Instance.Write("copy_monitor_changed", new Dictionary<string, string>
        {
            ["enabled"] = enabled ? "true" : "false"
        });
    }

    private void SetCopyHookEnabled(bool enabled)
    {
        if (!enabled)
        {
            if (_keyboardHook != IntPtr.Zero)
            {
                UnhookWindowsHookEx(_keyboardHook);
                _keyboardHook = IntPtr.Zero;
            }
            return;
        }
        if (_keyboardHook != IntPtr.Zero) return;
        _keyboardHook = SetWindowsHookEx(WhKeyboardLl, _keyboardProc, GetModuleHandle(null), 0);
        if (_keyboardHook == IntPtr.Zero)
            _status.Text = "警告：全局 Ctrl+C 监听启动失败";
    }

    private async Task StartCountdownAsync()
    {
        if (_typing) return;
        var text = _preview.Text;
        if (string.IsNullOrEmpty(text))
        {
            _status.Text = "没有可输入的内容";
            System.Media.SystemSounds.Beep.Play();
            return;
        }
        if (text.Length > 100_000)
        {
            _status.Text = "内容超过 100,000 字符，已拒绝输入";
            System.Media.SystemSounds.Beep.Play();
            return;
        }

        _cancellation?.Dispose();
        _cancellation = new CancellationTokenSource();
        var token = _cancellation.Token;
        _typing = true;
        SetControlsEnabled(false);
        var inputError = 0;
        try
        {
            var countdownSeconds = (int)_countdown.Value;
            for (var seconds = countdownSeconds; seconds > 0; seconds--)
            {
                _status.Text = $"请点击要输入的位置（{seconds} 秒后输入）";
                await Task.Delay(1000, token);
            }
            var delay = (int)_delay.Value;
            var allowReturn = _allowReturn.Checked;
            var dryRun = _dryRun.Checked;
            var plan = TextPlan.Create(text, allowReturn);
            var contentId = SafeLogger.Instance.ContentId(text);
            _status.Text = dryRun ? "演练中…" : "输入中…（物理扫描码模式，Ctrl+Alt+Esc 停止）";
            var watch = System.Diagnostics.Stopwatch.StartNew();
            var sent = await Task.Run(async () =>
            {
                var count = 0;
                foreach (var unit in plan.Units)
                {
                    token.ThrowIfCancellationRequested();
                    if (!dryRun && !KeyboardEmitter.Send(unit, out var win32Error))
                    {
                        inputError = win32Error;
                        throw new InvalidOperationException(
                            $"SendInput 失败（Win32={win32Error}，INPUT={KeyboardEmitter.InputStructureSize} 字节）");
                    }
                    count += unit.Length;
                    var unitDelay = unit == "\n" ? Math.Max(delay, 150) : delay;
                    await Task.Delay(unitDelay, token);
                }
                return count;
            }, token);
            watch.Stop();
            _status.Text = $"完成（已处理 {sent} 个字符）";
            SafeLogger.Instance.Write(dryRun ? "dry_run_completed" : "typing_completed", new Dictionary<string, string>
            {
                ["chars"] = sent.ToString(), ["content_id"] = contentId,
                ["elapsed_ms"] = watch.ElapsedMilliseconds.ToString(),
                ["newlines_replaced"] = plan.ReplacedNewlines.ToString(),
                ["input_mode"] = "physical_ascii"
            });
        }
        catch (OperationCanceledException)
        {
            _status.Text = "已停止";
            SafeLogger.Instance.Write("typing_cancelled");
        }
        catch (Exception ex)
        {
            _status.Text = $"输入失败：{ex.Message}";
            SafeLogger.Instance.Write("typing_failed", new Dictionary<string, string>
            {
                ["exception"] = ex.GetType().Name,
                ["win32_error"] = inputError.ToString(),
                ["input_size"] = KeyboardEmitter.InputStructureSize.ToString()
            });
        }
        finally
        {
            _typing = false;
            SetControlsEnabled(true);
        }
    }

    private void StopTyping()
    {
        _cancellation?.Cancel();
        _status.Text = "正在停止…";
    }

    private void SetControlsEnabled(bool enabled)
    {
        _start.Enabled = enabled;
        _delay.Enabled = enabled;
        _countdown.Enabled = enabled;
        _uiScale.Enabled = enabled;
        _allowReturn.Enabled = enabled;
        _dryRun.Enabled = enabled;
    }

    private void UpdatePreviewStatus()
    {
        if (_typing) return;
        var lines = _preview.Text.Count(ch => ch == '\n') + 1;
        _previewInfo.Text = $"{_preview.Text.Length} 字符 · {lines} 行";
        _status.Text = _preview.Text.Length == 0 ? "●  等待输入内容" : "●  内容已更新，等待确认";
    }

    private void ShowAndActivate()
    {
        Show();
        WindowState = FormWindowState.Normal;
        BringToFront();
        Activate();
    }

    private void KeepOnTop()
    {
        if (!Visible || WindowState == FormWindowState.Minimized || !IsHandleCreated) return;
        SetWindowPos(Handle, HwndTopmost, 0, 0, 0, 0, SwpNomove | SwpNosize | SwpNoactivate);
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!_reallyExit && e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            Hide();
            return;
        }
        _cancellation?.Cancel();
        _frontTimer.Stop();
        _tray.Visible = false;
        base.OnFormClosing(e);
    }
}

internal static class SelfTests
{
    public static int Run()
    {
        var failed = 0;
        void Expect(bool condition, string name)
        {
            Console.WriteLine($"{(condition ? "PASS" : "FAIL")} {name}");
            if (!condition) failed++;
        }

        var safe = TextPlan.Create("echo a\r\nb\tc", false);
        Expect(string.Concat(safe.Units) == "echo a b    c", "newline and tab safe normalization");
        Expect(safe.ReplacedNewlines == 1, "newline count");
        var allowed = TextPlan.Create("a\nb", true);
        Expect(string.Concat(allowed.Units) == "a\nb", "allowed return preserved");
        Expect(PhysicalKeyMapper.Map('a')?.VirtualKey == 0x41, "physical key mapping for a");
        Expect(PhysicalKeyMapper.Map('p')?.VirtualKey == 0x50, "physical key mapping for p");
        Expect(PhysicalKeyMapper.Map('A')?.Shift == true, "uppercase uses shift");
        Expect(PhysicalKeyMapper.Map('.')?.VirtualKey == 0xBE, "physical key mapping for period");
        Expect(PhysicalKeyMapper.Map('$')?.Shift == true, "shell symbol uses shift");
        Expect(KeyboardEmitter.InputStructureSize == (IntPtr.Size == 8 ? 40 : 28), "native INPUT layout");
        Expect(SafeLogger.Instance.ContentId("secret").Length == 12, "redacted content id");
        Console.WriteLine(failed == 0 ? "SELF-TEST OK" : $"SELF-TEST FAILED: {failed}");
        return failed == 0 ? 0 : 1;
    }
}

