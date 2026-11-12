// DEMO-ONLY SOURCE. Part of the Demo mode of the console (-Gui -Demo): a synthetic tenant and a fake Microsoft Graph, compiled together with the engine
// in Demo mode and by the tests ONLY. It is never loaded by the command line modes and never talks to the network. Single source of truth (the tests compile it from here).
// =============================================================================
//  TeamsTransfer - synthetic tenant generator (tests, demo mode, volume tests)
// -----------------------------------------------------------------------------
//  WHY: the engine, the preview and the sizing (Assess) must be exercised on tenants that look like production without any real data:
//  deterministic (same seed = same tenant, byte for byte), parameterizable from "5 users for a screenshot" to "1 million messages for a
//  volume test", and rich in the awkward cases the export / import / preview meet in real life (departed and federated authors, edits,
//  deletions, reactions, mentions, inline images, the same file posted in several chats, system events, cards, emoji, right-to-left text,
//  HTML that tries to run a script, 27 KB messages, files whose link is broken).
//
//  USAGE:   var tenant = SyntheticTenant.Tiny(seed);                          // or Small(), Demo(), Volume(1000000)
//           var r = SyntheticTenant.Build(SyntheticProfile.Small());          // r.Tenant + r.Stats (counts, timings)
//           var transport = new FakeGraphTransport(tenant);
//  Everything is fictitious: names are common French first / last names, domains are contoso.com and fabrikam.com.
//  Times are UTC; the work-day shape (weekdays, 08:00-18:00 with a lunch dip, conversations in bursts) is the generator's, not Teams'.
//
//  TEXT: ordinary message bodies are not stored, they are rendered from a seed by FakeText.Render (see the memory notes in the model).
// =============================================================================
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

namespace TeamsTransfer.Testing
{
    /// <summary>Renders the body of an ordinary message from (seed, language): same inputs, same HTML, nothing stored.</summary>
    public static class FakeText
    {
        static readonly string[] EnOpen = { "Hi all,", "Hello,", "Thanks for the update.", "Quick note:", "FYI,", "Good news,", "Following up on this morning,", "", "", "" };
        static readonly string[] EnSubj = { "The file", "The meeting", "The customer", "The team", "The schedule", "The mockup", "The budget", "The support desk", "Version 2", "The vendor", "The report", "The demo", "The ticket", "The delivery", "The contract", "The roadmap" };
        static readonly string[] EnPred = { "is ready for review", "will slip to next week", "is still waiting for approval", "was updated this morning", "needs a quick sync", "is progressing despite the delays", "must go out before Thursday", "raises a security question", "is blocked at the supplier", "was approved last night", "depends on the management decision", "is going better than expected" };
        static readonly string[] EnTail = { ".", ".", ".", " - what do you think?", " (see the shared document).", ", I'm on it.", ", shall we talk tomorrow?", ". Thanks in advance!", ": I need your opinion." };

        public static string Render(int seed, string lang)
        {
            var r = new FakeRng(seed);
            // English only (the lang argument is kept for the callers)
            var open = EnOpen; var subj = EnSubj; var pred = EnPred; var tail = EnTail;
            var sb = new StringBuilder(160);
            sb.Append("<p>");
            string o = open[r.Next(open.Length)];
            if (o.Length > 0) sb.Append(o).Append(' ');
            int sentences = 1 + (r.Next(10) < 3 ? 1 : 0) + (r.Next(10) < 1 ? 1 : 0);
            for (int i = 0; i < sentences; i++)
            {
                if (i > 0) sb.Append(' ');
                sb.Append(subj[r.Next(subj.Length)]).Append(' ').Append(pred[r.Next(pred.Length)]).Append(tail[r.Next(tail.Length)]);
            }
            sb.Append("</p>");
            return sb.ToString();
        }

        public static string Plain(int seed, string lang) { return System.Text.RegularExpressions.Regex.Replace(Render(seed, lang), "<[^>]+>", ""); }
    }

    /// <summary>A tiny PNG writer: deterministic small pictures (a gradient, a bar chart) for inline images, without System.Drawing.</summary>
    public static class FakePng
    {
        static uint[] _crc;
        static uint Crc(byte[] data, int off, int len, uint crc)
        {
            if (_crc == null)
            {
                var t = new uint[256];
                for (uint n = 0; n < 256; n++) { uint c = n; for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1; t[n] = c; }
                _crc = t;
            }
            crc ^= 0xFFFFFFFFu;
            for (int i = 0; i < len; i++) crc = _crc[(crc ^ data[off + i]) & 0xFF] ^ (crc >> 8);
            return crc ^ 0xFFFFFFFFu;
        }

        static void Chunk(Stream s, string type, byte[] data)
        {
            var len = new byte[] { (byte)(data.Length >> 24), (byte)(data.Length >> 16), (byte)(data.Length >> 8), (byte)data.Length };
            s.Write(len, 0, 4);
            var td = new byte[4 + data.Length];
            Encoding.ASCII.GetBytes(type).CopyTo(td, 0); data.CopyTo(td, 4);
            s.Write(td, 0, td.Length);
            uint c = Crc(td, 0, td.Length, 0);
            s.Write(new byte[] { (byte)(c >> 24), (byte)(c >> 16), (byte)(c >> 8), (byte)c }, 0, 4);
        }

        /// <summary>rgb(x, y) -> 0xRRGGBB.</summary>
        public static byte[] Make(int w, int h, Func<int, int, int> rgb)
        {
            var raw = new byte[h * (1 + w * 3)];
            int p = 0;
            for (int y = 0; y < h; y++)
            {
                raw[p++] = 0;
                for (int x = 0; x < w; x++) { int c = rgb(x, y); raw[p++] = (byte)(c >> 16); raw[p++] = (byte)(c >> 8); raw[p++] = (byte)c; }
            }
            using (var ms = new MemoryStream())
            {
                ms.Write(new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }, 0, 8);
                Chunk(ms, "IHDR", new byte[] { (byte)(w >> 24), (byte)(w >> 16), (byte)(w >> 8), (byte)w, (byte)(h >> 24), (byte)(h >> 16), (byte)(h >> 8), (byte)h, 8, 2, 0, 0, 0 });
                using (var z = new MemoryStream())
                {
                    using (var zs = new ZLibStream(z, CompressionLevel.Optimal, true)) zs.Write(raw, 0, raw.Length);
                    Chunk(ms, "IDAT", z.ToArray());
                }
                Chunk(ms, "IEND", new byte[0]);
                return ms.ToArray();
            }
        }

        public static byte[] Gradient(int seed, int w = 96, int h = 64)
        {
            int a = (int)((uint)seed * 2654435761u % 200) + 30, b = (int)((uint)seed * 40503u % 200) + 30;
            return Make(w, h, (x, y) => ((a * x / w) << 16) | ((b * y / h) << 8) | (255 - (a + b) / 2));
        }

        /// <summary>A small bar chart on a light background: readable in a screenshot.</summary>
        public static byte[] Chart(int seed, int w = 320, int h = 180)
        {
            var r = new FakeRng(seed);
            int bars = 6; var hs = new int[bars];
            for (int i = 0; i < bars; i++) hs[i] = 30 + r.Next(h - 70);
            return Make(w, h, (x, y) =>
            {
                if (y > h - 20) return 0x374151;                        // axis
                int slot = (x - 16) / ((w - 32) / bars);
                if (slot >= 0 && slot < bars && ((x - 16) % ((w - 32) / bars)) < ((w - 32) / bars) - 10 && y > h - 20 - hs[slot])
                    return slot % 2 == 0 ? 0x4F6BED : 0x7F9CF5;
                return (y % 36 == 0) ? 0xE5E7EB : 0xF9FAFB;             // grid lines
            });
        }
    }

    public sealed class SyntheticStats
    {
        public int Seed, Users, DepartedUsers, ExternalUsers, Chats, OneOnOneChats, GroupChats, MeetingChats, Teams, Channels, DriveFiles, SharedFileCopies;
        public long Messages, ChatMessages, ChannelMessages, Replies, Edited, Deleted, Reactions, WithImages, WithFiles, FileBytes;
        public double GenerationSeconds;
        public string Profile;
    }

    public sealed class SyntheticResult
    {
        public FakeTenant Tenant;
        public SyntheticStats Stats;
    }

    /// <summary>All the dials of the generator. Use the presets, then change what the test needs.</summary>
    public sealed class SyntheticProfile
    {
        public string Name = "custom";
        public int Seed = 1;
        public string Language = "en";
        public string Domain = "contoso.com";
        public int Users = 5;
        public double DepartedPct = 0.10, ExternalPct = 0.05;
        public DateTimeOffset EndUtc = new DateTimeOffset(2026, 11, 2, 17, 0, 0, TimeSpan.Zero);
        public double Years = 1.0;
        // chats per user (the number of chats a user belongs to, by kind)
        public double OneOnOnePerUser = 2, GroupChatsPerUser = 1, MeetingChatsPerUser = 0.3;
        public int GroupMinSize = 3, GroupMaxSize = 8, MeetingMaxMembers = 300;
        public double MessagesPerChatMedian = 25, MessagesPerChatSigma = 1.0;
        public int MaxMessagesPerChat = 5000;
        // message features, as a fraction of messages
        public double EditPct = 0.04, DeletePct = 0.02, ReactionPct = 0.08, MentionPct = 0.04, InlineImagePct = 0.015, FilePct = 0.03, CardPct = 0.004, TextBodyPct = 0.03;
        // teams
        public int Teams = 1, ChannelsPerTeam = 3, TeamMembers = 0;
        public double PrivateChannelPct = 0.25, SharedChannelPct = 0.15;
        public double ThreadsPerChannelMedian = 15, RepliesPerThreadMean = 2.5;
        // files
        public double FileSizeMedianBytes = 250 * 1024, FileSizeSigma = 1.7;
        public long MaxFileBytes = 2L * 1024 * 1024 * 1024;
        public int PopularFiles = 4;
        public double PopularFilePct = 0.20, ForwardedFilePct = 0.10;
        public double HugeFilePct = 0.0005;
        public bool EdgeCases = true;
        // volume: a few "heavy" users belong to a large share of the chats; TargetMessages makes the generator add chats until reached
        public int HeavyUsers = 0;
        public double HeavyUserChatShare = 0;
        public long TargetMessages = 0;

        public static SyntheticProfile Tiny(int seed = 1)
        {
            return new SyntheticProfile { Name = "Tiny", Seed = seed, Users = 5, DepartedPct = 0.2, ExternalPct = 0.2, Years = 0.25, OneOnOnePerUser = 1.6, GroupChatsPerUser = 1.5, MeetingChatsPerUser = 0.6, GroupMinSize = 3, GroupMaxSize = 4,
                MessagesPerChatMedian = 14, MessagesPerChatSigma = 0.6, Teams = 1, ChannelsPerTeam = 3, ThreadsPerChannelMedian = 5, RepliesPerThreadMean = 2, EditPct = 0.08, DeletePct = 0.05, ReactionPct = 0.2, MentionPct = 0.08, InlineImagePct = 0.04, FilePct = 0.06, PopularFiles = 2 };
        }

        public static SyntheticProfile Small(int seed = 1)
        {
            return new SyntheticProfile { Name = "Small", Seed = seed, Users = 200, DepartedPct = 0.08, ExternalPct = 0.04, Years = 2, OneOnOnePerUser = 6, GroupChatsPerUser = 3, MeetingChatsPerUser = 1.5, MessagesPerChatMedian = 30, MessagesPerChatSigma = 1.1,
                Teams = 8, ChannelsPerTeam = 4, ThreadsPerChannelMedian = 40, HeavyUsers = 2, HeavyUserChatShare = 0.15 };
        }

        /// <summary>
        /// Volume test tenant: `targetMessages` messages (chats first, then teams), with `heavyUsers` users that belong to `heavyShare` of all the
        /// chats (a "large user" for getAllMessages paging tests). Parameterize freely: users, years, messages per chat...
        /// </summary>
        public static SyntheticProfile Volume(long targetMessages = 1000000, int seed = 1, int heavyUsers = 2, double heavyShare = 0.5)
        {
            int users = (int)Math.Max(200, Math.Min(20000, targetMessages / 2500));
            return new SyntheticProfile
            {
                Name = "Volume", Seed = seed, Users = users, DepartedPct = 0.05, ExternalPct = 0.02, Years = 5, OneOnOnePerUser = 3, GroupChatsPerUser = 1, MeetingChatsPerUser = 0.3,
                MessagesPerChatMedian = 120, MessagesPerChatSigma = 1.2, MaxMessagesPerChat = 20000, Teams = Math.Max(2, users / 40), ChannelsPerTeam = 5, ThreadsPerChannelMedian = 120, RepliesPerThreadMean = 3,
                HeavyUsers = heavyUsers, HeavyUserChatShare = heavyShare, TargetMessages = targetMessages, EdgeCases = false, FilePct = 0.01, InlineImagePct = 0.005
            };
        }
    }

    /// <summary>Entry points: presets and the generic builder.</summary>
    public static class SyntheticTenant
    {
        public static FakeTenant Tiny(int seed = 1) { return Build(SyntheticProfile.Tiny(seed)).Tenant; }
        public static FakeTenant Small(int seed = 1) { return Build(SyntheticProfile.Small(seed)).Tenant; }
        public static FakeTenant Volume(long targetMessages = 1000000, int seed = 1) { return Build(SyntheticProfile.Volume(targetMessages, seed)).Tenant; }
        /// <summary>Handwritten French conversations for screenshots of the Teams-like preview and client demos.</summary>
        public static FakeTenant Demo() { return SyntheticDemo.Build(); }
        public static SyntheticResult Build(SyntheticProfile profile) { return new SyntheticGenerator(profile).Run(); }

        /// <summary>SHA-256 over every observable fact of the tenant (users, chats, members, messages, files). Same seed = same value.</summary>
        public static string Fingerprint(FakeTenant t)
        {
            using (var h = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
            {
                Action<string> s = x => h.AppendData(Encoding.UTF8.GetBytes((x ?? "~") + "\u0001"));
                Action<long> l = x => h.AppendData(BitConverter.GetBytes(x));
                foreach (var u in t.Users) { s(u.Id); s(u.Upn); s(u.DisplayName); s(u.Deleted ? "D" : "A"); s(u.External ? "E" : "I"); l(u.DeletedMs); }
                Action<FakeThread> thread = th =>
                {
                    s(th.Id); l(th.CreatedMs); s(th.MigrationMode);
                    foreach (var m in th.Messages)
                    {
                        l(m.CreatedMs); l(m.ModifiedMs); l(m.AuthorOrd); l(m.Seed); l(m.Flags);
                        var x = m.X;
                        if (x == null) continue;
                        s(x.Body); l(x.ReplyTo); l(x.EditedMs); l(x.DeletedMs); s(x.Subject); s(x.EventDetailJson);
                        if (x.Reactions != null) foreach (var r in x.Reactions) { s(r.Type); l(r.UserOrd); l(r.CreatedMs); }
                        if (x.Attachments != null) foreach (var a in x.Attachments) { s(a.Id); s(a.ContentUrl); s(a.Name); s(a.Content); }
                        if (x.Hosted != null) foreach (var hc in x.Hosted) { s(hc.Id); l(hc.Bytes.Length); }
                        if (x.Mentions != null) foreach (var mn in x.Mentions) { l(mn.UserOrd); s(mn.Text); }
                    }
                };
                foreach (var c in t.Chats) { thread(c); s(c.Topic); s(c.TypeName); foreach (var m in c.Members) { l(m.UserOrd); l(m.VisibleHistoryStartMs); } }
                foreach (var tm in t.Teams)
                {
                    s(tm.Id); s(tm.DisplayName); foreach (var m in tm.Members) l(m.UserOrd);
                    foreach (var ch in tm.Channels) { thread(ch); s(ch.DisplayName); s(ch.TypeName); foreach (var m in ch.Members) l(m.UserOrd); }
                }
                foreach (var kv in t.ItemsById.OrderBy(k => k.Key, StringComparer.Ordinal)) { var it = kv.Value; s(it.Id); s(it.Name); l(it.Size); l((long)it.Seed); s(it.WebUrl); s(it.FolderPath); }
                return Convert.ToHexString(h.GetHashAndReset());
            }
        }
    }

    sealed class SyntheticGenerator
    {
        const long Day = 86400000L;
        readonly SyntheticProfile p;
        readonly FakeRng rng;
        FakeTenant t;
        readonly SyntheticStats st = new SyntheticStats();
        long startMs, endMs, day0;
        double[] dayPrefix, hourCdf;
        FakeUser[] users, internalUsers;
        int activeCount, depCount, extCount;
        readonly List<byte[]> images = new List<byte[]>();
        readonly List<int[]> imageSize = new List<int[]>();
        sealed class Popular { public string Name; public long Size; public ulong Seed; }
        readonly List<Popular> popular = new List<Popular>();
        readonly List<FakeDriveItem> recentFiles = new List<FakeDriveItem>();
        long fileCounter, permCounter;

        static readonly string[] First = { "Camille", "Julien", "Sophie", "Marc", "Léa", "Nicolas", "Emma", "Thomas", "Chloé", "Antoine", "Manon", "Lucas", "Laura", "Hugo", "Inès", "Maxime", "Clara", "Alexandre", "Pauline", "Romain", "Julie", "Benoît", "Marion", "Pierre", "Sarah", "Mathieu", "Audrey", "Quentin", "Elodie", "Florian", "Céline", "Damien", "Margaux", "Kevin", "Anna", "Yann", "Lucie", "Adrien", "Noémie", "Guillaume" };
        static readonly string[] Last = { "Martin", "Lefèvre", "Bernard", "Dubois", "Moreau", "Petit", "Durand", "Leroy", "Roux", "Fournier", "Girard", "Bonnet", "Lambert", "Fontaine", "Rousseau", "Vincent", "Muller", "Faure", "André", "Mercier", "Blanc", "Guerin", "Boyer", "Garnier", "Chevalier", "François", "Legrand", "Gauthier", "Perrin", "Robin", "Clement", "Morin", "Nicolas", "Henry", "Masson", "Marchand", "Duval", "Denis", "Dumont", "Lemaire" };
        static readonly string[] TeamNames = { "Product Team", "Project Moon", "Sales Management", "Customer Support", "Infrastructure", "Human Resources", "Marketing", "Finance", "Quality", "Legal" };
        static readonly string[] ChannelNames = { "Announcements", "Engineering", "Design", "Support", "Ideas", "Planning", "Customer feedback", "Watch", "Purchasing", "Training", "Partners" };
        static readonly string[] Topics = { "Project coordination", "Budget check-in", "Committee preparation", "Production incident", "Sprint review", "Offer launch", "Office move", "Supplier follow-up" };
        static readonly string[] Reacts = { "like", "like", "like", "heart", "laugh", "surprised", "sad", "angry" };
        static readonly string[] FileBases = { "Minutes", "Budget", "Presentation", "Contract", "Photo", "Archive", "Notes", "Export", "Schedule", "Mockup" };
        static readonly string[] FileExts = { ".docx", ".xlsx", ".pptx", ".pdf", ".jpg", ".zip", ".txt", ".csv" };

        public SyntheticGenerator(SyntheticProfile profile) { p = profile; rng = new FakeRng(p.Seed * 104729L + 3); }

        static string Ascii(string s)
        {
            var sb = new StringBuilder();
            foreach (char c in s.Normalize(NormalizationForm.FormD)) if (c < 128 && char.IsLetterOrDigit(c)) sb.Append(char.ToLowerInvariant(c));
            return sb.ToString();
        }

        public SyntheticResult Run()
        {
            var sw = Stopwatch.StartNew();
            t = new FakeTenant(p.Seed, p.Domain);
            endMs = FakeTime.ToMs(p.EndUtc);
            startMs = endMs - (long)(p.Years * 365.25 * Day);
            var clockBase = p.EndUtc.AddHours(1); var csw = Stopwatch.StartNew();
            t.Clock = () => clockBase + csw.Elapsed;
            BuildCalendar();
            CreateUsers();
            CreatePools();
            CreateBaselineChats();
            CreateTeams();
            if (p.EdgeCases && users.Length >= 4) SyntheticEdgeCases.Add(t, users, internalUsers, activeCount, depCount, extCount, startMs, p.Language, st, images);
            if (p.TargetMessages > 0) FillToTarget();
            FinishStats(sw);
            return new SyntheticResult { Tenant = t, Stats = st };
        }

        void FinishStats(Stopwatch sw)
        {
            st.Seed = p.Seed; st.Profile = p.Name; st.Users = t.Users.Count; st.DepartedUsers = depCount; st.ExternalUsers = extCount;
            st.Chats = t.Chats.Count; st.Teams = t.Teams.Count; st.Channels = t.Teams.Sum(x => x.Channels.Count);
            st.OneOnOneChats = t.Chats.Count(c => c.ChatType == FakeChatType.OneOnOne); st.GroupChats = t.Chats.Count(c => c.ChatType == FakeChatType.Group); st.MeetingChats = t.Chats.Count(c => c.ChatType == FakeChatType.Meeting);
            st.Messages = t.MessageCount;
            st.DriveFiles = t.ItemsById.Values.Count(i => !i.IsFolder);
            st.GenerationSeconds = sw.Elapsed.TotalSeconds;
        }

        // ---- calendar: working days, working hours
        void BuildCalendar()
        {
            day0 = (startMs / Day) * Day;
            int days = (int)((endMs - day0) / Day) + 2;
            dayPrefix = new double[days + 1];
            for (int i = 0; i < days; i++)
            {
                long dayNumber = day0 / Day + i;
                int dow = (int)((dayNumber + 4) % 7);        // 1970-01-01 was a Thursday; 0 = Sunday
                double w = dow == 0 ? 0.04 : dow == 6 ? 0.06 : 1.0;
                dayPrefix[i + 1] = dayPrefix[i] + w;
            }
            double[] hw = { .1, .1, .1, .1, .1, .1, .2, .6, 2, 4, 5, 4.5, 2.5, 3, 4.5, 4.5, 4, 3, 1.5, .8, .5, .3, .2, .1 };
            hourCdf = new double[24]; double sum = hw.Sum(), acc = 0;
            for (int i = 0; i < 24; i++) { acc += hw[i] / sum; hourCdf[i] = acc; }
        }

        long SampleTime(long w0, long w1)
        {
            if (w1 <= w0) return w0;
            int d0 = (int)((w0 - day0) / Day), d1 = Math.Min((int)((w1 - day0) / Day), dayPrefix.Length - 2);
            double a = dayPrefix[d0], b = dayPrefix[d1 + 1];
            double u = a + rng.NextDouble() * (b - a);
            int lo = d0, hi = d1;
            while (lo < hi) { int mid = (lo + hi) >> 1; if (dayPrefix[mid + 1] > u) hi = mid; else lo = mid + 1; }
            double hu = rng.NextDouble(); int hour = 0;
            while (hour < 23 && hourCdf[hour] < hu) hour++;
            long tm = day0 + lo * Day + hour * 3600000L + rng.NextLong(3600000L);
            return tm < w0 ? w0 : tm > w1 ? w1 : tm;
        }

        long[] GenTimes(int n, long w0, long w1)
        {
            var times = new long[n]; int i = 0;
            while (i < n)
            {
                long s = SampleTime(w0, w1); int len = 1 + rng.Next(8);
                for (int k = 0; k < len && i < n; k++)
                {
                    times[i++] = s;
                    long gap = (long)(-Math.Log(Math.Max(rng.NextDouble(), 1e-9)) * 75000);
                    s += Math.Min(gap, 20 * 60000L);
                    if (s > w1) s = w1;
                }
            }
            Array.Sort(times);
            return times;
        }

        // ---- users
        void CreateUsers()
        {
            int n = Math.Max(2, p.Users);
            extCount = (int)Math.Round(n * p.ExternalPct); depCount = (int)Math.Round(n * p.DepartedPct);
            if (n >= 5 && p.ExternalPct > 0 && extCount == 0) extCount = 1;
            if (n >= 5 && p.DepartedPct > 0 && depCount == 0) depCount = 1;
            while (extCount + depCount > n - 2) { if (depCount > 0) depCount--; else extCount--; }
            activeCount = n - extCount - depCount;
            users = new FakeUser[n];
            var used = new Dictionary<string, int>();
            for (int i = 0; i < n; i++)
            {
                string fn = First[i % First.Length], ln = Last[(i + i / First.Length * 3) % Last.Length];
                if (i > 4 && i < First.Length * Last.Length) { fn = First[(i * 7 + i / 40) % First.Length]; ln = Last[(i * 3 + i / 17) % Last.Length]; }
                bool ext = i >= n - extCount, dep = !ext && i >= activeCount;
                string local = Ascii(fn) + "." + Ascii(ln); int dup;
                string key = local + (ext ? "@f" : "");
                used.TryGetValue(key, out dup); used[key] = dup + 1;
                if (dup > 0) local += dup;
                var u = t.AddUser(local + "@" + (ext ? "fabrikam.com" : p.Domain), fn + " " + ln, dep, ext);
                u.JobTitle = i % 5 == 0 ? "Project manager" : i % 5 == 1 ? "Developer" : i % 5 == 2 ? "Designer" : i % 5 == 3 ? "Salesperson" : "Analyst";
                if (dep) u.DeletedMs = endMs - (long)(rng.NextDouble() * 0.4 * (endMs - startMs));
                users[i] = u;
            }
            internalUsers = users.Where(u => !u.External).ToArray();
        }

        void CreatePools()
        {
            for (int i = 0; i < 6; i++) { images.Add(i % 2 == 0 ? FakePng.Chart(p.Seed * 31 + i) : FakePng.Gradient(p.Seed * 17 + i)); imageSize.Add(i % 2 == 0 ? new[] { 320, 180 } : new[] { 96, 64 }); }
            for (int i = 0; i < p.PopularFiles; i++)
                popular.Add(new Popular { Name = "Note_interne_" + (i + 1) + FileExts[i % 4], Size = (long)Math.Max(2048, rng.LogNormal(p.FileSizeMedianBytes, 1.0)), Seed = (ulong)rng.NextU64() });
        }

        // ---- chats
        FakeUser[] PickMembers(int k, bool heavy)
        {
            var chosen = new List<FakeUser>(k);
            if (heavy && p.HeavyUsers > 0 && rng.Chance(p.HeavyUserChatShare)) chosen.Add(users[rng.Next(Math.Min(p.HeavyUsers, users.Length))]);
            int guard = 0;
            while (chosen.Count < k && guard++ < k * 20)
            {
                var u = users[rng.Next(users.Length)];
                if (!chosen.Contains(u)) chosen.Add(u);
            }
            return chosen.ToArray();
        }

        void CreateBaselineChats()
        {
            int one = (int)Math.Round(users.Length * p.OneOnOnePerUser / 2.0);
            double avgGroup = (p.GroupMinSize + p.GroupMaxSize) / 2.0;
            int groups = (int)Math.Round(users.Length * p.GroupChatsPerUser / avgGroup);
            int meetings = (int)Math.Round(users.Length * p.MeetingChatsPerUser / 8.0);
            if (p.MeetingChatsPerUser > 0 && meetings == 0) meetings = 1;
            for (int i = 0; i < one; i++) MakeChat(FakeChatType.OneOnOne);
            for (int i = 0; i < groups; i++) MakeChat(FakeChatType.Group);
            for (int i = 0; i < meetings; i++) MakeChat(FakeChatType.Meeting, i == 0);
        }

        void FillToTarget()
        {
            while (st.Messages < p.TargetMessages)
            {
                double r = rng.NextDouble();
                MakeChat(r < 0.55 ? FakeChatType.OneOnOne : r < 0.90 ? FakeChatType.Group : FakeChatType.Meeting, false);
            }
        }

        FakeChat MakeChat(FakeChatType kind, bool allHands = false)
        {
            FakeUser[] members;
            if (kind == FakeChatType.OneOnOne)
            {
                members = null;
                for (int tries = 0; tries < 6 && members == null; tries++)
                {
                    var m = PickMembers(2, true);
                    if (m.Length == 2 && !t.OneOnOneByPair.ContainsKey(FakeTenant.PairKey(m[0].Ordinal, m[1].Ordinal))) members = m;
                }
                if (members == null) { kind = FakeChatType.Group; members = PickMembers(3, true); }
            }
            else if (kind == FakeChatType.Group) members = PickMembers(rng.Next(p.GroupMinSize, p.GroupMaxSize + 1), true);
            else
            {
                int cap = Math.Min(users.Length, p.MeetingMaxMembers);
                int size = allHands ? cap : (int)Math.Max(3, Math.Min(cap, rng.LogNormal(8, 1.1)));
                members = PickMembers(size, true);
            }
            double span = (endMs - startMs);
            long w0 = startMs + (long)(rng.NextDouble() * span * 0.9);
            double durDays = kind == FakeChatType.OneOnOne ? rng.LogNormal(120, 1.0) : kind == FakeChatType.Group ? rng.LogNormal(90, 1.0) : rng.LogNormal(20, 1.0);
            long w1 = Math.Min(endMs - 3600000L, w0 + (long)(durDays * Day));
            if (w1 < w0 + 3600000L) w1 = Math.Min(endMs, w0 + 3600000L);
            string topic = kind == FakeChatType.OneOnOne ? null : kind == FakeChatType.Meeting ? "Meeting: " + Topics[rng.Next(Topics.Length)] : (rng.Chance(0.7) ? Topics[rng.Next(Topics.Length)] : null);
            var chat = t.AddChatMs(kind, members, topic, w0 - 60000, p.Language);
            double median = kind == FakeChatType.Meeting ? Math.Max(4, p.MessagesPerChatMedian / 2) : p.MessagesPerChatMedian;
            int n = (int)Math.Max(1, Math.Min(p.MaxMessagesPerChat, rng.LogNormal(median, p.MessagesPerChatSigma)));
            if (allHands) n = Math.Max(n, 40);
            var times = GenTimes(n, w0, w1);
            FakeUser last = null;
            for (int i = 0; i < n; i++)
            {
                var author = PickAuthor(members, times[i], last, members.Length == 2);
                last = author;
                AddOne(chat, times[i], author, members, null, 0, true);
            }
            st.ChatMessages += n;
            return chat;
        }

        FakeUser PickAuthor(FakeUser[] members, long when, FakeUser last, bool alternate)
        {
            for (int tries = 0; tries < 6; tries++)
            {
                var u = members[rng.Next(members.Length)];
                if (alternate && last != null && u == last && rng.Chance(0.5)) continue;
                if (u.Deleted && when >= u.DeletedMs) continue;
                return u;
            }
            foreach (var u in members) if (!(u.Deleted && when >= u.DeletedMs)) return u;
            return members[0];
        }

        string MsgPath(FakeThread th, FakeMessage m)
        {
            var chat = th as FakeChat;
            if (chat != null) return "chats/" + chat.Id + "/messages/" + m.CreatedMs;
            var ch = (FakeChannel)th;
            string b = "teams/" + ch.Team.Id + "/channels/" + ch.Id + "/messages/";
            return m.ReplyTo != 0 ? b + m.ReplyTo + "/replies/" + m.CreatedMs : b + m.CreatedMs;
        }

        static string HostedId(long msgId, int k) { return Convert.ToBase64String(Encoding.ASCII.GetBytes("id=x_" + k + "-wus-d1-" + msgId.ToString("x"))).TrimEnd('=').Replace('+', '-').Replace('/', '_'); }

        FakeMessage AddOne(FakeThread th, long when, FakeUser author, FakeUser[] members, FakeChannel channel, long replyTo, bool isChat)
        {
            var m = new FakeMessage { CreatedMs = when, ModifiedMs = when, AuthorOrd = author.Ordinal, Seed = rng.Next(int.MaxValue) };
            if (rng.Chance(p.TextBodyPct)) m.Flags |= FakeMessage.FlagText;
            if (replyTo != 0) m.Ext().ReplyTo = replyTo;
            bool deleted = rng.Chance(p.DeletePct);
            if (deleted)
            {
                var x = m.Ext(); x.DeletedMs = Math.Min(endMs, when + 60000 + rng.NextLong(3 * Day)); m.Flags |= FakeMessage.FlagDeleted; m.ModifiedMs = x.DeletedMs; st.Deleted++;
            }
            else if (rng.Chance(p.EditPct))
            {
                var x = m.Ext(); x.EditedMs = Math.Min(endMs, when + 60000 + rng.NextLong(2 * Day)); m.ModifiedMs = x.EditedMs; st.Edited++;
            }
            th.AddUnique(m);
            st.Messages++;
            if (deleted) return m;
            double r = rng.NextDouble();
            double c1 = p.InlineImagePct, c2 = c1 + p.FilePct, c3 = c2 + p.CardPct, c4 = c3 + (members.Length > 2 || channel != null ? p.MentionPct : 0);
            if (r < c1) AddImage(th, m);
            else if (r < c2) AddFile(th, m, author, members, channel);
            else if (r < c3) AddCard(m);
            else if (r < c4) AddMention(m, author, members);
            if (rng.Chance(p.ReactionPct))
            {
                int k = 1 + rng.Next(3); var rs = new FakeReaction[k];
                for (int i = 0; i < k; i++) rs[i] = new FakeReaction { Type = Reacts[rng.Next(Reacts.Length)], UserOrd = members[rng.Next(members.Length)].Ordinal, CreatedMs = Math.Min(endMs, m.CreatedMs + 30000 + rng.NextLong(Day)) };
                m.Ext().Reactions = rs; st.Reactions += k;
            }
            return m;
        }

        string Inner(FakeMessage m, string lang)
        {
            var s = FakeText.Render(m.Seed, lang);
            return s;
        }

        void AddImage(FakeThread th, FakeMessage m)
        {
            int ix = rng.Next(images.Count);
            string hid = HostedId(m.CreatedMs, 0);
            var x = m.Ext();
            x.Hosted = new[] { new FakeHostedContent { Id = hid, ContentType = "image/png", Bytes = images[ix] } };
            x.Body = Inner(m, th.Lang) + "<p><img src=\"https://graph.microsoft.com/v1.0/" + MsgPath(th, m) + "/hostedContents/" + hid + "/$value\" width=\"" + imageSize[ix][0] + "\" height=\"" + imageSize[ix][1] + "\" alt=\"image\" style=\"vertical-align:bottom;\"></p>";
            st.WithImages++;
        }

        void AddMention(FakeMessage m, FakeUser author, FakeUser[] members)
        {
            FakeUser target = null;
            for (int i = 0; i < 6 && target == null; i++) { var u = members[rng.Next(members.Length)]; if (u != author && !u.Deleted) target = u; }
            if (target == null) return;
            var x = m.Ext();
            string inner = FakeText.Render(m.Seed, "en"); inner = inner.Substring(3, inner.Length - 7);
            x.Body = "<p><at id=\"0\">" + target.DisplayName + "</at> " + inner + "</p>";
            x.Mentions = new[] { new FakeMention { Id = 0, Text = target.DisplayName, UserOrd = target.Ordinal } };
        }

        void AddCard(FakeMessage m)
        {
            string aid = t.NewGuid();
            var x = m.Ext();
            bool adaptive = rng.Chance(0.6);
            x.Body = "<attachment id=\"" + aid + "\"></attachment>";
            x.Attachments = new[] { new FakeAttachment
            {
                Id = aid, ContentType = adaptive ? FakeAttachment.AdaptiveCard : FakeAttachment.HeroCard, Name = null,
                Content = adaptive ? "{\"type\":\"AdaptiveCard\",\"version\":\"1.4\",\"body\":[{\"type\":\"TextBlock\",\"weight\":\"Bolder\",\"text\":\"Demande d'approbation\"},{\"type\":\"TextBlock\",\"text\":\"Commande n°" + (1000 + m.Seed % 9000) + "\",\"wrap\":true}],\"actions\":[{\"type\":\"Action.Submit\",\"title\":\"Approuver\"}]}"
                                   : "{\"title\":\"Rapport hebdomadaire\",\"subtitle\":\"Semaine " + (1 + m.Seed % 52) + "\",\"text\":\"Les indicateurs sont disponibles.\",\"buttons\":[{\"type\":\"openUrl\",\"title\":\"Ouvrir\",\"value\":\"https://contoso.com/rapport\"}]}"
            } };
        }

        void AddFile(FakeThread th, FakeMessage m, FakeUser author, FakeUser[] members, FakeChannel channel)
        {
            FakeDrive drive; string folder; FakeUser owner = author;
            if (channel != null) { drive = channel.Drive; folder = "/" + channel.FolderName; }
            else
            {
                if (owner.External) owner = members.FirstOrDefault(u => !u.External && !u.Deleted) ?? internalUsers[0];
                drive = t.UserDrive(owner); folder = "/Microsoft Teams Chat Files";
            }
            FakeDriveItem item = null;
            if (recentFiles.Count > 0 && rng.Chance(p.ForwardedFilePct)) { item = recentFiles[rng.Next(recentFiles.Count)]; st.SharedFileCopies++; }
            else
            {
                string name; long size; ulong seed;
                if (popular.Count > 0 && rng.Chance(p.PopularFilePct)) { var pf = popular[rng.Next(popular.Count)]; name = pf.Name; size = pf.Size; seed = pf.Seed; st.SharedFileCopies++; }
                else
                {
                    fileCounter++;
                    name = FileBases[rng.Next(FileBases.Length)] + "_" + fileCounter + FileExts[rng.Next(FileExts.Length)];
                    size = rng.Chance(p.HugeFilePct) ? p.MaxFileBytes : (long)Math.Min(p.MaxFileBytes, Math.Max(1024, rng.LogNormal(p.FileSizeMedianBytes, p.FileSizeSigma)));
                    seed = rng.NextU64();
                }
                string stem = Path.GetFileNameWithoutExtension(name), ext = Path.GetExtension(name); int n = 1;
                string fp = folder + "/" + name;
                while (drive.ByPath.ContainsKey(fp)) { name = stem + " (" + n++ + ")" + ext; fp = folder + "/" + name; }
                item = t.AddGeneratedFile(drive, folder, name, size, seed, owner, FakeTime.FromMs(m.CreatedMs - 5000));
                st.FileBytes += size;
                int others = Math.Min(members.Length, 4);
                for (int i = 0; i < others; i++)
                    if (members[i] != owner && !members[i].External && !members[i].Deleted)
                        item.Permissions.Add(new FakePermission { Id = "perm" + (++permCounter), Roles = new[] { "read" }, UserOrd = members[i].Ordinal, Email = members[i].Mail });
                if (recentFiles.Count < 64) recentFiles.Add(item); else recentFiles[rng.Next(64)] = item;
            }
            string aid = t.NewGuid();
            var x = m.Ext();
            x.Body = Inner(m, th.Lang) + "<attachment id=\"" + aid + "\"></attachment>";
            x.Attachments = new[] { new FakeAttachment { Id = aid, ContentType = FakeAttachment.Reference, ContentUrl = item.WebUrl, Name = item.Name } };
            st.WithFiles++;
        }

        // ---- teams
        void CreateTeams()
        {
            for (int ti = 0; ti < p.Teams; ti++)
            {
                string name = TeamNames[ti % TeamNames.Length] + (ti >= TeamNames.Length ? " " + (ti / TeamNames.Length + 1) : "");
                int size = p.TeamMembers > 0 ? p.TeamMembers : Math.Max(4, Math.Min(internalUsers.Length, users.Length * 3 / (Math.Max(1, p.Teams) * 2)));
                size = Math.Min(size, internalUsers.Length);
                var members = new List<FakeUser>();
                int guard = 0;
                while (members.Count < size && guard++ < size * 20) { var u = internalUsers[rng.Next(internalUsers.Length)]; if (!members.Contains(u)) members.Add(u); }
                long created = startMs + (long)(rng.NextDouble() * 0.3 * (endMs - startMs));
                var team = t.AddTeam(name, members, FakeTime.FromMs(created), "Espace de travail de " + name.ToLowerInvariant());
                int channels = Math.Max(1, p.ChannelsPerTeam);
                for (int ci = 0; ci < channels; ci++)
                {
                    FakeChannelType type = ci == 0 ? FakeChannelType.Standard : rng.Chance(p.PrivateChannelPct) ? FakeChannelType.Private : rng.Chance(p.SharedChannelPct) ? FakeChannelType.Shared : FakeChannelType.Standard;
                    string cname = ci == 0 ? "General" : ChannelNames[(ti + ci - 1) % ChannelNames.Length];
                    if (team.Channels.Any(x => x.DisplayName == cname)) cname += " " + ci;
                    var cmembers = new List<FakeUser>();
                    if (type != FakeChannelType.Standard)
                    {
                        int cs = Math.Min(members.Count, 2 + rng.Next(4));
                        for (int i = 0; i < cs; i++) cmembers.Add(members[i]);
                        if (type == FakeChannelType.Shared) { var ext = users.FirstOrDefault(u => u.External); if (ext != null) cmembers.Add(ext); }
                    }
                    var ch = t.AddChannel(team, cname, type, cmembers, FakeTime.FromMs(created + (ci == 0 ? 0 : rng.NextLong(10 * Day))), null);
                    ch.Lang = p.Language;
                    var authors = (type == FakeChannelType.Standard ? members : cmembers).ToArray();
                    GenerateChannelThreads(ch, authors, Math.Max(created, ch.CreatedMs));
                }
            }
        }

        void GenerateChannelThreads(FakeChannel ch, FakeUser[] members, long from)
        {
            if (members.Length == 0) return;
            int roots = (int)Math.Max(1, Math.Min(5000, rng.LogNormal(p.ThreadsPerChannelMedian, 0.8)));
            var times = GenTimes(roots, from + 3600000L, endMs - 3600000L);
            for (int i = 0; i < roots; i++)
            {
                var author = PickAuthor(members, times[i], null, false);
                var root = AddOne(ch, times[i], author, members, ch, 0, false);
                if (rng.Chance(0.3)) root.Ext().Subject = "Sujet " + (1 + rng.Next(99));
                st.ChannelMessages++;
                int replies = 0;
                while (rng.NextDouble() < p.RepliesPerThreadMean / (p.RepliesPerThreadMean + 1.0) && replies < 60) replies++;
                long tm = root.CreatedMs;
                for (int k = 0; k < replies; k++)
                {
                    tm = Math.Min(endMs, tm + 60000 + (long)(-Math.Log(Math.Max(rng.NextDouble(), 1e-9)) * 25 * 60000));
                    AddOne(ch, tm, PickAuthor(members, tm, author, false), members, ch, root.CreatedMs, false);
                    st.Replies++; st.ChannelMessages++;
                }
            }
        }
    }

    /// <summary>The awkward messages real tenants contain, in one group chat. Used by the preview sanitizer tests, the export and the import.</summary>
    static class SyntheticEdgeCases
    {
        const long Day = 86400000L;

        public static void Add(FakeTenant t, FakeUser[] users, FakeUser[] internalUsers, int active, int dep, int ext, long startMs, string lang, SyntheticStats st, List<byte[]> images)
        {
            var members = new List<FakeUser> { users[0], users[1] };
            FakeUser departed = dep > 0 ? users[active] : null;
            FakeUser external = ext > 0 ? users[users.Length - 1] : null;
            if (active > 2) members.Add(users[2]);
            if (departed != null) members.Add(departed);
            if (external != null) members.Add(external);
            var chat = t.AddChatMs(FakeChatType.Group, members, "Edge cases (test data)", startMs + Day, lang);
            long when = startMs + Day + 3600000L;
            var a = users[0]; var b = users[1];

            Func<FakeUser, string, FakeMessage> say = (u, html) =>
            {
                var m = new FakeMessage { CreatedMs = when, ModifiedMs = when, AuthorOrd = u.Ordinal };
                m.Ext().Body = html;
                chat.AddUnique(m);
                when += 61000;
                st.Messages++;
                return m;
            };

            // 1-4: HTML that must never run in the preview
            say(a, "<p>Test XSS : <script>alert('xss')</script>fin du message</p>");
            say(b, "<p><img src=\"x\" onerror=\"alert(document.cookie)\"> broken image with an error handler</p>");
            say(a, "<p><a href=\"javascript:alert(1)\">cliquez ici</a> et <a href=\"https://fabrikam.com/page?a=1&amp;b=2\" onclick=\"steal()\">un lien normal</a></p>");
            say(b, "<iframe src=\"https://evil.example/x\"></iframe><style>body{display:none}</style><svg onload=\"alert(1)\"></svg><object data=\"x.swf\"></object><p>after the dangerous tags</p>");
            // 5-6: unicode, emoji, right-to-left
            say(a, "<p>Emoji : \U0001F600 \U0001F468‍\U0001F469‍\U0001F467‍\U0001F466 \U0001F1EB\U0001F1F7 \U0001F44D\U0001F3FD ❤️ \U0001F680</p>");
            say(b, "<p dir=\"rtl\">مرحبا بالعالم - هذا اختبار</p><p dir=\"rtl\">שלום עולם</p><p>Meeting مع الفريق at 10:30 (UTC+1)</p>");
            // 7: very long message, close to the 28 KB limit
            var sb = new StringBuilder("<p>");
            int i = 1;
            while (sb.Length < 26000) { sb.Append(FakeText.Plain(i++, lang)).Append(' '); }
            sb.Append("</p>");
            say(a, sb.ToString());
            // 8: code blocks
            say(b, "<p>Voici le script :</p><pre><code>function f(x) {\n  return x &lt; 3 ? &quot;a&quot; : &quot;b&quot;;\n}</code></pre><codeblock class=\"python\"><code>def f(x):\n    return 'a' if x &lt; 3 else 'b'</code></codeblock>");
            // 9: plain text content type
            var plain = say(a, "Plain text with <tags> & special characters, no HTML.");
            plain.Flags |= FakeMessage.FlagText;
            // 10: entities, whitespace, zero width, combining
            say(b, "<p>&nbsp;&lt;script&gt;alert(1)&lt;/script&gt; &amp; tab\t new\nline zero​width combiné é</p>");
            say(a, "<p>&nbsp;</p>");

            // 11: quote reply (messageReference)
            var quoted = say(b, "<p>Original message to quote.</p>");
            string refId = t.NewGuid();
            var reply = say(a, "<attachment id=\"" + refId + "\"></attachment><p>Replying to this message.</p>");
            reply.Ext().Attachments = new[] { new FakeAttachment { Id = refId, ContentType = FakeAttachment.MessageReference, Content = "{\"messageId\":\"" + quoted.CreatedMs + "\",\"messagePreview\":\"Original message to quote.\",\"messageSender\":{\"user\":{\"displayName\":\"" + b.DisplayName + "\",\"id\":\"" + b.Id + "\",\"userIdentityType\":\"aadUser\"}}}" } };
            // 12: cards
            string c1 = t.NewGuid(), c2 = t.NewGuid();
            var cards = say(b, "<attachment id=\"" + c1 + "\"></attachment><attachment id=\"" + c2 + "\"></attachment>");
            cards.Ext().Attachments = new[]
            {
                new FakeAttachment { Id = c1, ContentType = FakeAttachment.AdaptiveCard, Content = "{\"type\":\"AdaptiveCard\",\"version\":\"1.4\",\"body\":[{\"type\":\"TextBlock\",\"text\":\"Adaptive card\"}]}" },
                new FakeAttachment { Id = c2, ContentType = FakeAttachment.HeroCard, Content = "{\"title\":\"Hero card\",\"text\":\"Card text\"}" }
            };

            // 13: files: a real small file, a 1 GiB generated file, a deleted one (404) and a forbidden one (403)
            var drive = t.UserDrive(a);
            var small = t.AddFile(drive, "/Microsoft Teams Chat Files", "Read-me.txt", Encoding.UTF8.GetBytes("Test file for TeamsTransfer.\nSecond line with accents: éèà .\n"), a, FakeTime.FromMs(when - 60000));
            var big = t.AddGeneratedFile(drive, "/Microsoft Teams Chat Files", "Large_file_1GB.bin", 1024L * 1024 * 1024, 0xB16B00B5UL, a, FakeTime.FromMs(when - 60000));
            var gone = t.AddGeneratedFile(drive, "/Microsoft Teams Chat Files", "Deleted.docx", 40960, 0xDEADUL, a, FakeTime.FromMs(when - 60000)); gone.Deleted = true;
            var denied = t.AddGeneratedFile(drive, "/Microsoft Teams Chat Files", "Confidential.pdf", 81920, 0xBEEFUL, a, FakeTime.FromMs(when - 60000)); denied.AccessDenied = true;
            var fm = say(a, "");
            var atts = new List<FakeAttachment>(); var body = new StringBuilder("<p>Four attachments, two of them unreachable.</p>");
            foreach (var it in new[] { small, big, gone, denied })
            {
                string id = t.NewGuid();
                atts.Add(new FakeAttachment { Id = id, ContentType = FakeAttachment.Reference, ContentUrl = it.WebUrl, Name = it.Name });
                body.Append("<attachment id=\"").Append(id).Append("\"></attachment>");
            }
            fm.Ext().Body = body.ToString(); fm.Ext().Attachments = atts.ToArray();
            st.WithFiles++;

            // 14: system events
            Action<string> sys = json =>
            {
                var m = new FakeMessage { CreatedMs = when, ModifiedMs = when, AuthorOrd = -1, Flags = FakeMessage.FlagSystem };
                m.Ext().EventDetailJson = json;
                chat.AddUnique(m); when += 61000; st.Messages++;
            };
            string init = "\"initiator\":{\"application\":null,\"device\":null,\"user\":{\"id\":\"" + a.Id + "\",\"displayName\":\"" + a.DisplayName + "\",\"userIdentityType\":\"aadUser\"}}";
            sys("{\"@odata.type\":\"#microsoft.graph.membersAddedEventMessageDetail\",\"visibleHistoryStartDateTime\":\"0001-01-01T00:00:00Z\",\"members\":[{\"id\":\"" + b.Id + "\",\"displayName\":null,\"userIdentityType\":\"aadUser\"}]," + init + "}");
            sys("{\"@odata.type\":\"#microsoft.graph.chatRenamedEventMessageDetail\",\"chatDisplayName\":\"Edge cases (test data)\"," + init + "}");
            sys("{\"@odata.type\":\"#microsoft.graph.callEndedEventMessageDetail\",\"callId\":\"" + t.NewGuid() + "\",\"callEventType\":\"meeting\",\"callDuration\":\"PT32M10S\",\"callParticipants\":[]," + init + "}");

            // 15: bot / application author
            var bot = say(a, "<p>Automatic reminder: the security review is tomorrow at 9 am.</p>");
            bot.AuthorOrd = -1; bot.Ext().FromApplication = "00000000-0000-0000-0000-00000000b07a|Planning assistant";

            // 16: departed and federated authors (and an edit, a deletion, an urgent message)
            if (departed != null) say(departed, "<p>Last message before I leave, all the best everyone!</p>");
            if (external != null) say(external, "<p>Hello, this is your contact at Fabrikam: a message from a federated user.</p>");
            var edited = say(b, "<p>Message edited afterwards.</p>");
            edited.Ext().EditedMs = when + 120000; edited.ModifiedMs = edited.Ext().EditedMs; st.Edited++;
            var del = say(a, "<p>This message was deleted.</p>");
            del.Flags |= FakeMessage.FlagDeleted; del.Ext().DeletedMs = when + 300000; del.ModifiedMs = del.Ext().DeletedMs; st.Deleted++;
            var urgent = say(b, "<p>Message urgent !</p>"); urgent.Ext().Importance = "urgent";

            // 17: image + reactions, including an emoji reaction type
            var img = say(a, "");
            string hid = Convert.ToBase64String(Encoding.ASCII.GetBytes("id=x_0-wus-d1-" + img.CreatedMs.ToString("x"))).TrimEnd('=').Replace('+', '-').Replace('/', '_');
            img.Ext().Hosted = new[] { new FakeHostedContent { Id = hid, ContentType = "image/png", Bytes = images[0] } };
            img.Ext().Body = "<p>Screenshot:</p><img src=\"https://graph.microsoft.com/v1.0/chats/" + chat.Id + "/messages/" + img.CreatedMs + "/hostedContents/" + hid + "/$value\" width=\"320\" height=\"180\" alt=\"screenshot\">";
            img.Ext().Reactions = new[]
            {
                new FakeReaction { Type = "like", UserOrd = b.Ordinal, CreatedMs = when },
                new FakeReaction { Type = "\U0001F680", UserOrd = a.Ordinal, CreatedMs = when + 1000 },
                new FakeReaction { Type = "heart", UserOrd = (departed ?? b).Ordinal, CreatedMs = when + 2000 }
            };
            st.WithImages++; st.Reactions += 3;
            chat.Touch();
        }
    }

    /// <summary>
    /// The "Demo" tenant: a few handwritten, readable French conversations (reactions, an image, a file, a meeting chat, a channel with
    /// replies, a departed colleague and a federated partner) tuned for screenshots of the Teams-like preview and for client demos.
    /// Fictitious people at contoso.com / fabrikam.com. Fully deterministic, no randomness.
    /// </summary>
    static class SyntheticDemo
    {
        static FakeTenant t;
        static FakeUser camille, julien, sophie, nicolas, marc, lea;

        static long Ms(string iso) { long ms; if (!FakeTime.TryParse(iso, out ms)) throw new ArgumentException(iso); return ms; }

        static FakeMessage Say(FakeThread th, FakeUser who, string iso, string html, string reacts = null, long replyTo = 0)
        {
            long c = Ms(iso);
            var m = new FakeMessage { CreatedMs = c, ModifiedMs = c, AuthorOrd = who.Ordinal };
            var x = m.Ext(); x.Body = html;
            if (replyTo != 0) x.ReplyTo = replyTo;
            if (reacts != null)
            {
                var list = new List<FakeReaction>(); int k = 0;
                foreach (var grp in reacts.Split(';'))
                {
                    var kv = grp.Split(':');
                    foreach (var id in kv[1].Split(','))
                    {
                        var u = t.Users[int.Parse(id)];
                        list.Add(new FakeReaction { Type = kv[0], UserOrd = u.Ordinal, CreatedMs = c + 45000 + (k++) * 70000 });
                    }
                }
                x.Reactions = list.ToArray();
            }
            th.AddUnique(m);
            return m;
        }

        static void Edit(FakeMessage m, string iso, string newHtml) { m.Ext().EditedMs = Ms(iso); m.ModifiedMs = m.Ext().EditedMs; m.Ext().Body = newHtml; }
        static void Delete(FakeMessage m, string iso) { m.Ext().DeletedMs = Ms(iso); m.ModifiedMs = m.Ext().DeletedMs; m.Flags |= FakeMessage.FlagDeleted; }

        static void Attach(FakeMessage m, FakeThread th, string text, FakeDriveItem item)
        {
            string aid = t.NewGuid();
            m.Ext().Body = "<p>" + text + "</p><attachment id=\"" + aid + "\"></attachment>";
            m.Ext().Attachments = new[] { new FakeAttachment { Id = aid, ContentType = FakeAttachment.Reference, ContentUrl = item.WebUrl, Name = item.Name } };
        }

        static void Picture(FakeMessage m, FakeThread th, string text, byte[] png, int w, int h, string path)
        {
            string hid = Convert.ToBase64String(Encoding.ASCII.GetBytes("id=x_0-wus-d1-" + m.CreatedMs.ToString("x"))).TrimEnd('=').Replace('+', '-').Replace('/', '_');
            m.Ext().Hosted = new[] { new FakeHostedContent { Id = hid, ContentType = "image/png", Bytes = png } };
            m.Ext().Body = "<p>" + text + "</p><p><img src=\"https://graph.microsoft.com/v1.0/" + path + "/messages/" + m.CreatedMs + "/hostedContents/" + hid + "/$value\" width=\"" + w + "\" height=\"" + h + "\" alt=\"image\" style=\"vertical-align:bottom;\"></p>";
        }

        static void Sys(FakeThread th, string iso, string json)
        {
            long c = Ms(iso);
            var m = new FakeMessage { CreatedMs = c, ModifiedMs = c, AuthorOrd = -1, Flags = FakeMessage.FlagSystem };
            m.Ext().EventDetailJson = json;
            th.AddUnique(m);
        }

        static string At(int id, FakeUser u) { return "<at id=\"" + id + "\">" + u.DisplayName + "</at>"; }

        static void Mention(FakeMessage m, FakeUser u, string rest)
        {
            m.Ext().Body = "<p>" + At(0, u) + " " + rest + "</p>";
            m.Ext().Mentions = new[] { new FakeMention { Id = 0, Text = u.DisplayName, UserOrd = u.Ordinal } };
        }

        public static FakeTenant Build()
        {
            t = new FakeTenant(2026, "contoso.com");
            var end = new DateTimeOffset(2026, 11, 6, 16, 0, 0, TimeSpan.Zero);
            var csw = Stopwatch.StartNew();
            t.Clock = () => end.AddHours(1) + csw.Elapsed;
            camille = t.AddUser("camille.martin@contoso.com", "Camille Martin"); camille.JobTitle = "Project manager";
            julien = t.AddUser("julien.lefevre@contoso.com", "Julien Lefèvre"); julien.JobTitle = "Developer";
            sophie = t.AddUser("sophie.bernard@contoso.com", "Sophie Bernard"); sophie.JobTitle = "Designer";
            nicolas = t.AddUser("nicolas.petit@contoso.com", "Nicolas Petit"); nicolas.JobTitle = "Sales manager";
            marc = t.AddUser("marc.dubois@contoso.com", "Marc Dubois", deleted: true); marc.DeletedMs = Ms("2026-11-01T17:00:00Z");
            lea = t.AddUser("lea.moreau@fabrikam.com", "Léa Moreau", external: true); lea.JobTitle = "Product manager at Fabrikam";
            var chart = FakePng.Chart(7); var mockup = FakePng.Gradient(11, 192, 128);

            // A. one-to-one Camille / Julien
            var a = t.AddChat(FakeChatType.OneOnOne, new[] { camille, julien }, null, DateTimeOffset.Parse("2026-10-27T08:40:00Z"));
            Say(a, camille, "2026-10-27T08:42:10Z", "<p>Hi Julien, did you get a chance to look at last night's test export?</p>");
            var f1 = t.AddGeneratedFile(t.UserDrive(julien), "/Microsoft Teams Chat Files", "Export_test_results.xlsx", 188416, 101, julien, DateTimeOffset.Parse("2026-10-27T08:47:30Z"));
            Attach(Say(a, julien, "2026-10-27T08:48:05Z", "", "like:0;heart:0"), a, "Yes, 1,240 messages exported without errors. The details are in the spreadsheet:", f1);
            Say(a, camille, "2026-10-27T08:55:40Z", "<p>Perfect, thanks! \U0001F44D</p>");
            Picture(Say(a, julien, "2026-10-27T09:10:12Z", "", "like:0"), a, "Here is the throughput measured overnight:", chart, 320, 180, "chats/" + a.Id);
            Say(a, camille, "2026-10-27T09:14:50Z", "<p>Impressive. How many messages per minute at the peak?</p>");
            Say(a, julien, "2026-10-27T09:20:03Z", "<p>About 2,400. The ceiling mostly comes from the Graph quota, not from our machine.</p>");
            Say(a, camille, "2026-10-27T09:21:30Z", "<p>OK. So we keep two machines running in parallel for the cutover.</p>", "like:1");
            var ed = Say(a, camille, "2026-10-28T14:02:00Z", "<p>Follow-up meeting on Thursday at 10:00, does that work for you?</p>");
            Edit(ed, "2026-10-28T14:03:10Z", "<p>Follow-up meeting on Thursday at 10:30, does that work for you?</p>");
            Say(a, julien, "2026-10-28T14:05:44Z", "<p>Perfect, I will be there.</p>", "like:0");

            // B. group chat "Projet Lune"
            var b = t.AddChat(FakeChatType.Group, new[] { camille, julien, sophie, nicolas, marc }, "Project Moon - launch", DateTimeOffset.Parse("2026-10-20T09:00:00Z"));
            var f2 = t.AddGeneratedFile(t.UserDrive(camille), "/Microsoft Teams Chat Files", "Moon_requirements.docx", 188000 + 4096, 202, camille, DateTimeOffset.Parse("2026-10-20T09:10:00Z"));
            Attach(Say(b, camille, "2026-10-20T09:12:00Z", "", "like:1,2,3;heart:4"), b, "Hi everyone, here are the requirements for Project Moon. Please review them and send me your feedback before Friday.", f2);
            Say(b, marc, "2026-10-20T10:31:00Z", "<p>I am fine with the technical part, the contractor confirms delivery for the 15th.</p>", "like:0");
            Picture(Say(b, sophie, "2026-10-21T11:05:00Z", "", "heart:0,1,3;laugh:3"), b, "I have finished the mockups of the home page, what do you think?", mockup, 192, 128, "chats/" + b.Id);
            Mention(Say(b, nicolas, "2026-10-22T15:20:00Z", ""), camille, "the customer wants a check-in before signing, can you call them tomorrow?");
            Say(b, camille, "2026-10-22T15:26:00Z", "<p>I am on it, call tomorrow at 11:00.</p>", "like:3");
            Say(b, julien, "2026-10-27T17:45:00Z", "<p>Quick reminder: the staging environment will be down tonight for the update.</p>", "surprised:2");
            Say(b, marc, "2026-10-30T16:40:00Z", "<p>Last review done. I am handing over to Julien for the follow-up, write to him directly.</p>");
            Say(b, julien, "2026-10-30T16:48:00Z", "<p>Got it Marc, thanks for everything and all the best!</p>", "heart:0,2,3");
            Say(b, sophie, "2026-11-03T09:30:00Z", "<p>Colors approved by management: <b>midnight blue</b> and <b>coral</b>.</p>", "like:0,1");
            var gone = Say(b, nicolas, "2026-11-04T10:02:00Z", "<p>Message sent by mistake</p>"); Delete(gone, "2026-11-04T10:03:00Z");
            Say(b, nicolas, "2026-11-04T10:05:00Z", "<p>Great news: the customer signed this morning! \U0001F389</p>", "heart:0,1,2;laugh:1;like:0");
            Say(b, camille, "2026-11-04T10:12:00Z", "<p>Well done everyone, this is a great launch. See you Monday for the review.</p>", "heart:3,1,2");

            // C. meeting chat
            var c = t.AddChat(FakeChatType.Meeting, new[] { camille, julien, sophie, nicolas }, "Weekly product team sync", DateTimeOffset.Parse("2026-11-03T09:00:00Z"));
            string init = "\"initiator\":{\"application\":null,\"device\":null,\"user\":{\"id\":\"" + camille.Id + "\",\"displayName\":\"Camille Martin\",\"userIdentityType\":\"aadUser\"}}";
            Sys(c, "2026-11-03T10:00:12Z", "{\"@odata.type\":\"#microsoft.graph.callStartedEventMessageDetail\",\"callId\":\"" + t.NewGuid() + "\",\"callEventType\":\"meeting\"," + init + "}");
            Say(c, sophie, "2026-11-03T10:03:00Z", "<p>I will share my screen in two minutes, just reopening the mockup.</p>");
            Say(c, julien, "2026-11-03T10:12:00Z", "<p>Last week's minutes are in the meeting files.</p>", "like:0");
            Say(c, nicolas, "2026-11-03T10:20:00Z", "<p>Customer update: three change requests, I am posting them in the Announcements channel.</p>");
            Sys(c, "2026-11-03T10:32:30Z", "{\"@odata.type\":\"#microsoft.graph.callEndedEventMessageDetail\",\"callId\":\"" + t.NewGuid() + "\",\"callEventType\":\"meeting\",\"callDuration\":\"PT32M18S\",\"callParticipants\":[]," + init + "}");
            Say(c, camille, "2026-11-03T10:40:00Z", "<p>Actions: Sophie delivers the mockups on Thursday, Julien prepares staging, Nicolas follows up with the customer.</p>", "like:1,2,3");

            // D. one-to-one Camille / Sophie
            var d = t.AddChat(FakeChatType.OneOnOne, new[] { camille, sophie }, null, DateTimeOffset.Parse("2026-11-05T13:50:00Z"));
            Say(d, sophie, "2026-11-05T13:55:00Z", "<p>Do you have five minutes to look at the final version of the logo?</p>");
            Say(d, camille, "2026-11-05T13:58:00Z", "<p>Yes, send me the link.</p>");
            var oops = Say(d, sophie, "2026-11-05T14:00:00Z", "<p>Here is the wrong link, oops</p>"); Delete(oops, "2026-11-05T14:01:00Z");
            Say(d, sophie, "2026-11-05T14:02:00Z", "<p>The right link: https://contoso.com/design/logo-final</p>", "like:0");

            // E. a team with standard, private and shared channels
            var team = t.AddTeam("Product Team", new[] { camille, julien, sophie, nicolas }, DateTimeOffset.Parse("2026-09-15T08:00:00Z"), "Product team space");
            var general = t.AddChannel(team, "General", FakeChannelType.Standard, null, DateTimeOffset.Parse("2026-09-15T08:00:00Z"));
            var annonces = t.AddChannel(team, "Announcements", FakeChannelType.Standard, null, DateTimeOffset.Parse("2026-09-15T08:05:00Z"));
            var design = t.AddChannel(team, "Design", FakeChannelType.Standard, null, DateTimeOffset.Parse("2026-09-16T08:05:00Z"));
            var direction = t.AddChannel(team, "Management", FakeChannelType.Private, new[] { camille, nicolas }, DateTimeOffset.Parse("2026-09-20T08:00:00Z"));
            var partners = t.AddChannel(team, "Fabrikam Partners", FakeChannelType.Shared, new[] { camille, sophie, lea }, DateTimeOffset.Parse("2026-10-01T08:00:00Z"));
            string pg = "teams/" + team.Id + "/channels/" + general.Id, pa = "teams/" + team.Id + "/channels/" + annonces.Id;

            var g1 = Say(general, camille, "2026-10-12T08:30:00Z", "<p>Welcome to the product team space! The weekly syncs are on Mondays at 10:00.</p>", "heart:1,2,3;like:1");
            g1.Ext().Subject = "Welcome";
            Say(general, julien, "2026-10-12T08:41:00Z", "<p>Thanks Camille, I am updating the meeting link.</p>", "like:0", g1.CreatedMs);
            Say(general, sophie, "2026-10-12T09:02:00Z", "<p>Great, I am adding the mockups folder to the Files tab.</p>", "like:0", g1.CreatedMs);

            var planning = t.AddGeneratedFile(annonces.Drive, "/Announcements", "Q4_schedule.pdf", 312000, 303, camille, DateTimeOffset.Parse("2026-10-30T09:00:00Z"));
            var n1 = Say(annonces, camille, "2026-10-30T09:05:00Z", "");
            Attach(n1, annonces, "The Q4 schedule is published. Please report your time off before November 10.", planning);
            n1.Ext().Subject = "Q4 schedule"; n1.Ext().Reactions = new[] { new FakeReaction { Type = "like", UserOrd = julien.Ordinal, CreatedMs = Ms("2026-10-30T09:20:00Z") }, new FakeReaction { Type = "like", UserOrd = sophie.Ordinal, CreatedMs = Ms("2026-10-30T09:30:00Z") }, new FakeReaction { Type = "heart", UserOrd = nicolas.Ordinal, CreatedMs = Ms("2026-10-30T10:00:00Z") } };
            Say(annonces, nicolas, "2026-10-30T10:15:00Z", "<p>Are the staging days already blocked?</p>", null, n1.CreatedMs);
            Say(annonces, camille, "2026-10-30T10:22:00Z", "<p>Yes, from November 17 to 19.</p>", "like:3", n1.CreatedMs);

            var n2 = Say(annonces, nicolas, "2026-11-03T11:00:00Z", "<p>Three change requests from the customer Fabrikam: PDF export, date filter and dark mode.</p>", "surprised:1;like:0,2");
            n2.Ext().Subject = "Customer requests";
            Say(annonces, sophie, "2026-11-03T11:10:00Z", "<p>Dark mode is already designed, I will push it this afternoon.</p>", "heart:3", n2.CreatedMs);
            Say(annonces, julien, "2026-11-03T11:25:00Z", "<p>PDF export takes two days, the date filter half a day.</p>", "like:0,3", n2.CreatedMs);

            var dmsg = Say(design, sophie, "2026-11-02T16:00:00Z", "");
            Picture(dmsg, design, "First version of the new home page:", mockup, 192, 128, "teams/" + team.Id + "/channels/" + design.Id);
            dmsg.Ext().Reactions = new[] { new FakeReaction { Type = "heart", UserOrd = camille.Ordinal, CreatedMs = Ms("2026-11-02T16:05:00Z") }, new FakeReaction { Type = "laugh", UserOrd = julien.Ordinal, CreatedMs = Ms("2026-11-02T16:07:00Z") } };
            Say(design, camille, "2026-11-02T16:12:00Z", "<p>Very nice. Let us keep this direction.</p>", null, dmsg.CreatedMs);

            var d1 = Say(direction, camille, "2026-10-25T18:00:00Z", "<p>Budget 2027: I suggest keeping the same scope and adding a designer position.</p>");
            d1.Ext().Subject = "Budget 2027";
            Say(direction, nicolas, "2026-10-25T18:30:00Z", "<p>Agreed in principle, I am preparing the figures for the committee.</p>", "like:0", d1.CreatedMs);

            var p1 = Say(partners, camille, "2026-10-14T14:00:00Z", "<p>Welcome Léa! This channel is shared with Fabrikam to follow the deliveries.</p>", "heart:5,2");
            p1.Ext().Subject = "Welcome";
            Say(partners, lea, "2026-10-14T14:20:00Z", "<p>Thanks Camille, delighted to work with you. We look forward to seeing the first version.</p>", "like:0", p1.CreatedMs);
            Say(partners, sophie, "2026-10-14T14:35:00Z", "<p>I will send you the mockups as soon as they are approved.</p>", null, p1.CreatedMs);

            foreach (var chat in t.Chats) chat.Touch();
            return t;
        }
    }
}
