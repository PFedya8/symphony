// Two real browser tabs; start the current Go backend with a fresh database.
const { chromium } = require("playwright");
const assert = require("node:assert/strict");
const path = require("node:path");
(async () => {
  const browser = await chromium.launch({
    executablePath: process.env.CHROMIUM_PATH || "/usr/bin/chromium",
    headless: true,
    args: ["--no-sandbox"],
  });
  try {
    const context = await browser.newContext({
      viewport: { width: 1000, height: 850 },
    });
    const first = await context.newPage(),
      second = await context.newPage();
    const errors = [];
    for (const page of [first, second]) {
      page.on("pageerror", (e) => errors.push(e.message));
      await page.goto(
        process.env.SYMPHONY_URL || "http://127.0.0.1:4003/tasks",
      );
      await page.locator("#token").fill(process.env.SYMPHONY_DEMO_TOKEN);
      await page.getByRole("button", { name: "Connect", exact: true }).click();
      await page
        .getByRole("heading", { name: "Simulated timeout change" })
        .waitFor();
    }
    async function preview(page) {
      const response = page.waitForResponse(
        (r) =>
          r.url().endsWith("/commands") &&
          r.request().postDataJSON()?.op === "preview",
      );
      await page.getByRole("button", { name: "preview", exact: true }).click();
      const result = await (await response).json();
      await page
        .getByRole("button", { name: "Approve and start simulation" })
        .waitFor();
      return result.id;
    }
    const firstID = await preview(first),
      secondID = await preview(second);
    assert.notEqual(firstID, secondID);
    await first
      .getByRole("button", { name: "Approve and start simulation" })
      .waitFor({ state: "detached", timeout: 4000 });
    for (const page of [first, second]) {
      const html = await page.content();
      assert(!html.includes(firstID));
      assert(!html.includes(secondID));
    }
    await first.screenshot({
      path: path.join(__dirname, "../docs/go-evidence/05-replaced-preview.png"),
      fullPage: true,
    });
    await second.getByRole("button", { name: "hold", exact: true }).click();
    await second
      .getByRole("button", { name: "Approve and start simulation" })
      .waitFor({ state: "detached" });
    await second
      .getByRole("button", { name: "release-hold", exact: true })
      .click();
    const finalID = await preview(second);
    await second
      .getByRole("button", { name: "Approve and start simulation" })
      .click();
    await second.getByText(/succeeded · attempt 1/).waitFor();
    const results = await second.evaluate(async (token) => {
      const headers = { Authorization: "Bearer " + token };
      return Promise.all(
        ["snapshot", "events"].map(async (view) => {
          const r = await fetch("/api/v1/control/" + view, { headers });
          return r.json();
        }),
      );
    }, process.env.SYMPHONY_DEMO_TOKEN);
    for (const id of [firstID, secondID, finalID])
      assert(!JSON.stringify(results).includes(id));
    assert.equal(results[0].approval_valid, false);
    await second.screenshot({
      path: path.join(__dirname, "../docs/go-evidence/06-redacted-run.png"),
      fullPage: true,
    });
    assert.deepEqual(errors, []);
    console.log(
      "PASS: two-tab preview replacement, private approval redaction, hold invalidation, run completion, no page errors",
    );
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
