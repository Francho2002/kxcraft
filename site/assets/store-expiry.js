(() => {
  "use strict";
  // Argentina: 1 Jan 2027 at midnight (UTC-03). UI-only restriction on static hosting.
  const CLOSES_AT = Date.parse("2027-01-01T00:00:00-03:00");
  const links = document.querySelectorAll("[data-shop-nav]");
  const countdown = document.querySelector("[data-shop-countdown]");
  const catalog = document.getElementById("shop-catalog");
  const closed = document.getElementById("shop-closed");
  const digits = countdown ? {
    days: countdown.querySelector("[data-shop-days]"),
    hours: countdown.querySelector("[data-shop-hours]"),
    minutes: countdown.querySelector("[data-shop-minutes]"),
    seconds: countdown.querySelector("[data-shop-seconds]")
  } : null;
  const sync = () => {
    const remaining = CLOSES_AT - Date.now();
    const isOpen = Number.isFinite(remaining) && remaining > 0;
    for (const link of links) link.hidden = !isOpen;
    if (catalog && closed) {
      catalog.hidden = !isOpen;
      closed.hidden = isOpen;
    }
    if (countdown) countdown.hidden = !isOpen;
    if (isOpen && digits) {
      const secondsRemaining = Math.ceil(remaining / 1000);
      const days = Math.floor(secondsRemaining / 86400);
      const hours = Math.floor((secondsRemaining % 86400) / 3600);
      const minutes = Math.floor((secondsRemaining % 3600) / 60);
      const seconds = secondsRemaining % 60;
      if (digits.days) digits.days.textContent = String(days);
      if (digits.hours) digits.hours.textContent = String(hours).padStart(2, "0");
      if (digits.minutes) digits.minutes.textContent = String(minutes).padStart(2, "0");
      if (digits.seconds) digits.seconds.textContent = String(seconds).padStart(2, "0");
    }
  };
  sync();
  const timer = window.setInterval(sync, 1000);
  document.addEventListener("kxcraft:page-leave", () => window.clearInterval(timer), { once: true });
})();
