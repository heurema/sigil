global using Sample.Common;
using System;
using static Sample.Common.EmailValidator;
using CommonValidation = Sample.Common.EmailValidator;

namespace Sample.App.Services
{
    public sealed class SignupService
    {
        private readonly IEmailValidator _validator;

        public SignupService(IEmailValidator validator)
        {
            _validator = validator;
        }

        public async Task<UserDto> CreateAsync(string email)
        {
            await Task.Yield();
            if (!ValidateEmail(email))
            {
                throw new ArgumentException("Invalid email", nameof(email));
            }

            return new UserDto(email);
        }

        internal static string NormalizeForStorage(string email)
        {
            return CommonValidation.NormalizeEmail(email);
        }
    }
}
