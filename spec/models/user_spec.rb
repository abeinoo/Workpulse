require "rails_helper"

RSpec.describe User, type: :model do
  subject(:user) { build(:user) }

  # ── Associations ──────────────────────────────────────────────────────────
  describe "associations" do
    it { is_expected.to belong_to(:business) }
    it { is_expected.to belong_to(:manager).optional }
    it { is_expected.to have_many(:managed_employees).dependent(:nullify) }
    it { is_expected.to have_many(:user_branches).dependent(:destroy) }
    it { is_expected.to have_many(:branches).through(:user_branches) }
    it { is_expected.to have_many(:salary_profiles).dependent(:destroy) }
    it { is_expected.to have_many(:shift_assignments).dependent(:destroy) }
    it { is_expected.to have_many(:attendance_records).dependent(:destroy) }
    it { is_expected.to have_many(:employee_requests).dependent(:destroy) }
    it { is_expected.to have_many(:advances).dependent(:destroy) }
    it { is_expected.to have_many(:payroll_entries).dependent(:destroy) }
  end

  # ── Validations ───────────────────────────────────────────────────────────
  describe "validations" do
    it { is_expected.to validate_presence_of(:first_name) }
    it { is_expected.to validate_presence_of(:last_name) }
    it { is_expected.to validate_presence_of(:role) }

    describe "email uniqueness" do
      it "rejects a duplicate email (case-insensitive)" do
        create(:user, email: "same@example.com")
        duplicate = build(:user, email: "SAME@EXAMPLE.COM")
        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:email]).to be_present
      end

      it "accepts a blank email (phone-only user)" do
        expect(build(:user, :phone_only)).to be_valid
      end

      it "rejects a malformed email" do
        expect(build(:user, email: "not-an-email")).not_to be_valid
      end
    end

    describe "phone_number uniqueness" do
      it "rejects a duplicate phone number" do
        create(:user, :with_phone, phone_number: "+966500000001")
        duplicate = build(:user, :phone_only, phone_number: "+966500000001")
        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:phone_number]).to be_present
      end

      it "allows blank phone number" do
        expect(build(:user)).to be_valid
      end
    end

    describe "phone_or_email_present" do
      it "is invalid when both email and phone_number are blank" do
        user = build(:user, email: nil, phone_number: nil)
        expect(user).not_to be_valid
        expect(user.errors[:base]).to include("Phone number or email must be present")
      end

      it "is valid with only email" do
        expect(build(:user, phone_number: nil)).to be_valid
      end

      it "is valid with only phone_number" do
        expect(build(:user, :phone_only)).to be_valid
      end
    end

    describe "password" do
      it "validates minimum length when password is set" do
        expect(build(:user, password: "short", password_confirmation: "short")).not_to be_valid
      end

      it "skips password validation when password is blank" do
        user = build(:user, :unregistered)
        # no password set — should still be valid (pre-created by admin)
        user.valid?
        expect(user.errors[:password]).to be_empty
      end
    end
  end

  # ── employee_code ─────────────────────────────────────────────────────────
  describe "employee_code" do
    let(:business) { create(:business) }

    it "accepts a blank employee_code" do
      expect(build(:user, business: business, employee_code: nil)).to be_valid
    end

    it "strips leading/trailing whitespace on normalization" do
      u = build(:user, business: business, employee_code: "  EMP001  ")
      u.valid?
      expect(u.employee_code).to eq("EMP001")
    end

    it "normalizes blank strings to nil" do
      u = build(:user, business: business, employee_code: "   ")
      u.valid?
      expect(u.employee_code).to be_nil
    end

    it "rejects a duplicate employee_code within the same business (case-insensitive)" do
      create(:user, business: business, employee_code: "EMP001")
      duplicate = build(:user, business: business, employee_code: "emp001")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:employee_code]).to be_present
    end

    it "allows the same employee_code in a different business" do
      other_business = create(:business)
      create(:user, business: business,       employee_code: "EMP001")
      user_other_biz  = build(:user, business: other_business, employee_code: "EMP001")
      expect(user_other_biz).to be_valid
    end

    it "allows multiple employees with blank employee_code in the same business" do
      create(:user, business: business, employee_code: nil)
      expect(build(:user, business: business, employee_code: nil)).to be_valid
    end
  end

  # ── Identity card ─────────────────────────────────────────────────────────
  describe "identity_card_number" do
    it "accepts a blank value" do
      expect(build(:user, identity_card_number: nil)).to be_valid
    end

    it "strips whitespace and upcases on normalization" do
      u = build(:user, identity_card_number: "  a1234567  ")
      u.valid?
      expect(u.identity_card_number).to eq("A1234567")
    end

    it "rejects a value shorter than 5 characters" do
      expect(build(:user, identity_card_number: "AB1")).not_to be_valid
    end

    it "rejects a value longer than 30 characters" do
      expect(build(:user, identity_card_number: "A" * 31)).not_to be_valid
    end

    it "rejects a duplicate identity card number" do
      create(:user, identity_card_number: "UNIQUE1234")
      duplicate = build(:user, identity_card_number: "unique1234")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:identity_card_number]).to be_present
    end
  end

  # ── Phone normalizer ──────────────────────────────────────────────────────
  describe "phone_number normalization" do
    it "preserves the leading + and strips non-digit characters" do
      u = build(:user, :phone_only, phone_number: "+966 05 123 4567")
      u.valid?
      expect(u.phone_number).to eq("+966051234567")
    end

    it "strips non-digit characters without + prefix" do
      u = build(:user, :phone_only, phone_number: "05-123-4567")
      u.valid?
      expect(u.phone_number).to eq("051234567")
    end

    it "does nothing when phone_number is blank" do
      u = build(:user, phone_number: "")
      u.valid?
      expect(u.phone_number).to eq("")
    end
  end

  # ── Scopes ────────────────────────────────────────────────────────────────
  describe "scopes" do
    let!(:active_user)   { create(:user) }
    let!(:inactive_user) { create(:user, :inactive) }

    describe ".active" do
      it "returns only active users" do
        expect(User.active).to include(active_user)
        expect(User.active).not_to include(inactive_user)
      end
    end

    describe ".inactive" do
      it "returns only inactive users" do
        expect(User.inactive).to include(inactive_user)
        expect(User.inactive).not_to include(active_user)
      end
    end

    describe ".staff" do
      let!(:admin) { create(:user, :super_admin) }

      it "excludes super_admin users" do
        expect(User.staff).not_to include(admin)
      end

      it "includes employees and branch_managers" do
        manager = create(:user, :branch_manager)
        expect(User.staff).to include(active_user, manager)
      end
    end
  end

  # ── .find_for_database_authentication ────────────────────────────────────
  describe ".find_for_database_authentication" do
    let!(:email_user) do
      create(:user, email: "ahmed@example.com", phone_number: nil)
    end
    let!(:phone_user) do
      create(:user, :phone_only, phone_number: "+966501234567")
    end

    it "finds a user by email" do
      expect(User.find_for_database_authentication(login: "ahmed@example.com")).to eq(email_user)
    end

    it "finds a user by email case-insensitively" do
      expect(User.find_for_database_authentication(login: "AHMED@EXAMPLE.COM")).to eq(email_user)
    end

    it "finds a user by phone number" do
      expect(User.find_for_database_authentication(login: "+966501234567")).to eq(phone_user)
    end

    it "strips whitespace around the login" do
      expect(User.find_for_database_authentication(login: "  ahmed@example.com  ")).to eq(email_user)
    end

    it "returns nil for an unrecognised login" do
      expect(User.find_for_database_authentication(login: "nobody@example.com")).to be_nil
    end

    it "returns nil for a blank login" do
      expect(User.find_for_database_authentication(login: "")).to be_nil
    end
  end

  # ── Manager relationship validations ─────────────────────────────────────
  describe "manager validations" do
    let(:business) { create(:business) }
    let(:manager)  { create(:user, :branch_manager, business: business) }

    describe "manager_must_be_branch_manager" do
      it "accepts a branch_manager as manager" do
        employee = build(:user, business: business, manager: manager)
        expect(employee).to be_valid
      end

      it "rejects a non-manager user as manager" do
        other_employee = create(:user, business: business)
        employee = build(:user, business: business, manager: other_employee)
        expect(employee).not_to be_valid
        expect(employee.errors[:manager]).to include("does not have the required role for this position")
      end

      it "rejects a super_admin as direct manager for an employee" do
        admin = create(:user, :super_admin, business: business)
        employee = build(:user, business: business, manager: admin)
        expect(employee).not_to be_valid
        expect(employee.errors[:manager]).to include("does not have the required role for this position")
      end

      it "permits super_admin as manager of a branch_manager" do
        admin = create(:user, :super_admin, business: business)
        bm = build(:user, :branch_manager, business: business, manager: admin)
        expect(bm).to be_valid
      end

      it "is valid with no manager assigned" do
        employee = build(:user, business: business, manager: nil)
        expect(employee).to be_valid
      end
    end

    describe "no_self_management" do
      it "rejects assigning oneself as manager" do
        mgr = create(:user, :branch_manager, business: business)
        mgr.manager = mgr
        expect(mgr).not_to be_valid
        expect(mgr.errors[:manager]).to include("cannot be yourself")
      end
    end
  end

  # ── #managed_employee_ids ─────────────────────────────────────────────────
  describe "#managed_employee_ids" do
    let(:business) { create(:business) }
    let(:manager)  { create(:user, :branch_manager, business: business) }

    it "returns IDs of directly managed employees" do
      emp1 = create(:user, business: business, manager: manager)
      emp2 = create(:user, business: business, manager: manager)
      expect(manager.managed_employee_ids).to match_array([emp1.id, emp2.id])
    end

    it "returns an empty array when no employees are assigned" do
      expect(manager.managed_employee_ids).to eq([])
    end

    it "does not include employees managed by a different manager" do
      other_manager = create(:user, :branch_manager, business: business)
      create(:user, business: business, manager: other_manager)
      expect(manager.managed_employee_ids).to be_empty
    end
  end

  # ── Instance methods ──────────────────────────────────────────────────────
  describe "#full_name" do
    it "concatenates first_name and last_name" do
      user = build(:user, first_name: "Ahmed", last_name: "Al-Zahrani")
      expect(user.full_name).to eq("Ahmed Al-Zahrani")
    end
  end

  describe "#role predicates" do
    it "returns true for the assigned role" do
      expect(build(:user, :super_admin).super_admin?).to be true
      expect(build(:user, :branch_manager).branch_manager?).to be true
      expect(build(:user, :employee).employee?).to be true
    end
  end
end
