//! Linux io_uring engine rows.
//!
//! One measured body = `QD` (32) independent 4 KiB random reads/writes submitted
//! as SQEs, then harvested as CQEs. Mirrors the Dart IOCP engine's batched copy
//! semantics: one big buffer for the whole batch, one copy in/out per body.
//!
//! Emitted rows (throughput is bodies/sec, the chart multiplies by 32):
//!   uring.read.random4K.qd32
//!   uring.write.random4K.qd32

use std::fs::{File, OpenOptions};
use std::hint::black_box;
use std::io;
use std::os::fd::AsRawFd;
use std::path::Path;

use io_uring::{opcode, types, IoUring};

use crate::{emit, fill_pattern, measure, Rng, Row, BLOCK, ENGINE_BODIES, ENGINE_WARMUP, QD};

fn open(path: &Path) -> io::Result<File> {
    OpenOptions::new().read(true).write(true).open(path)
}

fn submit_read(ring: &mut IoUring, fd: i32, offsets: &[u64; QD], buf: &mut [u8]) -> io::Result<()> {
    {
        let mut sq = ring.submission();
        for (i, &offset) in offsets.iter().enumerate() {
            let slice = &mut buf[i * BLOCK..(i + 1) * BLOCK];
            let entry = opcode::Read::new(types::Fd(fd), slice.as_mut_ptr(), BLOCK as u32)
                .offset(offset)
                .build();
            unsafe { sq.push(&entry) }
                .map_err(|_| io::Error::other("io_uring submission queue full"))?;
        }
    }
    finish_batch(ring, offsets.len(), "read")
}

fn submit_write(ring: &mut IoUring, fd: i32, offsets: &[u64; QD], buf: &[u8]) -> io::Result<()> {
    {
        let mut sq = ring.submission();
        for (i, &offset) in offsets.iter().enumerate() {
            let slice = &buf[i * BLOCK..(i + 1) * BLOCK];
            let entry = opcode::Write::new(types::Fd(fd), slice.as_ptr(), BLOCK as u32)
                .offset(offset)
                .build();
            unsafe { sq.push(&entry) }
                .map_err(|_| io::Error::other("io_uring submission queue full"))?;
        }
    }
    finish_batch(ring, offsets.len(), "write")
}

fn finish_batch(ring: &mut IoUring, want: usize, kind: &str) -> io::Result<()> {
    ring.submit_and_wait(want)?;
    let mut done = 0;
    for cqe in ring.completion() {
        let result = cqe.result();
        if result != BLOCK as i32 {
            return Err(io::Error::other(format!(
                "io_uring {kind} completion result {result}"
            )));
        }
        done += 1;
    }
    if done != want {
        return Err(io::Error::other(format!(
            "io_uring {kind} completions {done}/{want}"
        )));
    }
    Ok(())
}

fn read_body(
    ring: &mut IoUring,
    fd: i32,
    rng: &mut Rng,
    offsets: &mut [u64; QD],
    buf: &mut [u8],
    out: &mut [u8],
) -> io::Result<()> {
    for offset in offsets.iter_mut() {
        *offset = rng.offset();
    }
    submit_read(ring, fd, offsets, buf)?;
    out.copy_from_slice(buf);
    black_box(out[0]);
    Ok(())
}

fn write_body(
    ring: &mut IoUring,
    fd: i32,
    rng: &mut Rng,
    offsets: &mut [u64; QD],
    src: &[u8],
    scratch: &mut [u8],
) -> io::Result<()> {
    scratch.copy_from_slice(src);
    for offset in offsets.iter_mut() {
        *offset = rng.offset();
    }
    submit_write(ring, fd, offsets, scratch)?;
    black_box(scratch[0]);
    Ok(())
}

pub(crate) fn run(path: &Path) -> io::Result<()> {
    let file = open(path)?;
    let fd = file.as_raw_fd();
    let mut ring = IoUring::new(QD as u32)?;
    let mut rng = Rng::new();
    let mut offsets = [0u64; QD];
    let mut read_buf = vec![0u8; QD * BLOCK];
    let mut read_out = vec![0u8; QD * BLOCK];
    let mut write_src = vec![0u8; QD * BLOCK];
    fill_pattern(&mut write_src, 13, 7);
    let mut write_scratch = vec![0u8; QD * BLOCK];

    for _ in 0..ENGINE_WARMUP {
        read_body(
            &mut ring,
            fd,
            &mut rng,
            &mut offsets,
            &mut read_buf,
            &mut read_out,
        )?;
    }
    let (ops, lat) = measure(ENGINE_BODIES, || {
        read_body(
            &mut ring,
            fd,
            &mut rng,
            &mut offsets,
            &mut read_buf,
            &mut read_out,
        )
        .unwrap();
    });
    emit(Row {
        name: "uring.read.random4K.qd32",
        ops_per_second: ops,
        samples: ENGINE_BODIES,
        mean_latency_us: lat,
    });

    for _ in 0..ENGINE_WARMUP {
        write_body(
            &mut ring,
            fd,
            &mut rng,
            &mut offsets,
            &write_src,
            &mut write_scratch,
        )?;
    }
    let (ops, lat) = measure(ENGINE_BODIES, || {
        write_body(
            &mut ring,
            fd,
            &mut rng,
            &mut offsets,
            &write_src,
            &mut write_scratch,
        )
        .unwrap();
    });
    emit(Row {
        name: "uring.write.random4K.qd32",
        ops_per_second: ops,
        samples: ENGINE_BODIES,
        mean_latency_us: lat,
    });

    Ok(())
}
