using System.Reflection;
using Router.ProviderAdapters.Abstractions;
using Xunit;

namespace Router.ProviderAdapters.Tests;

public sealed class AttemptRecordSafetyTests
{
    [Fact]
    public void Attempt_record_shape_has_no_content_or_secret_fields()
    {
        string[] forbidden = ["prompt", "rawbody", "toolpayload", "image", "header", "authorization", "secretvalue", "cookie", "apikey", "requestbody", "responsebody", "contenttext"];
        foreach (PropertyInfo property in typeof(AttemptRecord).GetProperties(BindingFlags.Public | BindingFlags.Instance))
        {
            string name = property.Name.ToLowerInvariant();
            foreach (string needle in forbidden)
            {
                Assert.DoesNotContain(needle, name);
            }
        }
    }

    [Fact]
    public void Attempt_record_contains_safe_operational_fields()
    {
        string[] required =
        [
            "attemptid", "requestid", "traceid", "routeid", "adapterid", "providerid", "endpointid",
            "attemptnumber", "startedat", "completedat", "outcome", "finalcheckpoint",
        ];

        foreach (string needle in required)
        {
            Assert.NotNull(
                typeof(AttemptRecord).GetProperties(BindingFlags.Public | BindingFlags.Instance)
                    .FirstOrDefault(property => string.Equals(property.Name, needle, StringComparison.OrdinalIgnoreCase)));
        }

        Assert.NotNull(typeof(AttemptRecord).GetProperty("NormalizedError"));
        Assert.NotNull(typeof(AttemptRecord).GetProperty("CancellationReason"));
    }
}
