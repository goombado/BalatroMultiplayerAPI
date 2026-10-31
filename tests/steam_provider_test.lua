-- Contract test for Steam providers (networking/steam.lua): a mod can stand in
-- for luasteam on a build with no Steam client, luasteam always wins when it
-- exists, and a connect that waits for the provider starts when it is ready.
-- Run from the MPAPI repository root: luajit tests/steam_provider_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

MPAPI = { _internal = {}, networking = {} }
dofile('domain/offline_reason.lua')
local R = MPAPI.OfflineReason
MPAPI.ConnectionState = { DISCONNECTED = 'disconnected', CONNECTED = 'connected' }
MPAPI.connection_state = { state = MPAPI.ConnectionState.DISCONNECTED }

local calls = {}
MPAPI.connect = function(opts)
	calls[#calls + 1] = 'connect'
end
MPAPI.disconnect = function()
	calls[#calls + 1] = 'disconnect'
end
MPAPI.get_last_opts = function()
	return {}
end
local mpapi_ready = true
MPAPI.is_ready = function()
	return mpapi_ready
end
MPAPI.account_button = {
	update = function()
		calls[#calls + 1] = 'menu'
	end,
}

local LOGIN_REQUIRED = 'login_required'
local provider
provider = {
	_present = true,
	_ready = false,
	_settled = false,
	present = function()
		return provider._present
	end,
	ready = function()
		return provider._ready
	end,
	settled = function()
		return provider._settled
	end,
	offline_reason = function()
		return LOGIN_REQUIRED
	end,
	get_steam_id = function()
		return 'provider-id'
	end,
	get_persona_name = function()
		return 'Provider Name'
	end,
	get_auth_ticket = function()
		return { ticket = 'providerticket', handle = 7 }
	end,
	cancel_auth_ticket = function(h)
		provider.cancelled = h
	end,
}

G = nil
dofile('networking/steam.lua')
local steam = MPAPI.networking.steam

-----------------------------
-- Without a provider: as before
-----------------------------

check(steam.provider() == nil, 'no provider registered')
check(not steam.available(), 'no luasteam: not available')
check(steam.unavailable_reason() == R.STEAM_NOT_RUNNING, 'no luasteam: Steam is not running')
check(not steam.defer_startup_connect(), 'no provider: the first connect is not deferred')

-----------------------------
-- Provider stands in for luasteam
-----------------------------

steam.register_provider(provider)
check(steam.provider() == provider, 'a present provider is used without luasteam')
check(not steam.available(), 'a provider that is not ready is not available')
check(steam.unavailable_reason() == LOGIN_REQUIRED, "the provider's reason is reported")
check(steam.get_steam_id() == 'provider-id' and steam.get_persona_name() == 'Provider Name', 'id and name come from the provider')
check(steam.get_auth_ticket().ticket == 'providerticket', 'tickets come from the provider')
steam.cancel_auth_ticket(7)
check(provider.cancelled == 7, 'cancels go to the provider')

-----------------------------
-- Startup and retry
-----------------------------

check(steam.defer_startup_connect(), 'a provider still logging in defers the first connect')
calls = {}
steam.provider_changed()
check(#calls == 1 and calls[1] == 'menu', 'still settling: only the menu refreshes')
provider._settled = true
calls = {}
steam.provider_changed()
check(calls[#calls] == 'connect', 'once settled, the deferred first connect starts')

-- That connect failed for want of a login (connection.lua asks why).
check(steam.unavailable_reason() == LOGIN_REQUIRED, 'the failure reason comes from the provider')
calls = {}
steam.provider_changed()
check(calls[#calls] ~= 'connect', 'no connect before the provider is ready')
provider._ready = true
calls = {}
steam.provider_changed()
check(calls[#calls - 1] == 'disconnect' and calls[#calls] == 'connect', 'logging in connects')
calls = {}
steam.provider_changed()
check(#calls == 1, 'and only once')

-- Ready before MPAPI's startup step: startup does the first connect.
provider._ready = false
steam.provider_changed()
mpapi_ready = false
provider._ready = true
calls = {}
steam.provider_changed()
check(calls[#calls] ~= 'connect', 'no connect before startup has run')
mpapi_ready = true

-- Log out (MPAPI.disconnect, no failed connect), then log in again.
provider._ready = false
steam.provider_changed()
provider._ready = true
calls = {}
steam.provider_changed()
check(calls[#calls] == 'connect', 'logging in again after a logout connects too')

MPAPI.connection_state.state = MPAPI.ConnectionState.CONNECTED
calls = {}
steam.provider_changed()
check(#calls == 0, 'a live connection is left alone')
MPAPI.connection_state.state = MPAPI.ConnectionState.DISCONNECTED

-----------------------------
-- luasteam always wins
-----------------------------

G = { STEAM = { user = {
	getSteamID = function()
		return 'desktop-id'
	end,
} } }
check(steam.provider() == nil, 'luasteam present: the provider is ignored')
check(steam.available(), 'luasteam present: available as before')
check(steam.get_steam_id() == 'desktop-id', 'luasteam present: the id comes from luasteam')
check(not steam.defer_startup_connect(), 'luasteam present: the first connect is not deferred')
G = nil

provider._present = false
check(steam.provider() == nil, 'a provider that is not present is not used')

-----------------------------
-- IP-literal hosts skip DNS (some resolvers reject them)
-----------------------------

package.preload.socket = function()
	return {}
end
local net = dofile('networking/nakama_net.lua')
package.preload.socket, package.loaded.socket = nil, nil
check(net.ipv4_literal('10.0.2.2') == '10.0.2.2', 'IPv4 literal is used as is')
check(net.ipv4_literal('192.168.1.24') == '192.168.1.24', 'LAN IPv4 literal is used as is')
check(net.ipv4_literal('nakama.example.com') == nil, 'hostnames still resolve through DNS')
check(net.ipv4_literal('256.1.1.1') == nil and net.ipv4_literal('1.2.3') == nil, 'malformed addresses still go to DNS')

print(('ok   %d checks'):format(checks))
