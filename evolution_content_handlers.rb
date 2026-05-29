module Whatsapp::EvolutionHandlers::ContentHandlers
  def handle_location
    location_msg = @raw_message.dig(:message, :locationMessage)
    return unless location_msg

    @message.content_attributes[:location] = {
      latitude: location_msg[:degreesLatitude],
      longitude: location_msg[:degreesLongitude],
      name: location_msg[:name],
      address: location_msg[:address]
    }
  end

  def handle_contacts
    contact_msg = @raw_message.dig(:message, :contactMessage)
    contacts_array = @raw_message.dig(:message, :contactsArrayMessage, :contacts)

    contacts = if contact_msg
                 [contact_msg]
               elsif contacts_array
                 contacts_array
               else
                 []
               end

    @message.content_attributes[:contacts] = contacts.map do |contact|
      {
        display_name: contact[:displayName],
        vcard: contact[:vcard]
      }
    end
  end

  def message_content_attributes
    content_attributes = {
      external_created_at: evolution_extract_message_timestamp(@raw_message[:messageTimestamp])
    }

    if message_type == 'reaction'
      content_attributes[:in_reply_to_external_id] = @raw_message.dig(:message, :reactionMessage, :key, :id)
      content_attributes[:is_reaction] = true
    elsif message_type == 'unsupported'
      content_attributes[:is_unsupported] = true
    end

    content_attributes[:sender_name] = participant_push_name if jid_type == 'group' && participant_push_name.present?
    content_attributes[:media_type] = message_type if media_attachment?

    # Persist CTWA (Click-to-WhatsApp) tracking fields from Evolution API contextInfo so they
    # are available in webhook_data and forwarded to downstream integrations such as n8n.
    # contextInfo can be at the root OR nested inside the message type object.
    context_info = find_ctwa_context_info
    if context_info.present?
      content_attributes[:ctwa_clid] = context_info[:ctwaClid] if context_info[:ctwaClid].present?
      content_attributes[:ad_source_id] = context_info[:sourceId] if context_info[:sourceId].present?
    end

    content_attributes
  end

  def find_ctwa_context_info
    # 1. Root level (some Evolution API versions)
    ctx = @raw_message[:contextInfo]
    return ctx if ctx.is_a?(Hash) && ctx.present?

    msg = @raw_message[:message]
    return nil unless msg.is_a?(Hash)

    # 2. Directly under the message object
    ctx = msg[:contextInfo]
    return ctx if ctx.is_a?(Hash) && ctx.present?

    # 3. Inside each known message type (most common for CTWA ads)
    %i[extendedTextMessage imageMessage videoMessage audioMessage
       documentMessage stickerMessage buttonMessage templateMessage].each do |type|
      ctx = msg.dig(type, :contextInfo)
      return ctx if ctx.is_a?(Hash) && ctx.present?
    end

    nil
  end
end
