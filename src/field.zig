//! BSD 3-Clause License
//!
//! Copyright (c) Raptodb
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
//! It contains the implementation of fields.

pub const Types = @import("field/types.zig").Types;
pub const ScalarItem = @import("field/scalar.zig").ScalarItem;

pub const Void = @import("field/scalar.zig").Void;
pub const Integer = @import("field/scalar.zig").Integer;
pub const Decimal = @import("field/scalar.zig").Decimal;
pub const Flag = @import("field/scalar.zig").Flag;
pub const String = @import("field/scalar.zig").String;
pub const Point = @import("field/scalar.zig").Point;

pub const List = @import("field/collection.zig").List;
pub const Map = @import("field/collection.zig").Map;

pub const splitSerialized = @import("field/types.zig").splitSerialized;

test {
    _ = @import("field/types.zig");
    _ = @import("field/scalar.zig");
    _ = @import("field/collection.zig");
}
