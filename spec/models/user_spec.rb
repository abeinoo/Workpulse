require "rails_helper"

RSpec.describe User, type: :model do
  subject(:user) { build(:user) }

  # ── Associations ──────────────────────────────────────────────────────────
  describe "associations" do
    it { is_expected.to belong_to(:business) }
    it { is_expected.to belong_to(:manager).optional }
    it { is_expected.to belong_to(:permission_role).optional }
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

  # ── Devise authentication gate ────────────────────────────────────────────
  describe "#active_for_authentication?" do
    it "returns true for an active user" do
      expect(build(:user, active: true).active_for_authentication?).to be true
    end

    it "returns false for an inactive user" do
      expect(build(:user, active: false).active_for_authentication?).to be false
    end
  end

  describe "#inactive_message" do
    it "returns :inactive for a deactivated user" do
      expect(build(:user, active: false).inactive_message).to eq(:inactive)
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
    let(:business)       { create(:business) }
    let(:other_business) { create(:business) }

    describe "validate_manager_in_same_business" do
      it "accepts any user in the same business as manager" do
        manager  = create(:user, business: business)
        employee = build(:user, business: business, manager: manager)
        expect(employee).to be_valid
      end

      it "rejects a manager from a different business" do
        other_manager = create(:user, business: other_business)
        employee = build(:user, business: business, manager: other_manager)
        expect(employee).not_to be_valid
        expect(employee.errors[:manager]).to include("must belong to the same business")
      end

      it "is valid with no manager assigned" do
        employee = build(:user, business: business, manager: nil)
        expect(employee).to be_valid
      end
    end

    describe "no_self_management" do
      it "rejects assigning oneself as manager" do
        mgr = create(:user, business: business)
        mgr.manager = mgr
        expect(mgr).not_to be_valid
        expect(mgr.errors[:manager]).to include("cannot be yourself")
      end
    end
  end

  # ── #managed_employee_ids ─────────────────────────────────────────────────
  describe "#managed_employee_ids" do
    let(:business) { create(:business) }
    let(:manager)  { create(:user, business: business) }

    it "returns IDs of directly managed employees" do
      emp1 = create(:user, business: business, manager: manager)
      emp2 = create(:user, business: business, manager: manager)
      expect(manager.managed_employee_ids).to match_array([emp1.id, emp2.id])
    end

    it "returns an empty array when no employees are assigned" do
      expect(manager.managed_employee_ids).to eq([])
    end

    it "does not include employees managed by a different manager" do
      other_manager = create(:user, business: business)
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

  describe "#owner?" do
    let(:business) { create(:business) }

    it "returns true when the user is the business owner" do
      owner = create(:user, :owner, business: business)
      expect(owner.owner?).to be true
    end

    it "returns false for a regular staff member" do
      staff = create(:user, business: business)
      expect(staff.owner?).to be false
    end
  end

  describe "#can?" do
    let(:business) { create(:business) }

    it "returns true for any permission when the user is the owner" do
      owner = create(:user, :owner, business: business)
      expect(owner.can?(:view_payroll)).to be true
      expect(owner.can?(:manage_employees)).to be true
    end

    it "returns false when the user has no permission role" do
      staff = create(:user, business: business)
      expect(staff.can?(:view_payroll)).to be false
    end

    it "delegates to the permission_role when present" do
      role = create(:permission_role, business: business, permissions: %w[view_payroll])
      staff = create(:user, business: business, permission_role: role)
      expect(staff.can?(:view_payroll)).to be true
      expect(staff.can?(:manage_payroll)).to be false
    end
  end

  describe "#manages_branch?" do
    let(:business) { create(:business) }

    it "returns true when the user is set as branch_manager_id on a branch" do
      manager = create(:user, :branch_manager, business: business)
      expect(manager.manages_branch?).to be true
    end

    it "returns false for a plain employee" do
      employee = create(:user, business: business)
      expect(employee.manages_branch?).to be false
    end
  end

  describe "#manages_area?" do
    let(:business) { create(:business) }

    it "returns true when the user is set as area_manager_id on a branch" do
      area_mgr = create(:user, :area_manager, business: business)
      expect(area_mgr.manages_area?).to be true
    end

    it "returns false for a plain employee" do
      employee = create(:user, business: business)
      expect(employee.manages_area?).to be false
    end
  end

  describe "#profile_completion_percentage" do
    let(:business) { create(:business) }

    it "returns 0 when only required fields are set" do
      user = build_stubbed(:user,
        business:                business,
        phone_number:            nil,
        email:                   nil,
        job_title:               nil,
        department:              nil,
        hire_date:               nil,
        employment_type:         nil,
        emergency_contact_name:  nil,
        emergency_contact_phone: nil,
        identity_card_number:    nil
      )
      allow(user.profile_photo).to receive(:attached?).and_return(false)
      expect(user.profile_completion_percentage).to eq(0)
    end

    it "returns 100 when all completion fields are set" do
      user = build_stubbed(:user,
        business:                business,
        phone_number:            "+966500000001",
        email:                   "full@example.com",
        job_title:               "Engineer",
        department:              "Engineering",
        hire_date:               Date.new(2024, 1, 1),
        employment_type:         "full_time",
        emergency_contact_name:  "Dad",
        emergency_contact_phone: "+966500000002",
        identity_card_number:    "A12345678"
      )
      allow(user.profile_photo).to receive(:attached?).and_return(true)
      expect(user.profile_completion_percentage).to eq(100)
    end

    it "returns a percentage proportional to filled fields" do
      user = build_stubbed(:user,
        business:                business,
        phone_number:            "+966500000001",
        email:                   nil,
        job_title:               "Engineer",
        department:              nil,
        hire_date:               nil,
        employment_type:         nil,
        emergency_contact_name:  nil,
        emergency_contact_phone: nil,
        identity_card_number:    nil
      )
      allow(user.profile_photo).to receive(:attached?).and_return(false)
      # 2 of 10 filled = 20%
      expect(user.profile_completion_percentage).to eq(20)
    end

    it "returns between 0 and 100" do
      user = build_stubbed(:user, business: business)
      allow(user.profile_photo).to receive(:attached?).and_return(false)
      expect(user.profile_completion_percentage).to be_between(0, 100)
    end
  end

  describe "#profile_completion_grade" do
    let(:business) { create(:business) }

    it "returns :complete for >= 90%" do
      user = build_stubbed(:user, business: business)
      allow(user).to receive(:profile_completion_percentage).and_return(95)
      expect(user.profile_completion_grade).to eq(:complete)
    end

    it "returns :partial for 60-89%" do
      user = build_stubbed(:user, business: business)
      allow(user).to receive(:profile_completion_percentage).and_return(70)
      expect(user.profile_completion_grade).to eq(:partial)
    end

    it "returns :incomplete for < 60%" do
      user = build_stubbed(:user, business: business)
      allow(user).to receive(:profile_completion_percentage).and_return(30)
      expect(user.profile_completion_grade).to eq(:incomplete)
    end
  end

  describe "employment_type enum" do
    it "accepts valid employment types" do
      User::EMPLOYMENT_TYPES.each do |type|
        user = build_stubbed(:user, employment_type: type)
        expect(user.employment_type).to eq(type)
      end
    end

    it "allows nil employment_type" do
      user = build_stubbed(:user, employment_type: nil)
      expect(user.employment_type).to be_nil
    end
  end

  describe "notification preferences" do
    let(:pref_user) { create(:user) }

    it "enables every category by default" do
      Notification::CATEGORIES.each do |cat|
        expect(pref_user.notification_enabled?(cat)).to be(true)
      end
    end

    it "can disable a single category and persist it" do
      pref_user.set_notification_preference("payroll", false)
      expect(pref_user.reload.notification_enabled?("payroll")).to be(false)
      expect(pref_user.notification_enabled?("attendance")).to be(true)
    end

    it "can re-enable a previously disabled category" do
      pref_user.set_notification_preference("leave", false)
      pref_user.set_notification_preference("leave", true)
      expect(pref_user.reload.notification_enabled?("leave")).to be(true)
    end

    it "treats unknown categories as enabled and ignores writes to them" do
      expect(pref_user.notification_enabled?("nonsense")).to be(true)
      expect { pref_user.set_notification_preference("nonsense", false) }
        .not_to change { pref_user.reload.notification_preferences }
    end

    it "coerces string booleans" do
      pref_user.set_notification_preference("system", "0")
      expect(pref_user.reload.notification_enabled?("system")).to be(false)
    end
  end
end
