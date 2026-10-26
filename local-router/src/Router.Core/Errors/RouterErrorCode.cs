namespace Router.Core.Errors;

/// <summary>
/// Stable, content-free error codes from the error contract. Codes never change
/// for a given semantic; messages never carry secrets or exception details.
/// </summary>
public static class RouterErrorCode
{
    public const string Type = "router_error";
    public const string InvalidRequest = "invalid_request";
    public const string UnsupportedParameter = "unsupported_parameter";
    public const string UnsupportedCapability = "unsupported_capability";
    public const string RouteNotFound = "route_not_found";
    public const string RouteDisabled = "route_disabled";
    public const string Cancelled = "cancelled";
    public const string InternalError = "internal_error";

    // LR-3 ingress / transport codes. Names follow the error contract table and
    // extend, never duplicate, existing codes.
    public const string AuthenticationRequired = "authentication_required";
    public const string AuthenticationInvalid = "authentication_invalid";
    public const string RequestTooLarge = "request_too_large";
    public const string RateLimited = "rate_limited";
    public const string ProviderTimeout = "provider_timeout";
    public const string RouterPortInUse = "router_port_in_use";
    public const string RouterAlreadyRunning = "router_already_running";
    public const string ScopeDenied = "scope_denied";
    public const string OriginForbidden = "origin_forbidden";

    // LR-2 configuration / state / secrets / ownership codes.
    // Names follow the error contract table; new codes extend, never duplicate.
    public const string ConfigMissingRequired = "config_missing_required";
    public const string ConfigInvalid = "config_invalid";
    public const string ConfigSchemaUnsupported = "config_schema_unsupported";
    public const string ConfigCorrupt = "config_corrupt";
    public const string ConfigSecurityViolation = "config_security_violation";
    public const string StateCorrupt = "state_corrupt";
    public const string StateWriteFailed = "state_write_failed";
    public const string StateRecoveryFailed = "state_recovery_failed";
    public const string MigrationFailed = "migration_failed";
    public const string MigrationRollbackFailed = "migration_rollback_failed";
    public const string OwnershipConflict = "ownership_conflict";
    public const string OwnershipForeignProcess = "ownership_foreign_process";
    public const string OwnershipStale = "ownership_stale";
    public const string SecretMissing = "secret_missing";
    public const string SecretScopeViolation = "secret_scope_violation";
    public const string SecretReferenceInvalid = "secret_reference_invalid";

    // LR-4 registries, catalog projection, and route resolution codes.
    // Names follow the error contract table; new codes extend, never duplicate.
    public const string CatalogInvalid = "catalog_invalid";
    public const string CatalogUnsupportedVersion = "catalog_unsupported_version";
    public const string UnknownProvider = "unknown_provider";
    public const string UnknownProtocol = "unknown_protocol";
    public const string UnknownModel = "unknown_model";
    public const string UnknownRoute = "unknown_route";
    public const string UnknownClient = "unknown_client";
    public const string UnknownEndpoint = "unknown_endpoint";
    public const string UnknownAdapter = "unknown_adapter";
    public const string DuplicateRegistryKey = "duplicate_registry_key";
    public const string InvalidRegistry = "invalid_registry";
    public const string AmbiguousModel = "ambiguous_model";
    public const string RouteNotAllowed = "route_not_allowed";
    public const string ExplicitRoutePreferenceInvalid = "explicit_route_preference_invalid";
    public const string RouteIneligible = "route_ineligible";
    public const string PlaceholderUnavailable = "placeholder_unavailable";
    public const string InvalidProviderModelRelation = "invalid_provider_model_relation";
    public const string InvalidEndpointReference = "invalid_endpoint_reference";

    // LR-5 provider harness / upstream transport codes. Names follow the
    // error contract table; new codes extend, never duplicate.
    public const string ConnectionFailed = "connection_failed";
    public const string TimeoutConnect = "timeout_connect";
    public const string TimeoutFirstByte = "timeout_first_byte";
    public const string TimeoutIdle = "timeout_idle";
    public const string TimeoutTotal = "timeout_total";
    public const string Provider4xx = "provider_4xx";
    public const string Provider5xx = "provider_5xx";
    public const string QuotaExhausted = "quota_exhausted";
    public const string CreditExhausted = "credit_exhausted";
    public const string QuotaFallbacksExhausted = "quota_fallbacks_exhausted";
    public const string InvalidResponse = "invalid_response";
    public const string StreamInterrupted = "stream_interrupted";
    public const string RedirectRejected = "redirect_rejected";
    public const string TlsRequired = "tls_required";
    public const string AdapterNotFound = "adapter_not_found";
    public const string AdapterVersionMismatch = "adapter_version_mismatch";
    public const string AdapterRegistrationInvalid = "adapter_registration_invalid";

    // LR-8 protocol adapter boundary codes. Names follow the error contract
    // table; new codes extend, never duplicate, existing codes.
    public const string SemanticLoss = "semantic_loss";
    public const string ProtocolUnsupported = "protocol_unsupported";

    // LR-14P control-plane codes. Names follow the error contract table and
    // extend, never duplicate, existing codes. These are the only codes the
    // control-plane HTTP surface may return for its own failures.
    public const string ControlInvalidRequest = "control_invalid_request";
    public const string ControlGenerationConflict = "control_generation_conflict";
    public const string ControlPolicyInvalid = "control_policy_invalid";
    public const string ControlPolicyNotFound = "control_policy_not_found";
    public const string ControlFeatureUpdateFailed = "control_feature_update_failed";
    public const string ControlMutationFailed = "control_mutation_failed";
    public const string ControlReadUnavailable = "control_read_unavailable";
    public const string ControlReadDegraded = "control_read_degraded";
    public const string ControlPayloadTooLarge = "control_payload_too_large";
    public const string ControlMutationBusy = "control_mutation_busy";
    public const string RouterDisabled = "router_disabled";

    // HS-1B thread-scoped model selection codes. Names follow the error
    // contract table and extend, never duplicate, existing codes.
    public const string ControlThreadNotObserved = "control_thread_not_observed";
    public const string ControlThreadSelectionConflict = "control_thread_selection_conflict";
    public const string ControlThreadSelectionExpired = "control_thread_selection_expired";
    public const string ControlThreadSelectionDisabled = "control_thread_selection_disabled";
    public const string ControlThreadSelectionUnavailable = "control_thread_selection_unavailable";
    public const string ControlThreadSelectionFeatureUpdateFailed = "control_thread_selection_feature_update_failed";
    public const string ControlThreadIdentityMismatch = "control_thread_identity_mismatch";
    public const string ControlThreadSelectionInvalidRequestKind = "control_thread_selection_invalid_request_kind";
    public const string ControlModelNotApproved = "control_model_not_approved";
    public const string ControlModelRouteUnavailable = "control_model_route_unavailable";
    public const string ControlModelCapabilityMismatch = "control_model_capability_mismatch";
    public const string ControlThreadCaptureNotFound = "control_thread_capture_not_found";
    public const string ControlThreadCaptureUnavailable = "control_thread_capture_unavailable";
    public const string ControlThreadCaptureBusy = "control_thread_capture_busy";
}
