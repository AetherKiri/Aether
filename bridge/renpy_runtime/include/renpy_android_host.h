#pragma once

#include <jni.h>
#include <string>

namespace aetherkiri::renpy::mobile {

// Private Android handoff. Neither JNI references nor callback tables travel
// through the public provider's reserved media/shader extension slots.
class AndroidLocalReference final {
 public:
  AndroidLocalReference(JNIEnv* env, jobject value) : env_(env), value_(value) {}
  ~AndroidLocalReference() { if (value_) env_->DeleteLocalRef(value_); }
  AndroidLocalReference(const AndroidLocalReference&) = delete;
  AndroidLocalReference& operator=(const AndroidLocalReference&) = delete;
  jobject get() const { return value_; }
 private:
  JNIEnv* env_;
  jobject value_;
};

inline bool AndroidHostException(JNIEnv* env, std::string* error) {
  if (!env->ExceptionCheck()) return false;
  AndroidLocalReference exception(env, env->ExceptionOccurred());
  env->ExceptionClear();
  if (exception.get()) {
    AndroidLocalReference klass(env, env->GetObjectClass(exception.get()));
    if (!env->ExceptionCheck() && klass.get()) {
      const auto describe = env->GetMethodID(static_cast<jclass>(klass.get()),
                                           "toString", "()Ljava/lang/String;");
      if (!env->ExceptionCheck() && describe) {
        AndroidLocalReference detail(env, env->CallObjectMethod(exception.get(), describe));
        if (!env->ExceptionCheck() && detail.get()) {
          const char* utf8 = env->GetStringUTFChars(static_cast<jstring>(detail.get()), nullptr);
          if (utf8) {
            *error += ": ";
            *error += utf8;
            env->ReleaseStringUTFChars(static_cast<jstring>(detail.get()), utf8);
          }
        }
      }
    }
  }
  if (env->ExceptionCheck()) env->ExceptionClear();
  return true;
}

inline bool RequireAndroidHostActivity(JNIEnv* env, jobject activity,
                                       std::string* error) {
  if (!activity) {
    *error = "Ren'Py requires the existing Godot Activity";
    return false;
  }
  AndroidLocalReference klass(env, env->FindClass("android/app/Activity"));
  *error = "Ren'Py could not validate the existing Godot Activity";
  if (AndroidHostException(env, error) || !klass.get()) return false;
  const bool valid = env->IsInstanceOf(activity, static_cast<jclass>(klass.get()));
  if (AndroidHostException(env, error)) return false;
  if (!valid) {
    *error = "Ren'Py host must be an android.app.Activity";
    return false;
  }
  return true;
}

using AndroidActivityResolver = jobject (*)(JNIEnv*); // Returns an owned local reference.
using AndroidClassResolver = jclass (*)(JNIEnv*, const char*); // App class loader; owned local ref.

inline bool BindRenPyAndroidHost(JNIEnv* env, AndroidActivityResolver resolve_activity,
                                AndroidClassResolver resolve_class, std::string* error) {
  if (!env) {
    *error = "Ren'Py could not attach to the Android VM";
    return false;
  }
  AndroidLocalReference activity(env, resolve_activity(env));
  *error = "Ren'Py could not obtain the existing Godot Activity";
  if (AndroidHostException(env, error) ||
      !RequireAndroidHostActivity(env, activity.get(), error)) return false;
  AndroidLocalReference bridge(env, resolve_class(env,
      "org/github/krkr2/aetherkiri/RenPyMobileBridge"));
  *error = "Ren'Py Android host bridge is missing from the APK";
  if (AndroidHostException(env, error) || !bridge.get()) return false;
  const auto bind = env->GetStaticMethodID(static_cast<jclass>(bridge.get()),
      "bindHostActivity", "(Landroid/app/Activity;)V");
  *error = "Ren'Py Android host bridge lacks bindHostActivity(Activity)";
  if (AndroidHostException(env, error) || !bind) return false;
  env->CallStaticVoidMethod(static_cast<jclass>(bridge.get()), bind, activity.get());
  *error = "Ren'Py could not bind the existing Godot Activity";
  if (AndroidHostException(env, error)) return false;
  error->clear();
  return true;
}

inline bool PrepareRenPyAndroidHost(bool (*load_bridge)(std::string*),
                                    JNIEnv* (*resolve_env)(),
                                    AndroidActivityResolver resolve_activity,
                                    AndroidClassResolver resolve_class,
                                    std::string* error) {
  // load_bridge uses Godot's own Java environment. Do not ask engine_api for
  // its cached JavaVM until the real Java load has called JNI_OnLoad.
  if (!load_bridge(error)) return false;
  return BindRenPyAndroidHost(resolve_env(), resolve_activity, resolve_class, error);
}

} // namespace aetherkiri::renpy::mobile
