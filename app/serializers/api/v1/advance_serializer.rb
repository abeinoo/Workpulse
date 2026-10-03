module Api
  module V1
    # Field set is identical to the legacy AdvancesController#advance_json it
    # replaces (locked by spec/requests/api/v1/characterization/advances_spec.rb).
    class AdvanceSerializer < BaseSerializer
      attributes :id, :user_id, :total_amount, :remaining_amount, :status, :issued_at
      attribute(:repaid_amount) { record.repaid_amount }
    end
  end
end
