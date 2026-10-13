use crate::protocol::*;
use desktop_pet_contracts::{CliExtension, CliInvocation, CliOption, CliOutput};
use serde::de::{self, DeserializeSeed, MapAccess, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer};
use std::collections::HashSet;
use std::ffi::OsStr;
use std::fs;
use std::io::{self, Read, Write};
use std::mem::offset_of;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

pub fn decode_exchange_request(frame: &[u8]) -> Result<TernExchangeRequest, String> {
    let frame = match frame.strip_suffix(b"\n") {
        Some(frame) => frame.strip_suffix(b"\r").unwrap_or(frame),
        None => frame,
    };
    if frame.len() > MAX_EXCHANGE_BYTES {
        return Err("Tern exchange request JSON exceeds 256 KiB".into());
    }
    reject_duplicate_json_keys(frame).map_err(|error| format!("invalid Tern exchange: {error}"))?;
    serde_json::from_slice(frame).map_err(|error| format!("invalid Tern exchange: {error}"))
}

pub fn send_exchange(
    socket_path: &Path,
    frame: &[u8],
    timeout: Duration,
) -> Result<TernExchangeReply, String> {
    // Parse/size-check before connection, then forward the selected profile only.
    let request = decode_exchange_request(frame)?;
    if socket_path.as_os_str().is_empty() {
        return Err("control socket path is empty".into());
    }
    let mut bytes = serde_json::to_vec(&request)
        .map_err(|error| format!("cannot encode Tern exchange: {error}"))?;
    if bytes.len() > MAX_EXCHANGE_BYTES {
        return Err("Tern exchange request JSON exceeds 256 KiB".into());
    }
    bytes.push(b'\n');
    let deadline = Instant::now() + timeout;
    if let Ok(metadata) = fs::symlink_metadata(socket_path) {
        if metadata.file_type().is_symlink()
            || !metadata.file_type().is_socket()
            || metadata.uid() != desktop_pet_contracts::profile_store::effective_uid()
            || metadata.permissions().mode() & 0o777 != 0o600
        {
            return Err(format!(
                "control socket {} is not a private user socket",
                socket_path.display()
            ));
        }
    }
    let mut stream = connect(socket_path, deadline).map_err(|error| {
        format!(
            "cannot connect to control socket {}: {error}",
            socket_path.display()
        )
    })?;
    write_frame(&mut stream, &bytes, deadline)
        .map_err(|error| format!("cannot send Tern exchange: {error}"))?;
    let frame = read_frame(&mut stream, deadline)
        .map_err(|error| format!("cannot read Tern exchange: {error}"))?;
    reject_duplicate_json_keys(&frame)
        .map_err(|error| format!("invalid Tern exchange response: {error}"))?;
    let reply: TernExchangeReply = serde_json::from_slice(&frame)
        .map_err(|error| format!("invalid Tern exchange response: {error}"))?;
    validate_tern_reply(&reply, &request)?;
    Ok(reply)
}

pub(crate) struct ExchangeCli;
impl CliExtension for ExchangeCli {
    fn options(&self) -> &'static [CliOption] {
        &[]
    }
    fn commands(&self) -> &'static [&'static str] {
        &["tern-exchange"]
    }
    fn configure_option(&self, name: &str, _value: Option<&OsStr>) -> Result<(), String> {
        Err(format!("unknown Tern option: {name}"))
    }
    // Include optional CRLF and one proving oversize byte, never unbounded stdin.
    fn max_input_bytes(&self, _command: &str) -> usize {
        MAX_EXCHANGE_BYTES + 3
    }
    fn execute(&self, invocation: CliInvocation<'_>) -> Result<CliOutput, String> {
        if invocation.command != "tern-exchange" || !invocation.arguments.is_empty() {
            return Err("tern-exchange accepts no arguments".into());
        }
        let reply = send_exchange(
            &invocation.profile.control_socket,
            invocation.input,
            Duration::from_secs(2),
        )?;
        Ok(CliOutput {
            stdout: serialize_response(&reply)
                .map_err(|error| format!("cannot serialize Tern exchange: {error}"))?,
            stderr: vec![],
            exit_code: 0,
        })
    }
}

pub(crate) fn reject_duplicate_json_keys(bytes: &[u8]) -> Result<(), String> {
    let mut deserializer = serde_json::Deserializer::from_slice(bytes);
    UniqueJsonKeys
        .deserialize(&mut deserializer)
        .map_err(|error| error.to_string())?;
    deserializer.end().map_err(|error| error.to_string())
}

fn write_frame(stream: &mut UnixStream, bytes: &[u8], deadline: Instant) -> io::Result<()> {
    let mut written = 0;
    while written < bytes.len() {
        stream.set_write_timeout(Some(remaining(deadline)?))?;
        let count = stream.write(&bytes[written..])?;
        if count == 0 {
            return Err(io::Error::new(
                io::ErrorKind::WriteZero,
                "control peer closed while writing",
            ));
        }
        written += count;
    }
    Ok(())
}

fn read_frame(stream: &mut UnixStream, deadline: Instant) -> io::Result<Vec<u8>> {
    let mut frame = Vec::with_capacity(16 * 1024);
    let mut chunk = [0u8; 1024];
    loop {
        let read = read_with_deadline(stream, &mut chunk, deadline)?;
        if read == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "control peer closed before frame terminator",
            ));
        }
        let newline = chunk[..read].iter().position(|byte| *byte == b'\n');
        let count = newline.unwrap_or(read);
        if frame.len() + count >= MAX_RESPONSE_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "control frame exceeds limit",
            ));
        }
        frame.extend_from_slice(&chunk[..count]);
        if newline.is_some() {
            if frame.last() == Some(&b'\r') {
                frame.pop();
            }
            return Ok(frame);
        }
    }
}

struct UniqueJsonKeys;

impl<'de> DeserializeSeed<'de> for UniqueJsonKeys {
    type Value = ();

    fn deserialize<D>(self, deserializer: D) -> Result<Self::Value, D::Error>
    where
        D: Deserializer<'de>,
    {
        deserializer.deserialize_any(UniqueJsonVisitor)
    }
}

struct UniqueJsonVisitor;

impl<'de> Visitor<'de> for UniqueJsonVisitor {
    type Value = ();

    fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("a JSON value")
    }

    fn visit_map<A>(self, mut access: A) -> Result<Self::Value, A::Error>
    where
        A: MapAccess<'de>,
    {
        let mut keys = HashSet::new();
        while let Some(key) = access.next_key::<String>()? {
            if !keys.insert(key) {
                return Err(de::Error::custom("duplicate JSON object key"));
            }
            access.next_value_seed(UniqueJsonKeys)?;
        }
        Ok(())
    }

    fn visit_seq<A>(self, mut access: A) -> Result<Self::Value, A::Error>
    where
        A: SeqAccess<'de>,
    {
        while access.next_element_seed(UniqueJsonKeys)?.is_some() {}
        Ok(())
    }

    fn visit_bool<E>(self, _value: bool) -> Result<Self::Value, E>
    where
        E: de::Error,
    {
        Ok(())
    }

    fn visit_i64<E>(self, _value: i64) -> Result<Self::Value, E>
    where
        E: de::Error,
    {
        Ok(())
    }

    fn visit_u64<E>(self, _value: u64) -> Result<Self::Value, E>
    where
        E: de::Error,
    {
        Ok(())
    }

    fn visit_f64<E>(self, _value: f64) -> Result<Self::Value, E>
    where
        E: de::Error,
    {
        Ok(())
    }

    fn visit_str<E>(self, _value: &str) -> Result<Self::Value, E>
    where
        E: de::Error,
    {
        Ok(())
    }

    fn visit_string<E>(self, _value: String) -> Result<Self::Value, E>
    where
        E: de::Error,
    {
        Ok(())
    }

    fn visit_unit<E>(self) -> Result<Self::Value, E>
    where
        E: de::Error,
    {
        Ok(())
    }
}

pub(crate) fn remaining(deadline: Instant) -> io::Result<Duration> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|duration| !duration.is_zero())
        .ok_or_else(|| io::Error::new(io::ErrorKind::TimedOut, "socket deadline elapsed"))
}

/// Read one nonblocking chunk without changing the caller's socket mode.
pub(crate) fn read_with_deadline(
    stream: &mut UnixStream,
    buffer: &mut [u8],
    deadline: Instant,
) -> io::Result<usize> {
    if buffer.is_empty() {
        return Ok(0);
    }
    let fd = stream.as_raw_fd();
    // SAFETY: fd remains owned by stream for this function's duration.
    let original_flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if original_flags < 0 {
        return Err(io::Error::last_os_error());
    }
    let originally_nonblocking = original_flags & libc::O_NONBLOCK != 0;
    if !originally_nonblocking {
        // SAFETY: fd remains owned by stream and original_flags came from F_GETFL.
        if unsafe { libc::fcntl(fd, libc::F_SETFL, original_flags | libc::O_NONBLOCK) } < 0 {
            return Err(io::Error::last_os_error());
        }
    }

    let result = loop {
        let timeout = match remaining(deadline) {
            Ok(timeout) => timeout,
            Err(error) => break Err(error),
        };
        let milliseconds = timeout.as_millis().saturating_add(1).min(i32::MAX as u128);
        let mut descriptor = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: descriptor points to one initialized pollfd for a live fd.
        let polled = unsafe { libc::poll(&mut descriptor, 1, milliseconds as i32) };
        if polled < 0 {
            let error = io::Error::last_os_error();
            if matches!(
                error.kind(),
                io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
            ) {
                continue;
            }
            break Err(error);
        }
        if polled == 0 {
            break Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "socket read timed out",
            ));
        }
        match stream.read(buffer) {
            Ok(read) => break Ok(read),
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
                ) =>
            {
                continue;
            }
            Err(error) => break Err(error),
        }
    };

    if !originally_nonblocking {
        // SAFETY: fd remains owned by stream and original_flags came from F_GETFL.
        if unsafe { libc::fcntl(fd, libc::F_SETFL, original_flags) } < 0 {
            return Err(io::Error::last_os_error());
        }
    }
    result
}

/// Connect without allowing a stalled/full Unix listener to block its caller.
/// Callers must renew write I/O timeouts from the same deadline before subsequent I/O.
pub(crate) fn connect(path: &Path, deadline: Instant) -> io::Result<UnixStream> {
    remaining(deadline)?;
    let bytes = path.as_os_str().as_bytes();
    // SAFETY: sockaddr_un consists only of integer fields and a byte array.
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if bytes.is_empty() || bytes.contains(&0) || bytes.len() >= address.sun_path.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Unix socket path is empty, contains NUL, or exceeds the platform limit",
        ));
    }
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    for (target, source) in address.sun_path.iter_mut().zip(bytes) {
        *target = *source as libc::c_char;
    }
    let length = offset_of!(libc::sockaddr_un, sun_path) + bytes.len() + 1;
    #[cfg(target_os = "macos")]
    {
        address.sun_len = length as u8;
    }
    // SAFETY: socket has no pointer arguments; ownership transfers immediately
    // into UnixStream so every subsequent error closes the descriptor.
    let fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: fd is a newly created, uniquely owned stream socket.
    let stream = unsafe { UnixStream::from_raw_fd(fd) };
    // SAFETY: the descriptor remains valid for the lifetime of stream.
    if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
        return Err(io::Error::last_os_error());
    }
    stream.set_nonblocking(true)?;
    // SAFETY: address is initialized, its path is NUL-terminated, and length
    // covers only initialized bytes within sockaddr_un.
    let connected = unsafe {
        libc::connect(
            stream.as_raw_fd(),
            (&address as *const libc::sockaddr_un).cast(),
            length as libc::socklen_t,
        )
    };
    if connected < 0 {
        let error = io::Error::last_os_error();
        if !matches!(
            error.raw_os_error(),
            Some(libc::EINPROGRESS | libc::EALREADY | libc::EINTR)
        ) {
            // In particular, EAGAIN on a full Unix accept queue is a bounded
            // retryable failure, not evidence that a connection has started.
            return Err(error);
        }
        loop {
            let timeout = remaining(deadline)?;
            let milliseconds = timeout.as_millis().saturating_add(1).min(i32::MAX as u128);
            let mut descriptor = libc::pollfd {
                fd: stream.as_raw_fd(),
                events: libc::POLLOUT,
                revents: 0,
            };
            // SAFETY: descriptor points to one initialized pollfd for a live fd.
            let result = unsafe { libc::poll(&mut descriptor, 1, milliseconds as i32) };
            if result < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            if result == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "socket connect timed out",
                ));
            }
            remaining(deadline)?;
            if let Some(error) = stream.take_error()? {
                return Err(error);
            }
            break;
        }
    }
    stream.set_nonblocking(false)?;
    let timeout = remaining(deadline)?;
    stream.set_read_timeout(Some(timeout))?;
    stream.set_write_timeout(Some(timeout))?;
    Ok(stream)
}

fn validate_tern_reply(
    reply: &TernExchangeReply,
    request: &TernExchangeRequest,
) -> Result<(), String> {
    if reply.instance_id.is_empty()
        || reply.instance_id.len() > 4096
        || reply.instance_id.contains('\0')
        || (reply.ok
            && (reply.error.is_some()
                || reply.error_code.is_some()
                || reply.hosts.len() != request.hosts.len()
                || request
                    .instance_id
                    .as_deref()
                    .is_some_and(|instance| instance != reply.instance_id)))
        || (!reply.ok
            && (reply.error.as_deref().is_none_or(str::is_empty)
                || reply
                    .error
                    .as_ref()
                    .is_some_and(|error| error.len() > 4096 || error.contains('\0'))
                || reply.error_code.is_none()
                || !reply.hosts.is_empty()
                || reply.command.is_some()))
    {
        return Err("invalid Tern exchange response fields".into());
    }
    let mut seen = HashSet::with_capacity(reply.hosts.len());
    for (host, inventory) in reply.hosts.iter().zip(&request.hosts) {
        if !canonical_host(&host.host)
            || !seen.insert(host.host.as_str())
            || host.host != inventory.host
            || host.observation_generation == 0
            || host.observation_generation > MAX_SAFE_INTEGER
            || host.observation_generation != inventory.observation_generation
            || host.generation > MAX_SAFE_INTEGER
            || host.error.as_ref().is_some_and(|error| {
                error.is_empty() || error.len() > MAX_HOST_ERROR_BYTES || error.contains('\0')
            })
            || host.error.is_some() != host.error_code.is_some()
            || host
                .error_code
                .is_some_and(|code| code != TernExchangeErrorCode::Rejected)
            || (inventory.status == TernHostStatus::Available
                && host.generation == 0
                && host.error.is_none())
        {
            return Err("invalid Tern host response fields or request correspondence".into());
        }
    }
    if let Some(command) = &reply.command {
        let local = request.hosts.iter().position(|host| host.is_local);
        if !reply.ok
            || request.instance_id.is_none()
            || command.operation_id.is_empty()
            || command.operation_id.len() > 4096
            || command.operation_id.contains('\0')
            || command.pane.is_empty()
            || command.pane.len() > 4096
            || command.pane.contains('\0')
            || local.is_none_or(|index| {
                request.hosts[index].status != TernHostStatus::Available
                    || reply.hosts[index].generation == 0
                    || reply.hosts[index].error.is_some()
                    || !request.hosts[index]
                        .agents
                        .iter()
                        .any(|agent| agent.pane == command.pane)
            })
        {
            return Err("invalid or nonlocal Tern command response".into());
        }
    }
    Ok(())
}
