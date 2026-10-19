# Loads the local model in the background (System health › AI status ›
# "Load local model"): loading a large model can take longer than a page
# request may wait. See LocalLlm::WarmUp.
class LocalLlmWarmUpJob < ApplicationJob
  queue_as :high_priority

  def perform
    LocalLlm::WarmUp.call
  end
end
