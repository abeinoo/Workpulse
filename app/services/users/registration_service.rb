module Users
  # Self-service activation of a pre-created, passwordless account ("Pending
  # Registration") by its registered mobile number.
  #
  # ACCEPTED RISK (product decision 2026-11-15, reverting OA-S6): the mobile
  # number is the only proof offered. There is no OTP, invitation, national ID
  # or employee code check, so anyone who knows a pending employee's number
  # can claim that account first. See OA-S6 in
  # docs/architecture/organization-access-migration-readiness.md. Recovery:
  # an administrator resets the password (UserPolicy#reset_password?).
  #
  # Flow: password rules → lookup → eligibility → activation. A future
  # verification step (e.g. OTP) belongs between eligibility and activation.
  #
  # No enumeration: password rules are checked before any lookup, so their
  # errors never depend on the account; every account-related failure
  # (unknown, ambiguous, inactive, already registered, unexpected invalid
  # record, audit failure) returns the same message.
  #
  # Only the password is written. Business, role, branch / warehouse access and
  # every other attribute stay as the administrator set them; nothing is read
  # from the request except the phone number and the password pair.
  class RegistrationService
    include AuditLoggable

    Result = Struct.new(:success?, :user, :error, keyword_init: true)

    AUDIT_ACTION = "account_registered".freeze

    def self.call(...)
      new(...).call
    end

    def initialize(phone_number:, password:, password_confirmation:, ip_address: nil)
      @phone_number          = phone_number.to_s.strip
      @password              = password.to_s
      @password_confirmation = password_confirmation.to_s
      @ip_address            = ip_address
    end

    def call
      password_errors = password_rule_errors
      return failure(password_errors.to_sentence) if password_errors.any?

      candidate = @phone_number.present? ? User.find_by_phone_login(@phone_number) : nil
      return not_available unless eligible?(candidate)

      activate(candidate)
    end

    private

    # The model's own password rules (length, confirmation), checked on a
    # throwaway record so the answer cannot depend on which account matches.
    def password_rule_errors
      probe = User.new(password: @password, password_confirmation: @password_confirmation)
      probe.validate
      probe.errors.add(:password, :blank) if @password.blank?
      (probe.errors.full_messages_for(:password) + probe.errors.full_messages_for(:password_confirmation)).uniq
    end

    def eligible?(user)
      user.present? && user.active? && user.encrypted_password.blank?
    end

    # Locks the row and re-checks eligibility on committed state, so of two
    # concurrent claims exactly one sets the password; the other is refused.
    def activate(candidate)
      activated = false

      candidate.with_lock do
        raise ActiveRecord::Rollback unless eligible?(candidate)

        candidate.password              = @password
        candidate.password_confirmation = @password_confirmation
        candidate.save!
        log_audit!(actor: candidate, auditable: candidate, action: AUDIT_ACTION,
                   changes:  { registration_status: %w[pending_registration registered] },
                   metadata: { method: "phone_self_registration", ip_address: @ip_address }.compact)
        activated = true
      end

      activated ? Result.new(success?: true, user: candidate, error: nil) : not_available
    rescue ActiveRecord::RecordInvalid => e
      # Password rules passed above, so the record itself is invalid (legacy
      # data). Its errors describe the account and are never shown; attribute
      # names only go to the log so an administrator can correct the record.
      Rails.logger.warn("[Registration] eligible account #{candidate.id} failed validation on " \
                        "#{e.record.errors.attribute_names.join(', ')}")
      not_available
    rescue AuditLoggable::AuditWriteFailed
      # Already logged and reported by AuditLoggable; the transaction rolled back.
      not_available
    end

    def not_available
      failure(I18n.t("auth.register.not_available"))
    end

    def failure(message)
      Result.new(success?: false, user: nil, error: message)
    end
  end
end
