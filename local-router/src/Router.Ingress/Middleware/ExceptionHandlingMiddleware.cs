using Microsoft.AspNetCore.Http;
using Router.Core.Errors;

namespace Router.Ingress.Middleware;

/// <summary>
/// Outermost exception boundary. Maps controlled over-limit signals to 413,
/// ignores client disconnects, and normalizes unexpected failures without
/// leaking exception details.
/// </summary>
public sealed class ExceptionHandlingMiddleware
{
    private readonly RequestDelegate _next;

    public ExceptionHandlingMiddleware(RequestDelegate next)
    {
        _next = next;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        try
        {
            await _next(context).ConfigureAwait(false);
        }
        catch (RequestTooLargeException)
        {
            if (!context.Response.HasStarted)
            {
                RouterError error = RouterError.RequestTooLarge(CurrentRequestId(context));
                await ErrorEnvelopeWriter.WriteAsync(context.Response, error, HttpStatusMapper.ToStatusCode(error), context.RequestAborted).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
        {
            // Client disconnected or shutdown: nothing safe to write.
        }
        catch (BadHttpRequestException badRequest) when (badRequest.StatusCode is StatusCodes.Status413PayloadTooLarge or StatusCodes.Status431RequestHeaderFieldsTooLarge)
        {
            if (!context.Response.HasStarted)
            {
                RouterError error = badRequest.StatusCode == StatusCodes.Status413PayloadTooLarge
                    ? RouterError.RequestTooLarge(CurrentRequestId(context))
                    : RouterError.InvalidRequest("The request headers exceed the configured limit.", "headers", CurrentRequestId(context));
                await ErrorEnvelopeWriter.WriteAsync(context.Response, error, HttpStatusMapper.ToStatusCode(error), context.RequestAborted).ConfigureAwait(false);
            }
        }
        catch (Exception)
        {
            if (!context.Response.HasStarted)
            {
                RouterError error = RouterError.InternalError(CurrentRequestId(context));
                await ErrorEnvelopeWriter.WriteAsync(context.Response, error, HttpStatusMapper.ToStatusCode(error), context.RequestAborted).ConfigureAwait(false);
            }
        }
    }

    private static string? CurrentRequestId(HttpContext context)
        => context.Items.TryGetValue(IngressContextKeys.RequestId, out object? value) && value is Router.Core.Ids.RequestId requestId
            ? requestId.Value
            : null;
}
