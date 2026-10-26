using Router.Policies;
using Router.ProviderAdapters.Abstractions;
using Xunit;

namespace Router.Policies.Tests;

public sealed class TimeoutPolicyTests
{
    [Fact]
    public void Remaining_total_deadline_never_exceeded()
    {
        TimeoutPolicy policy = TimeoutPolicy.Default;

        TimeoutBoundaries boundaries = TimeoutPolicyEngine.Boundaries(policy, TimeSpan.FromSeconds(20));

        Assert.True(boundaries.TotalTimeout <= TimeSpan.FromSeconds(20));
        Assert.True(boundaries.ConnectTimeout <= boundaries.TotalTimeout);
        Assert.True(boundaries.FirstByteTimeout <= boundaries.TotalTimeout);
    }

    [Fact]
    public void Default_boundaries_are_conservative()
    {
        Assert.Equal(TimeSpan.FromMinutes(10), TimeoutPolicy.Default.TotalTimeout);
        Assert.Equal(TimeSpan.FromMinutes(5), TimeoutPolicy.Default.AttemptTimeout);
    }
}
