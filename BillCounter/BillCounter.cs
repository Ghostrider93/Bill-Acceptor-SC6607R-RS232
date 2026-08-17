// BillCounter - money counter for MEI/CPI CashFlow SC-series bill validators
// speaking EBDS over RS232. Built for the SC6607R on this bench.
//
// Protocol notes (verified against live hardware):
//   9600 baud, 7 data bits, EVEN parity, 1 stop bit
//   host  -> 02 08 1T D0 D1 D2 03 CHK          (8 bytes)
//   device-> 02 0B 2T D0 D1 D2 D3 D4 D5 03 CHK (11 bytes)
//   CHK = XOR of bytes[1] .. bytes[len-3]      (STX and ETX excluded)
//   Poll every ~100ms. Slower than ~200ms and the unit parks in PowerUp.
//
// Build: build.cmd  (uses the in-box csc.exe, no dependencies)

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.IO.Ports;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace BillCounter
{
    // ---------------------------------------------------------------- model --

    public class NoteEvent
    {
        public DateTime When;
        public int Index;
        public decimal Value;
        public bool Kept;          // stacked (true) or returned (false)
    }

    public class AcceptorStatus
    {
        public bool Idling, Accepting, Escrowed, Stacking, Stacked, Returning, Returned;
        public bool Cheated, Rejected, Jammed, StackerFull, CashboxPresent, Paused, Calibration;
        public bool PowerUp, InvalidCommand, Failure, TransportOpen;
        public int NoteValue;
        public byte Model, Revision;

        public string Summary()
        {
            var on = new List<string>();
            if (Idling) on.Add("Idling");
            if (Accepting) on.Add("Accepting");
            if (Escrowed) on.Add("Escrowed");
            if (Stacking) on.Add("Stacking");
            if (Stacked) on.Add("Stacked");
            if (Returning) on.Add("Returning");
            if (Returned) on.Add("Returned");
            if (Cheated) on.Add("Cheated");
            if (Rejected) on.Add("Rejected");
            if (Jammed) on.Add("JAMMED");
            if (StackerFull) on.Add("STACKER FULL");
            if (Paused) on.Add("Paused");
            if (PowerUp) on.Add("PowerUp");
            if (Failure) on.Add("FAILURE");
            if (TransportOpen) on.Add("Transport open");
            return on.Count == 0 ? "(idle)" : string.Join(", ", on.ToArray());
        }
    }

    // ------------------------------------------------------------- protocol --

    public static class Ebds
    {
        public static byte Checksum(byte[] b, int len)
        {
            int chk = 0;
            for (int i = 1; i <= len - 3; i++) chk ^= b[i];
            return (byte)(chk & 0xFF);
        }

        public static byte[] BuildPoll(int ack, int enableMask, int data1, int data2)
        {
            byte[] m = new byte[8];
            m[0] = 0x02;
            m[1] = 0x08;
            m[2] = (byte)(0x10 | (ack & 1));
            m[3] = (byte)(enableMask & 0x7F);
            m[4] = (byte)(data1 & 0x7F);
            m[5] = (byte)(data2 & 0x7F);
            m[6] = 0x03;
            m[7] = Checksum(m, 8);
            return m;
        }

        public static AcceptorStatus Decode(byte[] f)
        {
            var d = new byte[6];
            Array.Copy(f, 3, d, 0, 6);
            var s = new AcceptorStatus();
            s.Idling    = (d[0] & 0x01) != 0;
            s.Accepting = (d[0] & 0x02) != 0;
            s.Escrowed  = (d[0] & 0x04) != 0;
            s.Stacking  = (d[0] & 0x08) != 0;
            s.Stacked   = (d[0] & 0x10) != 0;
            s.Returning = (d[0] & 0x20) != 0;
            s.Returned  = (d[0] & 0x40) != 0;

            s.Cheated        = (d[1] & 0x01) != 0;
            s.Rejected       = (d[1] & 0x02) != 0;
            s.Jammed         = (d[1] & 0x04) != 0;
            s.StackerFull    = (d[1] & 0x08) != 0;
            s.CashboxPresent = (d[1] & 0x10) != 0;
            s.Paused         = (d[1] & 0x20) != 0;
            s.Calibration    = (d[1] & 0x40) != 0;

            s.PowerUp        = (d[2] & 0x01) != 0;
            s.InvalidCommand = (d[2] & 0x02) != 0;
            s.Failure        = (d[2] & 0x04) != 0;
            s.NoteValue      = (d[2] >> 3) & 0x07;
            s.TransportOpen  = (d[2] & 0x40) != 0;

            s.Model = d[4];
            s.Revision = d[5];
            return s;
        }
    }

    // ----------------------------------------------------------------- form --

    public class MainForm : Form
    {
        // denomination table - index 1..7. Verified on hardware: 1=$1, 3=$5, 6=$50.
        static readonly decimal[] Denoms = { 0m, 1m, 2m, 5m, 10m, 20m, 50m, 100m };

        Thread worker;
        volatile bool running;
        volatile bool wantReturn = true;   // return notes instead of stacking
        SerialPort port;

        // counters (touched on UI thread only)
        readonly int[] counts = new int[8];
        decimal total;
        int accepted, rejected, pollCount, replyCount, errorCount;
        DateTime sessionStart = DateTime.Now;
        readonly List<NoteEvent> history = new List<NoteEvent>();

        // controls
        ComboBox cboPort;
        Button btnConnect, btnReset, btnSave;
        CheckBox chkReturn, chkSound;
        Label lblTotal, lblState, lblCashbox, lblLink, lblStats, lblTargetInfo, lblAlert;
        ListView lvDenoms;
        TextBox txtLog, txtTarget;
        ProgressBar barTarget;
        decimal target;

        // kept so the rejection alert can flash the whole window
        Panel pnlTop, pnlLeft, pnlRight, pnlBottom;
        System.Windows.Forms.Timer flashTimer;
        int flashesLeft;

        static readonly Color BgDark   = Color.FromArgb(24, 26, 30);
        static readonly Color BgPanel  = Color.FromArgb(34, 37, 43);
        static readonly Color FgText   = Color.FromArgb(226, 230, 236);
        static readonly Color FgDim    = Color.FromArgb(150, 158, 170);
        static readonly Color AccentOk = Color.FromArgb(88, 214, 141);
        static readonly Color AccentNo = Color.FromArgb(236, 112, 99);
        static readonly Color FlashBg    = Color.FromArgb(120, 20, 20);
        static readonly Color FlashPanel = Color.FromArgb(150, 30, 30);

        public MainForm()
        {
            Text = "Bill Counter - MEI CashFlow SC (EBDS)";
            Size = new Size(940, 640);
            MinimumSize = new Size(880, 600);
            BackColor = BgDark;
            ForeColor = FgText;
            Font = new Font("Segoe UI", 9f);
            StartPosition = FormStartPosition.CenterScreen;

            BuildUi();
            RefreshPorts();
            UpdateDisplays();
        }

        void BuildUi()
        {
            // ---- top bar: port + connect ----
            var top = new Panel { Dock = DockStyle.Top, Height = 46, BackColor = BgPanel, Padding = new Padding(10, 8, 10, 8) };

            var lblPort = new Label { Text = "Port", AutoSize = true, Location = new Point(12, 14), ForeColor = FgDim };
            cboPort = new ComboBox { Location = new Point(50, 10), Width = 100, DropDownStyle = ComboBoxStyle.DropDownList,
                                     FlatStyle = FlatStyle.Flat, BackColor = BgDark, ForeColor = FgText };
            btnConnect = new Button { Text = "Connect", Location = new Point(160, 9), Width = 100, FlatStyle = FlatStyle.Flat,
                                      BackColor = Color.FromArgb(52, 120, 200), ForeColor = Color.White };
            btnConnect.FlatAppearance.BorderSize = 0;
            btnConnect.Click += (s, e) => { if (running) Stop(); else Start(); };

            var btnRescan = new Button { Text = "Rescan", Location = new Point(268, 9), Width = 70, FlatStyle = FlatStyle.Flat,
                                         BackColor = BgDark, ForeColor = FgText };
            btnRescan.FlatAppearance.BorderSize = 0;
            btnRescan.Click += (s, e) => RefreshPorts();

            chkReturn = new CheckBox { Text = "Return notes after counting (don't stack)", Location = new Point(360, 13),
                                       AutoSize = true, Checked = true, ForeColor = FgText };
            chkReturn.CheckedChanged += (s, e) =>
            {
                wantReturn = chkReturn.Checked;
                Log(wantReturn ? "Mode: RETURN, notes counted then handed back"
                               : "Mode: STACK, notes counted and kept (needs a cashbox!)");
            };

            chkSound = new CheckBox { Text = "Sound", Location = new Point(660, 13), AutoSize = true, Checked = true, ForeColor = FgText };

            top.Controls.AddRange(new Control[] { lblPort, cboPort, btnConnect, btnRescan, chkReturn, chkSound });

            // ---- left: total + denominations ----
            var left = new Panel { Dock = DockStyle.Left, Width = 430, BackColor = BgDark, Padding = new Padding(12) };

            var totalCaption = new Label { Text = "TOTAL COUNTED", Dock = DockStyle.Top, Height = 20, ForeColor = FgDim };
            lblTotal = new Label { Text = "$0.00", Dock = DockStyle.Top, Height = 72, ForeColor = AccentOk,
                                   Font = new Font("Segoe UI", 40f, FontStyle.Bold), TextAlign = ContentAlignment.MiddleLeft };

            lvDenoms = new ListView { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, GridLines = false,
                                      BackColor = BgPanel, ForeColor = FgText, BorderStyle = BorderStyle.None, HeaderStyle = ColumnHeaderStyle.Nonclickable };
            lvDenoms.Columns.Add("Denomination", 150);
            lvDenoms.Columns.Add("Count", 90, HorizontalAlignment.Right);
            lvDenoms.Columns.Add("Subtotal", 140, HorizontalAlignment.Right);
            for (int i = 1; i <= 7; i++)
                lvDenoms.Items.Add(new ListViewItem(new string[] { Denoms[i].ToString("C0", CultureInfo.GetCultureInfo("en-US")), "0", "$0.00" }));

            lblAlert = new Label { Dock = DockStyle.Top, Height = 36, Text = "", ForeColor = Color.White,
                                   Font = new Font("Segoe UI", 14f, FontStyle.Bold),
                                   TextAlign = ContentAlignment.MiddleCenter, BackColor = FlashPanel, Visible = false };

            left.Controls.Add(lvDenoms);
            left.Controls.Add(lblTotal);
            left.Controls.Add(totalCaption);
            left.Controls.Add(lblAlert);   // added last so it docks above the rest

            // ---- right: status, target, stats, log ----
            var right = new Panel { Dock = DockStyle.Fill, BackColor = BgDark, Padding = new Padding(12) };

            lblState   = new Label { Dock = DockStyle.Top, Height = 24, Text = "Disconnected", ForeColor = FgText, Font = new Font("Segoe UI", 11f, FontStyle.Bold) };
            lblCashbox = new Label { Dock = DockStyle.Top, Height = 20, Text = "Cashbox: --", ForeColor = FgDim };
            lblLink    = new Label { Dock = DockStyle.Top, Height = 20, Text = "Link: idle", ForeColor = FgDim };
            var sp1    = new Label { Dock = DockStyle.Top, Height = 10, Text = "" };

            var targetCaption = new Label { Text = "TARGET / CHANGE DUE", Dock = DockStyle.Top, Height = 20, ForeColor = FgDim };
            var targetRow = new Panel { Dock = DockStyle.Top, Height = 30 };
            txtTarget = new TextBox { Location = new Point(0, 3), Width = 110, BackColor = BgPanel, ForeColor = FgText, BorderStyle = BorderStyle.FixedSingle, Text = "" };
            var btnTarget = new Button { Text = "Set", Location = new Point(118, 2), Width = 60, FlatStyle = FlatStyle.Flat, BackColor = BgPanel, ForeColor = FgText };
            btnTarget.FlatAppearance.BorderSize = 0;
            btnTarget.Click += (s, e) => SetTarget();
            var btnClearTarget = new Button { Text = "Clear", Location = new Point(184, 2), Width = 60, FlatStyle = FlatStyle.Flat, BackColor = BgPanel, ForeColor = FgText };
            btnClearTarget.FlatAppearance.BorderSize = 0;
            btnClearTarget.Click += (s, e) => { target = 0m; txtTarget.Text = ""; UpdateDisplays(); };
            targetRow.Controls.AddRange(new Control[] { txtTarget, btnTarget, btnClearTarget });

            barTarget = new ProgressBar { Dock = DockStyle.Top, Height = 16, Maximum = 1000 };
            lblTargetInfo = new Label { Dock = DockStyle.Top, Height = 22, Text = "No target set", ForeColor = FgDim };
            var sp2 = new Label { Dock = DockStyle.Top, Height = 10, Text = "" };

            var statsCaption = new Label { Text = "SESSION", Dock = DockStyle.Top, Height = 20, ForeColor = FgDim };
            lblStats = new Label { Dock = DockStyle.Top, Height = 76, Text = "", ForeColor = FgText };
            var sp3 = new Label { Dock = DockStyle.Top, Height = 8, Text = "" };

            var logCaption = new Label { Text = "LOG", Dock = DockStyle.Top, Height = 20, ForeColor = FgDim };
            txtLog = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical,
                                   BackColor = BgPanel, ForeColor = FgText, BorderStyle = BorderStyle.None, Font = new Font("Consolas", 8.5f) };

            right.Controls.Add(txtLog);
            right.Controls.Add(logCaption);
            right.Controls.Add(sp3);
            right.Controls.Add(lblStats);
            right.Controls.Add(statsCaption);
            right.Controls.Add(sp2);
            right.Controls.Add(lblTargetInfo);
            right.Controls.Add(barTarget);
            right.Controls.Add(targetRow);
            right.Controls.Add(targetCaption);
            right.Controls.Add(sp1);
            right.Controls.Add(lblLink);
            right.Controls.Add(lblCashbox);
            right.Controls.Add(lblState);

            // ---- bottom buttons ----
            var bottom = new Panel { Dock = DockStyle.Bottom, Height = 52, BackColor = BgPanel, Padding = new Padding(10) };
            btnReset = new Button { Text = "Reset", Width = 110, Height = 32, Location = new Point(12, 10), FlatStyle = FlatStyle.Flat,
                                    BackColor = Color.FromArgb(150, 60, 60), ForeColor = Color.White };
            btnReset.FlatAppearance.BorderSize = 0;
            btnReset.Click += (s, e) => DoReset();

            btnSave = new Button { Text = "Save CSV", Width = 110, Height = 32, Location = new Point(130, 10), FlatStyle = FlatStyle.Flat,
                                   BackColor = Color.FromArgb(52, 120, 200), ForeColor = Color.White };
            btnSave.FlatAppearance.BorderSize = 0;
            btnSave.Click += (s, e) => DoSave();

            var btnCopy = new Button { Text = "Copy total", Width = 110, Height = 32, Location = new Point(248, 10), FlatStyle = FlatStyle.Flat,
                                       BackColor = BgDark, ForeColor = FgText };
            btnCopy.FlatAppearance.BorderSize = 0;
            btnCopy.Click += (s, e) => { try { Clipboard.SetText(total.ToString("0.00")); Log("Total copied to clipboard."); } catch { } };

            bottom.Controls.AddRange(new Control[] { btnReset, btnSave, btnCopy });

            pnlTop = top; pnlLeft = left; pnlRight = right; pnlBottom = bottom;

            Controls.Add(right);
            Controls.Add(left);
            Controls.Add(bottom);
            Controls.Add(top);
        }

        void RefreshPorts()
        {
            cboPort.Items.Clear();
            string[] names = SerialPort.GetPortNames();
            Array.Sort(names);
            foreach (var n in names) cboPort.Items.Add(n);
            if (cboPort.Items.Contains("COM4")) cboPort.SelectedItem = "COM4";
            else if (cboPort.Items.Count > 0) cboPort.SelectedIndex = 0;
        }

        // ------------------------------------------------------- serial loop --

        void Start()
        {
            if (cboPort.SelectedItem == null) { Log("No COM port selected."); return; }
            string name = cboPort.SelectedItem.ToString();
            try
            {
                port = new SerialPort(name, 9600, Parity.Even, 7, StopBits.One);
                port.Handshake = Handshake.None;
                port.DtrEnable = true;
                port.RtsEnable = true;
                port.ReadTimeout = 50;
                port.WriteTimeout = 500;
                port.Open();
            }
            catch (Exception ex) { Log("Open failed: " + ex.Message); return; }

            running = true;
            worker = new Thread(PollLoop);
            worker.IsBackground = true;
            worker.Start();

            btnConnect.Text = "Disconnect";
            cboPort.Enabled = false;
            Log("Connected on " + name + " @ 9600 7E1. Polling every 100ms.");
        }

        void Stop()
        {
            running = false;
            try { if (worker != null) worker.Join(800); } catch { }
            try { if (port != null && port.IsOpen) port.Close(); } catch { }
            btnConnect.Text = "Connect";
            cboPort.Enabled = true;
            SafeInvoke(() => { lblState.Text = "Disconnected"; lblState.ForeColor = FgText; });
            Log("Disconnected.");
        }

        byte[] ReadFrame(int timeoutMs)
        {
            var buf = new List<byte>();
            int expected = -1;
            var t0 = DateTime.Now;
            while ((DateTime.Now - t0).TotalMilliseconds < timeoutMs)
            {
                try
                {
                    if (port.BytesToRead > 0)
                    {
                        int b = port.ReadByte();
                        if (buf.Count == 0 && b != 0x02) continue;   // hunt for STX
                        buf.Add((byte)b);
                        if (buf.Count == 2)
                        {
                            expected = buf[1];
                            if (expected < 5 || expected > 250) { buf.Clear(); expected = -1; }
                        }
                        if (expected > 0 && buf.Count >= expected) return buf.ToArray();
                    }
                    else Thread.Sleep(1);
                }
                catch { break; }
            }
            return null;
        }

        void PollLoop()
        {
            int ack = 0;
            string pending = "none";
            bool countedThisNote = false;
            bool prevRejected = false, prevCheated = false, prevJammed = false, prevFull = false;

            while (running)
            {
                int d1 = 0x1C;                                   // escrow mode + all orientations
                if (pending == "stack") d1 |= 0x20;
                else if (pending == "return") d1 |= 0x40;

                byte[] tx = Ebds.BuildPoll(ack, 0x7F, d1, 0x00);
                byte[] rx = null;
                try { port.DiscardInBuffer(); port.Write(tx, 0, tx.Length); rx = ReadFrame(300); }
                catch { }

                pollCount++;

                if (rx == null || rx.Length < 11 || rx[rx.Length - 2] != 0x03 ||
                    Ebds.Checksum(rx, rx.Length) != rx[rx.Length - 1] || (rx[2] & 0xF0) != 0x20)
                {
                    if (rx != null) errorCount++;
                    Thread.Sleep(100);
                    continue;
                }

                replyCount++;
                var st = Ebds.Decode(rx);

                // ---- escrow decision ----
                if (st.Escrowed)
                {
                    if (!countedThisNote && st.NoteValue >= 1 && st.NoteValue <= 7)
                    {
                        countedThisNote = true;
                        int idx = st.NoteValue;
                        bool keep = !wantReturn;
                        SafeInvoke(() => Credit(idx, keep));
                    }
                    if (pending == "none") pending = wantReturn ? "return" : "stack";
                }
                else
                {
                    pending = "none";
                    if (st.Idling && !st.Returned && !st.Stacked) countedThisNote = false;
                }

                // Edge-trigger these: the status bits stay set for several polls,
                // so testing the level would fire the alert repeatedly per note.
                if (st.Rejected && !prevRejected) SafeInvoke(() => OnRejected("note not recognised"));
                if (st.Cheated && !prevCheated) SafeInvoke(() => OnRejected("cheat attempt detected"));
                if (st.Jammed && !prevJammed) SafeInvoke(() => { Log("*** JAMMED ***"); StartFlash(); });
                if (st.StackerFull && !prevFull) SafeInvoke(() => Log("*** STACKER FULL ***"));

                prevRejected = st.Rejected;
                prevCheated = st.Cheated;
                prevJammed = st.Jammed;
                prevFull = st.StackerFull;

                SafeInvoke(() => UpdateStatus(st));

                ack = 1 - ack;
                Thread.Sleep(100);
            }
        }

        void SafeInvoke(Action a)
        {
            try { if (IsHandleCreated && !IsDisposed) BeginInvoke(a); } catch { }
        }

        // ------------------------------------------------------------- logic --

        void Credit(int idx, bool kept)
        {
            counts[idx]++;
            total += Denoms[idx];
            accepted++;
            history.Add(new NoteEvent { When = DateTime.Now, Index = idx, Value = Denoms[idx], Kept = kept });

            Log(string.Format("+{0}  ({1})  →  total {2}",
                Denoms[idx].ToString("C0", CultureInfo.GetCultureInfo("en-US")),
                kept ? "kept" : "returned",
                total.ToString("C2", CultureInfo.GetCultureInfo("en-US"))));

            if (chkSound.Checked) { try { System.Media.SystemSounds.Asterisk.Play(); } catch { } }

            // brief white flash on the total, then back to green
            lblTotal.ForeColor = Color.White;
            var t = new System.Windows.Forms.Timer();
            t.Interval = 140;
            t.Tick += (s, e) => { lblTotal.ForeColor = AccentOk; t.Stop(); t.Dispose(); };
            t.Start();

            UpdateDisplays();
        }

        // ---- rejection alert: red flash + error beep + banner ----
        void OnRejected(string reason)
        {
            rejected++;
            Log("REJECTED - " + reason);

            lblAlert.Text = "!!  BILL NOT READ  !!";
            lblAlert.Visible = true;

            if (chkSound.Checked)
            {
                // two descending tones, clearly different from the credit chime
                var th = new Thread(delegate()
                {
                    try { Console.Beep(320, 160); Thread.Sleep(60); Console.Beep(220, 260); } catch { }
                });
                th.IsBackground = true;
                th.Start();
            }

            StartFlash();
            UpdateDisplays();
        }

        void StartFlash()
        {
            flashesLeft = 6;                     // three on/off pairs
            if (flashTimer == null)
            {
                flashTimer = new System.Windows.Forms.Timer();
                flashTimer.Interval = 120;
                flashTimer.Tick += delegate
                {
                    SetFlashColors((flashesLeft % 2) == 0);
                    flashesLeft--;
                    if (flashesLeft < 0)
                    {
                        flashTimer.Stop();
                        SetFlashColors(false);
                        lblAlert.Visible = false;
                    }
                };
            }
            flashTimer.Stop();
            flashTimer.Start();
        }

        void SetFlashColors(bool alarm)
        {
            BackColor = alarm ? FlashBg : BgDark;
            if (pnlLeft   != null) pnlLeft.BackColor   = alarm ? FlashBg    : BgDark;
            if (pnlRight  != null) pnlRight.BackColor  = alarm ? FlashBg    : BgDark;
            if (pnlTop    != null) pnlTop.BackColor    = alarm ? FlashPanel : BgPanel;
            if (pnlBottom != null) pnlBottom.BackColor = alarm ? FlashPanel : BgPanel;
        }

        void UpdateStatus(AcceptorStatus st)
        {
            lblState.Text = st.Summary();
            lblState.ForeColor = (st.Jammed || st.Failure) ? AccentNo : (st.Idling ? AccentOk : FgText);
            lblCashbox.Text = "Cashbox: " + (st.CashboxPresent ? "present" : "NOT PRESENT")
                            + "   |   model 0x" + st.Model.ToString("X2") + " rev 0x" + st.Revision.ToString("X2");
            lblCashbox.ForeColor = st.CashboxPresent ? FgDim : AccentNo;
            lblLink.Text = string.Format("Link: {0} polls | {1} replies | {2} errors", pollCount, replyCount, errorCount);
        }

        void UpdateDisplays()
        {
            var us = CultureInfo.GetCultureInfo("en-US");
            lblTotal.Text = total.ToString("C2", us);

            for (int i = 1; i <= 7; i++)
            {
                var it = lvDenoms.Items[i - 1];
                it.SubItems[1].Text = counts[i].ToString();
                it.SubItems[2].Text = (counts[i] * Denoms[i]).ToString("C2", us);
                it.ForeColor = counts[i] > 0 ? FgText : FgDim;
            }

            double mins = (DateTime.Now - sessionStart).TotalMinutes;
            double rate = mins > 0.01 ? accepted / mins : 0;
            int attempts = accepted + rejected;
            double acceptRate = attempts > 0 ? (100.0 * accepted / attempts) : 0;
            decimal largest = 0m;
            foreach (var h in history) if (h.Value > largest) largest = h.Value;

            lblStats.Text =
                "Notes counted : " + accepted + "\r\n" +
                "Rejected      : " + rejected + "   (" + acceptRate.ToString("0.0") + "% accepted)\r\n" +
                "Rate          : " + rate.ToString("0.0") + " notes/min\r\n" +
                "Largest note  : " + (largest > 0 ? largest.ToString("C0", us) : "--");

            if (target > 0m)
            {
                decimal remaining = target - total;
                double pct = (double)(total / target);
                if (pct > 1) pct = 1;
                barTarget.Value = (int)(pct * 1000);
                if (remaining > 0m)
                {
                    lblTargetInfo.Text = "Target " + target.ToString("C2", us) + "  |  still need " + remaining.ToString("C2", us);
                    lblTargetInfo.ForeColor = FgText;
                }
                else
                {
                    lblTargetInfo.Text = "Target met!  Change due: " + (-remaining).ToString("C2", us);
                    lblTargetInfo.ForeColor = AccentOk;
                }
            }
            else
            {
                barTarget.Value = 0;
                lblTargetInfo.Text = "No target set";
                lblTargetInfo.ForeColor = FgDim;
            }
        }

        void SetTarget()
        {
            decimal v;
            string raw = txtTarget.Text.Replace("$", "").Trim();
            if (decimal.TryParse(raw, NumberStyles.Any, CultureInfo.InvariantCulture, out v) && v > 0m)
            {
                target = v;
                Log("Target set to " + target.ToString("C2", CultureInfo.GetCultureInfo("en-US")));
                UpdateDisplays();
            }
            else Log("Could not read that target amount.");
        }

        void DoReset()
        {
            if (accepted > 0 &&
                MessageBox.Show("Clear the running total and all counts?", "Reset",
                                MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
            for (int i = 0; i < counts.Length; i++) counts[i] = 0;
            total = 0m; accepted = 0; rejected = 0;
            history.Clear();
            sessionStart = DateTime.Now;
            Log("--- reset ---");
            UpdateDisplays();
        }

        void DoSave()
        {
            using (var dlg = new SaveFileDialog())
            {
                dlg.Filter = "CSV file (*.csv)|*.csv|All files (*.*)|*.*";
                dlg.FileName = "bill-count-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".csv";
                if (dlg.ShowDialog() != DialogResult.OK) return;
                try
                {
                    var sb = new StringBuilder();
                    sb.AppendLine("# Bill Counter session");
                    sb.AppendLine("# started," + sessionStart.ToString("yyyy-MM-dd HH:mm:ss"));
                    sb.AppendLine("# saved," + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
                    sb.AppendLine();
                    sb.AppendLine("denomination,count,subtotal");
                    for (int i = 1; i <= 7; i++)
                        sb.AppendLine(Denoms[i].ToString("0") + "," + counts[i] + "," + (counts[i] * Denoms[i]).ToString("0.00"));
                    sb.AppendLine("TOTAL,," + total.ToString("0.00"));
                    sb.AppendLine();
                    sb.AppendLine("timestamp,denomination,kept");
                    foreach (var h in history)
                        sb.AppendLine(h.When.ToString("yyyy-MM-dd HH:mm:ss") + "," + h.Value.ToString("0.00") + "," + (h.Kept ? "stacked" : "returned"));
                    File.WriteAllText(dlg.FileName, sb.ToString(), Encoding.UTF8);
                    Log("Saved: " + dlg.FileName);
                }
                catch (Exception ex) { Log("Save failed: " + ex.Message); }
            }
        }

        void Log(string msg)
        {
            string line = DateTime.Now.ToString("HH:mm:ss") + "  " + msg + "\r\n";
            if (txtLog.TextLength > 60000) txtLog.Text = txtLog.Text.Substring(30000);
            txtLog.AppendText(line);
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            running = false;
            try { if (port != null && port.IsOpen) port.Close(); } catch { }
            base.OnFormClosing(e);
        }
    }

    static class Program
    {
        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }
}
