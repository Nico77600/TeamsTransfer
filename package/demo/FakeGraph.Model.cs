// DEMO-ONLY SOURCE. Part of the Demo mode of the console (-Gui -Demo): a synthetic tenant and a fake Microsoft Graph, compiled together with the engine
// in Demo mode and by the tests ONLY. It is never loaded by the command line modes and never talks to the network. Single source of truth (the tests compile it from here).
// =============================================================================
//  TeamsTransfer - fake Microsoft Graph: the in-memory tenant model (tests, demo mode, volume tests)
// -----------------------------------------------------------------------------
//  WHY: the engine must be tested offline, deterministically, and at the scale it will meet in production (a user with
//  hundreds of thousands of messages, a tenant with millions). This file holds the tenant the fake service answers from:
//  users, chats, teams and channels, messages, hosted contents, drives and drive items.
//
//  HOW IT STAYS SMALL (>= 1 million messages in a test process):
//   - a message is a ~60-byte object: two longs (created / modified, epoch ms), an author ordinal, a text seed, flags and ONE
//     reference to a "extras" object that exists only for the messages that need it (reactions, attachments, edits, images...).
//   - the body of an ordinary message is NOT stored: it is rendered on demand from (seed, language) by FakeText, so the
//     same message always produces the same HTML without holding it in memory.
//   - the id of a message IS its createdDateTime in epoch milliseconds (the service does the same for chat messages), so lookup is
//     a binary search in the thread (messages are kept sorted by creation) and no dictionary is needed. Unique per thread.
//   - file contents of any size are a deterministic byte stream (FakeContentStream: seed + length, seekable), so a 1 GB file costs
//     a few bytes; real bytes are kept only for small files that tests or the import API put there.
//   - JSON is never built for the whole dataset: the transport streams one page at a time with Utf8JsonWriter.
//  Users are referenced by ordinal (index in FakeTenant.Users) everywhere inside the model.
//
//  Concurrency: the transport takes FakeTenant.Gate around every request; direct use of the model from tests is single-threaded.
// =============================================================================
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace TeamsTransfer.Testing
{
    public enum FakeChatType { OneOnOne, Group, Meeting }
    public enum FakeChannelType { Standard, Private, Shared }

    /// <summary>Epoch-millisecond helpers. Graph chat messages carry millisecond timestamps; everything in the model is long ms.</summary>
    public static class FakeTime
    {
        const long UnixEpochTicks = 621355968000000000L;
        public static long ToMs(DateTimeOffset d) { return FloorDiv(d.UtcTicks - UnixEpochTicks, 10000); }
        public static DateTimeOffset FromMs(long ms) { return new DateTimeOffset(ms * 10000 + UnixEpochTicks, TimeSpan.Zero); }

        static long FloorDiv(long a, long b) { long q = a / b; return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q; }

        /// <summary>Parses an ISO 8601 instant and TRUNCATES (not rounds) to the millisecond, as the import API does.</summary>
        public static bool TryParse(string s, out long ms)
        {
            ms = 0;
            if (string.IsNullOrWhiteSpace(s)) return false;
            DateTimeOffset d;
            if (!DateTimeOffset.TryParse(s.Trim().Trim('\''), System.Globalization.CultureInfo.InvariantCulture,
                    System.Globalization.DateTimeStyles.AssumeUniversal | System.Globalization.DateTimeStyles.AdjustToUniversal, out d)) return false;
            ms = ToMs(d);
            return true;
        }

        /// <summary>yyyy-MM-ddTHH:mm:ss.fffZ, hand-rolled because a page of 50 messages formats 150 timestamps.</summary>
        public static string Format(long ms)
        {
            Span<char> b = stackalloc char[24];
            FormatTo(b, ms);
            return new string(b);
        }

        public static void FormatTo(Span<char> b, long ms)
        {
            long days = FloorDiv(ms, 86400000L);
            long rem = ms - days * 86400000L;
            // civil_from_days (Howard Hinnant)
            long z = days + 719468;
            long era = FloorDiv(z, 146097);
            long doe = z - era * 146097;
            long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
            long y = yoe + era * 400;
            long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
            long mp = (5 * doy + 2) / 153;
            long d = doy - (153 * mp + 2) / 5 + 1;
            long m = mp < 10 ? mp + 3 : mp - 9;
            if (m <= 2) y++;
            int hh = (int)(rem / 3600000); rem %= 3600000;
            int mi = (int)(rem / 60000); rem %= 60000;
            int ss = (int)(rem / 1000); int fff = (int)(rem % 1000);
            Dig(b, 0, (int)y, 4); b[4] = '-'; Dig(b, 5, (int)m, 2); b[7] = '-'; Dig(b, 8, (int)d, 2); b[10] = 'T';
            Dig(b, 11, hh, 2); b[13] = ':'; Dig(b, 14, mi, 2); b[16] = ':'; Dig(b, 17, ss, 2); b[19] = '.'; Dig(b, 20, fff, 3); b[23] = 'Z';
        }

        static void Dig(Span<char> b, int at, int v, int n)
        {
            for (int i = n - 1; i >= 0; i--) { b[at + i] = (char)('0' + v % 10); v /= 10; }
        }
    }

    /// <summary>Splitmix64: tiny, fast, seedable and identical on every machine (System.Random is not guaranteed to be).</summary>
    public sealed class FakeRng
    {
        ulong _s;
        public FakeRng(long seed) { _s = (ulong)seed * 0x9E3779B97F4A7C15UL + 0x1234567UL; }
        public ulong NextU64()
        {
            ulong z = (_s += 0x9E3779B97F4A7C15UL);
            z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
            z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
            return z ^ (z >> 31);
        }
        public int Next(int maxExclusive) { return maxExclusive <= 1 ? 0 : (int)(NextU64() % (ulong)maxExclusive); }
        public int Next(int min, int maxExclusive) { return min + Next(maxExclusive - min); }
        public long NextLong(long maxExclusive) { return maxExclusive <= 1 ? 0 : (long)(NextU64() % (ulong)maxExclusive); }
        public double NextDouble() { return (NextU64() >> 11) * (1.0 / 9007199254740992.0); }
        public bool Chance(double p) { return p > 0 && NextDouble() < p; }
        /// <summary>Log-normal sample with the given median (bytes, message counts...).</summary>
        public double LogNormal(double median, double sigma)
        {
            double u1 = Math.Max(NextDouble(), 1e-12), u2 = NextDouble();
            double n = Math.Sqrt(-2 * Math.Log(u1)) * Math.Cos(2 * Math.PI * u2);
            return median * Math.Exp(sigma * n);
        }
        public T Pick<T>(IList<T> list) { return list[Next(list.Count)]; }
        public Guid NextGuid()
        {
            var b = new byte[16];
            BitConverter.GetBytes(NextU64()).CopyTo(b, 0); BitConverter.GetBytes(NextU64()).CopyTo(b, 8);
            b[7] = (byte)((b[7] & 0x0F) | 0x40); b[8] = (byte)((b[8] & 0x3F) | 0x80);
            return new Guid(b);
        }
    }

    /// <summary>A byte stream defined by (seed, length): deterministic, seekable, no memory. Stands for files of any size.</summary>
    public sealed class FakeContentStream : Stream
    {
        readonly ulong _seed; readonly long _length; long _pos;
        public FakeContentStream(ulong seed, long length) { _seed = seed; _length = length; }

        static ulong Mix(ulong z)
        {
            z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
            z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
            return z ^ (z >> 31);
        }

        /// <summary>Fills dst with the bytes of the virtual file starting at offset.</summary>
        public static void Fill(ulong seed, long offset, Span<byte> dst)
        {
            int i = 0;
            while (i < dst.Length)
            {
                long p = offset + i;
                ulong v = Mix(seed + (ulong)(p >> 3) * 0x9E3779B97F4A7C15UL);
                int sh = (int)(p & 7);
                while (sh < 8 && i < dst.Length) { dst[i++] = (byte)(v >> (sh * 8)); sh++; }
            }
        }

        public override bool CanRead { get { return true; } }
        public override bool CanSeek { get { return true; } }
        public override bool CanWrite { get { return false; } }
        public override long Length { get { return _length; } }
        public override long Position { get { return _pos; } set { _pos = value; } }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) { return Read(new Span<byte>(buffer, offset, count)); }
        public override int Read(Span<byte> buffer)
        {
            long left = _length - _pos;
            if (left <= 0) return 0;
            int n = (int)Math.Min(buffer.Length, left);
            Fill(_seed, _pos, buffer.Slice(0, n));
            _pos += n;
            return n;
        }
        public override long Seek(long offset, SeekOrigin origin)
        {
            _pos = origin == SeekOrigin.Begin ? offset : origin == SeekOrigin.Current ? _pos + offset : _length + offset;
            return _pos;
        }
        public override void SetLength(long value) { throw new NotSupportedException(); }
        public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
    }

    public sealed class FakeUser
    {
        public int Ordinal;
        public string Id, Upn, DisplayName, Mail, TenantId, UserType = "Member";
        /// <summary>Soft-deleted account (a leaver): gone from /users, readable under /directory/deletedItems, still the author of old messages.</summary>
        public bool Deleted;
        public long DeletedMs;
        /// <summary>Federated user of ANOTHER tenant: never in the directory (404 on /users/{id}), but can be a chat member and a message author.</summary>
        public bool External;
        public string GivenName, Surname, JobTitle;
        public FakeDrive Drive;
    }

    public sealed class FakeMember
    {
        public int UserOrd;
        /// <summary>"owner" or "guest" or "" (Graph roles).</summary>
        public string Roles = "";
        /// <summary>FakeMember.AllHistory (= 0001-01-01, the Graph default) or an instant in epoch ms.</summary>
        public long VisibleHistoryStartMs = AllHistory;
        public const long AllHistory = long.MinValue;
    }

    /// <summary>Common part of a chat and a channel: a time-ordered list of messages and the indexes used to list them.</summary>
    public abstract class FakeThread
    {
        public string Id;
        public int Ordinal;
        public long CreatedMs;
        /// <summary>null | "inProgress" | "completed".</summary>
        public string MigrationMode;
        /// <summary>AppId that started the migration: only that application may import and complete.</summary>
        public string MigrationOwnerAppId;
        /// <summary>"fr" or "en": language of the lazily rendered bodies.</summary>
        public string Lang = "fr";
        public readonly List<FakeMessage> Messages = new List<FakeMessage>();
        public int Version;
        public long LastModifiedMs;

        int _indexVersion = -1;
        int[] _byMod;                       // positions in Messages, newest modification first
        int[] _roots;                       // same, only root messages (ReplyTo == 0)
        Dictionary<long, List<int>> _replies; // root id -> positions of its replies, newest modification first

        public bool IsChannel { get { return this is FakeChannel; } }

        /// <summary>Inserts keeping creation order. The caller guarantees the id (createdMs) is free; use AddUnique to bump.</summary>
        public void Add(FakeMessage m)
        {
            int n = Messages.Count;
            if (n == 0 || Messages[n - 1].CreatedMs < m.CreatedMs) Messages.Add(m);
            else
            {
                int i = IndexOf(m.CreatedMs);
                Messages.Insert(i < 0 ? ~i : i, m);
            }
            if (m.ModifiedMs > LastModifiedMs) LastModifiedMs = m.ModifiedMs;
            Version++;
        }

        /// <summary>Adds the message, shifting its timestamps by +1 ms until its id is free (the generator's way to honour the uniqueness rule).</summary>
        public FakeMessage AddUnique(FakeMessage m)
        {
            while (IndexOf(m.CreatedMs) >= 0)
            {
                m.CreatedMs++; m.ModifiedMs++;
                if (m.X != null) { if (m.X.EditedMs != 0) m.X.EditedMs++; if (m.X.DeletedMs != 0) m.X.DeletedMs++; }
            }
            Add(m);
            return m;
        }

        public int IndexOf(long createdMs)
        {
            int lo = 0, hi = Messages.Count - 1;
            while (lo <= hi)
            {
                int mid = (int)(((long)lo + hi) >> 1);
                long v = Messages[mid].CreatedMs;
                if (v == createdMs) return mid;
                if (v < createdMs) lo = mid + 1; else hi = mid - 1;
            }
            return ~lo;
        }

        public FakeMessage Find(long id) { int i = IndexOf(id); return i >= 0 ? Messages[i] : null; }

        public void Touch() { Version++; }

        void EnsureIndex()
        {
            if (_indexVersion == Version && _byMod != null) return;
            int n = Messages.Count;
            var pos = new int[n];
            for (int i = 0; i < n; i++) pos[i] = i;
            var msgs = Messages;
            // newest modification first; ties broken by id descending, strict and deterministic
            Array.Sort(pos, (a, b) =>
            {
                int c = msgs[b].ModifiedMs.CompareTo(msgs[a].ModifiedMs);
                return c != 0 ? c : msgs[b].CreatedMs.CompareTo(msgs[a].CreatedMs);
            });
            _byMod = pos;
            if (IsChannel)
            {
                var roots = new List<int>(); var replies = new Dictionary<long, List<int>>();
                foreach (int p in pos)
                {
                    long rt = msgs[p].ReplyTo;
                    if (rt == 0) roots.Add(p);
                    else { List<int> l; if (!replies.TryGetValue(rt, out l)) replies[rt] = l = new List<int>(); l.Add(p); }
                }
                _roots = roots.ToArray(); _replies = replies;
            }
            else { _roots = pos; _replies = null; }
            _indexVersion = Version;
        }

        public int[] ByModified { get { EnsureIndex(); return _byMod; } }
        public int[] Roots { get { EnsureIndex(); return _roots; } }
        public int[] RepliesOf(long rootId)
        {
            EnsureIndex();
            List<int> l;
            return _replies != null && _replies.TryGetValue(rootId, out l) ? l.ToArray() : new int[0];
        }
    }

    public sealed class FakeChat : FakeThread
    {
        public FakeChatType ChatType;
        public string Topic;
        public readonly List<FakeMember> Members = new List<FakeMember>();
        public string MeetingJoinUrl;
        public string PairKey;      // one-on-one only: "userOrdA:userOrdB"
        public long LastUpdatedMs;
        public string TypeName { get { return ChatType == FakeChatType.OneOnOne ? "oneOnOne" : ChatType == FakeChatType.Group ? "group" : "meeting"; } }
    }

    public sealed class FakeChannel : FakeThread
    {
        public FakeTeam Team;
        public string DisplayName, Description;
        public FakeChannelType ChannelType;
        /// <summary>Members of a private / shared channel (a standard channel exposes the team's members).</summary>
        public readonly List<FakeMember> Members = new List<FakeMember>();
        public FakeDrive Drive;         // private and shared channels have their own site; standard ones use the team drive
        public string FolderName { get { return DisplayName; } }
        public string TypeName { get { return ChannelType == FakeChannelType.Standard ? "standard" : ChannelType == FakeChannelType.Private ? "private" : "shared"; } }
        public string Key { get { return Team.Id + "/" + Id; } }
        public bool IsGeneral;
    }

    public sealed class FakeTeam
    {
        public int Ordinal;
        public string Id, DisplayName, Description, Visibility = "private";
        public long CreatedMs;
        public string MigrationMode, MigrationOwnerAppId;
        public readonly List<FakeChannel> Channels = new List<FakeChannel>();
        public readonly List<FakeMember> Members = new List<FakeMember>();
        public FakeDrive Drive;
        public string SiteSlug;
    }

    public sealed class FakeAttachment
    {
        public string Id, ContentType, ContentUrl, Name, Content, ThumbnailUrl;
        public const string Reference = "reference";
        public const string AdaptiveCard = "application/vnd.microsoft.card.adaptive";
        public const string HeroCard = "application/vnd.microsoft.card.hero";
        public const string MessageReference = "messageReference";
    }

    public sealed class FakeMention
    {
        public int Id;
        public string Text;
        /// <summary>"user" | "channel" | "team" | "tag".</summary>
        public string Kind = "user";
        public int UserOrd = -1;
        public string TargetId, TargetName;
    }

    public struct FakeReaction
    {
        public string Type;
        public int UserOrd;
        public long CreatedMs;
    }

    public sealed class FakeHostedContent
    {
        public string Id, ContentType;
        public byte[] Bytes;            // may be shared between many messages (small pool of images)
    }

    /// <summary>The rare parts of a message, allocated only when needed.</summary>
    public sealed class FakeMessageExtras
    {
        /// <summary>Explicit HTML/text body; null means "render from the seed".</summary>
        public string Body;
        public long ReplyTo, EditedMs, DeletedMs;
        public string Subject, Importance, EventDetailJson, FromApplication;
        public FakeAttachment[] Attachments;
        public FakeMention[] Mentions;
        public FakeReaction[] Reactions;
        public FakeHostedContent[] Hosted;
    }

    public sealed class FakeMessage
    {
        public const byte FlagText = 1;         // body.contentType = text (else html)
        public const byte FlagDeleted = 2;      // soft-deleted: empty body, deletedDateTime set
        public const byte FlagSystem = 4;       // messageType = systemEventMessage
        public const byte FlagImported = 8;     // created through the import API

        public long CreatedMs, ModifiedMs;
        public int AuthorOrd = -1;
        public int Seed;
        public byte Flags;
        public FakeMessageExtras X;

        public long Id { get { return CreatedMs; } }
        public long ReplyTo { get { return X == null ? 0 : X.ReplyTo; } }
        public bool IsDeleted { get { return (Flags & FlagDeleted) != 0; } }
        public FakeMessageExtras Ext() { return X ?? (X = new FakeMessageExtras()); }
    }

    // ------------------------------------------------------------------ drives

    public sealed class FakePermission
    {
        public string Id, LinkUrl, LinkType, LinkScope;
        public string[] Roles = new[] { "read" };
        public int UserOrd = -1;
        public string Email;
    }

    public sealed class FakeDriveItem
    {
        public string Id, DriveId, Name, ParentId, FolderPath, ContentType = "application/octet-stream", WebUrl, ETag;
        public bool IsFolder, Deleted, AccessDenied;
        public long Size, CreatedMs, ModifiedMs;
        public int CreatedByOrd = -1;
        /// <summary>Real bytes (small files, uploads); when null the content is the deterministic stream (Seed, Size).</summary>
        public byte[] Bytes;
        public ulong Seed;
        /// <summary>SHA-256 of an uploaded file whose bytes were not retained (above FakeTenant.MaxRetainedUploadBytes).</summary>
        public string UploadedSha256;
        public readonly List<FakePermission> Permissions = new List<FakePermission>();

        public Stream OpenRead()
        {
            if (Bytes != null) return new MemoryStream(Bytes, false);
            return new FakeContentStream(Seed, Size);
        }

        string _sha;
        public string Sha256Hex()
        {
            if (_sha != null) return _sha;
            if (UploadedSha256 != null) return _sha = UploadedSha256;
            using (var h = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
            using (var s = OpenRead())
            {
                var buf = new byte[81920]; int n;
                while ((n = s.Read(buf, 0, buf.Length)) > 0) h.AppendData(buf, 0, n);
                return _sha = Convert.ToHexString(h.GetHashAndReset()).ToLowerInvariant();
            }
        }
    }

    public sealed class FakeDrive
    {
        public string Id, Name, DriveType, WebUrlBase;
        public int OwnerUserOrd = -1;
        public string OwnerTeamId;
        public readonly Dictionary<string, FakeDriveItem> Items = new Dictionary<string, FakeDriveItem>();
        public readonly Dictionary<string, FakeDriveItem> ByPath = new Dictionary<string, FakeDriveItem>(StringComparer.OrdinalIgnoreCase);
        public FakeDriveItem Root;
    }

    // ------------------------------------------------------------------ tenant

    /// <summary>
    /// A whole fake tenant. Build it with the Add* methods (or SyntheticTenant) and hand it to FakeGraphTransport. Several transports
    /// (several "applications") can share one tenant: that is how a test makes two apps fight for the same migration thread.
    /// </summary>
    public sealed class FakeTenant
    {
        public readonly object Gate = new object();
        public string TenantId, Domain, ForeignTenantId;
        public readonly List<FakeUser> Users = new List<FakeUser>();
        public readonly Dictionary<string, FakeUser> UsersById = new Dictionary<string, FakeUser>(StringComparer.OrdinalIgnoreCase);
        public readonly Dictionary<string, FakeUser> UsersByUpn = new Dictionary<string, FakeUser>(StringComparer.OrdinalIgnoreCase);
        public readonly List<FakeChat> Chats = new List<FakeChat>();
        public readonly Dictionary<string, FakeChat> ChatsById = new Dictionary<string, FakeChat>(StringComparer.OrdinalIgnoreCase);
        public readonly Dictionary<string, FakeChat> OneOnOneByPair = new Dictionary<string, FakeChat>();
        public readonly Dictionary<int, List<FakeChat>> ChatsByUser = new Dictionary<int, List<FakeChat>>();
        public readonly List<FakeTeam> Teams = new List<FakeTeam>();
        public readonly Dictionary<string, FakeTeam> TeamsById = new Dictionary<string, FakeTeam>(StringComparer.OrdinalIgnoreCase);
        public readonly Dictionary<string, FakeDrive> Drives = new Dictionary<string, FakeDrive>(StringComparer.OrdinalIgnoreCase);
        public readonly Dictionary<string, FakeDriveItem> ItemsById = new Dictionary<string, FakeDriveItem>(StringComparer.OrdinalIgnoreCase);
        public readonly Dictionary<string, FakeDriveItem> ItemsByUrl = new Dictionary<string, FakeDriveItem>(StringComparer.OrdinalIgnoreCase);

        // ---- behaviours of the real service that the options below can flip (each one is documented in FakeGraphTransport) ----
        /// <summary>Does the import API accept a message whose author is a deleted account? The real service refuses it (400), so the default is false.</summary>
        public bool DeletedAuthorsAccepted = false;
        /// <summary>Max body size of an imported message in bytes (the Teams limit is about 28 KB).</summary>
        public int MaxBodyBytes = 28 * 1024;
        public int MaxReactions = 250;
        /// <summary>Evaluation mode (getAllMessages without a valid model): at most this many messages per query, then the data ends.</summary>
        public int EvaluationModeMaxMessages = 500;
        /// <summary>Whether GET /teams answers (the documented way is groups?$filter=resourceProvisioningOptions/Any(x:x eq 'Team')).</summary>
        public bool TeamsListEndpointEnabled = true;
        public long MaxRetainedUploadBytes = 64L * 1024 * 1024;

        /// <summary>The service's wall clock (createdDateTime in the future is rejected against it). Synthetic tenants pin it after their data.</summary>
        public Func<DateTimeOffset> Clock = () => DateTimeOffset.UtcNow;
        public long NowMs { get { return FakeTime.ToMs(Clock()); } }

        public readonly FakeRng Ids;
        long _messageCount;

        public FakeTenant(int seed = 1, string domain = "contoso.com")
        {
            Ids = new FakeRng(seed * 7919L + 17);
            Domain = domain;
            TenantId = Ids.NextGuid().ToString();
            ForeignTenantId = Ids.NextGuid().ToString();
        }

        public string NewGuid() { return Ids.NextGuid().ToString(); }

        public long MessageCount
        {
            get
            {
                long n = 0;
                foreach (var c in Chats) n += c.Messages.Count;
                foreach (var t in Teams) foreach (var ch in t.Channels) n += ch.Messages.Count;
                _messageCount = n;
                return n;
            }
        }

        // ---- users
        public FakeUser AddUser(string upn, string displayName, bool deleted = false, bool external = false, string userType = null, string id = null)
        {
            var u = new FakeUser
            {
                Ordinal = Users.Count, Id = id ?? NewGuid(), Upn = upn, DisplayName = displayName, Mail = upn,
                TenantId = external ? ForeignTenantId : TenantId, Deleted = deleted, External = external,
                DeletedMs = deleted ? NowMs : 0, UserType = userType ?? (external ? "Guest" : "Member")
            };
            var parts = (displayName ?? "").Split(new[] { ' ' }, 2);
            u.GivenName = parts[0]; u.Surname = parts.Length > 1 ? parts[1] : "";
            Users.Add(u); UsersById[u.Id] = u; UsersByUpn[upn] = u;
            return u;
        }

        public FakeUser FindUser(string idOrUpn)
        {
            FakeUser u;
            if (idOrUpn != null && (UsersById.TryGetValue(idOrUpn, out u) || UsersByUpn.TryGetValue(idOrUpn, out u))) return u;
            return null;
        }

        // ---- chats
        public FakeChat AddChat(FakeChatType type, IList<FakeUser> members, string topic, DateTimeOffset created, string lang = "fr", string id = null)
        {
            return AddChatMs(type, members, topic, FakeTime.ToMs(created), lang, id);
        }

        public FakeChat AddChatMs(FakeChatType type, IList<FakeUser> members, string topic, long createdMs, string lang = "fr", string id = null)
        {
            var chat = new FakeChat { ChatType = type, Topic = topic, CreatedMs = createdMs, LastUpdatedMs = createdMs, Lang = lang, Ordinal = Chats.Count };
            if (id == null)
            {
                if (type == FakeChatType.OneOnOne && members.Count == 2)
                {
                    var a = members[0].Id; var b = members[1].Id;
                    if (string.CompareOrdinal(a, b) > 0) { var t = a; a = b; b = t; }
                    id = "19:" + a + "_" + b + "@unq.gbl.spaces";
                }
                else if (type == FakeChatType.Meeting)
                    id = "19:meeting_" + Convert.ToBase64String(Guid.Parse(NewGuid()).ToByteArray()).TrimEnd('=').Replace('/', '_').Replace('+', '-') + "@thread.v2";
                else id = "19:" + NewGuid().Replace("-", "") + "@thread.v2";
            }
            chat.Id = id;
            if (type == FakeChatType.Meeting) chat.MeetingJoinUrl = "https://teams.microsoft.com/l/meetup-join/" + Uri.EscapeDataString(id) + "/0";
            foreach (var m in members) AttachMember(chat, m, FakeMember.AllHistory, "");
            if (type == FakeChatType.OneOnOne && members.Count == 2)
            {
                chat.PairKey = PairKey(members[0].Ordinal, members[1].Ordinal);
                OneOnOneByPair[chat.PairKey] = chat;
            }
            Chats.Add(chat); ChatsById[chat.Id] = chat;
            return chat;
        }

        public static string PairKey(int a, int b) { return a < b ? a + ":" + b : b + ":" + a; }

        public FakeMember AttachMember(FakeChat chat, FakeUser u, long visibleHistoryStartMs, string roles)
        {
            var m = new FakeMember { UserOrd = u.Ordinal, VisibleHistoryStartMs = visibleHistoryStartMs, Roles = roles ?? "" };
            chat.Members.Add(m);
            List<FakeChat> l;
            if (!ChatsByUser.TryGetValue(u.Ordinal, out l)) ChatsByUser[u.Ordinal] = l = new List<FakeChat>();
            l.Add(chat);
            chat.Touch();
            return m;
        }

        public bool DetachMember(FakeChat chat, int userOrd)
        {
            int i = chat.Members.FindIndex(x => x.UserOrd == userOrd);
            if (i < 0) return false;
            chat.Members.RemoveAt(i);
            List<FakeChat> l;
            if (ChatsByUser.TryGetValue(userOrd, out l)) l.Remove(chat);
            chat.Touch();
            return true;
        }

        public static string MembershipId(int threadOrd, int userOrd)
        {
            return string.Format("{0:x8}-0000-4000-8000-{1:x12}", threadOrd, userOrd);
        }

        // ---- teams and channels
        public FakeTeam AddTeam(string name, IEnumerable<FakeUser> members, DateTimeOffset created, string description = null, string id = null)
        {
            var t = new FakeTeam { Ordinal = Teams.Count, Id = id ?? NewGuid(), DisplayName = name, Description = description ?? "", CreatedMs = FakeTime.ToMs(created) };
            t.SiteSlug = new string(name.ToLowerInvariant().Normalize(NormalizationForm.FormD).Where(ch => char.IsLetterOrDigit(ch) && ch < 128).ToArray());
            if (t.SiteSlug.Length == 0) t.SiteSlug = "team" + t.Ordinal;
            bool first = true;
            if (members != null)
                foreach (var u in members) { t.Members.Add(new FakeMember { UserOrd = u.Ordinal, Roles = first ? "owner" : "" }); first = false; }
            Teams.Add(t); TeamsById[t.Id] = t;
            t.Drive = NewDrive("documentLibrary", "Documents", -1, t.Id, "https://" + Domain.Split('.')[0] + ".sharepoint.com/sites/" + t.SiteSlug + "/Shared Documents");
            return t;
        }

        public FakeChannel AddChannel(FakeTeam team, string name, FakeChannelType type, IEnumerable<FakeUser> members, DateTimeOffset created, string description = null)
        {
            var ch = new FakeChannel
            {
                Team = team, Id = "19:" + NewGuid().Replace("-", "") + "@thread.tacv2", DisplayName = name, Description = description ?? "",
                ChannelType = type, CreatedMs = FakeTime.ToMs(created), Ordinal = team.Channels.Count, IsGeneral = team.Channels.Count == 0, Lang = "fr"
            };
            if (members != null && type != FakeChannelType.Standard)
            {
                bool first = true;
                foreach (var u in members) { ch.Members.Add(new FakeMember { UserOrd = u.Ordinal, Roles = first ? "owner" : "" }); first = false; }
            }
            if (type != FakeChannelType.Standard)
                ch.Drive = NewDrive("documentLibrary", "Documents", -1, team.Id, "https://" + Domain.Split('.')[0] + ".sharepoint.com/sites/" + team.SiteSlug + "-" + Slug(name) + "/Shared Documents");
            else ch.Drive = team.Drive;
            team.Channels.Add(ch);
            EnsureFolder(ch.Drive, "/" + ch.FolderName, created);
            return ch;
        }

        static string Slug(string s)
        {
            var sb = new StringBuilder();
            foreach (char c in s.ToLowerInvariant().Normalize(NormalizationForm.FormD)) if (char.IsLetterOrDigit(c) && c < 128) sb.Append(c);
            return sb.Length == 0 ? "ch" : sb.ToString();
        }

        // ---- drives
        public FakeDrive NewDrive(string type, string name, int ownerUserOrd, string ownerTeamId, string webUrlBase)
        {
            var d = new FakeDrive { Id = "b!" + Convert.ToBase64String(Guid.Parse(NewGuid()).ToByteArray()).TrimEnd('=').Replace('/', '_').Replace('+', '-'), Name = name, DriveType = type, OwnerUserOrd = ownerUserOrd, OwnerTeamId = ownerTeamId, WebUrlBase = webUrlBase };
            d.Root = new FakeDriveItem { Id = "01" + NewGuid().Replace("-", "").ToUpperInvariant().Substring(0, 30), DriveId = d.Id, Name = "root", IsFolder = true, FolderPath = "", CreatedMs = NowMs, ModifiedMs = NowMs, WebUrl = webUrlBase };
            d.Items[d.Root.Id] = d.Root; d.ByPath["/"] = d.Root; ItemsById[d.Root.Id] = d.Root;
            Drives[d.Id] = d;
            return d;
        }

        /// <summary>The user's OneDrive (created on first use).</summary>
        public FakeDrive UserDrive(FakeUser u)
        {
            if (u.Drive != null) return u.Drive;
            var slug = u.Upn.Replace('@', '_').Replace('.', '_');
            u.Drive = NewDrive("business", "OneDrive", u.Ordinal, null, "https://" + Domain.Split('.')[0] + "-my.sharepoint.com/personal/" + slug + "/Documents");
            return u.Drive;
        }

        public FakeDriveItem EnsureFolder(FakeDrive d, string path, DateTimeOffset? when = null)
        {
            path = NormalizePath(path);
            FakeDriveItem it;
            if (d.ByPath.TryGetValue(path, out it)) return it;
            int cut = path.LastIndexOf('/');
            var parent = EnsureFolder(d, cut <= 0 ? "/" : path.Substring(0, cut), when);
            long ms = when.HasValue ? FakeTime.ToMs(when.Value) : NowMs;
            it = new FakeDriveItem
            {
                Id = "01" + NewGuid().Replace("-", "").ToUpperInvariant().Substring(0, 30), DriveId = d.Id, Name = path.Substring(cut + 1), ParentId = parent.Id,
                FolderPath = parent.FolderPath + (parent == d.Root ? "" : "/" + parent.Name), IsFolder = true, CreatedMs = ms, ModifiedMs = ms,
                WebUrl = d.WebUrlBase + EscapePath(path)
            };
            Register(d, it, path);
            return it;
        }

        public static string EscapePath(string p) { return string.Join("/", p.Split((char)47).Select(Uri.EscapeDataString)); }

        public static string NormalizePath(string p)
        {
            p = (p ?? "").Replace('\\', '/').Trim();
            if (!p.StartsWith("/")) p = "/" + p;
            while (p.Length > 1 && p.EndsWith("/")) p = p.Substring(0, p.Length - 1);
            return p;
        }

        void Register(FakeDrive d, FakeDriveItem it, string fullPath)
        {
            d.Items[it.Id] = it; d.ByPath[fullPath] = it; ItemsById[it.Id] = it;
            ItemsByUrl[NormUrl(it.WebUrl)] = it;
        }

        public static string NormUrl(string url) { try { return Uri.UnescapeDataString(url ?? "").TrimEnd('/'); } catch { return url ?? ""; } }

        /// <summary>Adds (or replaces) a file whose content is the deterministic stream (seed, size).</summary>
        public FakeDriveItem AddGeneratedFile(FakeDrive d, string folder, string name, long size, ulong seed, FakeUser author, DateTimeOffset created, string contentType = null)
        {
            return AddFileCore(d, folder, name, size, seed, null, author, FakeTime.ToMs(created), contentType);
        }

        public FakeDriveItem AddFile(FakeDrive d, string folder, string name, byte[] bytes, FakeUser author, DateTimeOffset created, string contentType = null)
        {
            return AddFileCore(d, folder, name, bytes.Length, 0, bytes, author, FakeTime.ToMs(created), contentType);
        }

        public FakeDriveItem AddFileCore(FakeDrive d, string folder, string name, long size, ulong seed, byte[] bytes, FakeUser author, long createdMs, string contentType)
        {
            folder = NormalizePath(folder);
            var parent = EnsureFolder(d, folder, FakeTime.FromMs(createdMs));
            string full = folder == "/" ? "/" + name : folder + "/" + name;
            FakeDriveItem old;
            if (d.ByPath.TryGetValue(full, out old)) { d.Items.Remove(old.Id); ItemsById.Remove(old.Id); ItemsByUrl.Remove(NormUrl(old.WebUrl)); }
            var it = new FakeDriveItem
            {
                Id = "01" + NewGuid().Replace("-", "").ToUpperInvariant().Substring(0, 30), DriveId = d.Id, Name = name, ParentId = parent.Id,
                FolderPath = folder == "/" ? "" : folder, Size = size, Seed = seed, Bytes = bytes, CreatedByOrd = author == null ? -1 : author.Ordinal,
                CreatedMs = createdMs, ModifiedMs = createdMs, ContentType = contentType ?? GuessContentType(name),
                WebUrl = d.WebUrlBase + EscapePath(full)
            };
            it.ETag = "\"{" + it.Id.Substring(2, 8) + "},1\"";
            Register(d, it, full);
            return it;
        }

        public static string GuessContentType(string name)
        {
            var ext = Path.GetExtension(name ?? "").ToLowerInvariant();
            switch (ext)
            {
                case ".docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
                case ".xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
                case ".pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation";
                case ".pdf": return "application/pdf";
                case ".png": return "image/png";
                case ".jpg": case ".jpeg": return "image/jpeg";
                case ".txt": return "text/plain";
                case ".csv": return "text/csv";
                case ".zip": return "application/zip";
                case ".mp4": return "video/mp4";
                default: return "application/octet-stream";
            }
        }

        public void RemoveItem(FakeDriveItem it)
        {
            it.Deleted = true;
        }

        // ---- lookups used by the transport
        public FakeThread FindThreadByKey(string key)
        {
            FakeChat c;
            if (ChatsById.TryGetValue(key, out c)) return c;
            int i = key.IndexOf('/');
            FakeTeam t;
            if (i > 0 && TeamsById.TryGetValue(key.Substring(0, i), out t))
                return t.Channels.Find(x => string.Equals(x.Id, key.Substring(i + 1), StringComparison.OrdinalIgnoreCase));
            return null;
        }
    }
}
