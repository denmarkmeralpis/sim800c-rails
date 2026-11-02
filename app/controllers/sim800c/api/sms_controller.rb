# frozen_string_literal: true

module Sim800c
  module Api
    class SmsController < ApiController
      IDEMPOTENCY_KEY = /\A[\x21-\x7e]{1,255}\z/

      before_action :authenticate!

      def index
        require_scope!("sms:read")
        v = query_validation
        page, limit = v.pagination
        filters = {
          direction: v.enum("direction", %w[inbound outbound]),
          status: v.enum("status", SmsMessage::STATUSES),
          phone: v.string("phone", max: 40, optional: true),
          q: v.string("q", max: 200, optional: true),
          unread: v.flag("unread")
        }
        v.validate!
        records, total = SmsMessage.search(page: page, limit: limit, **filters)
        render json: { data: records.map(&:as_api), page: page, limit: limit, total: total }
      end

      def show
        require_scope!("sms:read")
        render json: { data: SmsMessage.find_record(id_param).as_api }
      end

      def create
        require_scope!("sms:send")
        idempotency = idempotency_key
        v = body_validation
        to = recipients(v)
        text = v.string("message", min: 1, max: 5000, min_message: "Message text is required")
        priority = v.integer("priority", min: 0, max: 10, optional: true)
        v.validate!

        records, replayed = SmsMessage.enqueue(to: to, text: text, priority: priority, idempotency: idempotency, **actor)
        if replayed
          response.set_header("Idempotent-Replayed", "true")
        else
          Gateway.notify(sms_updated: records.map(&:id), kick: true)
        end
        render json: { data: records.map(&:as_api) }, status: :accepted
      end

      def read
        require_scope!("sms:read")
        v = body_validation
        ids = v.ids
        read = v.boolean("read", default: true)
        v.validate!
        updated = SmsMessage.mark_read(ids, read)
        Gateway.notify(sms_updated: ids)
        render json: { updated: updated }
      end

      def bulk_delete
        require_scope!("sms:delete")
        v = body_validation
        ids = v.ids
        v.validate!
        deleted = SmsMessage.delete_ids(ids)
        Gateway.notify(sms_deleted: deleted)
        render json: { deleted: deleted }
      end

      def destroy
        require_scope!("sms:delete")
        id = id_param
        SmsMessage.find_record(id)
        Gateway.notify(sms_deleted: SmsMessage.delete_ids([id]))
        head :no_content
      end

      def retry_message
        require_scope!("sms:send")
        record = SmsMessage.retry!(id_param)
        Gateway.notify(sms_status: [record.id], kick: true)
        render json: { data: record.as_api }
      end

      def retry_failed
        require_scope!("sms:send")
        ids = SmsMessage.retry_failed!
        if ids.any?
          log_id = log_event(:info, "sms", "Re-queued #{ids.size} failed message(s)")
          Gateway.notify(sms_status: ids, log: [log_id].compact, kick: true)
        end
        render json: { retried: ids }
      end

      def cancel
        require_scope!("sms:send")
        record = SmsMessage.cancel!(id_param)
        Gateway.notify(sms_status: [record.id])
        render json: { data: record.as_api }
      end

      private

      # The optional Idempotency-Key header, scoped to the calling API key or dashboard user.
      def idempotency_key
        key = request.headers["Idempotency-Key"]
        return nil if key.nil?
        unless IDEMPOTENCY_KEY.match?(key)
          raise AppError.bad_request("Idempotency-Key must be 1–255 visible ASCII characters, without spaces")
        end

        { owner: principal.idempotency_owner, key: key }
      end

      # "to": a string (comma, semicolon or newline separated) or an array of up to 100 numbers.
      def recipients(v)
        value = v.raw("to")
        list = case value
               when String then value.split(/[,;\n]+/)
               when Array
                 return v.issue("to", "Too big: expected array to have <=100 items") if value.size > 100

                 bad = value.index { |n| !n.is_a?(String) || n.size > 40 }
                 return v.issue("to.#{bad}", "Invalid input: expected a phone number of up to 40 characters") if bad

                 value
               else
                 return v.issue("to", "Invalid input: expected string or array")
               end
        list = list.map(&:strip).reject(&:empty?)
        return v.issue("to", "At least one recipient is required") if list.empty?
        return v.issue("to", "At most 100 recipients per request") if list.size > 100

        list
      end
    end
  end
end
