import { Controller } from "@hotwired/stimulus"

// Keeps the chat pane's [n] citation chips in sync with whichever chunk is
// currently shown in the document pane, and scrolls a freshly-opened citation
// into view. There is no shared client-side state: the document pane is
// plain server-rendered Turbo Frame content, so this just re-reads the
// frame's "active chunk" marker after every navigation and reconciles the
// chips against it.
export default class extends Controller {
  static targets = ["frame", "chip"]

  connect() {
    this.sync()
  }

  sync() {
    const activeId = this.hasFrameTarget ? this.frameTarget.dataset.activeChunkId : undefined

    this.chipTargets.forEach((chip) => {
      chip.classList.toggle("is-active", !!activeId && chip.dataset.chunkId === activeId)
    })

    const highlighted = this.hasFrameTarget ? this.frameTarget.querySelector(".doc-para--hl") : null
    if (highlighted) highlighted.scrollIntoView({ block: "center", behavior: "smooth" })
  }
}
