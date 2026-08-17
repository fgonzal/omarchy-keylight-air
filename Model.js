// Pure helpers for the Key Light Air plugin. No QML types in here so the
// logic stays testable with any JS runtime.
.pragma library

// The Elgato API expresses color temperature in mireds (143..344). Humans and
// every other lighting UI use Kelvin, so the panel works in Kelvin and
// converts at the API boundary. K = 1,000,000 / mired.
var MIRED_MIN = 143 // ~7000K (coolest)
var MIRED_MAX = 344 // ~2900K (warmest)
var KELVIN_MIN = 2900
var KELVIN_MAX = 7000
var BRIGHTNESS_MIN = 3 // the device rejects values below 3
var BRIGHTNESS_MAX = 100

function clamp(v, lo, hi) {
  return Math.max(lo, Math.min(hi, v))
}

function kelvinFromMired(mired) {
  if (!mired) return 0
  return clamp(Math.round(1000000 / mired / 50) * 50, KELVIN_MIN, KELVIN_MAX)
}

function miredFromKelvin(kelvin) {
  if (!kelvin) return MIRED_MAX
  return clamp(Math.round(1000000 / kelvin), MIRED_MIN, MIRED_MAX)
}

function clampBrightness(v) {
  return clamp(Math.round(v), BRIGHTNESS_MIN, BRIGHTNESS_MAX)
}

// Parse the /elgato/lights response. Returns null when the payload is not
// the expected shape; the caller treats that as "unreachable".
function parseLights(text) {
  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return null
  }
  if (!parsed || !parsed.lights || !parsed.lights.length) return null
  var light = parsed.lights[0]
  if (light.on === undefined) return null
  return {
    on: light.on === 1,
    brightness: clampBrightness(light.brightness || BRIGHTNESS_MIN),
    temperature: clamp(light.temperature || MIRED_MAX, MIRED_MIN, MIRED_MAX)
  }
}

// Build a PUT payload from a partial patch ({on, brightness, temperature},
// any subset). The device accepts partial light objects.
function lightsPayload(patch) {
  var light = {}
  if (patch.on !== undefined) light.on = patch.on ? 1 : 0
  if (patch.brightness !== undefined) light.brightness = clampBrightness(patch.brightness)
  if (patch.temperature !== undefined) light.temperature = clamp(Math.round(patch.temperature), MIRED_MIN, MIRED_MAX)
  return JSON.stringify({ lights: [light] })
}

// Parse the /elgato/accessory-info response. Returns null when the payload
// is not the expected shape.
function parseAccessoryInfo(text) {
  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return null
  }
  if (!parsed || parsed.productName === undefined) return null
  var wifi = parsed["wifi-info"] || {}
  return {
    displayName: String(parsed.displayName || ""),
    productName: String(parsed.productName || ""),
    firmware: String(parsed.firmwareVersion || "")
      + (parsed.firmwareBuildNumber ? " (build " + parsed.firmwareBuildNumber + ")" : ""),
    serialNumber: String(parsed.serialNumber || ""),
    macAddress: String(parsed.macAddress || ""),
    ssid: String(wifi.ssid || ""),
    frequencyMHz: typeof wifi.frequencyMHz === "number" ? wifi.frequencyMHz : 0,
    rssi: typeof wifi.rssi === "number" ? wifi.rssi : 0
  }
}

// Nerd-font wifi-strength glyph for an RSSI reading (dBm, negative).
function wifiGlyph(rssi) {
  if (!rssi) return ""
  if (rssi >= -50) return "󰤨"
  if (rssi >= -60) return "󰤥"
  if (rssi >= -70) return "󰤢"
  return "󰤟"
}

// Decode avahi's \NNN decimal escapes ("Elgato\032Key\032Light\032Air").
function decodeAvahiName(name) {
  return String(name || "").replace(/\\(\d{3})/g, function(_, code) {
    return String.fromCharCode(parseInt(code, 10))
  })
}

// Parse `avahi-browse -rtp _elg._tcp` output. Resolved rows look like:
//   =;iface;IPv4;name;type;domain;hostname;address;port;txt
// Returns { address, port, name } for the first resolved IPv4 row, else null.
function parseAvahi(text) {
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var f = lines[i].split(";")
    if (f[0] !== "=" || f[2] !== "IPv4" || f.length < 9) continue
    if (!f[7]) continue
    return {
      address: f[7],
      port: parseInt(f[8], 10) || 9123,
      name: decodeAvahiName(f[3])
    }
  }
  return null
}
