import { Controller } from "@hotwired/stimulus"

// Dark/light toggle. The flip itself happens on <html data-theme> (set
// synchronously in the layout's <head> to avoid a flash of the wrong theme);
// this controller keeps the visual switch and its accessible action in sync,
// and persists the choice for next time.
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
    const light = this.current === "light"
    this.element.dataset.themeState = this.current
    this.element.setAttribute("aria-checked", light.toString())
    this.element.setAttribute("aria-label", light ? "Use dark theme" : "Use light theme")
    this.element.title = light ? "Use dark theme" : "Use light theme"
  }

  get current() {
    return document.documentElement.dataset.theme === "light" ? "light" : "dark"
  }
}
