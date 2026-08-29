// Small modal: last N lines of a service's logs. Text content only
// (textContent, never innerHTML) since log lines are arbitrary bytes from
// whatever the container printed.

const modal = document.getElementById("log-modal");
const titleEl = document.getElementById("log-modal-title");
const bodyEl = document.getElementById("log-modal-body");

document.getElementById("log-modal-close").addEventListener("click", () => modal.classList.add("hidden"));

export async function openLogViewer(id, label, fetchJSON) {
  titleEl.textContent = `${label} — logs`;
  bodyEl.textContent = "Loading…";
  modal.classList.remove("hidden");
  try {
    const data = await fetchJSON(`/api/services/${id}/logs?lines=200`);
    bodyEl.textContent = data.lines.join("\n") || "(no output)";
  } catch (err) {
    bodyEl.textContent = `Failed to load logs: ${err.message}`;
  }
}
