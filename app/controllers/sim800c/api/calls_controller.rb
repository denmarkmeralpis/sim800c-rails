# frozen_string_literal: true

module Sim800c
  module Api
    class CallsController < ApiController
      before_action :authenticate!

      def index
        require_scope!("calls:read")
        v = query_validation
        page, limit = v.pagination
        filters = { direction: v.enum("direction", %w[inbound outbound]), status: v.enum("status", Call::STATUSES),
                    q: v.string("q", max: 40, optional: true) }
        v.validate!
        records, total = Call.search(page: page, limit: limit, **filters)
        render json: { data: records.map(&:as_api), page: page, limit: limit, total: total }
      end

      def active
        require_scope!("calls:read")
        render json: { data: Gateway.snapshot["call"] }
      end

      def show
        require_scope!("calls:read")
        render json: { data: Call.find_record(id_param).as_api }
      end

      def create
        require_scope!("calls:write")
        v = body_validation
        number = v.string("number", min: 2, max: 40)
        v.validate!
        render json: { data: Gateway.request("calls.dial", { number: number, actor: actor }) }, status: :accepted
      end

      def hangup
        require_scope!("calls:write")
        render json: { data: Gateway.request("calls.hangup") }
      end

      def answer
        require_scope!("calls:write")
        render json: { data: Gateway.request("calls.answer") }
      end

      def reject
        require_scope!("calls:write")
        render json: { data: Gateway.request("calls.reject") }
      end

      def dtmf
        require_scope!("calls:write")
        v = body_validation
        digits = v.string("digits", format: /\A[0-9*#A-Da-d]{1,20}\z/, format_message: "Digits must be 0-9, *, #, A-D")
        v.validate!
        Gateway.request("calls.dtmf", { digits: digits })
        head :no_content
      end

      def bulk_delete
        require_scope!("calls:write")
        v = body_validation
        ids = v.ids
        v.validate!
        deleted = Call.delete_ids(ids)
        Gateway.notify(call_deleted: deleted)
        render json: { deleted: deleted }
      end

      def destroy
        require_scope!("calls:write")
        id = id_param
        Call.find_record(id)
        Gateway.notify(call_deleted: Call.delete_ids([id]))
        head :no_content
      end
    end
  end
end
