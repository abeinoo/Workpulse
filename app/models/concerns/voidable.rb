# A posted inventory document that can be reversed ("voided") but never deleted
# or edited. Voiding is an accounting-style reversal: the original document and
# its ledger movements stay untouched; compensating movements are posted and the
# void metadata (who/when/why) is recorded.
#
# Requires the including table to have: voided_at (datetime), voided_by_id
# (references users), void_reason (text). Pairs with ImmutableDocument, which
# blocks destruction outright.
module Voidable
  extend ActiveSupport::Concern

  included do
    belongs_to :voided_by, class_name: "User", optional: true

    scope :active, -> { where(voided_at: nil) }
    scope :voided, -> { where.not(voided_at: nil) }

    validates :void_reason, presence: true, if: :voided?
  end

  def voided?
    voided_at.present?
  end

  def active?
    !voided?
  end

  # Distinct products touched by this document — the set whose cost must be
  # recomputed after a void.
  def affected_products
    items.map(&:product).uniq
  end
end
