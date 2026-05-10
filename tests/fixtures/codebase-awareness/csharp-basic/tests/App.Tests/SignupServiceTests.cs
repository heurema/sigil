using Sample.Common;
using Sample.App.Services;
using Xunit;

namespace Sample.App.Tests;

public class SignupServiceTests
{
    [Fact]
    public void UsesExistingEmailValidator()
    {
        Assert.True(EmailValidator.ValidateEmail("user@example.com"));
    }

    [Theory]
    [InlineData("USER@EXAMPLE.COM")]
    public void NormalizesEmailThroughSharedValidator(string value)
    {
        Assert.Equal("user@example.com", EmailValidator.NormalizeEmail(value));
    }
}
