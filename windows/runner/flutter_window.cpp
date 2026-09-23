#include "flutter_window.h"

#include <optional>
#include <string>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Riusa lo stesso canale già esistente lato Linux ("io.github.scripta/window")
  // invece di crearne uno nuovo, così window_decoration_service.dart resta
  // identico su entrambe le piattaforme desktop.
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "io.github.scripta/window",
          &flutter::StandardMethodCodec::GetInstance());

  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleWindowMethodCall(call, std::move(result)); });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::HandleWindowMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());

  if (method == "setFullScreen") {
    bool fullscreen = false;
    if (args != nullptr) {
      auto it = args->find(flutter::EncodableValue("fullscreen"));
      if (it != args->end()) {
        if (const bool* value = std::get_if<bool>(&it->second)) {
          fullscreen = *value;
        }
      }
    }
    SetFullScreen(fullscreen);
    result->Success();
  } else if (method == "updateTitleBarTheme") {
    // Default coerenti con quelli usati in my_application.cc lato Linux, nel
    // caso arrivasse una mappa incompleta.
    std::string bg_hex = "#16191d";
    std::string text_hex = "#f1f5f9";
    bool is_dark = true;

    if (args != nullptr) {
      auto bg_it = args->find(flutter::EncodableValue("backgroundColor"));
      if (bg_it != args->end()) {
        if (const std::string* value = std::get_if<std::string>(&bg_it->second)) {
          bg_hex = *value;
        }
      }
      auto text_it = args->find(flutter::EncodableValue("textColor"));
      if (text_it != args->end()) {
        if (const std::string* value = std::get_if<std::string>(&text_it->second)) {
          text_hex = *value;
        }
      }
      auto dark_it = args->find(flutter::EncodableValue("isDark"));
      if (dark_it != args->end()) {
        if (const bool* value = std::get_if<bool>(&dark_it->second)) {
          is_dark = *value;
        }
      }
    }

    SetTitleBarTheme(bg_hex, text_hex, is_dark);
    result->Success();
  } else {
    result->NotImplemented();
  }
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
