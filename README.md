# DelayedJobPreventDuplicate

The purpose of this gem is to prevent re-enqueueing on DelayedJob a task already enqueued.  
A "signature" is attached to every task which is a composite of the class, id, and method called.  
When creating a new job, the gem checks for an existing pending job with the same signature.

## Note

This gem is based on the [synth](https://github.com/synth) work: https://gist.github.com/synth/fba7baeffd083a931184

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'delayed_job_prevent_duplicate'
```

This line should be added after including the gem 'delayed_job'

And then execute:

    $ bundle install

Next, you need to run the generator: 

```ruby
rails g delayed_job_prevent_duplicate
```
  
All should be fine now!  

## Duplicate Prevention Strategies

The gem supports three strategies for preventing duplicate jobs:

### 1. `:validation` (Default — Legacy behavior)

Uses a SELECT query to check for existing pending jobs with the same signature before inserting.
No unique index required, but adds one SELECT query per enqueue.

```ruby
# This is the default, no configuration needed
DelayedDuplicatePreventionPlugin.strategy = :validation
```

### 2. `:insert_ignore` (Recommended for MySQL/MariaDB)

Uses MySQL's `INSERT IGNORE` statement with a unique index on `signature`.
Silently skips duplicates at the database level — no SELECT query, no Ruby exception.

```ruby
# In an initializer (e.g., config/initializers/delayed_job.rb)
DelayedDuplicatePreventionPlugin.strategy = :insert_ignore
```

**Requires** a unique index on the `signature` column (added by the generator migration).

### 3. `:on_duplicate_key` (Alternative for MySQL/MariaDB)

Uses MySQL's `INSERT ... ON DUPLICATE KEY UPDATE` with a unique index on `signature`.
On conflict, updates the existing row's `updated_at` timestamp. No SELECT, no exception.

```ruby
DelayedDuplicatePreventionPlugin.strategy = :on_duplicate_key
```

**Requires** a unique index on the `signature` column (added by the generator migration).

### How the unique index strategies work

When using `:insert_ignore` or `:on_duplicate_key`:

1. The signature is still generated the same way (before validation callback)
2. Instead of doing a SELECT to check for duplicates, the INSERT itself handles conflicts
3. When a worker **picks up a job** to execute it, the signature is **cleared** (`SET signature = NULL`), 
   allowing the same method to be re-enqueued after the job starts running
4. This preserves the original behavior where only pending/queued jobs block re-enqueueing

### Deduplication scope

The strategies differ in **what** they consider a duplicate:

| Strategy | Dedup key | Behavior with same signature, different args |
|---|---|---|
| `:validation` | signature + args | Both jobs are enqueued (args differ) |
| `:insert_ignore` | signature only | Second job is silently skipped |
| `:on_duplicate_key` | signature only | Second job is silently skipped |

The `:validation` strategy performs a SELECT query and compares both the signature and serialized args, so two jobs with the same class/id/method but different arguments are **not** considered duplicates.

The `:insert_ignore` and `:on_duplicate_key` strategies rely on a database unique index on the `signature` column, so deduplication is based on signature alone — regardless of arguments.

> **Note:** Because the generator migration adds a unique index on `signature`, the `:validation` strategy will also prevent same-signature inserts at the DB level — even when args differ. This is handled gracefully (no exception raised), but it means the unique index makes all strategies behave consistently at the signature level.

### Performance comparison

| Strategy | SELECT per enqueue | INSERT per enqueue | Exception on dupe | Best for |
|---|---|---|---|---|
| `:validation` | Yes (1 query) | Yes | No (validation error) | Low volume, any DB |
| `:insert_ignore` | No | Yes | No | High volume, MySQL |
| `:on_duplicate_key` | No | Yes | No | High volume, MySQL |

## Custom Signatures

You can define a custom `signature` method on model objects to control the dedup key:

```ruby
class MyModel < ApplicationRecord
  def signature(method_name = nil, args = nil)
    "MyModel:#{id}##{method_name}"
  end
end
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/noesya/delayed_job_prevent_duplicate.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Bibliography

https://groups.google.com/g/delayed_job/c/gZ9bFCdZrsk\#2a05c39a192e630c
https://github.com/collectiveidea/delayed_job/blob/master/lib/delayed/backend/base.rb
https://github.com/ignatiusreza/activejob-trackable
