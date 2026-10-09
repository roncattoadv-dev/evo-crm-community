# https://docs.360dialog.com/whatsapp-api/whatsapp-api/media
# https://developers.facebook.com/docs/whatsapp/api/media/

class Whatsapp::IncomingMessageWhatsappCloudService < Whatsapp::IncomingMessageBaseService
  private

  def processed_params
    @processed_params ||= params[:entry].try(:first).try(:[], 'changes').try(:first).try(:[], 'value')
  end

  # Click-to-WhatsApp ads (patch 2026-10-09): Meta sends the ad attribution in
  # `messages[].referral` (ctwa_clid, source_id = ad id, source_url, headline...).
  # The vendor base service ignores it, so the lead lost its tracking on the Cloud
  # inbox. Stored under the same content_attributes keys the Evolution handler uses
  # (`ctwa_clid`, `ad_source_id`), so the messages API, the bot runtime metadata and
  # the n8n payload work the same for both channels. Never allowed to drop a message.
  def create_message(message)
    super
    attrs = referral_content_attributes(message)
    @message.content_attributes = (@message.content_attributes || {}).merge(attrs) if attrs.present?
    @message
  end

  def referral_content_attributes(message)
    referral = message.respond_to?(:key?) ? (message[:referral] || message['referral']) : nil
    return {} if referral.blank?

    referral = referral.to_h.with_indifferent_access
    {
      ctwa_clid: referral[:ctwa_clid],
      ad_source_id: referral[:source_id],
      ad_source_type: referral[:source_type],
      ad_source_url: referral[:source_url],
      ad_headline: referral[:headline],
      ad_body: referral[:body],
      ad_media_type: referral[:media_type]
    }.compact_blank
  rescue StandardError => e
    Rails.logger.error "[WhatsApp Cloud] referral extraction failed: #{e.message}"
    {}
  end

  def download_attachment_file(attachment_payload)
    url_response = HTTParty.get(inbox.channel.media_url(attachment_payload[:id]), headers: inbox.channel.api_headers)
    # This url response will be failure if the access token has expired.
    inbox.channel.authorization_error! if url_response.unauthorized?
    Down.download(url_response.parsed_response['url'], headers: inbox.channel.api_headers) if url_response.success?
  end
end
