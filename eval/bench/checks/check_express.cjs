const assert = require("node:assert");
const path = require("node:path");
const mod = require(path.resolve(process.argv[2]));
const app = mod.default || mod.app || mod;

(async () => {
  const server = app.listen(0);
  await new Promise((r) => server.once("listening", r));
  const base = "http://127.0.0.1:" + server.address().port;
  const req = (method, url, body) =>
    fetch(base + url, { method, headers: body ? { "content-type": "application/json" } : {}, body: body ? JSON.stringify(body) : undefined });
  try {
    let r = await req("GET", "/notes");
    assert.strictEqual(r.status, 200);
    assert.ok(Array.isArray(await r.json()));
    r = await req("POST", "/notes", { text: "hello bench" });
    assert.strictEqual(r.status, 201);
    const note = await r.json();
    assert.strictEqual(note.text, "hello bench");
    assert.strictEqual(typeof note.id, "number");
    r = await req("GET", "/notes");
    assert.ok((await r.json()).some((n) => n.id === note.id && n.text === "hello bench"));
    r = await req("POST", "/notes", { text: "" });
    assert.strictEqual(r.status, 400);
    assert.ok(typeof (await r.json()).error === "string");
    r = await req("POST", "/notes", {});
    assert.strictEqual(r.status, 400);
    r = await req("DELETE", "/notes/" + note.id);
    assert.strictEqual(r.status, 204);
    r = await req("DELETE", "/notes/" + note.id);
    assert.strictEqual(r.status, 404);
    r = await req("GET", "/notes");
    assert.ok(!(await r.json()).some((n) => n.id === note.id));
    console.log("express check ok");
  } finally {
    server.close();
  }
})().catch((e) => {
  console.error(e && e.message ? e.message : e);
  process.exit(1);
});
