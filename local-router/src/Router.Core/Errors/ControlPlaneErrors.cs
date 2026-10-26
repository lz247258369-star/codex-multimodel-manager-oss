namespace Router.Core.Errors;

/// <summary>
/// Stable, content-free error factories for the LR-14P control-plane surface.
/// Messages never carry exception details, secret-shaped content, paths, or
/// request content.
/// </summary>
public static class ControlPlaneErrors
{
    public static RouterError InvalidRequest(string? param = null, string? requestId = null)
        => RouterError.Create(
            RouterErrorCode.ControlInvalidRequest,
            "The control-plane request is invalid.",
            param,
            requestId);

    public static RouterError GenerationConflict(string? requestId = null)
        => RouterError.Create(
            RouterErrorCode.ControlGenerationConflict,
            "The expected config generation is stale.",
            "expected_generation",
            requestId);

    public static RouterError PolicyInvalid(string? param = null, string? requestId = null)
        => RouterError.Create(
            RouterErrorCode.ControlPolicyInvalid,
            "The policy body is invalid or unsupported.",
            param,
            requestId);

    public static RouterError PolicyNotFound(string? policyId = null, string? requestId = null)
        => RouterError.Create(
            RouterErrorCode.ControlPolicyNotFound,
            "The requested policy does not exist.",
            policyId,
            requestId);

    public static RouterError FeatureUpdateFailed(string? param = null, string? requestId = null)
        => RouterError.Create(
            RouterErrorCode.ControlFeatureUpdateFailed,
            "The Local Router feature update could not be applied.",
            param,
            requestId);

    public static RouterError MutationFailed(string? param = null, string? requestId = null)
        => RouterError.Create(
            RouterErrorCode.ControlMutationFailed,
            "The control-plane mutation could not be applied.",
            param,
            requestId);

    public static RouterError ReadUnavailable(string? param = null, string? requestId = null)
        => RouterError.Create(
            RouterErrorCode.ControlReadUnavailable,
            "The requested control-plane read is not available.",
            param,
            requestId);

    public static RouterError PayloadTooLarge(string? param = null, string? requestId = null)
        => RouterError.Create(
            RouterErrorCode.ControlPayloadTooLarge,
            "The control-plane request body exceeds the hard size limit.",
            param,
            requestId);

    public static RouterError MutationBusy(string? requestId = null)
        => RouterError.Create(
            RouterErrorCode.ControlMutationBusy,
            "Another config mutation holds the serialization boundary; retry.",
            null,
            requestId,
            retryable: true);

    // HS-1B thread-scoped model selection. Every factory is content-free: no
    // raw thread id, header value, or provider text can reach a client.
    public static RouterError ThreadNotObserved(string? param = null, string? requestId = null)
        => RouterError.Create(
            RouterErrorCode.ControlThreadNotObserved,
            "The thread reference has not been observed by this Router.",
            param,
            requestId);

    public static RouterError ThreadSelectionConflict(string? param = null, string? requestId = null)
        => RouterError.Create(
            RouterErrorCode.ControlThreadSelectionConflict,
            "The expected thread selection generation is stale.",
            param ?? "expected_generation",
            requestId);

    public static RouterError ThreadSelectionExpired(string? param = null, string? requestId = null)
        => RouterError.Create(
            RouterErrorCode.ControlThreadSelectionExpired,
            "The thread model selection has expired.",
            param,
            requestId);

    public static RouterError ThreadSelectionDisabled(string? param = null, string? requestId = null)
        => RouterError.Create(
            RouterErrorCode.ControlThreadSelectionDisabled,
            "Thread-scoped model selection is disabled.",
            param ?? "thread_selection.enabled",
            requestId);

    public static RouterError ThreadSelectionUnavailable(string? param = null, string? requestId = null)
        => RouterError.Create(
            RouterErrorCode.ControlThreadSelectionUnavailable,
            "Thread-scoped model selection is not available in this runtime.",
            param,
            requestId);

    public static RouterError ThreadSelectionFeatureUpdateFailed(string? param = null, string? requestId = null)
        => RouterError.Create(
            RouterErrorCode.ControlThreadSelectionFeatureUpdateFailed,
            "The thread-selection capability update could not be applied.",
            param,
            requestId);

    public static RouterError ModelNotApproved(string? param = null, string? requestId = null)
        => RouterError.Create(
            RouterErrorCode.ControlModelNotApproved,
            "The selected model is not approved for this client.",
            param ?? "model",
            requestId);

    public static RouterError ModelRouteUnavailable(string? param = null, string? requestId = null)
        => RouterError.Create(
            RouterErrorCode.ControlModelRouteUnavailable,
            "The selected model has no eligible route.",
            param ?? "model",
            requestId);

    public static RouterError ModelCapabilityMismatch(string? param = null, string? requestId = null)
        => RouterError.Create(
            RouterErrorCode.ControlModelCapabilityMismatch,
            "The selected model cannot satisfy the request capabilities.",
            param,
            requestId);

    public static RouterError ThreadCaptureNotFound(string? param = null, string? requestId = null)
        => RouterError.Create(
            RouterErrorCode.ControlThreadCaptureNotFound,
            "The capture window is unknown, cancelled, or no longer retained.",
            param,
            requestId);

    public static RouterError ThreadCaptureUnavailable(string? param = null, string? requestId = null)
        => RouterError.Create(
            RouterErrorCode.ControlThreadCaptureUnavailable,
            "Thread identity capture is not available in this runtime.",
            param,
            requestId);

    public static RouterError ThreadCaptureBusy(string? param = null, string? requestId = null)
        => RouterError.Create(
            RouterErrorCode.ControlThreadCaptureBusy,
            "A thread identity capture window is already open for this Router.",
            param,
            requestId);
}
