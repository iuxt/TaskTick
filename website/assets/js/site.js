document.querySelectorAll('[data-copy]').forEach((button) => {
  button.addEventListener('click', async () => {
    const status = button.closest('.terminal').querySelector('.copy-status');
    try {
      await navigator.clipboard.writeText(button.dataset.copy);
      const original = button.textContent;
      button.textContent = button.dataset.copied;
      status.textContent = button.dataset.copied;
      button.disabled = true;
      window.setTimeout(() => {
        button.textContent = original;
        button.disabled = false;
        status.textContent = '';
      }, 2200);
    } catch {
      status.textContent = button.dataset.failed;
    }
  });
});
