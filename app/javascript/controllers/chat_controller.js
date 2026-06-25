import { Controller } from "@hotwired/stimulus"

// Minimal chat UX: keep the message list scrolled to the newest message and
// clear the input after a question is sent. Everything else (streaming the
// answer in) is handled server-side via Turbo Streams.
export default class extends Controller {
  static targets = ["list", "input"]

  connect() {
    this.scrollToBottom()
    // Autoscroll as streamed tokens / new bubbles arrive.
    if (this.hasListTarget) {
      this.observer = new MutationObserver(() => this.scrollToBottom())
      this.observer.observe(this.listTarget, { childList: true, subtree: true })
    }
  }

  disconnect() {
    this.observer?.disconnect()
  }

  reset() {
    if (this.hasInputTarget) this.inputTarget.value = ""
    this.scrollToBottom()
  }

  scrollToBottom() {
    if (this.hasListTarget) this.listTarget.scrollTop = this.listTarget.scrollHeight
  }
}
