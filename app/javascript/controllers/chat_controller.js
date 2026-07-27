import { Controller } from "@hotwired/stimulus"

// Echo a pending question immediately, expose a clear sending state, keep the
// message list scrolled to the newest message, and hand the persisted messages
// back to the server/Turbo Stream flow.
export default class extends Controller {
  static targets = ["list", "input", "send"]

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

  start() {
    if (!this.hasInputTarget) return

    const question = this.inputTarget.value.trim()
    if (!question) return

    this.removePendingMessage()
    this.pendingMessage = this.buildPendingMessage(question)
    this.listTarget.append(this.pendingMessage)
    this.setSending(true)
    this.scrollToBottom()
  }

  reset(event) {
    const succeeded = event.detail.success

    if (succeeded && this.hasInputTarget) this.inputTarget.value = ""
    this.setSending(false)

    // Turbo renders the server response before submit-end. Removing the
    // optimistic copy on the next frame prevents a visible gap or duplicate.
    requestAnimationFrame(() => {
      this.removePendingMessage()
      this.scrollToBottom()
    })
  }

  scrollToBottom() {
    if (this.hasListTarget) this.listTarget.scrollTop = this.listTarget.scrollHeight
  }

  buildPendingMessage(question) {
    const message = document.createElement("div")
    message.className = "msg msg--pending"
    message.setAttribute("aria-live", "polite")

    const bubble = document.createElement("div")
    bubble.className = "msg-user msg-user--pending"

    const content = document.createElement("span")
    content.textContent = `> ${question}`

    const status = document.createElement("span")
    status.className = "msg-pending-status"
    status.textContent = "sending"

    bubble.append(content, status)
    message.append(bubble)
    return message
  }

  removePendingMessage() {
    this.pendingMessage?.remove()
    this.pendingMessage = null
  }

  setSending(sending) {
    if (!this.hasSendTarget) return

    this.sendTarget.disabled = sending
    this.sendTarget.classList.toggle("is-sending", sending)
    this.sendTarget.setAttribute("aria-busy", sending.toString())
    this.sendTarget.textContent = sending ? "sending…" : "send"
  }
}
