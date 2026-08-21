using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace AudioOutputSwitcher
{
    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            if (args.Length == 1 && String.Equals(args[0], "--tray-preview", StringComparison.OrdinalIgnoreCase))
            {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                var context = new SwitcherContext();
                context.SaveTrayMenuPreview(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,
                    "AudioOutputSwitcher-tray-preview.png"));
                context.CloseForTest();
                return;
            }
            if (args.Length == 1 && String.Equals(args[0], "--volume-test", StringComparison.OrdinalIgnoreCase))
            {
                int before = AudioManager.GetMasterVolumePercent();
                AudioManager.SetMasterVolumePercent(before);
                int after = AudioManager.GetMasterVolumePercent();
                File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "AudioOutputSwitcher-volume-test.txt"),
                    "before=" + before + Environment.NewLine + "after=" + after + Environment.NewLine);
                return;
            }
            if (args.Length == 1 && String.Equals(args[0], "--export-icon", StringComparison.OrdinalIgnoreCase))
            {
                SwitcherContext.ExportAppIcon(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,
                    "AudioOutputSwitcher.ico"));
                return;
            }
            if (args.Length == 1 && String.Equals(args[0], "--cycle-test", StringComparison.OrdinalIgnoreCase))
            {
                List<AudioDevice> devices = AudioManager.GetActiveRenderDevices();
                string currentId = AudioManager.GetDefaultRenderDeviceId();
                int currentIndex = devices.FindIndex(d => String.Equals(d.Id, currentId, StringComparison.OrdinalIgnoreCase));
                AudioDevice next = devices[currentIndex < 0 ? 0 : (currentIndex + 1) % devices.Count];
                AudioManager.SetDefaultRenderDevice(next.Id);
                File.AppendAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "AudioOutputSwitcher.log"),
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " Test switched to: " + next.Name + Environment.NewLine);
                return;
            }
            if (args.Length == 1 && String.Equals(args[0], "--overlay-test", StringComparison.OrdinalIgnoreCase))
            {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                var testOverlay = new OverlayForm();
                List<AudioDevice> devices = AudioManager.GetActiveRenderDevices();
                if (!devices.Any(d => d.Name.IndexOf("AirPods", StringComparison.OrdinalIgnoreCase) >= 0))
                    devices.Add(new AudioDevice("preview-airpods", "AirPods Pro"));
                testOverlay.ShowMessage("声音输出（窗口测试）", devices, AudioManager.GetDefaultRenderDeviceId(), 12000);
                try
                {
                    using (var preview = new Bitmap(testOverlay.Width, testOverlay.Height))
                    {
                        testOverlay.DrawToBitmap(preview, new Rectangle(0, 0, preview.Width, preview.Height));
                        preview.Save(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "AudioOutputSwitcher-preview.png"));
                    }
                }
                catch (Exception renderError)
                {
                    File.AppendAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "AudioOutputSwitcher.log"),
                        DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " Preview render warning: " +
                        renderError.Message + Environment.NewLine);
                }
                var exitTimer = new Timer { Interval = 15000 };
                exitTimer.Tick += delegate { exitTimer.Stop(); Application.Exit(); };
                exitTimer.Start();
                Application.Run();
                return;
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new SwitcherContext());
        }
    }

    internal sealed class SwitcherContext : ApplicationContext
    {
        private readonly HotKeyWindow hotKeyWindow;
        private readonly NotifyIcon trayIcon;
        private readonly Icon trayAppIcon;
        private readonly OverlayForm overlay;
        private readonly TrayMenuForm trayMenu;
        private string pendingDeviceId;
        private DateTime suppressTrayClickUntil = DateTime.MinValue;

        public SwitcherContext()
        {
            overlay = new OverlayForm();
            hotKeyWindow = new HotKeyWindow();
            hotKeyWindow.HotKeyHeld += delegate { PreviewNext(); };
            hotKeyWindow.HotKeyPressed += delegate { ApplyPendingDevice(); };

            trayMenu = new TrayMenuForm();
            trayMenu.VolumeChanged += delegate(object sender, EventArgs e)
            {
                try { AudioManager.SetMasterVolumePercent(trayMenu.Volume); }
                catch (Exception ex) { Log("Volume ERROR: " + ex); }
            };
            trayMenu.DeviceSelected += delegate(object sender, DeviceSelectedEventArgs e)
            {
                SelectDeviceFromMenu(e.Device);
            };
            trayMenu.ExitRequested += delegate { ExitThread(); };
            trayMenu.Dismissed += delegate
            {
                suppressTrayClickUntil = DateTime.UtcNow.AddMilliseconds(500);
            };

            trayAppIcon = CreateTrayIcon();
            trayIcon = new NotifyIcon
            {
                Icon = trayAppIcon,
                Text = "声音输出切换器（Alt + V）",
                Visible = true
            };
            trayIcon.MouseClick += delegate(object sender, MouseEventArgs e)
            {
                if (e.Button == MouseButtons.Left)
                {
                    overlay.Hide();
                    if (DateTime.UtcNow <= suppressTrayClickUntil)
                    {
                        suppressTrayClickUntil = DateTime.MinValue;
                        return;
                    }

                    if (trayMenu.Visible)
                        trayMenu.Hide();
                    else
                    {
                        RefreshTrayMenu();
                        trayMenu.ShowAt(Cursor.Position);
                    }
                }
            };

            if (!hotKeyWindow.Register())
            {
                MessageBox.Show("无法启用 Alt + V 快捷键。", "声音输出切换器",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }

            LogDevices();
        }

        private void RefreshTrayMenu()
        {
            List<AudioDevice> devices;
            string currentId;
            try
            {
                devices = AudioManager.GetActiveRenderDevices();
                currentId = AudioManager.GetDefaultRenderDeviceId();
            }
            catch
            {
                devices = new List<AudioDevice>();
                currentId = null;
            }
            int volume;
            try { volume = AudioManager.GetMasterVolumePercent(); }
            catch { volume = 0; }
            trayMenu.RefreshContent(devices, currentId, volume);
        }

        private void SelectDeviceFromMenu(AudioDevice selected)
        {
            try
            {
                AudioManager.SetDefaultRenderDevice(selected.Id);
                Log("Menu switched to: " + selected.Name + " | " + selected.Id);
            }
            catch (Exception ex)
            {
                Log("Menu switch ERROR: " + ex);
            }
        }

        internal void SaveTrayMenuPreview(string path)
        {
            RefreshTrayMenu();
            trayMenu.Show();
            Application.DoEvents();
            trayMenu.Refresh();
            using (var bitmap = new Bitmap(trayMenu.Width, trayMenu.Height))
            {
                trayMenu.DrawToBitmap(bitmap, new Rectangle(Point.Empty, trayMenu.Size));
                bitmap.Save(path, ImageFormat.Png);
            }
            trayMenu.Hide();
        }

        internal void CloseForTest()
        {
            ExitThread();
        }

        private void SwitchToNext()
        {
            try
            {
                List<AudioDevice> devices = AudioManager.GetActiveRenderDevices();
                if (devices.Count == 0)
                {
                    overlay.ShowMessage("没有可用的声音输出设备", devices, null);
                    return;
                }

                string currentId = AudioManager.GetDefaultRenderDeviceId();
                int currentIndex = devices.FindIndex(d => String.Equals(d.Id, currentId, StringComparison.OrdinalIgnoreCase));
                int nextIndex = currentIndex < 0 ? 0 : (currentIndex + 1) % devices.Count;
                AudioDevice next = devices[nextIndex];
                AudioManager.SetDefaultRenderDevice(next.Id);
                overlay.ShowMessage("声音输出", devices, next.Id);
                Log("Switched to: " + next.Name + " | " + next.Id);
            }
            catch (Exception ex)
            {
                overlay.ShowMessage("切换失败：" + ex.Message, new List<AudioDevice>(), null);
                Log("ERROR: " + ex);
            }
        }

        private void PreviewNext()
        {
            try
            {
                List<AudioDevice> devices = AudioManager.GetActiveRenderDevices();
                if (devices.Count == 0)
                {
                    overlay.ShowMessage("没有可用的声音输出设备", devices, null, 600000);
                    return;
                }

                string baseId = String.IsNullOrEmpty(pendingDeviceId)
                    ? AudioManager.GetDefaultRenderDeviceId()
                    : pendingDeviceId;
                int currentIndex = devices.FindIndex(d => String.Equals(d.Id, baseId, StringComparison.OrdinalIgnoreCase));
                int nextIndex = currentIndex < 0 ? 0 : (currentIndex + 1) % devices.Count;
                pendingDeviceId = devices[nextIndex].Id;
                overlay.ShowMessage("松开 Alt 后应用", devices, pendingDeviceId, 600000);
            }
            catch (Exception ex)
            {
                Log("Preview ERROR: " + ex);
            }
        }

        private void ApplyPendingDevice()
        {
            if (String.IsNullOrEmpty(pendingDeviceId)) return;
            try
            {
                List<AudioDevice> devices = AudioManager.GetActiveRenderDevices();
                AudioDevice selected = devices.FirstOrDefault(d =>
                    String.Equals(d.Id, pendingDeviceId, StringComparison.OrdinalIgnoreCase));
                if (selected == null)
                {
                    pendingDeviceId = null;
                    return;
                }

                AudioManager.SetDefaultRenderDevice(selected.Id);
                overlay.ShowMessage("声音输出", devices, selected.Id);
                Log("Applied on Alt release: " + selected.Name + " | " + selected.Id);
                pendingDeviceId = null;
            }
            catch (Exception ex)
            {
                Log("Apply ERROR: " + ex);
                pendingDeviceId = null;
            }
        }

        private static void LogDevices()
        {
            try
            {
                List<AudioDevice> devices = AudioManager.GetActiveRenderDevices();
                string current = AudioManager.GetDefaultRenderDeviceId();
                Log("Started. Active outputs: " + String.Join("; ", devices.Select(d =>
                    (String.Equals(d.Id, current, StringComparison.OrdinalIgnoreCase) ? "[default] " : "") + d.Name)));
            }
            catch (Exception ex) { Log("Startup diagnostic error: " + ex); }
        }

        private static void Log(string text)
        {
            try
            {
                string path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "AudioOutputSwitcher.log");
                File.AppendAllText(path, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + text + Environment.NewLine);
            }
            catch { }
        }

        protected override void ExitThreadCore()
        {
            hotKeyWindow.Dispose();
            trayIcon.Visible = false;
            trayIcon.Dispose();
            trayMenu.Dispose();
            trayAppIcon.Dispose();
            overlay.Dispose();
            base.ExitThreadCore();
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool DestroyIcon(IntPtr iconHandle);

        internal static void ExportAppIcon(string path)
        {
            int[] sizes = { 16, 20, 24, 32, 40, 48, 64, 128, 256 };
            var images = new List<byte[]>();
            foreach (int size in sizes)
            {
                using (Bitmap bitmap = CreateIconBitmap(size))
                using (var stream = new MemoryStream())
                {
                    bitmap.Save(stream, ImageFormat.Png);
                    images.Add(stream.ToArray());
                }
            }

            using (var file = new FileStream(path, FileMode.Create, FileAccess.Write))
            using (var writer = new BinaryWriter(file))
            {
                writer.Write((ushort)0);
                writer.Write((ushort)1);
                writer.Write((ushort)sizes.Length);
                int offset = 6 + sizes.Length * 16;
                for (int i = 0; i < sizes.Length; i++)
                {
                    writer.Write((byte)(sizes[i] == 256 ? 0 : sizes[i]));
                    writer.Write((byte)(sizes[i] == 256 ? 0 : sizes[i]));
                    writer.Write((byte)0);
                    writer.Write((byte)0);
                    writer.Write((ushort)1);
                    writer.Write((ushort)32);
                    writer.Write(images[i].Length);
                    writer.Write(offset);
                    offset += images[i].Length;
                }
                foreach (byte[] image in images) writer.Write(image);
            }
        }

        private static Bitmap CreateIconBitmap(int size)
        {
            var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
            using (Graphics graphics = Graphics.FromImage(bitmap))
            {
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                graphics.Clear(Color.Transparent);
                float scale = size / 32F;

                using (var accent = new SolidBrush(Color.FromArgb(0, 120, 212)))
                    graphics.FillEllipse(accent, 2F * scale, 2F * scale, 28F * scale, 28F * scale);

                using (var white = new SolidBrush(Color.White))
                using (var soundPen = new Pen(Color.White, Math.Max(1F, 2.2F * scale)))
                {
                    graphics.FillRectangle(white, 8F * scale, 13F * scale, 5F * scale, 7F * scale);
                    graphics.FillPolygon(white, new[] {
                        new PointF(13F * scale, 13F * scale), new PointF(19F * scale, 9F * scale),
                        new PointF(19F * scale, 24F * scale), new PointF(13F * scale, 20F * scale)
                    });
                    soundPen.StartCap = LineCap.Round;
                    soundPen.EndCap = LineCap.Round;
                    graphics.DrawArc(soundPen, 16F * scale, 11F * scale, 9F * scale, 11F * scale, -55, 110);
                }
            }
            return bitmap;
        }

        private static Icon CreateTrayIcon()
        {
            using (Bitmap bitmap = CreateIconBitmap(32))
            {
                IntPtr handle = bitmap.GetHicon();
                try
                {
                    using (Icon temporary = Icon.FromHandle(handle))
                        return (Icon)temporary.Clone();
                }
                finally
                {
                    DestroyIcon(handle);
                }
            }
        }
    }

    internal sealed class DeviceSelectedEventArgs : EventArgs
    {
        public AudioDevice Device { get; private set; }
        public DeviceSelectedEventArgs(AudioDevice device) { Device = device; }
    }

    internal sealed class TrayMenuForm : Form
    {
        private readonly VolumeMenuControl volumeControl;
        private readonly Color menuBackColor = Color.FromArgb(30, 30, 33);

        public event EventHandler VolumeChanged;
        public event EventHandler<DeviceSelectedEventArgs> DeviceSelected;
        public event EventHandler ExitRequested;
        public event EventHandler Dismissed;
        public int Volume { get { return volumeControl.Volume; } }

        public TrayMenuForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            BackColor = menuBackColor;
            Opacity = 0.96;
            Width = 332;
            DoubleBuffered = true;
            Padding = Padding.Empty;

            volumeControl = new VolumeMenuControl
            {
                Location = new Point(10, 8),
                BackColor = menuBackColor
            };
            volumeControl.VolumeChanged += delegate
            {
                EventHandler handler = VolumeChanged;
                if (handler != null) handler(this, EventArgs.Empty);
            };
        }

        public void RefreshContent(IList<AudioDevice> devices, string currentId, int volume)
        {
            while (Controls.Count > 0)
            {
                Control old = Controls[0];
                Controls.RemoveAt(0);
                if (!Object.ReferenceEquals(old, volumeControl)) old.Dispose();
            }

            volumeControl.SetVolume(volume);
            volumeControl.Location = new Point(10, 8);
            Controls.Add(volumeControl);

            int y = 88;
            Controls.Add(new Panel
            {
                Location = new Point(10, y),
                Size = new Size(312, 1),
                BackColor = Color.FromArgb(66, 66, 72)
            });
            y += 8;

            Controls.Add(new Label
            {
                Text = "输出设备",
                Location = new Point(18, y),
                Size = new Size(296, 26),
                BackColor = menuBackColor,
                ForeColor = Color.FromArgb(155, 155, 164),
                Font = new Font("Microsoft YaHei UI", 8.8F),
                TextAlign = ContentAlignment.MiddleLeft,
                Cursor = Cursors.Default
            });
            y += 28;

            if (devices.Count == 0)
            {
                Controls.Add(new Label
                {
                    Text = "没有可用的输出设备",
                    Location = new Point(18, y),
                    Size = new Size(296, 44),
                    BackColor = menuBackColor,
                    ForeColor = Color.FromArgb(170, 170, 178),
                    Font = new Font("Microsoft YaHei UI", 9.2F),
                    TextAlign = ContentAlignment.MiddleLeft
                });
                y += 46;
            }
            else
            {
                foreach (AudioDevice device in devices)
                {
                    AudioDevice target = device;
                    bool current = String.Equals(target.Id, currentId, StringComparison.OrdinalIgnoreCase);
                    var row = new DeviceMenuRow(target.Name, current)
                    {
                        Location = new Point(10, y)
                    };
                    row.Click += delegate
                    {
                        EventHandler<DeviceSelectedEventArgs> handler = DeviceSelected;
                        if (handler != null) handler(this, new DeviceSelectedEventArgs(target));
                        Hide();
                    };
                    Controls.Add(row);
                    y += 46;
                }
            }

            y += 4;
            Controls.Add(new Panel
            {
                Location = new Point(10, y),
                Size = new Size(312, 1),
                BackColor = Color.FromArgb(66, 66, 72)
            });
            y += 7;

            var exitButton = new Button
            {
                Text = "退出声音输出切换器",
                Location = new Point(10, y),
                Size = new Size(312, 38),
                BackColor = menuBackColor,
                ForeColor = Color.White,
                FlatStyle = FlatStyle.Flat,
                Font = new Font("Microsoft YaHei UI", 9F),
                TextAlign = ContentAlignment.MiddleLeft,
                Cursor = Cursors.Hand,
                TabStop = false
            };
            exitButton.FlatAppearance.BorderSize = 0;
            exitButton.FlatAppearance.MouseOverBackColor = Color.FromArgb(48, 48, 54);
            exitButton.FlatAppearance.MouseDownBackColor = Color.FromArgb(58, 58, 65);
            exitButton.Click += delegate
            {
                EventHandler handler = ExitRequested;
                if (handler != null) handler(this, EventArgs.Empty);
            };
            Controls.Add(exitButton);
            Height = y + 48;
            UpdateRoundedRegion();
        }

        public void ShowAt(Point anchor)
        {
            Rectangle area = Screen.FromPoint(anchor).WorkingArea;
            int x = area.Right - Width - 12;
            int y = Math.Max(area.Top + 8, Math.Min(anchor.Y - Height - 10, area.Bottom - Height - 8));
            Location = new Point(x, y);
            Show();
            Activate();
            BringToFront();
        }

        protected override void OnDeactivate(EventArgs e)
        {
            base.OnDeactivate(e);
            if (!Visible) return;
            Hide();
            EventHandler handler = Dismissed;
            if (handler != null) handler(this, EventArgs.Empty);
        }

        protected override void OnSizeChanged(EventArgs e)
        {
            base.OnSizeChanged(e);
            UpdateRoundedRegion();
        }

        private void UpdateRoundedRegion()
        {
            if (Width <= 0 || Height <= 0) return;
            Rectangle bounds = new Rectangle(0, 0, Width, Height);
            using (GraphicsPath path = RoundedRectangle(bounds, 14))
            {
                Region old = Region;
                Region = new Region(path);
                if (old != null) old.Dispose();
            }
        }

        private static GraphicsPath RoundedRectangle(Rectangle bounds, int radius)
        {
            int d = radius * 2;
            var path = new GraphicsPath();
            path.AddArc(bounds.Left, bounds.Top, d, d, 180, 90);
            path.AddArc(bounds.Right - d - 1, bounds.Top, d, d, 270, 90);
            path.AddArc(bounds.Right - d - 1, bounds.Bottom - d - 1, d, d, 0, 90);
            path.AddArc(bounds.Left, bounds.Bottom - d - 1, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }
    }

    internal sealed class DeviceMenuRow : Control
    {
        private enum IconKind { Speaker, Laptop, AirPods, Headset, Monitor, Virtual }
        private readonly string deviceName;
        private readonly bool current;
        private readonly IconKind iconKind;
        private bool hovered;

        public DeviceMenuRow(string name, bool isCurrent)
        {
            deviceName = name;
            current = isCurrent;
            iconKind = Classify(name);
            Size = new Size(312, 44);
            BackColor = Color.FromArgb(30, 30, 33);
            Cursor = Cursors.Hand;
            DoubleBuffered = true;
            SetStyle(ControlStyles.Selectable, false);
        }

        protected override void OnMouseEnter(EventArgs e) { hovered = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hovered = false; Invalidate(); base.OnMouseLeave(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Color rowColor = current ? Color.FromArgb(40, 62, 84)
                : (hovered ? Color.FromArgb(48, 48, 54) : BackColor);
            using (GraphicsPath path = RoundedRectangle(new Rectangle(0, 1, Width - 1, Height - 2), 9))
            using (var brush = new SolidBrush(rowColor))
                g.FillPath(brush, path);

            Color iconColor = current ? Color.FromArgb(120, 190, 255) : Color.FromArgb(205, 205, 214);
            using (var brush = new SolidBrush(iconColor))
            using (var pen = new Pen(iconColor, 1.8F))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                DrawIcon(g, brush, pen, rowColor);
            }

            using (Font font = new Font("Microsoft YaHei UI", 9.3F,
                current ? FontStyle.Bold : FontStyle.Regular))
                TextRenderer.DrawText(g, deviceName, font, new Rectangle(52, 0, 224, Height), Color.White,
                    TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);

            if (current)
            {
                using (var pen = new Pen(Color.FromArgb(105, 185, 255), 2F))
                {
                    pen.StartCap = LineCap.Round;
                    pen.EndCap = LineCap.Round;
                    g.DrawLines(pen, new[] { new Point(285, 22), new Point(290, 27), new Point(299, 17) });
                }
            }
        }

        private void DrawIcon(Graphics g, Brush brush, Pen pen, Color cutoutColor)
        {
            if (iconKind == IconKind.AirPods)
            {
                using (var cutout = new SolidBrush(cutoutColor))
                {
                    g.FillEllipse(brush, 14, 12, 11, 10);
                    g.FillRectangle(brush, 21, 18, 5, 16);
                    g.FillEllipse(cutout, 16, 15, 4, 3);
                    g.FillEllipse(brush, 29, 12, 11, 10);
                    g.FillRectangle(brush, 28, 18, 5, 16);
                    g.FillEllipse(cutout, 35, 15, 4, 3);
                }
                return;
            }
            if (iconKind == IconKind.Laptop)
            {
                using (GraphicsPath screen = RoundedRectangle(new Rectangle(14, 10, 28, 21), 3)) g.DrawPath(pen, screen);
                g.FillPolygon(brush, new[] { new Point(12, 34), new Point(44, 34), new Point(47, 38), new Point(9, 38) });
                return;
            }
            if (iconKind == IconKind.Headset)
            {
                g.DrawArc(pen, 14, 10, 28, 27, 180, 180);
                g.FillRectangle(brush, 12, 24, 6, 13);
                g.FillRectangle(brush, 38, 24, 6, 13);
                return;
            }
            if (iconKind == IconKind.Monitor)
            {
                using (GraphicsPath screen = RoundedRectangle(new Rectangle(14, 9, 28, 22), 3)) g.DrawPath(pen, screen);
                g.DrawLine(pen, 28, 31, 28, 36);
                g.DrawLine(pen, 22, 37, 34, 37);
                return;
            }
            if (iconKind == IconKind.Virtual)
            {
                int[] xs = { 13, 20, 27, 34, 41 };
                int[] hs = { 4, 8, 13, 8, 4 };
                for (int i = 0; i < xs.Length; i++) g.DrawLine(pen, xs[i], 22 - hs[i], xs[i], 22 + hs[i]);
                return;
            }
            g.FillRectangle(brush, 13, 18, 6, 9);
            g.FillPolygon(brush, new[] { new Point(19, 18), new Point(28, 12), new Point(28, 33), new Point(19, 27) });
            g.DrawArc(pen, 27, 15, 12, 15, -55, 110);
            g.DrawArc(pen, 26, 11, 19, 23, -55, 110);
        }

        private static IconKind Classify(string name)
        {
            if (Contains(name, "AirPods")) return IconKind.AirPods;
            if (Contains(name, "虚拟") || Contains(name, "Virtual")) return IconKind.Virtual;
            if (Contains(name, "MCHOSE") || Contains(name, "HEADSET") || Contains(name, "耳机") || Contains(name, "Headphone")) return IconKind.Headset;
            if (Contains(name, "NVIDIA") || Contains(name, "HDMI") || Contains(name, "Display") || Contains(name, "H27")) return IconKind.Monitor;
            if (Contains(name, "Realtek")) return IconKind.Laptop;
            return IconKind.Speaker;
        }

        private static bool Contains(string value, string token)
        {
            return value != null && value.IndexOf(token, StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private static GraphicsPath RoundedRectangle(Rectangle bounds, int radius)
        {
            int d = radius * 2;
            var path = new GraphicsPath();
            path.AddArc(bounds.Left, bounds.Top, d, d, 180, 90);
            path.AddArc(bounds.Right - d, bounds.Top, d, d, 270, 90);
            path.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90);
            path.AddArc(bounds.Left, bounds.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }
    }

    internal sealed class VolumeMenuControl : UserControl
    {
        private int volume;
        private bool dragging;
        public event EventHandler VolumeChanged;
        public int Volume { get { return volume; } }

        public VolumeMenuControl()
        {
            Size = new Size(312, 78);
            BackColor = Color.FromArgb(30, 30, 33);
            ForeColor = Color.White;
            DoubleBuffered = true;
            Cursor = Cursors.Hand;
        }

        public void SetVolume(int value)
        {
            volume = Math.Max(0, Math.Min(100, value));
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            Graphics graphics = e.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;

            using (Font titleFont = new Font("Microsoft YaHei UI", 10F, FontStyle.Bold))
                TextRenderer.DrawText(graphics, "音量", titleFont, new Rectangle(16, 10, 150, 25),
                    Color.White, TextFormatFlags.Left | TextFormatFlags.VerticalCenter);
            using (Font valueFont = new Font("Microsoft YaHei UI", 9.5F, FontStyle.Regular))
                TextRenderer.DrawText(graphics, volume + "%", valueFont, new Rectangle(210, 10, 86, 25),
                    Color.FromArgb(185, 185, 194), TextFormatFlags.Right | TextFormatFlags.VerticalCenter);

            RectangleF fullTrack = new RectangleF(16, 49, 280, 6);
            using (GraphicsPath path = RoundedRectangle(fullTrack, 3F))
            using (var trackBrush = new SolidBrush(Color.FromArgb(72, 72, 78)))
                graphics.FillPath(trackBrush, path);

            float filledWidth = 280F * volume / 100F;
            if (filledWidth > 0)
            {
                RectangleF filledTrack = new RectangleF(16, 49, Math.Max(6, filledWidth), 6);
                using (GraphicsPath path = RoundedRectangle(filledTrack, 3F))
                using (var accentBrush = new SolidBrush(Color.FromArgb(10, 132, 255)))
                    graphics.FillPath(accentBrush, path);
            }

            float knobX = 16 + filledWidth;
            using (var shadow = new SolidBrush(Color.FromArgb(65, 0, 0, 0)))
                graphics.FillEllipse(shadow, knobX - 8, 43, 17, 17);
            using (var knob = new SolidBrush(Color.White))
                graphics.FillEllipse(knob, knobX - 7, 42, 16, 16);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button != MouseButtons.Left) return;
            dragging = true;
            Capture = true;
            UpdateFromMouse(e.X);
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (dragging) UpdateFromMouse(e.X);
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            dragging = false;
            Capture = false;
        }

        private void UpdateFromMouse(int x)
        {
            int next = (int)Math.Round((Math.Max(16, Math.Min(296, x)) - 16) * 100D / 280D);
            if (next == volume) return;
            volume = next;
            Invalidate();
            EventHandler handler = VolumeChanged;
            if (handler != null) handler(this, EventArgs.Empty);
        }

        private static GraphicsPath RoundedRectangle(RectangleF bounds, float radius)
        {
            float diameter = radius * 2F;
            var path = new GraphicsPath();
            path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
            path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
            path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
            path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
            path.CloseFigure();
            return path;
        }
    }

    internal sealed class DarkMenuColorTable : ProfessionalColorTable
    {
        public override Color ToolStripDropDownBackground { get { return Color.FromArgb(30, 30, 33); } }
        public override Color ImageMarginGradientBegin { get { return Color.FromArgb(30, 30, 33); } }
        public override Color ImageMarginGradientMiddle { get { return Color.FromArgb(30, 30, 33); } }
        public override Color ImageMarginGradientEnd { get { return Color.FromArgb(30, 30, 33); } }
        public override Color MenuBorder { get { return Color.FromArgb(64, 64, 70); } }
        public override Color MenuItemBorder { get { return Color.FromArgb(75, 138, 220); } }
        public override Color MenuItemSelected { get { return Color.FromArgb(48, 84, 128); } }
        public override Color MenuItemSelectedGradientBegin { get { return Color.FromArgb(48, 84, 128); } }
        public override Color MenuItemSelectedGradientEnd { get { return Color.FromArgb(48, 84, 128); } }
        public override Color SeparatorDark { get { return Color.FromArgb(64, 64, 70); } }
        public override Color SeparatorLight { get { return Color.FromArgb(64, 64, 70); } }
    }

    internal sealed class HotKeyWindow : IDisposable
    {
        private const int VK_V = 0x56;
        private const int VK_MENU = 0x12;
        private readonly Timer keyTimer;
        private bool armed;
        private bool selectionSession;

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int virtualKey);

        public event EventHandler HotKeyPressed;
        public event EventHandler HotKeyHeld;

        public HotKeyWindow()
        {
            keyTimer = new Timer { Interval = 15 };
            keyTimer.Tick += CheckKeys;
        }

        public bool Register()
        {
            keyTimer.Start();
            return true;
        }

        private static bool IsDown(int virtualKey)
        {
            return (GetAsyncKeyState(virtualKey) & 0x8000) != 0;
        }

        private void CheckKeys(object sender, EventArgs e)
        {
            bool vDown = IsDown(VK_V);
            bool altDown = IsDown(VK_MENU);

            if (!armed && vDown && altDown)
            {
                armed = true;
                selectionSession = true;
                EventHandler heldHandler = HotKeyHeld;
                if (heldHandler != null) heldHandler(this, EventArgs.Empty);
            }

            if (armed && !vDown)
                armed = false;

            if (selectionSession && !altDown)
            {
                armed = false;
                selectionSession = false;
                EventHandler handler = HotKeyPressed;
                if (handler != null) handler(this, EventArgs.Empty);
            }
        }

        public void Dispose()
        {
            keyTimer.Stop();
            keyTimer.Dispose();
        }
    }

    internal sealed class OverlayForm : Form
    {
        private readonly Timer hideTimer;
        private readonly Timer fadeTimer;
        private bool fadingOut;
        private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        private const uint SWP_SHOWWINDOW = 0x0040;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
            int x, int y, int width, int height, uint flags);

        [DllImport("gdi32.dll")]
        private static extern IntPtr CreateRoundRectRgn(int left, int top, int right, int bottom, int width, int height);

        [DllImport("gdi32.dll")]
        private static extern bool DeleteObject(IntPtr handle);

        public OverlayForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            Text = "声音输出切换器";
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            BackColor = Color.FromArgb(28, 28, 31);
            Opacity = 0.01;
            Width = 456;
            AutoSize = false;
            Padding = Padding.Empty;
            DoubleBuffered = true;

            hideTimer = new Timer { Interval = 3000 };
            hideTimer.Tick += delegate
            {
                hideTimer.Stop();
                fadingOut = true;
                fadeTimer.Start();
            };

            fadeTimer = new Timer { Interval = 16 };
            fadeTimer.Tick += delegate
            {
                if (fadingOut)
                {
                    Opacity = Math.Max(0.01, Opacity - 0.12);
                    if (Opacity <= 0.02)
                    {
                        fadeTimer.Stop();
                        Hide();
                    }
                }
                else
                {
                    Opacity = Math.Min(0.98, Opacity + 0.14);
                    if (Opacity >= 0.98) fadeTimer.Stop();
                }
            };
        }

        protected override CreateParams CreateParams
        {
            get
            {
                const int CS_DROPSHADOW = 0x00020000;
                CreateParams cp = base.CreateParams;
                cp.ClassStyle |= CS_DROPSHADOW;
                return cp;
            }
        }

        protected override void OnSizeChanged(EventArgs e)
        {
            base.OnSizeChanged(e);
            IntPtr regionHandle = CreateRoundRectRgn(0, 0, Width + 1, Height + 1, 24, 24);
            Region oldRegion = Region;
            Region = Region.FromHrgn(regionHandle);
            DeleteObject(regionHandle);
            if (oldRegion != null) oldRegion.Dispose();
        }

        public void ShowMessage(string title, IList<AudioDevice> devices, string selectedId, int hideAfterMs = 3000)
        {
            SuspendLayout();
            Controls.Clear();

            var header = new Panel
            {
                Location = new Point(22, 18),
                Size = new Size(412, 58),
                BackColor = BackColor
            };

            header.Controls.Add(new Label
            {
                Text = "声音输出",
                ForeColor = Color.White,
                Font = new Font("Microsoft YaHei UI", 15F, FontStyle.Bold),
                AutoSize = false,
                Location = new Point(0, 0),
                Size = new Size(412, 31),
                TextAlign = ContentAlignment.MiddleLeft
            });

            string subtitle = title.IndexOf("松开", StringComparison.Ordinal) >= 0
                ? "按 V 选择下一个  ·  松开 Alt 应用"
                : (title.IndexOf("测试", StringComparison.Ordinal) >= 0 ? "界面预览" : "当前输出设备");

            header.Controls.Add(new Label
            {
                Text = subtitle,
                ForeColor = Color.FromArgb(170, 170, 178),
                Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Regular),
                AutoSize = false,
                Location = new Point(1, 33),
                Size = new Size(411, 22),
                TextAlign = ContentAlignment.MiddleLeft
            });

            var panel = new BufferedFlowLayoutPanel
            {
                Location = new Point(22, 83),
                Width = 412,
                FlowDirection = FlowDirection.TopDown,
                WrapContents = false,
                AutoScroll = false,
                BackColor = BackColor,
                Padding = Padding.Empty,
                Margin = Padding.Empty
            };

            foreach (AudioDevice device in devices)
            {
                bool selected = String.Equals(device.Id, selectedId, StringComparison.OrdinalIgnoreCase);
                panel.Controls.Add(new DeviceCard(device.Name, selected,
                    title.IndexOf("松开", StringComparison.Ordinal) >= 0));
            }

            panel.Height = Math.Max(66, devices.Count * 66);
            Height = Math.Min(560, 101 + panel.Height);
            Controls.Add(header);
            Controls.Add(panel);
            Rectangle area = Screen.FromPoint(Cursor.Position).WorkingArea;
            Location = new Point(area.Right - Width - 18, area.Top + Math.Max(18, (area.Height - Height) / 2));
            ResumeLayout(true);

            fadingOut = false;
            fadeTimer.Stop();
            Opacity = Visible ? 0.98 : 0.01;
            Show();
            SetWindowPos(Handle, HWND_TOPMOST, Left, Top, Width, Height, SWP_SHOWWINDOW);
            Activate();
            BringToFront();
            Refresh();
            fadeTimer.Start();
            hideTimer.Stop();
            hideTimer.Interval = hideAfterMs;
            hideTimer.Start();
        }
    }

    internal sealed class BufferedFlowLayoutPanel : FlowLayoutPanel
    {
        public BufferedFlowLayoutPanel()
        {
            DoubleBuffered = true;
            ResizeRedraw = true;
        }
    }

    internal sealed class DeviceCard : Control
    {
        private readonly string deviceName;
        private readonly bool selected;
        private readonly bool preview;
        private readonly DeviceIconKind iconKind;

        private enum DeviceIconKind { Speaker, Laptop, AirPods, Headset, Monitor, Virtual }

        public DeviceCard(string name, bool isSelected, bool isPreview)
        {
            deviceName = name;
            selected = isSelected;
            preview = isPreview;
            iconKind = ClassifyDevice(name);
            Size = new Size(412, 58);
            Margin = new Padding(0, 0, 0, 8);
            DoubleBuffered = true;
            BackColor = Color.FromArgb(28, 28, 31);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            Graphics graphics = e.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle cardBounds = new Rectangle(0, 0, Width - 1, Height - 1);

            using (GraphicsPath path = RoundedRectangle(cardBounds, 14))
            using (SolidBrush background = new SolidBrush(selected
                ? Color.FromArgb(0, 95, 184)
                : Color.FromArgb(43, 43, 48)))
            {
                graphics.FillPath(background, path);
                using (Pen border = new Pen(selected
                    ? Color.FromArgb(75, 170, 255)
                    : Color.FromArgb(58, 58, 64), 1F))
                    graphics.DrawPath(border, path);
            }

            Color iconColor = selected ? Color.White : Color.FromArgb(195, 195, 204);
            using (SolidBrush iconBrush = new SolidBrush(iconColor))
            using (Pen iconPen = new Pen(iconColor, 2F))
            {
                iconPen.StartCap = LineCap.Round;
                iconPen.EndCap = LineCap.Round;
                DrawDeviceIcon(graphics, iconBrush, iconPen);
            }

            Rectangle nameBounds = new Rectangle(57, selected ? 8 : 17, 310, 24);
            using (Font nameFont = new Font("Microsoft YaHei UI", 10.2F,
                selected ? FontStyle.Bold : FontStyle.Regular))
                TextRenderer.DrawText(graphics, deviceName, nameFont, nameBounds, Color.White,
                    TextFormatFlags.EndEllipsis | TextFormatFlags.VerticalCenter);

            if (selected)
            {
                string status = preview ? "松开 Alt 后应用此设备" : "当前正在使用";
                using (Font statusFont = new Font("Microsoft YaHei UI", 8.2F, FontStyle.Regular))
                    TextRenderer.DrawText(graphics, status, statusFont,
                        new Rectangle(58, 31, 300, 19), Color.FromArgb(220, 235, 250),
                        TextFormatFlags.EndEllipsis | TextFormatFlags.VerticalCenter);

                using (SolidBrush checkBackground = new SolidBrush(Color.White))
                    graphics.FillEllipse(checkBackground, 372, 17, 24, 24);
                using (Pen checkPen = new Pen(Color.FromArgb(0, 95, 184), 2.2F))
                {
                    checkPen.StartCap = LineCap.Round;
                    checkPen.EndCap = LineCap.Round;
                    graphics.DrawLines(checkPen, new[] {
                        new Point(379, 29), new Point(384, 34), new Point(391, 25)
                    });
                }
            }
        }

        private void DrawDeviceIcon(Graphics graphics, Brush iconBrush, Pen iconPen)
        {
            if (iconKind == DeviceIconKind.AirPods)
            {
                Color cutoutColor = selected ? Color.FromArgb(0, 95, 184) : Color.FromArgb(43, 43, 48);
                using (var cutout = new SolidBrush(cutoutColor))
                {
                    graphics.FillEllipse(iconBrush, 16, 16, 14, 12);
                    using (GraphicsPath leftStem = RoundedRectangle(new Rectangle(24, 23, 6, 21), 3))
                        graphics.FillPath(iconBrush, leftStem);
                    graphics.FillEllipse(cutout, 18, 19, 5, 4);

                    graphics.FillEllipse(iconBrush, 34, 16, 14, 12);
                    using (GraphicsPath rightStem = RoundedRectangle(new Rectangle(34, 23, 6, 21), 3))
                        graphics.FillPath(iconBrush, rightStem);
                    graphics.FillEllipse(cutout, 41, 19, 5, 4);
                }
                return;
            }

            if (iconKind == DeviceIconKind.Laptop)
            {
                iconPen.Width = 1.8F;
                using (GraphicsPath screen = RoundedRectangle(new Rectangle(17, 14, 30, 23), 3))
                    graphics.DrawPath(iconPen, screen);
                graphics.FillEllipse(iconBrush, 31, 16, 2, 2);
                using (var basePath = new GraphicsPath())
                {
                    basePath.AddLine(16, 40, 48, 40);
                    basePath.AddLine(48, 40, 51, 44);
                    basePath.AddLine(51, 44, 13, 44);
                    basePath.CloseFigure();
                    graphics.FillPath(iconBrush, basePath);
                }
                Color notchColor = selected ? Color.FromArgb(0, 95, 184) : Color.FromArgb(43, 43, 48);
                using (var notch = new SolidBrush(notchColor))
                    graphics.FillRectangle(notch, 29, 40, 6, 2);
                return;
            }

            if (iconKind == DeviceIconKind.Headset)
            {
                iconPen.Width = 2F;
                graphics.DrawArc(iconPen, 18, 14, 28, 28, 180, 180);
                using (GraphicsPath leftCup = RoundedRectangle(new Rectangle(16, 28, 7, 14), 3))
                    graphics.FillPath(iconBrush, leftCup);
                using (GraphicsPath rightCup = RoundedRectangle(new Rectangle(41, 28, 7, 14), 3))
                    graphics.FillPath(iconBrush, rightCup);
                return;
            }

            if (iconKind == DeviceIconKind.Monitor)
            {
                iconPen.Width = 1.8F;
                using (GraphicsPath screen = RoundedRectangle(new Rectangle(17, 14, 30, 23), 3))
                    graphics.DrawPath(iconPen, screen);
                graphics.DrawLine(iconPen, 32, 37, 32, 43);
                graphics.DrawLine(iconPen, 25, 44, 39, 44);
                return;
            }

            if (iconKind == DeviceIconKind.Virtual)
            {
                iconPen.Width = 2.2F;
                int[] x = { 18, 25, 32, 39, 46 };
                int[] halfHeight = { 4, 9, 14, 8, 3 };
                for (int i = 0; i < x.Length; i++)
                    graphics.DrawLine(iconPen, x[i], 29 - halfHeight[i], x[i], 29 + halfHeight[i]);
                return;
            }

            iconPen.Width = 1.8F;
            graphics.FillRectangle(iconBrush, 18, 25, 6, 9);
            Point[] speaker = {
                new Point(24, 25), new Point(33, 19), new Point(33, 40), new Point(24, 34)
            };
            graphics.FillPolygon(iconBrush, speaker);
            graphics.DrawArc(iconPen, 30, 21, 13, 16, -55, 110);
            graphics.DrawArc(iconPen, 29, 17, 20, 24, -55, 110);
        }

        private static DeviceIconKind ClassifyDevice(string name)
        {
            if (Contains(name, "AirPods"))
                return DeviceIconKind.AirPods;
            if (Contains(name, "虚拟") || Contains(name, "Virtual"))
                return DeviceIconKind.Virtual;
            if (Contains(name, "MCHOSE") || Contains(name, "HEADSET") ||
                Contains(name, "耳机") || Contains(name, "Headphone"))
                return DeviceIconKind.Headset;
            if (Contains(name, "NVIDIA") || Contains(name, "HDMI") ||
                Contains(name, "Display") || Contains(name, "H27"))
                return DeviceIconKind.Monitor;
            if (Contains(name, "Realtek"))
                return DeviceIconKind.Laptop;
            return DeviceIconKind.Speaker;
        }

        private static bool Contains(string value, string token)
        {
            return value != null && value.IndexOf(token, StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private static GraphicsPath RoundedRectangle(Rectangle bounds, int radius)
        {
            int diameter = radius * 2;
            var path = new GraphicsPath();
            path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
            path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
            path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
            path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
            path.CloseFigure();
            return path;
        }
    }

    internal sealed class AudioDevice
    {
        public string Id { get; private set; }
        public string Name { get; private set; }
        public AudioDevice(string id, string name) { Id = id; Name = name; }
    }

    internal static class AudioManager
    {
        private const int DEVICE_STATE_ACTIVE = 0x00000001;
        private static readonly PropertyKey PKEY_Device_FriendlyName =
            new PropertyKey(new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"), 14);

        public static List<AudioDevice> GetActiveRenderDevices()
        {
            var result = new List<AudioDevice>();
            var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
            IMMDeviceCollection collection;
            Marshal.ThrowExceptionForHR(enumerator.EnumAudioEndpoints(EDataFlow.eRender, DEVICE_STATE_ACTIVE, out collection));
            uint count;
            Marshal.ThrowExceptionForHR(collection.GetCount(out count));
            for (uint i = 0; i < count; i++)
            {
                IMMDevice device;
                collection.Item(i, out device);
                string id;
                device.GetId(out id);
                IPropertyStore store;
                device.OpenPropertyStore(0, out store);
                PropVariant value;
                PropertyKey friendlyNameKey = PKEY_Device_FriendlyName;
                store.GetValue(ref friendlyNameKey, out value);
                string name = value.GetString();
                value.Clear();
                result.Add(new AudioDevice(id, String.IsNullOrWhiteSpace(name) ? id : name));
            }
            return result;
        }

        public static string GetDefaultRenderDeviceId()
        {
            var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
            IMMDevice device;
            Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(EDataFlow.eRender, ERole.eMultimedia, out device));
            string id;
            device.GetId(out id);
            return id;
        }

        public static void SetDefaultRenderDevice(string id)
        {
            var policy = (IPolicyConfig)new PolicyConfigClient();
            for (int role = 0; role <= 2; role++)
                Marshal.ThrowExceptionForHR(policy.SetDefaultEndpoint(id, role));
        }

        public static int GetMasterVolumePercent()
        {
            IAudioEndpointVolume endpointVolume = GetDefaultEndpointVolume();
            float scalar;
            Marshal.ThrowExceptionForHR(endpointVolume.GetMasterVolumeLevelScalar(out scalar));
            return Math.Max(0, Math.Min(100, (int)Math.Round(scalar * 100F)));
        }

        public static void SetMasterVolumePercent(int percent)
        {
            IAudioEndpointVolume endpointVolume = GetDefaultEndpointVolume();
            Guid eventContext = Guid.Empty;
            float scalar = Math.Max(0, Math.Min(100, percent)) / 100F;
            Marshal.ThrowExceptionForHR(endpointVolume.SetMasterVolumeLevelScalar(scalar, ref eventContext));
        }

        private static IAudioEndpointVolume GetDefaultEndpointVolume()
        {
            var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
            IMMDevice device;
            Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(
                EDataFlow.eRender, ERole.eMultimedia, out device));
            Guid iid = new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");
            IntPtr pointer;
            Marshal.ThrowExceptionForHR(device.Activate(ref iid, 23, IntPtr.Zero, out pointer));
            try { return (IAudioEndpointVolume)Marshal.GetObjectForIUnknown(pointer); }
            finally { Marshal.Release(pointer); }
        }
    }

    internal enum EDataFlow { eRender, eCapture, eAll }
    internal enum ERole { eConsole, eMultimedia, eCommunications }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    internal class MMDeviceEnumeratorComObject { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(EDataFlow dataFlow, int stateMask, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice endpoint);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int Item(uint index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, out IntPtr iface);
        [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore properties);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioEndpointVolume
    {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int GetChannelCount(out uint channelCount);
        [PreserveSig] int SetMasterVolumeLevel(float levelDb, ref Guid eventContext);
        [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid eventContext);
        [PreserveSig] int GetMasterVolumeLevel(out float levelDb);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PropertyKey
    {
        public Guid FormatId;
        public int PropertyId;
        public PropertyKey(Guid formatId, int propertyId) { FormatId = formatId; PropertyId = propertyId; }
    }

    [StructLayout(LayoutKind.Explicit)]
    internal struct PropVariant
    {
        [FieldOffset(0)] private ushort vt;
        [FieldOffset(8)] private IntPtr pointerValue;

        public string GetString()
        {
            return vt == 31 && pointerValue != IntPtr.Zero ? Marshal.PtrToStringUni(pointerValue) : null;
        }

        public void Clear() { PropVariantClear(ref this); }
        [DllImport("ole32.dll")] private static extern int PropVariantClear(ref PropVariant variant);
    }

    [ComImport, Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")]
    internal class PolicyConfigClient { }

    [ComImport, Guid("F8679F50-850A-41CF-9C72-430F290290C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPolicyConfig
    {
        [PreserveSig] int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, out IntPtr format);
        [PreserveSig] int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int defaultFormat, out IntPtr format);
        [PreserveSig] int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId);
        [PreserveSig] int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr endpointFormat, IntPtr mixFormat);
        [PreserveSig] int GetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int defaultPeriod, out long period, out long minimumPeriod);
        [PreserveSig] int SetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string deviceId, ref long period);
        [PreserveSig] int GetShareMode([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr mode);
        [PreserveSig] int SetShareMode([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr mode);
        [PreserveSig] int GetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string deviceId, ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string deviceId, ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int role);
        [PreserveSig] int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int visible);
    }
}
