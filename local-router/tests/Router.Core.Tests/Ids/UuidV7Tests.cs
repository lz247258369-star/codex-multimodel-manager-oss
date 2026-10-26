using System.Text.RegularExpressions;
using Router.Core.Ids;
using Router.Core.Tests.Fakes;
using Xunit;

namespace Router.Core.Tests.Ids;

public sealed class UuidV7Tests
{
    private static readonly Regex CanonicalV7 = new(
        "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
        RegexOptions.CultureInvariant);

    private static readonly char[] VariantFirstCharacters = { '8', '9', 'a', 'b' };

    [Fact]
    public void Generated_uuid_is_canonical_version_7()
    {
        UuidV7IdGenerator generator = new(new FakeClock(1_700_000_000_000));

        UuidV7 uuid = generator.NewUuidV7();

        Assert.Matches(CanonicalV7, uuid.Value);
        Assert.Equal('7', uuid.Value[14]);
        Assert.Contains(uuid.Value[19], VariantFirstCharacters);
    }

    [Fact]
    public void Timestamp_comes_from_the_clock()
    {
        const long unixTimeMilliseconds = 1_752_000_123_456;
        FakeClock clock = new(unixTimeMilliseconds);
        UuidV7IdGenerator generator = new(clock);

        UuidV7 uuid = generator.NewUuidV7();

        Assert.Equal(unixTimeMilliseconds, uuid.UnixTimeMilliseconds);
    }

    [Fact]
    public void Same_millisecond_ids_are_unique_and_clock_advance_increases_time()
    {
        FakeClock clock = new(1_752_000_000_000);
        UuidV7IdGenerator generator = new(clock);

        HashSet<UuidV7> ids = new();
        for (int i = 0; i < 3_000; i++)
        {
            UuidV7 uuid = generator.NewUuidV7();
            Assert.True(ids.Add(uuid), "Duplicate UUIDv7 within one millisecond");
            Assert.Equal(1_752_000_000_000, uuid.UnixTimeMilliseconds);
        }

        clock.AdvanceMilliseconds(1);
        UuidV7 later = generator.NewUuidV7();

        Assert.True(later.UnixTimeMilliseconds > 1_752_000_000_000);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("00000000-0000-0000-0000-000000000000")]
    [InlineData("00000000-0000-6000-8000-000000000000")]
    [InlineData("00000000-0000-7000-c000-000000000000")]
    [InlineData("00000000-0000-7000-8000-00000000000G")]
    [InlineData("00000000-0000-7000-8000-00000000000 ")]
    [InlineData("00000000-0000-7000-8000-00000000000A")]
    [InlineData("00000000-0000-7000-8000-000000000000-")]
    public void Invalid_uuidv7_is_rejected(string? text)
    {
        Assert.False(UuidV7.TryParse(text, out _));
    }

    [Fact]
    public void Parse_round_trips_generated_values()
    {
        UuidV7IdGenerator generator = new(new FakeClock(1_752_000_000_000));
        for (int i = 0; i < 100; i++)
        {
            UuidV7 original = generator.NewUuidV7();

            UuidV7 parsed = UuidV7.Parse(original.Value);

            Assert.Equal(original, parsed);
            Assert.Equal(original.AsGuid, parsed.AsGuid);
        }
    }
}
