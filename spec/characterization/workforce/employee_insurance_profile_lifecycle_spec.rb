require "rails_helper"

# Characterization (Pilot 8 — Workforce Employee Insurance Profile, M1) —
# CURRENT behaviour of the profile's lifecycle: model rules and
# Employee::InsuranceProfileUpdater (create / update / validation failure /
# audit / the payroll recalculation it triggers).
#
# Already pinned elsewhere, not repeated: open vs locked periods recalculated and
# a raising recalculation not failing the change (spec/services/employee/
# insurance_profile_updater_spec.rb); the payroll notice states (spec/requests/
# admin/employee_insurance_profiles_spec.rb); SEC-P8-1 / SEC-P8-2
# (spec/requests/security/employee_insurance_profile_*_spec.rb).
RSpec.describe "Characterization: employee insurance profile lifecycle" do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let(:employee) { create(:user, business: business) }
  let(:actor)    { create(:user, business: business) }

  let(:insured_attrs) do
    { insured: true, employee_contribution_amount: 500, employer_contribution_amount: 1_000,
      insurance_start_date: Date.new(2026, 1, 1), insurance_number: "INS-1", notes: "HR note" }
  end

  def update(attrs, user: employee, by: actor)
    Employee::InsuranceProfileUpdater.call(user_id: user.id, actor: by, attrs: attrs)
  end

  def audits = AuditLog.where(auditable_type: "EmployeeInsuranceProfile").order(:id)

  before { allow(Payroll::EntryRecalculator).to receive(:recalculate_all_open_periods_for) }

  describe "model rules" do
    def build(**attrs)
      EmployeeInsuranceProfile.new(business: business, user: employee, created_by: actor, **attrs)
    end

    it "defaults to not insured with zero contributions; a start date is then optional" do
      profile = build
      expect(profile).to have_attributes(insured: false, employee_contribution_amount: 0, employer_contribution_amount: 0)
      expect(profile).to be_valid
    end

    it "an insured profile needs a start date; end date, number and notes are optional" do
      expect(build(insured: true)).not_to be_valid
      expect(build(insured: true).tap(&:valid?).errors[:insurance_start_date]).to be_present
      expect(build(insured: true, insurance_start_date: Date.new(2026, 1, 1))).to be_valid
    end

    it "contributions must be >= 0 when insured (zero allowed)" do
      base = { insured: true, insurance_start_date: Date.new(2026, 1, 1) }
      expect(build(**base, employee_contribution_amount: -1)).not_to be_valid
      expect(build(**base, employer_contribution_amount: -1)).not_to be_valid
      expect(build(**base, employee_contribution_amount: 0, employer_contribution_amount: 0)).to be_valid
    end

    it "the end date must be on or after the start date (same day allowed)" do
      base = { insured: true, insurance_start_date: Date.new(2026, 3, 1) }
      invalid = build(**base, insurance_end_date: Date.new(2026, 2, 28))
      expect(invalid).not_to be_valid
      expect(invalid.errors[:insurance_end_date]).to include("must be on or after the start date")
      expect(build(**base, insurance_end_date: Date.new(2026, 3, 1))).to be_valid
    end

    it "not insured: contributions are zeroed on validation, even negative or positive input" do
      profile = build(insured: false, employee_contribution_amount: 300, employer_contribution_amount: -5)
      expect(profile).to be_valid
      expect(profile).to have_attributes(employee_contribution_amount: 0, employer_contribution_amount: 0)
    end

    it "one profile per employee (uniqueness on user, also a unique index)" do
      build(insured: false).save!
      duplicate = build(insured: false)
      expect(duplicate).not_to be_valid
      expect { duplicate.save(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "covers_period? — insured and the coverage window overlaps the period" do
      profile = build(insured: true, insurance_start_date: Date.new(2026, 3, 15), insurance_end_date: Date.new(2026, 5, 10))
      expect(profile.covers_period?(Date.new(2026, 3, 1), Date.new(2026, 3, 31))).to be(true)  # starts mid-period
      expect(profile.covers_period?(Date.new(2026, 5, 1), Date.new(2026, 5, 31))).to be(true)  # ends mid-period
      expect(profile.covers_period?(Date.new(2026, 2, 1), Date.new(2026, 2, 28))).to be(false) # before start
      expect(profile.covers_period?(Date.new(2026, 6, 1), Date.new(2026, 6, 30))).to be(false) # after end
      expect(build(insured: true, insurance_start_date: Date.new(2026, 1, 1))
               .covers_period?(Date.new(2030, 1, 1), Date.new(2030, 1, 31))).to be(true)       # open-ended
      expect(build(insured: false).covers_period?(Date.new(2026, 3, 1), Date.new(2026, 3, 31))).to be(false)
    end

    it "associations: business, user, created_by; Business and User own the inverse (dependent: :destroy)" do
      expect(EmployeeInsuranceProfile.reflect_on_all_associations.map(&:name)).to contain_exactly(:business, :user, :created_by)
      expect(Business.reflect_on_association(:employee_insurance_profiles).options).to include(dependent: :destroy)
      expect(User.reflect_on_association(:employee_insurance_profile)).to have_attributes(macro: :has_one)
      expect(User.reflect_on_association(:employee_insurance_profile).options).to include(dependent: :destroy)
    end
  end

  describe "Employee::InsuranceProfileUpdater — create" do
    it "creates the profile in the employee's business, created_by the actor, with every submitted attribute" do
      result = update(insured_attrs)

      expect(result.ok?).to be(true)
      expect(result.profile).to be_persisted
      expect(result.profile).to have_attributes(user: employee, business: business, created_by: actor, insured: true,
                                                employee_contribution_amount: 500, employer_contribution_amount: 1_000,
                                                insurance_start_date: Date.new(2026, 1, 1), insurance_number: "INS-1",
                                                notes: "HR note")
    end

    it "audits insurance_profile_created with before / after of the six insurance fields (notes not included)" do
      update(insured_attrs)

      log = audits.last
      expect(log).to have_attributes(action: "insurance_profile_created", actor_id: actor.id, business_id: business.id)
      expect(log.changes_json.keys).to contain_exactly("before", "after")
      fields = %w[insured employee_contribution_amount employer_contribution_amount
                  insurance_start_date insurance_end_date insurance_number]
      expect(log.changes_json["before"].keys).to match_array(fields)
      expect(log.changes_json["after"].keys).to match_array(fields)
      expect(log.changes_json["before"]["insured"]).to be(false)
      expect(log.changes_json["after"]).to include("insured" => true, "insurance_number" => "INS-1")
      expect(log.changes_json["after"]["employee_contribution_amount"].to_d).to eq(500)
    end
  end

  describe "Employee::InsuranceProfileUpdater — update" do
    let!(:profile) do
      EmployeeInsuranceProfile.create!(business: business, user: employee, created_by: employee, **insured_attrs)
    end

    it "updates the same record in place; created_by stays the original creator" do
      result = update({ employee_contribution_amount: 650, insurance_end_date: Date.new(2026, 12, 31) })

      expect(result.profile.id).to eq(profile.id)
      expect(profile.reload).to have_attributes(employee_contribution_amount: 650, insurance_end_date: Date.new(2026, 12, 31),
                                                created_by: employee, employer_contribution_amount: 1_000)
      expect(EmployeeInsuranceProfile.where(user: employee).count).to eq(1)
    end

    it "audits insurance_profile_updated with the before and after values" do
      update({ employee_contribution_amount: 650 })

      log = audits.last
      expect(log.action).to eq("insurance_profile_updated")
      expect(log.changes_json["before"]["employee_contribution_amount"].to_d).to eq(500)
      expect(log.changes_json["after"]["employee_contribution_amount"].to_d).to eq(650)
    end

    it "switching to not insured zeroes both contributions and keeps the dates and number" do
      update({ insured: false })

      expect(profile.reload).to have_attributes(insured: false, employee_contribution_amount: 0, employer_contribution_amount: 0,
                                                insurance_start_date: Date.new(2026, 1, 1), insurance_number: "INS-1")
      expect(audits.last.changes_json["after"]).to include("insured" => false)
    end

    it "an invalid change returns ok: false with the messages, saves nothing, audits nothing, recalculates nothing" do
      result = update({ insurance_end_date: Date.new(2025, 1, 1) })

      expect(result.ok?).to be(false)
      expect(result.error).to include("must be on or after the start date")
      expect(result.profile.errors[:insurance_end_date]).to be_present
      expect(profile.reload.insurance_end_date).to be_nil
      expect(audits).to be_empty
      expect(Payroll::EntryRecalculator).not_to have_received(:recalculate_all_open_periods_for)
    end
  end

  describe "Employee::InsuranceProfileUpdater — tenant boundary" do
    it "an employee of another business: ok: false (RecordNotFound message), nothing created, no recalculation" do
      foreign = create(:user, business: other)

      result = nil
      expect { result = update(insured_attrs, user: foreign) }.not_to change(EmployeeInsuranceProfile, :count)
      expect(result.ok?).to be(false)
      expect(result.error).to match(/Couldn't find User/)
      expect(Payroll::EntryRecalculator).not_to have_received(:recalculate_all_open_periods_for)
    end

    it "authorization is not the updater's job: it does not check the actor's permissions or scope (callers authorize)" do
      expect(update(insured_attrs, by: create(:user, business: business)).ok?).to be(true)
    end
  end

  describe "the Workforce → Attendance & Payroll recalculation it triggers" do
    it "after a successful save it calls Payroll::EntryRecalculator.recalculate_all_open_periods_for(user:, triggered_by:) once" do
      update(insured_attrs)

      expect(Payroll::EntryRecalculator).to have_received(:recalculate_all_open_periods_for)
        .once.with(user: employee, triggered_by: actor)
    end

    it "it is called on every successful save, even when nothing changed" do
      update(insured_attrs)
      update(insured_attrs)

      expect(Payroll::EntryRecalculator).to have_received(:recalculate_all_open_periods_for).twice
    end

    it "it runs after the profile and its audit are committed: a raising recalculation leaves both in place, ok: true" do
      allow(Payroll::EntryRecalculator).to receive(:recalculate_all_open_periods_for).and_raise(StandardError, "boom")
      allow(Rails.logger).to receive(:error)

      result = update(insured_attrs)

      expect(result.ok?).to be(true)
      expect(employee.reload.employee_insurance_profile).to be_present
      expect(audits.last.action).to eq("insurance_profile_created")
      expect(Rails.logger).to have_received(:error).with(/\[Employee::InsuranceProfileUpdater\] payroll recalc failed user=#{employee.id}: StandardError: boom/)
    end
  end
end
