import { Controller } from "@hotwired/stimulus"

// Dark/light toggle. The flip itself happens on <html data-theme> (set
// synchronously in the layout's <head> to avoid a flash of the wrong theme);
// this controller only keeps the button's own label in sync and persists the
// choice for next time.
export default class extends Controller {
  connect() {
    this.render()
  }

  toggle() {
    const next = this.current === "dark" ? "light" : "dark"
    document.documentElement.dataset.theme = next
    try { localStorage.setItem("theme", next) } catch (e) {}
    this.render()
  }

  render() {
    this.element.textContent = this.current === "dark" ? "☀ light" : "◗ dark"
  }

  get current() {
    return document.documentElement.dataset.theme === "light" ? "light" : "dark"
  }
}
