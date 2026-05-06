require "rails_helper"

RSpec.describe Users::RegistrationService do
  subject(:result) do
    described_class.call(
      login:                 login,
      password:              password,
      password_confirmation: password_confirmation
    )
  end

  let(:password)              { "password123" }
  let(:password_confirmation) { "password123" }

  describe ".call" do
    context "when no employee matches the login" do
      let(:login) { "+966050000000" }

      it { is_expected.not_to be_success }

      it "returns an informative error" do
        expect(result.error).to eq("No account found for that phone number or email.")
      end

      it "does not create a user" do
        expect { result }.not_to change(User, :count)
      end
    end

    context "when the employee exists and has no user yet" do
      let!(:employee) { create(:employee, phone_number: "+966051234567") }
      let(:login)     { "+966051234567" }

      it { is_expected.to be_success }

      it "creates a user" do
        expect { result }.to change(User, :count).by(1)
      end

      it "links the user to the employee" do
        expect(result.user.employee).to eq(employee)
      end

      it "returns no error" do
        expect(result.error).to be_nil
      end
    end

    context "when the employee is already registered" do
      let!(:employee) { create(:employee) }
      let!(:_user)    { create(:user, employee: employee) }
      let(:login)     { employee.phone_number }

      it { is_expected.not_to be_success }

      it "returns an informative error" do
        expect(result.error).to eq("This account has already been registered.")
      end

      it "does not create another user" do
        expect { result }.not_to change(User, :count)
      end
    end

    context "when login is an email address" do
      let!(:employee) { create(:employee, email: "ahmed@workpulse.com") }
      let(:login)     { "ahmed@workpulse.com" }

      it { is_expected.to be_success }
    end

    context "when email login is uppercase" do
      let!(:employee) { create(:employee, email: "ahmed@workpulse.com") }
      let(:login)     { "AHMED@WORKPULSE.COM" }

      it { is_expected.to be_success }
    end

    context "when password confirmation does not match" do
      let!(:employee)         { create(:employee) }
      let(:login)             { employee.phone_number }
      let(:password_confirmation) { "different_password" }

      it { is_expected.not_to be_success }

      it "does not create a user" do
        expect { result }.not_to change(User, :count)
      end
    end

    context "when password is too short" do
      let!(:employee) { create(:employee) }
      let(:login)     { employee.phone_number }
      let(:password)  { "short" }
      let(:password_confirmation) { "short" }

      it { is_expected.not_to be_success }
    end
  end
end
