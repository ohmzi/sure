# frozen_string_literal: true

class AddClassificationCorroboratedToDocumentLinks < ActiveRecord::Migration[8.1]
  def change
    # Justified new column: N6's fourth auto-post condition is "the class is
    # corroborated (DocumentClassifier)" (spec §7.4), and that condition was
    # UNENFORCEABLE — the classifier's `corroborated` verdict was computed and
    # thrown away, and `AutoPost#class_corroborated?` could only read
    # `classified_by == "ai"`, which treats a confidently-asserted-but-
    # uncorroborated class as if the deterministic witness had agreed. This
    # column persists the classifier's boolean so the gate can require the real
    # witness.
    #
    # Nullable, and NULL reads as NOT corroborated (the gate requires `== true`),
    # so every historical row — and any future write path that forgets to set it
    # — fails SAFE: no money is ever written on a class the witness did not
    # confirm. No backfill: the historical corroboration verdicts no longer
    # exist, so inventing one would be a guess, and a guess on this column is a
    # money-write.
    add_column :document_links, :classification_corroborated, :boolean
  end
end
