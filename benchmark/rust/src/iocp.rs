//! Windows raw Win32 IOCP engine rows.
//!
//! One measured body = `QD` (32) independent 4 KiB random reads/writes submitted
//! through overlapped `ReadFile`/`WriteFile` on an I/O completion port, then
//! harvested with `GetQueuedCompletionStatus`. Mirrors the Dart `IocpFile` engine
//! (and its copy semantics): one big native buffer for the whole batch, copying
//! the batch in/out of the Dart-side buffer once per body.
//!
//! Emitted rows (throughput is bodies/sec, benchcat multiplies by 32):
//!   iocp.read.random4K.qd32
//!   iocp.write.random4K.qd32

use std::hint::black_box;
use std::io;
use std::path::Path;
use std::ptr;

use windows::core::{Error as WinError, HSTRING};
use windows::Win32::Foundation::{
    CloseHandle, GENERIC_READ, GENERIC_WRITE, HANDLE, INVALID_HANDLE_VALUE,
};
use windows::Win32::Storage::FileSystem::{
    CreateFileW, ReadFile, WriteFile, FILE_ATTRIBUTE_NORMAL, FILE_FLAG_OVERLAPPED, FILE_SHARE_READ,
    FILE_SHARE_WRITE, OPEN_ALWAYS,
};
use windows::Win32::System::IO::{CreateIoCompletionPort, GetQueuedCompletionStatus, OVERLAPPED};

use crate::{emit, fill_pattern, measure, Rng, Row, BLOCK, ENGINE_BODIES, ENGINE_WARMUP, QD};

/// `HRESULT_FROM_WIN32(ERROR_IO_PENDING)`.
const HRESULT_ERROR_IO_PENDING: u32 = 0x8007_03E5;

fn win_err(err: WinError) -> io::Error {
    io::Error::other(format!("Win32 error: {err}"))
}

struct IocpFile {
    handle: HANDLE,
    iocp: HANDLE,
}

impl Drop for IocpFile {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.handle);
            let _ = CloseHandle(self.iocp);
        }
    }
}

fn open(path: &Path) -> io::Result<IocpFile> {
    let wide = HSTRING::from(path.to_string_lossy().as_ref());
    let handle = unsafe {
        CreateFileW(
            &wide,
            (GENERIC_READ | GENERIC_WRITE).0,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            None,
            OPEN_ALWAYS,
            FILE_FLAG_OVERLAPPED | FILE_ATTRIBUTE_NORMAL,
            None,
        )
    }
    .map_err(win_err)?;

    let iocp =
        unsafe { CreateIoCompletionPort(INVALID_HANDLE_VALUE, None, 0, 0) }.map_err(win_err)?;
    unsafe { CreateIoCompletionPort(handle, Some(iocp), 0, 0) }.map_err(win_err)?;

    Ok(IocpFile { handle, iocp })
}

fn set_offset(overlapped: &mut OVERLAPPED, offset: u64) {
    overlapped.Anonymous.Anonymous.Offset = offset as u32;
    overlapped.Anonymous.Anonymous.OffsetHigh = (offset >> 32) as u32;
}

/// Blocks until `want` completion packets arrive; validates every transfer size.
fn wait_batch(file: &IocpFile, want: usize) -> io::Result<()> {
    let mut done = 0;
    while done < want {
        let mut transferred: u32 = 0;
        let mut key: usize = 0;
        let mut overlapped: *mut OVERLAPPED = ptr::null_mut();
        unsafe {
            GetQueuedCompletionStatus(
                file.iocp,
                &mut transferred,
                &mut key,
                &mut overlapped,
                u32::MAX,
            )
        }
        .map_err(win_err)?;
        if overlapped.is_null() {
            return Err(io::Error::other("IOCP returned a null OVERLAPPED"));
        }
        if transferred as usize != BLOCK {
            return Err(io::Error::other(format!(
                "IOCP short transfer: {transferred} bytes"
            )));
        }
        done += 1;
    }
    Ok(())
}

fn read_body(
    file: &IocpFile,
    rng: &mut Rng,
    offsets: &mut [u64; QD],
    overlapped: &mut [OVERLAPPED],
    buf: &mut [u8],
    out: &mut [u8],
) -> io::Result<()> {
    for offset in offsets.iter_mut() {
        *offset = rng.offset();
    }
    for i in 0..QD {
        let mut ov = OVERLAPPED::default();
        set_offset(&mut ov, offsets[i]);
        overlapped[i] = ov;
        let dst = &mut buf[i * BLOCK..(i + 1) * BLOCK];
        match unsafe { ReadFile(file.handle, Some(dst), None, Some(&mut overlapped[i])) } {
            Ok(()) => {}
            Err(err) if err.code().0 as u32 == HRESULT_ERROR_IO_PENDING => {}
            Err(err) => return Err(win_err(err)),
        }
    }
    wait_batch(file, QD)?;
    out.copy_from_slice(buf);
    black_box(out[0]);
    Ok(())
}

fn write_body(
    file: &IocpFile,
    rng: &mut Rng,
    offsets: &mut [u64; QD],
    overlapped: &mut [OVERLAPPED],
    src: &[u8],
    scratch: &mut [u8],
) -> io::Result<()> {
    scratch.copy_from_slice(src);
    for offset in offsets.iter_mut() {
        *offset = rng.offset();
    }
    for i in 0..QD {
        let mut ov = OVERLAPPED::default();
        set_offset(&mut ov, offsets[i]);
        overlapped[i] = ov;
        let data = &scratch[i * BLOCK..(i + 1) * BLOCK];
        match unsafe { WriteFile(file.handle, Some(data), None, Some(&mut overlapped[i])) } {
            Ok(()) => {}
            Err(err) if err.code().0 as u32 == HRESULT_ERROR_IO_PENDING => {}
            Err(err) => return Err(win_err(err)),
        }
    }
    wait_batch(file, QD)?;
    black_box(scratch[0]);
    Ok(())
}

pub(crate) fn run(path: &Path) -> io::Result<()> {
    let file = open(path)?;
    let mut rng = Rng::new();
    let mut offsets = [0u64; QD];
    let mut overlapped: Vec<OVERLAPPED> = (0..QD).map(|_| OVERLAPPED::default()).collect();
    let mut read_buf = vec![0u8; QD * BLOCK];
    let mut read_out = vec![0u8; QD * BLOCK];
    let mut write_src = vec![0u8; QD * BLOCK];
    fill_pattern(&mut write_src, 13, 7);
    let mut write_scratch = vec![0u8; QD * BLOCK];

    for _ in 0..ENGINE_WARMUP {
        read_body(
            &file,
            &mut rng,
            &mut offsets,
            &mut overlapped,
            &mut read_buf,
            &mut read_out,
        )?;
    }
    let (ops, lat) = measure(ENGINE_BODIES, || {
        read_body(
            &file,
            &mut rng,
            &mut offsets,
            &mut overlapped,
            &mut read_buf,
            &mut read_out,
        )
        .unwrap();
    });
    emit(Row {
        name: "iocp.read.random4K.qd32",
        ops_per_second: ops,
        samples: ENGINE_BODIES,
        mean_latency_us: lat,
    });

    for _ in 0..ENGINE_WARMUP {
        write_body(
            &file,
            &mut rng,
            &mut offsets,
            &mut overlapped,
            &write_src,
            &mut write_scratch,
        )?;
    }
    let (ops, lat) = measure(ENGINE_BODIES, || {
        write_body(
            &file,
            &mut rng,
            &mut offsets,
            &mut overlapped,
            &write_src,
            &mut write_scratch,
        )
        .unwrap();
    });
    emit(Row {
        name: "iocp.write.random4K.qd32",
        ops_per_second: ops,
        samples: ENGINE_BODIES,
        mean_latency_us: lat,
    });

    Ok(())
}
