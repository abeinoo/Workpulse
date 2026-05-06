module Users
  class RegistrationService
    Result = Struct.new(:success?, :user, :error, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(login:, password:, password_confirmation:)
      @login                 = login.to_s.strip
      @password              = password
      @password_confirmation = password_confirmation
    end

    def call
      employee = find_employee
      return failure("No account found for that phone number or email.") unless employee
      return failure("This account has already been registered.") if employee.user.present?

      user = User.new(employee: employee, password: @password, password_confirmation: @password_confirmation)

      if user.save
        Result.new(success?: true, user: user, error: nil)
      else
        Result.new(success?: false, user: nil, error: user.errors.full_messages.to_sentence)
      end
    end

    private

    def find_employee
      Employee.find_by(phone_number: @login) ||
        Employee.find_by(email: @login.downcase)
    end

    def failure(message)
      Result.new(success?: false, user: nil, error: message)
    end
  end
end
