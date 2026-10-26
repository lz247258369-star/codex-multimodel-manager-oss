using Microsoft.AspNetCore.Http;
using Router.Core.Errors;

namespace Router.Ingress;

/// <summary>Maps canonical error codes to stable HTTP status codes.</summary>
public static class HttpStatusMapper
{
    public static int ToStatusCode(RouterError error) => error.Code switch
    {
        RouterErrorCode.InvalidRequest or RouterErrorCode.UnsupportedParameter => StatusCodes.Status400BadRequest,
        RouterErrorCode.UnsupportedCapability => StatusCodes.Status422UnprocessableEntity,
        RouterErrorCode.AuthenticationRequired or RouterErrorCode.AuthenticationInvalid => StatusCodes.Status401Unauthorized,
        RouterErrorCode.ScopeDenied or RouterErrorCode.OriginForbidden => StatusCodes.Status403Forbidden,
        RouterErrorCode.RequestTooLarge => StatusCodes.Status413PayloadTooLarge,
        RouterErrorCode.RateLimited => StatusCodes.Status429TooManyRequests,
        RouterErrorCode.ControlGenerationConflict => StatusCodes.Status409Conflict,
        RouterErrorCode.ControlMutationBusy => StatusCodes.Status409Conflict,
        RouterErrorCode.ControlPayloadTooLarge => StatusCodes.Status413PayloadTooLarge,
        RouterErrorCode.ControlPolicyInvalid or RouterErrorCode.ControlInvalidRequest => StatusCodes.Status400BadRequest,
        RouterErrorCode.ControlPolicyNotFound => StatusCodes.Status404NotFound,
        RouterErrorCode.ControlThreadNotObserved or RouterErrorCode.ControlThreadCaptureNotFound => StatusCodes.Status404NotFound,
        RouterErrorCode.ControlThreadSelectionConflict
            or RouterErrorCode.ControlThreadSelectionExpired
            or RouterErrorCode.ControlThreadCaptureBusy => StatusCodes.Status409Conflict,
        RouterErrorCode.ControlModelNotApproved
            or RouterErrorCode.ControlModelRouteUnavailable
            or RouterErrorCode.ControlModelCapabilityMismatch => StatusCodes.Status422UnprocessableEntity,
        RouterErrorCode.ControlReadUnavailable => StatusCodes.Status503ServiceUnavailable,
        RouterErrorCode.ControlThreadSelectionDisabled
            or RouterErrorCode.ControlThreadSelectionUnavailable
            or RouterErrorCode.ControlThreadCaptureUnavailable => StatusCodes.Status503ServiceUnavailable,
        RouterErrorCode.RouterDisabled => StatusCodes.Status503ServiceUnavailable,
        RouterErrorCode.ProviderTimeout => StatusCodes.Status504GatewayTimeout,
        RouterErrorCode.SecretMissing => StatusCodes.Status503ServiceUnavailable,
        _ => StatusCodes.Status500InternalServerError,
    };
}
