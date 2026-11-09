//! The Dart-facing surface. Everything real lives in `group_play_core`.

pub mod api;
mod frb_generated;

/// Android: hands the JavaVM and application context to Rust (iroh's DNS resolver and cpal
/// read them through `ndk_context`). Called once from `GroupPlayNative.install(context)` in
/// Kotlin before Dart starts.
#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_com_shawket_groupplay_GroupPlayNative_install(
    env: *mut jni_sys::JNIEnv,
    _class: jni_sys::jclass,
    context: jni_sys::jobject,
) {
    use std::ffi::c_void;
    use std::sync::Once;
    static ONCE: Once = Once::new();
    ONCE.call_once(|| unsafe {
        // SAFETY: called by the JVM with a valid env; the global ref is never freed, so the
        // context stays valid for the life of the process, as ndk_context requires.
        let fns = &**env;
        let mut vm: *mut jni_sys::JavaVM = std::ptr::null_mut();
        let get_vm = fns.v1_1.GetJavaVM;
        if get_vm(env, &mut vm) != 0 || vm.is_null() {
            return;
        }
        let global = (fns.v1_1.NewGlobalRef)(env, context);
        if global.is_null() {
            return;
        }
        ndk_context::initialize_android_context(vm as *mut c_void, global as *mut c_void);
    });
}
