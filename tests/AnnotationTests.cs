using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

namespace SnapTool
{
    internal static class AnnotationTests
    {
        private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;

        internal static void Run(Action<bool, string> check, string outputFolder)
        {
            Directory.CreateDirectory(outputFolder);
            TestToolOrderAndKeys(check);
            TestDrawingPixels(check);
            TestMouseTools(check);
            TestConstraints(check);
            TestUndoRedo(check);
            TestSelectMoveDelete(check);
            TestDeleteDuringMove(check);
            TestShapeClipping(check);
            TestFilledAndDoubleArrow(check);
            TestSelectedStyles(check);
            TestAnnotationCaches(check);
            TestDegenerateAndDoubleClick(check);
            WritePreview(check, outputFolder);
        }

        private static object Get(CaptureForm form, string field)
        {
            return typeof(CaptureForm).GetField(field, Private).GetValue(form);
        }

        private static void Set(CaptureForm form, string field, object value)
        {
            typeof(CaptureForm).GetField(field, Private).SetValue(form, value);
        }

        private static object Call(CaptureForm form, string method, params object[] args)
        {
            return typeof(CaptureForm).GetMethod(method, Private).Invoke(form, args);
        }

        private static List<Annotation> Items(CaptureForm form)
        {
            return (List<Annotation>)Get(form, "_items");
        }

        private static Bitmap Source()
        {
            Bitmap source = new Bitmap(800, 600, PixelFormat.Format32bppArgb);
            using (Graphics graphics = Graphics.FromImage(source)) graphics.Clear(Color.White);
            for (int y = 320; y < 430; y++)
                for (int x = 450; x < 620; x++)
                    source.SetPixel(x, y, ((x + y) & 1) == 0 ? Color.Navy : Color.Orange);
            return source;
        }

        private static CaptureForm NewForm()
        {
            CaptureForm form = new CaptureForm(Source()) { Location = new Point(-20000, -20000), TopMost = false };
            form.Show();
            Application.DoEvents();
            Set(form, "_sel", new Rectangle(30, 80, 740, 480));
            Call(form, "EnterEditing");
            Set(form, "_color", Color.Red);
            Set(form, "_penWidth", 5f);
            return form;
        }

        private static MouseEventArgs Mouse(MouseButtons button, Point point)
        {
            return new MouseEventArgs(button, 1, point.X, point.Y, 0);
        }

        private static void Drag(CaptureForm form, Tool tool, Point start, Point end)
        {
            Call(form, "SelectTool", tool);
            Call(form, "OnMouseDown", Mouse(MouseButtons.Left, start));
            Call(form, "OnMouseMove", Mouse(MouseButtons.Left, end));
            Call(form, "OnMouseUp", Mouse(MouseButtons.Left, end));
        }

        private static Annotation Mark(Tool tool, Point start, Point end)
        {
            return new Annotation { Tool = tool, P1 = start, P2 = end, Color = Color.Red,
                Width = 5, FontSize = 24, Block = 8, Number = 7,
                Text = "Snap 123", Points = new List<Point> { start, end } };
        }

        private static Bitmap Draw(CaptureForm form, Annotation annotation)
        {
            Bitmap result = (Bitmap)((Bitmap)Get(form, "_screen")).Clone();
            using (Graphics graphics = Graphics.FromImage(result))
            {
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                Call(form, "DrawAnnotation", graphics, annotation);
            }
            return result;
        }

        private static bool Red(Color color)
        {
            return color.R > 190 && color.G < 90 && color.B < 90;
        }

        private static int Changed(Bitmap before, Bitmap after, Rectangle area)
        {
            int count = 0;
            area = Rectangle.Intersect(new Rectangle(Point.Empty, before.Size), area);
            for (int y = area.Top; y < area.Bottom; y++)
                for (int x = area.Left; x < area.Right; x++)
                    if (before.GetPixel(x, y).ToArgb() != after.GetPixel(x, y).ToArgb()) count++;
            return count;
        }

        private static void TestToolOrderAndKeys(Action<bool, string> check)
        {
            Tool[] tools = { Tool.Rect, Tool.Ellipse, Tool.Arrow, Tool.Line, Tool.Pen,
                Tool.Text, Tool.Mosaic, Tool.Number, Tool.Highlight, Tool.Select };
            Keys[] keys = { Keys.D1, Keys.D2, Keys.D3, Keys.D4, Keys.D5,
                Keys.D6, Keys.D7, Keys.D8, Keys.D9, Keys.D0 };
            using (CaptureForm form = NewForm())
            {
                var buttons = (List<Button>)Get(form, "_toolButtons");
                check(buttons.Count == tools.Length, "annotation toolbar exposes all ten tools");
                for (int i = 0; i < tools.Length; i++)
                {
                    buttons[i].PerformClick();
                    check((Tool)Get(form, "_tool") == tools[i], "toolbar position " + (i + 1) + " selects " + tools[i]);
                    KeyEventArgs key = new KeyEventArgs(keys[i]);
                    Call(form, "OnKeyDown", key);
                    check(key.Handled && (Tool)Get(form, "_tool") == tools[i], keys[i] + " selects " + tools[i]);
                }
                check(buttons[0].Text.Contains("矩形") && buttons[1].Text.Contains("圆"),
                    "annotation rectangle and circle tools are first and second");
            }
        }

        private static void TestDrawingPixels(Action<bool, string> check)
        {
            using (CaptureForm form = NewForm())
            {
                Bitmap source = (Bitmap)Get(form, "_screen");
                Point start = new Point(80, 100), end = new Point(220, 200);
                using (Bitmap result = Draw(form, Mark(Tool.Rect, start, end)))
                {
                    check(Red(result.GetPixel(150, 100)) && Changed(source, result, new Rectangle(75, 95, 150, 110)) > 500,
                        "rectangle annotation draws a visible outline");
                    check(result.GetPixel(150, 150).ToArgb() == source.GetPixel(150, 150).ToArgb(),
                        "rectangle annotation leaves its center unfilled");
                }
                using (Bitmap result = Draw(form, Mark(Tool.Ellipse, start, end)))
                {
                    check(Red(result.GetPixel(150, 100)), "ellipse annotation draws the curved top edge");
                    check(result.GetPixel(80, 100).ToArgb() == source.GetPixel(80, 100).ToArgb() &&
                        result.GetPixel(150, 150).ToArgb() == source.GetPixel(150, 150).ToArgb(),
                        "ellipse annotation leaves outside corner and center unfilled");
                }
                start = new Point(90, 150); end = new Point(220, 150);
                using (Bitmap result = Draw(form, Mark(Tool.Line, start, end)))
                {
                    check(Red(result.GetPixel(150, 150)), "line annotation draws its midpoint");
                    check(result.GetPixel(150, 175).ToArgb() == source.GetPixel(150, 175).ToArgb(),
                        "line annotation leaves pixels away from the stroke unchanged");
                }
                using (Bitmap result = Draw(form, Mark(Tool.Arrow, start, end)))
                {
                    check(Red(result.GetPixel(150, 150)), "existing arrow annotation still draws its shaft");
                    check(Changed(source, result, new Rectangle(190, 135, 30, 30)) > 100,
                        "arrow annotation includes a visible arrowhead");
                }
                Annotation pen = Mark(Tool.Pen, new Point(90, 110), new Point(180, 105));
                pen.Points = new List<Point> { pen.P1, new Point(135, 130), pen.P2 };
                using (Bitmap result = Draw(form, pen))
                    check(Red(result.GetPixel(135, 130)), "existing pen annotation preserves its intermediate stroke point");
                using (Bitmap result = Draw(form, Mark(Tool.Text, new Point(80, 100), Point.Empty)))
                    check(Changed(source, result, new Rectangle(75, 95, 160, 50)) > 100,
                        "existing text annotation renders outlined text pixels");
                using (Bitmap result = Draw(form, Mark(Tool.Mosaic, new Point(450, 320), new Point(610, 420))))
                {
                    check(Changed(source, result, new Rectangle(450, 320, 160, 100)) > 1000,
                        "existing mosaic annotation obscures fine source detail");
                    check(result.GetPixel(482, 350).ToArgb() == result.GetPixel(483, 350).ToArgb() &&
                        source.GetPixel(482, 350).ToArgb() != source.GetPixel(483, 350).ToArgb(),
                        "mosaic output replaces fine alternating pixels with blocks");
                }
                using (Bitmap result = Draw(form, Mark(Tool.Number, new Point(120, 140), Point.Empty)))
                    check(Changed(source, result, new Rectangle(102, 122, 36, 36)) > 100,
                        "existing numbered marker renders its badge and number");
                Annotation highlight = Mark(Tool.Highlight, new Point(90, 130), new Point(190, 130));
                highlight.Color = Color.Lime;
                using (Bitmap result = Draw(form, highlight))
                {
                    Color pixel = result.GetPixel(140, 130);
                    check(pixel.A == 255 && pixel.G == 255 && pixel.R > 100 && pixel.R < 245 && pixel.B == pixel.R,
                        "existing highlight blends translucent color with the screenshot");
                }
                check(source.GetPixel(150, 100).ToArgb() == Color.White.ToArgb(),
                    "annotation rendering never changes the source screenshot");
            }
        }

        private static void TestMouseTools(Action<bool, string> check)
        {
            foreach (Tool tool in new[] { Tool.Rect, Tool.Ellipse, Tool.Arrow, Tool.Line,
                Tool.Pen, Tool.Mosaic, Tool.Highlight })
            {
                using (CaptureForm form = NewForm())
                {
                    Point start = new Point(120, 210), end = new Point(300, 290);
                    if (tool == Tool.Line || tool == Tool.Arrow) end.Y = start.Y;
                    Drag(form, tool, start, end);
                    check(Items(form).Count == 1 && Items(form)[0].Tool == tool,
                        tool + " mouse gesture commits exactly one annotation");
                    check(Items(form)[0].P1 == start && Items(form)[0].P2 == end,
                        tool + " mouse-up preserves the final endpoint");
                    if (tool == Tool.Pen || tool == Tool.Highlight)
                        check(Items(form)[0].Points[Items(form)[0].Points.Count - 1] == end,
                            tool + " stroke retains the mouse-up point");
                }
            }
            using (CaptureForm form = NewForm())
            {
                Call(form, "SelectTool", Tool.Text);
                Call(form, "OnMouseDown", Mouse(MouseButtons.Left, new Point(160, 200)));
                TextBox box = (TextBox)Get(form, "_textBox");
                box.Text = "Added through text tool";
                Call(form, "TextBoxKeyDown", box, new KeyEventArgs(Keys.Enter));
                check(Items(form).Count == 1 && Items(form)[0].Tool == Tool.Text && Items(form)[0].Text == "Added through text tool",
                    "text mouse gesture and Enter commit the editor contents");
            }
            using (CaptureForm form = NewForm())
            {
                Drag(form, Tool.Number, new Point(160, 220), new Point(160, 220));
                Drag(form, Tool.Number, new Point(210, 220), new Point(210, 220));
                check(Items(form).Count == 2 && Items(form)[0].Number == 1 && Items(form)[1].Number == 2,
                    "number tool increments consecutive click badges");
            }
            foreach (Tool tool in new[] { Tool.Rect, Tool.Ellipse, Tool.Line, Tool.Arrow })
            {
                using (CaptureForm form = NewForm())
                {
                    Drag(form, tool, new Point(120, 210), new Point(120, 210));
                    check(Items(form).Count == 0, tool + " ignores a zero-length click");
                }
            }
        }

        private static void TestConstraints(Action<bool, string> check)
        {
            Point start = new Point(100, 100), end = new Point(220, 170);
            foreach (Tool tool in new[] { Tool.Rect, Tool.Ellipse })
            {
                Point constrained = CaptureForm.ConstrainAnnotationPoint(start, end, tool, true);
                check(constrained.X > start.X && constrained.Y > start.Y &&
                    constrained.X - start.X == constrained.Y - start.Y,
                    tool + " Shift constraint produces equal sides");
                check(CaptureForm.ConstrainAnnotationPoint(start, end, tool, false) == end,
                    tool + " remains unconstrained without Shift");
                Point reverse = CaptureForm.ConstrainAnnotationPoint(start, new Point(35, 55), tool, true);
                check(reverse.X < start.X && reverse.Y < start.Y && start.X - reverse.X == start.Y - reverse.Y,
                    tool + " Shift constraint preserves reverse-drag direction");
            }
            foreach (Tool tool in new[] { Tool.Line, Tool.Arrow })
            {
                Point diagonal = CaptureForm.ConstrainAnnotationPoint(start, new Point(220, 190), tool, true);
                check(Math.Abs((diagonal.X - start.X) - (diagonal.Y - start.Y)) <= 1,
                    tool + " Shift snaps a diagonal to 45 degrees");
                Point horizontal = CaptureForm.ConstrainAnnotationPoint(start, new Point(230, 110), tool, true);
                check(horizontal.X > start.X && horizontal.Y == start.Y,
                    tool + " Shift snaps a shallow stroke horizontally");
            }
        }

        private static void TestUndoRedo(Action<bool, string> check)
        {
            using (CaptureForm form = NewForm())
            {
                Drag(form, Tool.Rect, new Point(100, 170), new Point(240, 260));
                Drag(form, Tool.Ellipse, new Point(280, 190), new Point(400, 280));
                Call(form, "Undo");
                check(Items(form).Count == 1 && Items(form)[0].Tool == Tool.Rect, "Undo removes only the latest drawn annotation");
                Call(form, "Redo");
                check(Items(form).Count == 2 && Items(form)[1].Tool == Tool.Ellipse, "Redo restores the latest drawn annotation");
                KeyEventArgs undoKey = new KeyEventArgs(Keys.Control | Keys.Z);
                Call(form, "OnKeyDown", undoKey);
                check(undoKey.Handled && Items(form).Count == 1, "Ctrl+Z invokes annotation undo");
                KeyEventArgs redoKey = new KeyEventArgs(Keys.Control | Keys.Y);
                Call(form, "OnKeyDown", redoKey);
                check(redoKey.Handled && Items(form).Count == 2, "Ctrl+Y invokes annotation redo");
                Call(form, "Undo");
                Drag(form, Tool.Line, new Point(300, 350), new Point(430, 350));
                Call(form, "Redo");
                check(Items(form).Count == 2 && Items(form)[1].Tool == Tool.Line,
                    "drawing after Undo clears the abandoned redo branch");
            }
            using (CaptureForm form = NewForm())
            {
                Drag(form, Tool.Number, new Point(150, 200), new Point(150, 200));
                Call(form, "Undo");
                Call(form, "Redo");
                Drag(form, Tool.Number, new Point(220, 200), new Point(220, 200));
                check(Items(form).Count == 2 && Items(form)[0].Number == 1 && Items(form)[1].Number == 2,
                    "Undo and Redo keep the next numbered marker consistent");
            }
            using (CaptureForm form = NewForm())
            {
                Call(form, "Undo");
                check(!((Rectangle)Get(form, "_sel")).IsEmpty && !form.IsDisposed,
                    "Undo with no annotations preserves the screenshot selection");
            }
        }

        private static void TestSelectMoveDelete(Action<bool, string> check)
        {
            using (CaptureForm form = NewForm())
            {
                Point originalStart = new Point(120, 200), originalEnd = new Point(270, 300);
                Drag(form, Tool.Rect, originalStart, originalEnd);
                Drag(form, Tool.Select, new Point(180, 200), new Point(240, 250));
                check(Items(form).Count == 1 && Items(form)[0].P1 == new Point(180, 250) && Items(form)[0].P2 == new Point(330, 350),
                    "Select drags an existing annotation without creating a new one");
                check(Get(form, "_selectedAnnotation") != null, "Select keeps the moved annotation selected");
                Call(form, "Undo");
                check(Items(form).Count == 1 && Items(form)[0].P1 == originalStart && Items(form)[0].P2 == originalEnd,
                    "Undo restores both endpoints after an annotation move");
                Call(form, "Redo");
                check(Items(form)[0].P1 == new Point(180, 250) && Items(form)[0].P2 == new Point(330, 350),
                    "Redo restores an annotation move");
                Drag(form, Tool.Select, new Point(230, 250), new Point(230, 250));
                KeyEventArgs deleteKey = new KeyEventArgs(Keys.Delete);
                Call(form, "OnKeyDown", deleteKey);
                check(deleteKey.Handled && Items(form).Count == 0 && Get(form, "_selectedAnnotation") == null,
                    "Delete removes the selected annotation and clears its selection");
                Call(form, "Undo");
                check(Items(form).Count == 1 && Items(form)[0].P1 == new Point(180, 250),
                    "Undo restores a deleted annotation at its moved position");
                Call(form, "Redo");
                check(Items(form).Count == 0, "Redo reapplies selected annotation deletion");
            }
            using (CaptureForm form = NewForm())
            {
                Drag(form, Tool.Line, new Point(100, 210), new Point(300, 210));
                Drag(form, Tool.Select, new Point(200, 210), new Point(250, 250));
                check(Items(form)[0].P1 == new Point(150, 250) && Items(form)[0].P2 == new Point(350, 250),
                    "Select hit-tests and moves a line segment");
                Drag(form, Tool.Select, new Point(600, 500), new Point(650, 520));
                check(Items(form).Count == 1 && Get(form, "_selectedAnnotation") == null,
                    "Select on empty screenshot space clears selection without drawing");
            }
        }

        private static void TestDeleteDuringMove(Action<bool, string> check)
        {
            using (CaptureForm form = NewForm())
            {
                Point originalStart = new Point(120, 200), originalEnd = new Point(270, 300);
                Drag(form, Tool.Rect, originalStart, originalEnd);
                Call(form, "SelectTool", Tool.Select);
                Call(form, "OnMouseDown", Mouse(MouseButtons.Left, new Point(180, 200)));
                Call(form, "OnMouseMove", Mouse(MouseButtons.Left, new Point(210, 210)));
                check(Items(form)[0].P1 == new Point(150, 210) && Items(form)[0].P2 == new Point(300, 310) &&
                    (bool)Get(form, "_dragging") && (bool)Get(form, "_movingAnnotation"),
                    "unfinished Select drag temporarily moves the rectangle by 30 and 10 pixels");
                Call(form, "DeleteSelectedAnnotation");
                check(Items(form).Count == 0 && !(bool)Get(form, "_dragging") && !(bool)Get(form, "_movingAnnotation") &&
                    Get(form, "_selectedAnnotation") == null,
                    "deleting during an annotation move cancels the active drag and clears selection");
                Call(form, "Undo");
                check(Items(form).Count == 1 && Items(form)[0].P1 == originalStart && Items(form)[0].P2 == originalEnd &&
                    !(bool)Get(form, "_dragging") && !(bool)Get(form, "_movingAnnotation"),
                    "one Undo restores a mid-drag deletion at the pre-drag position");
                Call(form, "Redo");
                check(Items(form).Count == 0 && !(bool)Get(form, "_dragging") && !(bool)Get(form, "_movingAnnotation"),
                    "Redo reapplies a mid-drag deletion without restarting its canceled drag");
            }
        }

        private static void TestShapeClipping(Action<bool, string> check)
        {
            using (CaptureForm form = NewForm())
            {
                Set(form, "_sel", new Rectangle(80, 100, 240, 240));
                Set(form, "_shape", CaptureShape.Circle);
                Drag(form, Tool.Line, new Point(140, 160), new Point(310, 160));
                using (Bitmap result = (Bitmap)Call(form, "RenderSelection"))
                {
                    check(result.Size == new Size(240, 240) && Red(result.GetPixel(120, 60)),
                        "new line annotation appears in the circular screenshot output");
                    check(result.GetPixel(230, 60).A == 0 && result.GetPixel(0, 0).A == 0,
                        "shape masking clips annotations as well as source pixels");
                }
            }
        }

        private static void TestFilledAndDoubleArrow(Action<bool, string> check)
        {
            foreach (Tool tool in new[] { Tool.Rect, Tool.Ellipse })
            {
                using (CaptureForm form = NewForm())
                {
                    Call(form, "SelectTool", tool);
                    CheckBox fill = (CheckBox)Get(form, "_fillToggle");
                    check(fill.Enabled && !((CheckBox)Get(form, "_doubleArrowToggle")).Enabled,
                        tool + " enables fill and disables the arrow-only option");
                    fill.Checked = true;
                    Drag(form, tool, new Point(100, 200), new Point(260, 320));
                    Annotation item = Items(form)[0];
                    using (Bitmap result = Draw(form, item))
                    {
                        check(item.Filled && Red(result.GetPixel(180, 260)), tool + " fill option produces solid center pixels");
                        if (tool == Tool.Ellipse)
                            check(result.GetPixel(100, 200).ToArgb() == Color.White.ToArgb(),
                                "filled ellipse keeps its outside corner empty");
                    }
                    Drag(form, Tool.Select, new Point(180, 260), new Point(180, 260));
                    check(Get(form, "_selectedAnnotation") == item, tool + " filled interior can select the annotation");
                    fill.Checked = false;
                    using (Bitmap result = Draw(form, item))
                        check(!item.Filled && result.GetPixel(180, 260).ToArgb() == Color.White.ToArgb(),
                            tool + " selected fill change restores an empty center");
                    Call(form, "Undo");
                    using (Bitmap result = Draw(form, item))
                        check(item.Filled && Red(result.GetPixel(180, 260)), tool + " Undo restores filled pixels");
                    Call(form, "Redo");
                    using (Bitmap result = Draw(form, item))
                        check(!item.Filled && result.GetPixel(180, 260).ToArgb() == Color.White.ToArgb(),
                            tool + " Redo restores the unfilled outline");
                }
            }
            using (CaptureForm form = NewForm())
            {
                Call(form, "SelectTool", Tool.Arrow);
                CheckBox both = (CheckBox)Get(form, "_doubleArrowToggle");
                check(both.Enabled && !((CheckBox)Get(form, "_fillToggle")).Enabled,
                    "arrow enables bidirectional mode and disables fill");
                both.Checked = true;
                Drag(form, Tool.Arrow, new Point(100, 230), new Point(320, 230));
                Annotation item = Items(form)[0];
                Annotation single = Mark(Tool.Arrow, item.P1, item.P2);
                Bitmap source = (Bitmap)Get(form, "_screen");
                Rectangle startHead = new Rectangle(85, 212, 45, 36);
                int doublePixels, singlePixels;
                using (Bitmap result = Draw(form, item))
                    doublePixels = Changed(source, result, startHead);
                using (Bitmap result = Draw(form, single))
                    singlePixels = Changed(source, result, startHead);
                check(item.DoubleArrow && doublePixels > singlePixels + 20,
                    "bidirectional arrow adds a visible head at the starting endpoint");
                Drag(form, Tool.Select, new Point(210, 230), new Point(210, 230));
                both.Checked = false;
                using (Bitmap result = Draw(form, item))
                    check(!item.DoubleArrow && Changed(source, result, startHead) == singlePixels,
                        "selected arrow can return to a single head");
                Call(form, "Undo");
                using (Bitmap result = Draw(form, item))
                    check(item.DoubleArrow && Changed(source, result, startHead) == doublePixels,
                        "Undo restores the second arrowhead pixels");
                Call(form, "Redo");
                check(!item.DoubleArrow, "Redo reapplies the single-arrow style");
                Call(form, "SelectTool", Tool.Line);
                check(!both.Enabled && !((CheckBox)Get(form, "_fillToggle")).Enabled,
                    "line disables shape-specific fill and arrow options");
            }
        }

        private static void TestSelectedStyles(Action<bool, string> check)
        {
            using (CaptureForm form = NewForm())
            {
                Drag(form, Tool.Rect, new Point(100, 210), new Point(300, 320));
                Drag(form, Tool.Select, new Point(180, 210), new Point(180, 210));
                Annotation item = Items(form)[0];
                RectangleF originalBounds = AnnotationGeometry.Bounds(item);
                Call(form, "SelectColor", Color.DodgerBlue);
                using (Bitmap result = Draw(form, item))
                {
                    Color pixel = result.GetPixel(180, 210);
                    check(item.Color == Color.DodgerBlue && pixel.B > 230 && pixel.R < 70,
                        "changing selected color updates visible stroke pixels");
                }
                Call(form, "Undo");
                using (Bitmap result = Draw(form, item))
                    check(item.Color == Color.Red && Red(result.GetPixel(180, 210)), "Undo restores the selected annotation color");
                Call(form, "Redo");
                check(item.Color == Color.DodgerBlue, "Redo restores the changed annotation color");
                Bitmap source = (Bitmap)Get(form, "_screen");
                Rectangle region = new Rectangle(85, 195, 230, 140);
                int oldPixels;
                using (Bitmap result = Draw(form, item)) oldPixels = Changed(source, result, region);
                Call(form, "AdjustParam", 4);
                using (Bitmap result = Draw(form, item))
                    check(item.Width == 9f && Changed(source, result, region) > oldPixels + 100,
                        "selected width change thickens the visible outline");
                check(AnnotationGeometry.Bounds(item).Width > originalBounds.Width,
                    "width changes invalidate cached annotation bounds");
                Call(form, "Undo");
                using (Bitmap result = Draw(form, item))
                    check(item.Width == 5f && Changed(source, result, region) == oldPixels,
                        "Undo restores the previous stroke thickness exactly");
                check(AnnotationGeometry.Bounds(item) == originalBounds, "Undo rebuilds bounds at the original thickness");
                Call(form, "Redo");
                check(item.Width == 9f, "Redo reapplies selected stroke thickness");
                KeyEventArgs decrease = new KeyEventArgs(Keys.OemOpenBrackets);
                Call(form, "OnKeyDown", decrease);
                check(decrease.Handled && item.Width == 8f, "bracket shortcut changes selected stroke thickness");
                Call(form, "OnMouseWheel", new MouseEventArgs(MouseButtons.None, 0, 500, 450, 120));
                check(item.Width == 9f, "mouse wheel changes selected stroke thickness");
            }
        }

        private static void TestAnnotationCaches(Action<bool, string> check)
        {
            using (CaptureForm form = NewForm())
            {
                Drag(form, Tool.Pen, new Point(100, 210), new Point(240, 250));
                Annotation item = Items(form)[0];
                RectangleF beforeBounds = AnnotationGeometry.Bounds(item);
                Point[] beforePoints = item.DrawingPoints;
                check(object.ReferenceEquals(beforePoints, item.DrawingPoints), "unchanged pen redraw reuses its cached point array");
                using (Bitmap result = Draw(form, item))
                    check(Red(result.GetPixel(170, 230)), "cached pen rendering contains its original stroke");
                Drag(form, Tool.Select, new Point(170, 230), new Point(220, 260));
                Point[] movedPoints = item.DrawingPoints;
                RectangleF movedBounds = AnnotationGeometry.Bounds(item);
                using (Bitmap result = Draw(form, item))
                    check(Red(result.GetPixel(220, 260)) && result.GetPixel(170, 230).ToArgb() == Color.White.ToArgb(),
                        "moving a cached pen redraws at its new location and clears the old stroke");
                check(!object.ReferenceEquals(beforePoints, movedPoints) && movedPoints[0] == new Point(150, 240) &&
                    movedBounds.X == beforeBounds.X + 50 && movedBounds.Y == beforeBounds.Y + 30,
                    "pen move refreshes both cached points and hit-test bounds");
                Call(form, "Undo");
                using (Bitmap result = Draw(form, item))
                    check(Red(result.GetPixel(170, 230)) && AnnotationGeometry.Bounds(item) == beforeBounds,
                        "Undo rebuilds cached pen rendering at its original position");
            }
            using (CaptureForm form = NewForm())
            {
                Bitmap source = (Bitmap)Get(form, "_screen");
                using (Graphics graphics = Graphics.FromImage(source)) graphics.FillRectangle(Brushes.Lime, 495, 345, 27, 29);
                Drag(form, Tool.Mosaic, new Point(450, 320), new Point(610, 420));
                Annotation item = Items(form)[0];
                Rectangle area = new Rectangle(450, 320, 160, 100);
                using (Bitmap original = Draw(form, item))
                {
                    Bitmap firstPreview = item.MosaicPreview;
                    using (Bitmap same = Draw(form, item))
                        check(object.ReferenceEquals(firstPreview, item.MosaicPreview) && Changed(original, same, area) == 0,
                            "unchanged mosaic redraw reuses its cache without changing output pixels");
                    Drag(form, Tool.Select, new Point(550, 380), new Point(550, 380));
                    Call(form, "AdjustParam", 2);
                    using (Bitmap edited = Draw(form, item))
                        check(item.Block == 12 && !object.ReferenceEquals(firstPreview, item.MosaicPreview) && Changed(original, edited, area) > 20,
                            "selected mosaic block change refreshes the cache and visible obscured detail");
                    Call(form, "Undo");
                    using (Bitmap restored = Draw(form, item))
                        check(item.Block == 8 && Changed(original, restored, area) == 0,
                            "Undo rebuilds the original mosaic pixels exactly");
                    Call(form, "Redo");
                    check(item.Block == 12 && item.MosaicPreview == null, "Redo invalidates the mosaic preview before regeneration");
                }
                Call(form, "Undo"); // Style.
                Call(form, "Undo"); // Add.
                check(Items(form).Count == 0, "mosaic annotation can be undone after its style change");
                using (Bitmap cached = Draw(form, item)) { }
                Drag(form, Tool.Rect, new Point(100, 200), new Point(200, 280));
                check(item.MosaicPreview == null, "discarding a redo branch disposes an abandoned mosaic cache");
            }
        }

        private static void TestDegenerateAndDoubleClick(Action<bool, string> check)
        {
            foreach (Tool tool in new[] { Tool.Rect, Tool.Ellipse })
            {
                using (CaptureForm form = NewForm())
                {
                    Drag(form, tool, new Point(150, 220), new Point(152, 221));
                    check(Items(form).Count == 0, tool + " rejects a 2-by-1 degenerate drag");
                    Drag(form, tool, new Point(150, 220), new Point(152, 222));
                    check(Items(form).Count == 1, tool + " accepts a nondegenerate two-pixel shape");
                }
            }
            using (CaptureForm form = NewForm())
            {
                Call(form, "SelectTool", Tool.Pen);
                Point start = new Point(120, 230), end = new Point(240, 270);
                Call(form, "OnMouseDown", Mouse(MouseButtons.Left, start));
                for (int i = 0; i < 4; i++) Call(form, "OnMouseMove", Mouse(MouseButtons.Left, start));
                for (int i = 0; i < 4; i++) Call(form, "OnMouseMove", Mouse(MouseButtons.Left, end));
                Call(form, "OnMouseUp", Mouse(MouseButtons.Left, end));
                Annotation item = Items(form)[0];
                using (Bitmap result = Draw(form, item))
                    check(item.Points.Count == 2 && Red(result.GetPixel(180, 250)),
                        "duplicate mouse positions do not add redundant pen points or lose the stroke");
                Call(form, "RemoveDoubleClickStamp");
                check(Items(form).Count == 1, "double-click cleanup preserves a dragged pen stroke");
            }
            foreach (Tool tool in new[] { Tool.Number, Tool.Pen, Tool.Highlight })
            {
                using (CaptureForm form = NewForm())
                {
                    Drag(form, Tool.Rect, new Point(100, 200), new Point(260, 320));
                    Drag(form, tool, new Point(350, 260), new Point(350, 260));
                    check(Items(form).Count == 2, tool + " click commits one temporary stamp");
                    Call(form, "RemoveDoubleClickStamp");
                    check(Items(form).Count == 1 && Items(form)[0].Tool == Tool.Rect,
                        tool + " double-click cleanup removes only the recent stamp");
                    Call(form, "Undo");
                    check(Items(form).Count == 0, tool + " stamp cleanup preserves earlier undo history");
                    Call(form, "Redo");
                    check(Items(form).Count == 1 && Items(form)[0].Tool == Tool.Rect,
                        tool + " removed stamp never returns through Redo");
                    if (tool == Tool.Number)
                    {
                        Drag(form, Tool.Number, new Point(370, 260), new Point(370, 260));
                        check(Items(form)[1].Number == 1, "double-click number cleanup restores the next badge counter");
                    }
                }
            }
            using (CaptureForm form = NewForm())
            {
                Drag(form, Tool.Number, new Point(350, 260), new Point(350, 260));
                Set(form, "_lastAnnotationClickAt", DateTime.UtcNow.AddMilliseconds(-SystemInformation.DoubleClickTime - 100));
                Call(form, "RemoveDoubleClickStamp");
                check(Items(form).Count == 1, "double-click cleanup preserves an older intended number stamp");
            }
        }

        private static void WritePreview(Action<bool, string> check, string outputFolder)
        {
            using (Bitmap source = new Bitmap(800, 600, PixelFormat.Format32bppArgb))
            {
                List<Annotation> marks = new List<Annotation>();
                using (Graphics graphics = Graphics.FromImage(source))
                using (Font heading = new Font("Microsoft YaHei", 18, FontStyle.Bold))
                using (Font label = new Font("Microsoft YaHei", 12))
                using (Brush ink = new SolidBrush(Color.FromArgb(37, 48, 72)))
                using (Pen border = new Pen(Color.FromArgb(223, 229, 240)))
                {
                graphics.Clear(Color.FromArgb(248, 250, 254));
                graphics.DrawString("SnapTool · 截图内标注工具", heading, ink, 22, 16);
                graphics.DrawString("1–9 切换工具  ·  0 选择移动  ·  Shift 锁定比例 / 角度", label, ink, 24, 50);
                Tool[] tools = { Tool.Rect, Tool.Ellipse, Tool.Arrow, Tool.Line, Tool.Pen,
                    Tool.Text, Tool.Mosaic, Tool.Number, Tool.Highlight };
                string[] names = { "1 矩形", "2 圆形 / 椭圆", "3 箭头", "4 直线", "5 画笔",
                    "6 文字", "7 马赛克", "8 序号", "9 高亮" };
                for (int i = 0; i < tools.Length; i++)
                {
                    int left = 22 + (i % 3) * 255, top = 92 + (i / 3) * 165;
                    graphics.FillRectangle(Brushes.White, left, top, 238, 150);
                    graphics.DrawRectangle(border, left, top, 238, 150);
                    graphics.DrawString(names[i], label, ink, left + 12, top + 10);
                    Annotation mark = Mark(tools[i], new Point(left + 32, top + 58), new Point(left + 204, top + 121));
                    mark.Color = i % 2 == 0 ? Color.FromArgb(245, 81, 85) : Color.FromArgb(65, 117, 232);
                    if (tools[i] == Tool.Line || tools[i] == Tool.Arrow)
                    { mark.P1 = new Point(left + 35, top + 108); mark.P2 = new Point(left + 200, top + 74); }
                    if (tools[i] == Tool.Pen)
                        mark.Points = new List<Point> { new Point(left + 32, top + 104), new Point(left + 72, top + 72),
                            new Point(left + 115, top + 110), new Point(left + 156, top + 69), new Point(left + 203, top + 100) };
                    if (tools[i] == Tool.Text) { mark.P1 = new Point(left + 37, top + 76); mark.Text = "Snap 标注"; }
                    if (tools[i] == Tool.Mosaic)
                        for (int y = top + 58; y < top + 122; y++)
                            for (int x = left + 32; x < left + 205; x++)
                                graphics.FillRectangle(((x + y) & 1) == 0 ? Brushes.DarkSlateBlue : Brushes.Orange, x, y, 1, 1);
                    if (tools[i] == Tool.Number) { mark.P1 = new Point(left + 119, top + 94); mark.Width = 8; mark.Number = 1; }
                    if (tools[i] == Tool.Highlight)
                    {
                        graphics.DrawString("重点内容", heading, ink, left + 53, top + 74);
                        mark.Color = Color.Gold;
                        mark.Width = 8;
                        mark.Points = new List<Point> { new Point(left + 43, top + 94), new Point(left + 191, top + 94) };
                    }
                    marks.Add(mark);
                }
                }
                using (CaptureForm form = new CaptureForm((Bitmap)source.Clone()) { TopMost = false })
                using (Bitmap preview = (Bitmap)source.Clone())
                using (Graphics rendered = Graphics.FromImage(preview))
                {
                    rendered.SmoothingMode = SmoothingMode.AntiAlias;
                    foreach (Annotation mark in marks) Call(form, "DrawAnnotation", rendered, mark);
                    string path = Path.Combine(outputFolder, "annotation-tools-preview.png");
                    preview.Save(path, ImageFormat.Png);
                    using (Bitmap decoded = new Bitmap(path))
                        check(decoded.Size == new Size(800, 600), "annotation tool preview is saved and readable");
                }
            }
        }
    }
}
