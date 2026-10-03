require "rails_helper"

RSpec.describe Api::ListQuery do
  let(:users) { User.arel_table }

  subject(:query) do
    described_class.new(
      filters: {
        active:          { column: users[:active],          type: :boolean },
        employment_type: { column: users[:employment_type], type: :enum, values: %w[full_time part_time] },
        id:              { column: users[:id],              type: :integer },
        hired_from:      { column: users[:hire_date],       type: :date, operator: :gteq },
        code:            { column: users[:employee_code],   type: :string }
      },
      sorts:        { "first_name" => users[:first_name], "hire_date" => users[:hire_date] },
      default_sort: "first_name",
      tiebreaker:   users[:id],
      search:       [ users[:first_name], users[:last_name] ]
    )
  end

  let(:business) { create(:business) }
  let!(:ali)     { create(:user, business: business, first_name: "Ali",  last_name: "Zed",  employment_type: "full_time", hire_date: Date.new(2024, 1, 1)) }
  let!(:bea)     { create(:user, business: business, first_name: "Bea",  last_name: "Yan",  employment_type: "part_time", hire_date: Date.new(2025, 6, 1)) }
  let!(:cam)     { create(:user, business: business, first_name: "Cam%", last_name: "Xu",   employment_type: "full_time", hire_date: Date.new(2026, 1, 1), active: false) }
  let!(:foreign) { create(:user, first_name: "Ali", employment_type: "full_time") }

  let(:scope) { User.where(business_id: business.id) }

  def run(params) = query.apply(scope, ActionController::Parameters.new(params)).to_a

  def expect_bad_request(params, code)
    expect { run(params) }.to raise_error(Api::Errors::BadRequest) { |e| expect(e.details.first[:code]).to eq(code) }
  end

  describe "filters" do
    it "applies allowlisted filters with typed values" do
      expect(run(filter: { employment_type: "full_time" })).to eq([ ali, cam ])
      expect(run(filter: { active: "false" })).to eq([ cam ])
      expect(run(filter: { hired_from: "2025-01-01" })).to eq([ bea, cam ])
      expect(run(filter: { id: bea.id.to_s })).to eq([ bea ])
      expect(run(filter: { employment_type: %w[full_time part_time] })).to eq([ ali, bea, cam ])
    end

    it "rejects unknown filters instead of ignoring them" do
      expect_bad_request({ filter: { business_id: "1" } }, "unknown_filter")
    end

    it "rejects values outside the allowlist or of the wrong type" do
      expect_bad_request({ filter: { employment_type: "owner" } }, "invalid")
      expect_bad_request({ filter: { active: "yes" } }, "invalid")
      expect_bad_request({ filter: { id: "1 OR 1=1" } }, "invalid")
      expect_bad_request({ filter: { hired_from: "2025-13-45" } }, "invalid")
      expect_bad_request({ filter: { id: { nested: "1" } } }, "invalid")
      expect_bad_request({ filter: "active" }, "invalid")
    end

    it "rejects array values for range operators" do
      expect_bad_request({ filter: { hired_from: [ "2025-01-01" ] } }, "invalid")
    end

    it "binds string values instead of interpolating them" do
      expect(run(filter: { code: "x' OR '1'='1" })).to eq([])
    end

    it "can never widen the given scope (cross-business rows stay out)" do
      expect(run(filter: { id: foreign.id.to_s })).to eq([])
      expect(run(q: "Ali")).to eq([ ali ])
    end
  end

  describe "search" do
    it "matches allowlisted columns case-insensitively" do
      expect(run(q: "yan")).to eq([ bea ])
    end

    it "treats LIKE wildcards literally" do
      expect(run(q: "%")).to eq([ cam ])
      expect(run(q: "_")).to eq([])
    end

    it "ignores a blank term and rejects an overlong one" do
      expect(run(q: "  ").size).to eq(3)
      expect_bad_request({ q: "a" * 101 }, "too_long")
    end

    it "rejects search on endpoints without search columns" do
      no_search = described_class.new(tiebreaker: users[:id])
      expect { no_search.apply(scope, ActionController::Parameters.new(q: "x")) }
        .to raise_error(Api::Errors::BadRequest)
    end
  end

  describe "sorting" do
    it "uses the default sort" do
      expect(run({})).to eq([ ali, bea, cam ])
    end

    it "sorts descending with a - prefix and by multiple fields" do
      expect(run(sort: "-first_name")).to eq([ cam, bea, ali ])
      expect(run(sort: "-hire_date,first_name")).to eq([ cam, bea, ali ])
    end

    it "rejects unknown, duplicate, non-string or too many sort fields" do
      expect_bad_request({ sort: "encrypted_password" }, "unknown_sort")
      expect_bad_request({ sort: "first_name,-first_name" }, "invalid")
      expect_bad_request({ sort: [ "first_name" ] }, "invalid")
      expect_bad_request({ sort: "a,b,c,d" }, "invalid")
    end

    it "replaces any order already on the relation and always adds the tiebreaker" do
      sql = query.apply(scope.order(:last_name), ActionController::Parameters.new(sort: "first_name")).to_sql
      expect(sql).not_to include("last_name")
      expect(sql).to match(/ORDER BY "users"\."first_name" ASC, "users"\."id" ASC/)
    end
  end

  describe "configuration" do
    it "fails fast on invalid configuration" do
      expect { described_class.new(tiebreaker: users[:id], filters: { x: { column: users[:id], type: :regex } }) }
        .to raise_error(ArgumentError)
      expect { described_class.new(tiebreaker: users[:id], filters: { x: { column: users[:id], type: :enum } }) }
        .to raise_error(ArgumentError)
      expect { described_class.new(tiebreaker: users[:id], sorts: {}, default_sort: "nope") }
        .to raise_error(Api::Errors::BadRequest)
    end
  end
end
