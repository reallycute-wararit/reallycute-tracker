// Three-way merge for the products blob. Reads the functions embedded in the page.
import fs from "fs";
import assert from "assert";

const html = fs.readFileSync(new URL("./content-task-tracker.html", import.meta.url), "utf8");
const m = html.match(/\/\/ SYNC_LIB_START([\s\S]*?)\/\/ SYNC_LIB_END/);
if (!m) throw new Error("sync library markers missing");
const { mergeValue, diffValue, summaryFromDiff, diffEmpty } = new Function(
  m[1] + "\nreturn { mergeValue, diffValue, summaryFromDiff, diffEmpty };"
)();

const base = {
  list: [
    { id: "a", n: "เอ", p: 10, ph: false, g: "หมวด", c: "หมวด" },
    { id: "b", n: "บี", p: 20, ph: true, g: "หมวด", c: "หมวด" },
  ],
  order: ["หมวด"],
  trash: [{ id: "t", n: "ถัง", p: 5 }],
  updatedAt: 1,
  csku_retired: ["OLD-1"],
  costCfg: { ship: 20, fees: { shopee: 10 }, updatedAt: 1 },
  botNote: "keep",
};
const local = {
  list: [
    { id: "new", n: "ใหม่", p: 1, g: "หมวด", c: "หมวด" },
    { id: "a", n: "เอ", p: 99, ph: false, g: "หมวด", c: "หมวด" },
    { id: "b", n: "บี", p: 20, ph: true, g: "หมวด", c: "หมวด" },
  ],
  order: ["หมวด"],
  trash: [{ id: "t", n: "ถัง", p: 5 }],
  updatedAt: 2,
  csku_retired: ["OLD-1"],
  costCfg: { ship: 20, fees: { shopee: 12 }, updatedAt: 2 },
  botNote: "keep",
};
const remote = {
  list: [
    { id: "a", n: "เอแก้โดยบอท", p: 10, ph: true, g: "หมวด", c: "หมวด" },
    { id: "b", n: "บี", p: 20, ph: true, g: "อื่น", c: "อื่น" },
    { id: "r", n: "จากบอท", p: 7, g: "หมวด", c: "หมวด" },
  ],
  order: ["อื่น", "หมวด"],
  trash: [{ id: "t", n: "ถัง", p: 5 }],
  updatedAt: 3,
  csku_retired: ["OLD-1", "OLD-2"],
  costCfg: { ship: 30, fees: { shopee: 10, tiktok: 8 }, updatedAt: 3 },
  botNote: "from-bot",
};

const merged = mergeValue("products", base, local, remote);
const byId = Object.fromEntries(merged.list.concat(merged.trash).map((p) => [p.id, p]));
assert.strictEqual(merged.list.map((p) => p.id).join(","), "new,a,b,r");
assert.strictEqual(byId.a.p, 99, "local price kept");
assert.strictEqual(byId.a.n, "เอแก้โดยบอท", "remote name kept");
assert.strictEqual(byId.a.ph, true, "remote photo flag kept");
assert.strictEqual(byId.b.g, "อื่น");
assert.deepStrictEqual(merged.csku_retired, ["OLD-1", "OLD-2"]);
assert.strictEqual(merged.costCfg.fees.shopee, 12);
assert.strictEqual(merged.costCfg.fees.tiktok, 8);
assert.strictEqual(merged.costCfg.ship, 30);
assert.strictEqual(merged.botNote, "from-bot");
assert.deepStrictEqual(merged.order, ["อื่น", "หมวด"]);

const remoteDel = JSON.parse(JSON.stringify(remote));
remoteDel.list = remoteDel.list.filter((p) => p.id !== "b");
const gone = mergeValue("products", base, local, remoteDel);
assert.ok(!gone.list.some((p) => p.id === "b") && !gone.trash.some((p) => p.id === "b"));

const localEditB = JSON.parse(JSON.stringify(local));
localEditB.list.find((p) => p.id === "b").ph = false;
const kept = mergeValue("products", base, localEditB, remoteDel);
assert.ok(kept.list.some((p) => p.id === "b" && p.ph === false));

const localTrash = JSON.parse(JSON.stringify(base));
localTrash.list = localTrash.list.filter((p) => p.id !== "b");
localTrash.trash = [{ id: "b", n: "บี", p: 20, ph: true, g: "หมวด", c: "หมวด", deletedAt: 9 }, ...base.trash];
const remoteEditB = JSON.parse(JSON.stringify(base));
remoteEditB.list.find((p) => p.id === "b").n = "บีใหม่";
const trashed = mergeValue("products", base, localTrash, remoteEditB);
assert.ok(trashed.trash.some((p) => p.id === "b" && p.n === "บีใหม่"));
assert.ok(!trashed.list.some((p) => p.id === "b"));

const posts = mergeValue(
  "posts",
  [{ id: "p1", label: "โพสต์", caption: "เก่า" }],
  [{ id: "p1", label: "โพสต์", caption: "ใหม่" }, { id: "p2", label: "เพิ่ม" }],
  [{ id: "p1", label: "โพสต์", caption: "เก่า", note: "บอท" }]
);
assert.strictEqual(posts.map((p) => p.id).join(","), "p1,p2");
assert.strictEqual(posts[0].caption, "ใหม่");
assert.strictEqual(posts[0].note, "บอท");

const d = diffValue("products", base, local);
assert.strictEqual(d.added.length, 1);
assert.strictEqual(d.edited.length, 1);
assert.ok(d.edited[0].fields.includes("p"));
assert.strictEqual(d.costChanged, true);
assert.strictEqual(diffEmpty(diffValue("products", base, base)), true);
assert.ok(summaryFromDiff(d).includes("เพิ่ม 1"));

const bothPrice = mergeValue("products", base, local, {
  ...base,
  list: base.list.map((p) => (p.id === "a" ? { ...p, p: 50 } : p)),
});
assert.strictEqual(bothPrice.list.find((p) => p.id === "a").p, 99);

const staleLocal = { ...base, list: base.list.map((p) => (p.id === "a" ? { ...p, ph: true } : p)), updatedAt: 5 };
const freshRemote = {
  ...base,
  list: base.list.map((p) => (p.id === "b" ? { ...p, up: true } : p)).concat([{ id: "r", n: "ใหม่บอท", g: "หมวด", c: "หมวด" }]),
  updatedAt: 6,
};
const safe = mergeValue("products", base, staleLocal, freshRemote);
assert.strictEqual(safe.list.find((p) => p.id === "a").ph, true);
assert.strictEqual(safe.list.find((p) => p.id === "b").up, true);
assert.ok(safe.list.some((p) => p.id === "r"));

console.log("sync-merge tests ok");
