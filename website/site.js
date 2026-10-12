// Copy buttons for the install commands.
document.querySelectorAll("button.copy").forEach((button) => {
  button.addEventListener("click", async () => {
    const text = document.getElementById(button.dataset.copy).textContent;
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = "Copied";
    } catch {
      // Clipboard can be unavailable (insecure context); select the text instead.
      const range = document.createRange();
      range.selectNodeContents(document.getElementById(button.dataset.copy));
      getSelection().removeAllRanges();
      getSelection().addRange(range);
      button.textContent = "Press ⌘C";
    }
    setTimeout(() => { button.textContent = "Copy"; }, 1600);
  });
});
