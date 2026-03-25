# frozen_string_literal: true

class AddSignatureToDelayedJob < ActiveRecord::Migration<%= migration_version %>
  def change
    add_column :delayed_jobs, :signature, :string, unless_exists: true
    add_column :delayed_jobs, :args, :text, unless_exists: true
    add_index :delayed_jobs, :signature, unique: true, name: "index_delayed_jobs_on_signature_unique"
  end
end
