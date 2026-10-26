using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Router.Ingress.Tests.Support;

/// <summary>HTTP/socket helpers for ingress tests.</summary>
public static class TestHttp
{
    /// <summary>Reserves and releases an ephemeral loopback port.</summary>
    public static int GetFreePort()
    {
        TcpListener listener = new(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    public static byte[] Utf8(string text) => Encoding.UTF8.GetBytes(text);

    public static HttpRequestMessage JsonRequest(HttpMethod method, string path, string json)
    {
        HttpRequestMessage request = new(method, path)
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json"),
        };
        return request;
    }
}

/// <summary>A non-seekable stream used to force chunked request bodies.</summary>
public sealed class NonSeekableStream : Stream
{
    private readonly byte[] _bytes;
    private int _position;

    public NonSeekableStream(byte[] bytes)
    {
        _bytes = bytes;
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

    public override void Flush()
    {
    }

    public override int Read(byte[] buffer, int offset, int count)
    {
        int available = _bytes.Length - _position;
        int toRead = Math.Min(count, available);
        Array.Copy(_bytes, _position, buffer, offset, toRead);
        _position += toRead;
        return toRead;
    }

    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

    public override void SetLength(long value) => throw new NotSupportedException();

    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}
