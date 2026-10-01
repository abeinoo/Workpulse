module Users
  # Activates a pre-created, passwordless account ("Pending Registration").
  #
  # The claimant must present the signed invitation token issued by an
  # administrator (User#generate_token_for(:account_claim)) AND the account's
  # phone number or email. Knowing the phone/email alone is not enough (OA-S6).
  # Every failure returns the same message, so the form cannot be used to
  # discover which phone numbers or emails have accounts.
  class RegistrationService
    Result = Struct.new(:success?, :user, :error, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(login:, password:, password_confirmation:, invitation_token: nil)
      @login                 = login.to_s.strip
      @password              = password
      @password_confirmation = password_confirmation
      @invitation_token      = invitation_token.to_s
    end

    def call
      user = invited_user
      return failure(I18n.t("auth.register.invalid_invitation")) unless claimable?(user)

      user.password              = @password
      user.password_confirmation = @password_confirmation

      if user.save
        Result.new(success?: true, user: user, error: nil)
      else
        Result.new(success?: false, user: nil, error: user.errors.full_messages.to_sentence)
      end
    end

    private

    def invited_user
      return nil if @invitation_token.blank?

      User.find_by_token_for(:account_claim, @invitation_token)
    end

    def claimable?(user)
      user.present? && user.active? && user.encrypted_password.blank? && login_matches?(user)
    end

    def login_matches?(user)
      return false if @login.blank?

      if @login.include?("@")
        user.email.present? && user.email.casecmp?(@login)
      else
        user.phone_number.present? && user.phone_number == User.normalize_value_for(:phone_number, @login)
      end
    end

    def failure(message)
      Result.new(success?: false, user: nil, error: message)
    end
  end
end
