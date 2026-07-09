namespace CicdFixture.Tests;

using Xunit;

public class FixtureSmokeTests
{
    [Fact]
    public void Default_version_is_one_when_env_unset()
    {
        var version = Environment.GetEnvironmentVariable("DEPLOY_VERSION") ?? "1";
        Assert.Equal("1", version);
    }
}
