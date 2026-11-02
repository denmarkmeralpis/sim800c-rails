# frozen_string_literal: true

module Sim800c
  module Api
    class UssdController < ApiController
      REPLY = /\A[\x20\x21\x23-\x7e]{1,160}\z/

      before_action :authenticate!

      # The latest session, finished or not.
      def show
        require_scope!("calls:read")
        render json: { data: UssdSession.latest&.as_api }
      end

      def create
        require_scope!("calls:write")
        v = body_validation
        code = v.string("code", min: 3, max: 40)
        v.validate!
        render json: { data: Gateway.request("ussd.send", { code: code, actor: actor }) }
      end

      def reply
        require_scope!("calls:write")
        v = body_validation
        text = v.string("text", trim: true, format: REPLY,
                                format_message: "Reply must be 1-160 plain ASCII characters, without double quotes")
        v.validate!
        render json: { data: Gateway.request("ussd.reply", { text: text }) }
      end

      def cancel
        require_scope!("calls:write")
        render json: { data: Gateway.request("ussd.cancel") }
      end

      def sessions
        require_scope!("calls:read")
        v = query_validation
        page, limit = v.pagination
        filters = { status: v.enum("status", UssdSession::STATUSES), source: v.enum("source", UssdSession::SOURCES),
                    q: v.string("q", max: 160, optional: true) }
        v.validate!
        records, total = UssdSession.search(page: page, limit: limit, **filters)
        render json: { data: records.map(&:as_api), page: page, limit: limit, total: total }
      end

      def session_show
        require_scope!("calls:read")
        render json: { data: UssdSession.find_record(id_param).as_api }
      end

      def sessions_delete
        require_scope!("calls:write")
        v = body_validation
        ids = v.ids
        v.validate!
        render json: { deleted: UssdSession.delete_ids(ids) }
      end

      def session_destroy
        require_scope!("calls:write")
        id = id_param
        UssdSession.find_record(id)
        UssdSession.delete_ids([id])
        head :no_content
      end
    end
  end
end
