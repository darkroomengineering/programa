use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;
use std::sync::Mutex;

use programa_domain::{Command, Core, DomainError, Snapshot, ABI_VERSION};
use serde::Serialize;

const STATUS_OK: i32 = 0;
const STATUS_ERROR: i32 = 1;

#[repr(C)]
#[derive(Default)]
pub struct ProgramaBuffer {
    pub data: *mut u8,
    pub len: usize,
    pub capacity: usize,
}

struct CoreHandle {
    core: Mutex<Core>,
}

#[derive(Serialize)]
struct DispatchSuccess<'a> {
    snapshot: &'a Snapshot,
}

#[derive(Serialize)]
struct ErrorResponse<'a> {
    error: ErrorBody<'a>,
}

#[derive(Serialize)]
struct ErrorBody<'a> {
    code: &'a str,
    message: &'a str,
}

#[no_mangle]
pub extern "C" fn programa_core_abi_version() -> u32 {
    catch_unwind(|| ABI_VERSION).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn programa_core_create() -> *mut std::ffi::c_void {
    catch_unwind(|| {
        Box::into_raw(Box::new(CoreHandle {
            core: Mutex::new(Core::default()),
        }))
        .cast()
    })
    .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
/// # Safety
///
/// The pointer must be null or a live handle returned by
/// programa_core_create, and no other call may use it after this call begins.
pub unsafe extern "C" fn programa_core_destroy(core: *mut std::ffi::c_void) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !core.is_null() {
            drop(Box::from_raw(core.cast::<CoreHandle>()));
        }
    }));
}

#[no_mangle]
/// # Safety
///
/// Core must be a live handle. Result must point to writable ProgramaBuffer
/// storage. Request must identify len readable bytes unless it is null with a
/// zero length.
pub unsafe extern "C" fn programa_core_dispatch(
    core: *mut std::ffi::c_void,
    request: *const u8,
    len: usize,
    result: *mut ProgramaBuffer,
) -> i32 {
    ffi_call(result, || {
        let handle = handle(core)?;
        let bytes = input_bytes(request, len)?;
        let command: Command = serde_json::from_slice(bytes)
            .map_err(|error| ApiError::owned("invalid_json", error.to_string()))?;
        let mut core = handle
            .core
            .lock()
            .map_err(|_| ApiError::borrowed("internal_error", "core lock is poisoned"))?;
        let snapshot = core.dispatch(command).map_err(ApiError::from)?;
        serialize(&DispatchSuccess { snapshot })
    })
}

#[no_mangle]
/// # Safety
///
/// Core must be a live handle and result must point to writable
/// ProgramaBuffer storage.
pub unsafe extern "C" fn programa_core_snapshot(
    core: *mut std::ffi::c_void,
    result: *mut ProgramaBuffer,
) -> i32 {
    ffi_call(result, || {
        let handle = handle(core)?;
        let core = handle
            .core
            .lock()
            .map_err(|_| ApiError::borrowed("internal_error", "core lock is poisoned"))?;
        serialize(core.snapshot())
    })
}

#[no_mangle]
/// # Safety
///
/// Buffer must be either zero-initialized or the exact, not-yet-freed value
/// returned by programa_core_dispatch or programa_core_snapshot.
pub unsafe extern "C" fn programa_core_buffer_free(buffer: ProgramaBuffer) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !buffer.data.is_null() && buffer.len <= buffer.capacity {
            drop(Vec::from_raw_parts(
                buffer.data,
                buffer.len,
                buffer.capacity,
            ));
        }
    }));
}

unsafe fn ffi_call(
    result: *mut ProgramaBuffer,
    operation: impl FnOnce() -> Result<Vec<u8>, ApiError>,
) -> i32 {
    if result.is_null() {
        return STATUS_ERROR;
    }
    result.write(ProgramaBuffer::default());
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(bytes)) => {
            result.write(into_buffer(bytes));
            STATUS_OK
        }
        Ok(Err(error)) => {
            result.write(into_buffer(error_json(&error)));
            STATUS_ERROR
        }
        Err(_) => {
            result.write(into_buffer(error_json(&ApiError::borrowed(
                "panic",
                "internal panic was contained at the ABI boundary",
            ))));
            STATUS_ERROR
        }
    }
}

unsafe fn handle<'a>(core: *mut std::ffi::c_void) -> Result<&'a CoreHandle, ApiError> {
    core.cast::<CoreHandle>()
        .as_ref()
        .ok_or_else(|| ApiError::borrowed("invalid_argument", "core handle must not be null"))
}

unsafe fn input_bytes<'a>(request: *const u8, len: usize) -> Result<&'a [u8], ApiError> {
    if request.is_null() {
        if len == 0 {
            return Ok(&[]);
        }
        return Err(ApiError::borrowed(
            "invalid_argument",
            "request must not be null when len is nonzero",
        ));
    }
    Ok(slice::from_raw_parts(request, len))
}

fn serialize(value: &impl Serialize) -> Result<Vec<u8>, ApiError> {
    serde_json::to_vec(value)
        .map_err(|error| ApiError::owned("serialization_error", error.to_string()))
}

fn into_buffer(mut bytes: Vec<u8>) -> ProgramaBuffer {
    let buffer = ProgramaBuffer {
        data: bytes.as_mut_ptr(),
        len: bytes.len(),
        capacity: bytes.capacity(),
    };
    std::mem::forget(bytes);
    buffer
}

fn error_json(error: &ApiError) -> Vec<u8> {
    serde_json::to_vec(&ErrorResponse {
        error: ErrorBody {
            code: &error.code,
            message: &error.message,
        },
    })
    .unwrap_or_else(|_| {
        br#"{"error":{"code":"serialization_error","message":"failed to serialize error"}}"#
            .to_vec()
    })
}

struct ApiError {
    code: String,
    message: String,
}

impl ApiError {
    fn borrowed(code: &str, message: &str) -> Self {
        Self::owned(code, message)
    }

    fn owned(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
}

impl From<DomainError> for ApiError {
    fn from(error: DomainError) -> Self {
        Self::owned(error.code(), error.message())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    unsafe fn take_buffer(buffer: ProgramaBuffer) -> Vec<u8> {
        Vec::from_raw_parts(buffer.data, buffer.len, buffer.capacity)
    }

    #[test]
    fn ffi_dispatch_returns_owned_snapshot_and_structured_error() {
        unsafe {
            let core = programa_core_create();
            let request = br#"{"command":"create_workspace","workspace_id":"w","pane_id":"p","surface_id":"s","session_id":"session"}"#;
            let mut output = ProgramaBuffer::default();
            assert_eq!(
                programa_core_dispatch(core, request.as_ptr(), request.len(), &mut output),
                STATUS_OK
            );
            let json: serde_json::Value = serde_json::from_slice(&take_buffer(output)).unwrap();
            assert_eq!(json["snapshot"]["revision"], 1);
            assert_eq!(
                json["snapshot"]["workspaces"][0]["panes"][0]["surfaces"][0]["is_pinned"],
                false
            );

            let mut error = ProgramaBuffer::default();
            assert_eq!(
                programa_core_dispatch(core, std::ptr::null(), 4, &mut error),
                STATUS_ERROR
            );
            let json: serde_json::Value = serde_json::from_slice(&take_buffer(error)).unwrap();
            assert_eq!(json["error"]["code"], "invalid_argument");
            programa_core_destroy(core);
        }
    }
}
