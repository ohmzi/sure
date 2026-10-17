# frozen_string_literal: true

require Rails.root.join("lib/active_record_encryption_config").to_s

namespace :encryption do
  desc "Re-save records with encrypted attributes so pre-encryption plaintext becomes ciphertext"
  task backfill: :environment do
    unless ActiveRecordEncryptionConfig.ready?
      abort "ActiveRecord Encryption is not configured; set the three " \
            "ACTIVE_RECORD_ENCRYPTION_* keys first."
    end

    models = ActiveRecord::Base.descendants.select do |model|
      model.respond_to?(:encrypted_attributes) &&
        model.encrypted_attributes.present? &&
        model.table_exists?
    end.sort_by(&:name)

    total = 0
    failures = []

    models.each do |model|
      count = 0
      model.find_each do |record|
        begin
          # Through the encrypting writer. A plain, unchanged value would not
          # be marked dirty and would not be rewritten, so force each encrypted
          # attribute dirty first; the encrypting type then writes ciphertext.
          model.encrypted_attributes.each do |attribute|
            next unless record.has_attribute?(attribute) && record.public_send(attribute).present?

            record.public_send("#{attribute}_will_change!")
          end
          record.save!(validate: false)
          count += 1
        rescue => error
          failures << [ model.name, record.id, error.class.name, error.message ]
        end
      end
      total += count
      puts format("%-40s %d", model.name, count) if count.positive?
    end

    puts "Re-saved #{total} record(s); #{failures.size} failure(s)."
    failures.first(20).each { |failure| warn failure.inspect }
  end
end
