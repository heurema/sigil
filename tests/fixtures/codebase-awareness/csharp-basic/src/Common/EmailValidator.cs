namespace Sample.Common;

public interface IEmailValidator
{
    bool Validate(string value);
}

public enum Role
{
    User,
    Admin
}

public struct Result
{
    public bool IsValid { get; init; }
}

public record UserDto(string Email);

internal record SignupRequest(string Email);

public static class EmailValidator
{
    public const string DefaultRole = "user";

    public static bool ValidateEmail(string value)
    {
        return !string.IsNullOrWhiteSpace(value) && value.Contains("@");
    }

    internal static string NormalizeEmail(string value)
    {
        return value.Trim().ToLowerInvariant();
    }

    private static bool HasAtSign(string value)
    {
        return value.Contains("@");
    }
}
