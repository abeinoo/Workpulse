require "rails_helper"

# Self-service activation of a pre-created, passwordless account by its
# registered mobile number (product decision 2026-11-15, reverting OA-S6's
# invitation link; phone-only is an accepted risk). Password rules are checked
# before any lookup; every account-related failure returns one generic message.
# Concurrent claims: registration_service_concurrency_spec.rb.
RSpec.describe Users::RegistrationService do
  subject(:result) do
    described_class.call(phone_number: phone, password: password,
                         password_confirmation: password_confirmation, ip_address: "10.1.2.3")
  end

  let(:password)              { "password123" }
  let(:password_confirmation) { "password123" }
  let(:generic_error)         { I18n.t("auth.register.not_available") }

  def register(phone, pass = password, confirmation = pass)
    described_class.call(phone_number: phone, password: pass, password_confirmation: confirmation)
  end

  describe "an eligible pending account" do
    let(:business) { create(:business) }
    let!(:user)    { create(:user, :phone_only, :unregistered, business: business, phone_number: "+966501234567") }
    let(:phone)    { "+966501234567" }

    it "sets the password on the existing user without creating another" do
      expect { result }.not_to change(User, :count)
      expect(result).to be_success
      expect(result.error).to be_nil
      expect(result.user).to eq(user)
      expect(user.reload.valid_password?(password)).to be(true)
    end

    it "accepts the number in another format that normalizes to the same value" do
      expect(register("+966 50 123 4567")).to be_success
    end

    it "writes an account_registered audit entry by the employee on their own account" do
      expect { result }.to change(AuditLog, :count).by(1)
      entry = AuditLog.last
      expect(entry).to have_attributes(action: "account_registered", actor_id: user.id, business_id: business.id,
                                       auditable_type: "User", auditable_id: user.id)
      expect(entry.metadata).to eq("method" => "phone_self_registration", "ip_address" => "10.1.2.3")
      expect(entry.changes_json).to eq("registration_status" => %w[pending_registration registered])
    end

    it "never stores the password digest in the audit entry" do
      result
      serialized = AuditLog.last.attributes.to_json
      expect(serialized).not_to include(user.reload.encrypted_password)
      expect(serialized).not_to include(password)
    end

    it "changes only the password (business, role, access and profile untouched)" do
      role      = create(:permission_role, business: business, permissions: %w[view_attendance])
      warehouse = Warehouse.create!(business: business, name: "WH #{SecureRandom.hex(3)}")
      user.update_column(:permission_role_id, role.id)
      user.assigned_warehouses << warehouse
      create(:shift_assignment, user: user)
      ignored = %w[encrypted_password updated_at]
      before  = user.reload.attributes.except(*ignored)

      expect(result).to be_success
      user.reload
      expect(user.attributes.except(*ignored)).to eq(before)
      expect(user.assigned_warehouses).to eq([ warehouse ])
      expect(user.shift_assignments.count).to eq(1)
      expect(user.permission_role).to eq(role)
      expect(user.can?(:manage_settings)).to be(false)
    end

    it "fails closed when the audit entry cannot be written: no password, nothing committed" do
      fail_audit_writes!(:account_registered)
      expect(result).not_to be_success
      expect(result.error).to eq(generic_error)
      expect(user.reload.encrypted_password).to be_blank
      expect(AuditLog.where(action: "account_registered")).to be_empty
    end

    it "refuses a second registration of the same account and keeps the first password" do
      expect(register(phone)).to be_success
      second = register(phone, "another123")
      expect(second).not_to be_success
      expect(second.error).to eq(generic_error)
      expect(user.reload.valid_password?(password)).to be(true)
      expect(AuditLog.where(action: "account_registered").count).to eq(1)
    end
  end

  describe "Egyptian mobile stored in national form" do
    let!(:user) { create(:user, :phone_only, :unregistered, phone_number: "01012345678") }

    [ "01012345678", "+201012345678", "201012345678", "00201012345678", "٠١٠١٢٣٤٥٦٧٨" ].each do |format|
      it "activates the account entered as #{format.inspect} and keeps the stored number" do
        outcome = register(format)
        expect(outcome).to be_success
        expect(outcome.user).to eq(user)
        expect(user.reload.valid_password?(password)).to be(true)
        expect(user.phone_number).to eq("01012345678")
      end
    end
  end

  describe "password rules" do
    let!(:user) { create(:user, :phone_only, :unregistered, phone_number: "+966502222222") }
    let(:phone) { "+966502222222" }

    context "when the confirmation does not match" do
      let(:password_confirmation) { "different_password" }

      it "refuses with the confirmation error and leaves the account pending" do
        expect(result).not_to be_success
        expect(result.error).to include(User.human_attribute_name(:password_confirmation))
        expect(user.reload.encrypted_password).to be_blank
      end
    end

    context "when the password is too short" do
      let(:password)              { "short" }
      let(:password_confirmation) { "short" }

      it { expect(result).not_to be_success }
      it { expect { result }.not_to change { user.reload.encrypted_password } }
    end

    context "when the password is blank" do
      let(:password)              { "" }
      let(:password_confirmation) { "" }

      it "refuses (a blank password never activates an account)" do
        expect(result).not_to be_success
        expect(result.error).not_to eq(generic_error)
        expect(user.reload.encrypted_password).to be_blank
      end
    end

    it "gives the same password error whether or not the number belongs to an account (checked first)" do
      create(:user, :phone_only, phone_number: "+966503333333")
      errors = [ "+966502222222", "+966503333333", "+966500000000", "" ].map { |p| register(p, "short").error }
      expect(errors.uniq.size).to eq(1)
      expect(errors.first).not_to eq(generic_error)
    end
  end

  describe "refused accounts (one generic message, nothing written)" do
    shared_examples "a refused registration" do
      it "fails with the generic message and writes nothing" do
        expect { result }.not_to change(AuditLog, :count)
        expect(result).not_to be_success
        expect(result.error).to eq(generic_error)
      end
    end

    context "unknown mobile number" do
      let(:phone) { "+966500000000" }
      it_behaves_like "a refused registration"
    end

    context "blank mobile number" do
      let(:phone) { "" }
      it_behaves_like "a refused registration"
    end

    context "an email instead of a mobile number" do
      let!(:user) { create(:user, :unregistered, email: "sara@workpulse.com") }
      let(:phone) { "sara@workpulse.com" }

      it_behaves_like "a refused registration"
      it { expect { result }.not_to change { user.reload.encrypted_password } }
    end

    context "already registered account" do
      let!(:user) { create(:user, :phone_only, phone_number: "+966506666666") }
      let(:phone) { "+966506666666" }

      it_behaves_like "a refused registration"
      it "keeps the existing password" do
        result
        expect(user.reload.valid_password?("password123")).to be(true)
      end
    end

    context "inactive pending account" do
      let!(:user) { create(:user, :phone_only, :unregistered, phone_number: "+966507777777", active: false) }
      let(:phone) { "+966507777777" }

      it_behaves_like "a refused registration"
      it { expect { result }.not_to change { user.reload.encrypted_password } }
    end

    context "ambiguous match (two accounts stored in equivalent formats)" do
      let!(:national) { create(:user, :phone_only, :unregistered, phone_number: "01012345678") }
      let!(:intl)     { create(:user, :phone_only, :unregistered, phone_number: "+201012345678") }
      let(:phone)     { "201012345678" }

      it_behaves_like "a refused registration"
      it "activates neither account" do
        result
        expect([ national.reload, intl.reload ].map(&:encrypted_password)).to all(be_blank)
      end
    end

    context "an eligible account whose stored record is invalid (legacy data)" do
      let!(:user) { create(:user, :phone_only, :unregistered, phone_number: "+966508888888") }
      let(:phone) { "+966508888888" }

      before { user.update_column(:first_name, "") }

      it_behaves_like "a refused registration"
      it "never shows the record's own errors" do
        expect(result.error).not_to include(User.human_attribute_name(:first_name))
        expect(user.reload.encrypted_password).to be_blank
      end
    end

    it "answers unknown, registered, inactive and ambiguous numbers identically" do
      create(:user, :phone_only, phone_number: "+966506666666")
      create(:user, :phone_only, :unregistered, phone_number: "+966507777777", active: false)
      create(:user, :phone_only, :unregistered, phone_number: "01012345678")
      create(:user, :phone_only, :unregistered, phone_number: "+201012345678")

      errors = [ "+966500000000", "+966506666666", "+966507777777", "201012345678" ].map { |p| register(p).error }
      expect(errors.uniq).to eq([ generic_error ])
    end
  end

  describe "tenancy" do
    let(:business_a) { create(:business) }
    let(:business_b) { create(:business) }
    let!(:pending_b) { create(:user, :phone_only, :unregistered, business: business_b, phone_number: "+966509990000") }

    it "activates only the matching account, in its own business" do
      create(:user, :phone_only, :unregistered, business: business_a, phone_number: "+966509990001")
      outcome = register("+966509990000")
      expect(outcome.user).to eq(pending_b)
      expect(pending_b.reload.business).to eq(business_b)
      expect(AuditLog.last.business_id).to eq(business_b.id)
      expect(User.where(business: business_a).where.not(encrypted_password: [ nil, "" ])).to be_empty
    end

    it "accepts no business or other attribute (unknown keywords are rejected)" do
      expect {
        described_class.call(phone_number: "+966509990000", password: password,
                             password_confirmation: password, business_id: business_a.id)
      }.to raise_error(ArgumentError)
      expect(pending_b.reload.encrypted_password).to be_blank
    end
  end
end
