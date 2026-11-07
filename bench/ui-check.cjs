// Run with Node and Playwright installed; uses local Chromium, no browser download.
const { chromium } = require("playwright");
const path = require("path");
(async () => {
  const browser = await chromium.launch({
    executablePath: process.env.CHROMIUM_PATH || "/usr/bin/chromium",
    headless: true,
    args: ["--no-sandbox"],
  });
  const page = await browser.newPage({
    viewport: { width: 1280, height: 900 },
  });
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(process.env.SYMPHONY_URL || "http://127.0.0.1:4001/tasks");
  await page.locator("#token").fill(process.env.SYMPHONY_DEMO_TOKEN);
  await page.getByRole("button", { name: "Connect", exact: true }).click();
  await page.locator("#card-fixture-1").click();
  await page
    .locator(".detail")
    .getByRole("heading", { name: "Simulated timeout change" })
    .waitFor();
  await page.screenshot({
    path: path.join(__dirname, "../docs/go-evidence/board/01-connected.png"),
    fullPage: true,
  });
  await page.getByRole("button", { name: "preview", exact: true }).click();
  await page
    .getByRole("button", { name: "Approve and start simulation" })
    .click();
  await page.getByRole("button", { name: "Stop and hold" }).waitFor();
  await page.getByRole("button", { name: "Stop and hold" }).click();
  await page.getByText(/stopped · attempt 1/).waitFor();
  await page.screenshot({
    path: path.join(__dirname, "../docs/go-evidence/board/02-stopped.png"),
    fullPage: true,
  });
  await page.getByRole("button", { name: "release-hold", exact: true }).click();
  await page.getByRole("button", { name: "preview", exact: true }).click();
  await page.getByRole("button", { name: "Approve new retry" }).click();
  await page.getByText(/succeeded · attempt 2/).waitFor();
  await page.screenshot({
    path: path.join(
      __dirname,
      "../docs/go-evidence/board/03-retry-succeeded.png",
    ),
    fullPage: true,
  });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({
    path: path.join(__dirname, "../docs/go-evidence/board/04-mobile.png"),
    fullPage: true,
  });
  if (
    await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)
  )
    throw Error("mobile overflow");
  if (errors.length) throw Error(errors.join("\n"));
  console.log(
    "PASS: connect, preview, start, stop/hold, release, retry, success, mobile width; no page errors",
  );
  await browser.close();
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
