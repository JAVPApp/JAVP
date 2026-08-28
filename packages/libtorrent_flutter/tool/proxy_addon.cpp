// Standalone proxy helper linked against the stock libtorrent_flutter .so
// (with selected C++ symbols globalized). SessionWrapper starts with lt::session.

#include <cstring>

#include <libtorrent/session.hpp>
#include <libtorrent/settings_pack.hpp>

#include "../src/torrent_bridge.h"

namespace {

struct SessionShim {
    lt::session session;
};

}  // namespace

extern "C" TORRENT_API void lt_set_proxy(lt_session_t session,
                                         const lt_proxy_config* config) {
    if (!session) return;
    auto* sw = reinterpret_cast<SessionShim*>(session);
    lt::settings_pack sp;

    if (!config || config->type == LT_PROXY_NONE || config->hostname[0] == '\0') {
        sp.set_int(lt::settings_pack::proxy_type, lt::settings_pack::none);
        sp.set_str(lt::settings_pack::proxy_hostname, "");
        sp.set_int(lt::settings_pack::proxy_port, 0);
        sp.set_str(lt::settings_pack::proxy_username, "");
        sp.set_str(lt::settings_pack::proxy_password, "");
    } else {
        int proxy_type = lt::settings_pack::none;
        switch (config->type) {
            case LT_PROXY_SOCKS4:    proxy_type = lt::settings_pack::socks4; break;
            case LT_PROXY_SOCKS5:    proxy_type = lt::settings_pack::socks5; break;
            case LT_PROXY_SOCKS5_PW: proxy_type = lt::settings_pack::socks5_pw; break;
            case LT_PROXY_HTTP:      proxy_type = lt::settings_pack::http; break;
            case LT_PROXY_HTTP_PW:   proxy_type = lt::settings_pack::http_pw; break;
            default: break;
        }
        sp.set_int(lt::settings_pack::proxy_type, proxy_type);
        sp.set_str(lt::settings_pack::proxy_hostname, config->hostname);
        sp.set_int(lt::settings_pack::proxy_port, config->port);
        sp.set_str(lt::settings_pack::proxy_username, config->username);
        sp.set_str(lt::settings_pack::proxy_password, config->password);
        const bool peers = config->proxy_peer_connections != 0;
        const bool trackers = config->proxy_tracker_connections != 0;
        const bool hostnames = config->proxy_hostnames != 0;
        sp.set_bool(lt::settings_pack::proxy_peer_connections, peers);
        sp.set_bool(lt::settings_pack::proxy_tracker_connections, trackers);
        sp.set_bool(lt::settings_pack::proxy_hostnames, hostnames);
        if (proxy_type == lt::settings_pack::socks5 ||
            proxy_type == lt::settings_pack::socks5_pw) {
            sp.set_bool(lt::settings_pack::proxy_peer_connections, true);
            sp.set_bool(lt::settings_pack::proxy_tracker_connections, true);
            sp.set_bool(lt::settings_pack::proxy_hostnames, true);
        }
        if (proxy_type == lt::settings_pack::http ||
            proxy_type == lt::settings_pack::http_pw) {
            sp.set_bool(lt::settings_pack::enable_dht, false);
            sp.set_bool(lt::settings_pack::enable_lsd, false);
            sp.set_bool(lt::settings_pack::enable_upnp, false);
            sp.set_bool(lt::settings_pack::enable_natpmp, false);
            sp.set_bool(lt::settings_pack::enable_outgoing_utp, false);
            sp.set_bool(lt::settings_pack::enable_incoming_utp, false);
        }
    }

    try {
        sw->session.apply_settings(sp);
    } catch (...) {
    }
}
