class ActionCableListener < BaseListener
  include Events::Types

  def notification_created(event)
    notification, account, unread_count, count = extract_notification_and_account(event)
    tokens = [event.data[:notification].user.pubsub_token]
    broadcast(account, tokens, NOTIFICATION_CREATED, { notification: notification.push_event_data, unread_count: unread_count, count: count })
  end

  def notification_updated(event)
    notification, account, unread_count, count = extract_notification_and_account(event)
    tokens = [event.data[:notification].user.pubsub_token]
    broadcast(account, tokens, NOTIFICATION_UPDATED, { notification: notification.push_event_data, unread_count: unread_count, count: count })
  end

  def notification_deleted(event)
    return if event.data[:notification].user.blank?

    notification, account, unread_count, count = extract_notification_and_account(event)
    tokens = [event.data[:notification].user.pubsub_token]
    broadcast(account, tokens, NOTIFICATION_DELETED, { notification: { id: notification.id }, unread_count: unread_count, count: count })
  end

  def account_cache_invalidated(event)
    account = event.data[:account] || single_tenant_account
    tokens = User.pluck(:pubsub_token).compact.uniq

    broadcast(account, tokens, ACCOUNT_CACHE_INVALIDATED, {
                cache_keys: event.data[:cache_keys]
              })
  end

  def message_created(event)
    message, account = extract_message_and_account(event)
    conversation = message.conversation
    tokens = (user_tokens(account, conversation.inbox.members) + contact_tokens(conversation.contact_inbox, message) + [account_token(account)]).compact

    broadcast(account, tokens, MESSAGE_CREATED, message.push_event_data)
  end

  def message_updated(event)
    message, account = extract_message_and_account(event)
    conversation = message.conversation
    tokens = (user_tokens(account, conversation.inbox.members) + contact_tokens(conversation.contact_inbox, message) + [account_token(account)]).compact

    push_data = message.push_event_data
    pc = event.data[:previous_changes]

    # Rails 7.1 dirty-tracking (forget_attribute_assignments) can reset enum
    # attributes to their original loaded value after after_update_commit fires,
    # leaving push_event_data[:status] as nil despite the DB update succeeding.
    # Fall back to the committed new value recorded in previous_changes.
    if push_data[:status].nil? && pc&.key?('status')
      push_data[:status] = pc['status'].last
    end

    broadcast(account, tokens, MESSAGE_UPDATED, push_data.merge(previous_changes: pc))
  end

  def first_reply_created(event)
    message, account = extract_message_and_account(event)
    conversation = message.conversation
    tokens = user_tokens(account, conversation.inbox.members)

    broadcast(account, tokens, FIRST_REPLY_CREATED, message.push_event_data)
  end

  def conversation_created(event)
    conversation, account = extract_conversation_and_account(event)
    tokens = (user_tokens(account, conversation.inbox.members) + contact_inbox_tokens(conversation.contact_inbox) + [account_token(account)]).compact

    broadcast(account, tokens, CONVERSATION_CREATED, conversation.push_event_data)
  end

  def conversation_read(event)
    conversation, account = extract_conversation_and_account(event)
    tokens = user_tokens(account, conversation.inbox.members)

    broadcast(account, tokens, CONVERSATION_READ, conversation.push_event_data)
  end

  def conversation_status_changed(event)
    conversation, account = extract_conversation_and_account(event)
    tokens = user_tokens(account, conversation.inbox.members) + contact_inbox_tokens(conversation.contact_inbox)

    broadcast(account, tokens, CONVERSATION_STATUS_CHANGED, conversation.push_event_data)
  end

  def conversation_updated(event)
    conversation, account = extract_conversation_and_account(event)
    tokens = (user_tokens(account, conversation.inbox.members) + contact_inbox_tokens(conversation.contact_inbox) + [account_token(account)]).compact

    broadcast(account, tokens, CONVERSATION_UPDATED, conversation_live_payload(conversation))
  end

  # Mudança de estágio / entrada / saída de um card no pipeline. O vendor só
  # despacha esses eventos para automações e webhooks; o chat nunca era avisado,
  # então o selo "Pipeline • Estágio" da lista de conversas só mudava com F5.
  # Reaproveita conversation.updated, que o frontend já sabe aplicar.
  def pipeline_stage_updated(event)
    broadcast_pipeline_change(event, 'moved')
  end

  def pipeline_item_cancelled(event)
    broadcast_pipeline_change(event, 'removed')
  end

  def conversation_typing_on(event)
    conversation = event.data[:conversation]
    account = single_tenant_account
    user = event.data[:user]
    tokens = typing_event_listener_tokens(account, conversation, user)

    broadcast(
      account,
      tokens,
      CONVERSATION_TYPING_ON,
      conversation: conversation.push_event_data,
      user: user.push_event_data,
      is_private: event.data[:is_private] || false
    )
  end

  def conversation_typing_off(event)
    conversation = event.data[:conversation]
    account = single_tenant_account
    user = event.data[:user]
    tokens = typing_event_listener_tokens(account, conversation, user)

    broadcast(
      account,
      tokens,
      CONVERSATION_TYPING_OFF,
      conversation: conversation.push_event_data,
      user: user.push_event_data,
      is_private: event.data[:is_private] || false
    )
  end

  def assignee_changed(event)
    conversation, account = extract_conversation_and_account(event)
    tokens = user_tokens(account, conversation.inbox.members)

    broadcast(account, tokens, ASSIGNEE_CHANGED, conversation.push_event_data)
  end

  def team_changed(event)
    conversation, account = extract_conversation_and_account(event)
    tokens = user_tokens(account, conversation.inbox.members)

    broadcast(account, tokens, TEAM_CHANGED, conversation.push_event_data)
  end

  def conversation_contact_changed(event)
    conversation, account = extract_conversation_and_account(event)
    tokens = user_tokens(account, conversation.inbox.members)

    broadcast(account, tokens, CONVERSATION_CONTACT_CHANGED, conversation.push_event_data)
  end

  def contact_created(event)
    contact, account = extract_contact_and_account(event)
    broadcast(account, [account_token(account)].compact, CONTACT_CREATED, contact.push_event_data)
  end

  def contact_updated(event)
    contact, account = extract_contact_and_account(event)
    broadcast(account, [account_token(account)].compact, CONTACT_UPDATED, contact.push_event_data)
  end

  def contact_merged(event)
    contact, account = extract_contact_and_account(event)
    broadcast(account, [account_token(account)].compact, CONTACT_MERGED, contact.push_event_data)
  end

  def contact_deleted(event)
    contact, account = extract_contact_and_account(event)
    broadcast(account, [account_token(account)].compact, CONTACT_DELETED, contact.push_event_data)
  end

  def conversation_mentioned(event)
    conversation, account = extract_conversation_and_account(event)
    user = event.data[:user]

    broadcast(account, [user.pubsub_token], CONVERSATION_MENTIONED, conversation.push_event_data)
  end

  # Público: também é chamado pelo ActionCableLiveConversationExtras (fim do
  # arquivo), que reaplica estes campos dentro do ActionCableBroadcastJob.
  def conversation_live_extras(conversation)
    { labels_data: live_labels_data(conversation), pipelines: live_pipelines_data(conversation) }
  end

  private

  # push_event_data só leva `labels` como lista de nomes. O frontend descarta
  # etiquetas sem cor (mantém as antigas), então a etiqueta nova só aparecia ao
  # recarregar. `labels_data` (id/título/cor) e `pipelines` seguem o mesmo
  # formato do ConversationSerializer usado no GET /conversations.
  def conversation_live_payload(conversation)
    conversation.push_event_data.merge(conversation_live_extras(conversation))
  end

  def live_labels_data(conversation)
    names = conversation.label_list.map { |name| name.to_s.strip }.reject(&:blank?)
    return [] if names.empty?

    by_title = Label.where('LOWER(title) IN (?)', names.map(&:downcase)).index_by { |label| label.title.to_s.downcase }
    names.filter_map do |name|
      label = by_title[name.downcase]
      next unless label

      { id: label.id, title: label.title, color: label.color.presence || '#1f93ff' }
    end
  end

  def live_pipelines_data(conversation)
    items = PipelineItem.where(conversation_id: conversation.id).includes(:pipeline, :pipeline_stage).to_a
    items.select { |item| item.pipeline && item.pipeline_stage }.group_by(&:pipeline).map do |pipeline, pipeline_items|
      stages = pipeline_items.sort_by { |item| item.pipeline_stage.position.to_i }.map do |item|
        stage = item.pipeline_stage
        { id: stage.id, name: stage.name, color: stage.color, days_in_current_stage: item.days_in_current_stage }
      end
      { id: pipeline.id, name: pipeline.name, stages: stages }
    end
  end

  # Roda no SyncDispatcher, dentro da transação que move o card: nunca pode
  # levantar exceção, senão derruba a própria movimentação.
  #
  # Dois eventos: `pipeline.item_changed` (para o Kanban recarregar em silêncio e
  # animar o card; vale também para cards de contato, sem conversa) e
  # `conversation.updated` (selo de pipeline na lista de conversas do chat).
  def broadcast_pipeline_change(event, action)
    item = event.data[:pipeline_item]
    return if item.nil?

    account = single_tenant_account
    tokens = (user_tokens(account, nil) + [account_token(account)]).compact
    broadcast(account, tokens, 'pipeline.item_changed', {
                action: action,
                pipeline_id: item.pipeline_id,
                pipeline_item_id: item.id,
                pipeline_stage_id: item.pipeline_stage_id,
                conversation_id: item.conversation_id
              })

    conversation = item.conversation
    return if conversation.nil?

    broadcast(account, tokens, CONVERSATION_UPDATED, conversation_live_payload(conversation))
  rescue StandardError => e
    Rails.logger.error "ActionCableListener pipeline broadcast failed: #{e.class}: #{e.message}"
  end

  def account_token(account)
    # Return nil (not "") so callers using `[account_token(...)].compact`
    # actually drop the entry when account is missing — `compact` filters
    # nil but keeps empty strings. Accept both Hash and AR-object shapes.
    return nil if account.nil?

    id = account.is_a?(Hash) ? account['id'] : account.id
    "account_#{id}"
  end

  def typing_event_listener_tokens(account, conversation, user)
    current_user_token = user.is_a?(Contact) ? conversation.contact_inbox.pubsub_token : user.pubsub_token
    (user_tokens(account, conversation.inbox.members) + [conversation.contact_inbox.pubsub_token]) - [current_user_token]
  end

  def user_tokens(_account, agents)
    # All users receive broadcasts - permission filtering is handled by evo-auth
    User.pluck(:pubsub_token).compact.uniq
  end

  def contact_tokens(contact_inbox, message)
    return [] if message.private?
    return [] if message.activity?
    return [] if contact_inbox.nil?

    contact_inbox_tokens(contact_inbox)
  end

  def contact_inbox_tokens(contact_inbox)
    contact = contact_inbox.contact

    contact_inbox.hmac_verified? ? contact.contact_inboxes.where(hmac_verified: true).filter_map(&:pubsub_token) : [contact_inbox.pubsub_token]
  end

  def broadcast(account, tokens, event_name, data)
    return if tokens.blank?

    payload = data.dup
    payload[:performer] = Current.user&.push_event_data if Current.user.present?
    uniq_tokens = tokens.uniq
    Rails.logger.info "ActionCable enqueue event=#{event_name} recipients=#{uniq_tokens.size}"

    ::ActionCableBroadcastJob.perform_later(uniq_tokens, event_name, payload)
  end
end

ActionCableListener.prepend_mod_with('ActionCableListener')

# O ActionCableBroadcastJob recarrega a conversa e refaz `push_event_data` para
# todo evento de conversa (proteção do vendor contra eventos fora de ordem), o
# que descarta `labels_data` e `pipelines` montados acima. Este módulo reaplica
# os dois campos depois do recarregamento, já com o dado mais recente. Fica neste
# arquivo porque ele já é montado no crm e no crm_sidekiq (onde o job roda).
module ActionCableLiveConversationExtras
  private

  def prepare_broadcast_data(event_name, data)
    add_live_conversation_extras(event_name, super)
  end

  def add_live_conversation_extras(event_name, result)
    return result unless ActionCableBroadcastJob::CONVERSATION_UPDATE_EVENTS.include?(event_name) && result.is_a?(Hash)

    conversation = Conversation.find_by(id: result[:id] || result['id'])
    return result if conversation.nil?

    result.merge(ActionCableListener.instance.conversation_live_extras(conversation))
  rescue StandardError => e
    Rails.logger.error "ActionCableLiveConversationExtras failed: #{e.class}: #{e.message}"
    result
  end
end

ActionCableBroadcastJob.prepend(ActionCableLiveConversationExtras) unless ActionCableBroadcastJob.include?(ActionCableLiveConversationExtras)

