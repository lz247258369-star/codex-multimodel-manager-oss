namespace Router.Ingress;

/// <summary>Internal signal for a request body that exceeded the configured limit.</summary>
public sealed class RequestTooLargeException : Exception
{
    public RequestTooLargeException()
        : base("The request body exceeded the configured limit.")
    {
    }
}
