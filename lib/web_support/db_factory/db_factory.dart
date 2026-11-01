// WEB: selezione della factory SQLite in base alla piattaforma.
//
// Su IO (Android/iOS/desktop/test) viene compilato db_factory_io.dart, che
// usa path_provider e sqflite_common_ffi. Sul web viene compilato
// db_factory_web.dart, che usa sqflite_common_ffi_web (Wasm + IndexedDB).
// Il conditional export evita che il compilatore web debba risolvere le
// librerie FFI native.
export 'db_factory_io.dart'
    if (dart.library.js_interop) 'db_factory_web.dart';
