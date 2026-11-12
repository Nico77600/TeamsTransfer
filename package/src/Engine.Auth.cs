// =============================================================================
//  TeamsTransfer - engine, part 1: app-only authentication (client credentials, no MSAL)
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.0.1
//
//  Why this file exists, and why there is no MSAL here:
//    The export and the import run unattended, app-only (Chat.Read.All, Teamwork.Migrate.All...), for days.
//    The OAuth 2.0 client-credentials flow is one POST to the token endpoint; MSAL would add a dependency (and
//    its cache, its broker, its own HTTP stack) for nothing. So the flow is written directly, in ~200 lines:
//      - CertificateTokenProvider (production): signs a JWT client assertion (RS256) with the certificate private
//        key. No secret is ever stored in a file or a config; the key stays in the Windows certificate store.
//      - ClientSecretTokenProvider (LAB ONLY): same flow with client_secret. A secret has no place in a
//        production run; it exists so that a lab can be driven without issuing a certificate.
//    Both cache the access token in memory, refresh it 5 minutes before it expires, and allow a single refresh at
//    a time (SemaphoreSlim) however many workers ask at once. The HTTP call goes through an injectable HttpClient
//    so that the tests run offline.
//
//  Never logged, never put in an exception message: the token, the secret, the assertion. Error messages carry
//  the AAD error code and description only (AADSTS codes are what an operator needs).
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace TeamsTransfer
{
    /// <summary>The token endpoint refused the request or could not be reached. Carries no secret.</summary>
    public sealed class AuthException : Exception
    {
        public int StatusCode { get; }
        public string ErrorCode { get; }
        public string CorrelationId { get; }

        public AuthException(int statusCode, string errorCode, string message, string correlationId, Exception inner = null)
            : base($"Token request failed ({statusCode} {errorCode}): {message}", inner)
        {
            StatusCode = statusCode;
            ErrorCode = errorCode;
            CorrelationId = correlationId;
        }
    }

    /// <summary>Shared part: cache, refresh margin, single-flight refresh, token endpoint call.</summary>
    /// <summary>Optional capability of a token provider: forget a token the server rejected (401).</summary>
    public interface IInvalidatableTokenProvider : IAccessTokenProvider
    {
        void InvalidateToken(string rejectedToken);
    }

    public abstract class ClientCredentialsTokenProvider : IInvalidatableTokenProvider
    {
        private sealed class CachedToken
        {
            public string Value;
            public DateTimeOffset ExpiresAt;
        }

        private static readonly Lazy<HttpClient> DefaultHttp =
            new Lazy<HttpClient>(() => new HttpClient { Timeout = TimeSpan.FromSeconds(60) });

        /// <summary>The token is renewed when less than this remains before expiry.</summary>
        public static readonly TimeSpan RefreshMargin = TimeSpan.FromMinutes(5);
        private const int MaxTokenAttempts = 3;

        private readonly SemaphoreSlim _refresh = new SemaphoreSlim(1, 1);
        private readonly HttpClient _http;
        private readonly IClock _clock;
        private CachedToken _cached;

        public string TenantId { get; }
        public string ClientId { get; }
        public GraphCloud Cloud { get; }
        /// <summary>https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token (also the JWT audience).</summary>
        public string TokenEndpoint { get; }
        public string Scope { get; }
        /// <summary>Number of requests actually sent to the token endpoint (diagnostics/tests).</summary>
        public int TokenRequestCount { get; private set; }

        protected ClientCredentialsTokenProvider(string tenantId, string clientId, GraphCloud cloud, HttpClient http, IClock clock)
        {
            if (string.IsNullOrWhiteSpace(tenantId)) throw new ArgumentException("tenantId is required", nameof(tenantId));
            if (string.IsNullOrWhiteSpace(clientId)) throw new ArgumentException("clientId is required", nameof(clientId));
            TenantId = tenantId;
            ClientId = clientId;
            Cloud = cloud;
            _http = http ?? DefaultHttp.Value;
            _clock = clock ?? SystemClock.Instance;
            TokenEndpoint = GraphCloudEndpoints.Authority(cloud) + "/" + Uri.EscapeDataString(tenantId) + "/oauth2/v2.0/token";
            Scope = GraphCloudEndpoints.GraphRoot(cloud) + "/.default";
        }

        /// <summary>The credential-specific form fields (client_assertion... or client_secret).</summary>
        protected abstract IEnumerable<KeyValuePair<string, string>> CredentialFields();

        public async Task<string> GetTokenAsync(CancellationToken cancellationToken)
        {
            var c = Volatile.Read(ref _cached);
            if (c != null && _clock.UtcNow < c.ExpiresAt - RefreshMargin) return c.Value;

            await _refresh.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                c = Volatile.Read(ref _cached);
                if (c != null && _clock.UtcNow < c.ExpiresAt - RefreshMargin) return c.Value;
                var fresh = await RequestTokenAsync(cancellationToken).ConfigureAwait(false);
                Volatile.Write(ref _cached, fresh);
                return fresh.Value;
            }
            finally { _refresh.Release(); }
        }

        /// <summary>Forgets the cached token (e.g. after a 401 that says the token was revoked).</summary>
        public void Invalidate() { Volatile.Write(ref _cached, null); }

        /// <summary>Drops the cached token only if it is still the rejected one: N concurrent 401s on the same token cause one refresh.</summary>
        public void InvalidateToken(string rejectedToken)
        {
            var c = Volatile.Read(ref _cached);
            if (c != null && string.Equals(c.Value, rejectedToken, StringComparison.Ordinal))
                Interlocked.CompareExchange(ref _cached, null, c);
        }

        private async Task<CachedToken> RequestTokenAsync(CancellationToken ct)
        {
            for (int attempt = 1; ; attempt++)
            {
                var fields = new List<KeyValuePair<string, string>>
                {
                    new KeyValuePair<string, string>("grant_type", "client_credentials"),
                    new KeyValuePair<string, string>("client_id", ClientId),
                    new KeyValuePair<string, string>("scope", Scope)
                };
                fields.AddRange(CredentialFields());

                HttpResponseMessage resp = null;
                string body = null;
                Exception network = null;
                try
                {
                    TokenRequestCount++;
                    using (var req = new HttpRequestMessage(HttpMethod.Post, TokenEndpoint) { Content = new FormUrlEncodedContent(fields) })
                    {
                        resp = await _http.SendAsync(req, ct).ConfigureAwait(false);
                        body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
                    }
                }
                catch (Exception ex) when ((ex is HttpRequestException || ex is System.IO.IOException ||
                    (ex is OperationCanceledException && !ct.IsCancellationRequested)))
                {
                    network = ex;
                }

                if (network == null)
                {
                    int status = (int)resp.StatusCode;
                    string correlation = null;
                    IEnumerable<string> vals;
                    if (resp.Headers.TryGetValues("x-ms-request-id", out vals)) foreach (var v in vals) { correlation = v; break; }
                    resp.Dispose();

                    if (status >= 200 && status < 300) return ParseToken(body, status, correlation);

                    string code, desc;
                    ParseError(body, out code, out desc);
                    bool transient = status == 429 || status >= 500;
                    if (!transient || attempt >= MaxTokenAttempts)
                        throw new AuthException(status, code ?? "token_error", desc ?? "The token endpoint returned an error.", correlation);
                }
                else if (attempt >= MaxTokenAttempts)
                {
                    throw new AuthException(0, "network_error", network.GetType().Name, null, network);
                }

                await _clock.DelayAsync(TimeSpan.FromSeconds(attempt * 2), ct).ConfigureAwait(false);
            }
        }

        private CachedToken ParseToken(string body, int status, string correlation)
        {
            try
            {
                using (var doc = JsonDocument.Parse(body))
                {
                    var root = doc.RootElement;
                    string token = root.GetProperty("access_token").GetString();
                    double expiresIn = 3600;
                    JsonElement e;
                    if (root.TryGetProperty("expires_in", out e))
                    {
                        if (e.ValueKind == JsonValueKind.Number) expiresIn = e.GetDouble();
                        else if (e.ValueKind == JsonValueKind.String)
                            double.TryParse(e.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out expiresIn);
                    }
                    if (string.IsNullOrEmpty(token)) throw new AuthException(status, "empty_token", "The token endpoint returned no access_token.", correlation);
                    return new CachedToken { Value = token, ExpiresAt = _clock.UtcNow.AddSeconds(expiresIn) };
                }
            }
            catch (Exception ex) when (ex is JsonException || ex is KeyNotFoundException || ex is InvalidOperationException)
            {
                // Do not echo the body: it may contain the token.
                throw new AuthException(status, "invalid_token_response", "The token endpoint answer could not be parsed.", correlation);
            }
        }

        private static void ParseError(string body, out string code, out string description)
        {
            code = null; description = null;
            if (string.IsNullOrWhiteSpace(body)) return;
            try
            {
                using (var doc = JsonDocument.Parse(body))
                {
                    JsonElement e;
                    if (doc.RootElement.TryGetProperty("error", out e) && e.ValueKind == JsonValueKind.String) code = e.GetString();
                    if (doc.RootElement.TryGetProperty("error_description", out e) && e.ValueKind == JsonValueKind.String)
                    {
                        description = e.GetString();
                        int nl = description.IndexOf('\r');
                        if (nl < 0) nl = description.IndexOf('\n');
                        if (nl > 0) description = description.Substring(0, nl);   // first line: "AADSTS...: message."
                        if (description.Length > 400) description = description.Substring(0, 400);
                    }
                }
            }
            catch (JsonException) { }
        }
    }

    /// <summary>Certificate credential: RS256 JWT client assertion. The production provider.</summary>
    public sealed class CertificateTokenProvider : ClientCredentialsTokenProvider
    {
        private readonly X509Certificate2 _cert;
        private readonly IClock _assertionClock;

        public CertificateTokenProvider(string tenantId, string clientId, X509Certificate2 certificate,
            GraphCloud cloud = GraphCloud.Global, HttpClient http = null, IClock clock = null)
            : base(tenantId, clientId, cloud, http, clock)
        {
            if (certificate == null) throw new ArgumentNullException(nameof(certificate));
            if (!certificate.HasPrivateKey) throw new ArgumentException("The certificate has no private key.", nameof(certificate));
            _cert = certificate;
            _assertionClock = clock ?? SystemClock.Instance;
        }

        /// <summary>Loads the certificate with its private key from Cert:\CurrentUser\My, then Cert:\LocalMachine\My.</summary>
        public static X509Certificate2 FindCertificate(string thumbprint)
        {
            if (string.IsNullOrWhiteSpace(thumbprint)) throw new ArgumentException("thumbprint is required", nameof(thumbprint));
            // Thumbprints copied from the MMC carry an invisible U+200E and spaces.
            var clean = new StringBuilder();
            foreach (char ch in thumbprint) if (Uri.IsHexDigit(ch)) clean.Append(char.ToUpperInvariant(ch));
            string tp = clean.ToString();

            X509Certificate2 withoutKey = null;
            foreach (var location in new[] { StoreLocation.CurrentUser, StoreLocation.LocalMachine })
            {
                using (var store = new X509Store(StoreName.My, location))
                {
                    store.Open(OpenFlags.ReadOnly | OpenFlags.OpenExistingOnly);
                    var found = store.Certificates.Find(X509FindType.FindByThumbprint, tp, false);
                    foreach (var c in found)
                    {
                        if (c.HasPrivateKey) return c;
                        if (withoutKey == null) withoutKey = c;
                    }
                }
            }
            if (withoutKey != null)
                throw new InvalidOperationException("Certificate " + tp + " was found but has no accessible private key (check the key ACL for this account).");
            throw new InvalidOperationException("Certificate " + tp + " not found in CurrentUser\\My or LocalMachine\\My.");
        }

        public static CertificateTokenProvider FromThumbprint(string tenantId, string clientId, string thumbprint,
            GraphCloud cloud = GraphCloud.Global, HttpClient http = null)
        {
            return new CertificateTokenProvider(tenantId, clientId, FindCertificate(thumbprint), cloud, http);
        }

        public string CertificateThumbprint => _cert.Thumbprint;

        private static string B64Url(byte[] data)
        {
            return Convert.ToBase64String(data).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        }

        /// <summary>Builds a fresh signed client assertion (JWT, RS256, valid 10 minutes).</summary>
        public string BuildClientAssertion()
        {
            byte[] raw = _cert.RawData;
            byte[] sha1, sha256;
            using (var h1 = SHA1.Create()) sha1 = h1.ComputeHash(raw);
            using (var h2 = SHA256.Create()) sha256 = h2.ComputeHash(raw);

            long now = _assertionClock.UtcNow.ToUnixTimeSeconds();
            string header = "{\"alg\":\"RS256\",\"typ\":\"JWT\",\"x5t\":\"" + B64Url(sha1) + "\",\"x5t#S256\":\"" + B64Url(sha256) + "\"}";

            var ms = new System.IO.MemoryStream();
            using (var w = new Utf8JsonWriter(ms))
            {
                w.WriteStartObject();
                w.WriteString("aud", TokenEndpoint);
                w.WriteString("iss", ClientId);
                w.WriteString("sub", ClientId);
                w.WriteString("jti", Guid.NewGuid().ToString());
                w.WriteNumber("nbf", now);
                w.WriteNumber("exp", now + 600);
                w.WriteEndObject();
            }
            string signingInput = B64Url(Encoding.UTF8.GetBytes(header)) + "." + B64Url(ms.ToArray());

            using (RSA rsa = _cert.GetRSAPrivateKey())
            {
                if (rsa == null) throw new InvalidOperationException("The certificate private key is not an RSA key.");
                byte[] sig = rsa.SignData(Encoding.ASCII.GetBytes(signingInput), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                return signingInput + "." + B64Url(sig);
            }
        }

        protected override IEnumerable<KeyValuePair<string, string>> CredentialFields()
        {
            yield return new KeyValuePair<string, string>("client_assertion_type", "urn:ietf:params:oauth:client-assertion-type:jwt-bearer");
            yield return new KeyValuePair<string, string>("client_assertion", BuildClientAssertion());
        }
    }

    /// <summary>
    /// LAB ONLY. Client secret credential. A secret in a production run is a finding: use CertificateTokenProvider.
    /// The secret is held as a SecureString, converted to a managed string only for the duration of one token
    /// request, and never logged or put in a message.
    /// </summary>
    public sealed class ClientSecretTokenProvider : ClientCredentialsTokenProvider
    {
        private readonly SecureString _secret;

        public ClientSecretTokenProvider(string tenantId, string clientId, SecureString clientSecret,
            GraphCloud cloud = GraphCloud.Global, HttpClient http = null, IClock clock = null)
            : base(tenantId, clientId, cloud, http, clock)
        {
            if (clientSecret == null || clientSecret.Length == 0) throw new ArgumentException("clientSecret is required", nameof(clientSecret));
            _secret = clientSecret.Copy();
            _secret.MakeReadOnly();
        }

        public ClientSecretTokenProvider(string tenantId, string clientId, string clientSecret,
            GraphCloud cloud = GraphCloud.Global, HttpClient http = null, IClock clock = null)
            : this(tenantId, clientId, ToSecure(clientSecret), cloud, http, clock) { }

        private static SecureString ToSecure(string s)
        {
            if (string.IsNullOrEmpty(s)) throw new ArgumentException("clientSecret is required", nameof(s));
            var ss = new SecureString();
            foreach (char c in s) ss.AppendChar(c);
            ss.MakeReadOnly();
            return ss;
        }

        protected override IEnumerable<KeyValuePair<string, string>> CredentialFields()
        {
            IntPtr p = IntPtr.Zero;
            string plain;
            try
            {
                p = Marshal.SecureStringToGlobalAllocUnicode(_secret);
                plain = Marshal.PtrToStringUni(p);
            }
            finally { if (p != IntPtr.Zero) Marshal.ZeroFreeGlobalAllocUnicode(p); }
            return new[] { new KeyValuePair<string, string>("client_secret", plain) };
        }
    }
}
