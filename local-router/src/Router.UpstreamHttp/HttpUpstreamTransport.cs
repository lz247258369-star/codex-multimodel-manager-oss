using System.Net;
using System.Net.Http.Headers;
using Router.Core.Errors;
using Router.ProviderAdapters.Abstractions;

namespace Router.UpstreamHttp;

/// <summary>
/// Real loopback/HTTPS upstream transport. One transport owns an
/// <see cref="HttpClient"/>; adapters never create their own clients. It
/// enforces HTTPS (except explicit test-loopback HTTP), same-origin redirect
/// policy, per-stage timeout boundaries, cancellation, and safe-header
/// extraction.
/// </summary>
public sealed class HttpUpstreamTransport : IUpstreamTransport, IDisposable
{
    private const int MaxRedirects = 5;

    private readonly HttpClient _httpClient;
    private readonly bool _ownsClient;
    private bool _disposed;

    /// <summary>Creates a transport with a dedicated handler (HTTPS required, redirects manual).</summary>
    public HttpUpstreamTransport()
    {
        var handler = new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            UseCookies = false,
            AutomaticDecompression = DecompressionMethods.None,
        };
        _httpClient = new HttpClient(handler);
        _ownsClient = true;
    }

    /// <summary>Creates a transport over an injected handler (used by tests/guards).</summary>
    public HttpUpstreamTransport(HttpMessageHandler handler)
    {
        ArgumentNullException.ThrowIfNull(handler);
        _httpClient = new HttpClient(handler);
        _ownsClient = true;
    }

    public async Task<Result<UpstreamResponse, RouterError>> SendAsync(
        UpstreamRequest request,
        TimeoutBoundaries boundaries,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(boundaries);

        Uri currentUri = request.FullUri;
        IReadOnlyDictionary<string, string> headers = request.Headers;
        byte[]? body = request.Body;
        string? contentType = request.ContentType;
        int redirects = 0;

        using CancellationTokenSource totalCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        totalCts.CancelAfter(boundaries.TotalTimeout);

        try
        {
            while (true)
            {
                using HttpRequestMessage httpRequest = BuildRequest(request.Method, currentUri, headers, body, contentType);
                using CancellationTokenSource firstByteCts = CancellationTokenSource.CreateLinkedTokenSource(totalCts.Token);
                firstByteCts.CancelAfter(boundaries.FirstByteTimeout);

                HttpResponseMessage httpResponse;
                try
                {
                    httpResponse = await _httpClient.SendAsync(httpRequest, HttpCompletionOption.ResponseHeadersRead, firstByteCts.Token).ConfigureAwait(false);
                }
                catch (Exception exception)
                {
                    TimeoutStage stage = totalCts.IsCancellationRequested
                        ? TimeoutStage.Total
                        : cancellationToken.IsCancellationRequested
                            ? TimeoutStage.Connect
                            : firstByteCts.IsCancellationRequested
                                ? TimeoutStage.FirstByte
                                : TimeoutStage.Connect;
                    return new Result<UpstreamResponse, RouterError>
                    {
                        Error = TransportFailureMapper.MapException(exception, stage, cancellationToken.IsCancellationRequested),
                    };
                }

                if (IsRedirect(httpResponse.StatusCode))
                {
                    string? location = httpResponse.Headers.Location?.OriginalString;
                    httpResponse.Dispose();
                    if (string.IsNullOrWhiteSpace(location) || !Uri.TryCreate(location, UriKind.Absolute, out Uri? target))
                    {
                        return new Result<UpstreamResponse, RouterError> { Error = ProviderAdapterErrors.RedirectRejected() };
                    }

                    if (!request.Endpoint.AllowsRedirect(target))
                    {
                        return new Result<UpstreamResponse, RouterError> { Error = ProviderAdapterErrors.RedirectRejected() };
                    }

                    redirects++;
                    if (redirects > MaxRedirects)
                    {
                        return new Result<UpstreamResponse, RouterError> { Error = ProviderAdapterErrors.RedirectRejected() };
                    }

                    currentUri = target;
                    continue;
                }

                IReadOnlyDictionary<string, string> safeHeaders = UpstreamHeaderPolicy.ExtractSafeHeaders(httpResponse.Headers);
                Stream bodyStream;
                try
                {
                    bodyStream = await httpResponse.Content.ReadAsStreamAsync(firstByteCts.Token).ConfigureAwait(false);
                }
                catch (Exception exception)
                {
                    httpResponse.Dispose();
                    TimeoutStage readStage = totalCts.IsCancellationRequested
                        ? TimeoutStage.Total
                        : cancellationToken.IsCancellationRequested
                            ? TimeoutStage.Read
                            : TimeoutStage.Read;
                    return new Result<UpstreamResponse, RouterError>
                    {
                        Error = TransportFailureMapper.MapException(exception, readStage, cancellationToken.IsCancellationRequested),
                    };
                }

                Stream owned = new HttpResponseStream(bodyStream, httpResponse);
                return new Result<UpstreamResponse, RouterError>
                {
                    Value = new UpstreamResponse
                    {
                        StatusCode = (int)httpResponse.StatusCode,
                        SafeHeaders = safeHeaders,
                        Body = owned,
                    },
                };
            }
        }
        catch (Exception exception)
        {
            TimeoutStage stage = totalCts.IsCancellationRequested
                ? TimeoutStage.Total
                : cancellationToken.IsCancellationRequested
                    ? TimeoutStage.Read
                    : TimeoutStage.Read;
            return new Result<UpstreamResponse, RouterError>
            {
                Error = TransportFailureMapper.MapException(exception, stage, cancellationToken.IsCancellationRequested),
            };
        }
    }

    private static HttpRequestMessage BuildRequest(
        string method,
        Uri uri,
        IReadOnlyDictionary<string, string> headers,
        byte[]? body,
        string? contentType)
    {
        var request = new HttpRequestMessage(new HttpMethod(method), uri);
        foreach (KeyValuePair<string, string> header in headers)
        {
            if (header.Key.Equals("Authorization", StringComparison.OrdinalIgnoreCase))
            {
                request.Headers.TryAddWithoutValidation("Authorization", header.Value);
            }
            else if (!request.Headers.TryAddWithoutValidation(header.Key, header.Value))
            {
                request.Content ??= new ByteArrayContent(Array.Empty<byte>());
                request.Content.Headers.TryAddWithoutValidation(header.Key, header.Value);
            }
        }

        if (body is not null)
        {
            var content = new ByteArrayContent(body);
            if (!string.IsNullOrWhiteSpace(contentType))
            {
                content.Headers.ContentType = MediaTypeHeaderValue.Parse(contentType);
            }

            request.Content = content;
        }

        return request;
    }

    private static bool IsRedirect(HttpStatusCode statusCode)
        => statusCode is HttpStatusCode.MovedPermanently
            or HttpStatusCode.Found
            or HttpStatusCode.SeeOther
            or HttpStatusCode.TemporaryRedirect
            or HttpStatusCode.PermanentRedirect;

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        if (_ownsClient)
        {
            _httpClient.Dispose();
        }

        _disposed = true;
        GC.SuppressFinalize(this);
    }

    /// <summary>Stream that owns the underlying response until the body is consumed.</summary>
    private sealed class HttpResponseStream : Stream
    {
        private readonly Stream _inner;
        private readonly HttpResponseMessage _owner;
        private bool _disposed;

        public HttpResponseStream(Stream inner, HttpResponseMessage owner)
        {
            _inner = inner;
            _owner = owner;
        }

        public override bool CanRead => true;

        public override bool CanSeek => false;

        public override bool CanWrite => false;

        public override long Length => throw new NotSupportedException();

        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override int Read(byte[] buffer, int offset, int count)
            => _inner.Read(buffer, offset, count);

        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
            => await _inner.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);

        public override void Flush()
        {
        }

        public override long Seek(long offset, SeekOrigin origin)
            => throw new NotSupportedException();

        public override void SetLength(long value)
            => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count)
            => throw new NotSupportedException();

        protected override void Dispose(bool disposing)
        {
            if (_disposed)
            {
                return;
            }

            if (disposing)
            {
                _inner.Dispose();
                _owner.Dispose();
            }

            _disposed = true;
            base.Dispose(disposing);
        }
    }
}
