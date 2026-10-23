.pragma library

// Parsing and arithmetic for the PSU widget. Nothing here touches the shell, so
// everything can be tested with node.
//
// The helper's output is parsed as untrusted data, the way the shell's other
// plugins treat a helper process: known keys only, numbers clamped to a plausible
// range, anything else dropped.

var RAILS = [
  { key: "12v", label: "+12V", nominal: 12.0 },
  { key: "5v", label: "+5V", nominal: 5.0 },
  { key: "3v3", label: "+3.3V", nominal: 3.3 }
]

// ------------------------------------------------------------------- parsing

function num(value, min, max) {
  if (typeof value !== "number" || !isFinite(value)) return null
  return value < min || value > max ? null : value
}

function numbersFor(raw, min, max) {
  var out = {}
  if (!raw || typeof raw !== "object") return out
  for (var i = 0; i < RAILS.length; i++) {
    var v = num(raw[RAILS[i].key], min, max)
    if (v !== null) out[RAILS[i].key] = v
  }
  return out
}

// One line from psu-read.py -> a clean message, or null.
function parseLine(text) {
  var parsed
  try {
    parsed = JSON.parse(String(text))
  } catch (e) {
    return null
  }
  if (!parsed || typeof parsed !== "object") return null

  if (parsed.type === "absent") return { type: "absent" }

  if (parsed.type === "info") {
    var limits = parsed.limits && typeof parsed.limits === "object" ? parsed.limits : {}
    var volts = {}
    var rawVolts = limits.volts && typeof limits.volts === "object" ? limits.volts : {}
    for (var i = 0; i < RAILS.length; i++) {
      var key = RAILS[i].key
      var pair = rawVolts[key]
      if (pair && typeof pair === "object") {
        volts[key] = { min: num(pair.min, 0, 50), max: num(pair.max, 0, 50) }
      }
    }
    return {
      type: "info",
      vendor: typeof parsed.vendor === "string" ? parsed.vendor.slice(0, 24) : "",
      model: typeof parsed.model === "string" ? parsed.model.slice(0, 32) : "",
      ratedW: num(parsed.ratedW, 0, 5000) || 0,
      limits: { volts: volts, amps: numbersFor(limits.amps, 0, 1000), temp: num(limits.temp, 0, 200) || 0 }
    }
  }

  if (parsed.type === "sample") {
    return {
      type: "sample",
      t: num(parsed.t, 0, 1e15) || 0,
      vin: num(parsed.vin, 0, 500),
      w: (function() {
        var rails = numbersFor(parsed.w, 0, 5000)
        var total = parsed.w && typeof parsed.w === "object" ? num(parsed.w.total, 0, 5000) : null
        if (total !== null) rails.total = total
        return rails
      })(),
      v: numbersFor(parsed.v, 0, 50),
      a: numbersFor(parsed.a, 0, 1000),
      vrm: num(parsed.vrm, -40, 200),
      "case": num(parsed["case"], -40, 200),
      fan: num(parsed.fan, 0, 30000),
      duty: num(parsed.duty, 0, 100)
    }
  }

  if (parsed.type === "bar") {
    return {
      type: "bar",
      t: num(parsed.t, 0, 1e15) || 0,
      w: num(parsed.w, 0, 5000),
      vrm: num(parsed.vrm, -40, 200),
      "case": num(parsed["case"], -40, 200)
    }
  }
  return null
}

// ---------------------------------------------------------------- derived

function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

// Share of the rated output, 0-100+.
function loadPercent(watts, ratedW) {
  if (watts === null || watts === undefined || !(ratedW > 0)) return null
  return 100 * watts / ratedW
}

// How far a rail sits from nominal, in percent (positive = high).
function deviationPercent(volts, nominal) {
  if (volts === null || volts === undefined || !(nominal > 0)) return null
  return 100 * (volts - nominal) / nominal
}

// The ATX specification allows plus or minus 5 percent on the main rails. Inside
// 3 percent is comfortable; 3 to 5 is within spec but worth noticing; beyond 5 is out.
function railBand(deviation) {
  if (deviation === null || deviation === undefined) return "unknown"
  var d = Math.abs(deviation)
  if (d <= 3) return "ok"
  if (d <= 5) return "warn"
  return "bad"
}

// Mains tolerance: 115 V nominal, usable range roughly plus or minus 10 percent.
function lineBand(vin, nominal) {
  var d = deviationPercent(vin, nominal)
  if (d === null) return "unknown"
  var a = Math.abs(d)
  if (a <= 5) return "ok"
  if (a <= 10) return "warn"
  return "bad"
}

// 80 PLUS minimum efficiency at 115 V for each certification tier, as
// [load fraction, efficiency] points at 20%, 50% and 100% load. These are
// certification floors, not a measured curve; a real unit does a little better.
// The supply does not report wall power, so these are all the widget has to
// estimate it from. Below 20% load nothing is certified, so it holds the 20% figure.
var EFFICIENCY_FLOORS = {
  bronze: [[0.2, 0.82], [0.5, 0.85], [1.0, 0.82]],
  silver: [[0.2, 0.85], [0.5, 0.88], [1.0, 0.85]],
  gold: [[0.2, 0.87], [0.5, 0.90], [1.0, 0.87]],
  platinum: [[0.2, 0.90], [0.5, 0.92], [1.0, 0.89]],
  titanium: [[0.2, 0.92], [0.5, 0.94], [1.0, 0.90]]
}

// The setting, cleaned: a known tier, or "" for none (the estimate is then hidden).
function normalizeRating(name) {
  var key = String(name === undefined || name === null ? "" : name).trim().toLowerCase()
  // Own keys only: a plain object also answers to "constructor" and "__proto__".
  return Object.prototype.hasOwnProperty.call(EFFICIENCY_FLOORS, key) ? key : ""
}

// "80 PLUS Platinum", or "" when no tier is set.
function ratingLabel(rating) {
  var key = normalizeRating(rating)
  return key === "" ? "" : "80 PLUS " + key.charAt(0).toUpperCase() + key.slice(1)
}

// The floors in words, for a tooltip: "90% at 20% load, 92% at 50%, 89% at 100%".
function ratingNote(rating) {
  var points = EFFICIENCY_FLOORS[normalizeRating(rating)]
  if (!points) return ""
  return Math.round(points[0][1] * 100) + "% at 20% load, " + Math.round(points[1][1] * 100) + "% at 50%, " + Math.round(points[2][1] * 100) + "% at 100%"
}

function estimatedEfficiency(loadFraction, rating) {
  var points = EFFICIENCY_FLOORS[normalizeRating(rating)]
  if (!points) return null
  var x = clamp(loadFraction, 0, 1.2)
  if (x <= points[0][0]) return points[0][1]
  for (var i = 1; i < points.length; i++) {
    if (x <= points[i][0]) {
      var t = (x - points[i - 1][0]) / (points[i][0] - points[i - 1][0])
      return points[i - 1][1] + t * (points[i][1] - points[i - 1][1])
    }
  }
  return points[points.length - 1][1]
}

// What the wall probably supplies for this much DC output. An upper-bound-ish
// estimate (it uses the certified minimum efficiency), always labelled as one.
// null when the tier is unknown: better no number than a wrong one.
function estimatedAcWatts(dcWatts, ratedW, rating) {
  if (dcWatts === null || dcWatts === undefined || !(ratedW > 0)) return null
  var eff = estimatedEfficiency(dcWatts / ratedW, rating)
  if (eff === null) return null
  return { watts: dcWatts / eff, efficiency: eff, heat: dcWatts / eff - dcWatts }
}

// Share of a protection limit in use (current against its over-current trip).
function usePercent(value, limit) {
  if (value === null || value === undefined || !(limit > 0)) return null
  return clamp(100 * value / limit, 0, 100)
}

function severity(value, warn, critical) {
  if (value === null || value === undefined || !isFinite(value)) return 0
  if (value <= warn) return 0
  return clamp((value - warn) / Math.max(1e-9, critical - warn), 0, 1)
}

// ------------------------------------------------------------- short history

function pushRing(arr, value, cap) {
  var out = arr.slice()
  out.push(value)
  while (out.length > cap) out.shift()
  return out
}

function ringStats(arr) {
  var min = Infinity, max = -Infinity, sum = 0, n = 0
  for (var i = 0; i < arr.length; i++) {
    var v = arr[i]
    if (typeof v !== "number" || !isFinite(v)) continue
    if (v < min) min = v
    if (v > max) max = v
    sum += v
    n++
  }
  return n === 0 ? null : { min: min, max: max, avg: sum / n, count: n }
}

// Energy between two readings (trapezoid), in watt-hours. A gap longer than
// maxGapSec is not integrated: the shell was asleep, not the PSU idle.
function addEnergy(whSoFar, prevW, prevT, w, t, maxGapSec) {
  if (prevW === null || prevT === null || w === null || t <= prevT) return whSoFar
  var dt = (t - prevT) / 1000
  if (dt > maxGapSec) return whSoFar
  return whSoFar + (prevW + w) / 2 * dt / 3600
}

// ----------------------------------------------------------- 12 hour history
//
// Ten-minute buckets of total output power: lowest, highest and the sum and count
// for the average. Constant memory, tiny file. A reading ages out between 12 h and
// 12 h 10 min after it happened.

var BUCKET_MS = 10 * 60 * 1000
var BUCKETS = 72

function bucketId(nowMs) { return Math.floor(nowMs / BUCKET_MS) }

// Fold one reading in (mutates and returns the list). Returns the list; sets
// `rolled` on the returned array's .rolled to whether a new bucket opened.
function recordBucket(list, watts, nowMs) {
  if (typeof watts !== "number" || !isFinite(watts) || watts < 0 || watts > 5000) return list
  var id = bucketId(nowMs)
  while (list.length > 0 && list[0].id < id - BUCKETS) list.shift()
  var last = list.length > 0 ? list[list.length - 1] : null
  if (last && last.id >= id) {
    if (watts < last.min) last.min = watts
    if (watts > last.max) last.max = watts
    last.sum += watts
    last.n += 1
    list.rolled = false
    return list
  }
  list.push({ id: id, min: watts, max: watts, sum: watts, n: 1 })
  list.rolled = true
  return list
}

function bucketStats(list, nowMs) {
  var oldest = bucketId(nowMs) - BUCKETS
  var min = Infinity, max = -Infinity, sum = 0, n = 0
  for (var i = 0; i < list.length; i++) {
    var b = list[i]
    if (b.id < oldest) continue
    if (b.min < min) min = b.min
    if (b.max > max) max = b.max
    sum += b.sum
    n += b.n
  }
  return n === 0 ? null : { min: min, max: max, avg: sum / n, count: n }
}

// The saved file, read back as untrusted data.
function parseHistory(raw, nowMs) {
  var out = []
  var text = String(raw || "").trim()
  if (text === "") return out
  try {
    var parsed = JSON.parse(text)
    if (!parsed || parsed.version !== 1 || !(parsed.buckets instanceof Array)) return out
    var nowId = bucketId(nowMs)
    var lastId = -1
    for (var i = 0; i < parsed.buckets.length && i < BUCKETS + 8; i++) {
      var b = parsed.buckets[i]
      if (!b || typeof b !== "object") continue
      var id = Math.floor(Number(b.id))
      var min = num(b.min, 0, 5000), max = num(b.max, 0, 5000), sum = num(b.sum, 0, 1e12)
      var n = Math.floor(Number(b.n))
      if (!isFinite(id) || id < 0 || id < nowId - BUCKETS || id > nowId + 1 || id <= lastId) continue
      if (min === null || max === null || sum === null || !(n > 0) || n > 1e7 || min > max) continue
      out.push({ id: id, min: min, max: max, sum: sum, n: n })
      lastId = id
    }
  } catch (e) {
    return []
  }
  return out
}

// Saved buckets, plus whatever was recorded before the file arrived.
function mergeHistory(a, b) {
  var byId = {}
  var lists = [a, b]
  for (var l = 0; l < lists.length; l++) {
    for (var i = 0; i < lists[l].length; i++) {
      var x = lists[l][i]
      var have = byId[x.id]
      if (!have) byId[x.id] = { id: x.id, min: x.min, max: x.max, sum: x.sum, n: x.n }
      else if (x.n > have.n) byId[x.id] = { id: x.id, min: Math.min(x.min, have.min), max: Math.max(x.max, have.max), sum: x.sum, n: x.n }
      else {
        have.min = Math.min(have.min, x.min)
        have.max = Math.max(have.max, x.max)
      }
    }
  }
  return Object.keys(byId).map(Number).sort(function(p, q) { return p - q }).map(function(id) { return byId[id] })
}

function serializeHistory(list) {
  return JSON.stringify({ version: 1, buckets: list }) + "\n"
}

// ---------------------------------------------------------------- formatting

function fixed(v, digits) {
  return v === null || v === undefined || !isFinite(v) ? "–" : v.toFixed(digits)
}

function formatWatts(w) {
  if (w === null || w === undefined || !isFinite(w)) return "–"
  return (w >= 100 ? Math.round(w) : w.toFixed(1)) + " W"
}

function formatVolts(v, digits) { return v === null || v === undefined || !isFinite(v) ? "–" : v.toFixed(digits === undefined ? 2 : digits) + " V" }

function formatAmps(a) { return a === null || a === undefined || !isFinite(a) ? "–" : a.toFixed(a >= 10 ? 1 : 2) + " A" }

function formatTemp(c, fahrenheit) {
  if (c === null || c === undefined || !isFinite(c)) return "–"
  return Math.round(fahrenheit ? c * 9 / 5 + 32 : c) + "°" + (fahrenheit ? "F" : "C")
}

function formatPercent(p, digits) {
  return p === null || p === undefined || !isFinite(p) ? "–" : p.toFixed(digits === undefined ? 0 : digits) + "%"
}

function formatSigned(p, digits) {
  if (p === null || p === undefined || !isFinite(p)) return "–"
  return (p > 0 ? "+" : "") + p.toFixed(digits === undefined ? 1 : digits) + "%"
}

function formatEnergy(wh) {
  if (wh === null || wh === undefined || !isFinite(wh)) return "–"
  return wh >= 1000 ? (wh / 1000).toFixed(2) + " kWh" : wh.toFixed(wh >= 100 ? 0 : 1) + " Wh"
}

function formatFan(rpm) {
  if (rpm === null || rpm === undefined || !isFinite(rpm)) return "–"
  return rpm > 0 ? Math.round(rpm) + " RPM" : "stopped"
}

// Fan stopped while the PSU is cool is the designed zero-RPM mode, not a fault.
function fanNote(rpm, vrmC, tempLimitC) {
  if (rpm === null || rpm === undefined) return ""
  if (rpm > 0) return "spinning"
  if (vrmC !== null && tempLimitC > 0 && vrmC >= tempLimitC - 10) return "stopped while hot: check the PSU"
  return "zero-RPM mode (fan off at low load)"
}

function barText(w) {
  return w === null || w === undefined || !isFinite(w) ? "–" : Math.round(w) + "W"
}
