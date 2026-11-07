// Real Go backend, fresh fixture database, synthetic task content only.
// SYMPHONY_URL=http://127.0.0.1:4017 SYMPHONY_DEMO_TOKEN=... node bench/ui-board-check.cjs
const { chromium } = require("playwright");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { randomUUID } = require("node:crypto");
(async () => {
  const base = (process.env.SYMPHONY_URL || "http://127.0.0.1:4017").replace(
    /\/tasks\/?$/,
    "",
  );
  const token = process.env.SYMPHONY_DEMO_TOKEN;
  assert(token && token.length >= 32, "Set the synthetic instance token");
  async function api(payload) {
    const response = await fetch(base + "/api/v1/control/commands", {
      method: "POST",
      headers: {
        Authorization: "Bearer " + token,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    });
    const data = await response.json();
    assert(response.ok, JSON.stringify(data));
    return data;
  }
  async function mutate(op, fields = {}, id = "fixture-1") {
    const snap = await api({ op: "snapshot", task_id: id });
    return api({
      op,
      task_id: id,
      revision: op === "create" ? snap.board_revision : snap.task.revision,
      key: randomUUID(),
      ...fields,
    });
  }
  let snap = await api({ op: "snapshot" });
  assert.equal(snap.tasks.length, 1, "Use a fresh fixture DB");
  for (const [title, stage] of [
    ["Investigate retry boundaries", "Backlog"],
    ["Review resource comparison", "Human Review"],
    ["Prepare project configuration", "Todo"],
  ]) {
    const task = await mutate("create", {
      title,
      project: "demo",
      description:
        "Synthetic browser-test task. No real execution or PR is implied.",
    });
    await mutate("move", { stage }, task.id);
  }
  const browser = await chromium.launch({
    executablePath: process.env.CHROMIUM_PATH || "/usr/bin/chromium",
    headless: true,
    args: ["--no-sandbox"],
  });
  const out = path.join(__dirname, "../docs/go-evidence/board");
  fs.mkdirSync(out, { recursive: true });
  try {
    const page = await browser.newPage({
      viewport: { width: 1500, height: 1000 },
    });
    async function clickMutation(op, name) {
      const response = page.waitForResponse(
        (r) =>
          r.url().endsWith("/commands") &&
          r.request().postDataJSON()?.op === op,
      );
      await page.getByRole("button", { name, exact: true }).click();
      await response;
      await page.waitForFunction(() => !busy);
    }
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.goto(base + "/tasks");
    await page.locator("#token").fill(token);
    await page.getByRole("button", { name: "Connect", exact: true }).click();
    await page.locator("#card-fixture-1").waitFor();
    await page.screenshot({
      path: path.join(out, "01-board-desktop.png"),
      fullPage: true,
    });
    await page.locator("#card-fixture-1").click();
    await page.getByText("Edit plan", { exact: true }).click();
    await page
      .locator("#plan-text")
      .fill(
        "Inspect coordinator boundaries\nRun synthetic checks\nReview resource evidence",
      );
    await clickMutation("plan", "Save plan");
    await clickMutation("check", "Toggle Inspect coordinator boundaries");
    await page.getByText("Publish authored update", { exact: true }).click();
    await page
      .locator("#worklog-plan_text")
      .fill(
        "Inspect coordinator\n  Confirm one execution owner\n  Check task isolation",
      );
    await page
      .locator("#worklog-acceptance_text")
      .fill("Shared CLI and browser contract\n  Reject stale revisions");
    await page
      .locator("#worklog-validation_text")
      .fill(
        "Run synthetic API and browser tests\nReview results before any release",
      );
    await clickMutation("worklog", "Publish update");
    await page
      .locator("#comment-text")
      .fill("Synthetic review: check evidence before approving a run.");
    await clickMutation("comment", "Post comment");
    await page
      .locator(".thread p")
      .filter({ hasText: "Synthetic review:" })
      .waitFor();
    await page
      .getByText("Add an existing evidence link", { exact: true })
      .click();
    await page
      .locator("#link-title")
      .fill("Go implementation PR (operator supplied)");
    await page
      .locator("#link-url")
      .fill("https://github.com/PFedya8/symphony/pull/3");
    await clickMutation("link", "Add link");
    await page.locator("a.evidence").waitFor();
    await page.locator(".detail").evaluate((e) => (e.scrollTop = 0));
    await page.screenshot({
      path: path.join(out, "02-task-desktop.png"),
      fullPage: true,
    });
    // Polling must retain a dirty draft and its old revision.
    await page.locator("#plan-text").fill("Retain this unsaved draft");
    await mutate("comment", { text: "Concurrent synthetic API edit" });
    await page.locator(".stale").waitFor();
    assert.equal(
      await page.locator("#plan-text").inputValue(),
      "Retain this unsaved draft",
    );
    await clickMutation("plan", "Save plan");
    await page
      .locator("#detail-error")
      .filter({ hasText: /revision/ })
      .waitFor();
    await page.setViewportSize({ width: 390, height: 844 });
    await page.screenshot({
      path: path.join(out, "03-stale-draft-mobile.png"),
      fullPage: true,
    });
    await page
      .locator("#plan-task")
      .getByRole("button", { name: "Reload current data" })
      .click();
    await page.locator("#comment-text").fill("<img src=x onerror=alert(1)>");
    await clickMutation("comment", "Post comment");
    await page
      .locator(".thread p")
      .filter({ hasText: "<img src=x onerror=alert(1)>" })
      .waitFor();
    assert.equal(await page.locator("img").count(), 0);
    // Bad external URLs stay as drafts and never become navigable links.
    await page
      .locator("#link-url")
      .fill("https://user:secret@example.com/private");
    await page.locator("#link-title").fill("Rejected link");
    await clickMutation("link", "Add link");
    await page.locator("#detail-error").filter({ hasText: /url/ }).waitFor();
    assert.equal(await page.locator('a[href*="secret"]').count(), 0);
    assert.equal(
      await page.locator("#link-title").inputValue(),
      "Rejected link",
    );
    await page.screenshot({
      path: path.join(out, "04-evidence-mobile.png"),
      fullPage: true,
    });
    await page.locator("#move-stage").selectOption("Human Review");
    await clickMutation("move", "Move task");
    await page.getByRole("button", { name: "Close task" }).click();
    await page.locator('[data-stage="Human Review"] #card-fixture-1').waitFor();
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth > innerWidth,
      ),
      false,
    );
    await page.screenshot({
      path: path.join(out, "05-board-mobile.png"),
      fullPage: true,
    });
    assert.deepEqual(errors, []);
    console.log(
      "PASS: real durable Go board, plan/checklist/worklog/comment/link, stale draft conflict, HTML text safety, invalid URL rejection, mobile move and no page errors",
    );
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
