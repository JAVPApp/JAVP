//! Embedded librqbit session + loopback HTTP API for JAVP.
//!
//! Dart loads this cdylib, calls [rqbit_engine_start], then talks HTTP to
//! `http://127.0.0.1:<port>/`.

use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;
use std::sync::Mutex;
use std::thread;
use std::time::Duration;

use anyhow::Context;
use librqbit::dht::PersistentDhtConfig;
use librqbit::http_api::{HttpApi, HttpApiOptions};
use librqbit::{Api, Session, SessionOptions};
use tokio::net::TcpListener;
use tokio_util::sync::CancellationToken;

struct Running {
    port: u16,
    save_path: PathBuf,
    socks: Option<String>,
    cancel: CancellationToken,
    join: Option<thread::JoinHandle<()>>,
}

static LAST_ERROR: Mutex<Option<CString>> = Mutex::new(None);
static ENGINE: Mutex<Option<Running>> = Mutex::new(None);

fn set_error(msg: impl ToString) {
    let text = msg.to_string();
    *LAST_ERROR.lock().unwrap_or_else(|e| e.into_inner()) = CString::new(text).ok();
}

fn cstr(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .ok()
        .map(|s| s.to_string())
        .filter(|s| !s.is_empty())
}

/// Last UTF-8 error from a failed FFI call. Pointer is valid until the next
/// error or process exit; may be null.
#[no_mangle]
pub extern "C" fn rqbit_engine_last_error() -> *const c_char {
    match LAST_ERROR.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
        Some(s) => s.as_ptr(),
        None => std::ptr::null(),
    }
}

/// Start (or reuse) the session. Returns the loopback HTTP port, or `-1`.
///
/// `socks_url` may be null. Format: `socks5://[user:pass@]host:port`.
#[no_mangle]
pub extern "C" fn rqbit_engine_start(
    save_path: *const c_char,
    socks_url: *const c_char,
) -> i32 {
    let Some(path) = cstr(save_path) else {
        set_error("save_path is required");
        return -1;
    };
    let socks = cstr(socks_url);
    let save = PathBuf::from(&path);

    {
        let eng = ENGINE.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(running) = eng.as_ref() {
            if running.save_path == save && running.socks == socks {
                return i32::from(running.port);
            }
        }
    }

    // Start the replacement first. A failed restart must leave the previous
    // session running so Dart's RqbitEngine instance stays usable.
    match start_inner(save, socks) {
        Ok(new) => {
            let port = new.port;
            let old = ENGINE
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .replace(new);
            if let Some(old) = old {
                stop_running(old);
            }
            i32::from(port)
        }
        Err(err) => {
            set_error(format!("{err:#}"));
            -1
        }
    }
}

/// Bound loopback port, or `0` if the engine is not running.
#[no_mangle]
pub extern "C" fn rqbit_engine_port() -> i32 {
    ENGINE
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
        .map(|r| i32::from(r.port))
        .unwrap_or(0)
}

/// Restart the session with a new SOCKS URL (null / empty disables the proxy).
/// Returns the (possibly new) port, or `-1`.
#[no_mangle]
pub extern "C" fn rqbit_engine_set_socks_proxy(socks_url: *const c_char) -> i32 {
    let socks = cstr(socks_url);
    let save = {
        let eng = ENGINE.lock().unwrap_or_else(|e| e.into_inner());
        match eng.as_ref() {
            Some(running) if running.socks == socks => return i32::from(running.port),
            Some(running) => running.save_path.clone(),
            None => {
                set_error("engine not started");
                return -1;
            }
        }
    };
    let path = match CString::new(save.to_string_lossy().as_bytes()) {
        Ok(p) => p,
        Err(err) => {
            set_error(err);
            return -1;
        }
    };
    let socks_c = match socks.as_ref() {
        Some(s) => match CString::new(s.as_str()) {
            Ok(c) => Some(c),
            Err(err) => {
                set_error(err);
                return -1;
            }
        },
        None => None,
    };
    rqbit_engine_start(
        path.as_ptr(),
        socks_c
            .as_ref()
            .map(|s| s.as_ptr())
            .unwrap_or(std::ptr::null()),
    )
}

/// Stop the session and HTTP API. Safe to call when not running.
#[no_mangle]
pub extern "C" fn rqbit_engine_stop() {
    let running = ENGINE.lock().unwrap_or_else(|e| e.into_inner()).take();
    if let Some(running) = running {
        stop_running(running);
    }
}

fn stop_running(running: Running) {
    running.cancel.cancel();
    if let Some(join) = running.join {
        let _ = join.join();
    }
}

fn start_inner(save_path: PathBuf, socks: Option<String>) -> anyhow::Result<Running> {
    let (tx, rx) = std::sync::mpsc::channel();
    let cancel = CancellationToken::new();
    let cancel_thread = cancel.clone();
    let save_thread = save_path.clone();
    let socks_thread = socks.clone();

    let join = thread::Builder::new()
        .name("rqbit-engine".into())
        .spawn(move || {
            let runtime = match tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .thread_name("rqbit-worker")
                .build()
            {
                Ok(rt) => rt,
                Err(err) => {
                    let _ = tx.send(Err(anyhow::Error::from(err)));
                    return;
                }
            };
            runtime.block_on(async move {
                if let Err(err) =
                    run_server(save_thread, socks_thread, cancel_thread, &tx).await
                {
                    let _ = tx.send(Err(err));
                }
            });
        })
        .context("failed to spawn rqbit thread")?;

    let port = match rx.recv_timeout(Duration::from_secs(45)) {
        Ok(Ok(port)) => port,
        Ok(Err(err)) => {
            cancel.cancel();
            let _ = join.join();
            return Err(err);
        }
        Err(err) => {
            cancel.cancel();
            let _ = join.join();
            return Err(anyhow::Error::from(err).context("rqbit engine did not become ready"));
        }
    };

    Ok(Running {
        port,
        save_path,
        socks,
        cancel,
        join: Some(join),
    })
}

async fn run_server(
    save_path: PathBuf,
    socks: Option<String>,
    cancel: CancellationToken,
    ready: &std::sync::mpsc::Sender<anyhow::Result<u16>>,
) -> anyhow::Result<()> {
    std::fs::create_dir_all(&save_path)
        .with_context(|| format!("create save path {}", save_path.display()))?;

    // librqbit defaults to ProjectDirs("com", "rqbit", "dht"), which returns
    // None on Android and other hosts without a standard home/appdata dir.
    let dht_file = save_path.join("dht.json");
    let session = Session::new_with_opts(
        save_path,
        SessionOptions {
            socks_proxy_url: socks,
            cancellation_token: Some(cancel.clone()),
            enable_upnp_port_forwarding: false,
            dht_config: Some(PersistentDhtConfig {
                config_filename: Some(dht_file),
                ..Default::default()
            }),
            ..Default::default()
        },
    )
    .await
    .context("librqbit session")?;

    let api = Api::new(session.clone(), None, None);
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .context("bind 127.0.0.1:0")?;
    let port = listener.local_addr()?.port();
    let _ = ready.send(Ok(port));

    let http = HttpApi::new(api, Some(HttpApiOptions::default()))
        .make_http_api_and_run(listener, None);

    tokio::select! {
        _ = cancel.cancelled() => {
            session.stop().await;
            Ok(())
        }
        result = http => result,
    }
}
