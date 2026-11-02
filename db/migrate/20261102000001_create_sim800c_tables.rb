# frozen_string_literal: true

class CreateSim800cTables < ActiveRecord::Migration[7.2]
  def change
    create_table :sim800c_users do |t|
      t.string :username, null: false, limit: 40
      t.string :username_key, null: false, limit: 40 # lowercased: usernames are unique ignoring case
      t.string :password_hash, null: false
      t.string :role, null: false, limit: 16
      t.datetime :last_login_at
      t.timestamps
    end
    add_index :sim800c_users, :username_key, unique: true, name: "idx_sim800c_users_username"

    create_table :sim800c_sessions, id: false do |t|
      t.primary_key :id, :string, limit: 64 # sha256 of the session token
      t.references :user, null: false, index: { name: "idx_sim800c_sessions_user" },
                          foreign_key: { to_table: :sim800c_users, on_delete: :cascade }
      t.string :csrf_token, null: false
      t.datetime :expires_at, null: false
      t.string :ip
      t.string :user_agent, limit: 300
      t.datetime :created_at, null: false
    end
    add_index :sim800c_sessions, :expires_at, name: "idx_sim800c_sessions_expires"

    create_table :sim800c_api_keys do |t|
      t.string :name, null: false, limit: 80
      t.string :prefix, null: false, limit: 32
      t.string :key_hash, null: false, limit: 64 # sha256 of the full key
      t.json :scopes, null: false
      t.references :created_by, index: { name: "idx_sim800c_api_keys_creator" },
                                foreign_key: { to_table: :sim800c_users, on_delete: :nullify }
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.datetime :created_at, null: false
    end
    add_index :sim800c_api_keys, :key_hash, unique: true, name: "idx_sim800c_api_keys_hash"

    create_table :sim800c_sms_messages do |t|
      t.string :direction, null: false, limit: 8
      t.string :phone, null: false, limit: 40
      t.text :body, null: false
      t.string :status, null: false, limit: 16
      t.string :encoding, limit: 8
      t.integer :parts, null: false, default: 1
      t.integer :priority, null: false, default: 0
      t.integer :attempts, null: false, default: 0
      t.datetime :next_attempt_at
      t.text :error
      t.json :refs # {concatRef, parts: [{mr, st, err}]} per sent part, for delivery reports
      t.string :pdu_hash, limit: 64 # de-duplicates inbound messages re-read from the SIM
      t.string :smsc, limit: 40
      t.string :source, null: false, limit: 16
      t.references :user, index: false, foreign_key: { to_table: :sim800c_users, on_delete: :nullify }
      t.references :api_key, index: false, foreign_key: { to_table: :sim800c_api_keys, on_delete: :nullify }
      t.datetime :read_at
      t.datetime :sent_at
      t.datetime :delivered_at
      t.datetime :received_at
      t.timestamps
    end
    add_index :sim800c_sms_messages, :pdu_hash, unique: true, name: "idx_sim800c_sms_pdu_hash"
    add_index :sim800c_sms_messages, %i[direction created_at], name: "idx_sim800c_sms_direction_created"
    add_index :sim800c_sms_messages, %i[status priority next_attempt_at], name: "idx_sim800c_sms_queue"
    add_index :sim800c_sms_messages, :phone, name: "idx_sim800c_sms_phone"

    create_table :sim800c_sms_fragments do |t|
      t.string :phone, null: false, limit: 40
      t.integer :ref, null: false
      t.integer :total, null: false
      t.integer :seq, null: false
      t.text :body, null: false
      t.string :encoding, limit: 8
      t.string :smsc, limit: 40
      t.datetime :sent_at
      t.datetime :received_at, null: false
      t.string :pdu_hash, null: false, limit: 64
    end
    add_index :sim800c_sms_fragments, :pdu_hash, unique: true, name: "idx_sim800c_fragments_pdu_hash"
    add_index :sim800c_sms_fragments, %i[phone ref total seq], unique: true, name: "idx_sim800c_fragments_part"

    create_table :sim800c_calls do |t|
      t.string :direction, null: false, limit: 8
      t.string :phone, limit: 40
      t.string :status, null: false, limit: 16
      t.string :end_reason
      t.text :error
      t.string :source, null: false, limit: 16
      t.references :user, index: false, foreign_key: { to_table: :sim800c_users, on_delete: :nullify }
      t.references :api_key, index: false, foreign_key: { to_table: :sim800c_api_keys, on_delete: :nullify }
      t.datetime :started_at, null: false
      t.datetime :answered_at
      t.datetime :ended_at
      t.integer :duration
    end
    add_index :sim800c_calls, :started_at, name: "idx_sim800c_calls_started"
    add_index :sim800c_calls, :status, name: "idx_sim800c_calls_status"

    create_table :sim800c_ussd_sessions do |t|
      t.string :code, limit: 40 # null for a message pushed by the network
      t.string :status, null: false, limit: 16
      t.text :response
      t.text :error
      t.json :messages, null: false # [{direction, text, at}], oldest first; `at` in epoch ms
      t.string :source, null: false, limit: 16
      t.references :user, index: false, foreign_key: { to_table: :sim800c_users, on_delete: :nullify }
      t.references :api_key, index: false, foreign_key: { to_table: :sim800c_api_keys, on_delete: :nullify }
      t.datetime :started_at, null: false
      t.datetime :updated_at, null: false
    end
    add_index :sim800c_ussd_sessions, :started_at, name: "idx_sim800c_ussd_started"

    create_table :sim800c_event_log_entries do |t|
      t.string :level, null: false, limit: 8
      t.string :category, null: false, limit: 40
      t.text :message, null: false
      t.json :data
      t.datetime :created_at, null: false
    end

    # Keys are case-sensitive; MySQL's default collation is not.
    case_sensitive = connection.adapter_name.match?(/mysql|trilogy/i) ? { collation: "utf8mb4_bin" } : {}
    create_table :sim800c_idempotency_keys do |t|
      t.string :owner, null: false, limit: 40 # "key:<api key id>" or "user:<user id>"
      t.string :idempotency_key, null: false, **case_sensitive # the client's Idempotency-Key header
      t.string :request_hash, null: false, limit: 64 # sha256 of the parsed request, to spot a reused key
      t.json :sms_ids, null: false # ids of the messages the request created
      t.datetime :created_at, null: false
    end
    add_index :sim800c_idempotency_keys, %i[owner idempotency_key], unique: true, name: "idx_sim800c_idempotency_owner_key"
    add_index :sim800c_idempotency_keys, :created_at, name: "idx_sim800c_idempotency_created"
  end
end
