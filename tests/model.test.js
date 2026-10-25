const fs = require("fs");
const path = require("path");
// Usage: node tests/model.test.js   (loads ../Model.js)
const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(".pragma library", "");
eval(src + ";globalThis.M = { RAILS, parseLine, loadPercent, deviationPercent, railBand, lineBand, estimatedEfficiency, estimatedAcWatts, normalizeRating, ratingLabel, ratingNote, EFFICIENCY_FLOORS, usePercent, severity, pushRing, extendRing, ringStats, addEnergy, bucketId, recordBucket, bucketStats, parseHistory, mergeHistory, serializeHistory, formatWatts, formatVolts, formatAmps, formatTemp, formatPercent, formatSigned, formatEnergy, formatFan, fanNote, barText, BUCKET_MS, BUCKETS }");

let fail = 0;
function eq(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) fail++;
  console.log((ok ? "ok   " : "FAIL ") + name + (ok ? "" : "  got " + JSON.stringify(got) + " want " + JSON.stringify(want)));
}
const near = (a, b, tol) => Math.abs(a - b) <= tol;
function check(name, cond) { eq(name, !!cond, true); }

// The real helper's lines.
const lines = fs.readFileSync(path.join(__dirname, "fixtures", "psu_lines.txt"), "utf8").trim().split("\n");
const info = M.parseLine(lines[0]);
eq("info model", [info.type, info.vendor, info.model, info.ratedW], ["info", "Corsair", "HX1200i", 1200]);
eq("info limits", [info.limits.volts["12v"].min, info.limits.volts["12v"].max, info.limits.amps["12v"], info.limits.temp], [8.406, 15.593, 135, 70]);
const s = M.parseLine(lines[1]);
eq("sample type", s.type, "sample");
check("sample has total and rails", s.w.total > 0 && s.w["12v"] > 0 && s.w["5v"] > 0 && s.w["3v3"] > 0);
eq("sample voltages", [s.v["12v"], s.v["5v"], s.v["3v3"]], [11.906, 5.078, 3.312]);
eq("sample line voltage", s.vin, 115);
eq("sample fan stopped", s.fan, 0);
const bar = M.parseLine('{"type":"bar","t":1,"w":234.0,"vrm":45.0,"case":44.5}');
eq("bar", [bar.type, bar.w, bar.vrm, bar["case"]], ["bar", 234, 45, 44.5]);
const barRails = M.parseLine('{"type":"bar","t":1,"w":234.0,"r":{"12v":200,"5v":20.5,"3v3":-4,"bogus":9},"vrm":45.0,"case":44.5}');
eq("bar rails clamped, unknown dropped", barRails.r, { "12v": 200, "5v": 20.5 });
eq("bar without rails", bar.r, {});

// Chart ring: one point per second, gaps filled by interpolation.
{
  const pt = (a, b, c) => ({ total: a + b + c, "12v": a, "5v": b, "3v3": c });
  const first = M.extendRing([], 0, pt(100, 10, 5), 10000, 300);
  eq("first point starts the ring", [first.ring.length, first.t], [1, 10000]);
  const filled = M.extendRing(first.ring, first.t, pt(200, 20, 10), 15000, 300);
  eq("5 s gap becomes 5 points", filled.ring.length, 6);
  eq("gap interpolated", [filled.ring[1]["12v"], filled.ring[3].total, filled.ring[5]["12v"]], [120, 184, 200]);
  eq("newest point time", filled.t, 15000);
  const early = M.extendRing(filled.ring, filled.t, pt(1, 1, 1), 15400, 300);
  eq("reading under a second later is dropped", [early.ring.length, early.t], [6, 15000]);
  const jitter = M.extendRing(filled.ring, filled.t, pt(210, 20, 10), 16900, 300);
  eq("1.9 s later counts as 2 points", [jitter.ring.length, jitter.t], [8, 17000]);
  const old = M.extendRing(filled.ring, filled.t, pt(1, 1, 1), 14000, 300);
  eq("a reading from the past restarts the ring", old.ring.length, 1);
  const late = M.extendRing(filled.ring, filled.t, pt(1, 1, 1), 15000 + 400000, 300);
  eq("a gap longer than the ring restarts it", late.ring.length, 1);
  let r = first;
  for (let i = 1; i <= 400; i++) r = M.extendRing(r.ring, r.t, pt(i, 1, 1), 10000 + i * 1000, 300);
  eq("ring capped", r.ring.length, 300);
}
eq("absent", M.parseLine('{"type":"absent"}'), { type: "absent" });

// Hostile and broken input.
eq("garbage", M.parseLine("nope"), null);
eq("empty", M.parseLine(""), null);
eq("array", M.parseLine("[1,2]"), null);
eq("unknown type", M.parseLine('{"type":"shell","cmd":"rm -rf"}'), null);
const evil = M.parseLine(JSON.stringify({ type: "sample", t: "x", vin: 1e9, w: { total: -5, "12v": "lots", "5v": 12, bogus: 9 }, v: { "12v": null, "5v": 99999 }, a: [1], vrm: 9999, "case": "hot", fan: -3, duty: 500 }));
eq("hostile sample is cleaned", [evil.vin, evil.w, evil.v, evil.a, evil.vrm, evil["case"], evil.fan, evil.duty, evil.t], [null, { "5v": 12 }, {}, {}, null, null, null, null, 0]);
const evilInfo = M.parseLine(JSON.stringify({ type: "info", vendor: "x".repeat(100), model: 5, ratedW: 99999, limits: { volts: { "12v": { min: -1, max: 1e6 }, evil: { min: 1, max: 2 } }, amps: { "12v": "x" }, temp: 5000 } }));
eq("hostile info is cleaned", [evilInfo.vendor.length, evilInfo.model, evilInfo.ratedW, evilInfo.limits.volts, evilInfo.limits.amps, evilInfo.limits.temp], [24, "", 0, { "12v": { min: null, max: null } }, {}, 0]);
eq("missing rails tolerated", M.parseLine('{"type":"sample","w":{"total":100},"v":{},"a":{}}').w, { total: 100 });

// Derived figures.
check("load percent", near(M.loadPercent(202, 1200), 16.83, 0.01));
eq("load percent without rating", M.loadPercent(202, 0), null);
check("12v deviation low", near(M.deviationPercent(11.906, 12), -0.783, 0.001));
check("5v deviation", near(M.deviationPercent(5.078, 5), 1.56, 0.001));
eq("band ok", M.railBand(-0.78), "ok");
eq("band warn", M.railBand(4), "warn");
eq("band warn low", M.railBand(-4.9), "warn");
eq("band bad high", M.railBand(5.5), "bad");
eq("band bad low", M.railBand(-6), "bad");
eq("band unknown", M.railBand(null), "unknown");
eq("line ok", M.lineBand(115, 115), "ok");
eq("line warn", M.lineBand(105, 115), "warn");
eq("line bad", M.lineBand(90, 115), "bad");
check("efficiency at 20%", near(M.estimatedEfficiency(0.2, "platinum"), 0.90, 1e-9));
check("efficiency at 50%", near(M.estimatedEfficiency(0.5, "platinum"), 0.92, 1e-9));
check("efficiency at 100%", near(M.estimatedEfficiency(1.0, "platinum"), 0.89, 1e-9));
check("efficiency between 20 and 50", M.estimatedEfficiency(0.35, "platinum") > 0.90 && M.estimatedEfficiency(0.35, "platinum") < 0.92);
check("efficiency below 20 holds", near(M.estimatedEfficiency(0.05, "platinum"), 0.90, 1e-9));
const ac = M.estimatedAcWatts(240, 1200, "platinum");
check("ac estimate", near(ac.efficiency, 0.90, 1e-9) && near(ac.watts, 266.67, 0.01) && near(ac.heat, 26.67, 0.01));
eq("ac estimate without rating", M.estimatedAcWatts(240, 0, "platinum"), null);
check("use percent", near(M.usePercent(15.5, 135), 11.48, 0.01));
eq("use percent clamps", M.usePercent(500, 135), 100);
eq("severity", [M.severity(40, 45, 70), M.severity(70, 45, 70), M.severity(57.5, 45, 70)], [0, 1, 0.5]);

// Short history and energy.
eq("ring cap", M.pushRing([1, 2, 3], 4, 3), [2, 3, 4]);
eq("ring stats", M.ringStats([2, 4, null, 6]), { min: 2, max: 6, avg: 4, count: 3 });
eq("ring stats empty", M.ringStats([]), null);
check("energy 1 hour at 100 W", near(M.addEnergy(0, 100, 0, 100, 3600000, 7200), 100, 1e-9));
eq("energy skips a long gap", M.addEnergy(5, 100, 0, 100, 600000, 60), 5);
eq("energy without a previous reading", M.addEnergy(5, null, null, 100, 1000, 60), 5);

// 12 hour buckets.
const MIN = 60000, H = 60 * MIN, base = 1000 * H;
{
  let list = [];
  M.recordBucket(list, 200, base);
  check("first record rolls a bucket", list.rolled === true);
  M.recordBucket(list, 300, base + MIN);
  check("same bucket does not roll", list.rolled === false);
  M.recordBucket(list, 100, base + 2 * MIN);
  eq("bucket holds min max sum n", list[0], { id: M.bucketId(base), min: 100, max: 300, sum: 600, n: 3 });
  M.recordBucket(list, 250, base + 30 * MIN);
  const st = M.bucketStats(list, base + 31 * MIN);
  check("stats across buckets", st.min === 100 && st.max === 300 && near(st.avg, 212.5, 1e-9) && st.count === 4);
  check("kept at 11h59m", M.bucketStats(list, base + 11 * H + 59 * MIN) !== null);
  eq("gone after 13h", M.bucketStats(list, base + 13 * H), null);
  M.recordBucket(list, NaN, base); M.recordBucket(list, -4, base); M.recordBucket(list, 99999, base);
  eq("bad readings ignored", list.length, 2);
}
{
  const list = [];
  for (let i = 0; i < 400; i++) M.recordBucket(list, 100 + i % 50, base + i * M.BUCKET_MS);
  check("ring is bounded", list.length <= M.BUCKETS + 1);
}
{
  const now = base + H, id = M.bucketId(now);
  const list = []; M.recordBucket(list, 200, now); M.recordBucket(list, 350, now + MIN);
  const back = M.parseHistory(M.serializeHistory(list), now);
  eq("history round trip", back, list.map(b => ({ id: b.id, min: b.min, max: b.max, sum: b.sum, n: b.n })));
  eq("stale history dropped", M.parseHistory(M.serializeHistory(list), now + 13 * H), []);
  eq("history garbage", M.parseHistory("{no", now), []);
  eq("history wrong version", M.parseHistory('{"version":2,"buckets":[]}', now), []);
  const evilFile = JSON.stringify({ version: 1, buckets: [
    { id, min: 5, max: 1, sum: 5, n: 1 },                 // min > max
    { id: id - 1, min: 1, max: 2, sum: -5, n: 1 },        // negative sum
    { id: id - 2, min: 1, max: 2, sum: 3, n: 0 },         // no samples
    null, 7,
    { id: id + 50, min: 1, max: 2, sum: 3, n: 1 },        // from the future
    { id: id - 3, min: 100, max: 200, sum: 600, n: 4 },   // good
  ] });
  eq("hostile history keeps only sane buckets", M.parseHistory(evilFile, now).map(b => b.id), [id - 3]);
  const merged = M.mergeHistory([{ id: 5, min: 100, max: 200, sum: 300, n: 2 }], [{ id: 5, min: 50, max: 150, sum: 800, n: 8 }, { id: 4, min: 1, max: 2, sum: 3, n: 2 }]);
  eq("merge orders by id and keeps the larger sample", merged.map(b => [b.id, b.min, b.max, b.n]), [[4, 1, 2, 2], [5, 50, 200, 8]]);
}

// Formatting.
eq("watts big", M.formatWatts(202.4), "202 W");
eq("watts small", M.formatWatts(29.5), "29.5 W");
eq("watts null", M.formatWatts(null), "–");
eq("volts", M.formatVolts(11.906), "11.91 V");
eq("amps big", M.formatAmps(12.75), "12.8 A");
eq("amps small", M.formatAmps(3.312), "3.31 A");
eq("temp c", M.formatTemp(44.75, false), "45°C");
eq("temp f", M.formatTemp(45, true), "113°F");
eq("signed", [M.formatSigned(1.56), M.formatSigned(-0.78), M.formatSigned(0)], ["+1.6%", "-0.8%", "0.0%"]);
eq("energy wh", M.formatEnergy(12.3), "12.3 Wh");
eq("energy kwh", M.formatEnergy(2500), "2.50 kWh");
eq("fan", [M.formatFan(0), M.formatFan(1450)], ["stopped", "1450 RPM"]);
eq("fan note zero rpm", M.fanNote(0, 45, 70), "zero-RPM mode (fan off at low load)");
eq("fan note stopped but hot", M.fanNote(0, 65, 70), "stopped while hot: check the PSU");
eq("fan note spinning", M.fanNote(900, 60, 70), "spinning");
eq("bar text", [M.barText(202.4), M.barText(null)], ["202W", "–"]);


// Every tier, and the setting cleaned.
eq("tiers known", Object.keys(M.EFFICIENCY_FLOORS), ["bronze", "silver", "gold", "platinum", "titanium"]);
for (const tier of Object.keys(M.EFFICIENCY_FLOORS)) {
  const f = M.EFFICIENCY_FLOORS[tier];
  check(tier + " floors rise then fall", f[0][1] < f[1][1] && f[2][1] < f[1][1]);
  check(tier + " eff at 50%", near(M.estimatedEfficiency(0.5, tier), f[1][1], 1e-9));
}
check("gold is below platinum at 50%", M.estimatedEfficiency(0.5, "gold") < M.estimatedEfficiency(0.5, "platinum"));
check("titanium is above platinum at 50%", M.estimatedEfficiency(0.5, "titanium") > M.estimatedEfficiency(0.5, "platinum"));
eq("normalize", [M.normalizeRating("Gold"), M.normalizeRating(" PLATINUM "), M.normalizeRating("none"), M.normalizeRating(""), M.normalizeRating(undefined), M.normalizeRating(null), M.normalizeRating("__proto__"), M.normalizeRating("constructor"), M.normalizeRating(5)], ["gold", "platinum", "", "", "", "", "", "", ""]);
eq("unknown tier has no efficiency", M.estimatedEfficiency(0.5, "none"), null);
eq("unknown tier has no ac estimate", M.estimatedAcWatts(240, 1200, "none"), null);
eq("no rating argument has no estimate", M.estimatedAcWatts(240, 1200), null);
eq("labels", [M.ratingLabel("platinum"), M.ratingLabel("gold"), M.ratingLabel("none")], ["80 PLUS Platinum", "80 PLUS Gold", ""]);
eq("note", [M.ratingNote("platinum"), M.ratingNote("gold"), M.ratingNote("none")], ["90% at 20% load, 92% at 50%, 89% at 100%", "87% at 20% load, 90% at 50%, 87% at 100%", ""]);
check("gold estimate is higher draw than platinum", M.estimatedAcWatts(600, 1200, "gold").watts > M.estimatedAcWatts(600, 1200, "platinum").watts);
console.log(fail === 0 ? "ALL PASSED" : fail + " FAILED");
process.exit(fail === 0 ? 0 : 1);
