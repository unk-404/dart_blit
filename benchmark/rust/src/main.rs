//! Rust counterpart of `benchmark/c/blit_bench.c`.
//!
//! Emits benchmark_test-compatible JSONL (same `name` keys as the C harness) for
//! the six shared operations on a 1 GiB file:
//!
//!   file.read.8MiB       file.write.8MiB
//!   file.read.random4K   file.write.random4K
//!   mmap.read.random4K   mmap.write.random4K
//!
//! Feature-gated engine rows (same JSONL schema, `compiler":"rust"`):
//!
//!   --features iocp   (Windows) iocp.read.random4K.qd32 / iocp.write.random4K.qd32
//!   --features uring  (Linux)   uring.read.random4K.qd32 / uring.write.random4K.qd32
//!
//! One IOCP/uring measured body is a batch of 32 independent 4 KiB operations, so
//! the emitted `throughput.value` is bodies/sec; benchcat's rows multiply it by 32
//! to get IOPS (see `iocp.*` rows in benchcat.toml). The six shared rows have one
//! operation per body, so bodies/sec == ops/sec there.
//!
//! The measured bodies mirror the C harness (which mirrors the Dart engine):
//! syscall into a native scratch buffer, then copy to the destination buffer
//! (and the reverse for writes). Keep this in sync with the C file so the
//! Rust/C/Dart chart stays apples-to-apples.
//!
//! Build / run:
//!
//!   cargo run --release --features iocp     # Windows, 8 rows
//!   cargo run --release --features uring    # Linux, 8 rows
//!   cargo run --release                     # 6 common rows, any OS
//!
//! CLI:
//!
//!   bytes-bench-rust [PATH] [--file PATH] [--keep] [--help]
//!
//! PATH defaults to `bench-rust.bin` in the current directory. The file is
//! created/seeded (1 GiB) if missing or the wrong size, and is left in place for
//! repeated runs (`*.bin` is gitignored).

use std::env;
use std::fs::{File, OpenOptions};
use std::hint::black_box;
use std::io;
use std::path::{Path, PathBuf};
use std::time::Instant;

use memmap2::{Mmap, MmapMut, MmapOptions};

#[cfg(all(feature = "iocp", target_os = "windows"))]
mod iocp;
#[cfg(all(feature = "uring", target_os = "linux"))]
mod uring;

#[cfg(unix)]
use std::os::unix::fs::FileExt;
#[cfg(windows)]
use std::os::windows::fs::FileExt as _;

pub(crate) const FILE_SIZE: u64 = 1 << 30;
pub(crate) const BLOCK: usize = 4096;
const SEQ_BLOCK: usize = 8 << 20;
const SEQ_OPS: u64 = 128;
const RANDOM_OPS: u64 = 50_000;
const MMAP_OPS: u64 = 200_000;

/// Queue depth for the IOCP / io_uring rows (one body = QD ops).
#[allow(dead_code)] // only read by the feature-gated engine modules
pub(crate) const QD: usize = 32;
/// Measured bodies for the IOCP / io_uring rows.
#[allow(dead_code)] // only read by the feature-gated engine modules
pub(crate) const ENGINE_BODIES: u64 = 2_000;
/// Untimed warm-up bodies for the IOCP / io_uring rows.
#[allow(dead_code)] // only read by the feature-gated engine modules
pub(crate) const ENGINE_WARMUP: u64 = 100;

/// Fixed xorshift64, same constants as the C harness.
pub(crate) struct Rng(u64);

impl Rng {
    pub(crate) fn new() -> Self {
        Rng(0x9E37_79B9_7F4A_7C15)
    }

    pub(crate) fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }

    /// Uniform 4 KiB-aligned offset in `[0, FILE_SIZE - BLOCK)`.
    pub(crate) fn offset(&mut self) -> u64 {
        let slots = (FILE_SIZE - BLOCK as u64) / BLOCK as u64;
        (self.next_u64() % slots) * BLOCK as u64
    }
}

pub(crate) struct Row {
    pub(crate) name: &'static str,
    pub(crate) ops_per_second: f64,
    pub(crate) samples: u64,
    pub(crate) mean_latency_us: f64,
}

/// Emits exactly the `BenchmarkResult.toJson()` shape used by benchmark_test.
pub(crate) fn emit(row: Row) {
    println!(
        "{{\"formatVersion\":1,\"name\":\"{}\",\"compiler\":\"rust\",\
         \"throughput\":{{\"value\":{:.6},\"unit\":\"ops/sec\"}},\
         \"statistics\":{{\"relativeMarginOfError\":0.0,\"samples\":{}}},\
         \"latency\":{{\"mean\":{:.3},\"unit\":\"microseconds\"}}}}",
        row.name, row.ops_per_second, row.samples, row.mean_latency_us
    );
}

/// Times `body` `samples` times and returns (ops/sec, mean latency in µs).
pub(crate) fn measure<F: FnMut()>(samples: u64, mut body: F) -> (f64, f64) {
    let start = Instant::now();
    for _ in 0..samples {
        body();
    }
    let secs = start.elapsed().as_secs_f64();
    (samples as f64 / secs, secs * 1e6 / samples as f64)
}

#[cfg(windows)]
fn pread(file: &File, buf: &mut [u8], offset: u64) -> io::Result<usize> {
    file.seek_read(buf, offset)
}

#[cfg(unix)]
fn pread(file: &File, buf: &mut [u8], offset: u64) -> io::Result<usize> {
    file.read_at(buf, offset)
}

#[cfg(windows)]
fn pwrite(file: &File, buf: &[u8], offset: u64) -> io::Result<usize> {
    file.seek_write(buf, offset)
}

#[cfg(unix)]
fn pwrite(file: &File, buf: &[u8], offset: u64) -> io::Result<usize> {
    file.write_at(buf, offset)
}

fn read_exact_at(file: &File, buf: &mut [u8], offset: u64) -> io::Result<()> {
    let mut done = 0;
    while done < buf.len() {
        let n = pread(file, &mut buf[done..], offset + done as u64)?;
        if n == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "short pread at end of file",
            ));
        }
        done += n;
    }
    Ok(())
}

fn write_all_at(file: &File, buf: &[u8], offset: u64) -> io::Result<()> {
    let mut done = 0;
    while done < buf.len() {
        let n = pwrite(file, &buf[done..], offset + done as u64)?;
        if n == 0 {
            return Err(io::Error::new(io::ErrorKind::WriteZero, "short pwrite"));
        }
        done += n;
    }
    Ok(())
}

pub(crate) fn fill_pattern(buf: &mut [u8], mul: usize, add: usize) {
    for (i, b) in buf.iter_mut().enumerate() {
        *b = ((i * mul + add) & 0xFF) as u8;
    }
}

/// Creates/truncates `path` to 1 GiB and seeds it with the 8 MiB sequential
/// pattern when the size is wrong, exactly like the C harness.
fn ensure_file(path: &Path) -> io::Result<File> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)?;
        }
    }
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .open(path)?;
    if file.metadata()?.len() == FILE_SIZE {
        return Ok(file);
    }
    eprintln!(
        "seeding {} ({} GiB, pattern 8 MiB)...",
        path.display(),
        FILE_SIZE >> 30
    );
    file.set_len(FILE_SIZE)?;
    let mut seq = vec![0u8; SEQ_BLOCK];
    fill_pattern(&mut seq, 31, 7);
    let mut off = 0u64;
    while off < FILE_SIZE {
        write_all_at(&file, &seq, off)?;
        off += SEQ_BLOCK as u64;
    }
    file.sync_all()?;
    Ok(file)
}

fn common(file: &File) -> io::Result<()> {
    let mut rng = Rng::new();
    let mut scratch_seq = vec![0u8; SEQ_BLOCK];
    let mut seq = vec![0u8; SEQ_BLOCK];
    fill_pattern(&mut seq, 31, 7);
    let mut block = vec![0u8; BLOCK];
    fill_pattern(&mut block, 17, 3);
    let mut scratch = vec![0u8; BLOCK];

    // Warm the read path once, like the C harness.
    read_exact_at(file, &mut scratch, 0)?;

    // ---------------------------------------------------------- file.read.8MiB
    let mut offset = 0u64;
    let (ops, lat) = measure(SEQ_OPS, || {
        read_exact_at(file, &mut scratch_seq, offset).unwrap();
        seq.copy_from_slice(&scratch_seq);
        black_box(seq[0]);
        offset = (offset + SEQ_BLOCK as u64) % FILE_SIZE;
    });
    emit(Row {
        name: "file.read.8MiB",
        ops_per_second: ops,
        samples: SEQ_OPS,
        mean_latency_us: lat,
    });

    // --------------------------------------------------------- file.write.8MiB
    let mut offset = 0u64;
    let (ops, lat) = measure(SEQ_OPS, || {
        scratch_seq.copy_from_slice(&seq);
        write_all_at(file, &scratch_seq, offset).unwrap();
        black_box(scratch_seq[0]);
        offset = (offset + SEQ_BLOCK as u64) % FILE_SIZE;
    });
    emit(Row {
        name: "file.write.8MiB",
        ops_per_second: ops,
        samples: SEQ_OPS,
        mean_latency_us: lat,
    });

    // ----------------------------------------------------- file.read.random4K
    let (ops, lat) = measure(RANDOM_OPS, || {
        let off = rng.offset();
        read_exact_at(file, &mut scratch, off).unwrap();
        block.copy_from_slice(&scratch);
        black_box(block[0]);
    });
    emit(Row {
        name: "file.read.random4K",
        ops_per_second: ops,
        samples: RANDOM_OPS,
        mean_latency_us: lat,
    });

    // ---------------------------------------------------- file.write.random4K
    let (ops, lat) = measure(RANDOM_OPS, || {
        let off = rng.offset();
        scratch.copy_from_slice(&block);
        write_all_at(file, &scratch, off).unwrap();
        black_box(scratch[0]);
    });
    emit(Row {
        name: "file.write.random4K",
        ops_per_second: ops,
        samples: RANDOM_OPS,
        mean_latency_us: lat,
    });

    // ----------------------------------------------------- mmap.read.random4K
    {
        let map: Mmap = unsafe { MmapOptions::new().len(FILE_SIZE as usize).map(file)? };
        let mut out = vec![0u8; BLOCK];
        for _ in 0..1000 {
            let off = rng.offset() as usize;
            out.copy_from_slice(&map[off..off + BLOCK]);
        }
        black_box(out[0]);
        let (ops, lat) = measure(MMAP_OPS, || {
            let off = rng.offset() as usize;
            out.copy_from_slice(&map[off..off + BLOCK]);
            black_box(out[0]);
        });
        emit(Row {
            name: "mmap.read.random4K",
            ops_per_second: ops,
            samples: MMAP_OPS,
            mean_latency_us: lat,
        });
    }

    // ---------------------------------------------------- mmap.write.random4K
    {
        let mut map: MmapMut = unsafe { MmapOptions::new().len(FILE_SIZE as usize).map_mut(file)? };
        for _ in 0..1000 {
            let off = rng.offset() as usize;
            map[off..off + BLOCK].copy_from_slice(&block);
        }
        let (ops, lat) = measure(MMAP_OPS, || {
            let off = rng.offset() as usize;
            map[off..off + BLOCK].copy_from_slice(&block);
            black_box(map[off]);
        });
        map.flush()?;
        emit(Row {
            name: "mmap.write.random4K",
            ops_per_second: ops,
            samples: MMAP_OPS,
            mean_latency_us: lat,
        });
    }

    Ok(())
}

fn usage() {
    eprintln!(
        "usage: bytes-bench-rust [PATH] [--file PATH] [--keep] [--help]\n\
         \n\
         Writes benchmark_test JSONL to stdout. 6 shared rows always; plus\n\
         iocp.* rows with --features iocp (Windows) or uring.* with --features\n\
         uring (Linux). See benchmark/rust/README.md."
    );
}

fn run() -> io::Result<()> {
    let mut path: Option<PathBuf> = None;
    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--help" | "-h" => {
                usage();
                return Ok(());
            }
            "--file" => {
                path = args.next().map(PathBuf::from);
                if path.is_none() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--file needs a path",
                    ));
                }
            }
            "--keep" => {}
            other => path = Some(PathBuf::from(other)),
        }
    }
    let path = path.unwrap_or_else(|| PathBuf::from("bench-rust.bin"));

    let file = ensure_file(&path)?;
    common(&file)?;
    drop(file);

    #[cfg(all(feature = "iocp", target_os = "windows"))]
    iocp::run(&path)?;

    #[cfg(all(feature = "uring", target_os = "linux"))]
    uring::run(&path)?;

    #[cfg(any(
        all(feature = "iocp", not(target_os = "windows")),
        all(feature = "uring", not(target_os = "linux")),
    ))]
    {
        eprintln!("note: iocp is Windows-only and uring is Linux-only; engine rows skipped");
    }

    Ok(())
}

fn main() {
    if let Err(err) = run() {
        eprintln!("error: {err}");
        std::process::exit(1);
    }
}
