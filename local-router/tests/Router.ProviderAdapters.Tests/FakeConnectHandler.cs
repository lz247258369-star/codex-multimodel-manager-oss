using System.Net;

namespace Router.ProviderAdapters.Tests;

/// <summary>
/// Deterministic test handler that simulates a connect-phase failure (as if
/// the TCP connection could not be established) or hangs while connecting.
/// </summary>
public sealed class FakeConnectHandler : HttpMessageHandler
{
    public bool FailConnect { get; set; }

    public TimeSpan HangDuration { get; set; } = TimeSpan.Zero;

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        if (FailConnect)
        {
            throw new HttpRequestException("simulated connect failure");
        }

        if (HangDuration > TimeSpan.Zero)
        {
            await Task.Delay(HangDuration, cancellationToken);
        }

        return new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new ByteArrayContent("{}"u8.ToArray()),
        };
    }
}
