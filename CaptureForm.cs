using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace SnapTool
{
    public enum Tool { Rect, Arrow, Pen, Text, Mosaic, Number, Highlight, Ellipse, Line, Select }

    internal sealed class Annotation : IDisposable
    {
        public Tool Tool;
        public Point P1, P2;
        public List<Point> Points;
        public string Text;
        public Color Color;
        public float Width = 3;
        public float FontSize = 20;
        public int Block = 8;      // 马赛克粒度
        public int Number;
        public bool Filled;
        public bool DoubleArrow;
        internal bool BoundsValid;
        internal RectangleF CachedBounds;
        internal Bitmap MosaicPreview;
        internal Rectangle MosaicSource;
        internal int MosaicPreviewBlock;
        private Point[] _drawingPoints;
        private int _drawingCount = -1;
        private Point _drawingLast;

        internal Point[] DrawingPoints
        {
            get
            {
                if (Points == null) return null;
                Point last = Points.Count == 0 ? Point.Empty : Points[Points.Count - 1];
                if (_drawingPoints == null || _drawingCount != Points.Count || _drawingLast != last)
                { _drawingPoints = Points.ToArray(); _drawingCount = Points.Count; _drawingLast = last; }
                return _drawingPoints;
            }
        }

        internal void InvalidateCache()
        {
            BoundsValid = false;
            _drawingPoints = null;
            if (MosaicPreview != null) { MosaicPreview.Dispose(); MosaicPreview = null; }
        }
        public void Dispose() { InvalidateCache(); }
    }

    internal enum AnnotationChangeKind { Add, Delete, Move, Style }
    internal sealed class AnnotationStyle
    {
        internal Color Color;
        internal float Width, FontSize;
        internal int Block;
        internal bool Filled, DoubleArrow;
        internal AnnotationStyle(Annotation item)
        { Color = item.Color; Width = item.Width; FontSize = item.FontSize; Block = item.Block; Filled = item.Filled; DoubleArrow = item.DoubleArrow; }
        internal void Apply(Annotation item)
        { item.Color = Color; item.Width = Width; item.FontSize = FontSize; item.Block = Block; item.Filled = Filled; item.DoubleArrow = DoubleArrow; item.InvalidateCache(); }
    }
    internal sealed class AnnotationChange
    {
        internal AnnotationChangeKind Kind;
        internal Annotation Item;
        internal int Index;
        internal Point Delta;
        internal AnnotationStyle BeforeStyle, AfterStyle;
    }

    /// <summary>截图主窗体:全屏遮罩 → 框选/窗口识别 → 标注 → 输出。</summary>
    internal sealed class CaptureForm : Form
    {
        private readonly Bitmap _screen;
        private readonly Point _origin;

        private enum Mode { Selecting, Editing }
        private enum HandleEdge { None, Left, Right, Top, Bottom, TL, TR, BL, BR }
        private Mode _mode = Mode.Selecting;

        private Rectangle _sel = Rectangle.Empty;
        private CaptureShape _shape = CaptureShape.Rectangle;
        private readonly List<Point> _polygonPoints = new List<Point>();
        private Point[] _polygonDragOrigin;
        private bool _polygonClosed;
        private DateTime _polygonCompletedAt = DateTime.MinValue;
        private Point _down;
        private Point _downStart;
        private bool _dragging;
        private bool _userDragging;     // 真正拖动框选(超过阈值)
        private bool _movingSel;        // 调整态:正在拖动移动选区
        private Rectangle _moveOrig;    // 移动起始时的选区
        private bool _resizing;         // 调整态:正在拖动边/角缩放选区
        private Rectangle _resizeOrig;  // 缩放起始时的选区
        private HandleEdge _activeHandle;  // 当前抓住的边/角

        private Rectangle _hoverRect = Rectangle.Empty;
        private string _hoverTitle;

        private readonly List<Annotation> _items = new List<Annotation>();
        private readonly HashSet<Annotation> _ownedAnnotations = new HashSet<Annotation>();
        private readonly Stack<AnnotationChange> _undoHistory = new Stack<AnnotationChange>();
        private readonly Stack<AnnotationChange> _redoHistory = new Stack<AnnotationChange>();
        private Annotation _selectedAnnotation;
        private bool _movingAnnotation;
        private Point _annotationMoveDelta;
        private Point _annotationLastPoint;
        private Annotation _lastClickAnnotation;
        private DateTime _lastAnnotationClickAt;
        private Annotation _current;
        private Tool _tool = Tool.Rect;
        private Color _color = Color.Red;
        private float _penWidth = 3;      // 矩形/箭头/画笔线宽(可调)
        private float _fontSize = 20;     // 文字字号(可调)
        private int _mosaicBlock = 8;     // 马赛克粒度(可调)
        private int _numberCounter = 1;

        private Point _mouse;

        // 参数提示(调节线宽/字号/马赛克粒度时的短暂浮字)
        private string _toast;
        private DateTime _toastUntil = DateTime.MinValue;
        private readonly Timer _toastTimer;
        private Font _tbFont;
        private readonly Font _toolbarFont = new Font("Microsoft YaHei UI", 9);
        private readonly ToolTip _toolTips = new ToolTip();
        private Point _textOrigin;
        private bool _finishingText;

        // 本次会话内记住上次保存目录与格式
        private static string _lastSaveDir;
        private static int _lastSaveFilter = 1;

        private FlowLayoutPanel _toolbar;
        private FlowLayoutPanel _shapeBar;
        private readonly List<Button> _shapeButtons = new List<Button>();
        private ContextMenuStrip _polygonMenu;
        private readonly List<Button> _toolButtons = new List<Button>();
        private readonly List<Button> _colorButtons = new List<Button>();
        private readonly TextBox _textBox;
        private CheckBox _fillToggle, _doubleArrowToggle;
        private bool _updatingStyle;

        private static readonly Color Accent = Color.FromArgb(86, 134, 245);
        private static readonly Color BarBg = Color.FromArgb(245, 245, 248);
        private static readonly Color BarText = Color.FromArgb(45, 45, 50);
        private static readonly Color Hover = Color.FromArgb(225, 235, 252);
        private static readonly Tool[] AnnotationTools = { Tool.Rect, Tool.Ellipse, Tool.Arrow, Tool.Line,
            Tool.Pen, Tool.Text, Tool.Mosaic, Tool.Number, Tool.Highlight, Tool.Select };

        public CaptureForm() : this(null) { }

        // Tests may supply an owned bitmap without reading the desktop.
        internal CaptureForm(Bitmap screen)
        {
            AutoScaleMode = AutoScaleMode.None;
            Text = "SnapTool 截图";
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            Bounds = SystemInformation.VirtualScreen;
            _origin = Bounds.Location;
            TopMost = true;
            ShowInTaskbar = false;
            KeyPreview = true;
            DoubleBuffered = true;
            Cursor = Cursors.Cross;

            _screen = screen ?? CaptureScreen();
            if (screen != null) ClientSize = screen.Size;

            _shapeBar = BuildShapeBar();
            Controls.Add(_shapeBar);
            PositionShapeBar();

            _toolbar = BuildToolbar();
            _toolbar.Visible = false;
            Controls.Add(_toolbar);

            _textBox = new TextBox
            {
                Visible = false,
                BorderStyle = BorderStyle.FixedSingle,
                BackColor = Color.White,
            };
            _textBox.KeyDown += TextBoxKeyDown;
            _textBox.LostFocus += (s, e) => FinishText(true);
            Controls.Add(_textBox);

            _toastTimer = new Timer { Interval = 250 };
            _toastTimer.Tick += (s, e) =>
            {
                if (_toast != null && DateTime.Now > _toastUntil) { _toast = null; _toastTimer.Stop(); Invalidate(); }
            };
        }

        private Bitmap CaptureScreen()
        {
            var r = SystemInformation.VirtualScreen;
            var bmp = new Bitmap(r.Width, r.Height, PixelFormat.Format32bppArgb);
            try
            {
                using (var g = Graphics.FromImage(bmp))
                    g.CopyFromScreen(r.X, r.Y, 0, 0, r.Size, CopyPixelOperation.SourceCopy);
                return bmp;
            }
            catch { bmp.Dispose(); throw; }
        }

        // ---------- 工具栏 ----------
        private FlowLayoutPanel BuildShapeBar()
        {
            var bar = new FlowLayoutPanel
            {
                AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                WrapContents = false, BackColor = BarBg, Padding = new Padding(8, 6, 8, 6),
                BorderStyle = BorderStyle.FixedSingle
            };
            bar.SuspendLayout();
            bar.Controls.Add(new Label { Text = "截图形状", AutoSize = true, Font = _toolbarFont,
                ForeColor = BarText, Margin = new Padding(2, 6, 10, 0) });
            string[] names = { "▭ 矩形", "○ 圆形", "△ 三角形", "多边形 ▾" };
            for (int i = 0; i < names.Length; i++)
            {
                var button = MakeActionButton(names[i], delegate { });
                button.Size = new Size(i == 3 ? 100 : (i == 2 ? 86 : 76), 30);
                button.MinimumSize = button.Size;
                button.AutoSize = true;
                button.TabStop = false;
                button.Tag = i;
                int index = i;
                button.Click += (s, e) =>
                {
                    if (index < 3) SelectShape((CaptureShape)index);
                    else _polygonMenu.Show(button, new Point(0, button.Height));
                };
                _shapeButtons.Add(button);
                bar.Controls.Add(button);
            }
            _polygonMenu = new ContextMenuStrip();
            foreach (var shape in new[] { CaptureShape.Pentagon, CaptureShape.Hexagon, CaptureShape.Polygon })
            {
                CaptureShape chosen = shape;
                var item = new ToolStripMenuItem(ShapeName(shape)) { Tag = shape };
                item.Click += (s, e) => SelectShape(chosen);
                _polygonMenu.Items.Add(item);
            }
            bar.Controls.Add(MakeSeparator());
            var settings = MakeActionButton("快捷键设置", delegate
            {
                FinishText(true);
                Program.OpenSettings(this);
                Focus();
            });
            settings.Size = new Size(102, 30);
            settings.MinimumSize = settings.Size;
            settings.AutoSize = true;
            bar.Controls.Add(settings);
            UpdateShapeButtons();
            bar.ResumeLayout(true);
            return bar;
        }

        private static string ShapeName(CaptureShape shape)
        {
            switch (shape)
            {
                case CaptureShape.Rectangle: return "矩形";
                case CaptureShape.Circle: return "圆形";
                case CaptureShape.Triangle: return "三角形";
                case CaptureShape.Pentagon: return "五边形";
                case CaptureShape.Hexagon: return "六边形";
                default: return "自由多边形";
            }
        }

        private void UpdateShapeButtons()
        {
            foreach (var button in _shapeButtons)
            {
                int index = (int)button.Tag;
                bool active = index < 3 ? (int)_shape == index : (int)_shape >= 3;
                button.BackColor = active ? Accent : BarBg;
                button.ForeColor = active ? Color.White : BarText;
                if (index == 3) button.Text = (int)_shape >= 3 ? ShapeName(_shape) + " ▾" : "多边形 ▾";
            }
            if (_polygonMenu != null)
                foreach (ToolStripMenuItem item in _polygonMenu.Items) item.Checked = (CaptureShape)item.Tag == _shape;
        }

        private void PositionShapeBar()
        {
            var area = Screen.FromPoint(Cursor.Position).WorkingArea;
            area.Offset(-_origin.X, -_origin.Y);
            area = Rectangle.Intersect(ClientRectangle, area);
            if (area.Width < 200) area = ClientRectangle;
            _shapeBar.MaximumSize = new Size(Math.Max(100, area.Width - 16), 0);
            _shapeBar.WrapContents = true;
            _shapeBar.PerformLayout();
            int x = area.Left + (area.Width - _shapeBar.PreferredSize.Width) / 2;
            _shapeBar.Location = new Point(Math.Max(4, x), Math.Max(4, area.Top + 12));
            _shapeBar.BringToFront();
        }

        private void SelectShape(CaptureShape shape)
        {
            FinishText(true);
            if (_shape == shape) { Focus(); return; }
            _shape = shape;
            CancelAnnotationGesture();
            _current = null;
            _dragging = _userDragging = _movingSel = _resizing = false;
            _polygonPoints.Clear(); _polygonClosed = false;
            _hoverRect = Rectangle.Empty;
            if (shape == CaptureShape.Polygon)
            {
                // Changing a crop shape preserves annotations; explicit Reselect discards them.
                _mode = Mode.Selecting;
                _sel = Rectangle.Empty;
                _toolbar.Visible = false;
                _textBox.Visible = false;
                Cursor = Cursors.Cross;
            }
            else if (shape == CaptureShape.Circle && !_sel.IsEmpty) _sel = CircleBounds(_sel);
            UpdateShapeButtons();
            if (!_sel.IsEmpty) PositionToolbar();
            ShowToast(shape == CaptureShape.Polygon ? "逐点单击，双击或 Enter 完成；右键撤回一点" : "截图形状：" + ShapeName(shape));
            Focus();
            Invalidate();
        }

        private static Rectangle CircleBounds(Rectangle rectangle)
        {
            int side = Math.Min(rectangle.Width, rectangle.Height);
            return new Rectangle(rectangle.X + (rectangle.Width - side) / 2,
                rectangle.Y + (rectangle.Height - side) / 2, side, side);
        }

        private Rectangle SelectionRect(Point start, Point end)
        {
            var rectangle = Rectangle.Intersect(ClientRectangle, NormalizeRect(start, end));
            if (_shape != CaptureShape.Circle) return rectangle;
            int side = Math.Min(rectangle.Width, rectangle.Height);
            return new Rectangle(end.X >= start.X ? start.X : start.X - side,
                end.Y >= start.Y ? start.Y : start.Y - side, side, side);
        }

        private bool SelectionContains(Point point)
        {
            return _sel.Width > 0 && _sel.Height > 0 && SelectionGeometry.Contains(_shape, _sel, _polygonPoints, point);
        }

        private bool PolygonDraft { get { return _shape == CaptureShape.Polygon && !_polygonClosed; } }

        private void AddPolygonPoint(Point point)
        {
            point = ClampPoint(point);
            if (_polygonPoints.Count >= 3)
            {
                var first = _polygonPoints[0];
                if (Math.Abs(first.X - point.X) + Math.Abs(first.Y - point.Y) <= 12) { CompletePolygon(); return; }
            }
            if (_polygonPoints.Count == 0 || _polygonPoints[_polygonPoints.Count - 1] != point) _polygonPoints.Add(point);
            Invalidate();
        }

        private void CompletePolygon()
        {
            if (_polygonPoints.Count < 3) { ShowToast("至少选择三个顶点"); return; }
            // Consecutive duplicate final clicks should not create degenerate edges.
            int left = ClientSize.Width, top = ClientSize.Height, right = 0, bottom = 0;
            long area = 0;
            for (int i = 0; i < _polygonPoints.Count; i++)
            {
                Point p = _polygonPoints[i], next = _polygonPoints[(i + 1) % _polygonPoints.Count];
                left = Math.Min(left, p.X); top = Math.Min(top, p.Y);
                right = Math.Max(right, p.X); bottom = Math.Max(bottom, p.Y);
                area += (long)p.X * next.Y - (long)next.X * p.Y;
            }
            if (right - left <= 4 || bottom - top <= 4 || Math.Abs(area) <= 16)
            { ShowToast("顶点需围成有面积的多边形"); return; }
            _sel = Rectangle.FromLTRB(left, top, right, bottom);
            _polygonClosed = true;
            _polygonCompletedAt = DateTime.UtcNow;
            _toolbar.Visible = true; PositionToolbar(); _toolbar.BringToFront();
            if (_items.Count > 0) EnterEditing();
            Invalidate();
        }

        private void UndoPolygonPoint()
        {
            if (_polygonPoints.Count > 0) _polygonPoints.RemoveAt(_polygonPoints.Count - 1);
            Invalidate();
        }

        private FlowLayoutPanel BuildToolbar()
        {
            var panel = new FlowLayoutPanel
            {
                AutoSize = true,
                AutoSizeMode = AutoSizeMode.GrowAndShrink,
                FlowDirection = FlowDirection.LeftToRight,
                WrapContents = true,
                BackColor = BarBg,
                Padding = new Padding(6, 5, 6, 5),
                BorderStyle = BorderStyle.FixedSingle,
            };

            panel.SuspendLayout();
            panel.Controls.Add(new Label { Text = "标注", AutoSize = true, Font = _toolbarFont,
                ForeColor = BarText, Margin = new Padding(3, 7, 6, 0) });
            for (int i = 0; i < AnnotationTools.Length; i++)
            {
                Tool tool = AnnotationTools[i];
                var btn = MakeToolButton(NameOf(tool), tool);
                _toolTips.SetToolTip(btn, NameOf(tool) + "标注（" + (i == 9 ? "0" : (i + 1).ToString()) + "）" +
                    (tool == Tool.Rect || tool == Tool.Ellipse ? "；Shift 锁定正方形 / 正圆" :
                    (tool == Tool.Arrow || tool == Tool.Line ? "；Shift 锁定水平 / 垂直 / 45°" : "")));
                _toolButtons.Add(btn);
                panel.Controls.Add(btn);
            }

            panel.Controls.Add(MakeSeparator());

            _fillToggle = new CheckBox { Text = "实心", AutoSize = true, Font = _toolbarFont, Margin = new Padding(4, 7, 4, 0) };
            _doubleArrowToggle = new CheckBox { Text = "双向", AutoSize = true, Font = _toolbarFont, Margin = new Padding(4, 7, 4, 0) };
            _fillToggle.CheckedChanged += (s, e) => ApplyStyleOption();
            _doubleArrowToggle.CheckedChanged += (s, e) => ApplyStyleOption();
            _toolTips.SetToolTip(_fillToggle, "矩形 / 圆形填充实心颜色；黑色实心矩形可遮挡敏感内容");
            _toolTips.SetToolTip(_doubleArrowToggle, "箭头两端都显示箭头");
            panel.Controls.Add(_fillToggle); panel.Controls.Add(_doubleArrowToggle);

            Color[] colors = { Color.Red, Color.FromArgb(255, 140, 0), Color.Gold,
                               Color.LimeGreen, Color.DodgerBlue, Color.White, Color.Black };
            foreach (var c in colors)
            {
                var btn = MakeColorButton(c);
                _colorButtons.Add(btn);
                panel.Controls.Add(btn);
            }

            panel.Controls.Add(MakeSeparator());

            panel.Controls.Add(MakeActionButton("撤销", () => Undo()));
            panel.Controls.Add(MakeActionButton("重做", () => Redo()));
            panel.Controls.Add(MakeActionButton("复制", () => Confirm(OutMode.Clipboard)));
            panel.Controls.Add(MakeActionButton("保存", () => Confirm(OutMode.Save)));
            panel.Controls.Add(MakeActionButton("快存", () => QuickSave()));
            panel.Controls.Add(MakeActionButton("贴图", () => Confirm(OutMode.Pin)));
            panel.Controls.Add(MakeActionButton("OCR", () => DoOcr()));
            panel.Controls.Add(MakeActionButton("重选", () => Reselect()));
            panel.Controls.Add(MakeActionButton("退出", () => Close()));

            SelectTool(Tool.Rect);
            SelectColor(_color);
            panel.ResumeLayout(true);
            return panel;
        }

        private Button MakeToolButton(string text, Tool tool)
        {
            var b = new Button
            {
                Text = text,
                Size = new Size(50, 28),
                FlatStyle = FlatStyle.Flat,
                Font = _toolbarFont,
                TextAlign = ContentAlignment.MiddleCenter,
                Margin = new Padding(1),
                Cursor = Cursors.Hand,
                UseVisualStyleBackColor = false,
                Tag = tool,
            };
            b.FlatAppearance.BorderSize = 0;
            b.FlatAppearance.MouseOverBackColor = Hover;
            b.FlatAppearance.MouseDownBackColor = Accent;
            b.Click += (s, e) => SelectTool(tool);
            return b;
        }

        private Button MakeColorButton(Color c)
        {
            var b = new Button
            {
                Size = new Size(24, 24),
                FlatStyle = FlatStyle.Flat,
                BackColor = c,
                Margin = new Padding(1),
                Cursor = Cursors.Hand,
                UseVisualStyleBackColor = false,
            };
            b.FlatAppearance.BorderSize = 1;
            b.FlatAppearance.BorderColor = Color.FromArgb(180, 180, 185);
            b.Click += (s, e) => SelectColor(c);
            return b;
        }

        private Button MakeActionButton(string text, Action action)
        {
            var b = new Button
            {
                Text = text,
                Size = new Size(50, 28),
                FlatStyle = FlatStyle.Flat,
                Font = _toolbarFont,
                TextAlign = ContentAlignment.MiddleCenter,
                Margin = new Padding(1),
                Cursor = Cursors.Hand,
                UseVisualStyleBackColor = false,
                BackColor = BarBg,
                ForeColor = BarText,
            };
            b.FlatAppearance.BorderSize = 0;
            b.FlatAppearance.MouseOverBackColor = Hover;
            b.FlatAppearance.MouseDownBackColor = Accent;
            b.Click += (s, e) => action();
            return b;
        }

        private Control MakeSeparator()
        {
            return new Panel { Size = new Size(1, 22), BackColor = Color.FromArgb(208, 208, 214), Margin = new Padding(5, 4, 5, 4) };
        }

        private void SelectTool(Tool t)
        {
            FinishText(true);
            CancelAnnotationGesture();
            _dragging = false;
            _movingAnnotation = false;
            _selectedAnnotation = null;
            _tool = t;
            UpdateStyleOptions();
            foreach (var b in _toolButtons)
            {
                bool on = (Tool)b.Tag == t;
                b.BackColor = on ? Accent : BarBg;
                b.ForeColor = on ? Color.White : BarText;
            }
            Cursor = t == Tool.Select ? Cursors.Default : ((t == Tool.Text) ? Cursors.IBeam : Cursors.Cross);
            if (_mode == Mode.Selecting && _sel.Width > 0) EnterEditing();   // 调整态点标注工具→直接进标注
            else if (_toolbar != null && _sel.Width > 0)
                ShowToast(t == Tool.Select ? "选择标注：拖动移动，Delete 删除" : "已选标注工具：" + NameOf(t) + "，在截图内拖动绘制");
        }

        private static string NameOf(Tool t)
        {
            switch (t)
            {
                case Tool.Rect: return "矩形";
                case Tool.Arrow: return "箭头";
                case Tool.Pen: return "画笔";
                case Tool.Text: return "文字";
                case Tool.Mosaic: return "马赛克";
                case Tool.Number: return "序号";
                case Tool.Highlight: return "高亮";
                case Tool.Ellipse: return "圆形";
                case Tool.Line: return "直线";
                case Tool.Select: return "选择";
            }
            return "";
        }

        private void SelectColor(Color c)
        {
            FinishText(true);
            _color = c;
            if (_selectedAnnotation != null && _tool == Tool.Select)
                ChangeSelectedStyle(delegate(Annotation item) { item.Color = c; });
            foreach (var b in _colorButtons)
            {
                bool on = b.BackColor.ToArgb() == c.ToArgb();
                b.FlatAppearance.BorderSize = on ? 3 : 1;
                b.FlatAppearance.BorderColor = on ? Color.DodgerBlue : Color.FromArgb(180, 180, 185);
            }
        }

        private void UpdateStyleOptions()
        {
            if (_fillToggle == null) return;
            Tool tool = _selectedAnnotation == null ? _tool : _selectedAnnotation.Tool;
            _fillToggle.Enabled = tool == Tool.Rect || tool == Tool.Ellipse;
            _doubleArrowToggle.Enabled = tool == Tool.Arrow;
            if (_selectedAnnotation != null)
            {
                _updatingStyle = true;
                _fillToggle.Checked = _selectedAnnotation.Filled;
                _doubleArrowToggle.Checked = _selectedAnnotation.DoubleArrow;
                _updatingStyle = false;
            }
        }

        private void ApplyStyleOption()
        {
            if (_updatingStyle || _selectedAnnotation == null) return;
            ChangeSelectedStyle(delegate(Annotation item)
            { item.Filled = _fillToggle.Checked; item.DoubleArrow = _doubleArrowToggle.Checked; });
        }

        private void ChangeSelectedStyle(Action<Annotation> change)
        {
            if (_selectedAnnotation == null) return;
            Annotation item = _selectedAnnotation;
            var before = new AnnotationStyle(item);
            change(item);
            item.InvalidateCache();
            RecordChange(new AnnotationChange { Kind = AnnotationChangeKind.Style, Item = item,
                BeforeStyle = before, AfterStyle = new AnnotationStyle(item) });
            Invalidate();
        }

        // ---------- Win32:窗口识别 ----------
        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll", CharSet = CharSet.Auto)] private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
        [DllImport("user32.dll", CharSet = CharSet.Auto)] private static extern int GetWindowTextLength(IntPtr hWnd);
        [DllImport("user32.dll", CharSet = CharSet.Auto)] private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
        [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT pvAttribute, int cbAttribute);
        [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int pvAttribute, int cbAttribute);
        private const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;
        private const int DWMWA_CLOAKED = 14;
        [StructLayout(LayoutKind.Sequential)]
        private struct RECT { public int Left, Top, Right, Bottom; }

        // 窗口可见矩形:优先 DWM 扩展帧(排除 Win10/11 不可见边框/阴影),失败回退 GetWindowRect
        private static bool GetWindowRectAccurate(IntPtr hWnd, out RECT r)
        {
            if (DwmGetWindowAttribute(hWnd, DWMWA_EXTENDED_FRAME_BOUNDS, out r, Marshal.SizeOf(typeof(RECT))) == 0)
                return true;
            return GetWindowRect(hWnd, out r);
        }

        private IntPtr FindHwndAt(Point screenPt)
        {
            IntPtr myHwnd = Handle;
            IntPtr result = IntPtr.Zero;
            EnumWindows(delegate(IntPtr hWnd, IntPtr lp)
            {
                if (hWnd == myHwnd || !IsWindowVisible(hWnd)) return true;
                // 用户关闭"识别贴图"时,跳过贴图窗口
                if (!Program.IdentifyPinWindows && Program.OpenPinHandles.Contains(hWnd)) return true;
                // 跳过被 DWM 遮蔽(cloaked)的窗口:挂起的 UWP 应用对 IsWindowVisible 仍可见,但实际不显示
                int cloaked;
                if (DwmGetWindowAttribute(hWnd, DWMWA_CLOAKED, out cloaked, 4) == 0 && cloaked != 0) return true;
                RECT r;
                if (!GetWindowRectAccurate(hWnd, out r)) return true;
                var rect = new Rectangle(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
                if (!rect.Contains(screenPt)) return true;
                var cls = new StringBuilder(256);
                GetClassName(hWnd, cls, 256);
                string cn = cls.ToString();
                if (cn == "Progman" || cn == "WorkerW") return true;
                result = hWnd;
                return false;
            }, IntPtr.Zero);
            return result;
        }

        private static string GetTitle(IntPtr hWnd)
        {
            int len = GetWindowTextLength(hWnd);
            if (len <= 0) return "";
            var sb = new StringBuilder(len + 1);
            GetWindowText(hWnd, sb, sb.Capacity);
            return sb.ToString();
        }

        // ---------- 鼠标 ----------
        protected override void OnMouseDown(MouseEventArgs e)
        {
            _mouse = e.Location;
            if (e.Button == MouseButtons.Right || e.Button == MouseButtons.Middle)
            {
                if (PolygonDraft && _polygonPoints.Count > 0) { UndoPolygonPoint(); return; }
                if (_mode == Mode.Editing || _sel.Width > 0) Reselect();
                else Close();
                return;
            }
            if (e.Button != MouseButtons.Left) return;
            FinishText(true);
            Focus();

            if (PolygonDraft)
            {
                if (e.Clicks >= 2) CompletePolygon();
                else AddPolygonPoint(e.Location);
                return;
            }

            if (_mode == Mode.Selecting)
            {
                HandleEdge h = _sel.Width > 0 ? HandleAt(e.Location) : HandleEdge.None;
                if (h != HandleEdge.None)
                {
                    // 抓住边/角:缩放选区大小
                    _resizing = true;
                    _activeHandle = h;
                    _resizeOrig = _sel;
                    _polygonDragOrigin = _polygonPoints.ToArray();
                    _down = e.Location;
                    _dragging = true;
                }
                else if (SelectionContains(e.Location))
                {
                    _movingSel = true;
                    _moveOrig = _sel;
                    _polygonDragOrigin = _polygonPoints.ToArray();
                    _down = e.Location;
                    _dragging = true;
                }
                else
                {
                    if (_shape == CaptureShape.Polygon) { Reselect(); AddPolygonPoint(e.Location); return; }
                    _down = e.Location;
                    _downStart = e.Location;
                    if (_sel.Width > 0) _hoverRect = Rectangle.Empty;   // 重框才清;首次单击选中窗口需保留 _hoverRect
                    _sel = Rectangle.Empty;
                    _toolbar.Visible = false;
                    _dragging = true;
                    _userDragging = false;
                }
            }
            else
            {
                if (!SelectionContains(e.Location)) return;
                if (_tool == Tool.Select)
                {
                    _selectedAnnotation = HitTestAnnotation(e.Location);
                    UpdateStyleOptions();
                    _movingAnnotation = _selectedAnnotation != null;
                    _annotationMoveDelta = Point.Empty;
                    _annotationLastPoint = e.Location;
                    _dragging = _movingAnnotation;
                    Cursor = _movingAnnotation ? Cursors.SizeAll : Cursors.Default;
                    Invalidate();
                    return;
                }
                if (_tool == Tool.Text) { ShowTextBox(e.Location); return; }
                if (_tool == Tool.Number)
                {
                    // Commit on mouse-up, so double-clicks do not stamp a second number.
                    _current = new Annotation { Tool = Tool.Number, P1 = e.Location, P2 = e.Location,
                        Number = _numberCounter, Color = _color, Width = _penWidth };
                    _dragging = true;
                    return;
                }
                _down = e.Location;
                _current = new Annotation
                {
                    Tool = _tool, Color = _color, Width = _penWidth, FontSize = _fontSize, Block = _mosaicBlock,
                    Filled = _fillToggle.Checked, DoubleArrow = _doubleArrowToggle.Checked,
                    P1 = e.Location, P2 = e.Location, Points = new List<Point> { e.Location }
                };
                _dragging = true;
            }
            Invalidate();
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            Point oldMouse = _mouse;
            _mouse = e.Location;

            if (PolygonDraft)
            {
                if (_polygonPoints.Count > 0)
                {
                    Rectangle before = NormalizeRect(_polygonPoints[_polygonPoints.Count - 1], oldMouse);
                    Rectangle after = NormalizeRect(_polygonPoints[_polygonPoints.Count - 1], e.Location);
                    if (_polygonPoints.Count >= 2)
                    {
                        before = Rectangle.Union(before, NormalizeRect(_polygonPoints[0], oldMouse));
                        after = Rectangle.Union(after, NormalizeRect(_polygonPoints[0], e.Location));
                    }
                    Rectangle dirty = Rectangle.Union(before, after); dirty.Inflate(7, 7); Invalidate(dirty);
                }
                return;
            }

            if (_mode == Mode.Selecting && !_dragging)
            {
                if (_sel.Width > 0)
                {
                    // 调整态:边/角显示缩放光标,内部显示移动光标
                    HandleEdge h = HandleAt(e.Location);
                    if (h != HandleEdge.None) Cursor = CursorForHandle(h);
                    else Cursor = SelectionContains(e.Location) ? Cursors.SizeAll : Cursors.Cross;
                    InvalidateMouseAreas(oldMouse, e.Location);   // 只有取色器跟随鼠标,局部重绘
                }
                else
                {
                    if (_shape != CaptureShape.Rectangle)
                    {
                        _hoverRect = Rectangle.Empty;
                        InvalidateMouseAreas(oldMouse, e.Location);
                        return;
                    }
                    var sp = new Point(e.X + _origin.X, e.Y + _origin.Y);
                    IntPtr hwnd = FindHwndAt(sp);
                    Rectangle newHover = Rectangle.Empty;
                    string newTitle = null;
                    if (hwnd != IntPtr.Zero)
                    {
                        RECT r; GetWindowRectAccurate(hwnd, out r);
                        newHover = Rectangle.Intersect(ClientRectangle, new Rectangle(r.Left - _origin.X, r.Top - _origin.Y, r.Right - r.Left, r.Bottom - r.Top));
                        newTitle = GetTitle(hwnd);
                    }
                    if (newHover != _hoverRect || newTitle != _hoverTitle)
                    {
                        _hoverRect = newHover;
                        _hoverTitle = newTitle;
                        Invalidate();                               // 高亮窗口变化,整屏重绘
                    }
                    else InvalidateMouseAreas(oldMouse, e.Location);   // 取色器跟随鼠标
                }
                return;
            }

            if (_dragging)
            {
                if (_mode == Mode.Selecting)
                {
                    Rectangle before = _sel;
                    if (_resizing)
                    {
                        _sel = _shape == CaptureShape.Circle ? ResizeCircle(_resizeOrig, _activeHandle, ClampPoint(e.Location)) :
                            Rectangle.Intersect(ClientRectangle, ResizeSel(_resizeOrig, _activeHandle, ClampPoint(e.Location)));
                        TransformPolygon(_resizeOrig, _sel);
                    }
                    else if (_movingSel)
                    {
                        _sel = new Rectangle(
                            Math.Max(0, Math.Min(ClientSize.Width - _moveOrig.Width, _moveOrig.X + e.X - _down.X)),
                            Math.Max(0, Math.Min(ClientSize.Height - _moveOrig.Height, _moveOrig.Y + e.Y - _down.Y)),
                            _moveOrig.Width, _moveOrig.Height);
                        TransformPolygon(_moveOrig, _sel);
                    }
                    else
                    {
                        if (!_userDragging && (Math.Abs(e.X - _downStart.X) + Math.Abs(e.Y - _downStart.Y)) > 4)
                        {
                            _userDragging = true;
                            _hoverRect = Rectangle.Empty;
                        }
                        if (_userDragging) _sel = SelectionRect(_down, ClampPoint(e.Location));
                    }
                    if (_userDragging) Invalidate();                        // 十字辅助线横穿全屏,整屏重绘
                    else if (_sel != before) InvalidateSelDelta(before, _sel);
                }
                else if (_current != null)
                {
                    Point prev = (_tool == Tool.Pen || _tool == Tool.Highlight)
                        ? _current.Points[_current.Points.Count - 1] : _current.P2;
                    if (_tool == Tool.Pen || _tool == Tool.Highlight)
                    {
                        if (prev != e.Location) _current.Points.Add(e.Location);
                    }
                    else _current.P2 = ConstrainAnnotationPoint(_current.P1, e.Location, _current.Tool, (ModifierKeys & Keys.Shift) != 0);
                    _current.BoundsValid = false;
                    InvalidateAnnotationDelta(_current, prev, _current.Tool == Tool.Pen || _current.Tool == Tool.Highlight ? e.Location : _current.P2);
                }
                else if (_movingAnnotation && _selectedAnnotation != null)
                {
                    Point delta = new Point(e.X - _annotationLastPoint.X, e.Y - _annotationLastPoint.Y);
                    if (delta != Point.Empty)
                    {
                        RectangleF before = AnnotationGeometry.Bounds(_selectedAnnotation);
                        AnnotationGeometry.Translate(_selectedAnnotation, delta);
                        _annotationMoveDelta.Offset(delta);
                        _annotationLastPoint = e.Location;
                        Rectangle dirty = Rectangle.Ceiling(RectangleF.Union(before, AnnotationGeometry.Bounds(_selectedAnnotation)));
                        dirty.Inflate(5, 5); Invalidate(dirty);
                    }
                }
            }
            if (_mode == Mode.Editing && !_dragging) InvalidateMouseAreas(oldMouse, e.Location);
        }

        private Point ClampPoint(Point point)
        {
            return new Point(Math.Max(0, Math.Min(ClientSize.Width, point.X)),
                Math.Max(0, Math.Min(ClientSize.Height, point.Y)));
        }

        internal static Point ConstrainAnnotationPoint(Point start, Point end, Tool tool, bool constrain)
        {
            if (!constrain) return end;
            int dx = end.X - start.X, dy = end.Y - start.Y;
            if (tool == Tool.Rect || tool == Tool.Ellipse)
            {
                int side = Math.Max(Math.Abs(dx), Math.Abs(dy));
                return new Point(start.X + (dx < 0 ? -side : side), start.Y + (dy < 0 ? -side : side));
            }
            if (tool == Tool.Line || tool == Tool.Arrow)
            {
                double angle = Math.Round(Math.Atan2(dy, dx) / (Math.PI / 4)) * (Math.PI / 4);
                double length = Math.Sqrt((double)dx * dx + (double)dy * dy);
                return new Point(start.X + (int)Math.Round(Math.Cos(angle) * length), start.Y + (int)Math.Round(Math.Sin(angle) * length));
            }
            return end;
        }

        private Annotation HitTestAnnotation(Point point)
        {
            for (int i = _items.Count - 1; i >= 0; i--)
                if (AnnotationGeometry.HitTest(_items[i], point)) return _items[i];
            return null;
        }

        private void TransformPolygon(Rectangle before, Rectangle after)
        {
            if (_shape != CaptureShape.Polygon || _polygonDragOrigin == null || before.Width <= 0 || before.Height <= 0) return;
            _polygonPoints.Clear();
            foreach (Point point in _polygonDragOrigin)
                _polygonPoints.Add(new Point(after.X + (int)Math.Round((point.X - before.X) * after.Width / (double)before.Width),
                    after.Y + (int)Math.Round((point.Y - before.Y) * after.Height / (double)before.Height)));
        }

        // ---------- 局部重绘(避免每次鼠标移动整屏重绘,大屏/多屏明显更流畅)----------
        private static Rectangle MouseArea(Point p) { return new Rectangle(p.X - 270, p.Y - 160, 560, 340); }
        private void InvalidateMouseAreas(Point a, Point b) { Invalidate(Rectangle.Union(MouseArea(a), MouseArea(b))); }

        private void InvalidateSelDelta(Rectangle before, Rectangle after)
        {
            var u = Rectangle.Union(before, after);
            u.Inflate(160, 90);   // 覆盖选区右下外侧的尺寸标签与 8px 边框手柄
            Invalidate(u);
        }

        private void InvalidateAnnotationDelta(Annotation a, Point prev, Point cur)
        {
            int pad = (int)Math.Max(14, a.Width * 3 + 6);
            var r = Rectangle.Union(AroundPoint(prev, pad), AroundPoint(cur, pad));
            if (a.Tool == Tool.Rect || a.Tool == Tool.Ellipse || a.Tool == Tool.Arrow || a.Tool == Tool.Line || a.Tool == Tool.Mosaic)
            {
                var rPrev = NormalizeRect(a.P1, prev); rPrev.Inflate(pad, pad);
                var rCur = NormalizeRect(a.P1, cur); rCur.Inflate(pad, pad);
                r = Rectangle.Union(r, Rectangle.Union(rPrev, rCur));
            }
            Invalidate(r);
        }

        private static Rectangle AroundPoint(Point p, int pad) { return new Rectangle(p.X - pad, p.Y - pad, pad * 2, pad * 2); }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            if (!_dragging || e.Button != MouseButtons.Left) return;
            _dragging = false;

            if (_movingAnnotation)
            {
                _movingAnnotation = false;
                if (_selectedAnnotation != null)
                {
                    Point finalDelta = new Point(e.X - _annotationLastPoint.X, e.Y - _annotationLastPoint.Y);
                    if (finalDelta != Point.Empty)
                    {
                        AnnotationGeometry.Translate(_selectedAnnotation, finalDelta);
                        _annotationMoveDelta.Offset(finalDelta);
                    }
                }
                if (_selectedAnnotation != null && _annotationMoveDelta != Point.Empty)
                    RecordChange(new AnnotationChange { Kind = AnnotationChangeKind.Move, Item = _selectedAnnotation, Delta = _annotationMoveDelta });
                Invalidate();
                return;
            }

            if (_mode == Mode.Selecting)
            {
                if (_resizing)
                {
                    _resizing = false;
                    if (!(_sel.Width > 4 && _sel.Height > 4))
                    {
                        if (_shape == CaptureShape.Polygon) { Reselect(); return; }
                        _sel = Rectangle.Empty;
                    }
                }
                else if (_movingSel)
                {
                    _movingSel = false;
                    Cursor = SelectionContains(e.Location) ? Cursors.SizeAll : Cursors.Cross;
                }
                else if (_userDragging)
                {
                    _sel = SelectionRect(_down, ClampPoint(e.Location));
                    if (!(_sel.Width > 4 && _sel.Height > 4)) { _sel = Rectangle.Empty; _hoverRect = Rectangle.Empty; }
                }
                else if (_hoverRect.Width > 0)
                {
                    _sel = _hoverRect;
                    _hoverRect = Rectangle.Empty;
                }
                _userDragging = false;
                _sel = Rectangle.Intersect(ClientRectangle, _sel);
                if (_shape == CaptureShape.Circle) _sel = CircleBounds(_sel);
                _toolbar.Visible = false;
                if (_sel.Width > 4 && _sel.Height > 4) { _toolbar.Visible = true; PositionToolbar(); _toolbar.BringToFront(); }
            }
            else if (_current != null)
            {
                _current.P2 = ConstrainAnnotationPoint(_current.P1, e.Location, _current.Tool, (ModifierKeys & Keys.Shift) != 0);
                if ((_current.Tool == Tool.Pen || _current.Tool == Tool.Highlight) && _current.Points[_current.Points.Count - 1] != e.Location)
                    _current.Points.Add(e.Location);
                _current.BoundsValid = false;
                Rectangle bounds = NormalizeRect(_current.P1, _current.P2);
                bool keep = _current.Tool == Tool.Number || _current.Tool == Tool.Pen || _current.Tool == Tool.Highlight ||
                    (_current.Tool == Tool.Arrow || _current.Tool == Tool.Line ? bounds.Width >= 2 || bounds.Height >= 2 : bounds.Width >= 2 && bounds.Height >= 2);
                if (keep)
                {
                    AddAnnotation(_current);
                    bool click = _current.Tool == Tool.Number ||
                        ((_current.Tool == Tool.Pen || _current.Tool == Tool.Highlight) && _current.Points.Count == 1);
                    _lastClickAnnotation = click ? _current : null;
                    _lastAnnotationClickAt = DateTime.UtcNow;
                }
                else _current.Dispose();
                _current = null;
            }
            Invalidate();
        }

        protected override void OnMouseDoubleClick(MouseEventArgs e)
        {
            if (PolygonDraft)
            {
                if (e.Button == MouseButtons.Left) CompletePolygon();
                return;
            }
            if (_shape == CaptureShape.Polygon &&
                (DateTime.UtcNow - _polygonCompletedAt).TotalMilliseconds <= SystemInformation.DoubleClickTime + 50) return;
            // 无论调整态还是标注态,双击 = 直接复制截图(快速完成)
            if (e.Button == MouseButtons.Left && SelectionContains(e.Location) && !_textBox.Visible)
            {
                if (_current != null) _current.Dispose();
                _current = null;
                _dragging = false;
                RemoveDoubleClickStamp();
                Confirm(OutMode.Clipboard);
            }
            base.OnMouseDoubleClick(e);
        }

        // ---------- 键盘 ----------
        protected override bool ProcessCmdKey(ref Message message, Keys keyData)
        {
            if (_textBox.Visible) return base.ProcessCmdKey(ref message, keyData);
            var key = new KeyEventArgs(keyData);
            OnKeyDown(key);
            return key.Handled || base.ProcessCmdKey(ref message, keyData);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            // Text editing owns all keys, including digits, Backspace and Ctrl+C/Z.
            if (_textBox.Visible) { base.OnKeyDown(e); return; }
            if (PolygonDraft && (e.KeyData == Keys.Enter || e.KeyData == Keys.Back ||
                e.KeyData == Keys.Delete || e.KeyData == (Keys.Control | Keys.Z)))
            {
                if (e.KeyData == Keys.Enter) CompletePolygon();
                else UndoPolygonPoint();
                e.Handled = true; e.SuppressKeyPress = true; return;
            }
            bool hasSel = _sel.Width > 0 && _sel.Height > 0;
            bool handled = true;
            int ti = ToolIndexFromKey(e.KeyCode);
            if (e.KeyData == Keys.Escape) Close();
            else if (hasSel && e.Modifiers == Keys.None && ti >= 0) SelectTool((Tool)ti);
            else if (hasSel && e.KeyData == Keys.OemOpenBrackets) AdjustParam(-1);
            else if (hasSel && e.KeyData == Keys.OemCloseBrackets) AdjustParam(1);
            else if (hasSel && (e.KeyData == Keys.Enter || e.KeyData == (Keys.Control | Keys.C))) Confirm(OutMode.Clipboard);
            else if (hasSel && e.KeyData == (Keys.Control | Keys.S)) Confirm(OutMode.Save);
            else if (hasSel && e.KeyData == (Keys.Control | Keys.Shift | Keys.S)) QuickSave();
            else if (hasSel && e.KeyData == (Keys.Control | Keys.T)) Confirm(OutMode.Pin);
            else if (hasSel && e.KeyData == (Keys.Control | Keys.Shift | Keys.O)) DoOcr();
            else if (hasSel && e.KeyData == (Keys.Control | Keys.R)) Reselect();
            else if (hasSel && e.KeyData == (Keys.Control | Keys.Z)) Undo();
            else if (hasSel && (e.KeyData == (Keys.Control | Keys.Y) || e.KeyData == (Keys.Control | Keys.Shift | Keys.Z))) Redo();
            else if (hasSel && (e.KeyData == Keys.Delete || e.KeyData == Keys.Back))
            { if (_selectedAnnotation != null) DeleteSelectedAnnotation(); else Undo(); }
            else if (e.KeyData == Keys.C) CopyColorAt(_mouse, false);
            else if (!hasSel && e.KeyData == (Keys.Control | Keys.C)) CopyColorAt(_mouse, true);
            else handled = false;
            if (handled) { e.Handled = true; e.SuppressKeyPress = true; }
            base.OnKeyDown(e);
        }
        private static int ToolIndexFromKey(Keys k)
        {
            if (k == Keys.D0 || k == Keys.NumPad0) return (int)Tool.Select;
            if (k >= Keys.D1 && k <= Keys.D9) return (int)AnnotationTools[(int)k - (int)Keys.D1];
            if (k >= Keys.NumPad1 && k <= Keys.NumPad9) return (int)AnnotationTools[(int)k - (int)Keys.NumPad1];
            return -1;
        }

        // ---------- 工具参数调节(线宽/字号/马赛克粒度,[ ] 或滚轮)----------
        private void AdjustParam(int dir)
        {
            string label = null;
            if (_tool == Tool.Select && _selectedAnnotation != null)
            {
                ChangeSelectedStyle(delegate(Annotation item)
                {
                    if (item.Tool == Tool.Text) { item.FontSize = Math.Max(10, Math.Min(60, item.FontSize + dir * 2)); label = "字号 " + item.FontSize; }
                    else if (item.Tool == Tool.Mosaic) { item.Block = Math.Max(2, Math.Min(40, item.Block + dir * 2)); label = "马赛克粒度 " + item.Block; }
                    else { item.Width = Math.Max(1, Math.Min(20, item.Width + dir)); label = "笔宽 " + item.Width; }
                });
                ShowToast(label); return;
            }
            if (_tool == Tool.Rect || _tool == Tool.Ellipse || _tool == Tool.Arrow || _tool == Tool.Line || _tool == Tool.Pen)
            {
                _penWidth = Math.Max(1, Math.Min(20, _penWidth + dir));
                label = "笔宽 " + _penWidth.ToString("0.#");
            }
            else if (_tool == Tool.Text)
            {
                _fontSize = Math.Max(10, Math.Min(60, _fontSize + dir * 2));
                label = "字号 " + _fontSize.ToString("0.#");
            }
            else if (_tool == Tool.Mosaic)
            {
                _mosaicBlock = Math.Max(2, Math.Min(40, _mosaicBlock + dir * 2));
                label = "马赛克粒度 " + _mosaicBlock;
            }
            else if (_tool == Tool.Highlight)
            {
                _penWidth = Math.Max(1, Math.Min(20, _penWidth + dir));
                label = "高亮宽度 " + Math.Max(10, (int)(_penWidth * 5));
            }
            else if (_tool == Tool.Number)
            {
                _penWidth = Math.Max(1, Math.Min(20, _penWidth + dir));
                label = "序号大小 " + Math.Max(20, (int)(_penWidth * 9));
            }
            if (label != null) ShowToast(label);
        }

        private void ShowToast(string s)
        {
            _toast = s;
            _toastUntil = DateTime.Now.AddSeconds(1);
            _toastTimer.Start();
            Invalidate();
        }

        protected override void OnMouseWheel(MouseEventArgs e)
        {
            base.OnMouseWheel(e);
            if (_mode == Mode.Editing && !_textBox.Visible &&
                !(_toolbar.Visible && _toolbar.Bounds.Contains(e.Location)))
                AdjustParam(e.Delta > 0 ? 1 : -1);
        }

        private void TextBoxKeyDown(object sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Escape)
            {
                FinishText(e.KeyCode == Keys.Enter);
                Focus();
                e.Handled = true;
                e.SuppressKeyPress = true;
            }
        }

        private void FinishText(bool commit)
        {
            if (_textBox == null || !_textBox.Visible || _finishingText) return;
            _finishingText = true;
            try
            {
                if (commit && !string.IsNullOrEmpty(_textBox.Text))
                    AddAnnotation(new Annotation { Tool = Tool.Text, P1 = _textOrigin, Text = _textBox.Text,
                        Color = _textBox.ForeColor, FontSize = _tbFont.Size });
                _textBox.Text = "";
                _textBox.Visible = false;
                Invalidate();
            }
            finally { _finishingText = false; }
        }
        // ---------- 状态切换 ----------
        private void EnterEditing()
        {
            _mode = Mode.Editing;
            _toolbar.Visible = true;
            _toolbar.PerformLayout();
            PositionToolbar();
            _toolbar.BringToFront();
            SelectTool(_tool);
            Invalidate();
        }

        private void Reselect()
        {
            FinishText(false);
            _dragging = _userDragging = _movingSel = _resizing = false;
            _polygonPoints.Clear(); _polygonDragOrigin = null; _polygonClosed = false;
            ClearAnnotationResources();
            _items.Clear();
            _current = null;
            _mode = Mode.Selecting;
            _sel = Rectangle.Empty;
            _hoverRect = Rectangle.Empty;
            _numberCounter = 1;
            _toolbar.Visible = false;
            _textBox.Visible = false;
            Cursor = Cursors.Cross;
            Invalidate();
        }

        private void Undo()
        {
            FinishText(true);
            if (CancelAnnotationGesture()) { Invalidate(); return; }
            if (_undoHistory.Count == 0) return;
            AnnotationChange change = _undoHistory.Pop();
            ReplayChange(change, false); _redoHistory.Push(change);
            RefreshAfterHistory();
        }

        private void Redo()
        {
            FinishText(true);
            if (CancelAnnotationGesture()) { Invalidate(); return; }
            if (_redoHistory.Count == 0) return;
            AnnotationChange change = _redoHistory.Pop();
            ReplayChange(change, true); _undoHistory.Push(change);
            RefreshAfterHistory();
        }

        private void AddAnnotation(Annotation item)
        {
            _items.Add(item); _ownedAnnotations.Add(item);
            RecordChange(new AnnotationChange { Kind = AnnotationChangeKind.Add, Item = item, Index = _items.Count - 1 });
            RecalcNumberCounter();
        }

        private void RecordChange(AnnotationChange change)
        {
            _undoHistory.Push(change);
            var retained = new HashSet<Annotation>(_items);
            foreach (var entry in _undoHistory) retained.Add(entry.Item);
            foreach (var entry in _redoHistory)
                if (!retained.Contains(entry.Item) && _ownedAnnotations.Remove(entry.Item)) entry.Item.Dispose();
            _redoHistory.Clear();
        }

        private void ReplayChange(AnnotationChange change, bool redo)
        {
            bool insert = change.Kind == AnnotationChangeKind.Add ? redo : !redo;
            if (change.Kind == AnnotationChangeKind.Add || change.Kind == AnnotationChangeKind.Delete)
            {
                if (insert) _items.Insert(Math.Min(change.Index, _items.Count), change.Item);
                else _items.Remove(change.Item);
            }
            else if (change.Kind == AnnotationChangeKind.Move)
                AnnotationGeometry.Translate(change.Item, redo ? change.Delta : new Point(-change.Delta.X, -change.Delta.Y));
            else (redo ? change.AfterStyle : change.BeforeStyle).Apply(change.Item);
        }

        private void RefreshAfterHistory()
        {
            if (_selectedAnnotation != null && !_items.Contains(_selectedAnnotation)) _selectedAnnotation = null;
            _lastClickAnnotation = null;
            RecalcNumberCounter(); UpdateStyleOptions(); Invalidate();
        }

        private void DeleteSelectedAnnotation()
        {
            CancelAnnotationGesture();
            if (_selectedAnnotation == null) return;
            Annotation item = _selectedAnnotation;
            int index = _items.IndexOf(item);
            if (index < 0) return;
            _items.RemoveAt(index);
            RecordChange(new AnnotationChange { Kind = AnnotationChangeKind.Delete, Item = item, Index = index });
            _selectedAnnotation = null;
            RefreshAfterHistory();
        }

        private bool CancelAnnotationGesture()
        {
            bool active = _current != null || _movingAnnotation;
            if (_current != null) { _current.Dispose(); _current = null; }
            if (_movingAnnotation && _selectedAnnotation != null)
                AnnotationGeometry.Translate(_selectedAnnotation, new Point(-_annotationMoveDelta.X, -_annotationMoveDelta.Y));
            _movingAnnotation = false;
            if (active) _dragging = false;
            return active;
        }

        private void ClearAnnotationResources()
        {
            CancelAnnotationGesture();
            foreach (var item in _ownedAnnotations) item.Dispose();
            _ownedAnnotations.Clear(); _undoHistory.Clear(); _redoHistory.Clear();
            _selectedAnnotation = null; _lastClickAnnotation = null;
        }

        private void RemoveDoubleClickStamp()
        {
            if (_lastClickAnnotation == null || _undoHistory.Count == 0 ||
                (DateTime.UtcNow - _lastAnnotationClickAt).TotalMilliseconds > SystemInformation.DoubleClickTime + 50) return;
            if (_lastClickAnnotation.Tool != _tool ||
                Math.Abs(_lastClickAnnotation.P1.X - _mouse.X) > SystemInformation.DoubleClickSize.Width / 2 + 2 ||
                Math.Abs(_lastClickAnnotation.P1.Y - _mouse.Y) > SystemInformation.DoubleClickSize.Height / 2 + 2) return;
            AnnotationChange change = _undoHistory.Peek();
            if (change.Kind != AnnotationChangeKind.Add || change.Item != _lastClickAnnotation) return;
            _undoHistory.Pop(); _items.Remove(change.Item); _ownedAnnotations.Remove(change.Item); change.Item.Dispose();
            _lastClickAnnotation = null; RecalcNumberCounter();
        }

        // 撤销序号标注后,让下一个序号紧接着现有最大序号
        private void RecalcNumberCounter()
        {
            int max = 0;
            foreach (var a in _items) if (a.Tool == Tool.Number && a.Number > max) max = a.Number;
            _numberCounter = max + 1;
        }

        private void PositionToolbar()
        {
            var screenPoint = new Point(_origin.X + _sel.Left + _sel.Width / 2, _origin.Y + _sel.Top + _sel.Height / 2);
            var area = Screen.FromPoint(screenPoint).WorkingArea;
            area.Offset(-_origin.X, -_origin.Y);
            area = Rectangle.Intersect(ClientRectangle, area);
            if (area.Width < 100 || area.Height < 80) area = ClientRectangle;
            _toolbar.MaximumSize = new Size(Math.Max(100, area.Width - 8), 0);
            _toolbar.PerformLayout();
            int w = _toolbar.PreferredSize.Width;
            int h = _toolbar.PreferredSize.Height;
            int x = _sel.X;
            int y = _sel.Bottom + 10;
            if (y + h > area.Bottom) y = _sel.Top - h - 10;
            x = Math.Max(area.Left + 4, Math.Min(x, area.Right - w - 4));
            y = Math.Max(area.Top + 4, Math.Min(y, area.Bottom - h - 4));
            if (_shapeBar.Bounds.IntersectsWith(new Rectangle(x, y, w, h)))
                y = Math.Max(area.Top + 4, Math.Min(_shapeBar.Bottom + 8, area.Bottom - h - 4));
            _toolbar.Location = new Point(x, y);
        }

        private void ShowTextBox(Point p)
        {
            FinishText(true);
            _textOrigin = p;
            // 与最终落画效果一致(加粗),做到所见即所得;字体缓存避免 GDI 泄漏
            if (_tbFont == null || _tbFont.Size != _fontSize)
            {
                var nf = new Font("Microsoft YaHei UI", _fontSize, FontStyle.Bold, GraphicsUnit.Pixel);
                var old = _tbFont;
                _tbFont = nf;
                _textBox.Font = nf;
                if (old != null) old.Dispose();
            }
            _textBox.Font = _tbFont;
            _textBox.ForeColor = _color;
            _textBox.Text = "";
            _textBox.Width = Math.Min(260, Math.Max(20, ClientSize.Width - 8));
            // 钳位在屏幕内,靠边时不至于看不见输入内容
            int x = Math.Max(0, Math.Min(p.X, ClientSize.Width - _textBox.Width - 4));
            int y = Math.Max(0, Math.Min(p.Y, ClientSize.Height - _textBox.Height - 4));
            _textBox.Location = new Point(x, y);
            _textBox.Visible = true;
            _textBox.Focus();
        }

        // ---------- 输出 ----------
        private enum OutMode { Clipboard, Save, Pin }

        private void Confirm(OutMode mode)
        {
            if (_sel.Width <= 0) return;
            Bitmap bmp;
            try { bmp = RenderSelection(); }
            catch (Exception ex) { Program.ShowBalloon("生成截图失败: " + ex.Message); return; }
            if (bmp == null) return;
            try
            {
            switch (mode)
            {
                case OutMode.Clipboard:
                    if (Program.SetClipboardImageSafe(bmp))
                    {
                        Program.ShowBalloon("已复制到剪贴板");
                        Done();
                    }
                    else Program.ShowBalloon("剪贴板被占用,复制失败,请重试");
                    break;
                case OutMode.Save:
                    bool saved = SaveBitmap(bmp);
                    if (saved) Done();
                    break;
                case OutMode.Pin:
                    var pf = new PinForm(bmp, PointToScreen(_sel.Location));
                    try { pf.Show(); }
                    catch { pf.Dispose(); throw; }
                    bmp = null; // PinForm owns the image after a successful handoff.
                    Done();
                    break;
            }
            }
            catch (Exception ex) { Program.ShowBalloon("输出截图失败: " + ex.Message); }
            finally { if (bmp != null) bmp.Dispose(); }
        }

        private Bitmap RenderSelection()
        {
            FinishText(true);
            _sel = Rectangle.Intersect(new Rectangle(Point.Empty, _screen.Size), _sel);
            if (_sel.Width <= 0 || _sel.Height <= 0) return null;
            return SelectionGeometry.Render(_screen, _sel, _shape, _polygonPoints, delegate(Graphics graphics)
            {
                foreach (var annotation in _items) DrawAnnotation(graphics, annotation);
            });
        }

        private bool SaveBitmap(Bitmap bmp)
        {
            using (var dlg = new SaveFileDialog
            {
                Filter = "PNG 图片|*.png|JPEG 图片|*.jpg|位图|*.bmp",
                FileName = "Snap_" + DateTime.Now.ToString("yyyyMMdd_HHmmss"),
                DefaultExt = _shape != CaptureShape.Rectangle ? "png" : (_lastSaveFilter == 2 ? "jpg" : (_lastSaveFilter == 3 ? "bmp" : "png")),
                AddExtension = true,
                InitialDirectory = string.IsNullOrEmpty(_lastSaveDir) ? "" : _lastSaveDir,
                FilterIndex = _shape != CaptureShape.Rectangle ? 1 : _lastSaveFilter
            })
            {
                if (dlg.ShowDialog(this) != DialogResult.OK) return false;
                var fmt = ImageFormat.Png;
                string ext = Path.GetExtension(dlg.FileName).ToLowerInvariant();
                if (ext == ".jpg" || ext == ".jpeg") fmt = ImageFormat.Jpeg;
                else if (ext == ".bmp") fmt = ImageFormat.Bmp;
                try
                {
                    if (fmt.Guid == ImageFormat.Png.Guid) bmp.Save(dlg.FileName, fmt);
                    else using (var opaque = SelectionGeometry.CreateOpaque(bmp, Color.White)) opaque.Save(dlg.FileName, fmt);
                }
                catch (Exception ex) { MessageBox.Show("保存失败:" + ex.Message, "SnapTool"); return false; }
                _lastSaveDir = Path.GetDirectoryName(dlg.FileName);   // 记住上次目录与格式
                _lastSaveFilter = dlg.FilterIndex;
                Program.ShowBalloon("已保存: " + Path.GetFileName(dlg.FileName));
                return true;
            }
        }

        // 快速保存:不经对话框,直接存到「图片\SnapTool」,并把文件路径复制到剪贴板
        private void QuickSave()
        {
            if (_sel.Width <= 0) return;
            string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "SnapTool");
            try { Directory.CreateDirectory(dir); }
            catch (Exception ex) { Program.ShowBalloon("无法创建目录: " + ex.Message); return; }
            string file;
            Bitmap bmp;
            try { bmp = RenderSelection(); }
            catch (Exception ex) { Program.ShowBalloon("生成截图失败: " + ex.Message); return; }
            if (bmp == null) return;
            try
            {
                file = SaveQuickImage(bmp, dir);
            }
            catch (Exception ex) { bmp.Dispose(); Program.ShowBalloon("保存失败: " + ex.Message); return; }
            bmp.Dispose();
            _lastSaveDir = dir;
            bool copied = Program.SetClipboardTextSafe(file);
            Program.ShowBalloon("已快存: " + file + (copied ? "(路径已复制)" : "(剪贴板被占用，路径未复制)"));
        }

        internal static string SaveQuickImage(Bitmap bitmap, string directory)
        {
            string file = Path.Combine(directory, "Snap_" + DateTime.Now.ToString("yyyyMMdd_HHmmss_fff") + "_" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".png");
            using (var stream = new FileStream(file, FileMode.CreateNew, FileAccess.Write)) bitmap.Save(stream, ImageFormat.Png);
            return file;
        }

        private void Done() { _mode = Mode.Selecting; _toolbar.Visible = false; Close(); }

        // OCR:识别选区内的屏幕文字(原始像素,不含标注),后台线程执行。
        private void DoOcr()
        {
            if (_sel.Width <= 0 || _sel.Height <= 0) return;
            if (Program.OcrBusy) { ShowToast("正在识别，请稍候"); return; }

            Bitmap region = null;
            try
            {
                using (var shaped = SelectionGeometry.Render(_screen, _sel, _shape, _polygonPoints, null))
                {
                    if (shaped == null) return;
                    region = SelectionGeometry.CreateOpaque(shaped, Color.White);
                }
            }
            catch (Exception ex)
            {
                if (region != null) region.Dispose();
                Program.ShowBalloon("裁剪截图失败: " + ex.Message); return;
            }

            Program.StartOcr(region);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                FinishText(false);
                ClearAnnotationResources();
                if (_toastTimer != null) _toastTimer.Dispose();
                if (_tbFont != null) _tbFont.Dispose();
                if (_screen != null) _screen.Dispose();
                if (_polygonMenu != null) _polygonMenu.Dispose();
                _toolTips.Dispose();
                _toolbarFont.Dispose();
            }
            base.Dispose(disposing);
        }

        // ---------- 绘制 ----------
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.DrawImageUnscaled(_screen, 0, 0);
            g.SmoothingMode = SmoothingMode.AntiAlias;

            bool hasSel = _sel.Width > 0 && _sel.Height > 0;
            DrawDimOutside(g, hasSel ? _sel : Rectangle.Empty);

            if (_mode == Mode.Selecting)
            {
                if (_movingSel || _resizing) DrawSizeLabel(g, _sel);
                else if (_userDragging && hasSel) { DrawSizeLabel(g, _sel); DrawCross(g, _mouse); }
                else if (hasSel) DrawAdjustHint(g, _sel);
                else if (_hoverRect.Width > 0) DrawWindowHighlight(g, _hoverRect, _hoverTitle);
                else if (PolygonDraft) DrawPolygonHint(g);
                else DrawHint(g);
                // 取色器:悬停(未拖动、非移动、非缩放)时显示当前像素颜色
                if (!PolygonDraft && !_userDragging && !_movingSel && !_resizing) DrawColorPicker(g, _mouse);
            }
            else
            {
                var state = g.Save();
                using (var selectedPath = SelectionGeometry.CreatePath(_shape, _sel, _polygonPoints)) g.SetClip(selectedPath, CombineMode.Intersect);
                RectangleF visible = g.VisibleClipBounds;
                foreach (var a in _items)
                    if (AnnotationGeometry.Bounds(a).IntersectsWith(visible)) DrawAnnotation(g, a);
                if (_current != null) DrawAnnotation(g, _current);
                if (_selectedAnnotation != null)
                {
                    using (var outline = new Pen(Accent, 1) { DashStyle = DashStyle.Dash })
                    {
                        RectangleF selected = AnnotationGeometry.Bounds(_selectedAnnotation);
                        g.DrawRectangle(outline, selected.X, selected.Y, selected.Width, selected.Height);
                    }
                }
                g.Restore(state);
                if (_items.Count == 0 && _current == null) DrawEditHint(g, _sel);
            }

            if (hasSel) DrawSelectionBorder(g, _sel);
            if (PolygonDraft)
            {
                foreach (var annotation in _items)
                    if (AnnotationGeometry.Bounds(annotation).IntersectsWith(e.ClipRectangle)) DrawAnnotation(g, annotation);
                DrawPolygonDraft(g);
            }

            bool showMag = (_mode == Mode.Editing && !_dragging) || (_mode == Mode.Selecting && _userDragging);
            if (showMag && !_shapeBar.Bounds.Contains(_mouse) && !(_toolbar.Visible && _toolbar.Bounds.Contains(_mouse)) && !(_textBox.Visible && _textBox.Bounds.Contains(_mouse)))
                DrawMagnifier(g, _mouse);

            DrawToast(g);
        }

        // 参数调节提示(短暂浮字)
        private void DrawToast(Graphics g)
        {
            if (_toast == null || DateTime.Now > _toastUntil) return;
            using (var font = new Font("Microsoft YaHei UI", 10))
            {
                var sz = g.MeasureString(_toast, font);
                float w = sz.Width + 20, h = sz.Height + 10;
                float x = (ClientSize.Width - w) / 2;
                float y = ClientSize.Height - h - 60;
                using (var bg = new SolidBrush(Color.FromArgb(225, 0, 0, 0))) g.FillRectangle(bg, x, y, w, h);
                g.DrawString(_toast, font, Brushes.White, x + 10, y + 5);
            }
        }

        private void DrawDimOutside(Graphics g, Rectangle sel)
        {
            using (var b = new SolidBrush(Color.FromArgb(40, 0, 0, 0)))
            {
                if (sel.Width <= 0 || sel.Height <= 0) { g.FillRectangle(b, ClientRectangle); return; }
                if (_shape != CaptureShape.Rectangle)
                {
                    using (var path = SelectionGeometry.CreatePath(_shape, sel, _polygonPoints))
                    using (var outside = new Region(ClientRectangle))
                    {
                        outside.Exclude(path);
                        g.FillRegion(b, outside);
                    }
                    return;
                }
                g.FillRectangle(b, 0, 0, ClientSize.Width, sel.Top);
                g.FillRectangle(b, 0, sel.Bottom, ClientSize.Width, ClientSize.Height - sel.Bottom);
                g.FillRectangle(b, 0, sel.Top, sel.Left, sel.Height);
                g.FillRectangle(b, sel.Right, sel.Top, ClientSize.Width - sel.Right, sel.Height);
            }
        }

        private void DrawCross(Graphics g, Point p)
        {
            using (var pen = new Pen(Color.FromArgb(90, 0, 120, 215)) { DashStyle = DashStyle.Dot })
            {
                g.DrawLine(pen, p.X, 0, p.X, ClientSize.Height);
                g.DrawLine(pen, 0, p.Y, ClientSize.Width, p.Y);
            }
        }

        private void DrawHint(Graphics g)
        {
            using (var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
            using (var font = new Font("Microsoft YaHei UI", 16, FontStyle.Bold))
            using (var font2 = new Font("Microsoft YaHei UI", 11))
            {
                var rect1 = new RectangleF(0, ClientSize.Height / 2f - 30, ClientSize.Width, 50);
                var rect2 = new RectangleF(0, ClientSize.Height / 2f + 24, ClientSize.Width, 40);
                var s1 = rect1; s1.Offset(1, 1);
                var s2 = rect2; s2.Offset(1, 1);
                string instruction = _shape == CaptureShape.Rectangle ? "拖动框选 / 悬停单击选窗口" : "拖动选择" + ShapeName(_shape) + "区域";
                g.DrawString(instruction, font, Brushes.Black, s1, fmt);
                g.DrawString(instruction, font, Brushes.White, rect1, fmt);
                g.DrawString("双击复制  ·  Enter 确认  ·  Esc 取消", font2, Brushes.Black, s2, fmt);
                g.DrawString("双击复制  ·  Enter 确认  ·  Esc 取消", font2, Brushes.WhiteSmoke, rect2, fmt);
            }
        }

        private void DrawPolygonHint(Graphics graphics)
        {
            string text = _polygonPoints.Count == 0 ? "单击添加多边形顶点" : "已选择 " + _polygonPoints.Count + " 个顶点";
            int y = _polygonPoints.Count == 0 ? ClientSize.Height / 2 - 35 : _shapeBar.Bottom + 12;
            using (var font = new Font("Microsoft YaHei UI", _polygonPoints.Count == 0 ? 16 : 10, FontStyle.Bold))
            using (var small = new Font("Microsoft YaHei UI", 10))
            using (var format = new StringFormat { Alignment = StringAlignment.Center })
            {
                var header = new RectangleF(0, y, ClientSize.Width, 35);
                graphics.DrawString(text, font, Brushes.Black, header, format);
                header.Offset(0, -1);
                graphics.DrawString(text, font, Brushes.White, header, format);
                var help = new RectangleF(0, y + 33, ClientSize.Width, 30);
                graphics.DrawString("双击 / Enter 完成  ·  右键撤回一点  ·  Esc 取消", small, Brushes.WhiteSmoke, help, format);
            }
        }

        private void DrawPolygonDraft(Graphics graphics)
        {
            if (_polygonPoints.Count == 0) return;
            using (var line = new Pen(Color.FromArgb(86, 164, 255), 2))
            using (var preview = new Pen(Color.White, 1) { DashStyle = DashStyle.Dash })
            {
                if (_polygonPoints.Count > 1) graphics.DrawLines(line, _polygonPoints.ToArray());
                graphics.DrawLine(preview, _polygonPoints[_polygonPoints.Count - 1], _mouse);
                if (_polygonPoints.Count >= 2) graphics.DrawLine(preview, _mouse, _polygonPoints[0]);
            }
            for (int i = 0; i < _polygonPoints.Count; i++)
            {
                Point point = _polygonPoints[i];
                int radius = i == 0 ? 5 : 3;
                graphics.FillEllipse(Brushes.White, point.X - radius, point.Y - radius, radius * 2, radius * 2);
                graphics.DrawEllipse(Pens.DodgerBlue, point.X - radius, point.Y - radius, radius * 2, radius * 2);
            }
        }

        private void DrawEditHint(Graphics g, Rectangle sel)
        {
            if (sel.Width < 80 || sel.Height < 36) return;
            using (var font = new Font("Microsoft YaHei UI", 11))
            using (var brush = new SolidBrush(Color.FromArgb(150, 255, 255, 255)))
            using (var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
            {
                g.DrawString("下方“标注”选择矩形 / 圆形 / 箭头，再拖动绘制\n0 选择并移动标注  ·  Enter 复制", font, brush, sel, fmt);
            }
        }

        private void DrawWindowHighlight(Graphics g, Rectangle r, string title)
        {
            using (var b = new SolidBrush(Color.FromArgb(30, 0, 120, 215))) g.FillRectangle(b, r);
            using (var p = new Pen(Color.FromArgb(0, 120, 215), 2)) g.DrawRectangle(p, r);
            if (!string.IsNullOrEmpty(title))
            {
                using (var font = new Font("Microsoft YaHei UI", 9))
                {
                    var sz = g.MeasureString(title, font);
                    var bg = new RectangleF(r.X, r.Y - sz.Height - 6, sz.Width + 14, sz.Height + 6);
                    if (bg.Y < 0) bg.Y = r.Y + 2;
                    using (var bb = new SolidBrush(Color.FromArgb(220, 0, 120, 215))) g.FillRectangle(bb, bg);
                    g.DrawString(title, font, Brushes.White, bg.X + 7, bg.Y + 3);
                }
            }
        }

        private void DrawSizeLabel(Graphics g, Rectangle sel)
        {
            string s = string.Format("{0} × {1}", sel.Width, sel.Height);
            using (var font = new Font("Segoe UI", 10))
            {
                var sz = g.MeasureString(s, font);
                float x = sel.Right + 6, y = sel.Bottom + 6;
                if (x + sz.Width > ClientSize.Width) x = sel.Right - sz.Width - 6;
                if (y + sz.Height > ClientSize.Height) y = sel.Top - sz.Height - 6;
                var bg = new RectangleF(x, y, sz.Width + 12, sz.Height + 6);
                using (var b = new SolidBrush(Color.FromArgb(220, 0, 0, 0))) g.FillRectangle(b, bg);
                g.DrawString(s, font, Brushes.White, x + 6, y + 3);
            }
        }

        private void DrawSelectionBorder(Graphics g, Rectangle r)
        {
            if (r.Width <= 0 || r.Height <= 0) return;
            r = new Rectangle(r.X, r.Y, r.Width - 1, r.Height - 1);
            if (_shape == CaptureShape.Rectangle)
            {
                using (var p1 = new Pen(Color.White, 1)) g.DrawRectangle(p1, r);
                using (var p2 = new Pen(Color.FromArgb(0, 120, 215), 1)) g.DrawRectangle(p2, r);
            }
            else
            {
                using (var outline = SelectionGeometry.CreatePath(_shape, _sel, _polygonPoints))
                using (var white = new Pen(Color.White, 3))
                using (var blue = new Pen(Color.FromArgb(0, 120, 215), 1))
                using (var guide = new Pen(Color.FromArgb(150, 255, 255, 255), 1) { DashStyle = DashStyle.Dot })
                {
                    g.DrawRectangle(guide, r);
                    g.DrawPath(white, outline); g.DrawPath(blue, outline);
                }
            }
            foreach (var h in new[]
            {
                new Point(r.Left, r.Top), new Point(r.Right, r.Top),
                new Point(r.Left, r.Bottom), new Point(r.Right, r.Bottom)
            })
            {
                var hr = new Rectangle(h.X - 3, h.Y - 3, 6, 6);
                g.FillRectangle(Brushes.White, hr);
                g.DrawRectangle(Pens.DimGray, hr);
            }
        }

        private void DrawMagnifier(Graphics g, Point p)
        {
            const int box = 110;
            const int zoom = 4;
            var src = new Rectangle(p.X - box / (2 * zoom), p.Y - box / (2 * zoom), box / zoom, box / zoom);
            var dest = new Rectangle(p.X + 18, p.Y + 18, box, box);
            if (dest.Right > ClientSize.Width) dest.X = p.X - box - 18;
            if (dest.Bottom > ClientSize.Height) dest.Y = p.Y - box - 18;

            using (var bg = new SolidBrush(Color.FromArgb(230, 30, 30, 30))) g.FillRectangle(bg, dest);
            var oldI = g.InterpolationMode; var oldS = g.SmoothingMode;
            g.InterpolationMode = InterpolationMode.NearestNeighbor;
            g.SmoothingMode = SmoothingMode.None;
            g.DrawImage(_screen, dest, src, GraphicsUnit.Pixel);
            g.InterpolationMode = oldI; g.SmoothingMode = oldS;
            using (var pen = new Pen(Color.FromArgb(230, 255, 255, 255), 1)) g.DrawRectangle(pen, dest);
            int cx = dest.X + box / 2, cy = dest.Y + box / 2;
            g.DrawLine(Pens.Red, cx - 6, cy, cx + 6, cy);
            g.DrawLine(Pens.Red, cx, cy - 6, cx, cy + 6);
        }

        private void DrawAdjustHint(Graphics g, Rectangle sel)
        {
            const string s = "拖动调整选区  ·  下方“标注”可画矩形 / 圆形 / 箭头";
            using (var font = new Font("Microsoft YaHei UI", 11))
            using (var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
            {
                var sz = g.MeasureString(s, font);
                float w = sz.Width + 22, h = sz.Height + 8;
                float x = sel.X + (sel.Width - w) / 2;
                if (x + w > ClientSize.Width - 4) x = ClientSize.Width - w - 4;
                if (x < 4) x = 4;
                float y = sel.Y - h - 4;
                if (y < 2) y = sel.Y + 4;
                if (_shapeBar.Bounds.IntersectsWith(Rectangle.Ceiling(new RectangleF(x, y, w, h))))
                    y = Math.Max(sel.Top + 4, _shapeBar.Bottom + 6);
                y = Math.Max(2, Math.Min(y, ClientSize.Height - h - 2));
                using (var bg = new SolidBrush(Color.FromArgb(215, 0, 120, 215))) g.FillRectangle(bg, x, y, w, h);
                g.DrawString(s, font, Brushes.White, new RectangleF(x, y, w, h), fmt);
            }
        }

        private void DrawColorPicker(Graphics g, Point p)
        {
            if (p.X < 0 || p.Y < 0 || p.X >= _screen.Width || p.Y >= _screen.Height) return;
            Color c = _screen.GetPixel(p.X, p.Y);
            string hex = "#" + c.R.ToString("X2") + c.G.ToString("X2") + c.B.ToString("X2");
            string rgb = string.Format("RGB({0}, {1}, {2})", c.R, c.G, c.B);
            const string tip = "按 C 复制 HEX";

            using (var fHex = new Font("Segoe UI", 11, FontStyle.Bold))
            using (var fSm = new Font("Microsoft YaHei UI", 8))
            {
                var szHex = g.MeasureString(hex, fHex);
                var szRgb = g.MeasureString(rgb, fSm);
                var szTip = g.MeasureString(tip, fSm);

                const float pad = 6f;
                const float gap = 6f;
                const float swatchSize = 22f;
                float textW = Math.Max(Math.Max(szHex.Width, szRgb.Width), szTip.Width);
                float lineH = szHex.Height + 2 + szRgb.Height;
                float w = pad + swatchSize + gap + textW + pad;
                float h = pad + lineH + 5 + szTip.Height + pad;

                float x = p.X + 18, y = p.Y + 18;
                if (x + w > ClientSize.Width) x = p.X - w - 18;
                if (y + h > ClientSize.Height) y = p.Y - h - 18;
                if (x < 2) x = 2;
                if (y < 2) y = 2;

                using (var bg = new SolidBrush(Color.FromArgb(228, 28, 28, 32))) g.FillRectangle(bg, x, y, w, h);
                using (var bd = new Pen(Color.FromArgb(70, 255, 255, 255))) g.DrawRectangle(bd, x, y, w, h);

                float top = y + pad;
                var rc = new RectangleF(x + pad, top + (lineH - swatchSize) / 2, swatchSize, swatchSize);
                using (var sb = new SolidBrush(c)) g.FillRectangle(sb, rc);
                g.DrawRectangle(Pens.White, rc.X, rc.Y, rc.Width, rc.Height);

                float tx = rc.Right + gap;
                g.DrawString(hex, fHex, Brushes.White, tx, top);
                g.DrawString(rgb, fSm, Brushes.LightGray, tx, top + szHex.Height + 2);
                g.DrawString(tip, fSm, Brushes.DimGray, x + pad, top + lineH + 5);
            }
        }

        private void CopyColorAt(Point p, bool rgb)
        {
            if (p.X < 0 || p.Y < 0 || p.X >= _screen.Width || p.Y >= _screen.Height) return;
            Color c = _screen.GetPixel(p.X, p.Y);
            string hex = "#" + c.R.ToString("X2") + c.G.ToString("X2") + c.B.ToString("X2");
            string text = rgb ? string.Format("RGB({0}, {1}, {2})", c.R, c.G, c.B) : hex;
            if (Program.SetClipboardTextSafe(text)) Program.ShowBalloon("已复制颜色 " + text);
            else Program.ShowBalloon("剪贴板被占用,复制失败");
        }

        // ---------- 标注绘制 ----------
        private void DrawAnnotation(Graphics g, Annotation a)
        {
            switch (a.Tool)
            {
                case Tool.Rect:
                    Rectangle rectangle = NormalizeRect(a.P1, a.P2);
                    if (a.Filled) { using (var brush = new SolidBrush(a.Color)) g.FillRectangle(brush, rectangle); }
                    else using (var p = new Pen(a.Color, a.Width)) g.DrawRectangle(p, rectangle);
                    break;
                case Tool.Ellipse:
                    Rectangle ellipse = NormalizeRect(a.P1, a.P2);
                    if (ellipse.Width < 1 || ellipse.Height < 1) break;
                    if (a.Filled) { using (var brush = new SolidBrush(a.Color)) g.FillEllipse(brush, ellipse); }
                    else using (var p = new Pen(a.Color, a.Width)) g.DrawEllipse(p, ellipse);
                    break;
                case Tool.Arrow:
                    DrawArrow(g, a.P1, a.P2, a.Color, a.Width, a.DoubleArrow);
                    break;
                case Tool.Line:
                    using (var pen = new Pen(a.Color, a.Width) { StartCap = LineCap.Round, EndCap = LineCap.Round }) g.DrawLine(pen, a.P1, a.P2);
                    break;
                case Tool.Pen:
                    DrawPen(g, a);
                    break;
                case Tool.Highlight:
                    DrawHighlight(g, a);
                    break;
                case Tool.Text:
                    DrawOutlinedText(g, a.Text, a.P1, a.Color, a.FontSize);
                    break;
                case Tool.Mosaic:
                    DrawMosaic(g, a);
                    break;
                case Tool.Number:
                    DrawNumber(g, a.P1, a.Number, a.Color, Math.Max(20, (int)(a.Width * 9)));
                    break;
            }
        }

        private void DrawArrow(Graphics g, Point p1, Point p2, Color color, float width, bool both)
        {
            float w = Math.Max(2, width);
            using (var cap = new AdjustableArrowCap(2.6f, 2.6f, true))
            using (var pen = new Pen(color, w) { StartCap = LineCap.Round, CustomEndCap = cap, MiterLimit = 2 })
            {
                if (both) pen.CustomStartCap = cap;
                g.DrawLine(pen, p1, p2);
            }
        }

        private void DrawPen(Graphics g, Annotation a)
        {
            if (a.Points == null || a.Points.Count == 0) return;
            using (var pen = new Pen(a.Color, a.Width) { StartCap = LineCap.Round, EndCap = LineCap.Round, MiterLimit = 2, LineJoin = LineJoin.Round })
            {
                if (a.Points.Count == 1)
                {
                    var p = a.Points[0];
                    using (var b = new SolidBrush(a.Color)) g.FillEllipse(b, p.X - a.Width / 2f, p.Y - a.Width / 2f, a.Width, a.Width);
                }
                else g.DrawLines(pen, a.DrawingPoints);
            }
        }

        private void DrawHighlight(Graphics g, Annotation a)
        {
            if (a.Points == null || a.Points.Count == 0) return;
            Color c = Color.FromArgb(110, a.Color);
            float w = Math.Max(10f, a.Width * 5f);   // 跟随笔宽可调
            using (var pen = new Pen(c, w) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
            {
                if (a.Points.Count == 1)
                {
                    var p = a.Points[0];
                    using (var b = new SolidBrush(c)) g.FillEllipse(b, p.X - w / 2f, p.Y - w / 2f, w, w);
                }
                else g.DrawLines(pen, a.DrawingPoints);
            }
        }

        private void DrawNumber(Graphics g, Point p, int n, Color color, int d)
        {
            var r = new Rectangle(p.X - d / 2, p.Y - d / 2, d, d);
            using (var b = new SolidBrush(color)) g.FillEllipse(b, r);
            using (var pen = new Pen(Color.White, 2)) g.DrawEllipse(pen, r);
            using (var font = new Font("Segoe UI", Math.Max(9, d * 13 / 28), FontStyle.Bold))
            using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
            {
                g.DrawString(n.ToString(), font, Brushes.White, r, sf);
            }
        }

        private void DrawOutlinedText(Graphics g, string text, Point origin, Color color, float emSize)
        {
            if (string.IsNullOrEmpty(text)) return;
            FontFamily ff;
            try { ff = new FontFamily("Microsoft YaHei UI"); }
            catch { ff = FontFamily.GenericSansSerif; }
            using (ff)
            using (var format = StringFormat.GenericDefault)
            using (var path = new GraphicsPath())
            {
                path.AddString(text, ff, (int)FontStyle.Bold, emSize, origin, format);
                var old = g.SmoothingMode; g.SmoothingMode = SmoothingMode.AntiAlias;
                float ow = Math.Max(2.5f, emSize / 7f);
                using (var outline = new Pen(Color.White, ow) { LineJoin = LineJoin.Round, MiterLimit = 2 })
                    g.DrawPath(outline, path);
                using (var fill = new SolidBrush(color)) g.FillPath(fill, path);
                g.SmoothingMode = old;
            }
        }

        private void DrawMosaic(Graphics g, Annotation annotation)
        {
            _ownedAnnotations.Add(annotation);
            Rectangle r = NormalizeRect(annotation.P1, annotation.P2);
            int block = annotation.Block;
            if (r.Width < 2 || r.Height < 2) return;
            if (block < 2) block = 2;
            int sw = Math.Max(1, r.Width / block), sh = Math.Max(1, r.Height / block);
            if (annotation.MosaicPreview == null || annotation.MosaicSource != r || annotation.MosaicPreviewBlock != block)
            {
                if (annotation.MosaicPreview != null) annotation.MosaicPreview.Dispose();
                annotation.MosaicPreview = new Bitmap(sw, sh, PixelFormat.Format32bppArgb);
                using (var gs = Graphics.FromImage(annotation.MosaicPreview))
                {
                    gs.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    gs.DrawImage(_screen, new Rectangle(0, 0, sw, sh), r, GraphicsUnit.Pixel);
                }
                annotation.MosaicSource = r; annotation.MosaicPreviewBlock = block;
            }
            var oldI = g.InterpolationMode; var oldP = g.PixelOffsetMode;
            g.InterpolationMode = InterpolationMode.NearestNeighbor;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            g.DrawImage(annotation.MosaicPreview, new Rectangle(r.Location, r.Size), new Rectangle(0, 0, sw, sh), GraphicsUnit.Pixel);
            g.InterpolationMode = oldI; g.PixelOffsetMode = oldP;
        }

        private static Rectangle NormalizeRect(Point a, Point b)
        {
            int x = Math.Min(a.X, b.X), y = Math.Min(a.Y, b.Y);
            return new Rectangle(x, y, Math.Abs(a.X - b.X), Math.Abs(a.Y - b.Y));
        }

        private const int HandleSize = 8;
        // 鼠标在选区的哪个边/角(8px 热区内)
        private HandleEdge HandleAt(Point p)
        {
            if (_sel.Width <= 0) return HandleEdge.None;
            int l = _sel.Left, r = _sel.Right, t = _sel.Top, b = _sel.Bottom;
            bool nearL = p.X >= l - HandleSize && p.X <= l + HandleSize;
            bool nearR = p.X >= r - HandleSize && p.X <= r + HandleSize;
            bool nearT = p.Y >= t - HandleSize && p.Y <= t + HandleSize;
            bool nearB = p.Y >= b - HandleSize && p.Y <= b + HandleSize;
            bool inY = p.Y >= t - HandleSize && p.Y <= b + HandleSize;
            bool inX = p.X >= l - HandleSize && p.X <= r + HandleSize;
            if (nearL && nearT) return HandleEdge.TL;
            if (nearR && nearT) return HandleEdge.TR;
            if (nearL && nearB) return HandleEdge.BL;
            if (nearR && nearB) return HandleEdge.BR;
            if (nearL && inY) return HandleEdge.Left;
            if (nearR && inY) return HandleEdge.Right;
            if (nearT && inX) return HandleEdge.Top;
            if (nearB && inX) return HandleEdge.Bottom;
            return HandleEdge.None;
        }

        private static Cursor CursorForHandle(HandleEdge h)
        {
            switch (h)
            {
                case HandleEdge.TL:
                case HandleEdge.BR: return Cursors.SizeNWSE;
                case HandleEdge.TR:
                case HandleEdge.BL: return Cursors.SizeNESW;
                case HandleEdge.Left:
                case HandleEdge.Right: return Cursors.SizeWE;
                case HandleEdge.Top:
                case HandleEdge.Bottom: return Cursors.SizeNS;
            }
            return Cursors.Cross;
        }

        private Rectangle ResizeCircle(Rectangle original, HandleEdge edge, Point mouse)
        {
            bool left = edge == HandleEdge.Left || edge == HandleEdge.TL || edge == HandleEdge.BL;
            bool top = edge == HandleEdge.Top || edge == HandleEdge.TL || edge == HandleEdge.TR;
            int anchorX = left ? original.Right : original.Left;
            int anchorY = top ? original.Bottom : original.Top;
            bool horizontal = edge == HandleEdge.Left || edge == HandleEdge.Right;
            bool vertical = edge == HandleEdge.Top || edge == HandleEdge.Bottom;
            int side;
            if (horizontal)
            {
                int center = original.Top + original.Height / 2;
                side = Math.Min(Math.Abs(mouse.X - anchorX), 2 * Math.Min(center, ClientSize.Height - center));
                side = Math.Min(side, mouse.X < anchorX ? anchorX : ClientSize.Width - anchorX);
                return new Rectangle(mouse.X < anchorX ? anchorX - side : anchorX, center - side / 2, side, side);
            }
            if (vertical)
            {
                int center = original.Left + original.Width / 2;
                side = Math.Min(Math.Abs(mouse.Y - anchorY), 2 * Math.Min(center, ClientSize.Width - center));
                side = Math.Min(side, mouse.Y < anchorY ? anchorY : ClientSize.Height - anchorY);
                return new Rectangle(center - side / 2, mouse.Y < anchorY ? anchorY - side : anchorY, side, side);
            }
            side = Math.Min(Math.Abs(mouse.X - anchorX), Math.Abs(mouse.Y - anchorY));
            side = Math.Min(side, mouse.X < anchorX ? anchorX : ClientSize.Width - anchorX);
            side = Math.Min(side, mouse.Y < anchorY ? anchorY : ClientSize.Height - anchorY);
            return new Rectangle(mouse.X < anchorX ? anchorX - side : anchorX,
                mouse.Y < anchorY ? anchorY - side : anchorY, side, side);
        }

        // 拖动边/角时,把对应边/角贴到鼠标位置(自动处理翻转)
        private static Rectangle ResizeSel(Rectangle orig, HandleEdge h, Point m)
        {
            int l = orig.Left, t = orig.Top, r = orig.Right, b = orig.Bottom;
            if (h == HandleEdge.Left || h == HandleEdge.TL || h == HandleEdge.BL) l = m.X;
            if (h == HandleEdge.Right || h == HandleEdge.TR || h == HandleEdge.BR) r = m.X;
            if (h == HandleEdge.Top || h == HandleEdge.TL || h == HandleEdge.TR) t = m.Y;
            if (h == HandleEdge.Bottom || h == HandleEdge.BL || h == HandleEdge.BR) b = m.Y;
            int x = Math.Min(l, r), y = Math.Min(t, b);
            return new Rectangle(x, y, Math.Max(1, Math.Abs(r - l)), Math.Max(1, Math.Abs(b - t)));
        }
    }
}
