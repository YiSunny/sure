class Trading212Statement < ApplicationRecord
  include Encryptable

  belongs_to :trading212_account
  belongs_to :user

  encrypts :rows, :result if encryption_ready?
  enum :status, { preview: "preview", applied: "applied" }, default: :preview
  validates :checksum, presence: true, uniqueness: { scope: :trading212_account_id }
  validate :user_and_account_share_family

  def self.category_for(family, name)
    family.categories.find_or_create_by!(name: name) do |category|
      category.color = Category::UNCATEGORIZED_COLOR
      category.lucide_icon = "tag"
    end
  end

  def preview_result
    return result.symbolize_keys.slice(:matched, :conflicts, :skipped, :coverage_start, :coverage_end) if applied?

    Trading212Statement::Reconciler.new(self).preview
  end

  def apply!(actor:)
    trading212_account.with_connection_lock { apply_under_connection_lock!(actor: actor) }
  end

  def revert!(actor:)
    trading212_account.with_connection_lock { revert_under_connection_lock!(actor: actor) }
  end

  def authorize!(actor)
    account = trading212_account.current_account
    raise ActiveRecord::RecordNotFound unless account && actor.family_id == account.family_id &&
      Account.writable_by(actor).exists?(id: account.id)
  end

  private

    def apply_under_connection_lock!(actor:)
      with_lock do
        authorize!(actor)
        return result if applied?
        raise ArgumentError, "Wait for the provider sync to finish" if trading212_account.trading212_item.syncs.visible.exists?

        summary = nil
        trading212_account.with_lock do
          reconciler = Trading212Statement::Reconciler.new(self)
          summary = reconciler.preview
          raise ArgumentError, "Resolve statement conflicts before applying" if summary[:conflicts].any?
          raise ArgumentError, "No matching cash records in selected account" if summary[:matched].empty?
          enrichments = trading212_account.statement_enrichments.deep_dup
          self.result = result.merge("previous_enrichments" => summary[:matched].to_h { |row| [ row.fetch("reference"), enrichments[row.fetch("reference")] ] })
          summary[:matched].each { |row| enrichments[row.fetch("reference")] = row.except("state") }
          trading212_account.update!(statement_enrichments: enrichments)
          reconciler.apply_entries!(summary[:matched])
        end
        update!(status: :applied, result: summary.merge(before_values: result["before_values"] || {},
          after_values: result["after_values"] || {},
          previous_enrichments: result["previous_enrichments"] || {}), coverage_start: summary[:coverage_start], coverage_end: summary[:coverage_end])
        result
      end
    end

    def revert_under_connection_lock!(actor:)
      with_lock do
        authorize!(actor)
        return result unless applied?
        raise ArgumentError, "Wait for the provider sync to finish" if trading212_account.trading212_item.syncs.visible.exists?

        trading212_account.with_lock do
          enrichments = trading212_account.statement_enrichments.deep_dup
          references = result.fetch("matched").map { |row| row.fetch("reference") }
          reviewed_cashback = trading212_account.split_audit_payload.fetch("cashback_allocations", {}).keys
          raise ArgumentError, "Cashback funding was reviewed; review its allocation before reversing classifications" if (references & reviewed_cashback).any?
          references.each do |reference|
            current = enrichments[reference]
            raise ArgumentError, "A later statement changed this reference; revert the newer batch first" unless current && current["statement_checksum"] == checksum
          end
          references.each do |reference|
            previous = result.fetch("previous_enrichments", {})[reference]
            previous ? enrichments[reference] = previous : enrichments.delete(reference)
          end
          result.fetch("before_values", {}).each do |entry_id, before|
            entry = trading212_account.current_account.entries.find(entry_id)
            raise ArgumentError, "User edited this entry; reversal requires review" if entry.protected_from_sync?
            if %i[name notes date amount currency].any? { |attribute| entry.locked?(attribute) } ||
                %i[kind investment_activity_label category_id merchant_id].any? { |attribute| entry.transaction.locked?(attribute) }
              raise ArgumentError, "Entry has locked fields; reversal requires review"
            end
            raise ArgumentError, "Entry was matched as a transfer; reversal requires review" if entry.transaction.transfer
            raise ArgumentError, "Entry provenance changed; reversal requires review" unless entry.transaction.extra.dig("trading212_statement", "statement_checksum") == checksum
            current = { "entry" => entry.attributes.slice("name", "notes", "date", "amount", "currency"),
              "transaction" => entry.transaction.attributes.slice("kind", "investment_activity_label", "category_id", "merchant_id", "extra") }.as_json
            raise ArgumentError, "Entry changed since application; reversal requires review" unless current == result.fetch("after_values").fetch(entry_id)
            entry.update!(before.fetch("entry"))
            entry.transaction.update!(before.fetch("transaction"))
          end
          # Rows enriched on the next sync have no before-value snapshot. They
          # require review rather than silently discarding their classifications.
          untracked = trading212_account.current_account.entries.joins("JOIN transactions t ON t.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
            .where("t.extra -> 'trading212_statement' ->> 'statement_checksum' = ?", checksum)
          raise ArgumentError, "Sync created additional enriched entries; review before reversing" if untracked.exists?
          trading212_account.update!(statement_enrichments: enrichments)
        end
        update!(status: :preview, result: {})
        result
      end
    end

    def user_and_account_share_family
      return unless user && trading212_account
      errors.add(:user, "must belong to the account family") unless user.family_id == trading212_account.trading212_item.family_id
    end
end
