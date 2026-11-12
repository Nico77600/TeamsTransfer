// =============================================================================
//  TeamsTransfer - engine: shared contracts
// -----------------------------------------------------------------------------
//  The single seam between the engine and Microsoft Graph. Everything that talks to Graph goes through
//  IGraphTransport: the real HttpGraphTransport (Engine.Graph.cs) in production, FakeGraphTransport
//  (tests\support) in the offline tests, the demo mode and the volume tests. A transport is "dumb": one
//  request in, one response out, no retry, no paging, no throttling. Retries, Retry-After, paging and the
//  adaptive rate limiter live above it, in GraphClient, so that the fake exercises the real logic.
//
//  OWNERSHIP: this file is owned by the coordinator. Agents do not change it; a needed change is reported.
// =============================================================================
using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace TeamsTransfer
{
    /// <summary>Microsoft cloud the tenant lives in. Selects the authority host and the Graph root.</summary>
    public enum GraphCloud { Global, USGov, USGovDoD, China }

    public static class GraphCloudEndpoints
    {
        public static string Authority(GraphCloud cloud)
        {
            switch (cloud)
            {
                case GraphCloud.USGov:
                case GraphCloud.USGovDoD: return "https://login.microsoftonline.us";
                case GraphCloud.China: return "https://login.chinacloudapi.cn";
                default: return "https://login.microsoftonline.com";
            }
        }

        public static string GraphRoot(GraphCloud cloud)
        {
            switch (cloud)
            {
                case GraphCloud.USGov: return "https://graph.microsoft.us";
                case GraphCloud.USGovDoD: return "https://dod-graph.microsoft.us";
                case GraphCloud.China: return "https://microsoftgraph.chinacloudapi.cn";
                default: return "https://graph.microsoft.com";
            }
        }
    }

    /// <summary>
    /// One HTTP request to Graph. Url is either absolute (an @odata.nextLink) or relative to the Graph root
    /// including the version segment, e.g. "v1.0/chats/19:abc@thread.v2/messages?$top=50".
    /// Exactly one of BodyJson, BodyBytes, BodyStream is set for a request with a body.
    /// </summary>
    public sealed class GraphRequest
    {
        public HttpMethod Method { get; set; } = HttpMethod.Get;
        public string Url { get; set; }
        public string BodyJson { get; set; }
        public byte[] BodyBytes { get; set; }
        public Stream BodyStream { get; set; }
        /// <summary>Content type of a non-JSON body (BodyBytes/BodyStream), e.g. application/octet-stream.</summary>
        public string ContentType { get; set; }
        /// <summary>Extra headers (Content-Range of an upload session, Prefer, ConsistencyLevel...).</summary>
        public Dictionary<string, string> Headers { get; } = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        /// <summary>When true the bearer token is NOT added (pre-authenticated upload session URLs).</summary>
        public bool Anonymous { get; set; }
        /// <summary>Stable name of the endpoint family (see EndpointClass), used by the rate limiter and the logs.</summary>
        public string EndpointClass { get; set; }
        /// <summary>Key of the conversation (chat id, or teamId/channelId) for per-thread limits such as the 5 RPS of the import.</summary>
        public string ThreadKey { get; set; }
    }

    /// <summary>
    /// One HTTP response. Content is the raw body stream; the caller disposes the response.
    /// For a JSON answer use GraphResponse.ReadAsStringAsync or stream-parse Content.
    /// </summary>
    public sealed class GraphResponse : IDisposable
    {
        public int StatusCode { get; set; }
        public Dictionary<string, string> Headers { get; } = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        public Stream Content { get; set; } = Stream.Null;
        public string ContentType { get; set; }

        public bool IsSuccess => StatusCode >= 200 && StatusCode < 300;

        /// <summary>Retry-After header as a delay (seconds form or HTTP-date form), null when absent.</summary>
        public TimeSpan? RetryAfter
        {
            get
            {
                if (!Headers.TryGetValue("Retry-After", out var v) || string.IsNullOrWhiteSpace(v)) return null;
                if (double.TryParse(v, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var s))
                    return TimeSpan.FromSeconds(Math.Max(0, s));
                if (DateTimeOffset.TryParse(v, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AssumeUniversal, out var d))
                {
                    var delta = d - DateTimeOffset.UtcNow;
                    return delta < TimeSpan.Zero ? TimeSpan.Zero : delta;
                }
                return null;
            }
        }

        public async Task<string> ReadAsStringAsync()
        {
            using (var reader = new StreamReader(Content))
                return await reader.ReadToEndAsync().ConfigureAwait(false);
        }

        public void Dispose() => Content?.Dispose();
    }

    /// <summary>The only seam to Graph. Implementations: HttpGraphTransport (real), FakeGraphTransport (tests/demo).</summary>
    public interface IGraphTransport
    {
        Task<GraphResponse> SendAsync(GraphRequest request, CancellationToken cancellationToken);
    }

    /// <summary>App-only access token for one tenant (client credentials). Implementations cache and refresh.</summary>
    public interface IAccessTokenProvider
    {
        string TenantId { get; }
        Task<string> GetTokenAsync(CancellationToken cancellationToken);
    }

    /// <summary>Stable endpoint family names. Shared by the rate limiter, the logs, the fake and the reports.</summary>
    public static class EndpointClass
    {
        public const string Token = "token";
        public const string Users = "users";
        public const string UserChats = "users.chats";
        public const string ChatGetAllMessages = "users.chats.getAllMessages";
        public const string Chat = "chats";
        public const string ChatMembers = "chats.members";
        public const string ChatMessages = "chats.messages";
        public const string HostedContent = "hostedContents";
        public const string Teams = "teams";
        public const string Channels = "teams.channels";
        public const string ChannelMembers = "teams.channels.members";
        public const string ChannelGetAllMessages = "teams.channels.getAllMessages";
        public const string ChannelMessages = "teams.channels.messages";
        public const string ChannelReplies = "teams.channels.messages.replies";
        public const string DriveItem = "drive.items";
        public const string DriveContent = "drive.content";
        public const string DriveUpload = "drive.upload";
        public const string MigrationStart = "migration.start";
        public const string MigrationComplete = "migration.complete";
        public const string ImportMessage = "migration.importMessage";
        public const string Batch = "$batch";
        public const string Other = "other";
    }

    /// <summary>Error raised by GraphClient once retries are exhausted or for a non-retryable status.</summary>
    public sealed class GraphException : Exception
    {
        public int StatusCode { get; }
        public string ErrorCode { get; }
        public string RequestId { get; }
        public string Url { get; }

        public GraphException(int statusCode, string errorCode, string message, string requestId, string url, Exception inner = null)
            : base($"Graph {statusCode} {errorCode}: {message} (url: {url}, request-id: {requestId})", inner)
        {
            StatusCode = statusCode;
            ErrorCode = errorCode;
            RequestId = requestId;
            Url = url;
        }
    }
}
