# based on https://gist.github.com/synth/fba7baeffd083a931184

require 'delayed_job'

class DelayedDuplicatePreventionPlugin < Delayed::Plugin

  # Configuration for duplicate prevention strategy
  #
  # Available strategies:
  #   :validation       - (Default/Legacy) Uses SELECT query to check for duplicates before insert.
  #                        No unique index required, but adds a SELECT per enqueue.
  #   :insert_ignore    - Uses MySQL INSERT IGNORE with a unique index on `signature`.
  #                        Silently skips duplicates at the DB level. No SELECT, no exception.
  #   :on_duplicate_key - Uses MySQL INSERT ... ON DUPLICATE KEY UPDATE with a unique index on `signature`.
  #                        On conflict, updates the existing row's `updated_at`. No SELECT, no exception.
  #
  # Set via: DelayedDuplicatePreventionPlugin.strategy = :insert_ignore
  #
  # IMPORTANT: :insert_ignore and :on_duplicate_key require a unique index on the `signature` column.
  # Run the generator to create the migration: rails g delayed_job_prevent_duplicate
  class << self
    attr_writer :strategy

    def strategy
      @strategy || :validation
    end
  end

  module SignatureConcern
    extend ActiveSupport::Concern

    included do
      before_validation :add_signature
      validate :prevent_duplicate, if: -> { DelayedDuplicatePreventionPlugin.strategy == :validation }
    end

    # Override save to use INSERT IGNORE or ON DUPLICATE KEY UPDATE
    # when the corresponding strategy is configured.
    #
    # We override `save` (not `create_or_update`) because AR wraps
    # `create_or_update` inside `with_transaction_returning_status`.
    # If we returned false from create_or_update, the transaction would
    # ROLLBACK — undoing the ON DUPLICATE KEY UPDATE on the existing row.
    #
    # By overriding `save`, our raw SQL executes outside AR's transaction
    # wrapper, so INSERT IGNORE silently skips and ON DUPLICATE KEY UPDATE
    # actually persists the update on the existing row.
    def save(**options, &block)
      strategy = DelayedDuplicatePreventionPlugin.strategy

      if new_record? && (strategy == :insert_ignore || strategy == :on_duplicate_key)
        # Trigger before_validation callbacks (sets signature + args)
        # and run validations (except prevent_duplicate which is skipped)
        return false unless valid?

        _insert_with_duplicate_handling(strategy)
      else
        super
      end
    end

    private

    def add_signature
      # If signature fails, id will keep everything working (though deduplication will not work)
      self.signature = generate_signature || generate_signature_random
      self.args = get_args
      truncate_signature_if_needed
    end

    def generate_signature
      begin
        # NOTE: placing this block at the top since class method invocations also have Delayed::PerformableMethod as payload_object
        if payload_object.respond_to?(:object) && payload_object.object&.is_a?(Class) && !payload_object.respond_to?(:signature)
          generate_signature_for_class_method
        elsif payload_object.respond_to?(:signature) || payload_object.is_a?(Delayed::PerformableMethod)
          generate_signature_for_job_payload
        else
          generate_signature_random
        end
      rescue
        log_signature_failed
      end
    end

    # this is to prevent ActiveRecord::ValueTooLong error for some cases with complex/long args
    def truncate_signature_if_needed
      return unless self.signature.present?

      column_limit = self.class.columns_hash["signature"].limit
      return unless column_limit

      if self.signature.length > column_limit
        self.signature = self.signature[0...(column_limit - 1)]
      end
    end

    def generate_signature_for_class_method
       # cast individual args to string and AR objects to class:id if any
      arg_signatures = get_args.map do |obj|
        obj.respond_to?(:id) ? "#{obj.class}:#{obj.id}" : obj.to_s
      end

      kwarg_signatures = get_kwargs.map do |(key, val)|
        val = val.respond_to?(:id) ? "#{val.class}:#{val.id}" : val.to_s
        [key, val]
      end.to_h

      "#{payload_object.object}##{payload_object.method_name}-#{arg_signatures}-#{kwarg_signatures}"
    end

    # Methods tagged with handle_asynchronously
    def generate_signature_for_job_payload
      if payload_object.respond_to?(:signature)
        if payload_object.method(:signature).arity > 0
          combined_args = [get_args, get_kwargs]
          sig = payload_object.signature(payload_object.method_name, combined_args)
        else
          sig = payload_object.signature
        end
      else
        if payload_object.object.respond_to?(:id) and payload_object.object.id.present?
          sig = "#{payload_object.object.class}:#{payload_object.object.id}"
        else
          sig = "#{payload_object.object}"
        end
      end
      if payload_object.respond_to?(:method_name)
        sig += "##{payload_object.method_name}" unless sig.match("##{payload_object.method_name}")
      end
      sig
    end

    def generate_signature_random
      SecureRandom.uuid
    end

    def log_signature_failed
      Rails.logger.error "DelayedDuplicatePreventionPlugin could not generate the signature correctly."
    end

    def get_args
      self.payload_object.try(:args) || []
    end

    def get_kwargs
      self.payload_object.try(:kwargs) || []
    end

    def prevent_duplicate
      if DuplicateChecker.duplicate?(self)
        Rails.logger.warn "Found duplicate job(#{self.signature}), ignoring..."
        errors.add(:base, "This is a duplicate")
      end
    end

    # Performs an INSERT IGNORE or INSERT ... ON DUPLICATE KEY UPDATE
    # using raw SQL to avoid ActiveRecord raising RecordNotUnique.
    #
    # Returns true if a row was inserted, false if it was a duplicate.
    def _insert_with_duplicate_handling(strategy)
      # Ensure timestamps are set
      current_time = self.class.current_time_from_proper_timezone
      self.created_at ||= current_time
      self.updated_at ||= current_time
      self.run_at ||= current_time

      attrs = attributes_for_create(attribute_names)
      column_names = attrs.map { |name| self.class.connection.quote_column_name(name) }
      values = attrs.map { |name| self.class.connection.quote(_read_attribute(name)) }

      table = self.class.quoted_table_name

      sql = case strategy
            when :insert_ignore
              "INSERT IGNORE INTO #{table} (#{column_names.join(', ')}) VALUES (#{values.join(', ')})"
            when :on_duplicate_key
              "INSERT INTO #{table} (#{column_names.join(', ')}) VALUES (#{values.join(', ')}) " \
              "ON DUPLICATE KEY UPDATE updated_at = VALUES(updated_at)"
            end

      self.class.connection.execute(sql)

      # Check ROW_COUNT() to determine if a row was actually inserted.
      # - INSERT IGNORE:              ROW_COUNT() = 1 (inserted), 0 (skipped)
      # - INSERT ... ON DUPLICATE KEY UPDATE: ROW_COUNT() = 1 (inserted), 2 (updated existing)
      #
      # We must NOT rely on LAST_INSERT_ID() alone because it retains the
      # previous auto-increment value when INSERT IGNORE skips a row,
      # which would incorrectly assign the prior job's id to this object.
      row_count_result = self.class.connection.execute("SELECT ROW_COUNT() AS cnt").first
      affected_rows = if row_count_result.is_a?(Hash)
                        row_count_result["cnt"]
                      elsif row_count_result.is_a?(Array)
                        row_count_result[0]
                      else
                        row_count_result
                      end

      actually_inserted = case strategy
                          when :insert_ignore
                            affected_rows == 1
                          when :on_duplicate_key
                            affected_rows == 1  # 1 = inserted, 2 = updated existing
                          end

      if actually_inserted
        # Fetch the real auto-increment id for the newly inserted row
        last_id_result = self.class.connection.execute("SELECT LAST_INSERT_ID() AS id").first
        inserted_id = if last_id_result.is_a?(Hash)
                        last_id_result["id"]
                      elsif last_id_result.is_a?(Array)
                        last_id_result[0]
                      else
                        last_id_result
                      end

        self.id = inserted_id
        changes_applied
        @new_record = false
        true
      else
        # Duplicate was silently ignored / existing row updated
        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.info "DelayedJob duplicate skipped via #{strategy} for signature: #{self.signature}"
        end
        # Keep @new_record = true so persisted? correctly returns false
        false
      end
    end
  end

  class DuplicateChecker
    attr_reader :job

    def self.duplicate?(job)
      new(job).duplicate?
    end

    def initialize(job)
      @job = job
    end

    def duplicate?
      possible_dupes.any? { |possible_dupe| args_match?(possible_dupe, job) }
    end

    private

    def possible_dupes
      possible_dupes = Delayed::Job.where(attempts: 0, locked_at: nil)  # Only jobs not started, otherwise it would never compute a real change if the job is currently running
                                   .where(signature: job.signature)     # Same signature
      possible_dupes = possible_dupes.where.not(id: job.id) if job.id.present?
      possible_dupes
    end

    def args_match?(job1, job2)
      job1.payload_object.args == job2.payload_object.args &&
        job1.payload_object.kwargs == job2.payload_object.kwargs
    rescue
      false
    end
  end

  # Lifecycle callback to clear the signature when a job is picked up by a worker.
  # This allows the same method to be re-enqueued after the job starts running,
  # which preserves the original behavior where only pending (attempts=0, locked_at=nil)
  # jobs were checked for duplicates.
  callbacks do |lifecycle|
    lifecycle.before(:perform) do |_worker, job|
      if DelayedDuplicatePreventionPlugin.strategy != :validation
        job.update_column(:signature, nil) if job.respond_to?(:signature)
      end
    end
  end
end
