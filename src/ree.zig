//! BSD 3-Clause License
//!
//! Copyright (c) raptodb
//! Copyright (c) Andrea Vaccaro
//! All rights reserved.
//!
//! Redistribution and use in source and binary forms, with or without
//! modification, are permitted provided that the following conditions are met:
//!
//! 1. Redistributions of source code must retain the above copyright notice, this
//!    list of conditions and the following disclaimer.
//!
//! 2. Redistributions in binary form must reproduce the above copyright notice,
//!    this list of conditions and the following disclaimer in the documentation
//!    and/or other materials provided with the distribution.
//!
//! 3. Neither the name of the copyright holder nor the names of its
//!    contributors may be used to endorse or promote products derived from
//!    this software without specific prior written permission.
//!
//! THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//! AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//! IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//! DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
//! FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
//! DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
//! SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
//! CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
//! OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
//! OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//!
//! This file is part of "Rapto".
//! It contains the implementation of Rapto Error Expander.

const std = @import("std");

const RAPTO_VERSION = @import("rapto.zig").RAPTO_VERSION;

const ResolveError = @import("Query.zig").ResolveError;
const OptionsError = @import("options.zig").OptionsError;
const ClientError = @import("server.zig").Server.ClientError;
const ServerSessionError = @import("rapto.zig").ServerSessionError;
const SaveError = @import("storage.zig").Storage.SaveError;

pub fn expandOptionsError(err: OptionsError) []const u8 {
    return switch (err) {
        error.InvalidOption => "Unknown option.",
        error.InvalidValue => "Invalid value.",
        error.InvalidMode => "Invalid mode. Must be 'server' or 'client'.",
        error.MissingMode => "Missing mode.",
        error.MissingName => "Missing name.",
        error.MissingValue => "Missing value.",
        error.InvalidDirectory => "Invalid/not found directory.",
        error.IncompleteAddr => "Incomplete address.",
        error.CacheLarger => "Cache is larger than database storage.",
        else => unreachable,
    };
}

pub fn expandResolveError(err: ResolveError) []const u8 {
    return switch (err) {
        error.CommandNotFound => "ERR: command does not exist",
        error.MissingTokens => "ERR: tokens missing",
        error.MismatchType => "ERR: incompatible types",
        error.TypeOverflow => "ERR: value too large for type",
        error.KeyNotFound => "ERR: key not found",
        error.KeyReplacementExist => "ERR: new name correspond to existent key",
        error.SaveFailed => "ERR: persistent saving is failed",
        error.InvalidObject => "ERR: serialized object is invalid.",
        error.InvalidMetadata => "ERR: metadata is corrupted.",
        error.NoKeysFound => "ERR: no keys found.",
        error.UnknownArgument => "ERR: invalid argument.",
        error.ExcedeedSpaceLimit => "ERR: excedeed db space limit.",
        else => unreachable,
    };
}

pub fn expandClientError(err: ClientError) []const u8 {
    return switch (err) {
        error.UnmatchVersion => "ERR: compatible-version=" ++ RAPTO_VERSION,
        error.HandshakeFail => "ERR: tls-handshake-fail",
        error.UnmatchKey => "ERR: auth-fail",
        error.DecryptionFail => "ERR: decryption-fail",

        // stream errors
        error.ConnectionTimedOut,
        error.SocketNotConnected,
        error.ConnectionResetByPeer,
        => "ERR: no-connection",

        else => "ERR: unknown",
    };
}

pub fn expandServerSessionError(err: ServerSessionError) []const u8 {
    return switch (err) {
        error.NoCapacity => "Capacity of database is undefined or 0.",
        error.CorruptedStat => "Cannot get stat of storage file.",
        error.ThreadError => "Cannot start thread.",
        error.BindError => "Cannot bind. Try to change port or try next time.",
        error.LoadingError => "Cannot load from storage. Read error occurred.",
        error.ExcedeedSpaceLimit => "Cannot load from storage. Space limit excedeed.",
        error.OpenError => "Cannot open storage file.",

        // stream errors
        error.NotOpenForWriting,
        error.ConnectionResetByPeer,
        => "Unstabilized connection.",
        else => "Unrecognized connection error.",
    };
}

pub fn expandSaveError(err: SaveError) []const u8 {
    return switch (err) {
        error.FileSeek => "File seek error. The storage file may not exist.",
        error.FileSync => "File sync error.",
        error.AccessDenied => "Check file permission.",
        error.FileTooBig => "File is too big.",
        else => "Unknown error.",
    };
}
