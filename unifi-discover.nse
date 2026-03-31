-- unifi-discover.nse
-- Part of lss-network-tools (https://github.com/lssolutions-ie/lss-network-tools)
--
-- Discovers UniFi/Ubiquiti devices by sending the official discovery broadcast
-- on UDP port 10001 and parsing TLV responses. Equivalent to the
-- broadcast-ubiquiti-discover script shipped with Linux nmap builds, which is
-- absent from macOS Homebrew nmap.
--
-- Usage (called internally by lss-network-tools):
--   nmap --script /path/to/unifi-discover.nse
--
-- Output lines have the form:
--   UNIFI_DEVICE mac=<mac> ip=<ip>
-- so the calling shell can parse them with grep/sed without jq.

local nmap   = require "nmap"
local stdnse = require "stdnse"

description = [[Discovers UniFi/Ubiquiti devices via UDP port 10001 broadcast.
Sends the official UniFi discovery packets, binds to port 10001 to receive TLV
responses (devices reply back to port 10001, not the sender ephemeral port),
and parses MAC and IP from the response payload.]]

author   = "lss-network-tools"
license  = "Same as Nmap"
categories = {"broadcast", "discovery", "safe"}

-- prerule: runs once before host scanning (broadcast script style)
prerule = function() return true end

local function parse_tlv(data, src_ip)
  if #data < 4 then return nil end
  local mac, ip_str
  local offset = 5  -- skip 4-byte header; Lua strings are 1-indexed
  while offset + 2 <= #data do
    local tlv_type = data:byte(offset)
    local tlv_len  = data:byte(offset + 1) * 256 + data:byte(offset + 2)
    if offset + 2 + tlv_len > #data then break end
    local v = data:sub(offset + 3, offset + 2 + tlv_len)
    offset = offset + 3 + tlv_len

    if tlv_type == 0x01 and #v == 6 then
      -- Type 0x01: MAC address (6 bytes)
      mac = string.format("%02x:%02x:%02x:%02x:%02x:%02x",
        v:byte(1), v:byte(2), v:byte(3),
        v:byte(4), v:byte(5), v:byte(6))

    elseif tlv_type == 0x02 and #v >= 10 then
      -- Type 0x02: MAC (6 bytes) + IP (4 bytes)
      mac = string.format("%02x:%02x:%02x:%02x:%02x:%02x",
        v:byte(1), v:byte(2), v:byte(3),
        v:byte(4), v:byte(5), v:byte(6))
      ip_str = string.format("%d.%d.%d.%d",
        v:byte(7), v:byte(8), v:byte(9), v:byte(10))
    end
  end

  if mac then
    return { mac = mac, ip = ip_str or src_ip }
  end
  return nil
end

action = function()
  local sock = nmap.new_socket("udp")
  sock:set_timeout(500)

  -- Bind to port 10001: UniFi devices send their reply back to port 10001,
  -- not to the sender's ephemeral port.
  local ok, err = sock:bind(nil, 10001)
  if not ok then
    stdnse.debug1("bind port 10001 failed: %s", tostring(err))
    return nil
  end

  -- Send both known UniFi discovery packet versions to broadcast
  local pkts = { "\x01\x00\x00\x00", "\x02\x0a\x00\x04\x01\x00\x00\x01" }
  for _, pkt in ipairs(pkts) do
    sock:sendto("255.255.255.255", 10001, pkt)
  end

  local devices = {}
  local deadline = nmap.clock_ms() + 5000
  while nmap.clock_ms() < deadline do
    sock:set_timeout(math.max(100, deadline - nmap.clock_ms()))
    local ok2, data, src = sock:receivefrom()
    if ok2 and data then
      local dev = parse_tlv(data, src)
      if dev then
        devices[dev.mac] = dev
      end
    end
  end
  sock:close()

  if next(devices) == nil then return nil end

  local lines = {}
  for _, dev in pairs(devices) do
    table.insert(lines,
      string.format("UNIFI_DEVICE mac=%s ip=%s", dev.mac, dev.ip or "unknown"))
  end
  return table.concat(lines, "\n")
end
