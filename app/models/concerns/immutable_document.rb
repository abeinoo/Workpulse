# Marks a posted inventory document (goods receipt, stock issue, stock transfer)
# as immutable: it can never be deleted once created.
#
# Inventory movements are the source of truth for stock and cost. Deleting a
# posted document would remove its movements (silently reversing stock) WITHOUT
# recomputing the affected products' moving-average / last-purchase cost, leaving
# valuation corrupt. To undo a document you post a compensating one, never delete.
#
# The guard is a prepended before_destroy so it fires before any dependent
# (items / movements) cascade is touched, and it RAISES rather than quietly
# returning false — a stray `destroy` in the console or future code fails loudly.
module ImmutableDocument
  extend ActiveSupport::Concern

  # Raised on any attempt to delete an immutable document.
  class DeletionNotAllowedError < StandardError; end

  included do
    before_destroy :prevent_destruction, prepend: true, unless: :destroyable_as_draft?
  end

  # Overridable per model: true only for a genuine pre-workflow draft with no
  # posted effects yet (see StockIssue#destroyable_as_draft?). False for every
  # other document, which is what keeps this concern's default behavior
  # unconditional for GoodsReceipt/StockTransfer/StockCount.
  def destroyable_as_draft?
    false
  end

  private

  def prevent_destruction
    raise DeletionNotAllowedError,
          "#{self.class.name} ##{id} cannot be deleted — posted inventory documents " \
          "are immutable. Deleting one would corrupt stock and cost history. " \
          "Post a compensating document to reverse it instead."
  end
end
