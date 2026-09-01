Feature: No Guest Ollama 11434 hint in web or Console
  Workload detail, Device detail, GPU helper copy, and toasts used to
  advertise Guest Ollama at http://127.0.0.1:11434/v1. That hint is gone.
  Host Models inference how-to stays.

  Scenario: Web GPU copy has no Guest Ollama loopback hint
    Given GPU passthrough copy in the web UI
    Then it does not say Guest Ollama
    And it does not show 127.0.0.1:11434

  Scenario: Console GPU copy has no Guest Ollama loopback hint
    Given GPU passthrough copy in Console
    Then Workload detail does not show Guest Ollama
    And Device detail does not show Guest Ollama
    And attach-ready copy does not show 127.0.0.1:11434

  Scenario: Models how-to still documents host inference
    Given the Models inference how-to
    Then it still names OPENAI_BASE_URL
    And it still uses Home :7777 completions
