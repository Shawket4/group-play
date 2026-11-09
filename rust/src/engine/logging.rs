//! Logger: platform log (logcat / stderr) plus a ring the app can show and export.

use parking_lot::Mutex;
use std::collections::VecDeque;
use std::sync::OnceLock;

pub type LogListener = Box<dyn Fn(&str) + Send + Sync>;

struct Logger {
    lines: Mutex<VecDeque<String>>,
    listener: Mutex<Option<LogListener>>,
}

static LOGGER: OnceLock<Logger> = OnceLock::new();

impl log::Log for Logger {
    fn enabled(&self, m: &log::Metadata) -> bool {
        // our crate at info+, everything else (iroh internals) at warn+
        if m.target().starts_with("tutti_core") {
            m.level() <= log::Level::Info
        } else {
            m.level() <= log::Level::Warn
        }
    }

    fn log(&self, r: &log::Record) {
        if !self.enabled(r.metadata()) {
            return;
        }
        let line = format!("{:>5} {}", r.level(), r.args());
        platform_log(r.level(), &line);
        {
            let mut l = self.lines.lock();
            l.push_back(line.clone());
            while l.len() > 500 {
                l.pop_front();
            }
        }
        if let Some(f) = self.listener.lock().as_ref() {
            f(&line);
        }
    }

    fn flush(&self) {}
}

pub fn init() {
    let logger = LOGGER.get_or_init(|| Logger { lines: Mutex::new(VecDeque::new()), listener: Mutex::new(None) });
    if log::set_logger(logger).is_ok() {
        log::set_max_level(log::LevelFilter::Info);
    }
}

pub fn set_listener(f: Option<LogListener>) {
    if let Some(l) = LOGGER.get() {
        *l.listener.lock() = f;
    }
}

pub fn recent() -> Vec<String> {
    LOGGER.get().map(|l| l.lines.lock().iter().cloned().collect()).unwrap_or_default()
}

#[cfg(target_os = "android")]
fn platform_log(level: log::Level, line: &str) {
    use std::ffi::CString;
    #[link(name = "log")]
    extern "C" {
        fn __android_log_write(prio: i32, tag: *const std::os::raw::c_char, text: *const std::os::raw::c_char) -> i32;
    }
    let prio = match level {
        log::Level::Error => 6,
        log::Level::Warn => 5,
        log::Level::Info => 4,
        _ => 3,
    };
    let tag = CString::new("tutti").unwrap();
    if let Ok(text) = CString::new(line.replace('\0', " ")) {
        // SAFETY: both pointers are valid NUL-terminated strings for the duration of the call.
        unsafe {
            __android_log_write(prio, tag.as_ptr(), text.as_ptr());
        }
    }
}

#[cfg(not(target_os = "android"))]
fn platform_log(_level: log::Level, line: &str) {
    eprintln!("tutti: {line}");
}
