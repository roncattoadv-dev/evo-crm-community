# frozen_string_literal: true

# Custom patch (not a vendor file). Mounted as
# config/initializers/zz_scheduled_action_message_failure.rb in crm and crm_sidekiq.
#
# A scheduled action is marked `completed` as soon as its message row exists; the
# real delivery happens later (SendReplyJob / Meta status webhook). When a message
# linked to a scheduled action ends up `failed`, write that back to the action.
Rails.application.config.to_prepare do
  Message.after_update_commit do
    next unless saved_change_to_status? && failed?

    ScheduledActions::ExecutorService.propagate_message_failure(self)
  end
end
