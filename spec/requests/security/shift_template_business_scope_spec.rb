require "rails_helper"

# BUG-031 — a crafted shift-template request naming another business's shift
# or rule profile is refused and writes nothing (the form lists only own ones).
RSpec.describe "Shift templates refuse another business's shift or rule profile (BUG-031)", type: :request do
  let(:business)      { create(:business) }
  let(:owner)         { create(:user, :super_admin, business: business) }
  let(:shift)         { create(:shift, :fixed_time, business: business) }
  let(:other)         { create(:business) }
  let(:foreign_shift) { create(:shift, :fixed_time, business: other) }
  let(:foreign_rules) { create(:shift_rule_profile, business: other) }

  def params_with(**entry)
    { shift_template: { name: "Week plan", active: true,
                        entries_attributes: { "0" => { starts_on: Date.current.to_s, shift_id: shift.id }.merge(entry) } } }
  end

  before { sign_in owner }

  it "refuses creating a template with another business's shift" do
    expect { post admin_shift_templates_path, params: params_with(shift_id: foreign_shift.id) }
      .not_to change { [ ShiftTemplate.count, ShiftTemplateEntry.count ] }
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "refuses creating a template with another business's rule profile" do
    expect { post admin_shift_templates_path, params: params_with(shift_rule_profile_id: foreign_rules.id) }
      .not_to change { [ ShiftTemplate.count, ShiftTemplateEntry.count ] }
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "refuses updating an entry to another business's shift" do
    template = create(:shift_template, business: business, created_by: owner)
    entry    = create(:shift_template_entry, shift_template: template, shift: shift)

    patch admin_shift_template_path(template), params: { shift_template: {
      entries_attributes: { "0" => { id: entry.id, shift_id: foreign_shift.id } }
    } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(entry.reload.shift_id).to eq(shift.id)
  end

  it "still creates a template with the business's own shift" do
    expect { post admin_shift_templates_path, params: params_with }.to change(ShiftTemplate, :count).by(1)
  end
end
